# Azure OpenAI: chat model for the assistants and embedding model for the
# knowledge bases. Prompts and repository content stay inside the Azure tenant.
#
# Shared because quota is granted per subscription, region and model: 55
# accounts would compete for the same quota anyway.
#
# Scope cut: reachable over the public endpoint with an API key. The
# production version puts it behind a private endpoint in the environment's
# VNet and gives each OpCo its own key through a model gateway, so usage and
# cost can be attributed per OpCo.

resource "azurerm_cognitive_account" "openai" {
  name                  = "oai-${local.prefix}-${random_string.suffix.result}"
  location              = local.openai_location
  resource_group_name   = azurerm_resource_group.platform.name
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "oai-${local.prefix}-${random_string.suffix.result}"
  tags                  = local.tags
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.chat_model.name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.chat_model.name
    version = var.chat_model.version
  }

  sku {
    name     = var.chat_model.sku
    capacity = var.chat_model.capacity
  }
}

resource "azurerm_cognitive_deployment" "embedding" {
  name                 = var.embedding_model.name
  cognitive_account_id = azurerm_cognitive_account.openai.id

  model {
    format  = "OpenAI"
    name    = var.embedding_model.name
    version = var.embedding_model.version
  }

  sku {
    name     = var.embedding_model.sku
    capacity = var.embedding_model.capacity
  }

  # Cognitive deployments on one account must be created one at a time.
  depends_on = [azurerm_cognitive_deployment.chat]
}
