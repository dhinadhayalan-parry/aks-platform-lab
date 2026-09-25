# Interview notes

Fill in the results with numbers you actually measured. An interviewer will push on any number,
so only use ones you can explain.

## Results (measured)

| Metric | Value | How measured |
|---|---|---|
| Cold rebuild RTO (drill 9) | _fill in_ min | empty commit → podinfo 200 via Gateway + Watchdog in Slack |
| Detection time, fast burn (drill 4) | _fill in_ min | merge of error PR → Slack page |
| Bad release auto-rollback (drill 8) | _fill in_ min, 0 failed requests | helm-controller events + SLO dashboard |
| SLO cost of quota-constrained upgrade (drill 5) | _fill in_ min of errors | error budget panel before/after |
| Node-loss MTTR (drill 6) | _fill in_ min | node NotReady → all podinfo pods Ready |
| Total cloud spend | €_fill in_ | scripts/cost-report.sh at teardown |

## 60-second overview

"I built a small production-style AKS platform and ran it for a month on €100 of trial credit.
Terraform owns Azure: networking, the cluster, Key Vault and the identities. Everything inside
the cluster is GitOps through Flux, in four ordered layers. CI uses OIDC with three separate
identities: plan is read-only, apply is behind an environment approval and can only grant two
specific roles, and a third identity can only start and stop the cluster. Observability is
Prometheus and Grafana with a proper SLO: burn-rate alerts with unit tests. Then I broke it on
purpose ten times and wrote up each incident."

## Decisions and trade-offs (be ready to argue the other side)

**Terraform stops at the cluster boundary; Flux owns the inside.** No helm or kubernetes
provider in Terraform. The hand-off is the AKS Flux extension plus postBuild substitution of four
values (tenant, Key Vault URL, ESO client ID, cluster name). *Trade-off:* two reconciliation
loops to understand. *Gain:* no provider chicken-and-egg with a cluster that doesn't exist yet,
no Kubernetes credentials in CI, and drift inside the cluster is corrected continuously rather
than at the next apply.

**Substitution only in two layers.** Flux envsubst would silently blank `$value` in alert
annotations and `$__rate_interval` in dashboards. The monitoring and app layers have no
substitution, and CI fails if a `$` appears in the substituted layers.

**Least privilege in CI with ABAC conditions.** The apply identity has "Role Based Access Control
Administrator" constrained to Key Vault Secrets User and Network Contributor, for service
principals only. It can wire up workload identity but can't make anyone Owner. Gotcha:
`principal_type` has to be set on every role assignment, or the condition has nothing to evaluate
and the write is denied.

**Secrets never touch state.** Ephemeral `random_password` feeds a write-only `value_wo`. Rotation
is driven by a version number: every 90 days via `time_rotating`, or manually. Expiry is set
7 days after the rotation date, so a rotation nobody applied fails loudly instead of silently.

**Free-tier constraints designed in, not worked around.** 4-vCPU quota: the apps pool upgrades
in place with `maxUnavailable`; the system pool can't, and I documented what that costs. Spot
isn't allowed on trials, so the savings come from a nightly stop. Maintenance windows run in the
daytime because a cluster that is stopped at night never gets patched in a 02:00 window.

**Gateway API from day one.** ingress-nginx is retired upstream. Envoy Gateway, with the Azure LB
health probe switched to TCP, because the default HTTP probe on "/" got 404 from Envoy and would
mark every backend unhealthy.

**SLO alerting instead of threshold alerting.** Multi-window burn rates (14.4× over 1 h and 5 min;
6× over 6 h and 30 min). The short window makes the alert resolve quickly after a fix; the long
window stops it firing on blips. The rules have promtool unit tests in CI, including one that
proves health-check 500s are excluded from the SLI.

**What I'd change with a real budget.** Three availability zones and N+1 on every pool; Standard
tier always; private cluster, Key Vault and state behind private endpoints with self-hosted
runners; metrics `remote_write` to durable storage; Azure Policy or Kyverno admission control;
cosign-verified images.

## Incident stories (STAR, from the drills)

1. **Upgrade blocked by quota (drill 5).** *Situation:* a minor upgrade on a quota-capped
   subscription. *Task:* upgrade without asking for quota. *Action:* found that system pools
   can't use maxUnavailable, freed quota by scaling the user pool to zero for the window,
   measured the SLO cost. *Result:* upgrade done, _X_ minutes of budget spent, and a capacity
   policy (N+1 headroom) written as a decision record.
2. **Secret rotated, service still broken (drill 7).** Key Vault, ESO and the Kubernetes Secret
   all updated, yet login failed because environment variables are read once at pod start.
   Fixed it with a reload mechanism in Git. Lesson: rotation is a pipeline, not a value change.
3. **Bad release rolled itself back (drill 8).** An image tag typo reached production through a
   reviewed PR. helm-controller remediation rolled back after the readiness timeout with zero
   failed requests. The follow-up was an alert for "cluster diverged from Git", because a
   successful rollback is invisible otherwise.
4. **Stuck state lock (drill 1).** A killed apply left the blob lease held. Checked that no
   apply was running, then force-unlock. Knowing the backend implementation (a blob lease) is
   what made the recovery safe.

## Resume bullets (use only after doing the drills)

- Built a GitOps AKS platform (Terraform + Flux) with OIDC-based CI, ABAC-scoped deployment
  identities and write-only secrets, running production-style for 30 days on €_X_ of cloud spend.
- Implemented SLO-based alerting (multi-window burn rates) on Prometheus with unit-tested rules;
  detected injected failures in _X_ minutes and documented 10 game-day incidents as postmortems.
- Rebuilt the whole platform from code in _X_ minutes (measured RTO) and designed quota-aware
  upgrade and node-failure procedures for capacity-constrained clusters.
