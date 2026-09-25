data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "workload" {
  name = var.workload_resource_group_name
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name_base = "${var.prefix}-${var.environment}"
  location  = data.azurerm_resource_group.workload.location
  tags = merge({
    environment = var.environment
    managed_by  = "terraform"
    stack       = "live-lab"
    cost_center = "portfolio-lab"
  }, var.tags)
}

module "network" {
  source = "../../modules/network"

  name_base           = local.name_base
  location            = local.location
  resource_group_name = data.azurerm_resource_group.workload.name
  tags                = local.tags
}

module "aks" {
  source = "../../modules/aks"

  name_base                       = local.name_base
  location                        = local.location
  resource_group_name             = data.azurerm_resource_group.workload.name
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  node_subnet_id                  = module.network.node_subnet_id
  kubernetes_version              = var.kubernetes_version
  sku_tier                        = var.sku_tier
  system_vm_size                  = var.system_vm_size
  apps_vm_size                    = var.apps_vm_size
  apps_node_count                 = var.apps_node_count
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges
  tags                            = local.tags
}

module "secrets" {
  source = "../../modules/platform-secrets"

  name_base           = local.name_base
  name_suffix         = random_string.suffix.result
  location            = local.location
  resource_group_name = data.azurerm_resource_group.workload.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  oidc_issuer_url     = module.aks.oidc_issuer_url
  slack_webhook_url   = var.slack_webhook_url
  secrets_version     = var.secrets_version
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# GitOps hand-off. Terraform owns Azure + the Flux wiring; everything inside
# the cluster is owned by Git. No helm/kubernetes providers in this stack.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "flux"
  cluster_id     = module.aks.cluster_id
  extension_type = "microsoft.flux"
  release_train  = "Stable"

  configuration_settings = {
    # Single-team platform cluster: HelmReleases reference sources in their own
    # namespace, but we don't want per-tenant service-account impersonation.
    "multiTenancy.enforce"                = "false"
    "image-automation-controller.enabled" = "false"
    "image-reflector-controller.enabled"  = "false"
  }
}

locals {
  # Values Terraform knows and Git must not hard-code. Injected via Flux
  # postBuild substitution into the two layers that need them ONLY: the
  # monitoring/apps layers contain PromQL/Grafana "$vars" that envsubst would eat.
  gitops_substitutions = {
    AZURE_TENANT_ID = data.azurerm_client_config.current.tenant_id
    KEY_VAULT_URL   = module.secrets.key_vault_uri
    ESO_CLIENT_ID   = module.secrets.eso_client_id
    CLUSTER_NAME    = module.aks.cluster_name
  }

  gitops_layers = [
    { name = "infra-controllers", path = "./gitops/infrastructure/controllers", depends_on = [], substitute = true },
    { name = "infra-configs", path = "./gitops/infrastructure/configs", depends_on = ["infra-controllers"], substitute = true },
    { name = "monitoring", path = "./gitops/monitoring", depends_on = ["infra-configs"], substitute = false },
    { name = "apps", path = "./gitops/apps", depends_on = ["monitoring"], substitute = false },
  ]
}

resource "azurerm_kubernetes_flux_configuration" "platform" {
  name       = "platform"
  cluster_id = module.aks.cluster_id
  namespace  = "flux-system"
  scope      = "cluster"

  git_repository {
    url                      = var.gitops_repo_url
    reference_type           = "branch"
    reference_value          = var.gitops_branch
    sync_interval_in_seconds = 120
    timeout_in_seconds       = 600
  }

  dynamic "kustomizations" {
    for_each = local.gitops_layers
    content {
      name                       = kustomizations.value.name
      path                       = kustomizations.value.path
      depends_on                 = kustomizations.value.depends_on
      garbage_collection_enabled = true
      wait                       = true
      timeout_in_seconds         = 900
      sync_interval_in_seconds   = 600
      retry_interval_in_seconds  = 60

      dynamic "post_build" {
        for_each = kustomizations.value.substitute ? [1] : []
        content {
          substitute = local.gitops_substitutions
        }
      }
    }
  }

  depends_on = [
    azurerm_kubernetes_cluster_extension.flux,
    # ESO must be able to read Key Vault before Grafana waits on its secret.
    module.secrets,
  ]
}
