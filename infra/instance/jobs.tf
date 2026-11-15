# Four jobs. Three are day-0 / release steps and are started by hand
# (scripts/day0.sh runs them in order); one runs on a schedule.
#
#   db-init    server admin: login role, REVOKE CONNECT FROM PUBLIC, vector extension
#   migrate    Open WebUI schema migrations (also the first step of every upgrade)
#   bootstrap  API key, knowledge base, base model entry, "oikb Ops Assistant"
#   sync       oikb: repository -> knowledge base, every 15 minutes
#
# The scripts are passed to `python -c`, so the jobs run stock images and the
# repository needs no container registry.

locals {
  job_defaults = {
    cpu    = 0.5
    memory = "1Gi"
  }
}

resource "azurerm_container_app_job" "db_init" {
  name                         = "job-${local.instance}-dbinit"
  location                     = azurerm_resource_group.opco.location
  resource_group_name          = azurerm_resource_group.opco.name
  container_app_environment_id = local.platform.container_app_environment_id
  replica_timeout_in_seconds   = 300
  replica_retry_limit          = 0
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  secret {
    name                = "pg-admin-url"
    key_vault_secret_id = azurerm_key_vault_secret.this["pg-admin-url"].versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  secret {
    name                = "db-app-password"
    key_vault_secret_id = azurerm_key_vault_secret.this["db-app-password"].versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  template {
    container {
      name    = "db-init"
      image   = var.open_webui_image # ships psycopg; no extra image to pull
      cpu     = local.job_defaults.cpu
      memory  = local.job_defaults.memory
      command = ["python", "-c", file("${path.module}/../../app/db_init.py")]

      env {
        name        = "PG_ADMIN_URL"
        secret_name = "pg-admin-url"
      }
      env {
        name        = "APP_DB_PASSWORD"
        secret_name = "db-app-password"
      }
      env {
        name  = "APP_DB"
        value = local.db_name
      }
      env {
        name  = "APP_ROLE"
        value = local.db_role
      }
    }
  }

  depends_on = [azurerm_postgresql_flexible_server_database.app]
}

resource "azurerm_container_app_job" "migrate" {
  name                         = "job-${local.instance}-migrate"
  location                     = azurerm_resource_group.opco.location
  resource_group_name          = azurerm_resource_group.opco.name
  container_app_environment_id = local.platform.container_app_environment_id
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 0 # a half-applied migration must be looked at, not retried
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

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

  template {
    container {
      name   = "migrate"
      image  = var.open_webui_image # must be the image the app is about to run
      cpu    = 1.0
      memory = "2Gi"
      # Entry point from the official guide. It is an internal import, not a
      # stable CLI: re-check it against the code on every version change.
      command = ["python", "-c", "import open_webui.config"]

      dynamic "env" {
        for_each = merge(local.app_env, { ENABLE_DB_MIGRATIONS = "true" })

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
    }
  }
}

resource "azurerm_container_app_job" "bootstrap" {
  name                         = "job-${local.instance}-bootstrap"
  location                     = azurerm_resource_group.opco.location
  resource_group_name          = azurerm_resource_group.opco.name
  container_app_environment_id = local.platform.container_app_environment_id
  replica_timeout_in_seconds   = 1200
  replica_retry_limit          = 0
  tags                         = local.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  secret {
    name                = "admin-password"
    key_vault_secret_id = azurerm_key_vault_secret.this["admin-password"].versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  template {
    container {
      name    = "bootstrap"
      image   = var.open_webui_image # only for its Python; bootstrap.py is standard library only
      cpu     = local.job_defaults.cpu
      memory  = local.job_defaults.memory
      command = ["python", "-c", file("${path.module}/../../app/bootstrap.py")]

      env {
        name  = "OPEN_WEBUI_URL"
        value = local.url
      }
      env {
        name  = "ADMIN_EMAIL"
        value = var.admin_email
      }
      env {
        name        = "ADMIN_PASSWORD"
        secret_name = "admin-password"
      }
      env {
        name  = "CHAT_MODEL"
        value = local.platform.chat_model
      }
      env {
        name  = "KB_NAME"
        value = var.kb_name
      }
      env {
        name  = "STATE_FILE"
        value = "/tmp/runtime.env"
      }
      # The system prompt in the repository is the source of truth.
      env {
        name  = "SYSTEM_PROMPT"
        value = file("${path.module}/../../app/assistant/system_prompt.md")
      }
    }
  }
}

resource "azurerm_container_app_job" "sync" {
  name                         = "job-${local.instance}-sync"
  location                     = azurerm_resource_group.opco.location
  resource_group_name          = azurerm_resource_group.opco.name
  container_app_environment_id = local.platform.container_app_environment_id
  replica_timeout_in_seconds   = 840 # shorter than the interval: runs never overlap
  replica_retry_limit          = 0   # the next scheduled run is the retry
  tags                         = local.tags

  schedule_trigger_config {
    cron_expression          = var.sync_cron
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  secret {
    name                = "admin-password"
    key_vault_secret_id = azurerm_key_vault_secret.this["admin-password"].versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  secret {
    name                = "github-token"
    key_vault_secret_id = azurerm_key_vault_secret.this["github-token"].versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  template {
    container {
      name    = "oikb-sync"
      image   = var.oikb_image
      cpu     = local.job_defaults.cpu
      memory  = local.job_defaults.memory
      command = ["python", "-c", file("${path.module}/../../app/oikb_sync.py")]

      env {
        name  = "OPEN_WEBUI_URL"
        value = local.url
      }
      env {
        name  = "ADMIN_EMAIL"
        value = var.admin_email
      }
      env {
        name        = "ADMIN_PASSWORD"
        secret_name = "admin-password"
      }
      # Same read-only token as the MCP connection; lifts the GitHub API
      # limit from 60 to 5000 requests per hour.
      env {
        name        = "GITHUB_TOKEN"
        secret_name = "github-token"
      }
      env {
        name  = "KB_NAME"
        value = var.kb_name
      }
      env {
        name  = "SYNC_SOURCE"
        value = var.sync_source
      }
      env {
        name  = "INSTANCE"
        value = local.instance
      }
    }
  }
}
