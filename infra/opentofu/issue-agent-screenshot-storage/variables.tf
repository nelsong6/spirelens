variable "location" {
  description = "Azure region for screenshot evidence resources."
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group to create for issue-agent screenshot evidence storage."
  type        = string
  default     = "rg-spirelens-issue-agent-evidence"
}

variable "name_prefix" {
  description = "Lowercase prefix used for globally unique Azure resource names. Keep short; storage account names max at 24 chars."
  type        = string
  default     = "spirelensshots"

  validation {
    condition     = can(regex("^[a-z0-9]{3,18}$", var.name_prefix))
    error_message = "name_prefix must be 3-18 lowercase letters/numbers."
  }
}

variable "container_name" {
  description = "Public-read blob container for issue-agent screenshots."
  type        = string
  default     = "issue-agent-screenshots"
}

variable "github_repository" {
  description = "GitHub repository allowed to federate into the upload identity, in owner/name form."
  type        = string
  default     = "nelsong6/spirelens"
}

variable "github_federated_subjects" {
  description = "GitHub OIDC subject claims allowed to assume the user-assigned managed identity."
  type        = list(string)
  default = [
    "repo:nelsong6/spirelens:ref:refs/heads/main"
  ]
}

variable "retention_days" {
  description = "How long to retain issue-agent screenshot blobs before automatic deletion. Set to 0 to disable lifecycle deletion."
  type        = number
  default     = 90

  validation {
    condition     = var.retention_days >= 0
    error_message = "retention_days must be zero or greater."
  }
}

variable "tags" {
  description = "Tags applied to all Azure resources."
  type        = map(string)
  default = {
    project = "spirelens"
    surface = "issue-agent"
  }
}