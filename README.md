# SysOrg — Portable Windows File Organizer

Preview-first, zero-dependency file organizer for Windows 10/11, built entirely on
Windows PowerShell 5.1+. Nothing is installed and nothing runs in the background.
Licensed under the MIT license (see `LICENSE`).

**Revision 2.1** organizes the way Windows itself sorts: type-first into known-folder
names, name families within each type, numbered copies instead of quarantine, and an
explicit mutability engine that makes the C-drive guarantee provable. See
`ORGANIZATION-DESIGN.md` (the full design) and `IMPROVEMENTS.md` (the review tracker).

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
- **Numbered copies (v2.1)** — exact copies are kept and numbered beside the original
  (`Report.docx`, `Report (2).docx`); the keeper is the oldest file. Quarantine to `_Duplicates`
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
- **Report-only scheduled scans** — the weekly Task Scheduler job writes reports and can never move files

## Quick start

1. Download `SysOrg-2.1.0.zip` from the [Releases page](../../releases/latest).
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
.\SysOrg.ps1 -ExecutePlan .\Plans\plan-YYYYMMDD-HHMMSS.json
.\SysOrg.ps1 -ExecutePlan .\Plans\plan.json -Force   # resume after a crash
.\SysOrg.ps1 -UndoPlan plan-YYYYMMDD-HHMMSS
.\SysOrg.ps1 -Migrate C               # previewable plan mapping old trees to the Windows naming
.\SysOrg.ps1 -ScheduledReport         # report-only; used by Task Scheduler
```

## Destination layout (Windows preset)

```
<Root>\                              (C:\Organized, or <Drive>:\_Organized)
├── Documents\
│   ├── 2025\                        single documents by year (DateFolders)
│   ├── Report\                      family: Report.docx, Report (2).docx, Report final v2.docx
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
| `Copies` | `Policy` (NumberCopies/Quarantine/ReportOnly), `SuffixStyle`, `StartIndex` |
| `Downloads` | provenance `Roots`, `GroupBy` (SourceFirst/TypeFirst), `UnknownSourceFolder` |
| `Projects` | code project folder detection and destination |
| `TypeMap` | extension → routing-category overrides (legacy `Categories` still loads) |
| `ScanRoots` | Default scan scope per drive; whole-drive scans need `-FullDrive` |
| `Move.AllowCrossVolume` | `$true` = copy → SHA256-verify → remove source; `$false` = verified **copy-only** |

Deprecated v1.x keys (`Duplicates`, `Categories`, `ProjectDetection`) are mapped on load with a
warning, so old configs keep working.

## Safety model

- Never deletes anything — `NumberCopies` keeps exact copies beside the original; `Quarantine`
  (opt-in) moves them to `_Duplicates\<PlanId>\`; collision duplicates found at execution time are
  quarantined; different content is never overwritten (unique ` (2)` suffixes)
- Cross-volume moves are copy → SHA256-verify → remove source; the Zone.Identifier stream is
  reattached to the verified copy; on any mismatch the source is kept
- Protected on every drive: Windows, Program Files, ProgramData, WindowsApps, XboxGames, Boot,
  MSOCache, PerfLogs, `$Recycle.Bin`, System Volume Information, Recovery, hidden/system files,
  reparse points (junctions/symlinks), cloud placeholders, destination roots, `ExcludedPaths`,
  and anything marked with a `.sysorg-ignore` marker
- The mutability preview shows denials grouped by reason — outside the writable scope on C is
  provably untouched
- The undo journal is written per action (crash-safe); undo verifies content hashes, restores
  numbered copies to their original names, and skips changed files (`SkippedChanged`)
- Executing a plan twice is refused; `-Force` resumes and skips journaled sources
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
