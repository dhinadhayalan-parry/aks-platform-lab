variable "subscription_id" {
  type = string
}

variable "workload_resource_group_name" {
  description = "RG created by bootstrap (output workload_resource_group_name)."
  type        = string
}

variable "prefix" {
  type    = string
  default = "plat"
}

variable "environment" {
  type    = string
  default = "lab"
}

variable "kubernetes_version" {
  description = "null = AKS default. Pin a minor (\"1.34\") before the upgrade drill."
  type        = string
  default     = null

  validation {
    condition     = var.kubernetes_version == null || can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "Pin a minor version only (\"1.34\"); patches are rolled by the auto-upgrade channel."
  }
}

variable "sku_tier" {
  type    = string
  default = "Free"

  validation {
    condition     = contains(["Free", "Standard"], var.sku_tier)
    error_message = "sku_tier must be Free or Standard."
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
  type    = number
  default = 1

  validation {
    condition     = var.apps_node_count >= 0 && var.apps_node_count <= 3
    error_message = "apps_node_count must be 0-3 (free-trial vCPU quota)."
  }
}

variable "api_server_authorized_ip_ranges" {
  description = "Your public IP as /32 (curl -s https://ifconfig.me)."
  type        = list(string)

  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0 && alltrue([for c in var.api_server_authorized_ip_ranges : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Provide at least one CIDR; 0.0.0.0/0 is rejected."
  }
}

variable "gitops_repo_url" {
  description = "HTTPS URL of THIS repository (public). Flux pulls gitops/ from it."
  type        = string

  validation {
    condition     = can(regex("^https://github\\.com/[^/]+/[^/]+$", var.gitops_repo_url))
    error_message = "Use https://github.com/<owner>/<repo> (no .git suffix, no trailing slash)."
  }
}

variable "gitops_branch" {
  type    = string
  default = "main"
}

variable "slack_webhook_url" {
  description = "Slack incoming-webhook URL for Alertmanager. Pass via TF_VAR_slack_webhook_url; never committed, never in state."
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = can(regex("^https://hooks\\.slack\\.com/services/", var.slack_webhook_url))
    error_message = "Expected a Slack incoming webhook (https://hooks.slack.com/services/...)."
  }
}

variable "secrets_version" {
  description = "Bump to rotate the Grafana admin password and re-send the Slack webhook."
  type        = number
  default     = 1
}

variable "tags" {
  type    = map(string)
  default = {}
}
