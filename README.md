# AVD User-Assignment Report — Azure Automation Template

`Current-Reporting.ps1` is a **cleansed, generic template** for the FieldWork
AVD user-assignment reporting runbook, meant to be copied per customer. It's a
straight duplicate of `fw`'s working copy
(`customers/fw/reporting/Current-Reporting.ps1`) with every customer-specific
value (subscription ID, tenant ID, sender/recipient addresses, report name,
subject) reset back to placeholders.

It collects the users entitled to sign in to every Azure Virtual Desktop (AVD)
host pool across one or more subscriptions, builds a CSV, and emails it as an
attachment via Microsoft Graph — then deletes the CSV. It's built to run as an
**Azure Automation runbook** authenticating with the Automation Account's
**system-assigned managed identity** — no client secret, no Key Vault, nothing
to rotate. This only works for **single-tenant** deployments (the identity,
the subscriptions, and the tenant it reports on are all the same tenant); for
multi-tenant/MSP use, see `Email-AvdUserAssignments.ps1` / `-v2.ps1` in
`customers/fw/reporting/` instead, which use a portable service principal.

## Using this template for a new customer

1. Copy `Current-Reporting.ps1` into that customer's own scripts location
   (don't edit this template in place — keep it clean for the next customer).
2. Edit the **set-once defaults** near the top of the copy:
   - `$SubscriptionId` — subscription(s) to scan.
   - `$To` — report recipient(s).
   - `$Sender` — the mailbox to send as (must already exist in the tenant).
   - `$TenantId` — the customer's Entra tenant ID.
   - `$Name` / `$Subject` — optional, cosmetic (file name / email subject).
3. Follow the setup steps below to grant the Automation Account's managed
   identity the permissions it needs in the customer's tenant.
4. Test with `-HostPool '<one host pool>' -WhatIf` before scheduling for real
   (see [Testing](#testing-before-you-schedule-it) below).

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
        PowerShell/CLI, see below).
  - [ ] (Recommended) `Mail.Send` restricted to the sender mailbox via an
        Exchange **application access policy**.
- [ ] A **sender mailbox** that already exists in the tenant (a shared mailbox
      on a verified domain is ideal — free, can't be signed into).
- [ ] Outbound HTTPS to `management.azure.com` and `graph.microsoft.com` —
      automatic on the Azure-hosted sandbox; only a concern on a Hybrid
      Runbook Worker behind a restrictive firewall.

## Setup walkthrough

### 1. Create the Automation Account (skip if one already exists)

```powershell
New-AzResourceGroup -Name 'rg-<customer>-automation' -Location 'eastus'   # if needed

New-AzAutomationAccount `
    -ResourceGroupName 'rg-<customer>-automation' `
    -Name 'aa-<customer>-avd-reports' `
    -Location 'eastus' `
    -AssignSystemIdentity
```

`-AssignSystemIdentity` both creates the account and enables the
system-assigned managed identity in one step. If the account already exists
without an identity:

```powershell
Set-AzAutomationAccount -ResourceGroupName 'rg-<customer>-automation' `
    -Name 'aa-<customer>-avd-reports' -AssignSystemIdentity
```

Note the identity's **object ID** (principal ID) — needed for the Graph
app-role grant:

```powershell
$identity = (Get-AzAutomationAccount -ResourceGroupName 'rg-<customer>-automation' `
    -Name 'aa-<customer>-avd-reports').Identity
$identity.PrincipalId
```

### 2. Grant Azure RBAC Reader on each subscription

```powershell
foreach ($sub in @('<sub-guid-1>', '<sub-guid-2>')) {
    New-AzRoleAssignment `
        -ObjectId $identity.PrincipalId `
        -RoleDefinitionName 'Reader' `
        -Scope "/subscriptions/$sub"
}
```

`Reader` includes `Microsoft.Authorization/roleAssignments/read`, which the
script needs to read the "Desktop Virtualization User" assignments on each
application group.

### 3. Grant the Graph application permissions

A managed identity has no interactive consent flow — app roles are granted
directly to its service principal, using the **Microsoft Graph PowerShell
SDK** (a one-time bootstrap step run by an admin with
`RoleManagement.ReadWrite.Directory`, not something the runbook itself needs):

```powershell
Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'

# The managed identity's own service principal (same object ID as $identity.PrincipalId above)
$miSp = Get-MgServicePrincipal -ServicePrincipalId '<identity-object-id>'

# Microsoft Graph's own service principal - source of the app roles being granted
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

$roles = 'User.Read.All', 'GroupMember.Read.All', 'Mail.Send'
foreach ($roleName in $roles) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName -and $_.AllowedMemberTypes -contains 'Application' }
    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $miSp.Id `
        -PrincipalId        $miSp.Id `
        -ResourceId         $graphSp.Id `
        -AppRoleId          $appRole.Id
}
```

(`Directory.Read.All` in place of `User.Read.All` + `GroupMember.Read.All` is
the same idea — grant whichever pair the customer's security team prefers.)

Verify what's granted:

```powershell
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miSp.Id |
    Select-Object AppRoleId, ResourceDisplayName
```

### 4. Lock `Mail.Send` to the sender mailbox (recommended)

Otherwise the identity can send as *any* mailbox in the tenant:

```powershell
New-ApplicationAccessPolicy -AppId '<identity-app-id-not-object-id>' `
    -PolicyScopeGroupId '<sender-mailbox>' `
    -AccessRight RestrictAccess `
    -Description 'Limit AVD report managed identity to the reports mailbox'
```

> `New-ApplicationAccessPolicy` (Exchange Online PowerShell) keys off the
> **application (client) ID**, not the object ID:
> `(Get-MgServicePrincipal -ServicePrincipalId $miSp.Id).AppId`.

### 5. Import the runbook

```powershell
Import-AzAutomationRunbook `
    -ResourceGroupName 'rg-<customer>-automation' `
    -AutomationAccountName 'aa-<customer>-avd-reports' `
    -Name 'Current-Reporting' `
    -Type PowerShell72 `
    -Path './Current-Reporting.ps1'

Publish-AzAutomationRunbook `
    -ResourceGroupName 'rg-<customer>-automation' `
    -AutomationAccountName 'aa-<customer>-avd-reports' `
    -Name 'Current-Reporting'
```

Edit the set-once defaults in your customer copy before importing, or pass
them as runbook input parameters at publish/schedule time instead of
hardcoding.

### Testing before you schedule it

Run the runbook once manually (or `Start-AzAutomationRunbook -Wait`) against a
**single host pool** with `-WhatIf`, so the first live-tenant test doesn't
write a CSV or send mail:

```powershell
Start-AzAutomationRunbook `
    -ResourceGroupName 'rg-<customer>-automation' `
    -AutomationAccountName 'aa-<customer>-avd-reports' `
    -Name 'Current-Reporting' `
    -Parameters @{ HostPool = 'hp-customer-prod-01'; WhatIf = $true } `
    -Wait
```

Check the job output stream for the `[WhatIf] Preview only` block and confirm
the row-by-row user list looks right before removing `-WhatIf` and widening to
all host pools.

### 6. Schedule it

```powershell
$schedule = New-AzAutomationSchedule `
    -ResourceGroupName 'rg-<customer>-automation' `
    -AutomationAccountName 'aa-<customer>-avd-reports' `
    -Name 'Weekly-AVD-Report' `
    -StartTime (Get-Date).Date.AddDays(1).AddHours(7) `
    -WeekInterval 1 `
    -DaysOfWeek Monday

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName 'rg-<customer>-automation' `
    -AutomationAccountName 'aa-<customer>-avd-reports' `
    -RunbookName 'Current-Reporting' `
    -ScheduleName 'Weekly-AVD-Report'
```

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
customer tenants still needs an SPN (see `Email-AvdUserAssignments.ps1` /
`-v2.ps1`).

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `Failed to authenticate as the managed identity …` | No system-/user-assigned identity enabled on the Automation Account, or `Az.Accounts` unavailable in the runtime. |
| `… still hold placeholder values …` | A set-once default wasn't edited before import/run. |
| Tokens acquired but `Unique users (rows) : 0` and `Graph GET failed` warnings | Identity missing Graph directory-read permission (`User.Read.All` / `GroupMember.Read.All` / `Directory.Read.All`). |
| `Failed to list AVD resources` | Identity missing Azure `Reader` on the subscription. |
| `Email failed: … ErrorInvalidUser` / mailbox not found | `-Sender` doesn't exist in the tenant, isn't mailbox-enabled, or is on an unverified domain. |
