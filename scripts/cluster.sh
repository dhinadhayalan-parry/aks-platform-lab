#!/usr/bin/env bash
# Day-to-day cluster power and access. Stopping a cluster keeps its config,
# PVs and Flux state; you pay only for disks and state storage while stopped.
#
# Usage: scripts/cluster.sh {up|down|status|creds|grafana}
# Env:   AKS_RG (default rg-plat-lab-platform), AKS_NAME (default aks-plat-lab)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

ACTION="${1:-status}"
RG="${AKS_RG:-rg-plat-lab-platform}"
NAME="${AKS_NAME:-aks-plat-lab}"

require az jq
require_az_login

power_state() {
  az aks show -g "${RG}" -n "${NAME}" --query powerState.code -o tsv
}

case "${ACTION}" in
  up)
    state="$(power_state)"
    if [[ "${state}" == "Running" ]]; then
      log INFO "${NAME} already running"
    else
      log INFO "starting ${NAME} (~5 min); billing for nodes resumes now"
      az aks start -g "${RG}" -n "${NAME}" --only-show-errors
    fi
    ;;
  down)
    state="$(power_state)"
    if [[ "${state}" == "Stopped" ]]; then
      log INFO "${NAME} already stopped"
    else
      log INFO "stopping ${NAME}"
      az aks stop -g "${RG}" -n "${NAME}" --only-show-errors
    fi
    ;;
  status)
    az aks show -g "${RG}" -n "${NAME}" -o json \
      | jq '{name, powerState: .powerState.code, provisioningState, kubernetesVersion, sku: .sku.tier,
             pools: [.agentPoolProfiles[] | {name, mode, count, vmSize, orchestratorVersion, powerState: .powerState.code}]}'
    ;;
  creds)
    require kubelogin kubectl
    az aks get-credentials -g "${RG}" -n "${NAME}" --overwrite-existing --only-show-errors
    kubelogin convert-kubeconfig -l azurecli
    kubectl get nodes -o wide
    ;;
  grafana)
    require kubectl
    kv="$(az keyvault list -g "${RG}" --query '[0].name' -o tsv)"
    [[ -n "${kv}" ]] || die "no Key Vault found in ${RG}"
    log INFO "user: admin | password: az keyvault secret show --vault-name ${kv} -n grafana-admin-password --query value -o tsv"
    log INFO "open http://localhost:3000 (Ctrl-C to stop)"
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
    ;;
  *)
    die "usage: $0 {up|down|status|creds|grafana}"
    ;;
esac
