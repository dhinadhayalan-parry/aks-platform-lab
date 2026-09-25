# 30-day plan: production experience on trial credit

About 15–20 hours a week. Every drill ends with a written artefact (a postmortem, a decision
record, a measured number). Those artefacts are what you take into interviews.

**Daily routine.** Start with `scripts/cluster.sh up` and end with `scripts/cluster.sh down`.
The nightly workflow stops the cluster at 22:07 anyway, and Prometheus warns you after 22:00.
Run `scripts/cost-report.sh` on Mondays and Thursdays (Azure cost data lags 8–24 h).

**Credit check.** Planned total ≈ €52. If month-to-date spend is more than €10 above the table
in the README, cut soak hours first.

---

## Week 1: build it the way a team would (≈15 running hours, ≈€3)

| Day | Do | Done when |
|---|---|---|
| 1 | `preflight.sh`, `bootstrap.sh`, GitHub variables/secret/environment | Budget visible in Cost Management; bootstrap state in blob |
| 2 | Open a PR that changes only a tag → watch **plan** run as `id-gh-plan`; merge → approve **apply** | Cluster exists; `kubectl get nodes` works through Entra |
| 3 | Watch Flux reconcile the layers: `kubectl get kustomizations,helmreleases -A -w` | All Ready; Grafana shows the podinfo SLO dashboard; `curl http://<gateway-ip>/` returns podinfo JSON |
| 4–5 | Drills 1–3 | Three short notes in `docs/notes/` |

### Drill 1: state lock and a stuck apply
1. Start a plan locally and leave it waiting at the approval prompt (`make plan`, then `terraform apply` without answering).
2. In a second shell, run `make plan` → `Error acquiring the state lock`. Read the lock ID and the lease on the blob:
   `az storage blob show --auth-mode login --account-name <sa> -c tfstate -n lab/platform.tfstate --query properties.lease`.
3. Kill the first shell with `kill -9` (a crashed CI runner). The lease survives.
4. Recover the right way: confirm nobody is applying, then `terraform force-unlock <ID>`. Discuss why breaking the blob lease by hand is the last resort.

**Capture:** how the azurerm backend implements locking (blob lease), and the check you do before `force-unlock`.

### Drill 2: drift
1. In the portal, add an inbound rule to `nsg-plat-lab-nodes` (e.g. allow 22 from anywhere).
2. Run the `terraform` workflow's scheduled job manually (or `make plan`). Plan shows the rule being removed; the drift job fails red.
3. Decide: revert (apply) or codify (PR). Revert.

**Capture:** a one-paragraph drift policy: who can change the portal, how drift is detected, what happens next.

### Drill 3: refactor without destroying anything
1. Rename `module "secrets"` to `module "platform_secrets"` in `infra/live/lab/main.tf`. Plan: Key Vault **destroy/create**. Stop.
2. Add a `moved { from = module.secrets to = module.platform_secrets }` block. Plan: 0 to destroy.
3. In the portal, create a `CanNotDelete` lock on `rg-plat-lab-platform`. Bring it under Terraform with an `import {}` block plus a matching `azurerm_management_lock` resource. Plan must show `1 to import, 0 to add`.

**Capture:** when you'd use `moved`, `import`, `removed`, and `terraform state mv`, and why the first three are better (reviewed in a PR).

---

## Week 2: observability you can defend (≈20 running hours, ≈€4)

Read `gitops/monitoring/rules/podinfo-slo.yaml` and its test first. Be ready to explain the
14.4× / 6× numbers without notes: 14.4× burn for 1 h uses 2% of a 30-day budget.

