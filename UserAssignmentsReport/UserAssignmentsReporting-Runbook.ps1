<#
.SYNOPSIS
    Collects the users assigned to every AVD host pool across one or more 
    subscriptions AND emails the resulting CSV via Microsoft Graph (sendMail). 
    Designed to run as an Azure Automation runbook using the Automation Account's
    SYSTEM-ASSIGNED MANAGED IDENTITY - no client secret, no Key Vault, 
    so there is nothing to rotate. Applying necessary permissions to the Automation
    Account Managed Identity is out of scope for this script. The CLI must be used
    to grant such permissions, as they are not available for MI's in the Portal UI.

.DESCRIPTION
    Same collection logic as Email-AvdUserAssignments.ps1 (see that script's
    README for the full algorithm), but built for single-tenant Azure
    Automation instead of Hydra/AVD session hosts:

      * Authenticates with `Connect-AzAccount -Identity` (the Automation
        Account's system-assigned managed identity) instead of an app
        registration + client secret.
      * Gets ARM and Graph access tokens for that identity via
        `Get-AzAccessToken -ResourceUrl`.
      * Still uses only `Invoke-RestMethod` for the actual data calls (ARM +
        Graph REST) - the `Az.Accounts` module is used purely to obtain tokens
        for the managed identity, which is preinstalled in the Automation
        PowerShell 7.2 runtime.
      * There is no -ClientId / -ClientSecret / -ServiceAccountCredential /
        -CredentialIndex here - identity is fixed to "whatever managed
        identity this Automation Account/runbook is running as." This is only
        appropriate for SINGLE-TENANT use (the identity lives in, and can only
        be granted permissions in, its own tenant). For a multi-tenant / MSP
        scenario, use Email-AvdUserAssignments.ps1 or -v2.ps1 instead.
      * Logging goes through plain Write-Output (INFO/STEP/OK/WARN/ERROR - all
        land in the Automation job's output stream) and Write-Verbose (DEBUG -
        visible with -Verbose or "Log verbose records" enabled on the job).
        There is no Hydra OutputWriter/LogWriter dependency.

    For each subscription it:
      1. Lists every AVD host pool (ARM).
      2. Lists application groups and matches them to host pools by ARM path.
      3. Reads role assignments on each application group and keeps those for
         the "Desktop Virtualization User" role (by role-definition GUID).
      4. Resolves each assigned principal via Graph: users directly, groups via
         transitiveMembers (nested groups expanded server-side).
      5. Collapses to one row per user with host pools comma-separated, writes
         a CSV, and emails it as an attachment.

    Required permissions:
      - Azure RBAC: Reader (+ Microsoft.Authorization/roleAssignments/read) on
        each subscription, granted to the Automation Account's managed
        identity.
      - Microsoft Graph APPLICATION permissions, granted directly to the
        managed identity's service principal (via New-MgServicePrincipalAppRoleAssignment
        or equivalent - there is no consent-screen flow for a managed
        identity): User.Read.All + GroupMember.Read.All (or Directory.Read.All),
        and Mail.Send. Lock Mail.Send to the sender mailbox with an application
        access policy, same as the SPN-based scripts.

.PARAMETER SubscriptionId
    One or more subscription IDs to scan.

.PARAMETER To
    One or more recipient addresses. Can be external.

.PARAMETER Sender
    Mailbox to send AS. Must already exist in the tenant on a verified domain
    (a shared mailbox is ideal).

.PARAMETER TenantId
    Entra tenant ID of the tenant this Automation Account (and its managed
    identity) lives in. Also used to disambiguate Connect-AzAccount if the
    identity has visibility into more than one tenant.

.PARAMETER Name
    Label embedded in the output file name. Defaults to 'Customer'.

.PARAMETER RoleDefinitionId
    Role-definition GUID that grants sign-in entitlement. Defaults to the
    built-in "Desktop Virtualization User" role. Pass "" to include all roles.

.PARAMETER HostPool
    Optional. One or more host pool names to test against, instead of every
    host pool in the subscription(s). Matches either the ARM resource name or
    the AVD friendly name (case-insensitive). Combine with -WhatIf to do a
    quick, read-only test run against a single host pool. Leave empty (default)
    to process every host pool.

.PARAMETER UserAssignedIdentityClientId
    Optional. Client ID of a USER-ASSIGNED managed identity to run as instead
    of the Automation Account's system-assigned identity. Leave empty (default)
    to use the system-assigned identity.

