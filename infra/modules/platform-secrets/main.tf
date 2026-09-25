terraform {
  required_version = ">= 1.11.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

variable "name_base" {
  type = string
}

variable "name_suffix" {
  description = "Random suffix: Key Vault names are global and soft-deleted names stay reserved."
  type        = string
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

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer; ESO's service account federates against it."
  type        = string
}

variable "eso_namespace" {
  type    = string
  default = "external-secrets"
}

variable "eso_service_account" {
  type    = string
  default = "external-secrets"
}

variable "purge_protection_enabled" {
  description = "Production default. With it on, a destroyed vault blocks its name for soft_delete_retention_days."
  type        = bool
  default     = true
}

variable "slack_webhook_url" {
  description = "Alertmanager Slack incoming webhook. Ephemeral: never stored in state or plan files."
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "secrets_version" {
  description = "Bump to rotate generated secrets NOW (write-only attributes only re-send on version change)."
  type        = number
  default     = 1

  validation {
    condition     = var.secrets_version >= 1 && var.secrets_version < 20 && floor(var.secrets_version) == var.secrets_version
    error_message = "secrets_version must be an integer 1-19."
  }
}

variable "secret_rotation_days" {
  description = "Scheduled rotation. Secrets expire 7 days after this, so an un-applied rotation fails loudly (ESO sync errors) instead of silently."
  type        = number
  default     = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy # the lab is destroyed and rebuilt on purpose (DR drill); purge protection + soft delete are the safety net
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_109:GitHub-hosted runners have no fixed egress IPs; RBAC-only data plane. Prod: Deny + private endpoint.
  #checkov:skip=CKV_AZURE_189:Same as above; public endpoint is RBAC-gated, no access policies, no shared keys.
  #checkov:skip=CKV2_AZURE_32:Private endpoint needs private DNS + self-hosted runners; out of scope for a EUR 100 lab.
  name                          = "kv-${var.name_base}-${var.name_suffix}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = var.purge_protection_enabled
  soft_delete_retention_days    = 7
  public_network_access_enabled = true

  # GitHub-hosted runners have no fixed egress IPs; access is RBAC-gated.
  # Production: default_action = "Deny" + private endpoint + self-hosted runners.
  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow"
  }

  tags = var.tags
}

# --- External Secrets Operator identity (workload identity, no secrets) -----
resource "azurerm_user_assigned_identity" "eso" {
  name                = "id-${var.name_base}-eso"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "eso" {
  name                      = "aks-${var.eso_namespace}-${var.eso_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.eso.id
  issuer                    = var.oidc_issuer_url
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "system:serviceaccount:${var.eso_namespace}:${var.eso_service_account}"
}

resource "azurerm_role_assignment" "eso_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Secrets: write-only, so values never land in state -----------------------
# Rotation: time_rotating is replaced every N days -> the version below changes
# -> Terraform re-sends a fresh ephemeral password. Manual rotation = bump
# var.secrets_version. The version encodes both: <manual><yyyymmdd>.
resource "time_rotating" "secrets" {
  rotation_days = var.secret_rotation_days
}

locals {
  secret_version    = var.secrets_version * 100000000 + tonumber(formatdate("YYYYMMDD", time_rotating.secrets.id))
  secret_expires_on = timeadd(time_rotating.secrets.rotation_rfc3339, "168h")
}
ephemeral "random_password" "grafana_admin" {
  length           = 32
  special          = true
  override_special = "-_.~"
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy # the lab is destroyed and rebuilt on purpose (DR drill); purge protection + soft delete are the safety net
resource "azurerm_key_vault_secret" "grafana_admin_password" {
  name             = "grafana-admin-password"
  key_vault_id     = azurerm_key_vault.this.id
  value_wo         = ephemeral.random_password.grafana_admin.result
  value_wo_version = local.secret_version
  content_type     = "text/plain"
  expiration_date  = local.secret_expires_on
  tags             = var.tags
}

# tflint-ignore: azurerm_resources_missing_prevent_destroy # the lab is destroyed and rebuilt on purpose (DR drill); purge protection + soft delete are the safety net
resource "azurerm_key_vault_secret" "alertmanager_slack_webhook" {
  name             = "alertmanager-slack-webhook-url"
  key_vault_id     = azurerm_key_vault.this.id
  value_wo         = var.slack_webhook_url
  value_wo_version = local.secret_version
  content_type     = "text/uri"
  expiration_date  = local.secret_expires_on
  tags             = var.tags
}

output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "eso_client_id" {
  value = azurerm_user_assigned_identity.eso.client_id
}

output "secret_version" {
  description = "Current write-only version: <manual><yyyymmdd of last scheduled rotation>."
  value       = local.secret_version
}

output "secret_expires_on" {
  value = local.secret_expires_on
}
