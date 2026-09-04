# Scalability and Authentication Design

## Implemented Model

The current implementation uses one APIM subscription per logical tenant:

```text
APIM subscription ID = tenant ID = Event Grid domain topic name
```

Examples:

| APIM subscription | Allowed path | Event Grid topic | Queue |
|---|---|---|---|
| `tenantA` | `/events/tenantA` | `tenantA` | `tenant-a-events` |
| `tenantB` | `/events/tenantB` | `tenantB` | `tenant-b-events` |

The APIM policy reads the tenant from the URL and compares it with the authenticated subscription ID:

```xml
<set-variable
  name="tenantId"
  value="@((string)context.Request.MatchedParameters[&quot;tenantId&quot;])" />

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
```

There are no tenant-specific branches in the policy. Its size and authorization cost remain constant as tenants are added.

## Why the Initial Model Did Not Scale

An initial implementation mapped `userA` to `tenantA` and `userB` to `tenantB` with explicit `<when>` blocks. Extending that approach to 500 tenants would create hundreds of policy branches and several operational problems:

- large policies that are difficult to review;
- deployments for every tenant onboarding;
- increased risk of incorrect mappings;
- no clear source of truth for tenant configuration;
- complex automated testing.

The tenant-keyed subscription model moves the tenant list to Terraform data and keeps authorization generic.

## Terraform Provisioning

The `tenants` variable in `variables.tf` is the source of truth:

```hcl
variable "tenants" {
  type = map(object({
    queue_name = string
  }))

  default = {
    tenantA = {
      queue_name = "tenant-a-events"
    }
    tenantB = {
      queue_name = "tenant-b-events"
    }
  }
}
```

The same map creates all tenant-specific resources.

### APIM Subscriptions

```hcl
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
}
```

### Event Grid Topics

```hcl
resource "azurerm_eventgrid_domain_topic" "tenant" {
  for_each = var.tenants

  name                = each.key
  domain_name         = azurerm_eventgrid_domain.domain.name
  resource_group_name = azurerm_resource_group.rg.name
}
```

### Storage Queues

```hcl
resource "azurerm_storage_queue" "tenant" {
  for_each = var.tenants

  name                 = each.value.queue_name
  storage_account_name = azurerm_storage_account.sa.name
}
```

### Event Grid Subscriptions

```hcl
resource "azurerm_eventgrid_event_subscription" "tenant" {
  for_each = var.tenants

  name  = coalesce(each.value.event_subscription_name, "${each.key}-sub")
  scope = azurerm_eventgrid_domain_topic.tenant[each.key].id

  storage_queue_endpoint {
    storage_account_id = azurerm_storage_account.sa.id
    queue_name         = azurerm_storage_queue.tenant[each.key].name
  }
}
```

## Tenant Onboarding Example

