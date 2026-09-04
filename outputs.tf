# The PowerShell test runner consumes this output so configuration remains in Terraform.
output "deployment_config" {
  description = "Applied resource names and API settings consumed by the test runner."
  value = {
    azure_subscription_id             = var.azure_subscription_id
    resource_group_name               = azurerm_resource_group.rg.name
    location                          = azurerm_resource_group.rg.location
    managed_identity_name             = azurerm_user_assigned_identity.apim_mi.name
    managed_identity_client_id        = azurerm_user_assigned_identity.apim_mi.client_id
    storage_account_name              = azurerm_storage_account.sa.name
    eventgrid_domain_name             = azurerm_eventgrid_domain.domain.name
    eventgrid_endpoint                = azurerm_eventgrid_domain.domain.endpoint
    eventgrid_token_audience          = var.eventgrid_token_audience
    eventgrid_request_timeout_seconds = var.eventgrid_request_timeout_seconds
    event_type                        = var.event_type
    event_data_version                = var.event_data_version
    apim_name                         = azapi_resource.apim.name
    apim_gateway_url                  = "https://${azapi_resource.apim.name}.azure-api.net"
    api_name                          = azurerm_api_management_api.api.name
    api_path                          = azurerm_api_management_api.api.path
    tenant_parameter_name             = var.tenant_parameter_name
    tenant_queues = {
      for tenant_id, queue in azurerm_storage_queue.tenant : tenant_id => queue.name
    }
  }
}