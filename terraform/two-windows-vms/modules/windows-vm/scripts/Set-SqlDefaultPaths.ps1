<#
.SYNOPSIS
    One-time setup of SQL Server's default data, log and backup folders.

.DESCRIPTION
    Runs once through an Azure managed Run Command (Windows PowerShell 5.1, as SYSTEM),
    after Initialize-DataDisks.ps1 has formatted the volumes.
      1. Creates each folder and grants the SQL Server service account full control.
      2. Writes the default instance's DefaultData, DefaultLog and BackupDirectory
         registry values. This is what SSMS's Server Properties > Database Settings
         page changes.
      3. Restarts SQL Server so the new defaults take effect.
    Safe to re-run: existing folders, permissions and values are set again.

.PARAMETER DataPath
    Default folder for new database data files, e.g. F:\Data. Omit to leave unchanged.

.PARAMETER LogPath
    Default folder for new database log files, e.g. G:\Log. Omit to leave unchanged.

.PARAMETER BackupPath
    Default backup folder, e.g. H:\Backup. Omit to leave unchanged.
#>
[CmdletBinding()]
param(
    [string] $DataPath,
    [string] $LogPath,
    [string] $BackupPath
)

$ErrorActionPreference = 'Stop'

# --- 1. Find the default instance --------------------------------------------------
# Instance Names\SQL maps instance name to instance ID, e.g. MSSQLSERVER -> MSSQL17.MSSQLSERVER.
$instanceId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').MSSQLSERVER
$settingsKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer"

# The account SQL Server runs as. On Marketplace images: NT Service\MSSQLSERVER.
$serviceAccount = (Get-CimInstance -ClassName Win32_Service -Filter "Name = 'MSSQLSERVER'").StartName

# --- 2. Create folders, grant access, set defaults ------------------------------------
# Registry value name => folder. Empty parameters are skipped.
$settings = [ordered]@{ DefaultData = $DataPath; DefaultLog = $LogPath; BackupDirectory = $BackupPath }

foreach ($name in @($settings.Keys)) {
    $path = $settings[$name]
    if (-not $path) { continue }

    New-Item -ItemType Directory -Path $path -Force | Out-Null

    # (OI)(CI)F = full control, inherited by files (OI) and subfolders (CI).
    & icacls.exe $path /grant "$($serviceAccount):(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed to grant $serviceAccount access to $path." }

    Set-ItemProperty -Path $settingsKey -Name $name -Value $path
    Write-Output "$name = $path (full control: $serviceAccount)"
}

# --- 3. Restart SQL Server -------------------------------------------------------------
# -Force also stops SQL Server Agent, which depends on SQL Server, so start it again.
Restart-Service -Name MSSQLSERVER -Force
Start-Service -Name SQLSERVERAGENT
Write-Output 'SQL Server restarted.'
