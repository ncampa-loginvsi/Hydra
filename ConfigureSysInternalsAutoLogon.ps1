####################################################################################################
####################################################################################################
# Configure AutoLogon
####################################################################################################
####################################################################################################
$autoLogonCount               = "7" # Configure the number of automatic logins here. Currently, this will configure 7 automatic logins.
$autologonDownloadUrl         = "https://download.sysinternals.com/files/AutoLogon.zip"
$autologonDownloadDestination = "C:\Launcher\AutoLogon"
$autologonZipDestination      = Join-Path $autologonDownloadDestination "AutoLogon.zip" # C:\Launcher\AutoLogon\AutoLogon.zip
$autologonUnzipDestination    = Join-Path $autologonDownloadDestination "AutoLogon"     # C:\Launcher\AutoLogon\AutoLogon\
$autologonExePath             = Join-Path $autologonUnzipDestination "AutoLogon64.exe"  # C:\Launcher\AutoLogon\AutoLogon\AutoLogon64.exe
 
$autologonUsername            = "autologin" # This is the username of the local user account, used for AutoLogon. You may configure this value.
Add-Type -AssemblyName System.Web
$password = [System.Web.Security.Membership]::GeneratePassword(20, 4) # A randomized password is created
$securePass = ConvertTo-SecureString $password -AsPlainText -Force
 
OutputWriter("Downloading SysInternals' AutoLogon from: $autologonDownloadUrl")
OutputWriter("Archive will be downloaded to: $$autologonUnzipDestination")
 
OutputWriter("Archive will be extracted to: $autologonUnzipDestination")
OutputWriter("Target executable should be in: $autologonExePath")
 
##################################################
# Prepare for download and extraction
##################################################
if (-not (Test-Path $autologonDownloadDestination)) {
    OutputWriter("Creating folder to store Autologon download")
    New-Item -Path $autologonDownloadDestination -ItemType Directory -Force | Out-Null
}
else { 
    # OutputWriter("Folder already exists.")
    LogWriter("Autologon download folder already exists.")
}
 
##################################################
# Download AutoLogon and Extract
##################################################
OutputWriter("Downloading SysInternals' AutoLogon")
if (-not (Test-Path $autologonExePath)) {
    OutputWriter("AutoLogon64.exe not found. Proceeding to download and extract...")
     
    try {
        Invoke-WebRequest -Uri $autologonDownloadUrl -OutFile $autologonZipDestination -UseBasicParsing
        Expand-Archive -Path $autologonZipDestination -DestinationPath $autologonUnzipDestination -Force
        OutputWriter("Download and extraction complete.")
    }
    catch {
        OutputWriter("Failed to download or extract AutoLogon: $_")
        exit 1
    }
} else {
    OutputWriter("AutoLogon already downloaded and extracted.")
}
 
 
####################################################################################################
# Create autologon user (if not exists)
####################################################################################################
try {
    if (-not (Get-LocalUser -Name $autologonUsername -ErrorAction SilentlyContinue)) {
        OutputWriter("Creating local user '$autologonUsername'")
        New-LocalUser -Name $autologonUsername -Password $securePass -FullName $autologonUsername -PasswordNeverExpires:$true -UserMayNotChangePassword:$true
        OutputWriter("User '$autologonUsername' created.")
    } else {
        OutputWriter("User '$autologonUsername' already exists.")
    }
}
catch {
    OutputWriter("Failed to create or check user: $_")
    throw "Failed to create or check for user existence: $_"
}
 
####################################################################################################
# Configure AutoLogon using AutoLogon64.exe
####################################################################################################
if (Test-Path $autologonExePath) {
    try {
        OutputWriter "Running AutoLogon64.exe configuration..."
        Start-Process $autologonExePath -ArgumentList $autologonUsername,$env:COMPUTERNAME,$password,"-accepteula" -Wait
        OutputWriter("AutoLogon configured.")
    }
    catch {
        OutputWriter("Failed to configure AutoLogon: $_")
        exit 1
    }
} else {
    OutputWriter("AutoLogon64.exe not found at expected path: $autologonExePath")
    exit 1
}
 
####################################################################################################
# Registry configuration
####################################################################################################
OutputWriter("Configuring registry values for AutoLogon...")
 
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$policyPath   = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
 
# Ensure required policies
try {
    $regSettings = @{
        "$policyPath\dontdisplaylastusername"           = 0
        "$policyPath\DisableAutomaticRestartSignOn"     = 0
        "$winlogonPath\AutoLogonCount"                  = $autoLogonCount
    }
 
    foreach ($key in $regSettings.Keys) {
        $pathParts = $key.Split('\')
        $regPath = ($pathParts[0..($pathParts.Length - 2)] -join '\')
        $regName = $pathParts[-1]
        $desiredValue = $regSettings[$key]
 
        $existing = Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue
        if ($existing.$regName -ne $desiredValue) {
            Set-ItemProperty -Path $regPath -Name $regName -Value $desiredValue
            OutputWriter("Set registry '$regName' to '$desiredValue'")
        } else {
            OutputWriter("Registry '$regName' already set to '$desiredValue'")
        }
    }
}
catch {
    OutputWriter("Failed to update registry keys: $_")
    exit 1
}
OutputWriter("AutoLogon setup complete")