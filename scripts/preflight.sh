#!/usr/bin/env bash
# Check that the free-trial subscription can actually run this lab BEFORE
# spending anything: SKU availability, vCPU quota (regional + family), ephemeral
# OS disk support, and resource-provider registration.
#
# Usage: scripts/preflight.sh [region] [vm_size] [node_count]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REGION="${1:-swedencentral}"
SKU="${2:-Standard_D2ads_v5}"
NODES="${3:-2}"

[[ "${REGION}" =~ ^[a-z0-9]+$ ]] || die "region must be a short Azure region name, got '${REGION}'"
[[ "${SKU}" =~ ^Standard_[A-Za-z0-9_]+$ ]] || die "vm_size must look like Standard_D2ads_v5, got '${SKU}'"
[[ "${NODES}" =~ ^[1-9]$ ]] || die "node_count must be 1-9, got '${NODES}'"

require az jq
require_az_login

sub_json="$(az account show -o json)"
log INFO "subscription: $(jq -r '.name + " (" + .id + ")"' <<<"${sub_json}")"

log INFO "looking up ${SKU} in ${REGION}"
sku_json="$(az vm list-skus -l "${REGION}" --size "${SKU}" --resource-type virtualMachines -o json \
  | jq --arg s "${SKU}" '[.[] | select(.name == $s)][0]')"
[[ "${sku_json}" != "null" ]] || die "${SKU} is not offered in ${REGION}"

restricted="$(jq -r '[.restrictions[]? | select(.reasonCode == "NotAvailableForSubscription")] | length' <<<"${sku_json}")"
[[ "${restricted}" == "0" ]] || die "${SKU} is restricted for this subscription in ${REGION}; try another region or size"

family="$(jq -r '.family' <<<"${sku_json}")"
vcpus="$(jq -r '.capabilities[] | select(.name == "vCPUs") | .value' <<<"${sku_json}")"
ephemeral="$(jq -r '(.capabilities[] | select(.name == "EphemeralOSDiskSupported") | .value) // "False"' <<<"${sku_json}")"
temp_mb="$(jq -r '(.capabilities[] | select(.name == "MaxResourceVolumeMB") | .value) // "0"' <<<"${sku_json}")"

usage_json="$(az vm list-usage -l "${REGION}" -o json)"
read -r reg_used reg_limit < <(jq -r '.[] | select(.name.value == "cores") | "\(.currentValue) \(.limit)"' <<<"${usage_json}")
read -r fam_used fam_limit < <(jq -r --arg f "${family}" '.[] | select(.name.value == $f) | "\(.currentValue) \(.limit)"' <<<"${usage_json}")

need=$(( NODES * vcpus ))
need_upgrade=$(( need + vcpus ))
reg_free=$(( reg_limit - reg_used ))
fam_free=$(( fam_limit - fam_used ))
free=$(( reg_free < fam_free ? reg_free : fam_free ))

cat <<EOF

  SKU                      ${SKU} (${vcpus} vCPU, family ${family})
  Ephemeral OS disk        ${ephemeral} (local temp disk $(( temp_mb / 1024 )) GiB)
  Regional vCPUs           ${reg_used}/${reg_limit} used
  Family vCPUs             ${fam_used}/${fam_limit} used
  Needed steady state      ${need} vCPU (${NODES} nodes)
  Needed for surge upgrade ${need_upgrade} vCPU (system pool cannot use maxUnavailable)

EOF

[[ "${ephemeral}" == "True" ]] || log WARN "${SKU} has no ephemeral OS disk support: set os_disk_type = Managed in modules/aks"
(( temp_mb / 1024 >= 64 )) || log WARN "temp disk < 64 GiB: lower os_disk_size_gb in modules/aks"

rc=0
if (( need > free )); then
  log ERROR "not enough quota: need ${need}, free ${free}. Free trials cannot request increases."
  rc=1
elif (( need_upgrade > free )); then
  log WARN "steady state fits, but a system-pool surge upgrade will hit QuotaExceeded. That is drill 5 in docs/30-day-plan.md."
else
  log INFO "quota OK, including surge headroom"
fi

log INFO "resource providers"
for ns in Microsoft.ContainerService Microsoft.KubernetesConfiguration Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Network Microsoft.Compute Microsoft.Storage; do
  state="$(az provider show -n "${ns}" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
  printf '  %-36s %s\n' "${ns}" "${state}"
  [[ "${state}" == "Registered" ]] || log WARN "${ns} not registered yet; bootstrap registers it"
done

exit "${rc}"
