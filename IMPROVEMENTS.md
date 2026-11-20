# SysOrg Improvement Plan — Review Tracker

Companion to `ORGANIZATION-DESIGN.md` and `CHANGELOG.md`. The original v1.0.0 review produced a
numbered improvement plan (P0..P3), organized into milestones M1-M3. Every item below is
implemented and shipped in **v1.2.0**; milestone **M4** (revision 2.1, work items W1-W12) is
tracked at the bottom.

## M1 — P0 (correctness, blocking)

| ID | Item | Status |
|---|---|---|
| P0-1 | Static claim "published tree does not parse" — verified not reproducible; CI parse gate added | Done (v1.2.0) |
| P0-2 | Duplicate report sums / empty-result capture idiom (`return ,$array` trap) — streaming returns, callers collect with `@()` | Done (v1.2.0) |
| P0-3 | Config validation fails loudly at startup (`Test-SysOrgConfig`) | Done (v1.1.0), extended (v2.1.0) |
| P0-4 | `-ScheduledReport` read a non-existent `Letter` property; named-drive reports never ran | Fixed (v1.2.0) |
| P0-5 | Permanent CI parse gate on every push | Done (v1.2.0) |

## M2 — P1 (safety and robustness)

| ID | Item | Status |
|---|---|---|
| P1-1 | Incremental undo journal: appended + flushed after EVERY completed action (crash-safe) | Done (v1.2.0) |
| P1-2 | One shared preview -> confirm -> execute path for CLI and menu | Done (v1.2.0) |
| P1-3 | Re-execution guard with resume: a journaled plan is refused; `-Force` resumes, skipping journaled sources | Done (v1.2.0) |
| P1-4 | Undo verifies content hashes and skips files changed since the move (`SkippedChanged`) | Done (v1.2.0) |
| P1-5 | Cloud placeholders (Offline / RecallOnDataAccess) never opened — scanning cannot hydrate OneDrive | Done (v1.2.0) |
| P1-6 | Default scan scope narrowed to profile folders (`ScanRoots`); whole-drive scans need `-FullDrive` | Done (v1.2.0) |
| P1-7 | System locations protected on EVERY fixed drive, not just C (root-less segment matching) | Done (v1.2.0), extended by W9 (v2.1.0) |
| P1-8 | `.sysorg-ignore` marker excludes its whole tree | Done (v1.2.0) |
| P1-9 | Inventory cache keyed to scope + config content hash | Done (v1.2.0) |
| P1-10 | `Move.AllowCrossVolume=$false` performs verified copy-only; sources always kept | Done (v1.2.0) |

## M3 — P2/P3 (quality)

| ID | Item | Status |
|---|---|---|
| P2-1 | Hash economy: compare sizes before hashing; hash only when the journal needs it | Done (v1.2.0) |
| P2-2 | Header hash loops until the buffer is filled (short-read trap on filtered volumes) | Done (v1.2.0) |
| P2-3 | Drive enumeration happens once and is reused | Done (v1.2.0) |
| P2-4 | One bad drive/folder never kills the whole app (menu error isolation) | Done (v1.2.0) |
| P2-5 | Reparse points (files and dirs) never followed; long paths recorded, never planned | Done (v1.2.0) |
| P2-6 | Token signature is order-independent (sorted + deduplicated before comparison) | Done (v1.2.0) |
| P2-7 | SCM media type mapped in the drive confidence ladder | Done (v1.2.0) |
| P2-8 | Scheduled task name read from config | Done (v1.2.0) |
| P2-9 | Execution-policy change is opt-in; `schtasks` quoting fallback | Done (v1.2.0) |
| P3-1 | CI: parse gate + PSScriptAnalyzer (Error severity) + Pester on Windows PowerShell 5.1 | Done (v1.2.0) |
| P3-2 | README rewritten around the safety model | Done (v1.2.0) |
| P3-3 | PSScriptAnalyzer settings with documented exceptions | Done (v1.2.0) |

## M4 — Revision 2.1 (work items W1-W12, target v2.1.0)

Tracked in `ORGANIZATION-DESIGN.md` section 13. Implemented in **v2.1.0**:

| ID | Title | Status |
|---|---|---|
| W1 | Drive profiler (`Get-SysOrgDriveProfile`) and `-ProfileDrives`; no plan builds without a profile | Done (v2.1.0) |
| W2 | Known-folder resolver (`Get-SysOrgKnownFolders`) + localized category recognition | Done (v2.1.0) |
| W3 | Mutability engine (`Test-SysOrgFileMutable`) with denial reasons in the preview | Done (v2.1.0) |
| W4 | PerceivedType registry fallback + Windows/Compact4 naming presets | Done (v2.1.0) |
| W5 | Type-first name families within partitions, cross-type same-name link | Done (v2.1.0) |
| W6 | Numbered copies policy (default), plan-time assignment, reversible via undo | Done (v2.1.0) |
| W7 | Natural sort (`StrCmpLogicalW` with a portable fallback) everywhere user-visible | Done (v2.1.0) |
| W8 | OneDrive sync-out warning counted in the confirmation prompt; KnownFolders destination double-confirm | Done (v2.1.0) |
| W9 | Per-drive artifact auto-protection (WindowsApps, XboxGames, Boot, MSOCache, PerfLogs on every fixed drive) | Done (v2.1.0) |
| W10 | Config v2.1 + validation + Duplicates-to-Copies (and Categories-to-TypeMap) deprecation mapping | Done (v2.1.0) |
| W11 | Tests for W1-W10 (`Tests/`), green in CI on Windows PowerShell 5.1 | Done (v2.1.0) |
| W12 | Migration preview `-Migrate` from rev 2.0/1.x trees; `_Duplicates` untouched | Done (v2.1.0) |