The default `tenantC` entry is the third demonstration tenant, not a reserved Terraform name. To onboard a new customer, choose a unique logical tenant ID and a separate Storage Queue name that follows the rules in [CONFIGURATION.md](CONFIGURATION.md#tenant-map). For example:

```hcl
contoso = {
  queue_name = "contoso-events"
}
```

Run:

```powershell
terraform plan
terraform apply
```

Terraform creates:

- APIM subscription `contoso`;
- Event Grid domain topic `contoso`;
- Storage Queue `contoso-events`;
- Event Grid subscription `contoso-sub`.

No APIM policy update is required. The new key succeeds on `/events/contoso` and receives HTTP `403` on another tenant's route.

For large environments, provide the map from a non-committed `.tfvars` file or generate it in an onboarding pipeline. The PowerShell scripts consume Terraform's `deployment_config` output and therefore follow overridden names, endpoints, API paths, and queue mappings automatically after `terraform apply`.

## 500-Tenant Scale Example

The publishable [terraform.500-tenants.tfvars.example](terraform.500-tenants.tfvars.example) file generates `tenant1` through `tenant500`. Each tenant receives a matching queue named `tenant1-events` through `tenant500-events`. The file contains placeholder environment values and no credentials or deployment-specific identifiers.

Create a private working copy, replace every environment placeholder, and keep the copy outside source control:

```powershell
Copy-Item terraform.500-tenants.tfvars.example scale-test.tfvars
```

Review the expected resource count, Azure quotas, regional availability, and estimated cost before deployment. A normal plan refreshes every tenant resource and can issue many Azure Resource Manager requests, so begin with reduced concurrency:

```powershell
terraform plan -var-file="scale-test.tfvars" -parallelism=2 -out="scale-test.tfplan"
terraform show "scale-test.tfplan"
```

Only after reviewing a successful, fully refreshed plan, apply that exact saved plan:

```powershell
terraform apply "scale-test.tfplan"
```

This example demonstrates Terraform data generation and the constant-size APIM authorization policy. It is not evidence that 500 tenants fit the quotas, performance requirements, deployment window, or budget of a particular Azure subscription. Start at a smaller scale in a disposable non-production environment and increase incrementally. The generated plan file and private `.tfvars` copy are ignored by this repository.

## Safer URL Variant

When each credential always maps to exactly one tenant, the client does not need to choose a tenant in the URL. The API could expose:

```text
POST /events
```

APIM could derive the topic exclusively from the authenticated subscription:

```xml
<set-variable
  name="tenantId"
  value="@((string)context.Subscription.Id)" />
```

This removes the possibility of a client attempting cross-tenant routing. It is a useful future simplification, but it changes the current API contract.

## Microsoft Entra ID Alternative

APIM subscription keys are appropriate for a simple machine-to-machine demonstration. Microsoft Entra ID is preferable when clients are workforce users, managed identities, or registered applications and require centralized lifecycle management.

The trust flow becomes:

```text
Client -- OAuth access token --> APIM -- managed identity --> Event Grid
```

APIM validates the client token, derives a logical tenant from a trusted claim, and still uses `apim-mi` for Event Grid.

### Example JWT Validation

```xml
<validate-jwt
  header-name="Authorization"
  failed-validation-httpcode="401"
  failed-validation-error-message="Invalid or missing access token"
  output-token-variable-name="jwt">
  <openid-config url="https://login.microsoftonline.com/{entra-tenant-id}/v2.0/.well-known/openid-configuration" />
  <audiences>
    <audience>api://{api-application-client-id}</audience>
  </audiences>
  <required-claims>
    <claim name="roles" match="any">
      <value>Event.Publish</value>
    </claim>
  </required-claims>
</validate-jwt>
```

Read the requested tenant and the authorized tenant claim:

```xml
<set-variable
  name="requestedTenant"
  value="@((string)context.Request.MatchedParameters[&quot;tenantId&quot;])" />

<set-variable
  name="authorizedTenant"
  value="@(((Jwt)context.Variables[&quot;jwt&quot;]).Claims[&quot;tenant_id&quot;][0])" />
```

Reject a mismatch:

```xml
<choose>
  <when condition="@((string)context.Variables[&quot;requestedTenant&quot;] != (string)context.Variables[&quot;authorizedTenant&quot;])">
    <return-response>
      <set-status code="403" reason="Forbidden" />
  <set-body>{ "error": "Token cannot publish to this tenant" }</set-body>
    </return-response>
  </when>
</choose>
```

The `tenant_id` shown here is a logical application tenant, not necessarily the Microsoft Entra directory tenant ID. Microsoft Entra ID does not automatically issue an arbitrary logical tenant claim for client-credentials tokens. Choose one of these approaches:

- configure a trusted claims-mapping policy;
- assign a tenant-specific application role;
- map the `azp` or `appid` client claim to a tenant in an authorization service;
- use one managed identity or service principal per logical tenant.

Do not accept a tenant claim supplied in the request body or an unsigned header.

### Token Request Example

A confidential client can request a token with client credentials:

```powershell
$tokenResponse = Invoke-RestMethod `
  -Method POST `
  -Uri "https://login.microsoftonline.com/<entra-tenant-id>/oauth2/v2.0/token" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body @{
    client_id     = "<client-application-id>"
    client_secret = $env:CLIENT_SECRET
    scope         = "api://<api-application-id>/.default"
    grant_type    = "client_credentials"
  }

Invoke-RestMethod `
  -Method POST `
  -Uri "https://<apim-name>.azure-api.net/<api-path>/<tenant-id>" `
  -Headers @{ Authorization = "Bearer $($tokenResponse.access_token)" } `
  -ContentType "application/json" `
  -Body '{"hello":"world"}'
```

Store client secrets in Key Vault or GitHub Actions secrets. Prefer workload identity federation or managed identity when possible.

### Migration Order

To migrate safely from APIM keys to Entra ID:

1. Register the API and client applications.
2. Define API scopes or application roles.
3. Establish a trusted tenant claim or application-to-tenant mapping.
4. Add and test `validate-jwt` while subscription keys are still enabled.
5. Update clients to send bearer tokens.
6. Set `subscription_required = false` only after JWT enforcement is verified.
7. Remove APIM subscriptions after all clients have migrated.

Disabling subscription keys before JWT validation is active would expose the API anonymously.

## Users Authorized for Multiple Tenants

The one-subscription-to-one-tenant convention does not represent many-to-many authorization. For that case, use:

- Entra ID groups or application roles;
- a signed claim containing allowed tenant identifiers, within practical token-size limits;
- an external authorization service keyed by client identity and requested tenant;
- APIM `send-request` to the authorization service with short-lived caching.

Do not place hundreds of client-to-tenant mappings directly in the APIM policy.

## Security Boundaries

APIM and Event Grid enforce different concerns:

1. APIM authenticates the external client and authorizes the logical tenant.
2. Event Grid authorizes APIM as the technical publisher through `apim-mi`.

Event Grid sees APIM as the sender. Therefore, APIM must reject unauthorized clients before executing `send-request`.

Clients must never receive Event Grid access keys, the managed identity credentials, or Azure management credentials.

## Operational Limits to Review

The data model and APIM policy avoid tenant-specific policy growth, but that does not prove that a particular Azure subscription, region, SKU, or Terraform execution environment can support 500 tenants. This project has not validated a live 500-tenant deployment, sustained throughput at that scale, deployment duration, or total cost.

Before onboarding hundreds of tenants, estimate cost and verify current Azure quotas for the selected subscription, region, and SKUs:

- Event Grid domain topics and event subscriptions;
- APIM subscriptions, policy size, gateway throughput, and request limits;
- Storage Account queue count, throughput, and capacity;
- Terraform plan/apply duration with thousands of resource instances;
- API and Event Grid retry behavior;
- key rotation and secure tenant credential distribution;
- monitoring, alerting, and log retention.

Quotas, pricing, and service behavior change over time. Check the official Azure service-limit and pricing documentation during production design, request quota increases before deployment where supported, and validate the target scale incrementally in a non-production environment.

Terraform refreshes every managed tenant resource during a normal plan. With hundreds of topics and subscriptions, a transient Azure Resource Manager or network timeout can interrupt the plan even when the resources are healthy. Retry with reduced concurrency, for example:

```powershell
terraform plan -var-file="scale-test.tfvars" -parallelism=2 -out="scale-test.tfplan"
```

Typical errors include `dial tcp ...:443: connectex`, `HTTP response was nil`, and `connection may have been reset` while retrieving a scoped Event Grid subscription or its full URL. These indicate a transient Azure Resource Manager or network connection failure, not explicit service throttling unless Azure returns HTTP `429 Too Many Requests`.

Retry with `-parallelism=1` if the failures continue. When different tenant subscriptions fail on each attempt and a single targeted subscription succeeds, concurrency or network instability is more likely than a broken resource. A diagnostic `-refresh=false` plan can help separate stale local state from configuration changes, but always complete and review a normal refreshed plan before applying changes.

## State Migration

The repository includes Terraform `moved` blocks that migrated the original topic, queue, and Event Grid subscription addresses to `for_each` addresses without recreating those Azure resources.

The original APIM subscriptions `userA` and `userB` were intentionally replaced by `tenantA` and `tenantB`, which generated new keys. Existing clients must receive the new tenant-keyed credentials.

Keep the `moved` blocks until every relevant Terraform state has applied the migration. Removing them too early can cause Terraform to plan unnecessary replacements in another environment.

## Recommendation

Use tenant-keyed APIM subscriptions when:

- each client credential belongs to exactly one logical tenant;
- static key lifecycle management is acceptable;
- simple onboarding is more important than identity-based access.

Use Microsoft Entra ID when:

- clients already have managed identities or application registrations;
- centralized revocation, expiration, Conditional Access, or identity audit is required;
- users or applications can access multiple tenants;
- avoiding long-lived static keys is a priority.
