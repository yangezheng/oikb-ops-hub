variable "subscription_id" {
  description = "Azure subscription to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region. Sweden Central: EU region with broad Azure OpenAI model availability."
  type        = string
  default     = "swedencentral"
}

variable "name" {
  description = "Short name used as a prefix for all resources."
  type        = string
  default     = "aihub"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,9}$", var.name))
    error_message = "name must be 3-10 lowercase alphanumeric characters, starting with a letter."
  }
}

variable "stage" {
  description = "One platform (and one Container Apps environment) per stage, not per OpCo. 'staging' is where a new Open WebUI version runs the eval suite before it reaches 'prod'."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "staging", "dev"], var.stage)
    error_message = "stage must be prod, staging or dev."
  }
}

variable "alert_email" {
  description = "Where alerts go when an instance or its knowledge base sync is broken (the platform admin)."
  type        = string
}

# ── Azure OpenAI ───────────────────────────────────────────────────

variable "openai_location" {
  description = "Region of the Azure OpenAI resource. Defaults to var.location."
  type        = string
  default     = null
}

variable "chat_model" {
  description = "Chat model behind the assistants. Must support native function calling (required for MCP tools)."
  type = object({
    name     = string
    version  = string
    sku      = string
    capacity = number # thousands of tokens per minute
  })
  default = {
    name     = "gpt-5-mini"
    version  = "2025-08-07"
    sku      = "GlobalStandard" # "DataZoneStandard" keeps inference inside the EU data zone (about 10 % more expensive)
    capacity = 50
  }
}

variable "embedding_model" {
  description = "Embedding model used by Open WebUI for knowledge bases. 1536 dimensions = Open WebUI's pgvector default."
  type = object({
    name     = string
    version  = string
    sku      = string
    capacity = number
  })
  default = {
    name     = "text-embedding-3-small"
    version  = "1"
    sku      = "GlobalStandard"
    capacity = 50
  }
}

# ── PostgreSQL ─────────────────────────────────────────────────────

variable "postgres_location" {
  description = "Region of the PostgreSQL server. Defaults to var.location."
  type        = string
  default     = null
}

variable "postgres_sku" {
  description = "Shared PostgreSQL server. B1ms allows about 50 connections (35 usable): enough for a few instances, not for 55. Budget DATABASE_POOL_SIZE per instance before adding OpCos."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Storage of the shared PostgreSQL server."
  type        = number
  default     = 32768
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}
