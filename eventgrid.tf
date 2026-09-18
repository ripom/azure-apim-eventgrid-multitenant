terraform {
  required_version = "= 1.15.8"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "= 2.12.0"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.5.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}

provider "azapi" {
  subscription_id = var.azure_subscription_id
}

# -----------------------------
# Resource Group
# -----------------------------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# -----------------------------
# User Assigned Managed Identity for APIM
# -----------------------------
resource "azurerm_user_assigned_identity" "apim_mi" {
  name                = var.managed_identity_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  tags = var.common_tags
}

# -----------------------------
# Storage Account (subscriber)
# -----------------------------
resource "azurerm_storage_account" "sa" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = var.storage_account_tier
  account_replication_type = var.storage_replication_type

  public_network_access_enabled   = true
  shared_access_key_enabled       = var.storage_shared_access_key_enabled
  allow_nested_items_to_be_public = false

  tags = var.common_tags
}

resource "azurerm_storage_queue" "tenant" {
  for_each = var.tenants

  name                 = each.value.queue_name
  storage_account_name = azurerm_storage_account.sa.name
}

# -----------------------------
# Event Grid Domain
# -----------------------------
resource "azurerm_eventgrid_domain" "domain" {
  name                          = var.eventgrid_domain_name
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }

  tags = var.common_tags
}

# -----------------------------
# Domain Topics
# -----------------------------
resource "azurerm_eventgrid_domain_topic" "tenant" {
  for_each = var.tenants

  name                = each.key
  domain_name         = azurerm_eventgrid_domain.domain.name
  resource_group_name = azurerm_resource_group.rg.name
}

# -----------------------------
# Event Grid Subscriptions → Storage Queue
# -----------------------------
resource "azurerm_eventgrid_event_subscription" "tenant" {
  for_each = var.tenants

  name  = coalesce(each.value.event_subscription_name, "${each.key}-sub")
  scope = azurerm_eventgrid_domain_topic.tenant[each.key].id

  storage_queue_endpoint {
    storage_account_id = azurerm_storage_account.sa.id
    queue_name         = azurerm_storage_queue.tenant[each.key].name
  }
}

# -----------------------------
# API Management (Standard SKU)
# -----------------------------
resource "azapi_resource_action" "purge_apim_on_destroy" {
  type = "Microsoft.ApiManagement/locations/deletedservices@2024-05-01"
  resource_id = join("/", [
    "/subscriptions/${var.azure_subscription_id}/providers/Microsoft.ApiManagement/locations",
    var.location,
    "deletedservices",
    var.apim_name,
  ])
  method = "DELETE"
  when   = "destroy"

  retry = {
    error_message_regex  = ["404", "ResourceNotFound"]
    interval_seconds     = 5
    max_interval_seconds = 30
  }

  timeouts {
    delete = "15m"
  }
}

resource "azapi_resource" "apim" {
  type      = "Microsoft.ApiManagement/service@2024-05-01"
  name      = var.apim_name
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.apim_mi.id]
  }

  tags = var.common_tags

  body = {
    properties = {
      publisherEmail      = var.apim_publisher_email
      publisherName       = var.apim_publisher_name
      publicNetworkAccess = "Enabled"
      virtualNetworkType  = "None"
    }
    sku = {
      capacity = tonumber(split("_", var.apim_sku_name)[1])
      name     = split("_", var.apim_sku_name)[0]
    }
  }

  schema_validation_enabled = true

  depends_on = [azapi_resource_action.purge_apim_on_destroy]
}

# -----------------------------
# APIM API
# -----------------------------
resource "azurerm_api_management_api" "api" {
  name                = var.api_name
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azapi_resource.apim.name

  revision              = var.api_revision
  display_name          = var.api_display_name
  path                  = var.api_path
  protocols             = var.api_protocols
  subscription_required = var.api_subscription_required

  depends_on = [azapi_resource.apim]
}

