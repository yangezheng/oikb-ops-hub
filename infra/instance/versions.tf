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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # One state file per OpCo: a change to opco1 cannot touch the platform or
  # another OpCo, because they are not in this state. See ../platform/versions.tf
  # for the remote backend.
  # backend "azurerm" {
  #   resource_group_name  = "rg-aihub-tfstate"
  #   storage_account_name = "<output of ../tfstate>"
  #   container_name       = "tfstate"
  #   key                  = "instance-prod-opco1.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
