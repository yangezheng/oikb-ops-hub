# Secrets live in this OpCo's Key Vault. The app and the jobs read them with
# the managed identity; nothing secret is written into a container definition.

resource "random_password" "webui_secret_key" {
  length  = 64
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
  # GitHub MCP server (official, remote), READ-ONLY, three layers:
  #   1. /readonly endpoint  -> the server does not even register write tools
  #   2. X-MCP-Toolsets      -> only repository, issue and pull-request reads
  #   3. the token itself    -> fine-grained PAT, public repositories read-only
  # (3) is the real control: it holds even if (1) and (2) are misconfigured.
  # info.id "github" makes the tool id "server:mcp:github" (used by bootstrap.py).
  tool_server_connections = jsonencode([{
    type      = "mcp"
    url       = "https://api.githubcopilot.com/mcp/readonly"
    path      = ""
    auth_type = "bearer"
    key       = var.github_token
    headers   = { "X-MCP-Toolsets" = "repos,issues,pull_requests" }
    config = {
      enable        = true
      access_grants = [{ principal_type = "user", principal_id = "*", permission = "read" }]
    }
    info = {
      id          = "github"
      name        = "GitHub (read-only)"
      description = "Official GitHub MCP server, read-only: code, commits, issues and pull requests of public repositories."
    }
  }])

  secret_values = {
    "webui-secret-key"        = random_password.webui_secret_key.result
    "admin-password"          = random_password.admin_password.result
    "database-url"            = local.database_url
    "pg-admin-url"            = local.pg_admin_url
    "db-app-password"         = random_password.db_app.result
    "openai-key"              = local.platform.openai_key
    "github-token"            = var.github_token
    "tool-server-connections" = local.tool_server_connections
  }

  # Static list: for_each keys must be known at plan time and must not be sensitive.
  secret_names = [
    "webui-secret-key",
    "admin-password",
    "database-url",
    "pg-admin-url",
    "db-app-password",
    "openai-key",
    "github-token",
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
