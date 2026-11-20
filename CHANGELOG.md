# Changelog

All notable changes to SysOrg. Versions follow [SemVer](https://semver.org/).

## [2.1.0] - 2026-11-20 - Windows-native, type-first, numbered copies

Revision 2.1 (milestone M4, work items W1-W12) - see `ORGANIZATION-DESIGN.md`.

### Added
- **Drive hierarchy profiler (W1):** `Get-SysOrgDriveProfile` + `-ProfileDrives` and menu option 1
  produce one profile per volume - role (System / Removable / Data), detection evidence, protected
  artifacts found at the root, resolved known folders (with redirection and OneDrive flags),
  download roots, top-level tree and the proposed writable scope. **No plan is built without a profile.**
- **Known-folder resolver (W2):** real known-folder locations are resolved from the registry
  (`User Shell Folders`, legacy names + GUIDs). A redirected Pictures folder on D is scoped on D;
  OneDrive-backed folders carry the sync-out warning. Localized category recognition preserves
  intact structures (a German `Bilder` folder is recognized as Pictures-like and left alone).
- **Mutability engine (W3):** `Test-SysOrgFileMutable` gates every record before it can appear in a
  plan. The writable scope on C is the resolved known folders plus configurable
  `Policy.SystemDrive.WritablePaths` (or `-WritablePath` on the CLI); `FullDrive` is rejected for the
  system drive at config validation. Blocked extensions (`.dll .sys .drv .ocx .cpl .scr` + `.lnk .url`
  on C) with the installer-in-download-roots exception. Denials are recorded per file with reasons
  and summarized in the preview, so "untouched" is provable.
- **PerceivedType fallback (W4):** unmapped extensions route by the Windows `PerceivedType` registry
  value (`image` -> Pictures, `video` -> Videos, `system` -> never moved); config `TypeMap` overrides win.
- **Windows naming preset (W4):** main folders are now `Documents, Pictures, Videos, Music, Downloads`;
  `Archives`, `Code`, `Other` live under Documents and `Installers` routes to the Downloads branch.
  `NamingPreset='Compact4'` restores the rev 2.0 naming (Documents, Photo, Video, Downloads).
- **Type-first name families (W5):** related files share one named family folder WITHIN their type
  root; related files across types get the SAME family name in each root (`holiday.jpg` ->
  `Pictures\holiday\`, `holiday.mp4` -> `Videos\holiday\`, linked by the plan audit field `Family`).
  Nothing crosses the type boundary (`Families.WithinTypeOnly=$true`); `CrossTypeLink='Dominant'`
  restores rev 2.0 behavior as an opt-in.
- **Numbered copies (W6):** `Copies.Policy='NumberCopies'` is the new default. Exact copies are
  kept and numbered beside the original (`Report.docx`, `Report (2).docx`, `Report (3).docx`);
  the keeper is the OLDEST LastWriteTime, then natural name order. Nothing is quarantined or
  deleted. `Quarantine` remains opt-in; `ReportOnly` lists copies without moving anything.
  Undo restores every original name and path.
- **Natural sort (W7):** preview trees, family ordering and copy numbering use Explorer ordering
  (`StrCmpLogicalW`, with a portable fallback) - `file (2)` before `file (10)`.
- **OneDrive sync-out warning + double confirmation (W8):** moves out of a OneDrive root are listed
  and COUNTED IN THE CONFIRMATION PROMPT; `DestinationStyle='KnownFolders'` requires a second
  explicit confirmation (`yes`).
- **Per-drive artifact auto-protection (W9):** `WindowsApps`, `XboxGames`, `Boot`, `MSOCache`,
  `PerfLogs` are protected at the root of EVERY drive, extending P1-7.
- **Migration (W12):** `-Migrate` (CLI and menu option 7) builds a previewable, journal-backed plan
  that maps old v1.x / rev 2.0 trees (Photo/Images -> Pictures, Video -> Videos, Audio and
  Video\Audio -> Music, ...); `_Duplicates` and `_Reports` folders are left untouched.
- **Code project folders:** marker-bearing folders (`.git`, `package.json`, `*.sln`, ...) move whole
  as one MoveFolder unit to `Documents\Projects\Code\<Name>` - `.git` intact.
- **Multipart archives:** `name.zip.001/002`, `name.part1.rar/.r00` sets move as one unit; members
  are exempt from numbering and quarantine.
- **Preview renderer:** two-level destination tree (natural-sorted, counts + bytes per node),
  mutability summary grouped by denial reason, families/copies table, OneDrive warnings.
- **Zone.Identifier reattachment** after verified cross-volume copies (rev 2.0 D7) and download
  provenance: full URLs are stored ONLY in the local `Plans\<PlanId>-provenance.csv` sidecar.
- **Folder safe-move primitive** with copy -> count/byte verify -> remove semantics and the same
  never-overwrite guarantees as files.

### Changed
- **Config v2.1 (W10):** `Duplicates` -> `Copies` and `Categories` -> `TypeMap` are mapped on load
  with deprecation warnings, so v1.x/2.0 configs keep working (old `Policy='Quarantine'` is
  preserved). `Test-SysOrgConfig` now validates NamingPreset, DestinationStyle, Copies.Policy,
  SuffixStyle, Downloads.GroupBy, Families.MinFiles >= 2, Copies.StartIndex >= 2, the mutability
  Scope values and MainFolders-vs-preset.
- Scan roots now include the known folders resolved for the scanned drive (P1-6 + W2).
- The undo journal gained a `Kind` column (File/Folder); folder rows undo with the folder primitive.
- File-level "project clusters" were REPLACED by name families; the `ProjectDetection` config key
  maps to `Projects.Enabled`.

### CI note
The parse gate, PSScriptAnalyzer and the Pester suite (now including `Tests/SysOrg.Rev21.Tests.ps1`
covering the section-14 fixtures) run on every push.

## [1.2.0] - 2026-11-19

Safety, data-integrity and robustness release (improvement plan P0..P3).

### CI first-run fixes (this tag was re-published after the first CI run failed)
The initial v1.2.0 CI run failed 16 of 49 tests on Windows PowerShell 5.1. All
root causes were fixed and the release was rebuilt from the green commit:
- **Hex-literal trap (all runtimes).** `Test-SysOrgDirAccess` built
  `GENERIC_READ` from `0x80000000`, which PowerShell parses as a NEGATIVE Int32
  (two's complement for 8-digit hex with the high bit set); the `[uint32]` cast
  threw on every call, so every folder-safety probe and inventory scan crashed.
  The access mask is now the decimal literal `2147483649`.
- **`-f` inside method-call argument lists (all runtimes).** PowerShell binds
  the format operator only to its immediate next expression inside a method
  call, so `$writer.WriteLine('fmt' -f a, b, c)` formatted with ONE argument
  and threw FormatException on the first journal write of every plan
  execution. All three journal writes now format into a variable first.
- **Empty-array return idiom.** `return ,$array` leaks its one-element wrapper
  under Pester capture (and differs by host), so `Find-SysOrgDuplicates` /
  `Get-SysOrgInventory` results appeared as `@(@())`. Both functions now
  stream their records; every caller collects with `@()`.
- **Join-Path on a non-existent drive.** `New-SysOrgPlan` threw (silently
  swallowed per-file) when the destination root's drive letter was not present
  on the machine; destinations are now built by concatenation.
- **PS 5.1 enum gaps.** `RecallOnDataAccess` (0x400000) does not exist in the
  .NET Framework `FileAttributes` enum, so casting threw; attribute checks are
  raw-int based now, with a new exported `Test-SysOrgCloudPlaceholderAttributes`
  helper (same behavior on 5.1 and 7).
- **Wildcard exclusion subtrees.** `C:\Users\*\AppData` now also excludes
  everything BELOW the matched path, not just the exact match.
- **Junction fixture.** The reparse test uses `New-Item -ItemType Junction`
  (no elevation needed) instead of fragile `cmd /c mklink` quoting.
- **Test-fixture correctness.** The duplicate fixture used a `MinFileSizeKB=1`
  threshold against 20-byte files (no group could ever form); the cluster
  fixture used the stopword 'final' / short tokens / numbers the module
  deliberately filters, and a 2-char CJK stem below the >= 3 stem gate.
- **Portability hardening.** The Win32 writability probe degrades to a .NET
  check on non-Windows hosts (test runners); qualifier-less paths no longer
  crash `Test-SysOrgDestinationPath` / protection-reason logic; Windows-only
  tests are marked inconclusive off-Windows instead of failing.

### Verified review claims (P0)
- **P0-1 / P0-2 / P0-3 / P0-5 (review artifacts - verified not reproducible).** A
  static review claimed the published v1.0.0 tree did not parse (stripped casts in
  `Write-Progress`, `int64.Sum`, bare `void`, discarded config). A byte-level diff of
  the published ZIP, the git history and the working tree found all three identical
  and clean; every file parses. The permanent **CI parse gate** (below) now
  guarantees this on every push, which is the P0-5 remedy.
- **P0-4 (real bug - fixed).** `-ScheduledReport` read `$d.Letter`, but
  `Get-SysOrgDrive` exposes the letter as `Drive` (formatted `"C:"`). Named-drive
  scheduled reports could never run; every report attempt failed. The branch now
  trims `$d.Drive` and report-only scans run as designed.

### Added
- **CI (P3-1):** `.github/workflows/ci.yml` - parse gate on every PowerShell file,
  PSScriptAnalyzer at Error severity, and the Pester suite on Windows PowerShell 5.1.
- **Pester suite (P3-2):** `Tests/` covering config merge/validation, unique paths,
  safe-move guarantees, copy-only mode, exclusion segment matching, header hashing,
  marker-tree exclusion, cloud-placeholder skip, cache keying, clustering stability,
  execute-undo round trip, re-execution guard, resume, hash-mismatch undo skip and
  the drive confidence ladder with mocked CIM objects.
- **Scan scope (P1-6):** default scans start in existing profile folders
  (`ScanRoots`: Desktop, Documents, Downloads, Pictures, Videos, Music) instead of
  the whole drive root. Whole-drive scans need `-FullDrive`. Plan preview lists the
  affected top-level folders (blast radius).
- **Copy-only cross-volume mode (P1-10):** `Move.AllowCrossVolume = $false` now
  performs a verified copy and keeps every source, as the README always promised;
  `CopiedVerified` is counted as `Copied`, never as `Moved`.
- **Re-execution guard + resume (P1-3):** executing a plan that already has an undo
  journal throws with guidance; `-Force` resumes and skips journaled sources.
- **Undo content verification (P1-4):** journal rows with a `ContentHash` are
  re-hashed before restore; changed files are skipped (`SkippedChanged`) instead of
  blindly restored.
- **Cache invalidation (P1-9):** inventory cache files are keyed to the SHA256 of
  the config file and the scan scope; any config edit forces a rescan. `-NoCache`
  is exposed on the CLI; scheduled reports never read cache.
- **Cloud-placeholder safety (P1-5):** files with the `Offline` or
  `RecallOnDataAccess` attributes (OneDrive files-on-demand) are never opened, so a
  scan/execute cannot silently hydrate a cloud library.
- **Long-path recording (P2-5):** files at or above 260 characters of path are
  recorded with category `SkippedLongPath`, excluded from plans, and surfaced in
  scan output and previews (PowerShell 5.1 limit; documented).
- **`Test-SysOrgConfig` (P0-3):** config validation at startup - invalid
  `DateFolders`, `Duplicates.Policy`, non-negative integer keys or out-of-range
  ratios throw immediately instead of misbehaving at move time.
- **MIT LICENSE** and this changelog (P3-4).
- **Comment-based help (P3-6)** on all exported functions (`Get-Help <cmd> -Full`).

### Changed
- **Incremental undo journal (P1-1):** the journal is appended and flushed after
  every completed action (StreamWriter, AutoFlush) instead of being written once
  after the whole run. A crash, Ctrl+C or power loss mid-run leaves a journal of
  exactly the completed moves, and those moves are undoable.
- **Every execution path previews and confirms (P1-2):** menu option 5 now shares
  the CLI preview + explicit-confirm flow; there is no execute-without-preview path.
- **Exclusion matching (P1-7):** root-less single-segment patterns (`$Recycle.Bin`,
  `System Volume Information`, `Recovery`, `OneDriveTemp`) now match any path
  segment on any drive (`D:\Recovery` is protected; `D:\Projects\Recovery-notes`
  is not). Windows, Program Files, ProgramData, Recycle Bin, System Volume
  Information and Recovery are appended for **every** fixed drive at startup.
- **`.sysorg-ignore` excludes its whole tree (P1-8):** the traversal check skips
  any directory containing the marker, including all subfolders.
- **Hash economy (P2-1):** same-volume moves are no longer hashed before moving;
  cross-volume and quarantine actions hash only when the journal needs it and reuse
  the scan-time duplicate hash when available. Collision checks compare sizes before
  hashing either file.
- **Complete header reads (P2-2):** `Get-SysOrgFileHash -HeaderOnly` loops until the
  buffer is filled; a short read can no longer hash an uninitialized buffer tail.
- **Drive detection (P2-7):** MediaType 5 (SCM) is mapped; README documents the
  eSATA/Thunderbolt caveat.
- **Installer (P2-9):** execution policy change is now opt-in (`-SetExecutionPolicy`);
  the schtasks fallback quotes paths with spaces correctly (`\"`).
- **Installers/uninstallers (P2-8):** honor `ScheduledTaskName` from the config file.
- **Diagnostics (P2-10):** empty catch blocks now log via `Write-Verbose`; hot
  accumulation paths (`Drives` results, report lines, duplicate/cluster lists) use
  `System.Collections.Generic.List` instead of `+=` array growth.
- **Stable clustering (P2-6):** token signatures are order-independent (sorted,
  de-duplicated, then truncated to three); non-ASCII stems produce a `cluster` slug
  fallback instead of an empty key.

### Removed
- **`RemoveEmptySourceDirs` config key (P2-8):** the key was never implemented; it
  was removed rather than shipping dead configuration. SysOrg never deletes folders.

### Notes
- P3-7 (branch protection) requires repository admin settings and cannot be
  automated from CI; enable "Require status check: validate" on `main`.

## [1.1.0] - 2026-11-19

### Added
- **Folder safety audit:** classifies every folder as **Protected** (cannot alter),
  **Restricted** (read-only, left in place) or **Organizable**, using a
  non-destructive directory-handle probe, Defender Controlled Folder Access lists,
  config exclusions and access checks. Menu option `[2]` / `SysOrg.ps1 -AuditDrive C`;
  full map saved to `<Root>\_Reports\SysOrg-FolderAudit-*.txt`. Scans gate on the
  same classification and skip protected / read-only trees.

## [1.0.0] - 2026-11-19

### Added
- Initial release: preview-first pipeline (scan - classify - correlate - duplicate
  hash - plan - preview - explicit confirm - execute), type-first organization with
  year folders, conservative project clustering, duplicate quarantine, collision-safe
  moves, undo journal, drive detection with confidence model, report-only scheduled
  task.
