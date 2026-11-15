# Read by the instance layer through terraform_remote_state.

output "stage" {
  value = var.stage
}

output "name" {
  value = var.name
}

output "location" {
  value = azurerm_resource_group.platform.location
}

output "resource_group_name" {
  value = azurerm_resource_group.platform.name
}

output "container_app_environment_id" {
  value = azurerm_container_app_environment.this.id
}

output "container_app_environment_default_domain" {
  value = azurerm_container_app_environment.this.default_domain
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "application_insights_id" {
  value = azurerm_application_insights.this.id
}

output "action_group_id" {
  value = azurerm_monitor_action_group.admin.id
}

output "openai_endpoint" {
  value = trimsuffix(azurerm_cognitive_account.openai.endpoint, "/")
}

output "openai_key" {
  value     = azurerm_cognitive_account.openai.primary_access_key
  sensitive = true
}

output "chat_model" {
  value = azurerm_cognitive_deployment.chat.name
}

output "embedding_model" {
  value = azurerm_cognitive_deployment.embedding.name
}

output "postgres_server_id" {
  value = azurerm_postgresql_flexible_server.this.id
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "postgres_admin_login" {
  value = azurerm_postgresql_flexible_server.this.administrator_login
}

output "postgres_admin_password" {
  value     = random_password.postgres_admin.result
  sensitive = true
}
