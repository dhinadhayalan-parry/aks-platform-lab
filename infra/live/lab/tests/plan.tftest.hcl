# Offline tests: mocked providers, no Azure credentials needed.
#   terraform -chdir=infra/live/lab init -backend=false && terraform -chdir=infra/live/lab test

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      object_id       = "33333333-3333-3333-3333-333333333333"
      subscription_id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_data "azurerm_resource_group" {
    defaults = {
      id       = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-plat-lab-platform"
      location = "swedencentral"
    }
  }

  mock_resource "azurerm_network_security_group" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-plat-lab-platform/providers/Microsoft.Network/networkSecurityGroups/nsg-plat-lab-nodes"
    }
  }

  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-plat-lab-platform/providers/Microsoft.Network/virtualNetworks/vnet-plat-lab"
    }
  }

  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-plat-lab-platform/providers/Microsoft.Network/virtualNetworks/vnet-plat-lab/subnets/snet-plat-lab-nodes"
    }
  }

  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id              = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-plat-lab-platform/providers/Microsoft.ContainerService/managedClusters/aks-plat-lab"
      oidc_issuer_url = "https://swedencentral.oic.prod-aks.azure.com/22222222-2222-2222-2222-222222222222/44444444-4444-4444-4444-444444444444/"
    }
  }

  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-plat-lab-platform/providers/Microsoft.KeyVault/vaults/kv-plat-lab-abcde"
      vault_uri = "https://kv-plat-lab-abcde.vault.azure.net/"
    }
  }

  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-plat-lab-platform/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
      client_id    = "55555555-5555-5555-5555-555555555555"
      principal_id = "66666666-6666-6666-6666-666666666666"
    }
  }
}

# random is NOT mocked: it is local-only, and mocks do not support ephemeral resources yet.

mock_provider "time" {
  mock_resource "time_rotating" {
    defaults = {
      id               = "2026-09-25T10:00:00Z"
      rotation_rfc3339 = "2026-12-24T10:00:00Z"
    }
  }
}

variables {
  subscription_id                 = "11111111-1111-1111-1111-111111111111"
  workload_resource_group_name    = "rg-plat-lab-platform"
  api_server_authorized_ip_ranges = ["203.0.113.10/32"]
  gitops_repo_url                 = "https://github.com/example/aks-platform-lab"
  slack_webhook_url               = "https://hooks.slack.com/services/T000/B000/XXXX"
}

run "defaults_fit_the_trial" {
  command = apply

  assert {
    condition     = module.aks.cluster_name == "aks-plat-lab"
    error_message = "cluster name drifted from what scripts/cluster.sh and the workflows expect"
  }

  assert {
    condition     = length(azurerm_kubernetes_flux_configuration.platform.kustomizations) == 4
    error_message = "expected 4 ordered GitOps layers"
  }

  assert {
    condition = alltrue([
      for k in azurerm_kubernetes_flux_configuration.platform.kustomizations :
      length(k.post_build) == (contains(["infra-controllers", "infra-configs"], k.name) ? 1 : 0)
    ])
    error_message = "postBuild substitution must be enabled ONLY on the infra layers ($ in PromQL/Grafana)"
  }

  assert {
    condition     = output.key_vault_uri == "https://kv-plat-lab-abcde.vault.azure.net/"
    error_message = "Key Vault URI not wired to outputs"
  }
}

run "secret_version_encodes_manual_and_scheduled_rotation" {
  command = apply

  variables {
    secrets_version = 3
  }

  assert {
    condition     = module.secrets.secret_version == 320260925
    error_message = "version must be <manual=3><rotation date 20260925> so either kind of rotation re-sends the write-only value"
  }

  assert {
    condition     = module.secrets.secret_expires_on == "2026-12-31T10:00:00Z"
    error_message = "secrets must expire 7 days after the scheduled rotation date"
  }
}

run "rejects_open_api_server" {
  command = plan

  variables {
    api_server_authorized_ip_ranges = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_server_authorized_ip_ranges]
}

run "rejects_patch_version_pin" {
  command = plan

  variables {
    kubernetes_version = "1.34.2"
  }

  expect_failures = [var.kubernetes_version]
}

run "rejects_too_many_nodes_for_quota" {
  command = plan

  variables {
    apps_node_count = 4
  }

  expect_failures = [var.apps_node_count]
}

run "rejects_non_slack_webhook" {
  command = plan

  variables {
    slack_webhook_url = "https://example.com/hook"
  }

  expect_failures = [var.slack_webhook_url]
}
