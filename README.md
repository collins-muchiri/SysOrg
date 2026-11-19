# SysOrg — Portable Windows File Organizer

Preview-first, zero-dependency file organizer for Windows 10/11, built entirely on
Windows PowerShell 5.1+. Nothing is installed and nothing runs in the background.
Licensed under the MIT license (see `LICENSE`).

## Features

- **Folder safety audit (v1.1)** — classifies every folder as **Protected** (cannot alter), **Restricted** (read-only for you, left in place), or **Organizable**, using a non-destructive directory-handle probe, Defender Controlled Folder Access lists, and your exclusions
- **Narrow default scan scope (v1.2)** — scans start in your profile folders (Desktop, Documents, Downloads, Pictures, Videos, Music); whole-drive scans require an explicit `-FullDrive`
- **Drive detection** — internal SSD/HDD vs external, with confidence level and the evidence used
- **Preview-first workflow** — scan → classify → correlate → plan (JSON) → review → explicit confirm → execute. Every execution path (CLI and menu) previews and confirms first
- **Type-first organization** — `Documents/2025/`, `Images/`, `Videos/` … with year (or year-month) subfolders
- **Project clustering** — files sharing a filename stem across types, or distinctive name tokens, are grouped; token signatures are word-order independent
- **Exact duplicate detection** — size → 64 KB header hash → full SHA256; duplicates are quarantined, never deleted
- **Collision safety** — identical content is quarantined; different content gets unique ` (2)` suffixes; nothing is ever overwritten
- **Crash-safe undo (v1.2)** — the undo journal is flushed after every completed action; interrupted runs are fully undoable, and `-Force` resumes exactly where the crash happened
- **Verified undo (v1.2)** — undo re-checks file content hashes and skips files changed since the move instead of clobbering newer intent
- **Cloud-safe (v1.2)** — OneDrive files-on-demand placeholders are never opened; a scan cannot silently hydrate your cloud library
- **Report-only scheduled scans** — the weekly Task Scheduler job writes reports and can never move files

## Quick start

