terraform {
  required_version = ">= 1.11.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
  }
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
variable "name_base" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "node_subnet_id" {
  type = string
}

variable "kubernetes_version" {
  description = "Minor (e.g. \"1.34\") or null for the AKS default. Patch versions are handled by the auto-upgrade channel."
  type        = string
  default     = null

  validation {
    condition     = var.kubernetes_version == null || can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "Pin a minor version only (\"1.34\"); patches are rolled by automatic_upgrade_channel = patch."
  }
}

variable "sku_tier" {
  description = "Free (no SLA, EUR 0) or Standard (99.9/99.95% API SLA, ~EUR 0.09/h). Flip to Standard only for the soak week."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "sku_tier must be Free or Standard (Premium/LTS is not worth trial credit)."
  }
}

variable "system_vm_size" {
  type    = string
  default = "Standard_D2ads_v5"
}

variable "apps_vm_size" {
  type    = string
  default = "Standard_D2ads_v5"
}

variable "apps_node_count" {
  description = "User pool size. Set to 0 temporarily to free vCPU quota for a system-pool surge upgrade (see docs/30-day-plan.md, drill 5)."
  type        = number
  default     = 1

  validation {
    condition     = var.apps_node_count >= 0 && var.apps_node_count <= 3
    error_message = "apps_node_count must be 0-3 (free-trial vCPU quota)."
  }
}

variable "os_disk_size_gb" {
  description = "Ephemeral OS disk size; must fit the VM's local temp disk (75 GiB on D2ads_v5)."
  type        = number
  default     = 64
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the public API server (your home IP /32). Flux runs in-cluster and CI talks to ARM only, so nothing else needs it."
  type        = list(string)

  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0 && alltrue([for c in var.api_server_authorized_ip_ranges : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Provide at least one CIDR; 0.0.0.0/0 is rejected."
  }
}

variable "maintenance_utc_offset" {
  type    = string
  default = "+02:00"
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------------------
# Identity: user-assigned so the subnet role exists BEFORE the cluster does.
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "id-${var.name_base}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_role_assignment" "subnet_network_contributor" {
  scope                = var.node_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  # principal_type is mandatory here: the CI identity's ABAC condition evaluates it.
  principal_type = "ServicePrincipal"
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_4:Container Insights ingestion is ~EUR 2.5/GB; in-cluster Prometheus/Grafana is the observability stack.
  #checkov:skip=CKV_AZURE_115:Private cluster needs a jump host or VPN (extra VM or gateway cost). Mitigated: authorized IP ranges + Entra-only auth.
  #checkov:skip=CKV_AZURE_116:Azure Policy add-on costs ~400 MiB RAM on a 2-node cluster; policy runs in CI (checkov/kubeconform) instead.
  #checkov:skip=CKV_AZURE_117:Platform-managed keys + encryption at host. A CMK disk encryption set adds Key Vault key ops and a hard dependency.
  #checkov:skip=CKV_AZURE_170:SLA tier is a variable: Free for build weeks, Standard during the soak week (docs/30-day-plan.md).
  #checkov:skip=CKV_AZURE_172:Secrets Store CSI driver is not used; External Secrets Operator syncs Key Vault (refreshInterval 1h).
  #checkov:skip=CKV_AZURE_6:authorized_ip_ranges is set from a validated variable that rejects 0.0.0.0/0; checkov cannot resolve module inputs.
  name                = "aks-${var.name_base}"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "aks-${var.name_base}"
  node_resource_group = "rg-${var.name_base}-aks-nodes"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier

  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  local_account_disabled            = true
  role_based_access_control_enabled = true
  run_command_enabled               = false
  azure_policy_enabled              = false # Gatekeeper costs ~400 MiB RAM; policy-as-code lives in CI instead.
  image_cleaner_enabled             = true
  image_cleaner_interval_hours      = 48

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_vm_size
    orchestrator_version         = var.kubernetes_version
    node_count                   = 1
    auto_scaling_enabled         = false
    only_critical_addons_enabled = true # taints CriticalAddonsOnly: platform add-ons only
    os_sku                       = "AzureLinux"
    os_disk_type                 = "Ephemeral"
    os_disk_size_gb              = var.os_disk_size_gb
    host_encryption_enabled      = true # encrypts temp disk, caches and the ephemeral OS disk; free
    max_pods                     = 110
    vnet_subnet_id               = var.node_subnet_id
    temporary_name_for_rotation  = "systemtmp"
    tags                         = var.tags

    # System pools cannot use maxUnavailable, so a system upgrade needs +1 node
    # of quota. That constraint is the point of drill 5.
    upgrade_settings {
      max_surge                     = "1"
      drain_timeout_in_minutes      = 15
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  azure_active_directory_role_based_access_control {
    tenant_id          = var.tenant_id
    azure_rbac_enabled = true
  }

  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"

    load_balancer_profile {
      managed_outbound_ip_count = 1
      idle_timeout_in_minutes   = 4
    }
  }

  # "Auto" = Node Auto-Provisioning (Karpenter). It would ignore our fixed quota
  # math and cannot run with a 4-vCPU cap, so node pools stay explicit here.
  node_provisioning_profile {
    mode = "Manual"
  }

  storage_profile {
    disk_driver_enabled         = true
    file_driver_enabled         = false
    blob_driver_enabled         = false
    snapshot_controller_enabled = true
  }

  # Windows are in daytime on purpose: a cluster stopped overnight never gets
  # patched in a 02:00 window. (Interview talking point.)
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = "Saturday"
    start_time  = "10:00"
    utc_offset  = var.maintenance_utc_offset
    duration    = 4
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    day_of_week = "Sunday"
    start_time  = "10:00"
    utc_offset  = var.maintenance_utc_offset
    duration    = 4
  }

  tags = var.tags

  depends_on = [azurerm_role_assignment.subnet_network_contributor]
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                        = "apps"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.this.id
  mode                        = "User"
  vm_size                     = var.apps_vm_size
  node_count                  = var.apps_node_count
  auto_scaling_enabled        = false
  os_type                     = "Linux"
  os_sku                      = "AzureLinux"
  os_disk_type                = "Ephemeral"
  os_disk_size_gb             = var.os_disk_size_gb
  host_encryption_enabled     = true
  max_pods                    = 110
  vnet_subnet_id              = var.node_subnet_id
  orchestrator_version        = var.kubernetes_version
  temporary_name_for_rotation = "appstmp"
  node_labels = {
    "platform.lab/pool" = "apps"
  }
  tags = var.tags

  # In-place rolling upgrade: no surge node, so it fits inside the trial quota.
  # Cost: one node's worth of capacity is missing during the upgrade.
  # (azurerm treats max_surge and max_unavailable as mutually exclusive; setting
  # only max_unavailable sends maxSurge=0 to the API.)
  upgrade_settings {
    max_unavailable               = "1"
    drain_timeout_in_minutes      = 15
    node_soak_duration_in_minutes = 0
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "cluster_id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}
