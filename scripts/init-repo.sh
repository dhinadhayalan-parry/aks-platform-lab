#!/usr/bin/env bash
# One-time: point runbook links and docs at YOUR fork.
# Usage: scripts/init-repo.sh <owner>/<repo>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

SLUG="${1:-}"
[[ "${SLUG}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "usage: $0 <owner>/<repo>"

ROOT="$(repo_root)"
mapfile -t files < <(grep -rl --exclude-dir=.git --exclude-dir=.terraform --exclude=init-repo.sh 'OWNER/aks-platform-lab' "${ROOT}" || true)
(( ${#files[@]} > 0 )) || { log INFO "nothing to replace (already initialised?)"; exit 0; }

for f in "${files[@]}"; do
  sed -i.bak "s#OWNER/aks-platform-lab#${SLUG}#g" "${f}" && rm -f "${f}.bak"
  log INFO "updated ${f#"${ROOT}"/}"
done
