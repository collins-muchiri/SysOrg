# SysOrg — Portable Windows File Organizer

Preview-first, zero-dependency file organizer for Windows 10/11, built entirely on
Windows PowerShell 5.1+. Nothing is installed and nothing runs in the background.
Licensed under the MIT license (see `LICENSE`).

**Version 3.0.0** is the current release: a chooseable layout profile (`Windows` |
`Compact4` | `Findable`), a scored classification pipeline for ALL file types
(Decisions with confidence, signals and explainability), a persistent file-state
cache with parallel hashing for large drives, and a searchable offline catalog —
see the `v3.0 in one page` section below and the measured numbers (including the
honest misses) in `BENCHMARKS.md`.

**Revision 2.1** organizes the way Windows itself sorts: type-first into known-folder
names, name families within each type, numbered copies instead of quarantine, and an
explicit mutability engine that makes the C-drive guarantee provable. See
`ORGANIZATION-DESIGN.md` (the full design) and `IMPROVEMENTS.md` (the review tracker).

**Revision 2.1.1** hardens the security posture from a full audit: plans and undo journals
are re-validated at execution time (canonical paths, exclusions, destination containment,
integrity hash), a broken config fails closed instead of moving files on dropped
exclusions, protection lists have a non-overridable floor, copies keep their own names,
and the undo journal survives a power cut (WriteThrough + Pending/Done rows).


## v3.0 in one page

- **Choose a layout.** `LayoutProfile = Windows` (v2.1 behaviour), `Compact4`
  (rev 2.0 naming) or **`Findable`** (new). New installs default to Findable;
  an existing config file without the key keeps its current profile.

  ```
  <Root>\
  +- Documents\   Finance\{Invoices,Receipts,Statements,Tax}\<Year>
  |               Legal-Identity\<Year>   Work\<Year>   Education\<Year>
  |               Manuals\<Product>  Books\<Author|A-Z>  General\<Year>
  +- Pictures\    {Camera,Screenshots,Scans,Messaging\<Source>,Edited}\<date>
  |               Events\<YYYY-MM-DD to MM-DD>          (time-gap clusters)
  +- Videos\      {Camera,Screen-Recordings,Messaging\<Source>,Media}\<date>
  +- Music\       <Artist>\<Album>   (from tags)   Music\_Untagged\<Year>
  +- Audio-Recordings\<Year>          voice notes, meetings
  +- Data\<Year>                      csv/xlsx/json/db exports
  +- Software\    {Installers\<App>,Disk-Images,Drivers}
  +- Archives\<Year>  Code\Projects\<Name> + Code\Files\<Year>
  +- Design\<Year> + Fonts\
  +- Downloads\<Source>\<Type>\<date> (existing provenance branch)
  +- _Index\                          catalog, offline index, learned rules
  ```

  Max depth 4 below the root, 10 routing roots, ISO dates with ADAPTIVE
  granularity (YYYY -> YYYY-MM -> YYYY-MM-DD when a folder exceeds
  `Layout.MaxFilesPerFolder`), a 200-character path budget with deterministic
  hash-suffixed shortening. Files that cannot be classified confidently are LEFT
  IN PLACE and listed in the plan preview ("NEEDS A DECISION") - never dumped
  into a junk folder (`Review.Mode = Move` opts into `_Review\<Year>`).

- **Smarter classification.** Every file gets a scored Decision (destination,
  confidence 0..1, deciding rule, and the signals that produced it): safety
  gates > your rules (`Rules\UserRules.psd1`, validated fail-closed) > learned
  rules (never applied silently) > context > magic-byte true type (<= 512 B) >
  metadata (EXIF / ID3 / MP4 / Office / PDF / text - zero dependencies, mockable,
  fail-soft) > date (metadata > filename > filesystem, source recorded) >
  lexicon (`Rules\Lexicon.psd1`) > confidence gating. Photos/videos cluster into
  `Pictures\Events\<range>` by GPS cell + time gaps; near-duplicate images are
  reported, never moved.
