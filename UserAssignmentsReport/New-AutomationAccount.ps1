# ===========================================================
# This script is meant to be run from the Azure Cloud Shell
# ===========================================================

# =============================
# Note
# =============================
# Creates the Azure Automation Account that will run UserAssignmentsReporting-Runbook.ps1,
# with a system-assigned Managed Identity enabled, and grants that identity
# Reader on every subscription it needs to scan for AVD host pools.
# Run Add-Mi-Permissions.ps1 afterwards to grant the Graph permissions.

# Define your naming/location and target subscriptions here.
$ResourceGroupName     = "rg-<customer>-automation"
$AutomationAccountName = "aa-<customer>-avd-reports"
$Location              = "<region>"

# Every subscription the report should scan for AVD host pools. Multiple can be added here.
$SubscriptionIds = @("<sub-guid-1>")


# Reuse the Az context Cloud Shell already has (no new sign-in, no device code).
# Requires Contributor (or higher) on the target subscription/resource group.
Get-AzContext | Select-Object Account, Subscription

# Create the resource group if it doesn't already exist.
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    Write-Host "Created resource group: $ResourceGroupName" -ForegroundColor Green
} else {
    Write-Host "Resource group already exists: $ResourceGroupName" -ForegroundColor Yellow
}

# Create the Automation Account, or enable the identity on an existing one.
# -AssignSystemIdentity both creates the account and enables the
# system-assigned managed identity in one step.
$existingAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction SilentlyContinue

if (-not $existingAccount) {
    New-AzAutomationAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $AutomationAccountName `
        -Location $Location `
        -AssignSystemIdentity | Out-Null

    Write-Host "Created Automation Account: $AutomationAccountName" -ForegroundColor Green
} else {
    Set-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -AssignSystemIdentity | Out-Null
    Write-Host "Automation Account already existed, ensured Managed Identity is enabled: $AutomationAccountName" -ForegroundColor Yellow
}

# Note the identity's object ID (principal ID) - needed for the Graph
# app-role grant in Add-Mi-Permissions.ps1.
$identity = (Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName).Identity
Write-Host "Managed Identity Object ID: $($identity.PrincipalId)" -ForegroundColor Cyan

# Grant Azure RBAC Reader on each subscription being scanned.
# Reader includes Microsoft.Authorization/roleAssignments/read, which the
# report script needs to read the "Desktop Virtualization User" assignments
# on each application group.
foreach ($sub in $SubscriptionIds) {

    $existingAssignment = Get-AzRoleAssignment -ObjectId $identity.PrincipalId -Scope "/subscriptions/$sub" -RoleDefinitionName "Reader" -ErrorAction SilentlyContinue

    if ($existingAssignment) {
        Write-Host "Already assigned Reader on subscription: $sub" -ForegroundColor Yellow
        continue
    }

    New-AzRoleAssignment `
        -ObjectId $identity.PrincipalId `
        -RoleDefinitionName "Reader" `
        -Scope "/subscriptions/$sub" | Out-Null

    Write-Host "Assigned Reader on subscription: $sub" -ForegroundColor Green
}
