# Set Login Enterprise Details
$serverUrl = "https://<your_login_enterprise_fqdn_here>"
$secret = "<your_launcher_secret_here>"
 
# Set Launcher Installation Defaults and Startup Folder Location
$launcherProgramFilesPath = "C:\Program Files\Login VSI\Login Enterprise Launcher"
$targetPath = Join-Path $launcherProgramFilesPath "LoginEnterprise.Launcher.UI.exe"
$shortcutPath = "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\Startup\LoginEnterpriseLauncherUI.lnk"
$startupFolder = Split-Path -Parent $shortcutPath
 
 
####################################################################################################
# Download and Install MSI from GitHub
####################################################################################################
$msiUrl        = "https://<URL_for_launcher_executable>" # E.g. add Setup.msi to public Github Repo
$msiName       = "Setup.msi"
$downloadDir   = "C:\Launcher\Installer"
$msiPath       = Join-Path $downloadDir $msiName
 
OutputWriter("Starting MSI download and install process.")
OutputWriter("Installer URL: $msiUrl")
OutputWriter("Installer will be saved to: $msiPath")
 
####################################################################################################
# Create download directory
####################################################################################################
if (-not (Test-Path $downloadDir)) {
    OutputWriter("Creating installer download directory: $downloadDir")
    try {
        New-Item -Path $downloadDir -ItemType Directory -Force | Out-Null
        LogWriter("Created directory $downloadDir")
    } catch {
        OutputWriter("Failed to create directory: $_")
        LogWriter("Directory creation failed: $_")
        exit 1
    }
} else {
    LogWriter("Download directory already exists: $downloadDir")
}
 
####################################################################################################
# Download MSI
####################################################################################################
OutputWriter("Downloading installer...")
try {
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    OutputWriter("Download completed.")
    LogWriter("Downloaded $msiName to $msiPath")
} catch {
    OutputWriter("Download failed: $_")
    LogWriter("Download error: $_")
    exit 1
}
 
####################################################################################################
# Install MSI
####################################################################################################
if (Test-Path $msiPath) {
    OutputWriter("Starting MSI installation...")
    try {
        $arguments = "/i `"$msiPath`" /qn serverurl=$serverUrl secret=$secret"
        LogWriter("Executing: msiexec.exe $arguments")
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
 
        if ($process.ExitCode -eq 0) {
            OutputWriter("MSI installation succeeded.")
            LogWriter("Installer exit code: 0 (Success)")
        } else {
            OutputWriter("MSI installation failed with exit code: $($process.ExitCode)")
            LogWriter("Installer exit code: $($process.ExitCode)")
            exit $process.ExitCode
        }
    } catch {
        OutputWriter("Installation process failed: $_")
        LogWriter("Installer exception: $_")
        exit 1
    }
} else {
    OutputWriter("MSI file not found at expected path: $msiPath")
    LogWriter("Installer missing: $msiPath")
    exit 1
}
OutputWriter("MSI process completed.")
 
if (Test-Path $launcherProgramFilesPath) {
    OutputWriter("Launcher installation deemed successful based on installation folder in %PROGRAMFILES%.")
    # exit 0
}
 
##################################################
# Add Launcher to Startup folder
##################################################
OutputWriter("Starting shortcut creation and Startup placement process.")
OutputWriter("Creating shortcut from: $targetPath")
OutputWriter("Shortcut will be added to $startupFolder")
 
try {
     
    # Verify the target executable exists
    if (-not (Test-Path -Path $targetPath -PathType Leaf)) {
        throw "Target executable not found: $targetPath"
    }
 
    # Ensure the Startup folder exists (it should, but just in case)
    if (-not (Test-Path -Path $startupFolder -PathType Container)) {
        throw "Startup folder does not exist: $startupFolder"
    }
 
    # Create the WScript.Shell COM object
    try {
        $WshShell = New-Object -ComObject WScript.Shell
    }
    catch {
        throw "Unable to create WScript.Shell COM object: $_"
    }
 
    # Create the shortcut
    $shortcut = $WshShell.CreateShortcut($shortcutPath)
 
    # Assign properties to the shortcut
    $shortcut.TargetPath       = $targetPath
    $shortcut.Arguments        = $arguments
    $shortcut.WorkingDirectory = Split-Path -Parent $targetPath
 
    # Save the shortcut to disk
    $shortcut.Save()
 
    OutputWriter("Shortcut successfully created at: $shortcutPath")
    # LogWriter("Shortcut created!")
}
catch {
    # Write-Error "Failed to create shortcut: $_"
    OutputWriter("Failed to create shortcut! $_")
}