- **Speed.** Persistent file-state cache (unchanged files are never re-hashed or
  re-parsed), compiled exclusions, parallel hashing (HDD-aware), head+tail
  duplicate pre-filter, in-memory name sets, batched execution. Real numbers and
  honest misses: see `BENCHMARKS.md`.
- **Find things.** Every executed plan updates `_Index\catalog.ndjson`; search
  it instantly (name, type, date range, source, family, size, duplicates-of):

      .\SysOrg.ps1 -Find '*invoice*'                 (wildcard)
      .\SysOrg.ps1 -Find '.*\.pdf$' -Type Documents  (regex via module)

  `_Index\Index.html` is a static offline browse page; `_Index\README.txt`
  explains the folder.
- **Measure it.** `-Score` scores an existing tree against `Score.Targets`;
  every organize preview shows the before/after findability score and states
  plainly whether the plan improves or worsens it.
- **Migrate.** `-MigrateProfile Findable` moves an existing v2.1 tree into the
  Findable layout (previewable, journaled, undoable, whole folders where
  possible, `_Index`/`_Reports`/`_Duplicates` untouched).
- **Explain anything.** `-Explain <path>` prints the full Decision for one file:
  every signal, rule and the confidence math. Nothing is moved.
- **Benchmark.** `Tools\New-SysOrgCorpus.ps1` + `SysOrg.ps1 -Benchmark`
  reproduce every number in `BENCHMARKS.md`.

All v2.1.1 guarantees are unchanged: preview before execute, never overwrite,
never delete user data, crash-safe undo journals, executor re-validation,
fail-closed config, non-overridable protection floor.


## Features

- **Drive hierarchy profiler (v2.1)** — `-ProfileDrives` / menu `[1]` shows, per volume: role
  (System / Removable / Data), detection evidence, protected artifacts found, resolved known
  folders (with redirection and OneDrive flags), download roots and the proposed writable scope.
  No plan is built without a profile.
- **Mutability engine (v2.1)** — exactly which folders and file types may be changed is explicit
  and configurable. On C the default writable scope is your resolved known folders (+ optional
  `WritablePaths`); everything outside it is denied with a recorded reason and never touched.
