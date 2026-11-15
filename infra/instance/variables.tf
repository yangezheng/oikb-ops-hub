variable "subscription_id" {
  description = "Azure subscription to deploy into (same as the platform layer)."
  type        = string
}

variable "platform_state_path" {
  description = "Path to the platform layer's local state file. With a remote backend, replace the terraform_remote_state block in main.tf."
  type        = string
  default     = "../platform/terraform.tfstate"
}

variable "opco" {
  description = "Short id of the operating company. Adding an OpCo = a new tfvars file and a new state, nothing else."
  type        = string
  default     = "opco1"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.opco))
    error_message = "opco must be 2-8 lowercase alphanumeric characters, starting with a letter."
  }
}

variable "admin_email" {
  description = "E-mail (login) of the initial Open WebUI admin account."
  type        = string
}

variable "github_token" {
  description = <<-EOT
    GitHub fine-grained personal access token with 'Public repositories (read-only)'
    repository access and NO additional permissions. Used by oikb (to avoid the
    60 req/h anonymous rate limit) and by the GitHub MCP connection.
    It cannot write to any repository by construction.
  EOT
  type        = string
  sensitive   = true
}

# ── Pinned versions ────────────────────────────────────────────────

variable "open_webui_image" {
  description = "Open WebUI image (full image: the slim one has no Azure Blob client). Pinned: oikb needs >= 0.9.6 and an upgrade is a deliberate release (see README, 'Upgrading')."
  type        = string
  default     = "ghcr.io/open-webui/open-webui:v0.13.3"
}

variable "oikb_image" {
  description = "oikb image."
  type        = string
  default     = "ghcr.io/open-webui/oikb:0.6.0"
}

# ── Knowledge base sync ────────────────────────────────────────────

variable "kb_name" {
  description = "Name of the knowledge base that bootstrap creates and the sync job fills."
  type        = string
  default     = "oikb repository"
}

variable "sync_source" {
  description = "oikb source string: the entire repository, default branch, no path filter."
  type        = string
  default     = "github:open-webui/oikb"
}

variable "sync_cron" {
  description = "Schedule of the sync job (UTC). Every 15 minutes: the knowledge base is at most 15 minutes behind the default branch."
  type        = string
  default     = "*/15 * * * *"
}

variable "max_staleness" {
  description = "Alert when no sync has succeeded for this long (ISO 8601). 45 minutes = three missed runs. Allowed: PT30M, PT45M, PT1H, PT2H."
  type        = string
  default     = "PT45M"

  validation {
    condition     = contains(["PT30M", "PT45M", "PT1H", "PT2H"], var.max_staleness)
    error_message = "max_staleness must be one of PT30M, PT45M, PT1H, PT2H."
  }
}

# ── Sizing ─────────────────────────────────────────────────────────

variable "database_pool_size" {
  description = "Pool size per database engine. Open WebUI runs two engines (sync and async), so one instance holds up to 2 x this many connections (measured: 10 at pool size 5). The shared B1ms server has about 35 usable connections: budget before adding OpCos."
  type        = number
  default     = 5
}

variable "deploy_app" {
  description = "false on the very first apply, so that db-init and migrate can run before Open WebUI starts (scripts/day0.sh does this). true afterwards."
  type        = bool
  default     = true
}
