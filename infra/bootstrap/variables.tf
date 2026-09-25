variable "subscription_id" {
  description = "Target subscription (the free-trial subscription)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "location" {
  description = "Azure region for every resource in the lab. Run scripts/preflight.sh first: the free trial caps regional vCPUs."
  type        = string
  default     = "swedencentral"
}

variable "prefix" {
  description = "Short naming prefix (lowercase letters/digits, 2-8 chars)."
  type        = string
  default     = "plat"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.prefix))
    error_message = "prefix must be 2-8 lowercase alphanumerics."
  }
}

variable "environment" {
  description = "Environment name; also the GitHub Environment used for gated applies."
  type        = string
  default     = "lab"
}

variable "github_repository" {
  description = "GitHub repository in owner/name form that is allowed to federate into Azure."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/repo."
  }
}

variable "github_default_branch" {
  description = "Branch whose scheduled workflows (cost guardrail) may use the ops identity."
  type        = string
  default     = "main"
}

variable "admin_object_ids" {
  description = "Entra object IDs (users or groups) that operate the lab: kubectl admin, Key Vault secrets, state access. Defaults to the identity running bootstrap."
  type        = list(string)
  default     = []
}

variable "monthly_budget" {
  description = "Budget in the billing currency (EUR for a German sign-up). Set to the PLANNED spend (not the credit) so alerts fire while there is still slack."
  type        = number
  default     = 60

  validation {
    condition     = var.monthly_budget > 0 && var.monthly_budget <= 1000
    error_message = "monthly_budget must be between 1 and 1000."
  }
}

variable "budget_contact_emails" {
  description = "Addresses that receive budget alerts."
  type        = list(string)

  validation {
    condition     = length(var.budget_contact_emails) > 0 && alltrue([for e in var.budget_contact_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Provide at least one valid e-mail address."
  }
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}
