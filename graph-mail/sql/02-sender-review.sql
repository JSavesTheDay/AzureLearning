/*
    Builds the sender review list: one row per high-volume sender, with a suggested action.
    Re-running refreshes the stats but never overwrites a Decision you've made.
    Run with:  sqlcmd -S . -E -d MailInventory -i graph-mail/sql/02-sender-review.sql

    Mark decisions in SSMS / VS Code, or e.g.:
        UPDATE dbo.SenderReview SET Decision = 'keep' WHERE FromAddress = 'AmericanExpress@welcome.americanexpress.com';
        UPDATE dbo.SenderReview SET Decision = Suggested WHERE Decision IS NULL AND Suggested = 'remove';
*/
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.SenderReview') IS NULL
CREATE TABLE dbo.SenderReview
(
    FromAddress  nvarchar(320) NOT NULL CONSTRAINT PK_SenderReview PRIMARY KEY,
    Messages     int           NOT NULL,
    Unread       int           NOT NULL,
    ReadPct      decimal(4,1)  NOT NULL,
    SizeMB       decimal(10,1) NOT NULL,
    Oldest       date          NOT NULL,
    Newest       date          NOT NULL,
    Suggested    varchar(10)   NOT NULL,
    Decision     varchar(10)   NULL CONSTRAINT CK_SenderReview_Decision CHECK (Decision IN ('keep', 'remove', 'archive'))
);
GO

DECLARE @MinMessages int = 100;

MERGE dbo.SenderReview AS t
USING (
    SELECT  FromAddress, Messages, Unread, ReadPct, SizeMB, Oldest, Newest,
            -- Heuristic: rarely read = remove; occasionally read = look closer
            CASE WHEN ReadPct < 5  THEN 'remove'
                 WHEN ReadPct < 25 THEN 'review'
                 ELSE 'keep' END AS Suggested
    FROM (
        SELECT  FromAddress,
                COUNT(*) AS Messages,
                SUM(CASE WHEN IsRead = 0 THEN 1 ELSE 0 END) AS Unread,
                CAST(100.0 * SUM(CAST(IsRead AS int)) / COUNT(*) AS decimal(4,1)) AS ReadPct,
                CAST(SUM(CAST(SizeBytes AS bigint)) / 1048576.0 AS decimal(10,1)) AS SizeMB,
                CAST(MIN(ReceivedUtc) AS date) AS Oldest,
                CAST(MAX(ReceivedUtc) AS date) AS Newest
        FROM dbo.Message
        WHERE FromAddress IS NOT NULL
        GROUP BY FromAddress
        HAVING COUNT(*) >= @MinMessages
    ) AS s
) AS s
ON t.FromAddress = s.FromAddress
WHEN MATCHED THEN UPDATE SET
    Messages = s.Messages, Unread = s.Unread, ReadPct = s.ReadPct, SizeMB = s.SizeMB,
    Oldest = s.Oldest, Newest = s.Newest, Suggested = s.Suggested
WHEN NOT MATCHED THEN INSERT (FromAddress, Messages, Unread, ReadPct, SizeMB, Oldest, Newest, Suggested)
    VALUES (s.FromAddress, s.Messages, s.Unread, s.ReadPct, s.SizeMB, s.Oldest, s.Newest, s.Suggested);

SELECT Suggested, COUNT(*) AS Senders, SUM(Messages) AS Messages, SUM(SizeMB) AS SizeMB
FROM dbo.SenderReview
GROUP BY Suggested
ORDER BY Suggested;
