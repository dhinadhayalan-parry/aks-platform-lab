SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

TF ?= terraform
SCHEMAS := .schemas
LAYERS := infrastructure/controllers infrastructure/configs monitoring apps

.PHONY: help
help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

.PHONY: validate
validate: tf-validate tf-lint tf-policy gitops-validate rules-test shellcheck ## run every local check CI runs

.PHONY: tf-validate
tf-validate: ## fmt + validate both stacks + offline tests
	$(TF) fmt -check -recursive infra
	for d in infra/bootstrap infra/live/lab; do $(TF) -chdir=$$d init -backend=false -input=false >/dev/null; $(TF) -chdir=$$d validate; done
	$(TF) -chdir=infra/live/lab test

.PHONY: tf-lint
tf-lint: ## tflint with the azurerm ruleset
	tflint --init --config $(CURDIR)/.tflint.hcl
	tflint --recursive --config $(CURDIR)/.tflint.hcl --format compact

.PHONY: tf-policy
tf-policy: ## checkov (skips are inline, each with a reason)
	checkov --config-file .checkov.yaml

.PHONY: gitops-validate
gitops-validate: ## kustomize build + strict kubeconform against pinned CRDs
	python3 scripts/gen_crd_schemas.py gitops $(SCHEMAS)
	for l in $(LAYERS); do kustomize build gitops/$$l | kubeconform -strict -summary -schema-location default -schema-location "$(SCHEMAS)/{{ .ResourceKind }}-{{ .Group }}-{{ .ResourceAPIVersion }}.json"; done

.PHONY: rules-test
rules-test: ## promtool lint + unit tests for alert rules
	tmp=$$(mktemp -d); \
	for f in gitops/monitoring/rules/*.yaml; do yq -o=yaml '.spec' $$f > $$tmp/$$(basename $${f%.yaml}).rules.yaml; done; \
	promtool check rules $$tmp/*.rules.yaml; cp gitops/monitoring/tests/*.test.yaml $$tmp/; promtool test rules $$tmp/*.test.yaml

.PHONY: shellcheck
shellcheck: ## lint scripts
	shellcheck -x -P scripts scripts/*.sh

.PHONY: plan
plan: ## local plan against remote state (needs infra/live/lab/backend.hcl + lab.auto.tfvars)
	$(TF) -chdir=infra/live/lab init -backend-config=backend.hcl
	$(TF) -chdir=infra/live/lab plan -lock-timeout=5m
