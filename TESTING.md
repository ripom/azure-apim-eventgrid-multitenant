# Solution Testing Guide

The repository uses one test runner, `test-solution.ps1`, for functional and security verification. It reads the applied resource names and endpoints from Terraform, retrieves secrets only at runtime, and never writes credentials to disk.

## What Is Tested

| Test | Verification | Expected result |
|---|---|---|
| `Delivery` | Publishes through APIM and peeks the tenant Storage Queue for the generated test ID | HTTP `200` and matching queue event |
| `TenantAccessControl` | Uses one tenant subscription key first on its own route and then on another tenant route | Own tenant returns HTTP `200` and delivers; different tenant returns HTTP `403` |
| `DirectAccess` | Sends an anonymous request directly to the Event Grid endpoint | HTTP `401` or `403` |
| `All` | Runs APIM publishing, tenant isolation, and direct Event Grid bypass tests | Every selected test passes |

Queue reads use `PeekMessages`, so test events are not consumed or deleted.

## Prerequisites

1. Deploy the current Terraform configuration successfully.
2. Install PowerShell 7 and Terraform 1.15.8.
3. Run the tests from this applied Terraform workspace, or from a workspace that can read the same state and `deployment_config` output.
4. For `Delivery`, `TenantAccessControl`, and `All`, install `Az.Accounts` and `Az.Storage`, then authenticate to the Azure subscription configured in Terraform.

```powershell
Connect-AzAccount
Set-AzContext -SubscriptionId "<azure-subscription-id>"
terraform output -json deployment_config
```

The last command must return the applied configuration. If it fails, run `terraform apply` before testing.

`DirectAccess` only needs the Terraform output and does not require Azure PowerShell authentication.

### Azure access required

Azure subscription access is required for `Delivery`, `TenantAccessControl`, and `All`. The signed-in identity must be able to select the subscription and perform these management-plane actions on the deployed resources:

| Operation used by the runner | Required Azure RBAC action | Recommended scope |
|---|---|---|
| Read the APIM subscription primary key | `Microsoft.ApiManagement/service/subscriptions/listSecrets/action` | The APIM service |
| Read the Storage Account key | `Microsoft.Storage/storageAccounts/listKeys/action` | The Storage Account |
| Read the APIM and Storage resource metadata | Corresponding resource `read` actions | The same resources or their resource group |

`Reader` alone is not sufficient because it does not grant either secret-listing action.

For a demo operator, a practical built-in-role combination is:

- `API Management Service Contributor` on the APIM service.
- `Reader and Data Access` on the Storage Account.

These roles are broader than the runner requires. For a production test identity, use a custom role containing only the listed actions and the necessary resource read actions, scoped to the deployed APIM service and Storage Account.

The runner uses the retrieved Storage Account shared key to peek queue messages. Consequently, no separate Storage Queue data-plane role is required by the current implementation. Treat both retrieved keys as credentials with privileged access; the runner holds them only in process memory and does not print or persist them.

The permissions above are for running tests, not deploying the solution. The deployment identity also needs permission to create all configured resources and role assignments. In a simple demo this is commonly `Contributor` plus `User Access Administrator` on the target resource group or subscription; `Owner` also covers both but is broader. It must also be allowed to purge the soft-deleted APIM service during `terraform destroy`.

| Test mode | Terraform output | Azure login | APIM `listSecrets` | Storage `listKeys` |
|---|---:|---:|---:|---:|
| `DirectAccess` | Required | No | No | No |
| `Delivery` | Required | Required | Required | Required |
| `TenantAccessControl` | Required | Required | Required | Required |
| `All` | Required | Required | Required | Required |

### Where the values come from

The runner does not maintain a second list of resources or credentials. `terraform-config.ps1` executes `terraform output -json deployment_config`, and `outputs.tf` builds that output from the applied resources.

| Value used by the runner | Source |
|---|---|
| Azure subscription ID | `var.azure_subscription_id`, exposed as `deployment_config.azure_subscription_id` |
| Resource group, APIM, Storage Account, and Event Grid domain names | Applied Terraform resources exposed through `deployment_config` |
| APIM gateway URL and API path | APIM resource name and API resource, exposed through `deployment_config` |
| Tenant IDs | Keys of `var.tenants`, exposed as keys of `deployment_config.tenant_queues` |
| Event Grid domain topic names | The same `var.tenants` keys; topic names are the tenant IDs |
| APIM subscription IDs | The same `var.tenants` keys; the policy compares this ID with the route tenant ID |
| Storage Queue names | `queue_name` in each `var.tenants` entry, exposed in `deployment_config.tenant_queues` |
| Event Grid event subscription names | `event_subscription_name` when supplied; otherwise `<tenant-id>-sub` |
| APIM subscription primary keys | Generated and stored by APIM, retrieved at runtime with the ARM `listSecrets` operation |