- **Type-first families (v2.1)** — files are organized by type FIRST; related files share one
  named family folder within their type (`Documents\Report\`), and related files across types
  get the same family name in each root (`Pictures\holiday\` + `Videos\holiday\`).
- **Numbered copies (v2.1.1)** — exact copies are kept beside the original WITH THEIR OWN
  name (`Report - Copy.docx` stays `Report - Copy.docx`); a copy is numbered only when the
  name collides in the destination folder. The v2.1.0 keeper-stem numbering is available as
  `Copies.RenameToKeeper=$true`. The keeper is the oldest file. Quarantine to `_Duplicates`
  remains opt-in; nothing is ever deleted.
- **Windows-native classification (v2.1)** — Windows known-folder names (Documents, Pictures,
  Videos, Music, Downloads), `PerceivedType` registry fallback for unmapped types, Explorer
  natural sort (`file (2)` before `file (10)`), Compact4 preset for the old naming.
- **Downloads branch (v2.1)** — provenance from the Zone.Identifier stream routes downloads to
  `Downloads\GitHub\Archives\`, `Downloads\WhatsApp\Pictures\2025\`; unknown sources to
  `Downloads\_NoSource\`; full URLs stay in a local sidecar only.
- **Folder safety audit (v1.1)** — classifies every folder as **Protected** (cannot alter),
  **Restricted** (read-only for you, left in place), or **Organizable**
- **Known-folder awareness (v2.1)** — known folders are resolved from the registry, so a
  redirected Pictures folder on D is scoped on D; localized names (`Bilder`) are recognized and
  preserved; code project folders (`.git`, `package.json`, ...) move whole with `.git` intact
- **Preview-first workflow** — profile → scan → plan (JSON) → review (destination tree, mutability
  summary, families/copies table, OneDrive warnings) → explicit confirm → execute
- **Cloud-safe (v1.2)** — OneDrive placeholders are never opened; a scan cannot hydrate your cloud
  library. Moves OUT of OneDrive are listed and counted in the confirmation prompt (v2.1)
- **Crash-safe undo (v1.2)** — the journal is flushed after every action; interrupted runs resume
  with `-Force`; undo re-checks content hashes and restores numbered copies to their original names
- **Report-only scheduled scans** — the weekly Task Scheduler job writes reports to
  `<AppRoot>\Reports\` (never to drive roots), covers fixed non-removable drives only, and
  can never move files

## Hardened plan execution (v2.1.1)

A plan file and its undo journal are treated as **untrusted input**. Before anything moves,
the executor re-validates every action: canonical path forms (no `..` segments, no 8.3
short names, no `\\?\` namespace), exclusion and mutability re-checks against a fresh drive
profile, reparse-point and cloud-placeholder refusals, plan-time size/timestamp drift
checks, destination containment inside the plan root (or the resolved known folders), and
a SHA256 integrity hash over the action list — a hand-edited plan is refused unless
`-Force` is passed with a loud warning. The undo journal gets the same treatment per row,
so a tampered journal cannot move arbitrary files.

When SysOrg runs **as Administrator** it warns prominently, and every execute or undo
additionally requires typing `yes`.

## Quick start

1. Download `SysOrg-3.0.0.zip` from the [Releases page](../../releases/latest) and verify the
   published `SHA256SUMS` entry before extracting.
2. Right-click the ZIP → Properties → **Unblock** → extract.
3. In the extracted folder run in PowerShell:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-SysOrg.ps1
   ```

4. Launch the **SysOrg** desktop shortcut. Option `[1]` profiles your drives — start there.

> The installer leaves your PowerShell execution policy untouched. Pass
> `-SetExecutionPolicy` if you want RemoteSigned set for the current user.

## How C is handled (the mutability engine)

On the system drive the default writable scope is the **resolved known folders** (Documents,
Pictures, Videos, Music, Downloads, Desktop) plus anything you add:

```powershell
Policy.SystemDrive.WritablePaths = @('C:\Work\Exports')     # in SysOrg.config.psd1
.\SysOrg.ps1 -ScanDrive C -WritablePath 'C:\Work\Exports'   # or per run on the CLI
```

Everything else is denied with a recorded reason, shown in the preview:

```
Mutability: 42 file(s) allowed; 7 denied (provably never touched):
  Blocked extension .dll                        x3
  Outside writable scope on system drive        x4
```

`.dll .sys .drv .ocx .cpl .scr` (plus `.lnk .url` on C) are blocked; installers
(`.exe .msi .msix .appx .apk`) may only move inside download roots. Whole-C organizing
(`FullDrive` on the system drive) is rejected at startup. Data drives default to full-drive
scope with the same artifact and extension protections.

## Usage (menu-driven console)

- `[1]` Profile drives (role, artifacts, known folders, writable scope)
- `[2]` Audit folders: which can / cannot be altered (safety map)
- `[3]` Organize a drive (profile → scan → plan → preview → optional execute)
- `[4]` Report-only scan (no changes)
- `[5]` Execute a saved plan (preview + confirm, always)
- `[6]` Undo a plan
- `[7]` Migrate old organized trees (Photo/Video/... → Windows naming; preview first)
- `[8]` Open working folder (plans, undo journals, logs)

### CLI examples

```powershell
.\SysOrg.ps1 -ProfileDrives           # drive hierarchy profile for every volume
.\SysOrg.ps1 -ScanDrive C             # ScanRoots + known folders -> preview -> optional execute
.\SysOrg.ps1 -ScanDrive C -FullDrive  # whole-drive scan (old behavior)
.\SysOrg.ps1 -ScanDrive C -NoCache    # ignore the cached inventory
.\SysOrg.ps1 -ScanDrive D -ReportOnly
.\SysOrg.ps1 -ScanDrive C -WritablePath 'C:\Work\Exports'
.\SysOrg.ps1 -ExecutePlan .\Plans\plan-YYYYMMDD-HHMMSS-mmm.json
.\SysOrg.ps1 -ExecutePlan .\Plans\plan.json -Force   # resume after a crash
.\SysOrg.ps1 -UndoPlan plan-YYYYMMDD-HHMMSS-mmm
.\SysOrg.ps1 -Migrate C               # previewable plan mapping old trees to the Windows naming
.\SysOrg.ps1 -ScheduledReport         # report-only; used by Task Scheduler

# v3.0
.\SysOrg.ps1 -Find '*invoice*'        # search _Index\catalog.ndjson (instant, offline)
.\SysOrg.ps1 -Explain 'D:\stuff\x.pdf'  # print the full Decision for one file; moves nothing
.\SysOrg.ps1 -Score                   # score the organized tree against Score.Targets
.\SysOrg.ps1 -MigrateProfile Findable # migrate a v2.1 tree to the Findable layout (preview first)
.\SysOrg.ps1 -Benchmark -BenchmarkFiles 20000 -BenchmarkSeed 42  # reproduce BENCHMARKS.md
```

## Destination layout (Windows preset)

```
<Root>\                              (C:\Organized, or <Drive>:\_Organized)
├── Documents\
│   ├── 2025\                        single documents by year (DateFolders)
│   ├── Report\                      family: Report.docx, Report - Copy.docx, Report final v2.docx
│   ├── Projects\Code\<name>\        whole code project folders, .git intact
│   └── Archives\2025\
├── Pictures\{2025, holiday, ...}
├── Videos\{2025, holiday, ...}      same family names, never a mixed folder
├── Music\2025\
└── Downloads\
    ├── GitHub\Archives\
    ├── WhatsApp\Pictures\2025\
    └── _NoSource\Installers\
```

`DestinationStyle='KnownFolders'` (opt-in) files into your REAL known folders instead — it
requires a second explicit confirmation because moves into OneDrive-backed folders sync to the
cloud. `NamingPreset='Compact4'` restores Documents / Photo / Video / Downloads.

## Configuration

All preferences live in `SysOrg.config.psd1` (v2.1 keys documented inline):

| Key | Purpose |
|-----|---------|
| `NamingPreset` | `Windows` (Documents/Pictures/Videos/Music/Downloads) or `Compact4` (rev 2.0 names) |
| `DestinationStyle` | `OrganizedRoot` (default) or `KnownFolders` (opt-in, double confirmation) |
| `OrganizedRoots` | Destination root per drive letter (`'__AUTO__'` = `<Drive>:\_Organized`) |
| `Policy.SystemDrive` | `Scope` (KnownFolders/ExplicitPaths), `WritablePaths`, `BlockedExtensions` |
| `Policy.ProtectedArtifacts` | Auto-protected at EVERY drive root (WindowsApps, XboxGames, ...) |
| `Families` | MinFiles, noise tokens, `KeepDates`, `WithinTypeOnly`, `CrossTypeLink` |
| `Copies` | `Policy` (NumberCopies/Quarantine/ReportOnly), `SuffixStyle`, `StartIndex`, `RenameToKeeper` (opt-in keeper-stem numbering) |
| `Downloads` | provenance `Roots`, `GroupBy` (SourceFirst/TypeFirst), `UnknownSourceFolder` |
| `Projects` | code project folder detection and destination (v2.1.1: a VCS marker or two distinct markers required) |
| `TypeMap` | extension → routing-category overrides (legacy `Categories` still loads) |
| `ScanRoots` | Default scan scope per drive; whole-drive scans need `-FullDrive` |
| `Move.AllowCrossVolume` | `$true` = copy → SHA256-verify → remove source; `$false` = verified **copy-only** |
| `ScheduledDrives` | drives in scheduled reports; `*` = every fixed (internal) drive |

Deprecated v1.x keys (`Duplicates`, `Categories`, `ProjectDetection`) are mapped on load with a
warning, so old configs keep working. **v2.1.1: a config file that cannot be parsed makes
SysOrg fail closed** (interactive sessions stop; `-ScheduledReport` continues with safe
defaults after a loud warning), `Policy.ProtectedArtifacts` and the `BlockedExtensions`
lists merge additively (built-ins cannot be removed), and a non-overridable protection
floor (`SystemRoot`, `Program Files`, `Program Files (x86)`, `ProgramData`, `$Recycle.Bin`
and `System Volume Information` at every fixed drive root) is always applied.

## Safety model

- Never deletes anything — `NumberCopies` keeps exact copies beside the original; `Quarantine`
  (opt-in) moves them to `_Duplicates\<PlanId>\`; collision duplicates found at execution time are
  quarantined; different content is never overwritten (unique ` (2)` suffixes)
- Cross-volume moves are copy → SHA256-verify → remove source; the Zone.Identifier stream is
  reattached to the verified copy; on any mismatch the source is kept
- Protected on every drive: Windows, Program Files, ProgramData, WindowsApps, XboxGames, Boot,
  MSOCache, PerfLogs, `$Recycle.Bin`, System Volume Information, Recovery, hidden/system files,
  reparse points (junctions/symlinks), cloud placeholders, destination roots, `ExcludedPaths`,
  and anything marked with a `.sysorg-ignore` marker — plus the non-overridable v2.1.1
  protection floor
- Every plan action and undo-journal row is re-validated at execution time (v2.1.1):
  canonical paths, exclusions, destination containment, reparse/placeholder refusals and a
  plan integrity hash; failures are recorded per action, never abort the batch silently
- Folders containing junctions or symlinks are never moved; cross-volume folder moves are
  verified by per-file SHA256 and the source is deleted only after full verification
- The mutability preview shows denials grouped by reason — outside the writable scope on C is
  provably untouched
- The undo journal is written per action and flushed to disk (`WriteThrough` + `Flush($true)`,
  Pending row before / Done row after each move); interrupted runs resume with `-Force` and
  orphaned `Pending` rows are resolved against the actual filesystem state; undo verifies
  content hashes, restores copies to their original names, skips changed files
  (`SkippedChanged`), and archives a fully-successful journal to `undo-<PlanId>.undone.csv`
  (the plan can then be re-executed deliberately)
- Executing a plan twice is refused; `-Force` resumes and skips journaled sources
- Elevated sessions (running as Administrator) warn prominently and require typing `yes`
  before any execute or undo
- Per-file failures are logged and skipped; one bad file never aborts the batch

## Known limitations

- **260-character paths**: Windows PowerShell 5.1 cannot reliably address long paths; such
  files are recorded (`SkippedLongPath`), reported, and excluded from plans. PowerShell 7
  with the `LongPathsEnabled` policy lifts this limit.
- **eSATA / Thunderbolt externals**: Windows reports them as internal (SATA/PCIe), so the
  confidence model downgrades certainty; the `DetectionBasis` column is the source of truth.
- Hash economy: same-volume moves are not hashed before the move, so their undo is
  path-based only; cross-volume and quarantine moves are hash-verified.
- Non-ASCII-only file names produce no family signature (they are still organized by type/date).

## Uninstall

```powershell
.\Uninstall-SysOrg.ps1
```

Organized files and `_Duplicates` folders are never modified by uninstall.

---

Provided as-is under the MIT license. Review every plan before executing, and keep a
backup of irreplaceable folders on first runs.
