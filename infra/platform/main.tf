# Platform layer: everything that is shared by all OpCo instances of one stage.
#
# Rule used to decide what is shared (see DECISIONS.md):
#   shared   = fixed cost, holds no tenant secrets, an outage for everyone is acceptable
#   per OpCo = holds tenant data or secrets, or must be deletable with the tenant
#
# Owned by the platform team. One state file per stage.

locals {
  prefix            = var.stage == "prod" ? var.name : "${var.name}-${var.stage}"
  openai_location   = coalesce(var.openai_location, var.location)
  postgres_location = coalesce(var.postgres_location, var.location)

  tags = {
    project = var.name
    layer   = "platform"
    stage   = var.stage
    managed = "terraform"
  }
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "platform" {
  name     = "rg-${local.prefix}-platform"
  location = var.location
  tags     = local.tags
}

# ── Logs and alert routing: one place for all instances ────────────

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.prefix}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${local.prefix}"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = local.tags
}

resource "azurerm_monitor_action_group" "admin" {
  name                = "ag-${local.prefix}-admin"
  resource_group_name = azurerm_resource_group.platform.name
  short_name          = "hubadmin"
  tags                = local.tags

  email_receiver {
    name                    = "platform-admin"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# ── Container Apps environment: the shared "building" ──────────────
# All instances of this stage run here. They share a network and a log
# destination; isolation between OpCos is enforced by Open WebUI's
# authentication, not by the network. An OpCo with a hard network-isolation
# requirement gets its own environment.

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${local.prefix}"
  location                   = azurerm_resource_group.platform.location
  resource_group_name        = azurerm_resource_group.platform.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  tags                       = local.tags

  lifecycle {
    ignore_changes = [workload_profile]
  }
}