### Drill 4: SLO page, end to end
1. PR: `loadgen-errors` `replicas: 0 → 1` (1 rps of 500s against 5 rps of good traffic ≈ 16.7% errors ≈ 33× burn).
2. Merge. Time these: merge → Flux applies → fast-burn fires (`for: 2m`) → Slack message.
3. Silence it for 30 minutes in Alertmanager (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093`), with a comment.
4. Revert the PR. Watch the 5-minute window clear first, then the 1-hour one. The alert resolves as soon as the **5-minute** condition fails. That's why there are two windows.

**Capture:** a blameless postmortem (timeline, detection time, what the dashboard showed, error budget used).

### Drill 5 (prep): know your capacity numbers
From Grafana (Kubernetes / Compute Resources / Cluster): CPU and memory **requests** vs allocatable on the apps node.
Write down how much headroom is left. You'll need it in week 3.

### Drill 8: a bad release rolls itself back
1. PR: podinfo `image.tag: "does-not-exist"` in `gitops/apps/podinfo/release.yaml` values.
2. Watch `kubectl -n podinfo get hr podinfo -w`: upgrade → ImagePullBackOff → 5 min timeout → **rollback** (remediation strategy) → Ready on the previous revision. Traffic never drops: the old ReplicaSet keeps serving, and the PDB and maxUnavailable settings protect it.
3. Git still says `does-not-exist`. Flux retries 2 times, then stops. Fix with a revert PR.

**Capture:** the difference between the cluster being healthy and the cluster matching Git, and which alert tells you they have diverged (`kubectl get hr`, Flux events).

---

## Week 3: production week (5 days 24/7, ≈€33)

Setup: repository variable `SOAK_MODE=true` (the nightly stop skips); PR `sku_tier = "Standard"`
for 72 h; silence `LabClusterRunningAfterHours` for the week. Check Slack twice a day like an
on-call engineer and log everything in `docs/notes/oncall-week.md`.

### Drill 5: quota-constrained Kubernetes upgrade
1. `az aks get-upgrades -g rg-plat-lab-platform -n aks-plat-lab -o table`. PR: pin `kubernetes_version` to the **current** minor. Plan must be a no-op.
2. PR: bump to the next minor. Apply. The control plane upgrades, then the **system pool fails with `QuotaExceeded`**: it needs a surge node (+2 vCPU) and system pools can't use `maxUnavailable`.
3. Recovery options, and pick one:
   - a) PR `apps_node_count = 0`, re-apply (the system pool surges into the freed quota), then `apps_node_count = 1`. **Cost:** apps are down for the window. Watch the SLO burn.
   - b) In production: quota headroom is a capacity policy (≥ 1 node per pool + 1). Here it can't be requested.
4. The apps pool then upgrades in place (`maxUnavailable=1`, no surge). With one apps node that is also downtime.

**Capture:** a decision record: "upgrade strategy vs quota", including the SLO minutes it cost and what you'd change with a real budget (a second apps node, zones, blue/green node pools).

### Drill 6: lose a node
1. `az vmss list -g rg-plat-lab-aks-nodes -o table`, then `az vmss restart` the **apps** pool instance.
2. Watch: node NotReady → podinfo pods can't reschedule (the system pool is tainted) → fast-burn page.
3. Explain why the PDB didn't help: PDBs only cover **voluntary** disruptions.

**Capture:** MTTR, and the argument for N+1 on user pools.

### Drill 7: rotate a secret, find the missing piece
1. PR: `secrets_version = 2`. Apply → new Key Vault secret version. Check that state holds no secret: `terraform state pull | jq '.resources[] | select(.type=="azurerm_key_vault_secret") | .instances[].attributes | {name, value, value_wo_version}'` → `value` is null.
2. Force ESO: `kubectl -n monitoring annotate es grafana-admin force-sync=$(date +%s) --overwrite`. The Kubernetes secret changes.
3. Log in to Grafana with the new password. **It fails.** Environment variables are read at pod start.
4. Fix it properly: add a checksum or Reloader annotation, or `kubectl rollout restart` as the documented step. Implement one in Git.

**Capture:** "rotation is a pipeline, not a value change".

End of week: PR `sku_tier = "Free"`, `SOAK_MODE=false`.

---

## Week 4: disaster recovery and the story (≈20 running hours, ≈€4)

### Drill 9: rebuild from nothing, and measure it
1. Remove the resource-group lock from drill 3 first (PR deleting the resource), otherwise destroy fails on every child resource. Then `terraform -chdir=infra/live/lab destroy` (the bootstrap stack stays).
2. Start a stopwatch. Push an empty commit to trigger apply. Stop when `curl http://<new-ip>/` returns 200 **and** the Watchdog alert is flowing.
3. Write down what did **not** come back: 7 days of metrics (the PV is gone). The Key Vault is a new one (random suffix); the old one is in soft delete.

**Capture:** measured RTO; RPO for metrics = everything; the options (Prometheus `remote_write` to a durable store, Thanos/Mimir, Azure Monitor workspace) with cost trade-offs.

### Drill 10: review your own platform like a security reviewer
- Go through the 16 checkov skips in `infra/`. For each one, can you defend it in one sentence, and what would change in production?
- `kubectl auth can-i --list --as=system:serviceaccount:external-secrets:external-secrets`: is that least privilege?
- Which identities can do what? Draw the RBAC map (humans, 3 CI identities, AKS control plane, kubelet, ESO).

### Wrap-up (last 2 days)
- Fill in the "Results" table in `docs/interview-notes.md` with your **measured** numbers.
- Record a 3-minute screen capture: PR → plan → apply → Flux → page in Slack → revert.
- Teardown (README). Check Cost Management the next day.

## Stretch goals if credit is left
- OpenTelemetry Collector → traces from podinfo to Grafana Tempo (single binary, small PV).
- Loki for logs, with retention sized to fit the PV.
- kube-state-metrics custom resource metrics for Flux readiness and an alert on `Ready=False` > 15 min.
- Replace the nightly stop with KEDA cron scaling of the apps pool, and compare the savings.
