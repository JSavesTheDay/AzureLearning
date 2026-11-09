<#
.SYNOPSIS
    One-time move of tempdb to the temp disk, without the SQL IaaS Agent extension.

.DESCRIPTION
    Runs once through an Azure managed Run Command (Windows PowerShell 5.1, as SYSTEM).
      1. Installs Start-SqlOnTempDisk.ps1 in a folder only SYSTEM and Administrators can
         change, and registers a scheduled task that runs it at every boot.
      2. Sets the SQL services to Manual, so that task is what starts them.
      3. Restarts SQL Server in single-user mode, which is how a local administrator gets
         sysadmin rights, and points tempdb's files at the temp disk (DataFileCount data
         files plus the log). The old files stay where they were, unused.
      4. Starts SQL Server normally through the startup script.
    Safe to re-run: files already moved are set to the same path, and none are added
    once DataFileCount is reached.

.PARAMETER StartupScriptBase64
    Base64-encoded content of Start-SqlOnTempDisk.ps1.

.PARAMETER TempDbPath
    Folder on the temp disk for tempdb. Data files go in \Data, the log in \Log.

.PARAMETER DataFileCount
    Number of tempdb data files. Microsoft guidance: one per vCPU, up to 8.

.PARAMETER DataFileSizeMb
    Initial size of each data file. Defaults match the SQL IaaS Agent extension's.

.PARAMETER LogFileSizeMb
    Initial size of the log file.

.PARAMETER FileGrowthMb
    Growth increment for every tempdb file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $StartupScriptBase64,

    [string] $TempDbPath = 'D:\tempDb',

    [int] $DataFileCount = 8,

    [int] $DataFileSizeMb = 256,

    [int] $LogFileSizeMb = 256,

    [int] $FileGrowthMb = 512
)

$ErrorActionPreference = 'Stop'

# --- 1. Install the startup script and its scheduled task ------------------------------
$installPath = Join-Path $env:ProgramData 'SqlTempDb'
$startupScript = Join-Path $installPath 'Start-SqlOnTempDisk.ps1'
New-Item -ItemType Directory -Path $installPath -Force | Out-Null

# This script runs as SYSTEM at boot, so ordinary users must not be able to change it.
# /inheritance:r removes the permissions ProgramData would otherwise pass down.
& icacls.exe $installPath /inheritance:r /grant 'SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed to restrict $installPath." }

[IO.File]::WriteAllBytes($startupScript, [Convert]::FromBase64String($StartupScriptBase64))

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startupScript`" -TempDbPath `"$TempDbPath`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'Start-SqlOnTempDisk' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Scheduled task Start-SqlOnTempDisk runs $startupScript at startup."

# --- 2. Let the task start SQL Server ----------------------------------------------------
Set-Service -Name MSSQLSERVER -StartupType Manual
Set-Service -Name SQLSERVERAGENT -StartupType Manual

# --- 3. Move tempdb in single-user mode --------------------------------------------------
Stop-Service -Name SQLSERVERAGENT
Stop-Service -Name MSSQLSERVER -Force

# ADD FILE creates files right away, so the folders must exist and be writable first.
$serviceAccount = (Get-CimInstance -ClassName Win32_Service -Filter "Name = 'MSSQLSERVER'").StartName
New-Item -ItemType Directory -Path "$TempDbPath\Data", "$TempDbPath\Log" -Force | Out-Null
& icacls.exe $TempDbPath /grant "$($serviceAccount):(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed to grant $serviceAccount access to $TempDbPath." }

# A new FILENAME takes effect at the next start, and must be set on its own statement.
# SIZE can only grow a file, so it's skipped on a re-run. All data files get the same
# size and growth, because SQL Server fills them in proportion to their free space.
$moveTempDb = @"
SET NOCOUNT ON;
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'ALTER DATABASE tempdb MODIFY FILE (NAME = ' + QUOTENAME(name)
    + N', FILENAME = ''$TempDbPath\' + CASE type WHEN 0 THEN N'Data' ELSE N'Log' END + N'\'
    + RIGHT(physical_name, CHARINDEX(N'\', REVERSE(physical_name)) - 1) + N''');'
    + CASE WHEN size * 8 / 1024 < CASE type WHEN 0 THEN $DataFileSizeMb ELSE $LogFileSizeMb END
        THEN N'ALTER DATABASE tempdb MODIFY FILE (NAME = ' + QUOTENAME(name) + N', SIZE = '
            + CONCAT(CASE type WHEN 0 THEN $DataFileSizeMb ELSE $LogFileSizeMb END, N'MB);')
        ELSE N'' END
    + N'ALTER DATABASE tempdb MODIFY FILE (NAME = ' + QUOTENAME(name) + N', FILEGROWTH = ${FileGrowthMb}MB);'
FROM tempdb.sys.database_files;
EXEC (@sql);

DECLARE @files int;
SELECT @files = COUNT(*) FROM tempdb.sys.database_files WHERE type = 0;

WHILE @files < $DataFileCount
BEGIN
    SET @files += 1;
    SET @sql = CONCAT(N'ALTER DATABASE tempdb ADD FILE (NAME = temp', @files,
        N', FILENAME = ''$TempDbPath\Data\tempdb_mssql_', @files, N'.ndf'', SIZE = ${DataFileSizeMb}MB, FILEGROWTH = ${FileGrowthMb}MB);');
    EXEC (@sql);
END;
"@
$sqlFile = Join-Path $env:TEMP 'Move-TempDb.sql'
Set-Content -Path $sqlFile -Value $moveTempDb

# /mSQLCMD: single-user mode, and only the sqlcmd client may take the one connection.
& net.exe start MSSQLSERVER /mSQLCMD | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'SQL Server failed to start in single-user mode.' }

try {
    # Recovery can take a moment after the service reports started.
    # -C trusts the self-signed certificate; -b makes T-SQL errors set the exit code.
    foreach ($attempt in 1..30) {
        & sqlcmd.exe -S . -E -C -b -l 5 -Q 'SELECT 1' | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 5
    }
    if ($LASTEXITCODE -ne 0) { throw 'Could not connect to SQL Server in single-user mode.' }

    & sqlcmd.exe -S . -E -C -b -i $sqlFile
    if ($LASTEXITCODE -ne 0) { throw 'Moving tempdb failed.' }
    Write-Output "tempdb moved to $TempDbPath with $DataFileCount data files."
}
finally {
    # --- 4. Back to normal, even if the move failed ------------------------------------
    Remove-Item -Path $sqlFile -ErrorAction SilentlyContinue
    & net.exe stop MSSQLSERVER | Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $startupScript -TempDbPath $TempDbPath
}
if ($LASTEXITCODE -ne 0) { throw 'The startup script failed to start SQL Server.' }
