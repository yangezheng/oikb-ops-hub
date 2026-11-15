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

# ── GitHub access ──────────────────────────────────────────────────
# Two ways, chosen by what is filled in:
#
#   GitHub App (recommended)  github_app_* below. The sync job mints a 1-hour
#                             installation token per run; the MCP connection
#                             uses OAuth 2.1, so every user reads GitHub with
#                             their own identity and permissions.
#   Fine-grained PAT          github_token only. One read-only token for
#                             everything; fine for public repositories.

variable "github_app_id" {
  description = "App ID of the GitHub App (App settings > General). Used by the sync job."
  type        = string
  default     = ""
}

variable "github_app_installation_id" {
  description = "Installation ID of the GitHub App: the number at the end of https://github.com/settings/installations/<id>."
  type        = string
  default     = ""
}

variable "github_app_private_key" {
  description = "PEM private key of the GitHub App. Pass it as TF_VAR_github_app_private_key=\"$(cat key.pem)\", never in a file in the repository."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_app_client_id" {
  description = "Client ID of the GitHub App (starts with Iv). Turns the MCP connection into per-user OAuth 2.1."
  type        = string
  default     = ""
}

variable "github_app_client_secret" {
  description = "Client secret of the GitHub App."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_mcp_oauth_client_info" {
  description = "Encrypted OAuth client record that Open WebUI creates for the MCP connection. Written by scripts/day0.sh (app/runtime_setup.py) into <opco>.runtime.tfvars; do not fill in by hand."
  type        = string
  default     = ""
  sensitive   = true
}

variable "eval_user_id" {
  description = "Open WebUI id of the eval service account. Written by scripts/day0.sh (app/runtime_setup.py) into <opco>.runtime.tfvars; do not fill in by hand."
  type        = string
  default     = ""
}

variable "github_token" {
  description = <<-EOT
    Fine-grained personal access token with 'Public repositories (read-only)'
    and NO additional permissions, ideally of a bot account.
    With a GitHub App: only the eval account uses it (connection github-eval),
    because unattended runs cannot sign in to GitHub interactively.
    Without a GitHub App: used by the sync job and shared by all users.
  EOT
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.github_token != "" || (var.github_app_id != "" && var.github_app_installation_id != "" && var.github_app_client_id != "")
    error_message = "Configure either a GitHub App (github_app_id, github_app_installation_id, github_app_private_key, github_app_client_id, github_app_client_secret) or a github_token."
  }
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
