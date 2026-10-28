<#
.SYNOPSIS
    Loads metadata (not bodies) for every message in a mail folder into SQL Server. Read-only on the mailbox.

.DESCRIPTION
    Requires:
    - A Graph session with at least Mail.Read:  Connect-MgGraph -Scopes "Mail.Read" -NoWelcome
    - The MailInventory database:               sqlcmd -S . -E -i graph-mail/sql/01-schema.sql

    Built for large folders (100k+ items):
    - Pages manually via @odata.nextLink, 1000 per page (the Graph max for messages)
    - Sends each raw JSON page to dbo.usp_LoadMessagePage, which parses it with OPENJSON,
      upserts on message id, and saves the next-page link in the same transaction
    - -Resume continues from the saved link in dbo.ExportState

    Message size isn't a first-class Graph property, so it is read from the MAPI
    property PidTagMessageSize (0x0E08) via singleValueExtendedProperties.
    -IncludeHeaders adds the List-Unsubscribe check (newsletters) at a large speed cost.

.EXAMPLE
    ./Export-MailboxInventory.ps1                       # Inbox, fresh export
    ./Export-MailboxInventory.ps1 -Resume               # continue an interrupted export
    ./Export-MailboxInventory.ps1 -Folder archive -IncludeHeaders
#>
param(
    # Well-known folder name (inbox, archive, sentitems, deleteditems...) or a folder id
    [string]$Folder = 'inbox',
    [switch]$IncludeHeaders,
    [switch]$Resume,
    [string]$ServerInstance = '.',
    [string]$Database = 'MailInventory'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-MgContext)) {
    throw 'Not signed in. Run: Connect-MgGraph -Scopes "Mail.Read" -NoWelcome'
}

# Windows auth (Integrated Security): no password in the script.
# System.Data.SqlClient ships with PowerShell 7; Microsoft.Data.SqlClient is its successor.
$conn = [System.Data.SqlClient.SqlConnection]::new("Server=$ServerInstance;Database=$Database;Integrated Security=true")
$conn.Open()

try {
    if ($Resume) {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'SELECT NextLink FROM dbo.ExportState WHERE Folder = @Folder'
        [void]$cmd.Parameters.AddWithValue('@Folder', $Folder)
        $uri = $cmd.ExecuteScalar()
        if ($uri -is [DBNull] -or -not $uri) { throw "Nothing to resume for '$Folder'." }
    } else {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'DELETE dbo.ExportState WHERE Folder = @Folder'
        [void]$cmd.Parameters.AddWithValue('@Folder', $Folder)
        [void]$cmd.ExecuteNonQuery()

        # $select keeps the payload small; never pull bodies for an inventory
        $select = 'id,receivedDateTime,from,subject,isRead,hasAttachments,inferenceClassification'
        if ($IncludeHeaders) { $select += ',internetMessageHeaders' }
        $expand = "singleValueExtendedProperties(`$filter=id eq 'Integer 0x0E08')"
        $uri = "v1.0/me/mailFolders/$Folder/messages?`$select=$select&`$expand=$expand&`$top=1000"
    }

    # One reusable, parameterized command: the JSON is passed as data, never concatenated into SQL
    $load = $conn.CreateCommand()
    $load.CommandType = 'StoredProcedure'
    $load.CommandText = 'dbo.usp_LoadMessagePage'
    $load.CommandTimeout = 300
    [void]$load.Parameters.Add('@Folder', 'VarChar', 50)
    [void]$load.Parameters.Add('@Json', 'NVarChar', -1)          # -1 = nvarchar(max)
    $pNext = $load.Parameters.Add('@NextLink', 'NVarChar', -1); $pNext.Direction = 'Output'
    $pRows = $load.Parameters.Add('@Rows', 'Int');             $pRows.Direction = 'Output'
    $load.Parameters['@Folder'].Value = $Folder

    $total = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()

    while ($uri) {
        # Raw REST call through the SDK's auth; the SDK retries on 429 throttling
        $load.Parameters['@Json'].Value = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Json
        [void]$load.ExecuteNonQuery()

        $total += $pRows.Value
        $uri = if ($pNext.Value -is [DBNull]) { $null } else { $pNext.Value }
        Write-Host ("{0:N0} messages  ({1:hh\:mm\:ss} elapsed)" -f $total, $timer.Elapsed)
    }

    Write-Host "Done. Loaded $total messages from '$Folder' into $Database."
}
finally {
    $conn.Dispose()
}
