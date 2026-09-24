# ===========================================================
# This script is meant to be run from the Azure Cloud Shell
# ===========================================================

# =============================
# Note
# =============================
# Create an Azure Automation Account in the Azure Portal.
# It's possible to create a Managed Identity during the AA creation, 
# ensure this is enabled.

# Define your Automation Account ObjectId here.
# The permissions will be added against this Object.
$ManagedIdentityObjectId = "00000-00000-00000-00000"

# These are the required Graph permissions to enable reading assignments and 
# sending the report via Email. User.Read.All and Group.Read.All allow for
# identifying user assignments, but also inherited group assignments.
# Mail.Send allows for sending the report via mailbox.
$PermissionsToAdd = @("User.Read.All", "Group.Read.All", "Mail.Send")

# TODO: Add steps to limit scope of permissions to only approved mailboxes.

# Reuse the Az context Cloud Shell already has (no new sign-in, no device code)
# Requires Cloud Application Administrator or higher permissions.
$token = (Get-AzAccessToken -ResourceTypeName MSGraph -AsSecureString).Token
Connect-MgGraph -AccessToken $token -NoWelcome
 
# Sanity check: should show your UPN
Get-MgContext | Select-Object Account, AuthType

# Get the Microsoft Graph service principal in your tenant.
# 00000003-0000-0000-c000-000000000000 is Graph's well-known appId, the same in every tenant.
$GraphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Get the managed identity's service principal. This is the principal receiving the roles.
$ManagedIdentityServicePrincipal = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityObjectId

# Get the MI's current app role assignments, filtered to Graph only.
# Used later so the script can re-run without duplicate-assignment errors
$ExistingRoleAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityServicePrincipal.Id -All | Where-Object ResourceId -eq $GraphSp.Id

# Loop through each requested permission
    # - User.Read.All
    # - Group.Read.All
    # - Mail.Send
foreach ($perm in $PermissionsToAdd) {

    # Find the matching AppRole on the Graph SP.
    # AllowedMemberTypes -contains "Application" keeps only application permissions
    # and skips delegated scopes that share the name
    $role = $GraphSp.AppRoles | Where-Object { $_.Value -eq $perm -and $_.AllowedMemberTypes -contains "Application" }

    # If there's no match (typo or wrong casing), warn and move on
    if (-not $role) { Write-Warning "Role not found: $perm"; continue }

    # If this role's GUID is already assigned to the MI, skip it
    if ($ExistingRoleAssignments.AppRoleId -contains $role.Id) {
        Write-Host "Already assigned: $perm" -ForegroundColor Yellow
        continue
    }

    # Create the assignment (the equivalent of admin consent for an application permission):
    #   -ServicePrincipalId : the SP whose assignments you're editing (the MI)
    #   -PrincipalId        : who gets the role (also the MI)
    #   -ResourceId         : the SP that defines the role (Graph)
    #   -AppRoleId          : GUID of the specific permission
    # Out-Null suppresses the returned object
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityServicePrincipal.Id `
        -PrincipalId $ManagedIdentityServicePrincipal.Id -ResourceId $GraphSp.Id -AppRoleId $role.Id | Out-Null

    # Confirm success
    Write-Host "Assigned: $perm" -ForegroundColor Green
}