# Azure deployment
variable "azure_subscription_id" {
  description = "Azure subscription ID where all resources are provisioned."
  type        = string
}

# Event Grid
variable "eventgrid_domain_name" {
  description = "Globally unique name of the Event Grid domain."
  type        = string
}

# API Management service
variable "apim_name" {
  description = "Globally unique API Management service name."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group that contains the solution."
  type        = string
}

# Storage
variable "storage_account_name" {
  description = "Globally unique storage account name used for tenant queues."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must contain 3-24 lowercase letters or numbers."
  }
}

variable "location" {
  description = "Azure region used by regional resources."
  type        = string
}

variable "common_tags" {
  description = "Tags applied to resources that support tags in this solution."
  type        = map(string)
}

# Managed identity
variable "managed_identity_name" {
  description = "Name of the user-assigned managed identity used by APIM."
  type        = string
  default     = "apim-mi"
}

variable "storage_account_tier" {
  description = "Performance tier of the storage account."
  type        = string
  default     = "Standard"
}

variable "storage_replication_type" {
  description = "Replication type of the storage account."
  type        = string
  default     = "LRS"
}

variable "storage_shared_access_key_enabled" {
  description = "Whether shared-key authorization is enabled for test queue access."
  type        = bool
  default     = true
}

variable "eventgrid_sender_role_name" {
  description = "Azure built-in role granted to the APIM managed identity."
  type        = string
  default     = "EventGrid Data Sender"
}

variable "apim_publisher_name" {
  description = "Publisher name displayed by API Management."
  type        = string
  default     = "Publisher"
}

variable "apim_publisher_email" {
  description = "Publisher contact email used by API Management."
  type        = string
  default     = "publisher@example.com"
}

variable "apim_sku_name" {
  description = "API Management SKU and capacity in the AzureRM SKU format."
  type        = string
  default     = "Standard_1"
}

# APIM API contract
variable "api_name" {
  description = "Internal identifier of the APIM API."
  type        = string
  default     = "events-api"
}

variable "api_revision" {
  description = "Revision identifier of the APIM API."
  type        = string
  default     = "1"
}

variable "api_display_name" {
  description = "Display name of the APIM API."
  type        = string
  default     = "Events API"
}

variable "api_path" {
  description = "Public path prefix of the APIM API, without leading slash."
  type        = string
  default     = "events"
}

variable "api_protocols" {
  description = "Protocols exposed by the APIM API."
  type        = list(string)
  default     = ["https"]
}

variable "api_subscription_required" {
  description = "Whether callers must provide an APIM subscription key."
  type        = bool
  default     = true
}

variable "api_operation_id" {
  description = "Identifier of the publish operation."
  type        = string
  default     = "publish-event"
}

variable "api_operation_display_name" {
  description = "Display name of the publish operation."
  type        = string
  default     = "Publish Event"
}

variable "api_operation_method" {
  description = "HTTP method used to publish an event."
  type        = string
  default     = "POST"
}

variable "api_operation_url_template" {
  description = "URL template of the publish operation."
  type        = string
  default     = "/{tenantId}"
}

variable "tenant_parameter_name" {
  description = "Name of the route parameter containing the logical tenant ID."
  type        = string
  default     = "tenantId"
}

variable "tenant_parameter_description" {
  description = "Description shown for the tenant route parameter."
  type        = string
  default     = "Tenant identifier used to route to the correct Event Grid topic"
}

variable "event_type" {
  description = "Event Grid eventType value added by the APIM policy."
  type        = string
  default     = "tenant.event"
}

variable "event_data_version" {
  description = "Event Grid dataVersion value added by the APIM policy."
  type        = string
  default     = "1.0"
}

variable "eventgrid_request_timeout_seconds" {
  description = "Timeout used by the APIM send-request policy when publishing to Event Grid."
  type        = number
  default     = 30

  validation {
    condition     = var.eventgrid_request_timeout_seconds >= 1 && var.eventgrid_request_timeout_seconds <= 240
    error_message = "eventgrid_request_timeout_seconds must be between 1 and 240."
  }
}

variable "eventgrid_token_audience" {
  description = "Microsoft Entra resource audience requested by APIM for Event Grid authentication."
  type        = string
  default     = "https://eventgrid.azure.net/"
}

# Multi-tenant resources
variable "tenants" {
  description = "Tenant configuration. Each map key is the logical tenant ID, APIM subscription ID, Event Grid domain topic, and route value; queue_name is the separate destination queue."
  type = map(object({
    queue_name              = string
    event_subscription_name = optional(string)
  }))

  default = {
    tenantA = {
      queue_name = "tenant-a-events"
    }
    tenantB = {
      queue_name = "tenant-b-events"
    }
    tenantC = {
      queue_name = "tenant-c-events"
    }
  }

  validation {
    condition = alltrue([
      for tenant_id, config in var.tenants :
      can(regex("^[A-Za-z][A-Za-z0-9-]{1,48}[A-Za-z0-9]$", tenant_id))
    ])
    error_message = "Each tenant ID must be 3-50 characters, start with a letter, end with a letter or number, and contain only letters, numbers, or hyphens."
  }

  validation {
    condition = alltrue([
      for tenant_id, config in var.tenants :
      length(config.queue_name) >= 3 &&
      length(config.queue_name) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", config.queue_name)) &&
      !strcontains(config.queue_name, "--")
    ])
    error_message = "Each queue_name must be 3-63 characters, contain only lowercase letters, numbers, or hyphens, start and end with a letter or number, and not contain consecutive hyphens."
  }

  validation {
    condition = alltrue([
      for tenant_id, config in var.tenants :
      config.event_subscription_name == null || can(regex("^[A-Za-z0-9-]{3,64}$", config.event_subscription_name))
    ])
    error_message = "Each event_subscription_name, when provided, must be 3-64 characters and contain only letters, numbers, or hyphens."
  }
}