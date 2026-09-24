# AVD User-Assignment Report — Azure Automation Template

`UserAssignmentsReporting-Runbook.ps1` is a **cleansed, generic, field-tested
template** for an AVD user-assignment reporting runbook, meant to be copied
per customer, with every customer-specific value (subscription ID, tenant ID,
sender/recipient addresses, report name, subject) reset back to placeholders.

It collects the users entitled to sign in to every Azure Virtual Desktop (AVD)
host pool across one or more subscriptions, builds a CSV, and emails it as an
attachment via Microsoft Graph — then deletes the CSV. It's built to run as an
**Azure Automation runbook** authenticating with the Automation Account's
**system-assigned managed identity** — no client secret, no Key Vault, nothing
to rotate. This only works for **single-tenant** deployments (the identity,
the subscriptions, and the tenant it reports on are all the same tenant); a
multi-tenant/MSP deployment would instead need a portable service principal.

## Files

- `New-AutomationAccount.ps1` — creates the Automation Account and grants its
  managed identity **Azure RBAC `Reader`** (ARM plane).
- `Add-Mi-Permissions.ps1` — grants the managed identity its **Microsoft
  Graph** application permissions (Graph plane).
- `UserAssignmentsReporting-Runbook.ps1` — the runbook itself.

## Using this template for a new customer

1. Copy `UserAssignmentsReporting-Runbook.ps1` into that customer's own scripts location
   (don't edit this template in place — keep it clean for the next customer).
2. Edit the **set-once defaults** near the top of the copy:
   - `$SubscriptionId` — subscription(s) to scan.
   - `$To` — report recipient(s).
   - `$Sender` — the mailbox to send as (must already exist in the tenant).
   - `$TenantId` — the customer's Entra tenant ID.
   - `$Name` / `$Subject` — optional, cosmetic (file name / email subject).
3. Grant the Automation Account's managed identity the permissions it needs
   in the customer's tenant (see the prerequisites checklist below).
4. Test with `-HostPool '<one host pool>' -WhatIf` before scheduling for real.

## Prerequisites checklist

- [ ] An Azure Automation Account exists in the customer's tenant/subscription.
- [ ] It runs on the **PowerShell 7.2 runtime** (has `Az.Accounts`
      preinstalled — needed to mint tokens for the managed identity).
- [ ] **System-assigned managed identity** is enabled on the Automation
      Account.
- [ ] That identity has been granted:
  - [ ] **Azure RBAC `Reader`** on every subscription being scanned.
  - [ ] **Microsoft Graph application permissions** `User.Read.All` +
        `GroupMember.Read.All` (or `Directory.Read.All`), and `Mail.Send`,
        assigned directly to the identity's service principal (there's no
        admin-consent screen for a managed identity — you grant app roles via
        PowerShell/CLI, see `Add-Mi-Permissions.ps1`).
  - [ ] (Recommended) `Mail.Send` restricted to the sender mailbox via an
        Exchange **application access policy**.
- [ ] A **sender mailbox** that already exists in the tenant (a shared mailbox
      on a verified domain is ideal — free, can't be signed into).
- [ ] Outbound HTTPS to `management.azure.com` and `graph.microsoft.com` —
      automatic on the Azure-hosted sandbox; only a concern on a Hybrid
      Runbook Worker behind a restrictive firewall.

## Parameters

| Parameter                      | Required | Default                                    | Notes |
|---------------------------------|----------|--------------------------------------------|-------|
| `-SubscriptionId`                | yes      | *(set-once placeholder)*                    | One or more subscription IDs to scan. |
| `-To`                            | yes      | *(set-once placeholder)*                    | Recipient(s); can be external. |
| `-Sender`                        | yes      | *(set-once placeholder)*                    | Mailbox to send AS; must exist in the tenant. |
| `-TenantId`                      | yes      | *(set-once placeholder)*                    | Target Entra tenant ID. |
| `-Name`                          | no       | `Customer`                                  | Label embedded in the output file name. |
| `-RoleDefinitionId`              | no       | `1d18fff3-…` (Desktop Virtualization User)  | Pass `""` to include all roles. |
| `-HostPool`                      | no       | *(empty = all)*                             | Limit to specific host pool(s) by name; combine with `-WhatIf` for testing. |
| `-Subject`                       | no       | *(auto)* `AVD Users report - <Name> - <date>` | Email subject; set to override. |
| `-BodyFooter`                    | no       | `This is an automated message …`            | Footer/signature line; set `""` to omit. |
| `-WhatIf`                        | no       | `$false`                                    | Dry run — collects and previews, writes/sends nothing. |
| `-UserAssignedIdentityClientId`  | no       | *(empty = system-assigned)*                 | Client ID of a user-assigned identity, if used instead. |

A guard at the top of the script stops the run with a clear message if
`SubscriptionId`/`To`/`Sender`/`TenantId` are left at their placeholder
values.

## Why managed identity instead of an SPN + secret

| | SPN + client secret | Managed identity (this template) |
|---|---|---|
| Secret to store | Yes — packed credential or Key Vault | **None** |
| Secret to rotate | Yes (SPN secrets expire) | **None** |
| Where it can authenticate | Any tenant | Only its own tenant |
| Extra infrastructure | Key Vault (recommended) | None beyond the Automation Account |

A managed identity can't be exfiltrated as a credential (there's no secret
value to copy), can't be checked into a script or command line, and never
expires. The only reason not to use it is a **multi-tenant** scenario — a
managed identity cannot cross tenant boundaries, so an MSP reporting across
customer tenants would instead need a portable service principal.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `Failed to authenticate as the managed identity …` | No system-/user-assigned identity enabled on the Automation Account, or `Az.Accounts` unavailable in the runtime. |
| `… still hold placeholder values …` | A set-once default wasn't edited before import/run. |
| Tokens acquired but `Unique users (rows) : 0` and `Graph GET failed` warnings | Identity missing Graph directory-read permission (`User.Read.All` / `GroupMember.Read.All` / `Directory.Read.All`). |
| `Failed to list AVD resources` | Identity missing Azure `Reader` on the subscription. |
| `Email failed: … ErrorInvalidUser` / mailbox not found | `-Sender` doesn't exist in the tenant, isn't mailbox-enabled, or is on an unverified domain. |
