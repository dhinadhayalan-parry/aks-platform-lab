#!/usr/bin/env bash
# Shared helpers. Source, don't execute.
set -euo pipefail

log() {
  local level="$1"; shift
  printf '%s [%-5s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${level}" "$*" >&2
}

die() {
  log ERROR "$*"
  exit 1
}

require() {
  local bin
  for bin in "$@"; do
    command -v "${bin}" >/dev/null 2>&1 || die "missing dependency: ${bin}"
  done
}

require_az_login() {
  az account show --only-show-errors -o none 2>/dev/null || die "not logged in: run 'az login' first"
}

repo_root() {
  git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null \
    || (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
}

# Terraform or OpenTofu, caller's choice: TF_BIN=tofu scripts/bootstrap.sh
tf_bin() {
  local bin="${TF_BIN:-terraform}"
  require "${bin}"
  printf '%s' "${bin}"
}
