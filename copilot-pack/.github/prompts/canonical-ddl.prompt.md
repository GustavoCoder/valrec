---
mode: agent
description: One-time prompt — canonical (core) + reference (ref) + matching (match) DDL, from the settled data model
---
Generate the canonical, reference, and matching schema DDL under
**src/Valrec.Infrastructure/Sql/core/**, **/ref/**, and **/match/** — one .sql file per
object. Plain idempotent SQL (IF NOT EXISTS), no EF migrations.

CONTEXT
- Data model + column lists: #file:docs/specs/matching-rules.md, #file:docs/specs/break-keys.md,
  and the canonical model in the architecture doc (GlobalPosition, LocalPosition,
  PositionMatchable view, CanonicalMeasure, ref.MeasureNameMap, ref.ProductClassMap, match.MatchRule).
- Rules: #file:.github/instructions/sql.instructions.md

TABLES
- core.GlobalPosition — lean global side. Columns per the architecture data model
  (BusinessDate, System, Division, PositionKey, MatchingKey, ResolvedMatchKey, BookId,
  BookName, InstrumentId, ISIN, MaturityDate, Amount, Product, ProductType, Notional,
  UnderlyingPrice, InstrumentType, FileId). Clustered columnstore.
- core.LocalPosition — rich local side. The full LocalPosition column set (matching spine +
  SubBook, LocalBookId, SourceSystem, SecurityCode, PricingClass, AssetName, PositionType,
  Currency, TransactionId, FixingDate, ErrorMessage, SourceErrorMessage, plus
  ResolvedMatchKey). Clustered columnstore.
- core.PositionMatchable — VIEW projecting the common matching spine + ResolvedMatchKey +
  Side literal ('G'/'L') as a UNION ALL of the two position tables. This is what the engine
  joins on.
- core.CanonicalMeasure — unified, side-discriminated (Side CHAR(1) G|L), tall/narrow:
  BusinessDate, System, Division, Side, PositionKey, SourceMeasure, CanonicalMeasure,
  Dimension NULL, Underlying NULL, Value DECIMAL(28,8), Currency CHAR(3) NULL, Unit NULL,
  FxRateApplied DECIMAL(28,8) NULL, FileId. Clustered columnstore.
- ref.MeasureNameMap — System, Side, SourceMeasure, CanonicalMeasure (+ audit cols).
  Unique on (System, Side, SourceMeasure).
- ref.ProductClassMap — System, Side, SourceProductValue, CanonicalProduct (+ audit).
  Must be able to emit MM-OPEN / MM-SIG. Unique on (System, Side, SourceProductValue).
- match.MatchRule — System, Product, Side, ColumnOrder (NVARCHAR, JSON array of column
  names in order), EffectiveFrom, Version, audit cols. Unique on
  (System, Product, Side, EffectiveFrom).

TYPES & CONVENTIONS
- DECIMAL(28,8) for amounts/measures/rates; DATE for BusinessDate/MaturityDate/FixingDate;
  DATETIME2(3) UTC for audit timestamps. Money never FLOAT.
- Matching spine columns (BusinessDate, System, Division, MatchingKey, ResolvedMatchKey,
  BookId, ISIN) must be IDENTICAL in type/collation across GlobalPosition and LocalPosition
  so the view UNION and the engine join align — use a consistent collation explicitly.
- ref/match tables are rowstore (small, read-often); core tables columnstore.

SEED DATA (separate files under ref/ and match/, clearly marked as seed)
- match.MatchRule seed: the full 14-row table from matching-rules.md, both sides, as
  ColumnOrder JSON (e.g. MOR/Futures/G -> ["ISIN","BookId"]).
- Leave ref.MeasureNameMap and ref.ProductClassMap seeds as TEMPLATE files with the
  column structure and a comment: "populate from DISTINCT source values per sample —
  see matching-rules.md". Do not invent mapping values.

CONSTRAINTS
- No recon/ops/thr/just/rpt/audit schemas (separate work). No EF. No application code.
- If any column's type or nullability is unspecified by the referenced docs, STOP and list
  the gaps rather than guessing.