.PARAMETER WhatIf
    Dry run: collect and preview everything, but do NOT write the CSV to disk
    or send the email.

.EXAMPLE
    # As an Automation runbook (PowerShell 7.2 runtime, system-assigned MI)
    ./UserAssignmentsReporting-Runbook.ps1 `
        -SubscriptionId '<sub-guid>' -TenantId '<tenant-guid>' `
        -To 'client@example.com' -Sender 'avd-reports@example.com'

.EXAMPLE
    # Dry-run test against a single host pool - no CSV written, no email sent
    ./UserAssignmentsReporting-Runbook.ps1 -HostPool 'hp-customer-prod-01' -WhatIf

.NOTES
    Generic template (cleansed of customer values) - field-tested against a live tenant.
    Requires: Azure Automation PowerShell 7.2 runtime with the Az.Accounts
              module (preinstalled), a system- or user-assigned managed
              identity enabled on the Automation Account, and outbound HTTPS
              to management.azure.com and graph.microsoft.com (default for
              Azure-hosted sandboxes; add NSG/firewall rules only if run on a
              Hybrid Runbook Worker behind one). Single-tenant only. See
              README.md alongside this script for the full setup walkthrough.
#>
[CmdletBinding()]
param(
    # =========================================================================
    # SET-ONCE VALUES - edit the defaults below, then just run the script.
    # (You can still override any of them on the command line if you want.)
    # =========================================================================

    # One or more subscription IDs to scan.
    [string[]]$SubscriptionId = @('<subscription-id>'),

    # Recipient(s) of the report email. Can be external (any address).
    [string[]]$To = @('recipient@example.com'),

    # Mailbox to send AS. Must already exist in the target tenant (a shared
    # mailbox on a verified domain is ideal), e.g. avd-reports@customer.com
    [string]$Sender = 'avd-reports@example.com',

    # Entra tenant ID that this Automation Account's managed identity lives in.
    [string]$TenantId = '<tenant-id>',

    # =========================================================================
    # Usually fine as-is.
    # =========================================================================

    # Label embedded in the output file name.
    [string]$Name = 'Customer',

    # Role-definition GUID that grants sign-in entitlement.
    # Default = built-in "Desktop Virtualization User". Pass "" for all roles.
    [string]$RoleDefinitionId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63',

    # Optional: limit the run to these host pool(s) (ARM name or friendly name,
    # case-insensitive). Empty = every host pool. Combine with -WhatIf to test
    # against a single host pool without writing/emailing anything.
    [string[]]$HostPool = @(),

    # Email subject. Leave empty to auto-generate:
    # "AVD Users report - <Name> - <date>".
    [string]$Subject = '',

    # Footer/signature line at the bottom of the email body.
    [string]$BodyFooter = 'This is an automated message from the AVD reporting runbook.',

    # =========================================================================
    # TESTING toggle.
    #   $WhatIf = dry run: collect and preview everything, but DO NOT write the
    #   CSV to disk or send the email. Flip the default below for repeated
    #   testing, or pass -WhatIf / -WhatIf:$false on the command line to override.
    # =========================================================================
    [switch]$WhatIf = $true,

    # =========================================================================
    # Managed identity - system-assigned by default. Only set this if the
    # runbook should authenticate as a USER-assigned identity instead.
    # =========================================================================
    [string]$UserAssignedIdentityClientId = ''
)

$ErrorActionPreference = 'Stop'
$scriptStart = Get-Date

# --- guard: catch placeholder values that were never edited ------------------
$placeholders = @{
    SubscriptionId = @($SubscriptionId) -contains '<subscription-id>'
    To             = @($To)             -contains 'recipient@example.com'
    Sender         = $Sender -eq 'avd-reports@example.com'
    TenantId       = $TenantId -eq '<tenant-id>'
}
$unset = $placeholders.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key }
if ($unset) {
    throw "These parameters still hold placeholder values - edit the defaults at the top of the script (or pass them on the command line/runbook parameters): $($unset -join ', ')"
}

$now        = $scriptStart
$fileName   = "Users report_{0}_{1:dd}_{1:MM}_{1:yyyy}.csv" -f $Name, $now
$OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) $fileName

