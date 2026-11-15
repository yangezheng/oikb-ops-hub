# One PostgreSQL server for all instances; one database and one login role
# per OpCo (created in the instance layer).
#
# What a database does and does not isolate:
#   isolated = data (one connection sees one database)
#   shared   = roles, CPU, memory, connection limit, backups, downtime
#
# Consequences that are accepted and written down in DECISIONS.md:
#   - point-in-time restore works for the whole server only; restoring one
#     OpCo = restore to a new server + pg_dump of that database
#   - one noisy OpCo slows the others; the next step is cells of 10-15 OpCos
#     per server, not one server per OpCo
#
# Scope cut: public endpoint, TLS required, firewall open to Azure services
# only. The production version uses a private endpoint in the environment's
# VNet.

resource "random_password" "postgres_admin" {
  length  = 32
  special = false # the password travels inside a connection URL
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = "psql-${local.prefix}-${random_string.suffix.result}"
  location                      = azurerm_resource_group.platform.location
  resource_group_name           = azurerm_resource_group.platform.name
  version                       = var.postgres_version
  sku_name                      = var.postgres_sku
  storage_mb                    = var.postgres_storage_mb
  administrator_login           = "pgadmin"
  administrator_password        = random_password.postgres_admin.result
  public_network_access_enabled = true
  backup_retention_days         = 7
  tags                          = local.tags

  lifecycle {
    ignore_changes = [zone] # Azure picks the zone; do not force a re-create
  }
}

# "0.0.0.0" is Azure's notation for "allow connections from Azure services".
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Extensions must be allow-listed on the server before any database can
# create them. pgvector holds the knowledge base embeddings, so no vector
# index lives on a container's local disk.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "VECTOR"
}
