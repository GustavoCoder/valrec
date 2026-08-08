/* ============================================================================
   Seed: ops.FileWatcher   (DB: BrazilDataHub_ValRec)
   Matches actual schema: FileWatcherId, System, Division, FileType, Folder,
     FilenameRegex, ExpectedCutoffTime, CalendarId, Enabled, Version,
     CreatedAtUtc, UpdatedAtUtc.

   Notes on this schema:
     * No Side / SourceSystem / Mandatory columns here (by design).
       - Mandatory vs optional lives in ops.FileManifest.
       - RISCO source system is encoded in FileType (RISCO_GR, RISCO_MOR_IB, ...)
         so each feed is a distinct watcher row; the orchestrator derives the
         RISCO SourceSystem stamp from FileType.
     * Natural key for the MERGE: (System, Division, FileType).

   BEFORE RUNNING — replace placeholders with real values:
     Folder, FilenameRegex (test in the regex panel first), ExpectedCutoffTime,
     CalendarId. Rows are inserted DISABLED (Enabled=0); enable per feed once
     folder + regex + cutoff are confirmed.
   ============================================================================ */
USE [BrazilDataHub_ValRec];
GO

;WITH seed (System, Division, FileType, Folder, FilenameRegex, ExpectedCutoffTime, CalendarId) AS
(
    SELECT * FROM (VALUES
    -- ===== GR – IB (global) =====
    ('GR',   'IB', 'BrazilRec',          '\\share\valrec\in\gr\',    N'(?i)^BrazilRec_\d{8}\.txt$',          CAST('18:30' AS time), 'BR'),
    ('GR',   'IB', 'BrazilAttribution',  '\\share\valrec\in\gr\',    N'(?i)^BrazilAttribution_\d{8}\.txt$', CAST('18:30' AS time), 'BR'),
    ('GR',   'IB', 'MRCErrors',          '\\share\valrec\in\gr\',    N'(?i)^MRC_Errors_\d{8}\.txt$',        CAST('18:30' AS time), 'BR'),

    -- ===== MOR – IB (global) =====
    ('MOR',  'IB', 'Positions',          '\\share\valrec\in\mor\ib\', N'(?i)^MOR_Positions_\d{8}\.csv$',    CAST('19:00' AS time), 'BR'),
    ('MOR',  'IB', 'Measures',           '\\share\valrec\in\mor\ib\', N'(?i)^MOR_Measures_\d{8}\.csv$',     CAST('19:00' AS time), 'BR'),
    ('MOR',  'IB', 'FXRates',            '\\share\valrec\in\mor\ib\', N'(?i)^MOR_FXRates_\d{8}\.csv$',      CAST('19:00' AS time), 'BR'),

    -- ===== MOR – GT (global) =====
    ('MOR',  'GT', 'Positions',          '\\share\valrec\in\mor\gt\', N'(?i)^MOR_Positions_\d{8}\.csv$',    CAST('19:00' AS time), 'BR'),
    ('MOR',  'GT', 'Measures',           '\\share\valrec\in\mor\gt\', N'(?i)^MOR_Measures_\d{8}\.csv$',     CAST('19:00' AS time), 'BR'),
    ('MOR',  'GT', 'FXRates',            '\\share\valrec\in\mor\gt\', N'(?i)^MOR_FXRates_\d{8}\.csv$',      CAST('19:00' AS time), 'BR'),

    -- ===== APEX – GT (global) =====
    ('APEX', 'GT', 'ApexFile',           '\\share\valrec\in\apex\',   N'(?i)^APEX_\d{8}\.txt$',             CAST('19:30' AS time), 'BR'),

    -- ===== MUREX – GT (global) =====
    ('MUREX','GT', 'MurexFile',          '\\share\valrec\in\murex\',  N'(?i)^MUREX_\d{8}\.txt$',            CAST('19:30' AS time), 'BR'),

    -- ===== RISCO (local) — source system encoded in FileType =====
    ('GR',   'IB', 'RISCO_GR',           '\\share\valrec\in\risco\',  N'(?i)^RISCO_GR_\d{8}\.txt$',         CAST('20:00' AS time), 'BR'),
    ('MOR',  'IB', 'RISCO_MOR_IB',       '\\share\valrec\in\risco\',  N'(?i)^RISCO_MOR_IB_\d{8}\.txt$',     CAST('20:00' AS time), 'BR'),
    ('MOR',  'GT', 'RISCO_MOR_GT',       '\\share\valrec\in\risco\',  N'(?i)^RISCO_MOR_GT_\d{8}\.txt$',     CAST('20:00' AS time), 'BR'),
    ('APEX', 'GT', 'RISCO_APEX',         '\\share\valrec\in\risco\',  N'(?i)^RISCO_APEX_\d{8}\.txt$',       CAST('20:00' AS time), 'BR'),
    ('MUREX','GT', 'RISCO_MUREX',        '\\share\valrec\in\risco\',  N'(?i)^RISCO_MUREX_\d{8}\.txt$',      CAST('20:00' AS time), 'BR')
    ) AS v(System, Division, FileType, Folder, FilenameRegex, ExpectedCutoffTime, CalendarId)
)
MERGE ops.FileWatcher AS tgt
USING seed AS src
   ON  tgt.System   = src.System
   AND tgt.Division = src.Division
   AND tgt.FileType = src.FileType
WHEN MATCHED THEN UPDATE SET
       tgt.Folder             = src.Folder,
       tgt.FilenameRegex      = src.FilenameRegex,
       tgt.ExpectedCutoffTime = src.ExpectedCutoffTime,
       tgt.CalendarId         = src.CalendarId,
       tgt.Version            = tgt.Version + 1,
       tgt.UpdatedAtUtc       = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
   INSERT (System, Division, FileType, Folder, FilenameRegex, ExpectedCutoffTime,
           CalendarId, Enabled, Version, CreatedAtUtc, UpdatedAtUtc)
   VALUES (src.System, src.Division, src.FileType, src.Folder, src.FilenameRegex,
           src.ExpectedCutoffTime, src.CalendarId, 0, 1, SYSUTCDATETIME(), SYSUTCDATETIME());
GO
-- Inserted rows are DISABLED (Enabled=0). Enable per feed after confirming
-- folder + regex + cutoff and passing the watcher regex test panel:
--   UPDATE ops.FileWatcher SET Enabled = 1, Version = Version + 1,
--          UpdatedAtUtc = SYSUTCDATETIME()
--   WHERE System = '...' AND Division = '...' AND FileType = '...';