# ---------------------------------------------------------------------------
# Logging: plain Write-Output (INFO/STEP/OK/WARN/ERROR land in the Automation
# job's output stream) and Write-Verbose (DEBUG - needs -Verbose or "Log
# verbose records" enabled on the job/runbook). No Hydra dependency.
# ---------------------------------------------------------------------------
$script:WarnCount  = 0
$script:ErrorCount = 0

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','STEP','OK','WARN','ERROR','DEBUG')][string]$Level = 'INFO',
        [int]$Indent = 0
    )

    $ts   = (Get-Date).ToString('HH:mm:ss')
    $pad  = ' ' * ($Indent * 2)
    $line = "[{0}] [{1,-5}] {2}{3}" -f $ts, $Level, $pad, $Message

    if ($Level -eq 'WARN')  { $script:WarnCount++ }
    if ($Level -eq 'ERROR') { $script:ErrorCount++ }

    if ($Level -eq 'DEBUG') { Write-Verbose $line } else { Write-Output $line }
}

# ---------------------------------------------------------------------------
# REST helpers
# ---------------------------------------------------------------------------

# GET a REST collection, following paging. $NextProp is the paging property name
# ('nextLink' for ARM, '@odata.nextLink' for Graph).
function Get-RestCollection {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [string]$NextProp = '@odata.nextLink'
    )
    $headers = @{ Authorization = "Bearer $Token" }
    $items   = @()
    $next    = $Uri
    while ($next) {
        $resp  = Invoke-RestMethod -Method Get -Uri $next -Headers $headers
        if ($null -ne $resp.value) { $items += $resp.value } else { $items += $resp }
        $next  = $resp.$NextProp
    }
    # Emit the elements to the pipeline; callers wrap in @() to get a clean
    # array. (Do NOT use a unary-comma return here - combined with @()/() at
    # the call site it double-wraps into a single-element array-of-array.)
    $items
}

# GET a single Graph object; returns $null on 404/permission error.
function Get-GraphObject {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Token)
    try {
        Invoke-RestMethod -Method Get -Uri $Uri -Headers @{ Authorization = "Bearer $Token" }
    }
    catch {
        Write-Log "Graph GET failed ($Uri): $($_.Exception.Message)" 'WARN' 3
        $null
    }
}

# Resolve a role-assignment principal to zero or more user rows.
function Resolve-Principal {
    param(
        [string]$PrincipalId,
        [string]$PrincipalType,
        [Parameter(Mandatory)][string]$GraphToken
    )

    if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
        Write-Log "Role assignment with no principalId - skipping." 'DEBUG'
        return
    }

    switch ($PrincipalType) {

        'User' {
            $u = Get-GraphObject -Uri "https://graph.microsoft.com/v1.0/users/$PrincipalId`?`$select=displayName,userPrincipalName" -Token $GraphToken
            if ($u) {
                [pscustomobject]@{ Username = $u.displayName; Email = $u.userPrincipalName }
            }
        }

        'Group' {
            # --- Step 1: does the group still EXIST? -------------------------
            # An orphaned RBAC assignment (deleted group, leftover
            # "Desktop Virtualization User" assignment - common after a customer
            # is offboarded) shows up as a 404 on the group itself.
            $g = $null
            try {
                $g = Invoke-RestMethod -Method Get `
                    -Uri "https://graph.microsoft.com/v1.0/groups/$PrincipalId`?`$select=id,displayName" `
                    -Headers @{ Authorization = "Bearer $GraphToken" }
            }
            catch {
                $status = $null
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                if ($status -eq 404) {
                    Write-Log "ORPHANED assignment: group $PrincipalId no longer exists (deleted group, leftover role assignment) - skipping. Consider removing this stale RBAC assignment." 'WARN' 3
                }
                else {
                    Write-Log "Could not read group $PrincipalId : $($_.Exception.Message)" 'WARN' 3
                }
                return
            }

            $groupName = if ($g.displayName) { $g.displayName } else { $PrincipalId }

            # --- Step 2: group exists - expand its transitive members --------
            Write-Log "Expanding group '$groupName' ($PrincipalId) - transitive members..." 'DEBUG'
            $uri = "https://graph.microsoft.com/v1.0/groups/$PrincipalId/transitiveMembers/microsoft.graph.user`?`$select=displayName,userPrincipalName&`$top=999"
            try {
                $members = @(Get-RestCollection -Uri $uri -Token $GraphToken)
                if ($members.Count -eq 0) {
                    Write-Log "Group '$groupName' exists but has 0 members - contributes no users (empty group, NOT orphaned)." 'INFO' 3
                }
                else {
                    Write-Log "Group '$groupName' -> $($members.Count) member user(s)." 'DEBUG'
                }
                foreach ($m in $members) {
                    [pscustomobject]@{ Username = $m.displayName; Email = $m.userPrincipalName }
                }
            }
            catch {
                Write-Log "Could not expand group '$groupName' ($PrincipalId): $($_.Exception.Message)" 'WARN' 3
            }
        }

        'ServicePrincipal' {
            $sp = Get-GraphObject -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId`?`$select=displayName" -Token $GraphToken
            if ($sp) {
                [pscustomobject]@{ Username = "$($sp.displayName) (service principal)"; Email = $null }
            }
        }

        default {
            Write-Log "Skipping principal of type '$PrincipalType' ($PrincipalId)." 'WARN' 3
        }
    }
}

