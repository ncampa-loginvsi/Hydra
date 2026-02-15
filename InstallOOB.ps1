# Install Windows Out-of-Band (OOB) and standard security updates directly from Microsoft Update.
# This script searches for, downloads, and installs both normal and OOB updates.
# A restart may be required after installation.

# Initialize COM objects for Windows Update Agent
$updateSession   = New-Object -ComObject Microsoft.Update.Session
$updateSearcher  = New-Object -ComObject Microsoft.Update.Searcher
$updateCollection = New-Object -ComObject Microsoft.Update.UpdateColl

# Search for standard uninstalled, non-hidden software updates
OutputWriter("Searching for standard updates...")
$normalResult = $updateSearcher.Search(
    "IsInstalled=0 and Type='Software' and IsHidden=0"
)
OutputWriter("Found $($normalResult.Updates.Count) standard update(s).")

# Search for OOB (BrowseOnly) updates — these are out-of-band patches Microsoft
# publishes outside the normal Patch Tuesday cycle
OutputWriter("Searching for Out-of-Band (OOB) updates...")
$oobResult = $updateSearcher.Search(
    "IsInstalled=0 and Type='Software' and IsHidden=0 and BrowseOnly=1"
)
OutputWriter("Found $($oobResult.Updates.Count) OOB update(s).")

# Merge both result sets into the update collection for installation
foreach ($update in $normalResult.Updates) {
    $updateCollection.Add($update) | Out-Null
}
foreach ($update in $oobResult.Updates) {
    # Avoid duplicates — OOB results may overlap with normal results
    $isDuplicate = $false
    foreach ($existing in $updateCollection) {
        if ($existing.Identity.UpdateID -eq $update.Identity.UpdateID) {
            $isDuplicate = $true
            break
        }
    }
    if (-not $isDuplicate) {
        $updateCollection.Add($update) | Out-Null
    }
}

OutputWriter("Total unique updates to install: $($updateCollection.Count)")

if ($updateCollection.Count -eq 0) {
    OutputWriter("No applicable updates found. Exiting.")
    exit 0
}

# List the updates that will be installed
OutputWriter("Updates to install:")
foreach ($update in $updateCollection) {
    $kbArticles = ($update.KBArticleIDs | ForEach-Object { "KB$_" }) -join ", "
    OutputWriter("  - $($update.Title) [$kbArticles]")
}

# Download updates
OutputWriter("Downloading updates...")
$downloader = $updateSession.CreateUpdateDownloader()
$downloader.Updates = $updateCollection
$downloadResult = $downloader.Download()
OutputWriter("Download result code: $($downloadResult.ResultCode)")
# ResultCode: 2 = Succeeded, 3 = Succeeded with errors, 4 = Failed, 5 = Aborted

# Install updates
OutputWriter("Installing updates...")
$installer = $updateSession.CreateUpdateInstaller()
$installer.Updates = $updateCollection
$installResult = $installer.Install()

OutputWriter("Installation result code: $($installResult.ResultCode)")

# Report per-update results
for ($i = 0; $i -lt $updateCollection.Count; $i++) {
    $update = $updateCollection.Item($i)
    $result = $installResult.GetUpdateResult($i)
    $status = switch ($result.ResultCode) {
        2 { "Succeeded" }
        3 { "Succeeded with errors" }
        4 { "Failed" }
        5 { "Aborted" }
        default { "Unknown ($($result.ResultCode))" }
    }
    OutputWriter("  [$status] $($update.Title)")
}

# Check if a reboot is required
if ($installResult.RebootRequired) {
    OutputWriter("A restart is required to complete the installation.")
} else {
    OutputWriter("No restart required.")
}