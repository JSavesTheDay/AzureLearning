<#
.SYNOPSIS
    Prepares the tempdb folders on the temp disk, then starts SQL Server.

.DESCRIPTION
    Runs at every boot from a scheduled task, as SYSTEM. The temp disk comes back empty
    after deallocation or redeployment, and SQL Server can't start if the tempdb folders
    are missing, so the SQL services are set to Manual and this script starts them.
    It only creates folders under TempDbPath and starts services.
    Keeps a log of the latest run next to the script (Start-SqlOnTempDisk.log).

.PARAMETER TempDbPath
    Folder on the temp disk that holds tempdb, e.g. D:\tempDb.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $TempDbPath
)

$ErrorActionPreference = 'Stop'

Start-Transcript -Path (Join-Path $PSScriptRoot 'Start-SqlOnTempDisk.log') | Out-Null

# The temp disk can appear shortly after boot, so retry until it can be written to.
$deadline = (Get-Date).AddMinutes(5)
while ($true) {
    try {
        New-Item -ItemType Directory -Path "$TempDbPath\Data", "$TempDbPath\Log" -Force | Out-Null
        break
    }
    catch {
        if ((Get-Date) -gt $deadline) { throw }
        Start-Sleep -Seconds 5
    }
}

# A new temp disk has default permissions, so grant the service account access each time.
$serviceAccount = (Get-CimInstance -ClassName Win32_Service -Filter "Name = 'MSSQLSERVER'").StartName
& icacls.exe $TempDbPath /grant "$($serviceAccount):(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed to grant $serviceAccount access to $TempDbPath." }

Start-Service -Name MSSQLSERVER
Start-Service -Name SQLSERVERAGENT
Write-Output "SQL Server started with tempdb in $TempDbPath."

Stop-Transcript | Out-Null