# ---------------------------------------------------------------------------
# Authenticate as the Automation Account's managed identity, then get ARM and
# Graph tokens for it. No client secret, no Key Vault - Az.Accounts talks to
# the sandbox's managed-identity endpoint under the hood.
# ---------------------------------------------------------------------------
Write-Log "AVD user-assignment report starting (REST / managed identity)." 'STEP'

try {
    $connectArgs = @{ Identity = $true }
    if ($UserAssignedIdentityClientId) { $connectArgs.AccountId = $UserAssignedIdentityClientId }
    Connect-AzAccount @connectArgs | Out-Null

    $armToken   = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
    $graphToken = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com').Token
}
catch {
    throw "Failed to authenticate as the managed identity, or to acquire ARM/Graph tokens for it: $($_.Exception.Message). Confirm a system-assigned (or the named user-assigned) managed identity is enabled on this Automation Account, and that Az.Accounts is available in this runtime."
}

$miKind = if ($UserAssignedIdentityClientId) { "user-assigned ($UserAssignedIdentityClientId)" } else { 'system-assigned' }
Write-Log "Identity          : $miKind managed identity" 'INFO'
Write-Log "Tenant            : $TenantId" 'INFO'
Write-Log "Subscriptions     : $($SubscriptionId -join ', ')" 'INFO'
Write-Log "Output file       : $OutputPath" 'INFO'
Write-Log "Acquired ARM and Graph tokens." 'OK'

# ---------------------------------------------------------------------------
# Resolve a subscription's friendly display name (ARM). Cached so we only look
# each one up once. Falls back to the GUID if the lookup fails (e.g. the
# identity lacks read on that subscription).
# ---------------------------------------------------------------------------
$script:SubNameCache = @{}
function Get-SubscriptionName {
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Token)

    if ($script:SubNameCache.ContainsKey($SubscriptionId)) {
        return $script:SubNameCache[$SubscriptionId]
    }
    $name = $SubscriptionId
    try {
        $s = Invoke-RestMethod -Method Get `
            -Uri "https://management.azure.com/subscriptions/$SubscriptionId`?api-version=2022-12-01" `
            -Headers @{ Authorization = "Bearer $Token" }
        if ($s.displayName) { $name = $s.displayName }
    }
    catch {
        Write-Log "Could not resolve display name for subscription $SubscriptionId : $($_.Exception.Message)" 'DEBUG'
    }
    $script:SubNameCache[$SubscriptionId] = $name
    return $name
}

# ---------------------------------------------------------------------------
# Collect assignments
# ---------------------------------------------------------------------------
$rows       = [System.Collections.Generic.List[object]]::new()
$poolsTotal = 0
$hpApiVer   = '2023-09-05'
$raApiVer   = '2022-04-01'

