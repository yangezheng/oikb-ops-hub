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

  # Local state is a deliberate scope cut for a single-operator case study.
  # For a team: create the storage account in ../tfstate, then uncomment this
  # block here and in ../instance, and switch the instance layer's
  # terraform_remote_state to the azurerm backend.
  # backend "azurerm" {
  #   resource_group_name  = "rg-aihub-tfstate"
  #   storage_account_name = "<output of ../tfstate>"
  #   container_name       = "tfstate"
  #   key                  = "platform-prod.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    cognitive_account {
      purge_soft_delete_on_destroy = true
    }
  }
}
