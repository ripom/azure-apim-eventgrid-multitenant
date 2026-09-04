# Security Policy

## Reporting a Vulnerability

Do not open a public issue containing credentials, tenant data, Terraform state, access tokens, or vulnerability details that could enable abuse.

Use the repository's **Security** tab and select **Report a vulnerability** to submit the report through GitHub Private Vulnerability Reporting. Include only the minimum information required to reproduce the issue. If private reporting is unavailable, do not publish exploit details or secrets in a public issue; use GitHub to contact the repository owner and request a private reporting channel.

This is a demonstration project maintained on a best-effort basis. No response or remediation service-level agreement is provided.

## Credential Handling

- Never commit APIM subscription keys, Event Grid keys, client secrets, access tokens, `.tfvars`, or Terraform state.
- Treat Terraform state as sensitive because it can contain generated APIM keys and Azure resource metadata.
- Store production secrets in Azure Key Vault or GitHub Actions secrets.
- Prefer managed identity or workload identity federation over long-lived client secrets.
- Rotate a credential immediately if it appears in source control, chat, logs, or command history shared with others.
- Restrict access to APIM `listSecrets` operations.

## Trust Boundaries

The client authenticates to APIM. APIM authorizes the logical tenant before using its managed identity to publish to Event Grid. Event Grid sees APIM as the technical publisher, so cross-tenant authorization must complete before the policy executes `send-request`.

Direct anonymous Event Grid publishing is expected to return HTTP `401` or `403`; either response demonstrates that anonymous publishing was rejected. Azure identities with an explicit `EventGrid Data Sender` role may publish directly by design.

## Production Hardening

The proof of concept keeps public network connectivity enabled for APIM, Event Grid, and Storage. Public reachability does not grant anonymous resource access: Event Grid requires Microsoft Entra authentication and RBAC, anonymous public access to nested Storage resources is disabled, and Storage Queue access requires authorization. Storage shared-key authorization remains enabled for the included delivery tests.

Before production use, apply network restrictions, replace shared-key test access with least-privilege Microsoft Entra authorization, use a remote encrypted Terraform backend with access controls and locking, configure monitoring and alerting, and perform an independent threat-model and compliance review.

## Supported Versions

Security fixes are applied to the latest version on the default branch on a best-effort basis; no older release branches are maintained.