foreach ($sub in $SubscriptionId) {

    $subName = Get-SubscriptionName -SubscriptionId $sub -Token $armToken
    Write-Log "=== Checking subscription: $subName ($sub) ===" 'STEP'

    try {
        $hostPools = @(Get-RestCollection -Token $armToken -NextProp 'nextLink' `
            -Uri "https://management.azure.com/subscriptions/$sub/providers/Microsoft.DesktopVirtualization/hostPools?api-version=$hpApiVer")
        $appGroups = @(Get-RestCollection -Token $armToken -NextProp 'nextLink' `
            -Uri "https://management.azure.com/subscriptions/$sub/providers/Microsoft.DesktopVirtualization/applicationGroups?api-version=$hpApiVer")
    }
    catch {
        Write-Log "Failed to list AVD resources in '$sub': $($_.Exception.Message). Skipping." 'ERROR' 1
        continue
    }

    Write-Log "Found $(@($hostPools).Count) host pool(s), $(@($appGroups).Count) application group(s)." 'INFO' 1

    if ($HostPool.Count -gt 0) {
        $hostPools = @($hostPools | Where-Object {
            $hpName = $_.name
            $hpFriendly = $_.properties.friendlyName
            $HostPool | Where-Object { $_ -eq $hpName -or $_ -eq $hpFriendly }
        })
        Write-Log "-HostPool filter applied ($($HostPool -join ', ')) - $(@($hostPools).Count) host pool(s) matched in this subscription." 'INFO' 1
        if ($hostPools.Count -eq 0) { continue }
    }

    foreach ($hp in $hostPools) {
        $poolsTotal++
        # Prefer the AVD friendly name; fall back to the ARM resource name.
        $hpFriendly = if ($hp.properties.friendlyName) { $hp.properties.friendlyName } else { $hp.name }
        $hpLabel    = if ($hpFriendly -ne $hp.name) { "$hpFriendly [$($hp.name)]" } else { $hp.name }
        Write-Log "Checking host pool: $hpLabel" 'STEP' 1

        $hpAppGroups = @($appGroups | Where-Object { $_.properties.hostPoolArmPath -eq $hp.id })
        if ($hpAppGroups.Count -eq 0) {
            Write-Log "No application groups attached to '$hpFriendly' - 0 users." 'INFO' 2
            continue
        }
        Write-Log "$($hpAppGroups.Count) application group(s) attached: $(($hpAppGroups.name) -join ', ')" 'INFO' 2

        $poolSeenUsers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $poolRowStart  = $rows.Count

        foreach ($ag in $hpAppGroups) {
            $agFriendly = if ($ag.properties.friendlyName) { $ag.properties.friendlyName } else { $ag.name }
            $agLabel    = if ($agFriendly -ne $ag.name) { "$agFriendly [$($ag.name)]" } else { $ag.name }
            Write-Log "Checking app group: $agLabel" 'INFO' 2

            # Role assignments AT this app group's scope only (atScope()).
            $raUri = "https://management.azure.com$($ag.id)/providers/Microsoft.Authorization/roleAssignments?api-version=$raApiVer&`$filter=atScope()"
            try {
                $assignments = @(Get-RestCollection -Uri $raUri -Token $armToken -NextProp 'nextLink')
            }
            catch {
                Write-Log "Could not read role assignments on '$agFriendly': $($_.Exception.Message)" 'WARN' 3
                continue
            }

            $totalOnAg = $assignments.Count
            if ($RoleDefinitionId) {
                $assignments = @($assignments | Where-Object {
                    $_.properties.roleDefinitionId -match "$RoleDefinitionId$"
                })
            }
            Write-Log "$totalOnAg role assignment(s) at scope, $($assignments.Count) matching the entitlement role filter." 'INFO' 3

            foreach ($a in $assignments) {
                $principalId   = [string]$a.properties.principalId
                $principalType = [string]$a.properties.principalType
                if ([string]::IsNullOrWhiteSpace($principalId)) {
                    Write-Log "Assignment '$($a.name)' has no principalId - skipping." 'DEBUG'
                    continue
                }
                foreach ($u in (Resolve-Principal -PrincipalId $principalId -PrincipalType $principalType -GraphToken $graphToken)) {
                    if (-not $u) { continue }
                    $key = if ($u.Email) { $u.Email } else { $u.Username }
                    if ([string]::IsNullOrWhiteSpace($key)) { continue }
                    if ($poolSeenUsers.Add($key)) {
                        $rows.Add([pscustomobject]@{
                            Username = $u.Username
                            Email    = $u.Email
                            HostPool = $hp.name
                        })
                    }
                }
            }
        }

        $poolCount = $rows.Count - $poolRowStart
        Write-Log "$poolCount unique assigned user(s) for host pool '$hpFriendly'." 'OK' 2
    }
}

# ---------------------------------------------------------------------------
# Collapse to one row per user (host pools comma-separated) + summary
# ---------------------------------------------------------------------------
$report = $rows |
    Group-Object -Property { if ($_.Email) { $_.Email } else { $_.Username } } |
    ForEach-Object {
        $first = $_.Group[0]
        [pscustomobject]@{
            Username = $first.Username
            Email    = $first.Email
            HostPool = ($_.Group.HostPool | Sort-Object -Unique) -join ', '
        }
    }

