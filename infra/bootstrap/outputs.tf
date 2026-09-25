output "backend_config" {
  description = "Values for infra/live/lab/backend.hcl and the bootstrap state migration."
  value = {
    resource_group_name  = azurerm_resource_group.mgmt.name
    storage_account_name = azurerm_storage_account.state.name
    container_name       = azurerm_storage_container.state.name
  }
}

output "workload_resource_group_name" {
  value = azurerm_resource_group.workload.name
}

output "github_variables" {
  description = "Set these as GitHub repository variables (Settings > Secrets and variables > Actions > Variables). None of them are secrets."
  value = {
    AZURE_TENANT_ID         = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID   = var.subscription_id
    AZURE_PLAN_CLIENT_ID    = azurerm_user_assigned_identity.github["plan"].client_id
    AZURE_APPLY_CLIENT_ID   = azurerm_user_assigned_identity.github["apply"].client_id
    AZURE_OPS_CLIENT_ID     = azurerm_user_assigned_identity.github["ops"].client_id
    TFSTATE_RESOURCE_GROUP  = azurerm_resource_group.mgmt.name
    TFSTATE_STORAGE_ACCOUNT = azurerm_storage_account.state.name
    WORKLOAD_RESOURCE_GROUP = azurerm_resource_group.workload.name
  }
}
