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

  # Partial config: resource_group_name / storage_account_name / container_name
  # come from backend.hcl locally or -backend-config flags in CI.
  backend "azurerm" {
    key              = "lab/platform.tfstate"
    use_azuread_auth = true
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # Registration happened once in bootstrap; the CI identity has no
  # subscription-scope rights and must not try.
  resource_provider_registrations = "none"
  storage_use_azuread             = true

  features {
    key_vault {
      # Purge protection makes purge impossible anyway; never try on destroy.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
      recover_soft_deleted_secrets    = true
    }

    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}
