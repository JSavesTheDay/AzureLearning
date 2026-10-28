# graph-mail

Analyze and clean up an Office 365 / Exchange Online mailbox with the **Microsoft Graph PowerShell SDK**, using **SQL Server** as the local analysis store.

## What it demonstrates

- Delegated auth to Microsoft Graph with `Connect-MgGraph` (Entra ID, OAuth 2.0)
- Least privilege: `Mail.Read` to analyze, `Mail.ReadWrite` only when changing mail
- `$select` / `$expand` to keep payloads small; manual paging with `@odata.nextLink`
- Reading a MAPI property (message size, `0x0E08`) through extended properties
- Loading raw JSON into typed tables with T-SQL `OPENJSON`, idempotent upserts with `MERGE`
- Resumable bulk loads: rows and the next-page link are committed in one transaction

The T-SQL here runs unchanged on Azure SQL Database.

## Layout

| File | Purpose |
|---|---|
| `sql/01-schema.sql` | Creates the `MailInventory` database, tables and load procedure (idempotent) |
| `Export-MailboxInventory.ps1` | Pages through a mail folder via Graph and loads it into SQL Server |
| `sql/summary.sql` | Reporting queries: senders, domains, age, unread, size |

Mailbox data lives only in the local database, never in the repo.

## Prerequisites

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Mail -Scope CurrentUser
```

- Install only the Graph submodules you need; the `Microsoft.Graph` rollup is 40+ modules.
- SQL Server 2022 (Developer Edition is free for non-production) with `sqlcmd`, patched to the
  latest CU. Windows authentication is used throughout, so no passwords are stored.

## Run it

```powershell
# 1. Create the database (safe to re-run)
sqlcmd -S . -E -i graph-mail/sql/01-schema.sql

# 2. Sign in to Graph (read-only). The token is cached per user, so later sessions reuse it.
Connect-MgGraph -Scopes "Mail.Read" -NoWelcome
Get-MgContext                      # confirm account and scopes

# 3. Load the Inbox (large folders take a while; -Resume continues an interrupted run)
./graph-mail/Export-MailboxInventory.ps1

# 4. Analyze
sqlcmd -S . -E -d MailInventory -W -i graph-mail/sql/summary.sql

# 5. Sign out when done
Disconnect-MgGraph
```

`sqlcmd` flags: `-S .` local default instance, `-E` Windows auth, `-d` database, `-W` trim column padding, `-i` input file.

## Further reading

- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/overview)
- [Outlook mail API overview](https://learn.microsoft.com/graph/outlook-mail-concept-overview)
- [Graph paging](https://learn.microsoft.com/graph/paging) and [throttling](https://learn.microsoft.com/graph/throttling)
- [Graph permissions reference](https://learn.microsoft.com/graph/permissions-reference#mail-permissions)
- [OPENJSON (T-SQL)](https://learn.microsoft.com/sql/t-sql/functions/openjson-transact-sql)
- [SQL Server servicing (CU vs GDR)](https://learn.microsoft.com/troubleshoot/sql/releases/servicing-models-sql-server)
