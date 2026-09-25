data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name_base = "${var.prefix}-${var.environment}"
  tags = merge({
    environment = var.environment
    managed_by  = "terraform"
    stack       = "bootstrap"
    repository  = var.github_repository
  }, var.tags)

  admin_object_ids = length(var.admin_object_ids) > 0 ? var.admin_object_ids : [data.azurerm_client_config.current.object_id]

  # Built-in role definition IDs (identical in every tenant).
  role_ids = {
    key_vault_secrets_user = "4633458b-17de-408a-b874-0445c86b69e6"
    network_contributor    = "4d97b98b-1d4f-4787-a291-c67834d212e7"
  }

  # The apply identity may only hand out these two roles, only to service
  # principals (managed identities). It cannot escalate itself to Owner.
  delegable_roles      = join(", ", values(local.role_ids))
  rbac_admin_condition = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.delegable_roles}}
      AND
      @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.delegable_roles}}
      AND
      @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
     )
    )
  EOT

  github_oidc_issuer   = "https://token.actions.githubusercontent.com"
  github_oidc_audience = "api://AzureADTokenExchange"
}

# ---------------------------------------------------------------------------
# Management RG: state + CI identities. Locked against accidental deletion.
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "mgmt" {
  name     = "rg-${local.name_base}-mgmt"
  location = var.location
  tags     = local.tags
}

resource "azurerm_management_lock" "mgmt" {
  name       = "do-not-delete-state"
  scope      = azurerm_resource_group.mgmt.id
  lock_level = "CanNotDelete"
  notes      = "Holds Terraform state and CI identities. Remove deliberately during final teardown."
}

resource "azurerm_storage_account" "state" {
  #checkov:skip=CKV_AZURE_59:GitHub-hosted runners need the public endpoint; shared keys are disabled so access is Entra RBAC only.
  #checkov:skip=CKV2_AZURE_33:Private endpoint requires self-hosted runners; out of scope for the lab.
  #checkov:skip=CKV_AZURE_206:LRS + blob versioning + 14-day soft delete is sufficient for lab state; GRS doubles cost.
  #checkov:skip=CKV_AZURE_33:No queues are used in this account.
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys with infrastructure (double) encryption; CMK adds a Key Vault dependency to state.
  name                              = "st${var.prefix}tf${random_string.suffix.result}"
  resource_group_name               = azurerm_resource_group.mgmt.name
  location                          = azurerm_resource_group.mgmt.location
  account_kind                      = "StorageV2"
  account_tier                      = "Standard"
  account_replication_type          = "LRS" # ZRS/GRS doubles cost; state is also versioned. Accepted for a lab.
  access_tier                       = "Hot"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false # Entra ID only; no account keys to leak.
  default_to_oauth_authentication   = true
  allow_nested_items_to_be_public   = false
  infrastructure_encryption_enabled = true
  cross_tenant_replication_enabled  = false
  local_user_enabled                = false
  sftp_enabled                      = false
  # GitHub-hosted runners have no stable egress IPs, so the endpoint stays public
  # and access is enforced by RBAC. Production: private endpoint + self-hosted runners.
  public_network_access = "Enabled"

  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = false

    delete_retention_policy {
      days = 14
    }

    container_delete_retention_policy {
      days = 14
    }
  }

  tags = local.tags

  lifecycle {
    prevent_destroy = true # losing state = losing ownership of every resource
  }
}

