[CmdletBinding()]
param(
    [ValidateSet("All", "Delivery", "TenantAccessControl", "DirectAccess")]
    [string]$Test = "All",

    [string[]]$TenantId = @("all"),

    [switch]$AllTenants,

    [switch]$Guided,

    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\terraform-config.ps1"

function Resolve-TenantSelection {
    param(
        [Parameter(Mandatory)]
        [string[]]$RequestedTenants,

        [Parameter(Mandatory)]
        [string[]]$AvailableTenants
    )

    if ($AvailableTenants.Count -eq 0) {
        throw "Terraform deployment_config does not contain any tenants. Verify the tenants map and run terraform apply."
    }

    $canonicalTenants = @{}
    foreach ($availableTenant in $AvailableTenants) {
        if ($canonicalTenants.ContainsKey($availableTenant)) {
            throw "Terraform deployment_config contains tenant names that differ only by capitalization. Tenant IDs must be unique regardless of case."
        }
        $canonicalTenants[$availableTenant] = $availableTenant
    }

    $resolvedTenants = [System.Collections.Generic.List[string]]::new()
    $unknownTenants = [System.Collections.Generic.List[string]]::new()
    $seenTenants = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($requestedTenant in $RequestedTenants) {
        $candidate = if ($null -eq $requestedTenant) { "" } else { $requestedTenant.Trim() }
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not $canonicalTenants.ContainsKey($candidate)) {
            $unknownTenants.Add($(if ($candidate) { $candidate } else { "<empty>" }))
            continue
        }

        $canonicalTenant = $canonicalTenants[$candidate]
        if ($seenTenants.Add($canonicalTenant)) {
            $resolvedTenants.Add($canonicalTenant)
        }

        if ($candidate -cne $canonicalTenant) {
            Write-Information "[TenantSelection] Normalized '$candidate' to '$canonicalTenant'." -InformationAction Continue
        }
    }

    if ($unknownTenants.Count -gt 0) {
        throw "Unknown tenant(s): $($unknownTenants -join ', '). Available tenants: $($AvailableTenants -join ', ')."
    }

    return $resolvedTenants.ToArray()
}

function Assert-Prerequisite {
    param(
        [switch]$RequireAzure
    )

    if ($null -eq (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw "Terraform is not available in PATH."
    }

    if (-not $RequireAzure) {
        return
    }

    foreach ($moduleName in "Az.Accounts", "Az.Storage") {
        if ($null -eq (Get-Module -ListAvailable -Name $moduleName)) {
            throw "Required PowerShell module '$moduleName' is not installed."
        }
    }

    if ($null -eq (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw "No Azure context is active. Run Connect-AzAccount first."
    }
}

function Assert-AzRestSuccess {
    param(
        [Parameter(Mandatory)]
        $Response,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    $statusCode = [int]$Response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        throw "$Operation failed (HTTP $statusCode): $($Response.Content)"
    }
}

function Get-ApimSubscriptionKey {
    param(
        [Parameter(Mandatory)]
        [string]$ApimBasePath,

        [Parameter(Mandatory)]
        [string]$Tenant
    )

    $attempt = 0
    do {
        $attempt++
        try {
            $response = Invoke-AzRestMethod `
                -Method POST `
                -Path "$ApimBasePath/subscriptions/$Tenant/listSecrets?api-version=2024-05-01"
            Assert-AzRestSuccess -Response $response -Operation "Reading APIM key for '$Tenant'"
            return ($response.Content | ConvertFrom-Json).primaryKey
        }
        catch {
            if ($attempt -ge 5 -or $_.Exception.Message -notmatch "401|Unauthorized") {
                throw
            }

            Start-Sleep -Seconds ([Math]::Min($attempt * 2, 10))
        }
    } while ($true)
}

function ConvertFrom-QueueMessageBody {
    param(
        [Parameter(Mandatory)]
        $Body
    )

    $encodedBody = $Body.ToString()
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedBody))
    }
    catch [FormatException] {
        return $encodedBody
    }
}