For example, the default `tenantA` entry creates topic `tenantA`, APIM subscription ID `tenantA`, queue `tenant-a-events`, and Event Grid subscription `tenantA-sub`. Terraform outputs the identifiers and endpoint data, but deliberately does not output APIM subscription keys.

## Guided Procedure

Start the interactive runner:

```powershell
.\test-solution.ps1 -Guided
```

1. At `Test`, press Enter to run `All`, or enter `Delivery`, `TenantAccessControl`, or `DirectAccess`.
2. At `Tenant`, press Enter for `all`, or enter one tenant or a comma-separated list.
3. Wait for the summary tables.
4. For `Delivery`, confirm HTTP `200`, the expected queue, and `APIM SECTION RESULT : PASS`.
5. For `TenantAccessControl` or `All`, confirm HTTP `200` for the authorized route, HTTP `403` for the cross-tenant route, and `APIM SECTION RESULT : PASS`.
6. For `DirectAccess` or `All`, confirm HTTP `401` or `403` and `EVENT GRID SECTION RESULT : PASS`.

Example successful complete run:

```text
==============================================================================
APIM PUBLISHING TESTS
==============================================================================
PATH           : Client -> APIM -> Event Grid -> tenant Storage Queue
AUTHENTICATION : Tenant APIM subscription key
EXPECTED       : Own tenant HTTP 200 | Different tenant HTTP 403

APIM SUBSCRIPTION ID : tenantA
	AUTHORIZED REQUEST : /tenantA -> HTTP 200 -> queue tenant-a-events
	CROSS-TENANT TEST  : /tenantB -> HTTP 403 ACCESS DENIED
	TENANT RESULT      : PASS

APIM SECTION RESULT : PASS
```

This row proves the critical boundary: the `tenantA` subscription key can publish to `tenantA`, but the same key receives access denied when it targets `tenantB`.

The following block is a different test. It bypasses APIM and sends no subscription key or Azure token directly to the Event Grid endpoint:

```text
==============================================================================
DIRECT EVENT GRID TESTS - APIM BYPASS PROTECTION
==============================================================================
PATH           : Anonymous client -> Event Grid directly (APIM is bypassed)
AUTHENTICATION : None; no APIM subscription key or Azure token
EXPECTED       : HTTP 401 or 403 for every tenant

Tenant  HTTP Expected   Result TestId
------  ---- --------   ------ ------
tenantA  401 401 or 403 PASS   <unique-test-id>
tenantB  401 401 or 403 PASS   <unique-test-id>
tenantC  401 401 or 403 PASS   <unique-test-id>

EVENT GRID SECTION RESULT : PASS
```

In this table, HTTP `401` or `403` is a passing result because anonymous direct access must be rejected. It must not be compared with the APIM tenant test above, where HTTP `200` means an authorized publish and HTTP `403` means cross-tenant access was denied.

## Automated Commands

Run all tests for every tenant configured in Terraform:

```powershell
.\test-solution.ps1
```

Run all tests for selected tenants:

```powershell
.\test-solution.ps1 -TenantId tenantA,tenantC
```

Run one scenario:

```powershell
.\test-solution.ps1 -Test Delivery -TenantId tenantA
.\test-solution.ps1 -Test TenantAccessControl -TenantId tenantA
.\test-solution.ps1 -Test DirectAccess -TenantId tenantA
```

## Quick Manual Test With curl

To publish one event manually through APIM, replace the placeholder values and run:

```powershell
curl.exe -i -X POST `
	"https://<apim-name>.azure-api.net/<api-path>/<tenant-id>" `
	-H "Content-Type: application/json" `
	-H "Ocp-Apim-Subscription-Key: <apim-subscription-key>" `
	-d '{"hello":"world"}'
```

Customize these values for the deployed environment and the tenant being tested:

| Placeholder | Example | Where to get it |
|---|---|---|
| `<apim-name>` | `apim-eventgrid-example` | `deployment_config.apim_name` from `terraform output -json deployment_config` |
| `<api-path>` | `events` | `deployment_config.api_path` from the same Terraform output |
| `<tenant-id>` | `tenantC` | One of the keys in `deployment_config.tenant_queues` |
| `<apim-subscription-key>` | `example-key-from-apim` | The primary or secondary key of the APIM subscription whose ID is `<tenant-id>` |
| JSON after `-d` | `{"hello":"world"}` | Any valid JSON payload required by the personal test |