$elapsed = (Get-Date) - $scriptStart
Write-Log "----------------------------------------" 'INFO'
Write-Log "Run summary" 'STEP'
Write-Log "Host pools processed : $poolsTotal" 'INFO' 1
Write-Log "Assignments collected: $($rows.Count)" 'INFO' 1
Write-Log "Unique users (rows)  : $(@($report).Count)" 'INFO' 1
Write-Log "Warnings             : $script:WarnCount" 'INFO' 1
Write-Log "Errors               : $script:ErrorCount" 'INFO' 1
Write-Log "Elapsed              : $([int]$elapsed.TotalSeconds)s" 'INFO' 1

if ($rows.Count -eq 0) {
    Write-Log "No assigned users were found across the supplied subscription(s). Nothing written, no email sent." 'WARN'
    return
}

# ---------------------------------------------------------------------------
# -WhatIf: all the read-only collection above still runs (so you see exactly
# what would be reported), but we stop here - no CSV is written to disk and no
# email is sent. Just preview what the real run would do.
# ---------------------------------------------------------------------------
if ($WhatIf) {
    $whatIfSubject = if ($Subject) { $Subject } else { "AVD Users report - $Name - $($now.ToString('dd/MM/yyyy'))" }
    Write-Log "----------------------------------------" 'INFO'
    Write-Log "[WhatIf] Preview only - no CSV written, no email sent." 'STEP'
    Write-Log "[WhatIf] Would write $(@($report).Count) row(s) to: $OutputPath" 'INFO' 1
    Write-Log "[WhatIf] Would email as  : $Sender" 'INFO' 1
    Write-Log "[WhatIf] Would email to  : $($To -join ', ')" 'INFO' 1
    Write-Log "[WhatIf] Subject         : $whatIfSubject" 'INFO' 1
    Write-Log "[WhatIf] Report rows:" 'INFO' 1
    foreach ($r in ($report | Sort-Object Username)) {
        $email = if ($r.Email) { $r.Email } else { '(no email)' }
        Write-Log "$($r.Username) <$email> -> $($r.HostPool)" 'INFO' 2
    }
    Write-Log "[WhatIf] Done - nothing was written or sent." 'OK'
    return
}

$report | Sort-Object Username |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Log "Wrote $(@($report).Count) row(s) to: $OutputPath" 'OK'

# ---------------------------------------------------------------------------
# Email the CSV via Graph sendMail (REST)
# ---------------------------------------------------------------------------
$csvName  = Split-Path $OutputPath -Leaf
$bytes    = [System.IO.File]::ReadAllBytes($OutputPath)
$contentB = [System.Convert]::ToBase64String($bytes)

$subjectLine = if ($Subject) { $Subject } else { "AVD Users report - $Name - $($now.ToString('dd/MM/yyyy'))" }
$bodyContent = @"
Attached is the AVD assigned-users report.

Name      : $Name
Generated : $($now.ToString('dd/MM/yyyy HH:mm'))
Host pools: $poolsTotal
Users     : $(@($report).Count)
File      : $csvName
$(if ($BodyFooter) { "`n$BodyFooter" })
"@

$payload = @{
    message = @{
        subject = $subjectLine
        body    = @{
            contentType = 'Text'
            content     = $bodyContent
        }
        toRecipients = @(@($To) | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        attachments  = @(
            @{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                name          = $csvName
                contentType   = 'text/csv'
                contentBytes  = $contentB
            }
        )
    }
    saveToSentItems = $true
}

$sendUri = "https://graph.microsoft.com/v1.0/users/$Sender/sendMail"
$json    = $payload | ConvertTo-Json -Depth 12

Write-Log "Emailing $csvName as '$Sender' to $($To -join ', ') via Microsoft Graph ..." 'STEP'
try {
    Invoke-RestMethod -Method Post -Uri $sendUri `
        -Headers @{ Authorization = "Bearer $graphToken" } `
        -ContentType 'application/json' -Body $json | Out-Null
    Write-Log "Email sent." 'OK'
    Write-Log "=== DONE: emailed '$csvName' ($(@($report).Count) users) to $($To -join ', ') ===" 'OK'
}
catch {
    Write-Log "Email failed: $($_.Exception.Message)" 'ERROR'
    throw
}
finally {
    # Never leave the report on disk, whatever happened.
    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned up local CSV: $csvName" 'DEBUG'
    }
}
