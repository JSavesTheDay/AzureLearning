/*
    Mailbox summary. Offline; no Graph calls.
    Run with:  sqlcmd -S . -E -d MailInventory -W -i graph-mail/sql/summary.sql
    Or open in SSMS / VS Code (mssql extension) and run sections individually.
*/
SET NOCOUNT ON;

PRINT '=== Export progress ===';
SELECT Folder, Loaded, CASE WHEN NextLink IS NULL THEN 'complete' ELSE 'partial' END AS State, UpdatedUtc
FROM dbo.ExportState;

PRINT '=== Overview ===';
SELECT  COUNT(*)                                        AS Messages,
        SUM(CASE WHEN IsRead = 0 THEN 1 ELSE 0 END)     AS Unread,
        SUM(CASE WHEN Focused = 'other' THEN 1 ELSE 0 END) AS Other,
        SUM(CAST(IsBulk AS int))                        AS BulkMail,     -- NULL if headers not collected
        CAST(SUM(CAST(SizeBytes AS bigint)) / 1048576.0 AS decimal(10,1)) AS TotalMB,
        CAST(MIN(ReceivedUtc) AS date)                  AS Oldest
FROM dbo.Message;

PRINT '=== Age ===';
SELECT  Bucket, COUNT(*) AS Messages, SUM(CASE WHEN IsRead = 0 THEN 1 ELSE 0 END) AS Unread
FROM dbo.Message
CROSS APPLY (SELECT CASE
        WHEN ReceivedUtc >= DATEADD(day,   -30, SYSUTCDATETIME()) THEN '1: <= 30 days'
        WHEN ReceivedUtc >= DATEADD(month,  -6, SYSUTCDATETIME()) THEN '2: 1-6 months'
        WHEN ReceivedUtc >= DATEADD(year,   -1, SYSUTCDATETIME()) THEN '3: 6-12 months'
        ELSE '4: > 1 year' END AS Bucket) AS b
GROUP BY Bucket
ORDER BY Bucket;

PRINT '=== Top senders ===';
SELECT TOP (25)
        FromAddress,
        COUNT(*)                                        AS Messages,
        SUM(CASE WHEN IsRead = 0 THEN 1 ELSE 0 END)     AS Unread,
        CAST(100.0 * SUM(CASE WHEN IsRead = 0 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(4,1)) AS UnreadPct,
        SUM(CASE WHEN Focused = 'other' THEN 1 ELSE 0 END) AS Other,
        CAST(SUM(CAST(SizeBytes AS bigint)) / 1048576.0 AS decimal(10,1)) AS SizeMB,
        CAST(MAX(ReceivedUtc) AS date)                  AS Newest
FROM dbo.Message
GROUP BY FromAddress
ORDER BY Messages DESC;

PRINT '=== Top domains ===';
SELECT TOP (25)
        FromDomain,
        COUNT(*)                                        AS Messages,
        COUNT(DISTINCT FromAddress)                     AS Senders,
        SUM(CASE WHEN IsRead = 0 THEN 1 ELSE 0 END)     AS Unread,
        CAST(SUM(CAST(SizeBytes AS bigint)) / 1048576.0 AS decimal(10,1)) AS SizeMB
FROM dbo.Message
GROUP BY FromDomain
ORDER BY Messages DESC;

PRINT '=== Cleanup candidates: senders you never read (10+ messages, 0 read) ===';
SELECT  FromAddress, COUNT(*) AS Messages,
        CAST(MIN(ReceivedUtc) AS date) AS Oldest, CAST(MAX(ReceivedUtc) AS date) AS Newest
FROM dbo.Message
GROUP BY FromAddress
HAVING COUNT(*) >= 10 AND SUM(CAST(IsRead AS int)) = 0
ORDER BY Messages DESC;

PRINT '=== Largest messages ===';
SELECT TOP (15)
        CAST(SizeBytes / 1048576.0 AS decimal(10,1)) AS SizeMB,
        CAST(ReceivedUtc AS date) AS Received, FromAddress, LEFT(Subject, 80) AS Subject
FROM dbo.Message
ORDER BY SizeBytes DESC;
