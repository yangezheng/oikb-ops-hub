# This OpCo's database on the shared server. It lives in the platform
# resource group (a database cannot exist outside its server) but belongs to
# this state, so `terraform destroy` of the instance removes it.
#
# The login role, the REVOKE CONNECT FROM PUBLIC and the vector extension
# cannot be expressed in azurerm; the db-init job does them (app/db_init.py).

resource "random_password" "db_app" {
  length  = 32
  special = false # the password travels inside a connection URL
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = local.db_name
  server_id = local.platform.postgres_server_id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

locals {
  database_url = "postgresql://${local.db_role}:${random_password.db_app.result}@${local.platform.postgres_fqdn}:5432/${local.db_name}?sslmode=require"
  pg_admin_url = "postgresql://${local.platform.postgres_admin_login}:${local.platform.postgres_admin_password}@${local.platform.postgres_fqdn}:5432/postgres?sslmode=require"
}