1. Download `SysOrg-1.2.0.zip` from the [Releases page](../../releases/latest).
2. Right-click the ZIP → Properties → **Unblock** → extract.
3. In the extracted folder run in PowerShell:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-SysOrg.ps1
   ```

4. Launch the **SysOrg** desktop shortcut, then pick option `[1]` to detect drives.

> The installer leaves your PowerShell execution policy untouched. Pass
> `-SetExecutionPolicy` if you want RemoteSigned set for the current user.

## Folder safety audit (new in v1.1.0)

Menu option `[2]` (or `powershell -File .\SysOrg.ps1 -AuditDrive C`) shows the safety map for a drive:

- **CANNOT BE ALTERED (Protected)** — Windows, Program Files, ProgramData, any `AppData`,
  Recycle Bin, hidden/system folders, junctions/symlinks/OneDrive roots, Defender Controlled
  Folder Access protected folders, your `ExcludedPaths`, and folders the current user cannot
  even read. SysOrg never descends into or modifies any of these.
- **READ-ONLY (Restricted)** — readable but not writable for the current user; contents stay
  in place and are excluded from plans by default (`FolderAudit.IncludeRestrictedInPlans`).
- **CAN BE ORGANIZED (Organizable)** — readable and writable; eligible for planning.

The writability probe opens directory handles with create-rights only — it never creates,
modifies, or deletes anything. The full map is saved to
`<Root>\_Reports\SysOrg-FolderAudit-*.txt`, and every scan prints how many folders were
skipped as protected or read-only.

## Scan scope (new in v1.2.0)

Default scans resolve `ScanRoots` (see the config) and touch only the existing folders
listed there — by default your profile folders:

```
Scan scope (scoped): C:\Users\you\Desktop; C:\Users\you\Documents; ...
```

- A drive with none of those folders yields **zero** records and no plan until you either
  add a matching `ScanRoots` entry or scan the whole drive with `-FullDrive`.
- Plan previews list the **affected top-level folders** so you always see the blast radius
  before confirming.
- Whole-drive scans re-enable the pre-1.2 behavior and may propose moves from portable
  apps, game libraries and dev trees — use deliberately.

## Usage (menu-driven console)

- `[1]` Detect drives (type + confidence)
- `[2]` Audit folders: which can / cannot be altered (safety map)
- `[3]` Scan a drive → build plan → preview → optional execute
- `[4]` Report-only scan (no changes)
- `[5]` Execute a saved plan (preview + confirm, always)
- `[6]` Undo a plan
- `[7]` Open working folder (plans, undo journals, logs)

### CLI examples

```powershell
.\SysOrg.ps1 -DetectDrives
.\SysOrg.ps1 -ScanDrive C              # ScanRoots scope -> preview -> optional execute
.\SysOrg.ps1 -ScanDrive C -FullDrive   # whole-drive scan (old behavior)
.\SysOrg.ps1 -ScanDrive C -NoCache     # ignore the cached inventory
.\SysOrg.ps1 -ScanDrive D -ReportOnly
.\SysOrg.ps1 -ExecutePlan .\Plans\plan-YYYYMMDD-HHMMSS.json
.\SysOrg.ps1 -ExecutePlan .\Plans\plan.json -Force   # resume after a crash (journaled actions skipped)
.\SysOrg.ps1 -UndoPlan plan-YYYYMMDD-HHMMSS
.\SysOrg.ps1 -ScheduledReport          # report-only; used by Task Scheduler
```

## Configuration

All preferences live in `SysOrg.config.psd1`:

| Key | Purpose |
|-----|---------|
| `OrganizedRoots` | Destination root per drive letter (`'__AUTO__'` = `<Drive>:\_Organized`) |
| `ExcludedPaths` | Sensitive locations never touched (root-less names like `Recovery` match any drive; system folders of every fixed drive are always protected) |
| `ScanRoots` | Default scan scope per drive; whole-drive scans need `-FullDrive` |
| `.sysorg-ignore` | Drop a `.sysorg-ignore` file in any folder and the whole tree is skipped by the traversal check |
| `DateFolders` | `Year`, `YearMonth`, or `None` subfolders inside each category |
| `Duplicates.Policy` | `Quarantine` (recommended) or `ReportOnly` |
| `ProjectDetection` | Enable/disable relationship clustering, minimum cluster size |
| `Move.AllowCrossVolume` | `$true` = copy → SHA256-verify → remove source; `$false` = verified **copy-only** between drives, every source kept |

## Safety model

- Never deletes anything — duplicates go to `_Duplicates\<PlanId>\`
- Cross-volume moves are copy → SHA256-verify → remove source; on any mismatch the source is kept
- `Move.AllowCrossVolume = $false` performs a verified copy and **keeps every source** (counted as `Copied`, not `Moved`)
- Skips Windows, Program Files, ProgramData, AppData, Recycle Bin, hidden/system files,
  reparse points (junctions/symlinks), cloud placeholders, destination roots, and anything
  in `ExcludedPaths` or marked with a `.sysorg-ignore` marker
- The undo journal is written per action (crash-safe); undo verifies content hashes and
  skips changed files (`SkippedChanged`); one command: `.\SysOrg.ps1 -UndoPlan <planId>`
- Executing a plan twice is refused; `-Force` resumes and skips journaled sources
- Per-file failures are logged and skipped; one bad file never aborts the batch

## Known limitations

- **260-character paths**: Windows PowerShell 5.1 cannot reliably address long paths; such
  files are recorded (`SkippedLongPath`), reported, and excluded from plans. PowerShell 7
  with the `LongPathsEnabled` policy lifts this limit.
- **eSATA / Thunderbolt externals**: Windows reports them as internal (SATA/PCIe), so the
  confidence model downgrades certainty; the `DetectionBasis` column is the source of truth.
- Hash economy: same-volume moves are not hashed before the move, so their undo is
  path-based only; cross-volume and duplicate quarantine moves are hash-verified.

## Uninstall

```powershell
.\Uninstall-SysOrg.ps1
```

Organized files and `_Duplicates` folders are never modified by uninstall.

---

Provided as-is under the MIT license. Review every plan before executing, and keep a
backup of irreplaceable folders on first runs.
