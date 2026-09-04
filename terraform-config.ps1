function Get-TerraformDeploymentConfig {
    [CmdletBinding()]
    param()

    $terraformArguments = @(
        "-chdir=$PSScriptRoot"
        "output"
        "-json"
        "deployment_config"
    )

    $output = & terraform @terraformArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Terraform deployment_config. Run 'terraform apply' first. $($output -join ' ')"
    }

    try {
        return ($output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Terraform deployment_config is not valid JSON: $($_.Exception.Message)"
    }
}