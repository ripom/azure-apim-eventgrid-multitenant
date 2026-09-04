# Contributing

## Development Setup

Install Terraform 1.15.8, Azure CLI, and PowerShell 7. Use `az login` for local Terraform operations. For live automated tests, install the `Az.Accounts` and `Az.Storage` modules and authenticate their separate context with `Connect-AzAccount`.

Do not commit credentials, APIM keys, access tokens, `.tfvars`, Terraform state, or plan files.

## Making a Change

1. Keep tenant-specific configuration in the `tenants` map rather than adding policy branches.
2. Keep APIM authorization independent of the number of tenants.
3. Preserve existing Terraform resource addresses with `moved` blocks when refactoring. See the existing migration blocks in `eventgrid.tf` for the required pattern.
4. Update `README.md` and `SCALABILITY.md` when behavior or architecture changes.
5. Add or update a focused test for behavioral changes.

## Local Validation

Format and validate Terraform:

```powershell
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

Parse all PowerShell scripts without executing Azure operations:

```powershell
$failed = $false
Get-ChildItem -Filter '*.ps1' | ForEach-Object {
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    $_.FullName,
    [ref]$null,
    [ref]$errors
  ) | Out-Null

  if ($errors.Count -gt 0) {
    $failed = $true
    Write-Error "PowerShell syntax errors in $($_.Name): $($errors.Message -join '; ')"
  }
}
if ($failed) { exit 1 }
```

When Azure resources are available, run:

```powershell
.\test-solution.ps1
```

## Pull Requests

Describe:

- the behavior being changed;
- any Azure resources affected;
- whether Terraform plans replacements or deletions;
- the commands used for validation;
- any credential rotation or client migration required.

Never paste secrets or unredacted Terraform state into an issue, pull request, or CI log.

By participating, you agree to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). General usage questions follow [SUPPORT.md](SUPPORT.md); vulnerabilities must follow [SECURITY.md](SECURITY.md).
