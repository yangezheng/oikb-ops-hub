# Vanilla Open WebUI, configured only through environment variables.
# Follows the official Azure Container Apps guide
# (https://docs.openwebui.com/deployment/azure-container-apps):
# PostgreSQL + pgvector, Blob Storage for uploads, secrets from Key Vault,
# one replica, migrations in a separate job.

locals {
  # Settings shared by the app and the jobs that run the Open WebUI image.
  app_env = {
    WEBUI_URL = local.url

    # Admin account is created on first start (only when the database has no
    # users); self-signup stays off.
    WEBUI_ADMIN_EMAIL = var.admin_email
    WEBUI_ADMIN_NAME  = "Hub Admin"
    ENABLE_SIGNUP     = "false"

    # Environment is the single source of truth for admin settings: nothing
    # set in the Admin UI survives a restart, so the running system cannot
    # drift from this repository.
    ENABLE_PERSISTENT_CONFIG = "false"

    # The eval runner authenticates with an API key.
    ENABLE_API_KEYS = "true"

    # Schema migrations run in the migrate job, never at app start: a start
    # must not change the schema, and an image rollback does not undo one.
    ENABLE_DB_MIGRATIONS = "false"
    UVICORN_WORKERS      = "1"

    # All state leaves the container: rows and vectors in PostgreSQL,
    # uploaded files in Blob Storage. The vector extension is created by the
    # db-init job with the server admin, not by the app role.
    VECTOR_DB                    = "pgvector"
    PGVECTOR_CREATE_EXTENSION    = "false"
    DATABASE_POOL_SIZE           = tostring(var.database_pool_size)
    DATABASE_POOL_MAX_OVERFLOW   = "0"
    STORAGE_PROVIDER             = "azure"
    AZURE_STORAGE_ENDPOINT       = trimsuffix(azurerm_storage_account.uploads.primary_blob_endpoint, "/")
    AZURE_STORAGE_CONTAINER_NAME = azurerm_storage_container.uploads.name
    # No AZURE_STORAGE_KEY: Open WebUI then uses the managed identity.
    AZURE_CLIENT_ID = azurerm_user_assigned_identity.app.client_id

    # Chat model: Azure OpenAI (v1 endpoint). Only the listed deployment is exposed.
    ENABLE_OLLAMA_API    = "false"
    OPENAI_API_BASE_URLS = "${local.platform.openai_endpoint}/openai/v1"
    OPENAI_API_CONFIGS   = jsonencode({ "0" = { enable = true, azure = true, model_ids = [local.platform.chat_model] } })

    # Embeddings for the knowledge base: Azure OpenAI as well.
    RAG_EMBEDDING_ENGINE         = "azure_openai"
    RAG_EMBEDDING_MODEL          = local.platform.embedding_model
    RAG_AZURE_OPENAI_BASE_URL    = local.platform.openai_endpoint
    RAG_AZURE_OPENAI_API_VERSION = "2024-10-21"
    RAG_EMBEDDING_BATCH_SIZE     = "32"

    # Secrets come from Key Vault, and a changed secret does not restart the
    # app. This hash changes with the MCP connection, so Terraform rolls out a
    # new revision that reads the new value.
    CONFIG_REVISION = substr(nonsensitive(sha256(local.tool_server_connections)), 0, 12)

    # No outbound telemetry / update pings from an enterprise hub.
    SCARF_NO_ANALYTICS          = "true"
    DO_NOT_TRACK                = "true"
    ANONYMIZED_TELEMETRY        = "false"
    ENABLE_VERSION_UPDATE_CHECK = "false"
  }

  # env name -> Key Vault secret name
  app_secret_env = {
    WEBUI_SECRET_KEY         = "webui-secret-key"
    WEBUI_ADMIN_PASSWORD     = "admin-password"
    DATABASE_URL             = "database-url"
    OPENAI_API_KEYS          = "openai-key"
    RAG_AZURE_OPENAI_API_KEY = "openai-key"
    TOOL_SERVER_CONNECTIONS  = "tool-server-connections"
  }

  app_secret_names = distinct(values(local.app_secret_env))
}

resource "azurerm_container_app" "open_webui" {
  # Day 0 is two applies: the database role and schema must exist before the
  # first replica starts, otherwise the revision never becomes ready and the
  # apply fails. scripts/day0.sh: apply with deploy_app=false, run db-init and
  # migrate, apply again.
  count = var.deploy_app ? 1 : 0

  name                         = local.app_name
  resource_group_name          = azurerm_resource_group.opco.name
  container_app_environment_id = local.platform.container_app_environment_id # lives in the platform resource group
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  dynamic "secret" {
    for_each = toset(local.app_secret_names)

    content {
      name                = secret.value
      key_vault_secret_id = azurerm_key_vault_secret.this[secret.value].versionless_id
      identity            = azurerm_user_assigned_identity.app.id
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 8080
    transport                  = "auto"
    allow_insecure_connections = false # HTTPS only; the platform provides the certificate

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Exactly one replica. More than one needs Redis (WEBSOCKET_MANAGER=redis)
    # and a larger connection budget on the shared PostgreSQL server.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "open-webui"
      image  = var.open_webui_image
      cpu    = 1.0
      memory = "2Gi"

      dynamic "env" {
        for_each = local.app_env

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.app_secret_env

        content {
          name        = env.key
          secret_name = env.value
        }
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 30 # up to 5 minutes for the first start
      }

      # /ready also checks the database (and Redis, once one is configured).
      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/ready"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health"
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }
    }
  }
}