resource "azurerm_storage_container" "state" {
  #checkov:skip=CKV2_AZURE_21:Blob diagnostic logs need a Log Analytics workspace (ingestion cost). State access is auditable via Entra sign-in logs.
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Workload RG: everything the lab stack creates lives here.
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "workload" {
  name     = "rg-${local.name_base}-platform"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# GitHub Actions identities (OIDC, no client secrets).
#   plan  -> pull_request subject, read-only on workload
#   apply -> environment:<env> subject, gated by GitHub Environment reviewers
#   ops   -> default-branch subject, may only start/stop the cluster
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "github" {
  for_each = toset(["plan", "apply", "ops"])

  name                = "id-${local.name_base}-gh-${each.key}"
  resource_group_name = azurerm_resource_group.mgmt.name
  location            = azurerm_resource_group.mgmt.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "github" {
  for_each = {
    plan-pr      = { identity = "plan", subject = "repo:${var.github_repository}:pull_request" }
    plan-drift   = { identity = "plan", subject = "repo:${var.github_repository}:ref:refs/heads/${var.github_default_branch}" }
    apply-env    = { identity = "apply", subject = "repo:${var.github_repository}:environment:${var.environment}" }
    ops-schedule = { identity = "ops", subject = "repo:${var.github_repository}:ref:refs/heads/${var.github_default_branch}" }
  }

  name                      = "github-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.github[each.value.identity].id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = each.value.subject
}

# --- plan: read everything it must refresh, write nothing but the state lock.
resource "azurerm_role_assignment" "plan" {
  for_each = {
    reader           = "Reader"
    aks_cluster_user = "Azure Kubernetes Service Cluster User Role" # azurerm reads kubeconfig during refresh
    kv_secrets_user  = "Key Vault Secrets User"                     # refresh of azurerm_key_vault_secret metadata
  }

  scope                = azurerm_resource_group.workload.id
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.github["plan"].principal_id
  principal_type       = "ServicePrincipal"
}

# --- apply: contributor on the workload RG + constrained RBAC delegation.
resource "azurerm_role_assignment" "apply_contributor" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.github["apply"].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "apply_rbac_admin" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.github["apply"].principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = local.rbac_admin_condition
  description          = "May only assign Key Vault Secrets User / Network Contributor to service principals."
}

resource "azurerm_role_assignment" "apply_kv_officer" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.github["apply"].principal_id
  principal_type       = "ServicePrincipal"
}

# --- state access (plan needs write too: acquiring the blob lease IS the lock).
resource "azurerm_role_assignment" "state" {
  for_each = {
    plan  = azurerm_user_assigned_identity.github["plan"].principal_id
    apply = azurerm_user_assigned_identity.github["apply"].principal_id
  }

  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
  principal_type       = "ServicePrincipal"
}

# --- ops: custom least-privilege role, start/stop only.
resource "azurerm_role_definition" "aks_power_operator" {
  name        = "${local.name_base} AKS Power Operator"
  scope       = azurerm_resource_group.workload.id
  description = "Read, start and stop AKS clusters. Used by the nightly cost guardrail."

  permissions {
    actions = [
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/start/action",
      "Microsoft.ContainerService/managedClusters/stop/action",
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.workload.id]
}

resource "azurerm_role_assignment" "ops" {
  scope              = azurerm_resource_group.workload.id
  role_definition_id = azurerm_role_definition.aks_power_operator.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.github["ops"].principal_id
  principal_type     = "ServicePrincipal"
}

# --- humans: data-plane roles Owner does not imply.
resource "azurerm_role_assignment" "admin" {
  for_each = {
    for pair in setproduct(local.admin_object_ids, [
      "Azure Kubernetes Service RBAC Cluster Admin",
      "Azure Kubernetes Service Cluster User Role",
      "Key Vault Secrets Officer",
    ]) : "${pair[0]}|${pair[1]}" => { principal = pair[0], role = pair[1] }
  }

  scope                = azurerm_resource_group.workload.id
  role_definition_name = each.value.role
  principal_id         = each.value.principal
}

resource "azurerm_role_assignment" "admin_state" {
  for_each = toset(local.admin_object_ids)

  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

# ---------------------------------------------------------------------------
# Cost guardrail: budget alerts well before the trial credit runs out.
# ---------------------------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "lab" {
  name            = "budget-${local.name_base}"
  subscription_id = data.azurerm_subscription.current.id
  amount          = var.monthly_budget
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp())
  }

  dynamic "notification" {
    for_each = {
      actual_25  = { threshold = 25, type = "Actual" }
      actual_50  = { threshold = 50, type = "Actual" }
      actual_80  = { threshold = 80, type = "Actual" }
      forecast90 = { threshold = 90, type = "Forecasted" }
    }

    content {
      enabled        = true
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      operator       = "GreaterThanOrEqualTo"
      contact_emails = var.budget_contact_emails
      contact_roles  = ["Owner"]
    }
  }

  lifecycle {
    # start_date is derived from plan time; freeze it after creation.
    ignore_changes = [time_period]
  }
}
