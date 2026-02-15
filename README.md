# Hydra

PowerShell automation scripts for provisioning and configuring Login Enterprise target machines.

## Scripts

### ConfigureSysInternalsAutoLogon.ps1

Downloads SysInternals AutoLogon, creates a local user account, and configures automatic login via registry settings.

**What it does:**
- Downloads and extracts `AutoLogon64.exe` from SysInternals
- Creates a local `autologin` user with a random password
- Runs AutoLogon64.exe to configure credentials
- Sets registry keys (`AutoLogonCount`, `DisableAutomaticRestartSignOn`, etc.)

**Configuration:**
```powershell
$autoLogonCount = "7"                # Number of automatic logins
$autologonUsername = "autologin"     # Local user account name
```

**Usage:**
```powershell
# Run as Administrator
.\ConfigureSysInternalsAutoLogon.ps1
```

---

### DownloadExtractLogonExe.ps1

Downloads the Login Enterprise Logon application from the appliance, extracts it, and creates a startup shortcut so it launches on user login.

**Configuration:**
```powershell
$applianceFQDN = 'https://<your_appliance_url>.com'
```

**Usage:**
```powershell
# Update $applianceFQDN before running
.\DownloadExtractLogonExe.ps1
```

---

### InstallLauncherWithStartup.ps1

Downloads and silently installs the Login Enterprise Launcher MSI, then creates a startup shortcut for the Launcher UI.

**What it does:**
- Downloads `Setup.msi` from a configurable URL
- Runs a silent install (`/qn`) with server URL and secret
- Creates a shortcut in the All Users Startup folder

**Configuration:**
```powershell
$serverUrl = "https://<your_login_enterprise_fqdn_here>"
$secret    = "<your_launcher_secret_here>"
$msiUrl    = "https://<URL_for_launcher_executable>"
```

**Usage:**
```powershell
# Update $serverUrl, $secret, and $msiUrl before running
.\InstallLauncherWithStartup.ps1
```

---

### InstallOOB.ps1

Searches for, downloads, and installs both standard and Out-of-Band (OOB) Windows updates directly from Microsoft Update using the Windows Update Agent COM API.

**What it does:**
- Searches for uninstalled software updates (standard + OOB)
- Deduplicates and downloads all applicable patches
- Installs updates and reports per-update success/failure
- Reports whether a reboot is required

**Usage:**
```powershell
# Run as Administrator
.\InstallOOB.ps1
```

## Prerequisites

- Windows OS with PowerShell 5.1+
- Administrator privileges (all scripts modify system state)
- Network access to download dependencies (SysInternals, Login Enterprise appliance, Microsoft Update)
