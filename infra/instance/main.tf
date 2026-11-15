# Instance layer: everything that belongs to ONE operating company.
# Deleting this layer (terraform destroy) takes the OpCo offline and removes
# its data; nothing here is shared with another OpCo.
#
# Always offboard with `terraform destroy`, never by deleting the resource
# group in the portal: container apps deleted that way can stay registered in
# the shared environment and block it.

data "azurerm_client_config" "current" {}

data "terraform_remote_state" "platform" {
  backend = "local"

  config = {
    path = var.platform_state_path
  }
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  platform = data.terraform_remote_state.platform.outputs

  prefix   = local.platform.stage == "prod" ? local.platform.name : "${local.platform.name}-${local.platform.stage}"
  instance = "${local.prefix}-${var.opco}" # e.g. aihub-opco1
  suffix   = random_string.suffix.result

  app_name = "ca-${local.instance}"
  url      = "https://${local.app_name}.${local.platform.container_app_environment_default_domain}"

  db_name = replace("${local.instance}", "-", "_") # e.g. aihub_opco1
  db_role = "${local.db_name}_app"

  tags = {
    project = local.platform.name
    layer   = "instance"
    stage   = local.platform.stage
    opco    = var.opco
    managed = "terraform"
  }
}

resource "azurerm_resource_group" "opco" {
  name     = "rg-${local.instance}"
  location = local.platform.location
  tags     = local.tags
}

# One identity for the app and its jobs. It may read this OpCo's secrets and
# this OpCo's blob container, and nothing else.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.instance}"
  location            = azurerm_resource_group.opco.location
  resource_group_name = azurerm_resource_group.opco.name
  tags                = local.tags
}
