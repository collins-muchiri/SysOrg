# Changelog

All notable changes to SysOrg. Versions follow [SemVer](https://semver.org/).

## [3.0.2] - 2026-11-23 - The plan-build crash and the OneDrive regression, found in a real run

Driven by a real Windows 11 run on Windows PowerShell 5.1: option 3 failed twice,
identically, right after 'Code project folders detected: 3' with
'[ERROR] Menu action failed: Argument types do not match'; OneDrive
Documents/Pictures/Desktop were skipped as 'cannot alter' and the scanned file
count fell from 9,579 to 1,570; the cache printed ' file(s) reused' (blank) with
'1572 changed' for 1,570 scanned files; `proj\deploy\windows` was flagged
'System location (never alter)' purely by its folder name; option 5 asked for a
plan with no list; and the whole session produced nothing a supporter could read.
Every v3.0 guarantee is preserved: preview first, never overwrite, never delete,
crash-safe undo, protected paths and mutability always win, deterministic and
idempotent plans.

### Fixed (Phase A - the crash)
- **A2 THE PLAN-BUILD CRASH, root-caused and reproduced:** `@()` collecting the
  walk's `New-Object`-created `System.Collections.Generic.List[object]`
  (`$walkPreserved`, filled through the C2 `PreservedOut` out-parameter) throws
  `ArgumentException: Argument types do not match` - the engine's
  `PSToObjectArrayBinder` -> `PSEnumerableBinder.MaybeDebase` builds an
  `Expression.Condition` whose branch types do not match. The site lived in the
  menu/CLI scan FLOW, which no module-level test executed - the suite stayed
  green while option 3 crashed. Reproduced END-TO-END through the real flow with
  the new smoke test (the reverted code fails with exactly that message), fixed
  by `.ToArray()` before collection, and an AST audit over the whole repo proved
  these were the only three remaining sites. While wiring the harness a second
  hand-off defect fell out: the D2 picker's chosen roots and the remembered scan
  roots never reached the walk - the inventory re-resolved the scope from the
  config and silently scanned folders the user had deselected; chosen/remembered
  roots now reach the walk via `-Roots`.
- **A1 failures are diagnosable:** the menu catch-all and every CLI entry point
  log the exception TYPE, message, `ScriptStackTrace` and
  `InvocationInfo.PositionMessage` to the log file (Write-SysOrgErrorDiagnostic),
  print a one-line message pointing at the log and the honest phase verdict -
  'Nothing was modified.' before execution, the undo-journal warning during it
  (a script-scope phase flag set only around mutating calls). The last error is
  kept for -Diagnostics.
- **A3 `-SelfTest` (menu option 11):** builds a fresh `SysOrgSelfTest-<guid>`
  tree under the system temp area and runs the WHOLE pipeline exactly as a real
  run would - fixture, inventory walk, duplicate detection, project detection,
  plan build, preview, save, execute into the temporary destination, undo,
  byte-for-byte restore check - with a [PASS]/[FAIL] verdict per step; a failure
  logs the full diagnostic, prints the stack head and KEEPS the tree for
  inspection. Real user folders are never touched.
- **A4 support-friendly diagnostics:** every interactive session auto-writes a
  transcript to `Logs\last-run.txt`; `.\SysOrg.ps1 -Diagnostics` (menu option 12)
  bundles the real version, PowerShell and OS versions, elevation, the config
  file with its SHA256, the last 200 log lines and the last error with its stack
  into `Logs\diagnostics-<timestamp>.txt`.

### Fixed (Phase B - OneDrive and reparse points)
- **B1 reparse points are classified by TAG, not the attribute:** the 0x400
  ReparsePoint attribute alone conflated junctions and symlinks with OneDrive
  cloud folders. `Get-SysOrgReparseTag` reads the actual tag
  (`WIN32_FIND_DATA.dwReserved0` via FindFirstFileW; constants from the
  documented Windows set: SYMLINK 0xA000000C, MOUNT_POINT 0xA0000003, cloud
  family 0x90000000-0x9000F001) through a test seam (in-process mock +
  `SYSORG_REPARSE_MOCK` env). Symlinks, junctions and unknown tags are never
  followed; cloud folders are NORMAL folders - traversed, listed, planned - while
  placeholder FILES (Offline / RecallOnDataAccess) are still never opened or
  hashed. The inventory walk, the folder audit, the similar-folder walk and the
  scan-root options walk all classify by tag now. OneDrive roots are scanned
  again.
- **B2 a dropped scan root is never silent:** the walk records every dropped
  INITIAL root with its reason; the scan summary prints
  'N scan root(s) were NOT scanned - they are NOT part of this plan:' with
  'Documents was NOT scanned: <reason>' lines, and the plan header carries the
  count in the skip taxonomy plus a WARNING naming each root.
- **B3 legacy junctions skip quietly:** `Documents\My Pictures / My Videos /
  My Music` (on every Windows profile) are PRESERVED entries with reason
  'legacy junction (expected)' - no longer alarming 'cannot alter' rows.
- **B4 name-based system rules are scoped:** 'windows', 'intel', 'drivers',
  'dell', 'hp', 'appdata', ... protect only drive-root level (`X:\windows`,
  `X:\dell`) or known absolute system parents (C:\Windows, C:\Program Files,
  C:\ProgramData, ...). `proj\deploy\windows` inside a project tree is a normal,
  scannable folder; `C:\Windows` stays protected.

### Fixed (Phase C - cache honesty and speed)
- **C1 cache statistics add up:** the four counters (reused / changed / new /
  removed) are ALWAYS present, the filters run BEFORE the accounting so
  reused + changed + new == the files scanned (the real run's '1572 changed' for
  1,570 scanned files came from counting placeholders that were then filtered
  out), 'Removed' counts cache records whose file no longer exists, the summary
  prints all four plus the scanned count, and a rebuild is STATED
  ('cache rebuilt: scanner version changed / config changed / cache unreadable')
  now that the cache format is versioned ({ScannerVersion, Records}).
- **C2 profile-first throughput:** profiled on a deterministic 6,301-file corpus
  - enumerate+classify already ran at ~5,000-6,300 files/s on the profiling host
  (target >= 1,000; the real run's ~90 files/s covered the whole flow). The top
  three measured hotspots fixed: per-file Get-SysOrgCategory (41.7 us x files,
  ~21% of the walk) now memoizes per DISTINCT extension; per-file/per-directory
  exclusion matcher calls are skipped entirely when the config has no rules; the
  reparse-tag env mock is parsed once per distinct value instead of per call.

### Added (Phase D - usability)
- **D1 option 5 explains itself:** the 10 newest plans are listed before the
  prompt; an empty or missing plans folder prints 'No saved plans in <folder>.'
  with the pointer to option 3 instead of silently asking for input that cannot
  match. The prompt still accepts a number, id, full path or folder.
- **D2 the menu header shows the real version** from the config - the hardcoded
  'rev 2.1' survived the whole 3.x line.
- **D3 duplicate reports are grouped by folder pair:** the preview prints the
  top 5 groups with counts ('C:\dl vs C:\dl: 30 file(s)') instead of 41 raw
  pairs, for BOTH the version pairs and the numbered copies; the full list of
  every group row and pair goes to `Reports\SysOrg-DuplicateReport-<PlanId>.txt`
  (created on demand; report-only).
- **D4 a plan that cannot be built** reports the cause in one line plus the log
  path and OFFERS the -Diagnostics bundle right there; 'Nothing was modified.'
  is always part of the message.

### Internal
- New test files: the end-to-end smoke suite (real `Invoke-SysOrgScanFlow` over
  the crash fixture; Windows CI legs additionally run the real child process
  `SysOrg.ps1 -ScanDrive <subst-drive> -ReportOnly -FullDrive` on Windows
  PowerShell 5.1 AND pwsh 7 over a subst-mapped fixture with a real junction and
  a mocked cloud tag), self-test suite, diagnostics suite, reparse/tag suite,
  cache-statistics suite, menu suite. The v3.0.1 C3 cache test's Changed
  assertion was updated to the honest changed/new split.

### Fixed (CI - the first real Windows CI leg)
- The Windows PowerShell 5.1 leg failed with 7 tests (432 passed / 7 failed); all
  seven were fixture/portability defects, proven against the CI log, none weakened:
  - **The smoke harness doubled every separator** in the remembered scan roots:
    `-replace '\\','\\'` writes TWO literal backslashes per match (the `-replace`
    replacement string is not escape-processed), so `C:\Users\...` became
    `C:\\Users\\...`, reached the walk via `ScanRoots.json`, and the `\\?\`
    access probe - which performs NO normalization - refused it with
    `ERROR_INVALID_NAME` (123); the whole fixture collapsed to "Nothing was
    scanned". Paths are now written verbatim (ConvertTo-Json does the escaping).
  - **The Win32 access probe collapses doubled separators** before building the
    `\\?\` path (a leading UNC `\\` is preserved), so a hand-edited
    `ScanRoots.json` can never again wedge the probe into error 123.
  - **The child-process fixture config satisfied no config validator:**
    `ReviewConfidence=0.0` violates the shipped contract (MinConfidence must be
    below ReviewConfidence; 0.70 is the default) - the fixture now uses 0.70.
  - **The "uncreatable folder" fixtures were creatable** on a clean runner
    (`C:\definitely\missing\...` did not exist yet); they now place the path
    under a real FILE, which is uncreatable on every host.
  - **The reparse `Unknown` assertion was portable-host-only:** on Windows the
    real resolver CAN read the tag of a plain folder, so the correct answer is
    `None` there; `Unknown` stays the non-Windows contract. The test now asserts
    each platform's exact deterministic outcome.

## [3.0.1] - 2026-11-23 - Defects from a real run; classification that fits real usage

Driven by a real Windows 11 run (C: system NVMe + A: data NVMe, 9,579 files) whose
findings became the regression fixtures: a drive-relative audit bug, a scoring
verdict that could call an 11-of-9,579 plan "worsens", a mutability line that
counted preserved files as denied, and classification that put provenance above
content. All v3.0 guarantees are preserved: preview first, never overwrite, never
delete, crash-safe undo, protected paths and mutability always win, deterministic
plans, idempotent re-runs.

### Fixed (Phase A - defects)
- **A1 Folder audit root bug:** the audit walked 'X:' (slash stripped) - a
  DRIVE-RELATIVE path that .NET resolves against the drive's CURRENT directory - so
  auditing from a subfolder audited the app folder and reported error 2 for every
  child ('C:.github', 'C:Cache', ...). The root now stays 'X:\' for enumeration and
  probes; every path passes the new `ConvertTo-SysOrgPath`, which REJECTS
  drive-relative forms (`^[A-Za-z]:(?![\\])`) and '.'/'..' segments.
- **A2 Scoring correctness:** the plan score delta compares before/after over the
  SAME population (untouched + moved files at their before AND after locations) -
  never a whole-tree 'before' against a moved-files-only 'after'. An empty tree or
  fewer than 20 files scores 'n/a', never 100. Verdicts are honest about scale:
  an affected share below 5% reads 'no meaningful change (11 of 9,500 files
  affected)' and can never read 'worsens'.
- **A3 Honest skip taxonomy:** 'Mutability: N denied (provably never touched)' is
  replaced by three separate groups - Protected/denied (mutability engine),
  Preserved by design (organized-folder heuristic, project units, user
  collections), Left for a decision (low confidence) - plus per-reason counts with
  one example each and the untouched percentage. Headline:
  '9,579 scanned: 11 planned, 9,518 preserved, 50 protected, 0 need a decision.'
- **A4 Source buckets:** AI and chat sources map to buckets (z.ai -> Z-AI,
  chat.z.ai, meta.ai -> Meta-AI, claude.ai -> Claude, chatgpt.com/openai.com ->
  OpenAI, gemini.google.com -> Gemini) alongside the existing hosts, with
  public-suffix-aware registrable domains (co.ke, go.ke, co.uk, com.au, ...).
  Bucket names shorter than 3 characters fall back to the full host label. The map
  is extensible in `Rules\Sources.psd1`; every bucket passes
  `Get-SysOrgSafeFolderName`; a broken map file fails closed.
- **A5 Family folder names:** over-limit names truncate on a WORD boundary with a
  deterministic 4-character hash suffix ('Peer Education Support Supervision
  Report-a3f9'); the longest common word-prefix of the members wins over the
  longest stem; the 200-character total path budget stays enforced.
- **A6 Startup noise:** every module imports with `-DisableNameChecking` - the
  menu starts clean.

### Added (Phase B - layout and classification that fit real usage)
- **B1 Provenance is metadata, not taxonomy:** under the Findable layout, files
  from Downloads route by CONTENT like every other file (Documents\Work\<Year>,
  Pictures\..., Software\Installers\<App>); the source lives in the catalog's
  Source field and -Explain, and becomes a folder level ONLY for messaging sources
  and Screenshots. No `_NoSource` and no generic source-bucket folders in the
  Findable tree. The old behaviour stays behind `LayoutProfile = Windows` /
  `Compact4`.
- **B2 Respect user collections:** a user-named folder inside a scanned root
  (`Folders.PreserveUserCollections`, default on; bounded: <= 200 files, <= 3
  levels deep; not generic/date/auto-generated) is treated as ONE unit and moved
  whole (structure intact, never flattened) to the destination chosen by the
  majority classification of its contents - e.g. Documents\Work\UNDP - or left in
  place when the confidence is low. The preview lists collections separately.
  Fixture: a UNDP folder with a nested Workshop subfolder stays together.
- **B3 Self-supervised learning:** before classifying, a small multinomial naive
  Bayes model is built from the files ALREADY living in the user's curated folders
  (existing subfolders of the known folders in scope, plus `Learn.FromPaths`);
  filename tokens, extensions, metadata title/author tokens and the first 2 KB of
  text are features; labels need >= 5 files and a posterior margin >= 0.5; a
  single-label model is never trusted. Stored in `<root>\_Index\model.json`
  (versioned by an input fingerprint, rebuilt only on change). It NEVER moves
  anything by itself: it feeds the confidence pipeline like any other signal and
  appears in `-Explain`. `.\SysOrg.ps1 -Learn` prints what it learned and the
  labels it trusts.
- **B4 Lexicon extension:** monitoring & evaluation and NGO programme vocabulary
  (MEAL, M&E, narrative/monthly/quarterly report, concept note, supervision,
  workplan, logframe, indicator, baseline, endline, training, workshop,
  curriculum, TOR/terms of reference, MoU, budget) and CV/bio/profile terms,
  mapped to Documents\Work, Documents\Education, Documents\Legal-Identity and
  Documents\Personal. Filename, Office docProps title/creator and text-snippet
  matches carry separate, LOGGED weights ('Lexicon: Work score=4 (filename 4,
  metadata 0, content 1.6) -> confidence=0.72').
- **B5 Duplicates for small documents:** the 256 KB size floor now applies to media
  and installers only; documents and data files use `Copies.DocMinFileSizeKB`
  (default 0). Browser re-download pairs 'name(1).ext'/'name (1).ext' are
  recognized: hash-identical pairs collapse into the copies policy; pairs that
  differ are flagged 'possible newer version' in the preview with sizes and
  modified times (report-only).
- **B6 Review experience:** when more than half of the planned moves are below the
  review threshold, the plan is NOT a ready-to-execute default: the review offers
  [A] approve only confident moves (>= 0.70), [R] review the low-confidence moves
  one by one (accept / skip / set destination - saved as a rule), [S] skip all
  uncertain files, [N] cancel. Each low score shows its REASON
  ('no lexicon match, extension only'), not just 'conf 0.5'.

### Added (Phase C - speed, profiled first)
- **C1 `-Timing`:** per-phase wall times (enumerate / duplicates / plan). Profiled
  on a 3,151-file corpus; the top hotspots fixed: the mutability policy resolved
  once per (config, profile) instead of per file (2.4x per call), the TypeMap and
  excluded-file regexes compiled once per config (reference-identity cached - a
  config-hash key would itself cost ms/file), and the lexicon + rules files parsed
  ONCE per run instead of once per file (PSD1 parsing was 10-30 s of the observed
  112 s scan profile on real installs). The walk hoists all per-file settings.
- **C2 Prune during the walk:** dependency directories (node_modules, .venv, venv,
  site-packages, vendor, __pycache__, .next, dist, build, target, .gradle,
  bower_components, Pods, .git) are never descended into - counted as PRESERVED
  without enumerating their files - and code projects (VCS marker or two markers)
  are detected in the same single pass (the separate depth-4 walk is gone). On the
  9,500-file fixture (99% inside projects) the inventory reads 95 files in ~0.3 s.
- **C3 Cache freshness:** the 24-hour whole-inventory cache is validated, never
  trusted: the walk always re-enumerates (cheap, streaming) and reuses a cached
  record only when size AND mtime still match; the preview states the cache age and
  the changed count; a plan never references a file that no longer exists.
- **C4/C5:** exclusions are compiled once per run (hash set + one regex, identical
  semantics, regression-tested); the 'Other' category reports its top unknown
  extensions (count + bytes) so they can be mapped via TypeMap (report-only).

### Added (Phase D - usability and safety on data drives)
- **D1 Plan picker:** option 5 lists the 10 newest plans (id, drive, moves, age,
  executed status) and accepts a number, a plan id, a full path or a folder.
  Re-running an IDENTICAL scan reuses the existing not-executed plan (input
  fingerprint) instead of creating a duplicate.
- **D2 Scan-root picker:** on Data/Removable drives FullDrive is no longer the
  silent default - top-level folders are shown with risk labels (project, VCS
  repo, note vault (.obsidian), model store (ollama/models/...), app store,
  installer collection, OS/tool folder) and the choice is remembered per drive in
  Config\ScanRoots.json. Vault/model/app/VCS/OS folders are excluded by default
  and never moved.
- **D3 Similar-folder report:** folders fingerprinted by their file-hash sets;
  pairs with >= 80% overlap (e.g. '-v1' copies) listed with sizes and dates.
  REPORT ONLY - never moved or merged.
- **D4/D5:** a warning when the SysOrg app folder sits inside a scan root
  (it stays protected); option 10 on a tree with no files prints 'No organized
  tree yet.', not a score.

### Internal
- Two PowerShell portability classes caught by the real 5.1 CI leg and fixed:
  `.Count` on a Where-Object scalar is $null on 5.1 (pwsh 7 gives every object the
  intrinsic Count=1) - assertions @()-wrapped; `Join-Path` with 3 arguments is
  pwsh 7-only - nested 2-arg form. Collection truthiness (an empty List/hashtable
  is $false) had silently swallowed audit-trail writes - now $null-checked.
- The Learn model trains ONLY on the drive profile's known folders (in scope) -
  not on registry-resolved real folders of the machine.

## [3.0.0] - 2026-11-22 - Faster, smarter, more findable (Findable layout + scored pipeline)

The layout becomes a choice (`LayoutProfile = Windows | Compact4 | Findable`; new
installs default to Findable, existing configs keep their current profile), the
extension-only router becomes a scored Decision pipeline, large drives get a
persistent file-state cache and parallel hashing, and the organized tree gets a
catalog you can actually search. All v2.1.1 hardening guarantees are preserved:
preview before execute, never overwrite, never delete user data, crash-safe undo,
executor re-validation, fail-closed config, non-overridable protection floor.

### Added
- **Phase 0 (measurement):** `Tools/New-SysOrgCorpus.ps1` (deterministic synthetic
  corpus with REAL EXIF/ID3/MP4/PDF fixtures, ~5% exact duplicates, a metadata
  manifest) and `-Benchmark` (cold/warm scan, duplicate detection, plan build,
  execute, peak working set -> `Reports\benchmark-*.md`). Baselines and final
  numbers live in `BENCHMARKS.md`.
- **Phase 1 (Findable layout):** max depth 4 below the root, 10 routing roots,
  adaptive ISO date granularity (YYYY -> YYYY-MM -> YYYY-MM-DD above
  `Layout.MaxFilesPerFolder`, merged back up when mostly near-empty - the cap
  wins), a 200-character path budget with deterministic hash-suffixed shortening,
  family leaves kept date-free, "needs a decision" handling (never a junk folder;
  optional `_Review` via `Review.Mode`).
- **Phase 2 (classification):** a fixed-order Decision pipeline (safety gates >
  user rules > learned rules > context > true type > metadata > date > lexicon >
  confidence gating) producing Destination/Confidence/RuleId/Signals; magic-byte
  true-type sniffing (<= 512 bytes) for missing/mismatched extensions; zero-
  dependency, mockable, fail-soft metadata extractors (EXIF, ID3v2/v1, MP4 mvhd,
  Office core.xml, PDF info dict, 2 KB text snippet); date resolution (metadata >
  filename > filesystem, source recorded); `Rules\Lexicon.psd1` weighted document
  scoring; event clustering (GPS cell + time gap -> `Pictures\Events\<range>`);
  near-duplicate image dHash (REPORT ONLY); confidence gating (>= 0.70 plans,
  0.40-0.70 flagged review, < 0.40 needs a decision); `Rules\UserRules.psd1`
  (validated fail-closed) and learned rules that are NEVER applied silently
  (`Rules.ApplyLearned`, flagged in the preview). `-Explain <path>` prints the
  full Decision.
- **Phase 3 (speed):** persistent file-state cache (`Cache\filestate.ndjson`,
  streamed, corrupt->rescan fallback); compiled exclusion matcher; RunspacePool
  parallel hashing (deterministic order, HDD throttling via the drive profile's
  MediaType); head+tail hash duplicate pre-filter; in-memory destination name
  sets; batched directory creation; buffered logging with the undo journal still
  flushed per row.
- **Phase 4 (find things):** `_Index\catalog.ndjson` built after every executed
  plan and updated by undo; `Find-SysOrgFile` + `-Find` + menu search (instant,
  live-scan fallback); offline `_Index\Index.html` (no network); warn-only
  Windows Search status check; `_Index\README.txt`.
- **Phase 5 (measurable findability):** `Get-SysOrgFindabilityScore` (depth,
  fan-out percentiles, over-cap/near-empty shares, confidence shares, duplicate
  byte share, composite 0-100), targets in `Score.Targets`, before/after delta in
  the plan preview, `-Score` for existing trees.
- **Phase 6 (migration):** `-MigrateProfile Findable` migrates a v2.1 tree to the
  Findable layout - previewable, journaled, undoable, whole-folder moves, adaptive
  date re-bucketing, idempotent, `_Index`/`_Reports`/`_Duplicates` untouched.
- **Property tests:** determinism, idempotence (a second run plans ZERO moves),
  conservation (hash multiset survives execute), depth/root/collision bounds,
  protected-path exclusion; Perf-tagged tests excluded from the default CI run.

### Changed
- Plan-build now runs the full classifier per routed file (the honest cost is
  documented in BENCHMARKS.md: cold plan-build is ~1.6x the v2.1.1 baseline; warm
  duplicate detection is 5.1x faster; execute is unchanged).
- Data-type files (csv/tsv/xlsx/json/db) route to the `Data` leaf in the Findable
  layout via their extension (the Windows routing set calls them Documents).
- `New-SysOrgPlan` skips source==destination files (idempotent re-plans).

### Compatibility
- Existing configs keep working unchanged: a config file without `LayoutProfile`
  keeps the Windows profile; `NamingPreset='Compact4'` still maps to Compact4;
  existing plans, journals and configs are honored; new config keys all have
  safe defaults validated in `Test-SysOrgConfig`.

## [2.1.1] - 2026-11-22 - Security and quality hardening (audit follow-up)

Hardening release based on a full security/quality audit of v2.1.0. All core guarantees
are preserved (never overwrite, never delete user data, preview before execute, crash-safe
undo journal). Public function names and CLI parameters are unchanged; new helpers follow
the `*-SysOrg*` naming.

### Added
- **Executor re-validation (High #1):** `Invoke-SysOrgPlan` treats the plan JSON as untrusted
  input. Every action is re-validated at execution time: canonical path forms
  (`Get-SysOrgCanonicalPlanPath` - no `..` segments, no 8.3 short names, no `\\?\` namespace,
  absolute only), exclusion re-check on the source parent, reparse-point and cloud-placeholder
  refusals, mutability re-check against a fresh drive profile for the plan's drive, and
  destination containment inside the plan root (or resolved known folders when
  `DestinationStyle='KnownFolders'`). Validation failures are recorded per action as `Failed`
  with a reason - a bad action never aborts the whole run. The executor summary now counts
  `Skipped`.
- **Plan integrity hash:** `Save-SysOrgPlan` stores a SHA256 of the canonical action list
  (`Get-SysOrgPlanIntegrityHash`); the executor verifies it and refuses a hand-edited or
  corrupted plan unless `-Force` is passed (loud warning either way).
- **Plan-time snapshot:** every file action carries `PlannedLength` and
  `PlannedLastWriteTimeUtc`; sources that changed since planning are skipped
  (`changed since plan`) and counted as `Skipped`. Older plans without the snapshot are
  handled gracefully with a warning.
- **Tamper-proof undo:** `Undo-SysOrgPlan` validates the `PlanId` format and canonicalizes
  and re-checks every journal row's `CurrentLocation` and `OriginalSource` - a tampered
  journal cannot move arbitrary files.
- **Fail-closed configuration (High #2):** a config file that exists but cannot be parsed
  now makes `Import-SysOrgConfig` THROW. Report-only/scheduled sessions may pass
  `-AllowDegradedMode` (or run `-ScheduledReport`, which does) to continue with safe
  defaults after a loud warning.
- **Non-overridable protection floor:** `$env:SystemRoot`, `$env:ProgramFiles`,
  `${env:ProgramFiles(x86)}`, `$env:ProgramData`, plus `$Recycle.Bin` and
  `System Volume Information` at every fixed drive root are ALWAYS appended to
  `ExcludedPaths` after the merge, independent of `Policy.ProtectedArtifacts`.
- **Additive protection merges:** `Policy.ProtectedArtifacts` and the per-scope
  `BlockedExtensions` lists merge additively (`Join-SysOrgProtectedList`) - a user config
  can add entries but cannot remove built-ins; removal attempts are re-added with a warning.
- **`Resolve-SysOrgWritablePath`:** `-WritablePath` input is resolved to a full canonical
  path (a relative path used to be stored raw and never matched).
- **Known-folder sanity check:** `Test-SysOrgKnownFolderPath` rejects known folders
  redirected to a drive root, the profile root, or a parent of the Windows / Program Files
  folders (ignored with a warning).
- **Multi-label public suffixes (item 3):** `Get-SysOrgSourceBucket` honors a compact
  table of common second-level suffixes - `www.kra.go.ke` -> `Kra`,
  `safaricom.co.ke` -> `Safaricom`, `example.co.uk` -> `Example`. IP-address hosts and
  `localhost` fall through to the filename heuristics; every bucket passes through
  `Get-SysOrgSafeFolderName` (`nul.com` -> `_Nul`).
- **MPEG transport stream sniffing:** real `.ts` transport streams (0x47 sync bytes at
  offsets 0 and 188) route to Videos via `Test-SysOrgMpegTransportStream` (read-only,
  189-byte sniff, after the placeholder gates).
- **Stricter project detection (item 5):** a project folder requires a VCS marker
  (`.git`, `.hg`, `.svn`, `.jj`) or at least two distinct markers; a lone `.gitignore`,
  `Makefile` or lock file is not a project.
- **Folder-move safety:** `Invoke-SysOrgSafeMoveFolder` walks the tree reparse-point-aware
  (`Test-SysOrgFolderHasReparsePoint`) and REFUSES folders containing any junction or
  symlink, or trees that cannot be fully enumerated; cross-volume moves verify per-file
  SHA256 over matching relative paths, enumerate without `SilentlyContinue` on either
  side, and delete the source only after full verification.
- **Folder-move preview stats:** per folder move the preview shows the file count, the
  number of non-code files (`Get-SysOrgFolderMoveStats`), and BLOCKED-EXTENSION files
  outside build-output directories (documented choice: surfaced in the preview, the
  folder still moves).
- **OneDrive account detection (item 8):** `Get-SysOrgOneDriveRoots` /
  `Test-SysOrgUnderOneDrive` consider `$env:OneDrive`, `$env:OneDriveCommercial`,
  `$env:OneDriveConsumer` and the `HKCU:\Software\Microsoft\OneDrive\Accounts\*\UserFolder`
  registry values; matching is case-insensitive and segment-safe. Replaces five duplicated
  inline blocks (four in `New-SysOrgPlan`, one in `Get-SysOrgKnownFolders`).
- **Crash-durable journal (item 9):** the undo journal opens with `WriteThrough` and every
  row is flushed to disk (`Flush($true)`); a `Pending` row is written before each move and
  a `Done` row after; on resume, orphaned `Pending` rows are resolved against the actual
  filesystem state (skip-as-done when the source is gone, retry when it is present);
  after a FULLY successful undo the journal is renamed to `undo-<PlanId>.undone.csv` so
  the plan can be re-executed deliberately.
- **Proper CSV escaping:** journal and provenance rows are written through
  `ConvertTo-SysOrgCsvField`, so commas and quotes in untrusted URLs and file names survive
  a CSV round trip (column layout backward compatible).
- **Elevated-session gating (item 10):** the CLI warns prominently when running as
  Administrator, and any execute or undo additionally requires typing `yes`
  (`Confirm-SysOrgElevated`).
- **Millisecond plan IDs (item 10):** `plan-yyyyMMdd-HHmmss-fff` / `migrate-...-fff` - two
  plans within the same second can no longer collide; the executor regex accepts both the
  old and the new format.
- **Release pipeline (Phase 4):** `release.yml` builds `SysOrg-<version>.zip` from tracked
  files only on `v*` tags, publishes it with a `SHA256SUMS` file, and contains a clearly
  marked OPTIONAL Authenticode signing step that is skipped without certificate secrets.

### Changed
- **Copies keep their own names (item 6):** under `NumberCopies`, a copy keeps its OWN stem
  and extension and is numbered only when the name collides in the destination folder.
  `Copies.RenameToKeeper` (default `$false`) restores the v2.1.0 keeper-stem numbering as an
  opt-in; validated in `Test-SysOrgConfig` and documented in the config file.
- **`.ts` maps to Code only (item 4):** the duplicate `.ts` entry (Videos AND Code) is gone -
  with undefined hashtable enumeration order on Windows PowerShell 5.1, a `.ts` file could
  route differently per process. `ExtToCategory` is built deterministically
  (`Keys | Sort-Object`).
- **Scheduled reports (item 7):** `New-SysOrgScanReport` (and the folder-audit report)
  write under `<AppRoot>\Reports\` instead of drive roots; the undefined `$prof` is fixed
  (the drive profile is built fresh or accepted via the new optional `-DriveProfile`
  parameter); drives with empty scan roots are skipped instead of producing empty reports;
  the `*` default of `ScheduledDrives` covers fixed, non-removable drives only.
- **CI (Phase 4):** least privilege (`contents: read`), `actions/checkout` pinned to a
  commit SHA (v4.2.2), Pester pinned to 5.7.1 and PSScriptAnalyzer to 1.24.0, and an extra
  PowerShell 7 test leg next to the Windows PowerShell 5.1 leg. PSScriptAnalyzer settings
  now report Warning severity (printed; only Errors fail the build).
- **Uninstaller:** the cleanup prompt states that deleting `Undo\` removes the ability to
  undo past organizing (default stays "No"); "Scheduled task removed" is only printed when
  a task was actually removed.
- **Cross-volume hash reuse (item 10):** `Invoke-SysOrgSafeMove` accepts an optional
  `-ExpectedHash`, so a pre-move hash is not computed twice.
- **`Test-SysOrgElevated`** no longer throws on non-Windows hosts (returns `$false`).
- Version bumped to 2.1.1 in `SysOrg.config.psd1` and the `Import-SysOrgConfig` defaults.

### Fixed
- The misleading config comment claiming `Policy.ProtectedArtifacts` "cannot be opted away
  by accident" - they could be; now they genuinely cannot (additive merge + floor).
- Weekly reports no longer write to drive roots and the "Drive profile" report line
  actually prints (was an undefined `$prof`).

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
