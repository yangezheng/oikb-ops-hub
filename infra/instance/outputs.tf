output "url" {
  description = "URL of this OpCo's Open WebUI."
  value       = local.url
}

output "admin_email" {
  description = "Login of the Open WebUI admin."
  value       = var.admin_email
}

output "admin_password" {
  description = "Password of the Open WebUI admin: terraform output -raw admin_password"
  value       = random_password.admin_password.result
  sensitive   = true
}

output "resource_group_name" {
  value = azurerm_resource_group.opco.name
}

output "container_app_name" {
  value = local.app_name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "jobs" {
  description = "Job names, in the order scripts/day0.sh runs them."
  value = {
    db_init   = azurerm_container_app_job.db_init.name
    migrate   = azurerm_container_app_job.migrate.name
    bootstrap = azurerm_container_app_job.bootstrap.name
    sync      = azurerm_container_app_job.sync.name
  }
}

output "github_oauth_callback_url" {
  description = "Callback URL to register in the GitHub App (only used with github_app_client_id)."
  value       = "${local.url}/oauth/clients/mcp:github/callback"
}

output "sync_email" {
  description = "Service account the sync job signs in with (ordinary user, writes the knowledge base)."
  value       = local.service_accounts.sync
}

output "eval_email" {
  description = "Service account the eval runner signs in with (ordinary user)."
  value       = local.service_accounts.eval
}

output "sync_password" {
  value     = random_password.sync_password.result
  sensitive = true
}

output "eval_password" {
  value     = random_password.eval_password.result
  sensitive = true
}