The APIM subscription key and route tenant must belong to the same tenant. A matching key and tenant should return HTTP `200`. To verify tenant isolation, keep the same key but change `<tenant-id>` to another configured tenant; the expected result is HTTP `403 Forbidden`.

Do not commit a real key or include it in shared documentation. Supplying it directly in the command can also leave it in the local shell history.

### Retrieve the key without adding it to shell history

The following PowerShell example loads the applied values through `terraform-config.ps1`, retrieves the selected tenant key from APIM, and keeps it in an environment variable only for the duration of the request:

```powershell
. .\terraform-config.ps1
$config = Get-TerraformDeploymentConfig
$tenantId = "tenantC"
$apimBasePath = "/subscriptions/$($config.azure_subscription_id)/resourceGroups/$($config.resource_group_name)/providers/Microsoft.ApiManagement/service/$($config.apim_name)"
$subscriptionPath = "$apimBasePath/subscriptions/$tenantId/listSecrets?api-version=2024-05-01"
$secretResponse = Invoke-AzRestMethod -Method POST -Path $subscriptionPath -ErrorAction Stop
$env:APIM_SUBSCRIPTION_KEY = ($secretResponse.Content | ConvertFrom-Json).primaryKey

try {
	$gatewayUrl = $config.apim_gateway_url.TrimEnd("/")
	$apiPath = $config.api_path.Trim("/")
	curl.exe -i -X POST `
		"$gatewayUrl/$apiPath/$tenantId" `
		-H "Content-Type: application/json" `
		-H "Ocp-Apim-Subscription-Key: $env:APIM_SUBSCRIPTION_KEY" `
		-d '{"hello":"world"}'
}
finally {
	Remove-Item Env:APIM_SUBSCRIPTION_KEY -ErrorAction SilentlyContinue
}
```

Change only `$tenantId` to test another configured tenant. This procedure requires the Azure permissions described in [Azure access required](#azure-access-required).

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Test` | `All` | Scenario: `All`, `Delivery`, `TenantAccessControl`, or `DirectAccess` |
| `-TenantId` | `all` | All configured tenants, one tenant ID, or a comma-separated PowerShell array |
| `-AllTenants` | Off | Explicitly uses every tenant and ignores `-TenantId`; retained for compatibility |
| `-Guided` | Off | Prompts for the scenario and tenant selection |
| `-TimeoutSeconds` | `60` | Maximum queue-delivery wait, from 5 to 300 seconds |

`TenantAccessControl` requires at least two configured tenants. For each selected tenant, the runner chooses another configured tenant as the denied target.

### Tenant name validation

Tenant names are checked against `deployment_config.tenant_queues` before any Azure or HTTP request:

- Matching is case-insensitive, but the runner always normalizes the value to the exact spelling defined by Terraform. For example, `-TenantId TENANTA` runs as `tenantA`.
- Empty and unknown names are rejected with a `TENANT SELECTION ERROR` that lists all configured tenants.
- Repeated names with different capitalization are tested only once.
- The error exits with code `2`, so automation can distinguish invalid input from a failed functional test.

The default `all` selection is resolved from the applied Terraform output, so it automatically follows tenant-map changes. Use `-TenantId tenantA` when only one tenant should be tested.

## Troubleshooting

### Tenant selection error

Use one of the names displayed under `AVAILABLE`, without needing to match its capitalization exactly:

```powershell
.\test-solution.ps1 -Test DirectAccess -TenantId tenantA
```

If the expected tenant is not listed, update the Terraform tenant map, run `terraform apply`, and retry the test.

### Azure subscription mismatch

The runner stops if the active Azure context does not match Terraform:

```powershell
Set-AzContext -SubscriptionId "<expected-subscription-id>"
```

### Terraform output unavailable

Initialize and apply the workspace, then verify the output:

```powershell
terraform init
terraform apply
terraform output -json deployment_config
```

### APIM control-plane HTTP 401

APIM can return transient `401 Unauthorized` responses while reading subscription keys. The runner retries these responses five times with a short backoff. If all retries fail, confirm the Azure session and retry after refreshing it:

```powershell
Connect-AzAccount
Set-AzContext -SubscriptionId "<azure-subscription-id>"
```

### Queue delivery timeout

Retry with a longer timeout:

```powershell
.\test-solution.ps1 -Test Delivery -TenantId tenantA -TimeoutSeconds 180
```

If it still fails, verify the Event Grid subscription delivery status, destination queue, APIM managed identity, and `EventGrid Data Sender` role assignment.

## Exit Behavior

The runner exits successfully only when every selected test passes. Invalid tenant selection returns exit code `2`. Any unexpected HTTP response, subscription mismatch, unavailable configured resource, or queue timeout returns a nonzero exit code, making the command suitable for deployment pipelines.