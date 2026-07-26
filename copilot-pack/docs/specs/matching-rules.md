# Spec: Match-Key Resolution & Matching Rules

How a global position and a local position are decided to be the same trade. Matching is
**product-dependent** and **global-anchored** (for each global position, find its local
counterpart). The intelligence lives in a config-driven registry resolved during
canonicalization (phase 2), so the recon engine (phase 3) joins on one uniform key.

## ResolvedMatchKey
Each canonical position carries two keys:
- `MatchingKey` — raw source-provided value, kept for audit/investigation.
- `ResolvedMatchKey` — the normalized key the two sides are actually compared on, built by
  concatenating an ordered list of source columns (per the rule for that System+Product+Side),
  each canonicalized: trimmed, upper-cased, `|`-joined, null component → `~NULL~`.

The engine joins global vs local on `(BusinessDate, System, Division, ResolvedMatchKey)`.
`PositionKey` is a separate, side-local key used only to link measures to their position
within a side — never across sides.

## Rule registry (`match.MatchRule`)
Config-as-data, audited. One row per (System, Product, Side): an ordered `ColumnOrder[]`
of source columns projected into ResolvedMatchKey. Composite rules list 2 columns; both
sides must list their columns in the same semantic order (instrument component first, book
component second) or the concatenations won't align.

| System | Product | Global columns | Local columns | Shape |
|---|---|---|---|---|
| GR | Listed | ISIN, BookId | ISIN, BookId | symmetric composite |
| GR | OTC | MatchingKey | TransactionId | asymmetric single |
| GR | NDF | MatchingKey | SecurityCode | asymmetric single |
| GR | Flex Options | ISIN | ISIN | symmetric single |
| APEX | (all) | MatchingKey | MatchingKey | symmetric single (identity) |
| MOR | Futures | ISIN, BookId | ISIN, BookId | symmetric composite |
| MOR | FX Spot | MatchingKey | TransactionId | asymmetric single |
| MOR | FX Forward | MatchingKey | TransactionId | asymmetric single |
| MOR | NDF | MatchingKey | SecurityCode | asymmetric single |
| MOR | MM-OPEN | MatchingKey, BookId | MatchingKey, BookId | symmetric composite |
| MOR | MM-SIG | MatchingKey | TransactionId | asymmetric single |
| MUREX | Bonds | MatchingKey, BookId | SecurityCode, BookId | mixed composite (asym + sym) |
| MUREX | Notes | MatchingKey, BookId | SecurityCode, BookId | mixed composite (asym + sym) |
| MUREX | XCCY | MatchingKey | TransactionId | asymmetric single |

## Product classification (`ref.ProductClassMap`)
The resolver must know each position's Product before it can pick the rule. Global carries
`ProductType`, local carries `PricingClass`/`PositionType` — different vocabularies. A
per-(System, Side) map normalizes source product values to the canonical Product names used
in the rule table above. Unmapped source product → **hard failure at assembly** (listed for
file owners), never a silent default.

### MM Open vs SIG discriminator
MOR money-market positions split into MM-OPEN and MM-SIG by **the global MatchingKey**:
if it carries the Open marker (`OP`), the position classifies MM-OPEN; otherwise MM-SIG.
- Encode the marker as an explicit positional/delimited token match, NOT `LIKE '%OP%'`
  (which false-matches incidental "OP" elsewhere in the key). Exact token location TBC —
  confirm with a real Open MatchingKey sample.
- Classification test vectors (required): a real Open key → MM-OPEN; a real SIG key → MM-SIG;
  a SIG key containing an incidental "OP" elsewhere → MM-SIG.
- A money-market global key matching neither the Open marker nor the expected SIG shape →
  hard classification failure (consistent with fail-loud everywhere else).

## Rules
1. Missing rule for a (System, Product) → hard failure at canonicalization. No implicit default.
2. ResolvedMatchKey built in phase 2 (assembler), never in the engine. Both assemblers
   (global, local) use one shared `MatchKeyResolver` reading `match.MatchRule`.
3. Break identity uses ResolvedMatchKey (see break-keys.md), never raw MatchingKey or PositionKey.

## Cardinality — [TBC: run before finalizing]
`TransactionId`-based rules are expected 1:1. The **SecurityCode**-based rules — GR NDF,
MOR NDF, MUREX Bonds, MUREX Notes — may be many-to-one (one SecurityCode over multiple
positions). Run per (System, Product):
`SELECT ResolvedMatchKey, COUNT(*) FROM <side> GROUP BY ResolvedMatchKey HAVING COUNT(*) > 1`
- All unique → matching is 1:1; a non-unique ResolvedMatchKey at recon time is a hard error.
- Any non-unique → define aggregation: sum measures across the shared-key group and compare
  at the ResolvedMatchKey grain. Document the exact grain here once known.
