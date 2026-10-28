/*
    MailInventory schema. Idempotent: safe to re-run.
    Run with:  sqlcmd -S . -E -i graph-mail/sql/01-schema.sql
*/
-- sqlcmd (ODBC) defaults QUOTED_IDENTIFIER OFF; persisted computed columns need it ON,
-- and procedures capture the setting at creation, so set it explicitly for the whole script
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
IF DB_ID('MailInventory') IS NULL
    CREATE DATABASE MailInventory;
GO
USE MailInventory;
GO

IF OBJECT_ID('dbo.Message') IS NULL
CREATE TABLE dbo.Message
(
    -- Graph ids are case-sensitive, so use a binary collation for the key
    Id              varchar(255) COLLATE Latin1_General_BIN2 NOT NULL CONSTRAINT PK_Message PRIMARY KEY,
    Folder          varchar(50)    NOT NULL,
    ReceivedUtc     datetime2(0)   NOT NULL,
    FromName        nvarchar(256)  NULL,
    FromAddress     nvarchar(320)  NULL,
    FromDomain      AS LOWER(SUBSTRING(FromAddress, CHARINDEX('@', FromAddress) + 1, 320)) PERSISTED,
    Subject         nvarchar(max)  NULL,
    IsRead          bit            NOT NULL,
    HasAttachments  bit            NOT NULL,
    Focused         varchar(10)    NULL,
    IsBulk          bit            NULL,     -- NULL = headers not collected
    SizeBytes       int            NULL,
    LoadedUtc       datetime2(0)   NOT NULL CONSTRAINT DF_Message_LoadedUtc DEFAULT SYSUTCDATETIME(),
    Status          varchar(20)    NULL      -- set by the cleanup phase (archived, deleted...)
);
GO

-- Supports the "group by sender" reporting queries
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Message_FromAddress')
    CREATE INDEX IX_Message_FromAddress ON dbo.Message (FromAddress) INCLUDE (IsRead, SizeBytes, ReceivedUtc);
GO

IF OBJECT_ID('dbo.ExportState') IS NULL
CREATE TABLE dbo.ExportState
(
    Folder      varchar(50)    NOT NULL CONSTRAINT PK_ExportState PRIMARY KEY,
    NextLink    nvarchar(max)  NULL,     -- NULL = export finished
    Loaded      int            NOT NULL,
    UpdatedUtc  datetime2(0)   NOT NULL
);
GO

/*
    Upserts one Graph page (the raw JSON response) and records the next-page link,
    in one transaction, so a crash never leaves rows and state out of step.
*/
CREATE OR ALTER PROCEDURE dbo.usp_LoadMessagePage
    @Folder   varchar(50),
    @Json     nvarchar(max),
    @NextLink nvarchar(max) OUTPUT,
    @Rows     int           OUTPUT
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;

    BEGIN TRANSACTION;

    MERGE dbo.Message WITH (HOLDLOCK) AS t
    USING (
        SELECT  j.id,
                CAST(j.receivedDateTime AS datetime2(0)) AS ReceivedUtc,
                j.fromName, j.fromAddress, j.subject, j.isRead, j.hasAttachments,
                j.inferenceClassification,
                CASE WHEN j.headers IS NULL THEN NULL
                     WHEN EXISTS (SELECT 1 FROM OPENJSON(j.headers) WITH (name nvarchar(200))
                                  WHERE name = 'List-Unsubscribe') THEN 1
                     ELSE 0 END AS IsBulk,
                j.sizeBytes
        FROM OPENJSON(@Json, '$.value') WITH (
                id                      varchar(255)   '$.id',
                receivedDateTime        datetimeoffset '$.receivedDateTime',
                fromName                nvarchar(256)  '$.from.emailAddress.name',
                fromAddress             nvarchar(320)  '$.from.emailAddress.address',
                subject                 nvarchar(max)  '$.subject',
                isRead                  bit            '$.isRead',
                hasAttachments          bit            '$.hasAttachments',
                inferenceClassification varchar(10)    '$.inferenceClassification',
                headers                 nvarchar(max)  '$.internetMessageHeaders' AS JSON,
                sizeBytes               int            '$.singleValueExtendedProperties[0].value'
             ) AS j
    ) AS s
    ON t.Id = s.id
    WHEN MATCHED THEN UPDATE SET
        Folder = @Folder, ReceivedUtc = s.ReceivedUtc, FromName = s.fromName, FromAddress = s.fromAddress,
        Subject = s.subject, IsRead = s.isRead, HasAttachments = s.hasAttachments,
        Focused = s.inferenceClassification, IsBulk = COALESCE(s.IsBulk, t.IsBulk),
        SizeBytes = s.sizeBytes, LoadedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (Id, Folder, ReceivedUtc, FromName, FromAddress, Subject, IsRead, HasAttachments, Focused, IsBulk, SizeBytes)
        VALUES (s.id, @Folder, s.ReceivedUtc, s.fromName, s.fromAddress, s.subject, s.isRead,
                s.hasAttachments, s.inferenceClassification, s.IsBulk, s.sizeBytes);

    SET @Rows = @@ROWCOUNT;
    SET @NextLink = JSON_VALUE(@Json, '$."@odata.nextLink"');

    MERGE dbo.ExportState AS t
    USING (SELECT @Folder AS Folder) AS s ON t.Folder = s.Folder
    WHEN MATCHED THEN UPDATE SET NextLink = @NextLink, Loaded = t.Loaded + @Rows, UpdatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (Folder, NextLink, Loaded, UpdatedUtc) VALUES (@Folder, @NextLink, @Rows, SYSUTCDATETIME());

    COMMIT;
END;
GO
