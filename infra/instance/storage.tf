# Uploaded files (every file oikb syncs is an upload). PostgreSQL holds the
# text chunks and vectors; the original files live here. Without this they
# would sit on the container's temporary disk and vanish on every restart.
#
# Per OpCo, not shared: it holds tenant data.
# Access: the app's managed identity, no storage key in the app.

resource "azurerm_storage_account" "uploads" {
  name                            = "st${replace(local.instance, "-", "")}${local.suffix}"
  location                        = azurerm_resource_group.opco.location
  resource_group_name             = azurerm_resource_group.opco.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

resource "azurerm_storage_container" "uploads" {
  name                  = "openwebui"
  storage_account_id    = azurerm_storage_account.uploads.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "app_blob" {
  scope                = azurerm_storage_account.uploads.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}
