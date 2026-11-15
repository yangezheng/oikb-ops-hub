# Optional, run once: a storage account for remote Terraform state.
# It has to exist before everything else, so it has its own (local) state and
# its own resource group that is never deleted with the platform.
#
# Not needed for a single operator: the platform and instance layers default
# to local state. See the commented backend blocks in their versions.tf.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "swedencentral"
}

variable "name" {
  type    = string
  default = "aihub"
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-${var.name}-tfstate"
  location = var.location
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "st${var.name}tf${random_string.suffix.result}"
  location                        = azurerm_resource_group.tfstate.location
  resource_group_name             = azurerm_resource_group.tfstate.name
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true # a broken state can be rolled back
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

output "storage_account_name" {
  value = azurerm_storage_account.tfstate.name
}