function ConvertTo-TestBody {
    param(
        [Parameter(Mandatory)]
        [string]$TestId,

        [Parameter(Mandatory)]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$Scenario
    )

    return @{
        testId  = $TestId
        tenant  = $Tenant
        scenario = $Scenario
        message = "$Tenant $Scenario test"
        sentAt  = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json
}

function Get-HttpErrorStatus {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($null -eq $ErrorRecord.Exception.Response) {
        return 0
    }

    return [int]$ErrorRecord.Exception.Response.StatusCode
}

function Wait-ForQueueEvent {
    param(
        [Parameter(Mandatory)]
        $Queue,

        [Parameter(Mandatory)]
        [string]$TestId,

        [Parameter(Mandatory)]
        [int]$Timeout
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        foreach ($message in $Queue.QueueClient.PeekMessages(32).Value) {
            try {
                $receivedEvent = (ConvertFrom-QueueMessageBody -Body $message.Body) | ConvertFrom-Json
            }
            catch {
                continue
            }

            if ($receivedEvent.data.testId -eq $TestId) {
                return $receivedEvent
            }
        }

        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Event $TestId was not delivered within $Timeout seconds."
}

function Invoke-DeliveryTest {
    param(
        [Parameter(Mandatory)]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$SubscriptionKey,

        [Parameter(Mandatory)]
        $Queue,

        [Parameter(Mandatory)]
        [string]$QueueName,

        [Parameter(Mandatory)]
        [string]$RequestUrl,

        [Parameter(Mandatory)]
        [int]$Timeout
    )

    $testId = [Guid]::NewGuid().ToString()
    Write-Information "[Delivery][$Tenant] Publishing $testId..." -InformationAction Continue
    $response = Invoke-WebRequest `
        -Method POST `
        -Uri $RequestUrl `
        -Headers @{ "Ocp-Apim-Subscription-Key" = $SubscriptionKey } `
        -ContentType "application/json" `
        -Body (ConvertTo-TestBody -TestId $testId -Tenant $Tenant -Scenario "delivery")

    $deliveredEvent = Wait-ForQueueEvent -Queue $Queue -TestId $testId -Timeout $Timeout
    return [pscustomobject]@{
        Test       = "Delivery"
        Tenant     = $Tenant
        Success    = $true
        HttpStatus = [int]$response.StatusCode
        Queue      = $QueueName
        TestId     = $testId
        EventType  = $deliveredEvent.eventType
    }
}

function Invoke-IsolationTest {
    param(
        [Parameter(Mandatory)]
        [string]$Tenant,

        [Parameter(Mandatory)]
        [string]$DeniedTenant,

        [Parameter(Mandatory)]
        [string]$SubscriptionKey,

        [Parameter(Mandatory)]
        [string]$GatewayBaseUrl
    )

    $testId = [Guid]::NewGuid().ToString()
    Write-Information "[TenantAccessControl][$Tenant] Reusing the same key against '$DeniedTenant'..." -InformationAction Continue
    try {
        $response = Invoke-WebRequest `
            -Method POST `
            -Uri "$GatewayBaseUrl/$DeniedTenant" `
            -Headers @{ "Ocp-Apim-Subscription-Key" = $SubscriptionKey } `
            -ContentType "application/json" `
            -Body (ConvertTo-TestBody -TestId $testId -Tenant $DeniedTenant -Scenario "tenant-isolation")
        throw "Tenant isolation failed: request was accepted with HTTP $($response.StatusCode)."
    }
    catch {
        if ($_.Exception.Message -like "Tenant isolation failed:*") {
            throw
        }

        $statusCode = Get-HttpErrorStatus -ErrorRecord $_
        if ($statusCode -ne 403) {
            throw "Tenant isolation failed: expected HTTP 403, received HTTP $statusCode."
        }
    }

    return [pscustomobject]@{
        Test          = "TenantAccessControl"
        Tenant        = $Tenant
        DeniedTenant  = $DeniedTenant
        Success       = $true
        HttpStatus    = 403
        TestId        = $testId
    }
}

function Invoke-DirectAccessTest {
    param(
        [Parameter(Mandatory)]
        [string]$Tenant,

        [Parameter(Mandatory)]
        $Config
    )

    $testId = [Guid]::NewGuid().ToString()
    $requestBody = @(
        @{
            id          = $testId
            eventType   = $Config.event_type
            subject     = "/direct-test/$Tenant"
            eventTime   = [DateTime]::UtcNow.ToString("o")
            data        = @{ testId = $testId }
            dataVersion = $Config.event_data_version
            topic       = $Tenant
        }
    ) | ConvertTo-Json -Depth 10

    Write-Information "[DirectAccess][$Tenant] Attempting anonymous publish..." -InformationAction Continue
    try {
        $response = Invoke-WebRequest `
            -Method POST `
            -Uri $Config.eventgrid_endpoint `
            -ContentType "application/json" `
            -Body $requestBody
        throw "Direct access test failed: request was accepted with HTTP $($response.StatusCode)."
    }
    catch {
        if ($_.Exception.Message -like "Direct access test failed:*") {
            throw
        }

        $statusCode = Get-HttpErrorStatus -ErrorRecord $_
        if ($statusCode -notin 401, 403) {
            throw "Direct access test failed: expected HTTP 401 or 403, received HTTP $statusCode."
        }
    }

    return [pscustomobject]@{
        Test           = "DirectAccess"
        Tenant         = $Tenant
        Success        = $true
        HttpStatus     = $statusCode
        Authentication = "None"
        TestId          = $testId
    }
}

Assert-Prerequisite
$config = Get-TerraformDeploymentConfig
$configuredTenants = @($config.tenant_queues.PSObject.Properties.Name)

if ($Guided) {
    Write-Information "Available tests: All, Delivery, TenantAccessControl, DirectAccess" -InformationAction Continue
    $selectedTest = Read-Host "Test [$Test]"
    if (-not [string]::IsNullOrWhiteSpace($selectedTest)) {
        if ($selectedTest -notin "All", "Delivery", "TenantAccessControl", "DirectAccess") {
            throw "Unknown test '$selectedTest'."
        }
        $Test = $selectedTest
    }

    Write-Information "Configured tenants: $($configuredTenants -join ', ')" -InformationAction Continue
    $selectedTenant = Read-Host "Tenant, comma-separated list, or 'all' [$($TenantId -join ',')]"
    if ($selectedTenant -eq "all") {
        $AllTenants = $true
    }
    elseif (-not [string]::IsNullOrWhiteSpace($selectedTenant)) {
        $TenantId = @($selectedTenant -split "," | ForEach-Object { $_.Trim() })
    }
}

$selectAllTenants = $AllTenants -or ($TenantId.Count -eq 1 -and $TenantId[0].Trim() -eq "all")
$requestedTenants = if ($selectAllTenants) { $configuredTenants } else { @($TenantId) }
try {
    $selectedTenants = @(Resolve-TenantSelection `
            -RequestedTenants $requestedTenants `
            -AvailableTenants $configuredTenants)
}
catch {
    Write-Information "`n==============================================================================" -InformationAction Continue
    Write-Information "TENANT SELECTION ERROR" -InformationAction Continue
    Write-Information "==============================================================================" -InformationAction Continue
    Write-Information "REQUESTED : $($requestedTenants -join ', ')" -InformationAction Continue
    Write-Information "AVAILABLE : $($configuredTenants -join ', ')" -InformationAction Continue
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 2
}

if ($Test -in "All", "TenantAccessControl" -and $configuredTenants.Count -lt 2) {
    throw "TenantAccessControl requires at least two configured tenants."
}

$testDescription = switch ($Test) {
    "All" { "APIM publishing and tenant isolation plus direct Event Grid bypass denial" }
    "Delivery" { "publish to the subscription tenant and verify queue delivery" }
    "TenantAccessControl" { "same key: own tenant allowed, different tenant denied" }
    "DirectAccess" { "anonymous direct Event Grid access denied" }
}
Write-Information "`nTEST PLAN" -InformationAction Continue
Write-Information "Scenario : $Test - $testDescription" -InformationAction Continue
Write-Information "Tenants  : $($selectedTenants -join ', ')" -InformationAction Continue

$gatewayBaseUrl = "$($config.apim_gateway_url.TrimEnd('/'))/$($config.api_path.Trim('/'))"
$apimBasePath = "/subscriptions/$($config.azure_subscription_id)/resourceGroups/$($config.resource_group_name)/providers/Microsoft.ApiManagement/service/$($config.apim_name)"
$accessControlResults = [System.Collections.Generic.List[object]]::new()
$deliveryResults = [System.Collections.Generic.List[object]]::new()
$directAccessResults = [System.Collections.Generic.List[object]]::new()

$needsApim = $Test -in "All", "Delivery", "TenantAccessControl"
if ($needsApim) {
    Assert-Prerequisite -RequireAzure
    $context = Get-AzContext
    if ($context.Subscription.Id -ne $config.azure_subscription_id) {
        throw "Azure context uses subscription '$($context.Subscription.Id)', expected '$($config.azure_subscription_id)'."
    }

    $storageKey = (Get-AzStorageAccountKey `
        -ResourceGroupName $config.resource_group_name `
        -Name $config.storage_account_name)[0].Value
    $storageContext = New-AzStorageContext `
        -StorageAccountName $config.storage_account_name `
        -StorageAccountKey $storageKey
}

foreach ($tenant in $selectedTenants) {
    if ($needsApim) {
        $subscriptionKey = Get-ApimSubscriptionKey -ApimBasePath $apimBasePath -Tenant $tenant
        $queueName = $config.tenant_queues.PSObject.Properties[$tenant].Value
        $queue = Get-AzStorageQueue -Name $queueName -Context $storageContext

        $deliveryResult = Invoke-DeliveryTest `
            -Tenant $tenant `
            -SubscriptionKey $subscriptionKey `
            -Queue $queue `
            -QueueName $queueName `
            -RequestUrl "$gatewayBaseUrl/$tenant" `
            -Timeout $TimeoutSeconds

        if ($Test -eq "Delivery") {
            $deliveryResults.Add($deliveryResult)
        }
    }

    if ($Test -in "All", "TenantAccessControl") {
        $deniedTenant = $configuredTenants | Where-Object { $_ -ne $tenant } | Select-Object -First 1
        $isolationResult = Invoke-IsolationTest `
            -Tenant $tenant `
            -DeniedTenant $deniedTenant `
            -SubscriptionKey $subscriptionKey `
            -GatewayBaseUrl $gatewayBaseUrl

        $accessControlResults.Add([pscustomobject]@{
            SubscriptionTenant = $tenant
            AllowedTarget      = $tenant
            AllowedStatus      = $deliveryResult.HttpStatus
            DeliveredQueue     = $deliveryResult.Queue
            DeniedTarget       = $deniedTenant
            DeniedStatus       = $isolationResult.HttpStatus
            Result             = "PASS"
        })
    }

    if ($Test -in "All", "DirectAccess") {
        $directAccessResults.Add((Invoke-DirectAccessTest -Tenant $tenant -Config $config))
    }
}

if ($accessControlResults.Count -gt 0) {
    Write-Information "`n==============================================================================" -InformationAction Continue
    Write-Information "APIM PUBLISHING TESTS" -InformationAction Continue
    Write-Information "==============================================================================" -InformationAction Continue
    Write-Information "PATH           : Client -> APIM -> Event Grid -> tenant Storage Queue" -InformationAction Continue
    Write-Information "AUTHENTICATION : Tenant APIM subscription key" -InformationAction Continue
    Write-Information "VERIFIES       : Own tenant is accepted and delivered; another tenant is denied" -InformationAction Continue
    Write-Information "EXPECTED       : Own tenant HTTP 200 | Different tenant HTTP 403" -InformationAction Continue
    foreach ($result in $accessControlResults) {
        Write-Information "`nAPIM SUBSCRIPTION ID : $($result.SubscriptionTenant)" -InformationAction Continue
        Write-Information "  AUTHORIZED REQUEST : /$($result.AllowedTarget) -> HTTP $($result.AllowedStatus) -> queue $($result.DeliveredQueue)" -InformationAction Continue
        Write-Information "  CROSS-TENANT TEST  : /$($result.DeniedTarget) -> HTTP $($result.DeniedStatus) ACCESS DENIED" -InformationAction Continue
        Write-Information "  TENANT RESULT      : $($result.Result)" -InformationAction Continue
    }
    Write-Information "`nAPIM SECTION RESULT : PASS" -InformationAction Continue
}

if ($deliveryResults.Count -gt 0) {
    Write-Information "`n==============================================================================" -InformationAction Continue
    Write-Information "APIM PUBLISHING TESTS" -InformationAction Continue
    Write-Information "==============================================================================" -InformationAction Continue
    Write-Information "PATH           : Client -> APIM -> Event Grid -> tenant Storage Queue" -InformationAction Continue
    Write-Information "AUTHENTICATION : Tenant APIM subscription key" -InformationAction Continue
    Write-Information "EXPECTED       : HTTP 200 and matching event delivered to the tenant queue`n" -InformationAction Continue
    $deliveryResults | Select-Object Tenant, HttpStatus, Queue, EventType, TestId | Format-Table -AutoSize
    Write-Information "APIM SECTION RESULT : PASS" -InformationAction Continue
}

if ($directAccessResults.Count -gt 0) {
    Write-Information "`n==============================================================================" -InformationAction Continue
    Write-Information "DIRECT EVENT GRID TESTS - APIM BYPASS PROTECTION" -InformationAction Continue
    Write-Information "==============================================================================" -InformationAction Continue
    Write-Information "PATH           : Anonymous client -> Event Grid directly (APIM is bypassed)" -InformationAction Continue
    Write-Information "AUTHENTICATION : None; no APIM subscription key or Azure token" -InformationAction Continue
    Write-Information "VERIFIES       : Event Grid cannot be used as an anonymous back door" -InformationAction Continue
    Write-Information "EXPECTED       : HTTP 401 or 403 for every tenant" -InformationAction Continue
    $directAccessResults |
        Select-Object `
            Tenant,
            @{ Name = "HTTP"; Expression = { $_.HttpStatus } },
            @{ Name = "Expected"; Expression = { "401 or 403" } },
            @{ Name = "Result"; Expression = { "PASS" } },
            TestId |
        Format-Table -AutoSize
    Write-Information "EVENT GRID SECTION RESULT : PASS" -InformationAction Continue
}

Write-Information "`n==============================================================================" -InformationAction Continue
Write-Information "OVERALL RESULT: PASS - All selected tests completed successfully." -InformationAction Continue
Write-Information "==============================================================================" -InformationAction Continue