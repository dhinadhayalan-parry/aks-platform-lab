# Runbooks

Alert annotations link here. Each entry covers what the alert means, the first three commands to
run, and when to escalate. Use `scripts/cluster.sh creds` first.

## PodinfoErrorBudgetFastBurn

**Meaning:** in both the last 1 h and the last 5 min, more than 7.2% of requests returned 5xx
(14.4× the 0.5% budget). At that rate the 30-day budget is gone in under 2 days. **Page.**

1. What changed? `kubectl -n podinfo get hr podinfo -o jsonpath='{.status.history[0]}'` and `flux events -n podinfo` (or `kubectl get events -n podinfo --sort-by=.lastTimestamp`).
2. Is it the app or the platform? Grafana "podinfo SLO" → *Requests by status*: a single `status` value spiking points to the app; a drop in total requests points to the Gateway or network.
3. Is the error injector running? `kubectl -n podinfo get deploy loadgen-errors`. Replicas > 0 means it's a drill.

**Mitigate before you debug:** revert the last merged PR under `gitops/apps/`. Flux applies it within 2 minutes (`flux reconcile kustomization platform-apps --with-source` to speed it up).

## PodinfoErrorBudgetSlowBurn

**Meaning:** a sustained 3% error ratio over 6 h (6× budget). Not urgent; open a ticket.
Check *Requests by status* over 12 h for a slow regression and compare HelmRelease revisions.

## PodinfoLatencyP95High

**Meaning:** p95 above 250 ms for 10 minutes.
1. CPU throttling? Grafana → *CPU and memory per pod*; `kubectl -n podinfo top pods`.
2. HPA at max? `kubectl -n podinfo get hpa`: if replicas are at 4 and CPU is high, the apps node is full.
3. Node pressure? `kubectl describe node -l platform.lab/pool=apps | grep -A5 Allocated`.

## LabClusterRunningAfterHours

**Meaning:** the cluster is running between 22:00 and 07:00 Berlin time (about €0.22/h).
`scripts/cluster.sh down`. During the soak week, silence it for 7 days rather than deleting the rule.

## LabNodeCountAboveBudget

**Meaning:** more than 2 nodes for 10 minutes. Usually a stuck surge node from an upgrade, or a manual scale.
1. `scripts/cluster.sh status`: pool counts and provisioning state.
2. `az aks nodepool show -g rg-plat-lab-platform --cluster-name aks-plat-lab -n system --query '{state:provisioningState, upgrade:upgradeSettings}'`.
3. If an upgrade failed half-way, re-run the Terraform apply; AKS resumes the upgrade.

## ExternalSecret sync failures (from ESO metrics / `kubectl get es -A`)

1. `kubectl -n monitoring describe es grafana-admin`: look for `403` (RBAC), `SecretDisabled` or an expired secret.
2. Expired secret? The scheduled rotation wasn't applied. Merge a no-op PR to trigger apply, or bump `secrets_version`.
3. `403`: check the federated credential subject still matches `system:serviceaccount:external-secrets:external-secrets` and that the AKS OIDC issuer didn't change (it does after a cluster rebuild; Terraform recreates the credential on apply).
