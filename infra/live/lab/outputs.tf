output "cluster_name" {
  value = module.aks.cluster_name
}

output "resource_group_name" {
  value = data.azurerm_resource_group.workload.name
}

output "node_resource_group" {
  value = module.aks.node_resource_group
}

output "key_vault_uri" {
  value = module.secrets.key_vault_uri
}

output "oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "kubeconfig_command" {
  description = "Entra-authenticated kubeconfig (local accounts are disabled)."
  value       = "az aks get-credentials -g ${data.azurerm_resource_group.workload.name} -n ${module.aks.cluster_name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}
