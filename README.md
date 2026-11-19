# SysOrg — Portable Windows File Organizer

Preview-first, zero-dependency file organizer for Windows 10/11, built entirely on
Windows PowerShell 5.1+. Nothing is installed and nothing runs in the background.

## Features

- **Folder safety audit (v1.1)** — classifies every folder as **Protected** (cannot alter), **Restricted** (read-only for you, left in place), or **Organizable**, using a non-destructive directory-handle probe, Defender Controlled Folder Access lists, and your exclusions
- **Drive detection** — internal SSD/HDD vs external, with confidence level and the evidence used
- **Preview-first workflow** — scan → classify → correlate → plan (JSON) → review → explicit confirm → execute
- **Type-first organization** — `Documents/2025/`, `Images/`, `Videos/` … with year (or year-month) subfolders
- **Project clustering** — files sharing a filename stem across types, or distinctive name tokens, are grouped
- **Exact duplicate detection** — size → 64 KB header hash → full SHA256; duplicates are quarantined, never deleted
- **Collision safety** — identical content is quarantined; different content gets unique ` (2)` suffixes; nothing is ever overwritten
- **Full undo** — every executed action is journaled; reverse any plan with one command
- **Report-only scheduled scans** — the weekly Task Scheduler job writes reports and can never move files

## Quick start

1. Download `SysOrg-1.1.0.zip` from the [Releases page](../../releases/latest).
2. Right-click the ZIP → Properties → **Unblock** → extract.
3. In the extracted folder run in PowerShell:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-SysOrg.ps1
   ```

4. Launch the **SysOrg** desktop shortcut, then pick option `[1]` to detect drives.

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

## Usage (menu-driven console)

- `[1]` Detect drives (type + confidence)
- `[2]` Audit folders: which can / cannot be altered (safety map)
- `[3]` Scan a drive → build plan → preview → optional execute
- `[4]` Report-only scan (no changes)
- `[5]` Execute a saved plan
- `[6]` Undo a plan
- `[7]` Open working folder (plans, undo journals, logs)

### CLI examples

```powershell
.\SysOrg.ps1 -DetectDrives
.\SysOrg.ps1 -ScanDrive C              # scan -> preview -> optional execute
.\SysOrg.ps1 -ScanDrive D -ReportOnly
.\SysOrg.ps1 -ExecutePlan .\Plans\plan-YYYYMMDD-HHMMSS.json
.\SysOrg.ps1 -UndoPlan plan-YYYYMMDD-HHMMSS
.\SysOrg.ps1 -ScheduledReport          # report-only; used by Task Scheduler
```

## Configuration

All preferences live in `SysOrg.config.psd1`:

| Key | Purpose |
|-----|---------|
| `OrganizedRoots` | Destination root per drive letter (`'__AUTO__'` = `<Drive>:\_Organized`) |
| `ExcludedPaths` | Sensitive locations never touched (Windows, Program Files, AppData are pre-included) |
| `DateFolders` | `Year`, `YearMonth`, or `None` subfolders inside each category |
| `Duplicates.Policy` | `Quarantine` (recommended) or `ReportOnly` |
| `ProjectDetection` | Enable/disable relationship clustering, minimum cluster size |
| `Move.AllowCrossVolume` | `$false` = copy-only between drives (source always kept) |

## Safety model

- Never deletes anything — duplicates go to `_Duplicates\<PlanId>\`
- Cross-volume moves are copy → SHA256-verify → remove source; on any mismatch the source is kept
- Skips Windows, Program Files, ProgramData, AppData, Recycle Bin, hidden/system files,
  reparse points (junctions/symlinks), destination roots, and anything in `ExcludedPaths`
  or marked with a `.sysorg-ignore` marker
- One-command undo: `.\SysOrg.ps1 -UndoPlan <planId>` (journal in `Undo\undo-<PlanId>.csv`)
- Per-file failures are logged and skipped; one bad file never aborts the batch

## Uninstall

```powershell
.\Uninstall-SysOrg.ps1
```

Organized files and `_Duplicates` folders are never modified by uninstall.

---

Provided as-is. Review every plan before executing, and keep a backup of irreplaceable
folders on first runs. Add a LICENSE file if you plan to redistribute.