# -----------------------------
# APIM API Operation
# -----------------------------
resource "azurerm_api_management_api_operation" "publish" {
  operation_id        = var.api_operation_id
  api_name            = azurerm_api_management_api.api.name
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  display_name = var.api_operation_display_name
  method       = var.api_operation_method
  url_template = var.api_operation_url_template

  template_parameter {
    name        = var.tenant_parameter_name
    required    = true
    type        = "string"
    description = var.tenant_parameter_description
  }
}

# -----------------------------
# APIM API Policy: publish to Event Grid
# -----------------------------
resource "azurerm_api_management_api_policy" "eventgrid" {
  api_name            = azurerm_api_management_api.api.name
  api_management_name = azapi_resource.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <set-variable name="tenantId" value="@((string)context.Request.MatchedParameters[&quot;${var.tenant_parameter_name}&quot;])" />
        <!-- A tenant-scoped subscription can publish only when its ID matches the requested tenant. -->
        <choose>
          <when condition="@(context.Subscription == null || (string)context.Subscription.Id != (string)context.Variables[&quot;tenantId&quot;])">
            <return-response>
              <set-status code="403" reason="Forbidden" />
              <set-header name="Content-Type" exists-action="override">
                <value>application/json</value>
              </set-header>
              <set-body>{ "error": "Subscription cannot publish to this tenant" }</set-body>
            </return-response>
          </when>
        </choose>
        <send-request mode="new" response-variable-name="eventGridResponse" timeout="${var.eventgrid_request_timeout_seconds}" ignore-error="false">
          <set-url>${azurerm_eventgrid_domain.domain.endpoint}</set-url>
          <set-method>POST</set-method>
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <!-- Wrap the client payload in an Event Grid event and route it to the tenant topic. -->
          <set-body>@{
            var data = context.Request.Body.As&lt;Newtonsoft.Json.Linq.JToken&gt;(preserveContent: true);
            return new Newtonsoft.Json.Linq.JArray(
              new Newtonsoft.Json.Linq.JObject(
                new Newtonsoft.Json.Linq.JProperty("id", Guid.NewGuid().ToString()),
                new Newtonsoft.Json.Linq.JProperty("eventType", "${var.event_type}"),
                new Newtonsoft.Json.Linq.JProperty("subject", "/apim/" + (string)context.Variables["tenantId"]),
                new Newtonsoft.Json.Linq.JProperty("eventTime", DateTime.UtcNow.ToString("o")),
                new Newtonsoft.Json.Linq.JProperty("data", data),
                new Newtonsoft.Json.Linq.JProperty("dataVersion", "${var.event_data_version}"),
                new Newtonsoft.Json.Linq.JProperty("topic", (string)context.Variables["tenantId"])
              )
            ).ToString();
          }</set-body>
          <!-- APIM authenticates to Event Grid; client credentials are never forwarded downstream. -->
          <authentication-managed-identity resource="${var.eventgrid_token_audience}" client-id="${azurerm_user_assigned_identity.apim_mi.client_id}" />
        </send-request>
        <return-response response-variable-name="eventGridResponse" />
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML
}

# -----------------------------
# APIM Subscriptions per tenant
# -----------------------------
resource "azapi_resource" "apim_subscription" {
  for_each = var.tenants

  type      = "Microsoft.ApiManagement/service/subscriptions@2024-05-01"
  name      = each.key
  parent_id = azapi_resource.apim.id

  body = {
    properties = {
      allowTracing = false
      displayName  = each.key
      scope        = trimsuffix(azurerm_api_management_api.api.id, ";rev=${azurerm_api_management_api.api.revision}")
      state        = "active"
    }
  }

  retry = {
    error_message_regex  = ["401 Unauthorized"]
    interval_seconds     = 5
    max_interval_seconds = 30
  }

  schema_validation_enabled = true
}

# -----------------------------
# RBAC: APIM MI → EventGrid Data Sender
# -----------------------------
# Clients never receive Event Grid credentials. Only APIM's managed identity can publish.
resource "azurerm_role_assignment" "apim_sender" {
  scope                = azurerm_eventgrid_domain.domain.id
  role_definition_name = var.eventgrid_sender_role_name
  principal_id         = azurerm_user_assigned_identity.apim_mi.principal_id
}
