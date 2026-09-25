terraform {
  # Ephemeral resources + write-only attributes need Terraform >= 1.11 / OpenTofu >= 1.11.
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
  }

  # Chicken-and-egg: bootstrap creates the state account, so it starts on local
  # state. scripts/bootstrap.sh then writes backend_override.tf (azurerm backend)
  # and runs `init -migrate-state` so this stack ends up in remote state too.
  backend "local" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # Bootstrap is the only stack allowed to touch subscription-level settings,
  # so it registers exactly the resource providers the platform needs.
  resource_provider_registrations = "core"
  resource_providers_to_register = [
    "Microsoft.ContainerService",
    "Microsoft.KubernetesConfiguration",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.Consumption",
    "Microsoft.CostManagement",
  ]

  # Shared keys are disabled on the state account; data-plane calls use Entra ID.
  storage_use_azuread = true

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}
