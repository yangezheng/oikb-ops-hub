# Secrets live in this OpCo's Key Vault. The app and the jobs read them with
# the managed identity; nothing secret is written into a container definition.

resource "random_password" "webui_secret_key" {
  length  = 64
  special = false
}

# Service accounts: ordinary users, so they get exactly what a user gets and
# nothing more. sync = writes the knowledge base; eval = runs the golden set.
resource "random_password" "sync_password" {
  length  = 32
  special = false
}

resource "random_password" "eval_password" {
  length  = 32
  special = false
}

resource "random_password" "admin_password" {
  length           = 24
  special          = true
  override_special = "-_.~"
}

resource "azurerm_key_vault" "this" {
  name                       = "kv-${local.instance}-${local.suffix}"
  location                   = azurerm_resource_group.opco.location
  resource_group_name        = azurerm_resource_group.opco.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = local.tags
}

# Whoever runs Terraform may write secrets ...
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ... the app may only read them.
resource "azurerm_role_assignment" "app_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Azure RBAC is eventually consistent; without this the first secret write can 403.
resource "time_sleep" "rbac_propagation" {
  create_duration = "90s"

  depends_on = [
    azurerm_role_assignment.deployer_secrets_officer,
    azurerm_role_assignment.app_secrets_user,
    azurerm_role_assignment.app_blob,
  ]
}

locals {
  github_app = var.github_app_id != "" && var.github_app_installation_id != ""
  mcp_oauth  = var.github_app_client_id != ""

  # GitHub MCP server (official, remote), READ-ONLY, three layers:
  #   1. /readonly endpoint  -> the server does not even register write tools
  #   2. X-MCP-Toolsets      -> only repository, issue and pull-request reads
  #   3. the credential      -> GitHub App: its declared permissions are read-only,
  #                             and a user token is the intersection of App and
  #                             user permissions. PAT: no write permission at all.
  # (3) is the real control: it holds even if (1) and (2) are misconfigured.
  # info.id "github" makes the tool id "server:mcp:github" (used by bootstrap.py)
  # and the OAuth callback <url>/oauth/clients/mcp:github/callback.
  mcp_common = {
    type      = "mcp"
    url       = "https://api.githubcopilot.com/mcp/readonly"
    path      = ""
    headers   = { "X-MCP-Toolsets" = "repos,issues,pull_requests" }
    config = {
      enable        = true
      access_grants = [{ principal_type = "user", principal_id = "*", permission = "read" }]
    }
  }

  mcp_info = {
    id          = "github"
    name        = "GitHub (read-only)"
    description = "Official GitHub MCP server, read-only: code, commits, issues and pull requests."
  }

  # Per-user OAuth 2.1 with the GitHub App's static credentials. Each user
  # authorises once; Open WebUI stores their token and sends it with their calls.
  # GitHub Apps ignore OAuth scopes: permissions come from the App settings.
  mcp_connection_oauth = merge(local.mcp_common, {
    auth_type = "oauth_2.1_static"
    key       = ""
    info = merge(local.mcp_info, {
      oauth_scope         = "read:user"
      oauth_client_id     = var.github_app_client_id
      oauth_client_secret = var.github_app_client_secret
      oauth_server_url    = ""
      },
      # Created by Open WebUI itself (day0.sh step 7); empty on the first apply.
      var.github_mcp_oauth_client_info != "" ? { oauth_client_info = var.github_mcp_oauth_client_info } : {}
    )
  })

  mcp_connection_bearer = merge(local.mcp_common, {
    auth_type = "bearer"
    key       = var.github_token
    info      = local.mcp_info
  })

  # Same server, shared read-only PAT, usable ONLY by the eval account.
  # Unattended runs cannot do an interactive GitHub sign-in. Users without
  # access to a connection do not get its tools at all.
  mcp_connection_eval = merge(local.mcp_common, {
    auth_type = "bearer"
    key       = var.github_token
    config = {
      enable        = true
      access_grants = [{ principal_type = "user", principal_id = var.eval_user_id, permission = "read" }]
    }
    info = merge(local.mcp_info, {
      id   = "github-eval"
      name = "GitHub (read-only, eval account)"
    })
  })

  eval_connection_ready = local.mcp_oauth && var.github_token != "" && var.eval_user_id != ""

  tool_server_connections = jsonencode(
    local.mcp_oauth
    ? concat([local.mcp_connection_oauth], local.eval_connection_ready ? [local.mcp_connection_eval] : [])
    : [local.mcp_connection_bearer]
  )

  # The assistant carries both tools; access control decides who gets which.
  assistant_tool_ids = local.mcp_oauth ? "server:mcp:github,server:mcp:github-eval" : "server:mcp:github"

  service_accounts = {
    sync = "sync@${local.instance}.invalid"
    eval = "eval@${local.instance}.invalid"
  }

  secret_values = {
    "webui-secret-key"        = random_password.webui_secret_key.result
    "admin-password"          = random_password.admin_password.result
    "sync-password"           = random_password.sync_password.result
    "database-url"            = local.database_url
    "pg-admin-url"            = local.pg_admin_url
    "db-app-password"         = random_password.db_app.result
    "openai-key"              = local.platform.openai_key
    "github-token"            = var.github_token != "" ? var.github_token : "none"
    "github-app-private-key"  = var.github_app_private_key != "" ? var.github_app_private_key : "none"
    "tool-server-connections" = local.tool_server_connections
  }

  # Static list: for_each keys must be known at plan time and must not be sensitive.
  secret_names = [
    "webui-secret-key",
    "admin-password",
    "sync-password",
    "database-url",
    "pg-admin-url",
    "db-app-password",
    "openai-key",
    "github-token",
    "github-app-private-key",
    "tool-server-connections",
  ]
}

resource "azurerm_key_vault_secret" "this" {
  for_each = toset(local.secret_names)

  name         = each.key
  value        = local.secret_values[each.key]
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [time_sleep.rbac_propagation]
}
