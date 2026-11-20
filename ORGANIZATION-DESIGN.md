# SysOrg Organization Design, Revision 2.1: Windows-Native, Type-First, Numbered Copies

**Repository:** collins-muchiri/SysOrg
**Replaces:** ORGANIZATION-DESIGN.md revision 2.0
**Companion:** IMPROVEMENTS.md (v1.0.0 review). Depends on M1 (P0 fixes) and M2 (P1 safety), especially
P1-1 incremental journal, P1-3 resume guard, P1-5 placeholder skip, P1-7 per-drive exclusions.
**Target release:** v2.1.0

---

## 1. Requirements

1. Files are organized by type into folders FIRST. Type is the top level, always.
2. Inside each type folder, look at names and relations: related files and look-alike versions
   share one named family folder within that type.
3. If copies exist, just number them: `Report.docx`, `Report (2).docx`, `Report (3).docx`.
   Copies are kept, not quarantined, not deleted. Quarantine remains an opt-in policy.
4. On C, exactly which folders and file types may be changed is explicit and configurable.
   Everything outside that scope is provably untouched.
5. Before organizing, profile the hierarchy of ALL drives and understand the Windows architecture
   on each (system artifacts, known folders, redirection, junctions, cloud placeholders), then
   organize the way Windows itself sorts: known-folder taxonomy, perceived types, natural order.

---

## 2. What changed from revision 2.0

| Area | Rev 2.0 | Rev 2.1 |
|---|---|---|
| Family placement | Cross-type, dominant category wins | Within each type root; related files across types get the SAME family name in each root |
| Exact copies | Quarantined to `_Duplicates` | Numbered ` (2)`, ` (3)` beside the original; quarantine opt-in |
| Main folders | Documents, Photo, Video, Downloads | Windows known-folder names: Documents, Pictures, Videos, Music, Downloads (Compact4 preset restores the old four) |
| C drive scope | Whole-drive option with warnings | Mutability engine: default writable scope is the resolved known folders only |
| Classification | Extension map only | Extension map, then Windows PerceivedType registry fallback |
| Ordering | Ordinal sorts | Natural sort via `StrCmpLogicalW`, exactly like Explorer |
| New | - | Drive hierarchy profiling on all drives before any plan; OneDrive sync-out warning |

---

## 3. Windows architecture model

### 3.1 Known folders and redirection

Windows does not hardcode `C:\Users\<name>\Documents`. Known folders can be redirected to another
drive or into OneDrive. Resolve the real locations from the registry before deciding scope:

```powershell
function Get-SysOrgKnownFolders {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $names = @{
        'Personal'='Documents'; 'My Pictures'='Pictures'; 'My Video'='Videos'; 'My Music'='Music'; 'Desktop'='Desktop'
        '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'='Documents'
        '{0DDD015D-B06C-45D5-8C4C-F59713854639}'='Pictures'
        '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}'='Videos'
        '{A0C69A99-21C8-4671-8703-7934162FCF1D}'='Music'
        '{374DE290-123F-4565-9164-39C4925E467B}'='Downloads'
        '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}'='Downloads'
    }
    $props = Get-ItemProperty -Path $key
    $out = @{}
    foreach($p in $props.PSObject.Properties){
        if($names.ContainsKey($p.Name)){
            $path = [Environment]::ExpandEnvironmentVariables([string]$p.Value)
            $n = $names[$p.Name]
            if(-not $out.ContainsKey($n) -or $p.Name.StartsWith('{')){ $out[$n] = $path }
        }
    }
    foreach($k in $out.Keys){
        [pscustomobject]@{
            Name = $k; Path = $out[$k]
            IsRedirected  = -not $out[$k].StartsWith("$env:USERPROFILE\",[StringComparison]::OrdinalIgnoreCase)
            UnderOneDrive = ($env:OneDrive -and $out[$k].StartsWith($env:OneDrive,[StringComparison]::OrdinalIgnoreCase))
        }
    }
}
```

Consequences: a redirected Pictures folder on D is in scope on D, not C; a OneDrive-backed
Documents folder is in scope but placeholder-safe (P1-5) and carries the sync-out warning (12.3).
The known folders themselves are never renamed or moved.

### 3.2 Per-drive system artifacts (protected on every drive, not just C)

Data drives routinely carry Windows-managed trees. Auto-protect these at any drive root when present
(extends P1-7): `Windows`, `Program Files`, `Program Files (x86)`, `ProgramData`, `WindowsApps`,
`XboxGames`, `$Recycle.Bin`, `System Volume Information`, `Recovery`, `Boot`, `MSOCache`, `PerfLogs`.
Also never touch: `pagefile.sys`, `hiberfil.sys`, `swapfile.sys`, `DumpStack.log.tmp` (system
attributes already skip them; the explicit list makes the guarantee auditable).

### 3.3 Shell taxonomy: PerceivedType

Explorer groups by Kind using the perceived type registered per extension. Use it as the fallback
for extensions missing from our map, so unknown types land where Windows would put them:

```powershell
$script:PerceivedCache = @{}
function Get-SysOrgPerceivedSub {
    param([string]$Extension)
    if($script:PerceivedCache.ContainsKey($Extension)){ return $script:PerceivedCache[$Extension] }
    $sub = $null
    try {
        $pt = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\$Extension" -Name 'PerceivedType' -ErrorAction Stop).PerceivedType
        $sub = @{ 'image'='Pictures'; 'video'='Videos'; 'audio'='Music'; 'text'='Documents'
                  'document'='Documents'; 'compressed'='Archives'; 'application'='Installers' }[$pt]
        if($pt -eq 'system'){ $sub = 'SKIP' }
    } catch { }
    $script:PerceivedCache[$Extension] = $sub
    return $sub
}
```

Resolution order: config `TypeMap` override, built-in extension map, PerceivedType, then `Other`
(Documents\Other, count surfaced in preview). `SKIP` means the file is never moved.

### 3.4 Explorer conventions

- Natural sort: `file (2)` before `file (10)`, `Track 2` before `Track 11`. Implement once:

```powershell
if(-not ('SysOrg.NativeSort' -as [type])){
    Add-Type -Namespace SysOrg -Name NativeSort -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
public static extern int StrCmpLogicalW(string x, string y);
'@
}
function Sort-SysOrgNatural {
    param([string[]]$Values)
    $list = [System.Collections.Generic.List[string]]::new()
    $list.AddRange([string[]]$Values)
    $list.Sort([Comparison[string]]{ param($a,$b) [SysOrg.NativeSort]::StrCmpLogicalW($a,$b) })
    return ,$list.ToArray()
}
```

Use it for preview lists, family member ordering, and copy numbering determinism.
- Numbering style: browsers use `file (1).pdf`, Explorer paste uses `file - Copy.pdf`. Per the
  requirement we number with parentheses starting at 2 (the original is implicitly 1), matching
  the existing `Get-SysOrgUniquePath`. `Copies.SuffixStyle='DashCopy'` is available as an option.
- Date grouping: singletons group by year of LastWriteTime, the same field Explorer's
  "Date modified" grouping uses.

### 3.5 Compatibility junctions, placeholders, localized names

- Skip all reparse points (directories and files): `Documents and Settings`, `Application Data`,
  `My Documents` junctions exist to break naive scanners; ours already skips them (P2-5).
- Skip cloud placeholders before any read (P1-5), including before reading Zone.Identifier.
- Recognize existing category folders by their real names on this OS: compare against the leaf
  names returned by `Get-SysOrgKnownFolders` (already localized) plus the English canonical set.
  A German `Bilder` folder is recognized as Pictures-like and preserved, not treated as clutter.

### 3.6 Libraries (informational)

Libraries reference folders, not files. Organizing into `_Organized` does not break libraries,
but the organized roots are not library members by default. Optional future `-AddToLibrary`
can include them; out of scope here (section 15).

---

## 4. Drive hierarchy profiling (all drives, before any plan)

New menu option and CLI switch `-ProfileDrives`. Produces one profile per volume and drives all
scope decisions. No plan is built without a profile.

```powershell
function Get-SysOrgDriveProfile {
    param($Config)
    $known = @(Get-SysOrgKnownFolders)
    foreach($d in @(Get-SysOrgDrive)){
        $letter = $d.Drive.TrimEnd(':')
        $root = "$letter`:\"
        $role = if($letter -ieq $env:SystemDrive.TrimEnd(':')){ 'System' }
                elseif($d.Location -eq 'External'){ 'Removable' } else { 'Data' }
        $artifacts = @()
        foreach($a in @(Get-SysOrgSetting $Config 'Policy.ProtectedArtifacts' @())){
            if(Test-Path -LiteralPath (Join-Path $root $a)){ $artifacts += $a }
        }
        $kf = @($known | Where-Object { $_.Path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) })
        $top = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                 Select-Object -First 60)
        [pscustomobject]@{
            Letter = $letter; Role = $role; Drive = $d
            Artifacts = $artifacts; KnownFolders = $kf; TopLevelDirs = $top.Name
            ProposedScope = $(if($role -eq 'System'){ 'KnownFolders' } else { 'FullDrive' })
            DestinationRoot = (Get-SysOrgDestinationRoot -Letter $letter -Config $Config)
        }
    }
}
```

The profile report shows, per drive: role and detection evidence (existing confidence model),
protected artifacts found, known folders present (with redirection and OneDrive flags), top-level
tree, and the proposed writable scope. The user sees the architecture before confirming anything.
Existing category-like folders (3.5) feed `PreserveExistingFolders` so intact structures are kept.

---

## 5. Mutability engine: what may be changed on C and elsewhere

Every inventory record passes `Test-SysOrgFileMutable` before it can appear in a plan. Denials are
recorded in `Plan.Skipped` with a reason and summarized in the preview, so "untouched" is provable.

### 5.1 Policy matrix

| Check | System drive (C) default | Data / removable default |
|---|---|---|
| Protected paths (3.2, exclusions, app root, destinations) | Deny | Deny |
| Blocked extensions | `.dll .sys .drv .ocx .cpl .scr .lnk .url` | `.dll .sys .drv .ocx .cpl .scr` |
| Installer exception | `.exe .msi .msix .appx .apk` movable only inside download roots | same |
| Writable scope | Resolved known folders + `Policy.SystemDrive.WritablePaths` | Full drive minus the rows above |
| Attributes / placeholders / reparse | Deny (existing rules) | Deny |

This is the answer to "certain folders and file types in C can be changed": the writable set is
explicit, configurable, and visible. Extend it with `WritablePaths` in config or
`-WritablePath 'C:\Work\Exports'` on the CLI. Shortcuts (`.lnk`, `.url`) are blocked by default
because moving them breaks user expectations even though the files are harmless.

### 5.2 Implementation

```powershell
function Test-SysOrgFileMutable {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Extension,
          [Parameter(Mandatory)]$DriveProfile,$Config)
    $dir = Split-Path $Path -Parent
    if(Test-SysOrgExcludedPath -Path $dir -Config $Config){
        return [pscustomobject]@{ Allowed=$false; Reason='Protected path' } }
    $polKey = if($DriveProfile.Role -eq 'System'){ 'Policy.SystemDrive' } else { 'Policy.DataDrives' }
    $blocked = @(Get-SysOrgSetting $Config "$polKey.BlockedExtensions" @())
    if($blocked -contains $Extension){
        $isInstaller = @('.exe','.msi','.msix','.appx','.apk') -contains $Extension
        $inDownloads = $false
        foreach($r in @($DriveProfile.DownloadRoots)){
            if($Path.StartsWith($r.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){ $inDownloads = $true; break }
        }
        if(-not ($isInstaller -and $inDownloads -and (Get-SysOrgSetting $Config "$polKey.AllowInstallersInDownloads" $true))){
            return [pscustomobject]@{ Allowed=$false; Reason="Blocked extension $Extension" } }
    }
    if((Get-SysOrgSetting $Config "$polKey.Scope" 'KnownFolders') -eq 'FullDrive'){
        return [pscustomobject]@{ Allowed=$true; Reason='' } }
    $writable = @($DriveProfile.KnownFolders | ForEach-Object { $_.Path }) +
                @(Get-SysOrgSetting $Config "$polKey.WritablePaths" @())
    foreach($w in $writable){
        if([string]::IsNullOrWhiteSpace($w)){ continue }
        if($Path.StartsWith($w.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
            return [pscustomobject]@{ Allowed=$true; Reason='' } }
    }
    return [pscustomobject]@{ Allowed=$false; Reason='Outside writable scope on system drive' }
}
```

`FullDrive` on the system drive is intentionally not offered as a config value; whole-C organizing
is not a supported scenario. Data drives default to `FullDrive` because their content is user data,
with the artifact and extension protections still applied.

---

## 6. Taxonomy and layout

### 6.1 Main folders (Windows naming)

`Documents`, `Pictures`, `Videos`, `Music`, `Downloads` at each destination root. Subfolders inside
Downloads and for routing use the same names: `Documents, Pictures, Videos, Music, Archives, Code,
Installers, Other`. `Archives`, `Code`, `Other` live under `Documents`; `Installers` routes to the
Downloads branch. `NamingPreset='Compact4'` restores revision 2.0 naming (Documents, Photo, Video,
Downloads with Music under Video\Audio) for users who preferred it.

### 6.2 Example: C (system drive, OrganizedRoot style)

```
C:\Organized\
├── Documents\
│   ├── 2025\                          single documents by year
│   ├── Report\                        Report.docx, Report (2).docx (identical copy, numbered),
│   │                                  Report final v2.docx (different content, original name kept)
│   ├── Projects\Code\sysorg\          whole repo folder, .git intact
│   └── Archives\2025\
├── Pictures\
│   ├── 2025\
│   ├── Safari Trip\                   family inside Pictures
│   └── Screenshots\
├── Videos\
│   ├── 2025\
│   └── Safari Trip\                   same family name, videos stay under Videos
├── Music\2025\
└── Downloads\
    ├── GitHub\Archives\
    ├── WhatsApp\Pictures\2025\
    └── _NoSource\Installers\
```

D (data): `D:\_Organized\` with the same five roots; `D:\Games`, `D:\WindowsApps` untouched.
E (removable): `E:\_Organized\`, full-drive scope minus protections.

### 6.3 Destination style

`DestinationStyle='OrganizedRoot'` (default) keeps everything under `_Organized` or the configured
root, which is reversible and library-neutral. `'KnownFolders'` (opt-in) targets the user's real
known folders resolved in 3.1, which is how Windows itself would file things; it requires a second
explicit confirmation because moves into OneDrive-backed folders sync to the cloud, and it never
renames the known folders themselves.

---

## 7. Routing pipeline (decision order, per record)

| Order | Step | Result |
|---|---|---|
| 0 | Exclusions, attributes, placeholders, reparse (existing) | Skip |
| 1 | Mutability engine (section 5) | Skip with reason, or continue |
| 2 | Code project folder marker | `Documents\Projects\Code\<Name>`, MoveFolder (rev 2.0 D4) |
| 3 | Multipart archive set | one unit, one destination (rev 2.0 D5) |
| 4 | Context: download root or Zone.Identifier present | Downloads branch `Downloads\<Source>\<Sub>`; else main type root |
| 5 | Name family WITHIN the context leaf (section 8) | `<Leaf>\<FamilyName>\` |
| 6 | Exact copies: number within the final folder (section 9) | `name (2).ext` etc., all Move |
| 7 | Singleton | `<Leaf>[\Year]` per DateFolders |

Numbering is applied after the destination folder is known, so copies always sit beside their
original. Multipart members remain exempt from numbering and quarantine.

---

## 8. Type-first name families

1. Partition records by context leaf (main type root, or `Downloads\<Source>\<Sub>`).
   Cluster only within a partition. `Families.WithinTypeOnly=$true` is the default and the point
   of this revision.
2. Normalization unchanged from rev 2.0 (strip `(n)`, noise tokens, optional `vN`; dates kept).
   MinFiles=2. Token-signature pass for leftovers with the P2-6 sort fix.
3. Family folder name: most frequent original stem, sanitized (`Get-SysOrgSafeFolderName`).
4. Cross-type relations stay identifiable: `holiday.jpg` and `holiday.mp4` produce
   `Pictures\holiday\` and `Videos\holiday\`, the SAME family name in both roots, and the plan
   audit field `Family` links them. Nothing crosses the type boundary.
   `Families.CrossTypeLink='Dominant'` restores rev 2.0 behavior as an option.
5. No date subfolder inside a family folder; the family IS the grouping.

| Input | Result |
|---|---|
| Report.docx, Report.pdf, Report final v2.docx | `Documents\Report\` (3 files) |
| Report.docx + byte-identical Report - Copy.docx | `Documents\Report\Report.docx`, `Documents\Report\Report (2).docx` |
| holiday.jpg, holiday.mp4 | `Pictures\holiday\holiday.jpg`, `Videos\holiday\holiday.mp4` |
| IMG_1234.jpg, IMG_1235.jpg | no family; `Pictures\2025\` |
| Invoice 2025-01.pdf, Invoice 2025-02.pdf | separate by default (KeepDates); one family if KeepDates=$false |

---

## 9. Numbered copies policy (replaces quarantine default)

`Copies.Policy='NumberCopies'` (default) | `'Quarantine'` | `'ReportOnly'`.

Rules:

1. Exact duplicate detection unchanged: size, 64 KB header hash, full SHA256 (with P2-2 fix).
2. Keeper = oldest LastWriteTime, then natural name order (the original is the one the user
   created first). Keeper keeps its name; every other copy becomes `KeeperStem (n).ext` with n
   starting at `Copies.StartIndex` (2), assigned in LastWriteTime then natural-name order.
3. All copies land in the SAME final folder as the keeper (family folder or type/date folder).
   Nothing is deleted, nothing leaves the type hierarchy.
4. Different content with a colliding name: numbered by the existing execution-time
   `Get-SysOrgUniquePath`, flagged `DifferentContent` in the preview. Original names of
   different-content files are never rewritten at plan time.
5. Plan-time assignment checks the destination for existing files; execution re-checks and
   re-numbers if the tree changed since the scan. The never-overwrite guarantee is unchanged.
6. Undo restores every original name and path from the journal (OriginalSource column already
   carries it), so numbering is fully reversible.

Plan-time sketch inside the duplicate group handler:

```powershell
$ordered = @($keeper) + @($others | Sort-Object -Property LastWriteTime, FullName)
$n = 0
foreach($m in $ordered){
    $n++
    $name = if($n -eq 1){ $keeper.Name }
            else { '{0} ({1}){2}' -f $keeper.Stem, ($n + $startIndex - 2), $keeper.Extension }
    # destination folder = keeper's family folder or type/date folder, computed in step 5/7
    $actions.Add([pscustomobject]@{ Action='Move'; Kind='File'; Source=$m.FullName
        Destination=(Join-Path $destFolder $name); CopyIndex=$n; Family=$familyName
        Reason=("Exact copy {0} of {1}" -f $n, $ordered.Count); SizeBytes=$m.Length })
}
```

---

## 10. Downloads branch (carried over from rev 2.0, condensed)

Provenance and mechanics are unchanged (rev 2.0 section 8): Zone.Identifier `HostUrl`/`ReferrerUrl`
read after the placeholder skip, host-to-source bucket map, filename heuristics fallback
(WhatsApp, Telegram, Signal, Screenshots), `_NoSource` for the rest, safe folder names, streams
preserved on same-volume renames and reattached after verified cross-volume copies, full URLs only
in the local gitignored journal sidecar. Sub names now use the Windows set:
`Downloads\GitHub\Archives`, `Downloads\WhatsApp\Pictures\2025`. `GroupBy='SourceFirst'` default,
`'TypeFirst'` optional. Families and numbering apply inside each Downloads leaf exactly as in the
main roots. Installers without provenance land in `_NoSource\Installers`.

---

## 11. Configuration (SysOrg.config.psd1, Version = '2.1.0')

```powershell
Version          = '2.1.0'
NamingPreset     = 'Windows'          # Windows | Compact4
MainFolders      = @('Documents','Pictures','Videos','Music','Downloads')
DestinationStyle = 'OrganizedRoot'    # OrganizedRoot | KnownFolders (opt-in, double confirmation)
TypeMap          = @{ }               # extension overrides, e.g. '.heic' = 'Pictures'

Policy = @{
    SystemDrive = @{
        Scope = 'KnownFolders'        # KnownFolders | ExplicitPaths (FullDrive not supported on C)
        WritablePaths = @()           # e.g. @('C:\Work\Exports')
        BlockedExtensions = @('.dll','.sys','.drv','.ocx','.cpl','.scr','.lnk','.url')
        AllowInstallersInDownloads = $true
    }
    DataDrives = @{
        Scope = 'FullDrive'
        WritablePaths = @()
        BlockedExtensions = @('.dll','.sys','.drv','.ocx','.cpl','.scr')
        AllowInstallersInDownloads = $true
    }
    ProtectedArtifacts = @('Windows','Program Files','Program Files (x86)','ProgramData',
        'WindowsApps','XboxGames','$Recycle.Bin','System Volume Information','Recovery','Boot',
        'MSOCache','PerfLogs')
}

Families = @{
    Enabled = $true; MinFiles = 2; WithinTypeOnly = $true; CrossTypeLink = 'SameName'
    NoiseTokens = @('copy','copie','final','new','old','backup','bak','draft','rev','revised','edit','edited','version','untitled')
    StripVersionSuffix = $true; KeepDates = $true; MaxNameLength = 60
}

Copies = @{
    Policy = 'NumberCopies'           # NumberCopies | Quarantine | ReportOnly
    SuffixStyle = 'Parentheses'       # Parentheses | DashCopy
    StartIndex = 2
    MinFileSizeKB = 256; HeaderHashKB = 64
    QuarantineFolderName = '_Duplicates'   # used only when Policy = Quarantine
}

Downloads = @{
    Roots = @('Downloads'); GroupBy = 'SourceFirst'; DateFolders = 'Year'
    UseZoneIdentifier = $true; UnknownSourceFolder = '_NoSource'
}

Projects = @{ Enabled = $true; Destination = 'Documents\Projects\Code'; Markers = @()
              GenericNames = @('new folder','project','code','test','src','untitled','app')
              VerifyCrossVolumeHashes = $true }
Archives = @{ Extract = $false; KeepMultipartTogether = $true }
Preview  = @{ NaturalSort = $true; ShowDenied = $true; WarnOneDriveSyncOut = $true }
Privacy  = @{ StoreFullUrlsInJournal = $true }
```

`Test-SysOrgConfig` (P0-3) validates: NamingPreset, DestinationStyle, Copies.Policy, GroupBy,
MinFiles >= 2, StartIndex >= 2, Scope values (reject `FullDrive` under SystemDrive), and that
MainFolders matches the preset. The old `Duplicates` key is mapped to `Copies` on load with a
deprecation warning so v2.0 configs keep working.

---

## 12. Preview and reports

1. Destination tree, two levels, natural-sorted, counts and bytes per node (rev 2.0 D9 renderer,
   ordering switched to `Sort-SysOrgNatural`).
2. Mutability summary: allowed count, and denials grouped by reason
   (`Protected path`, `Blocked extension .dll`, `Outside writable scope on system drive`),
   so the user verifies the C drive guarantee before confirming.
3. OneDrive sync-out warning: if a source is under a OneDrive root and the destination is outside
   it, the move removes the file from cloud sync. Preview lists these files explicitly and the
   confirmation prompt names the count. `DestinationStyle='KnownFolders'` into a OneDrive-backed
   folder gets the inverse note (adds to cloud) plus the second confirmation.
4. Families and copies table: family name, type root, members, copy indices assigned, basis.
5. Drive profile report (section 4) available standalone via `-ProfileDrives` and menu option 1.

---

## 13. Work items

| ID | Title | Files | Acceptance |
|---|---|---|---|
| W1 | Drive profiler and `-ProfileDrives` | Drives, SysOrg.ps1 | every volume gets role, artifacts, known folders, proposed scope; no plan builds without a profile |
| W2 | Known-folder resolver, localized category recognition | Core, Scan | redirected Pictures on D is scoped on D; German `Bilder` recognized and preserved |
| W3 | Mutability engine with denial reasons | Core, Scan, Plan | `.dll` inside Documents denied; `.exe` in Downloads allowed; file outside scope on C never appears in Actions |
| W4 | PerceivedType fallback and Windows naming presets | Scan | unmapped `.heic` with PerceivedType=image lands in Pictures; Compact4 preset reproduces rev 2.0 roots |
| W5 | Type-first family partition, cross-type same-name link | Scan, Plan | holiday.jpg and holiday.mp4 produce same-named families in Pictures and Videos, never one mixed folder |
| W6 | Numbered copies policy, plan-time assignment, undo | Scan, Plan | three identical files produce name, (2), (3) in one folder; undo restores all original names and paths |
| W7 | Natural sort everywhere user-visible | Core, Plan | preview lists (2) before (10); numbering order deterministic across runs |
| W8 | OneDrive sync-out warning and KnownFolders double confirm | Plan, SysOrg.ps1 | moving a synced file out of OneDrive is listed and counted in the prompt |
| W9 | Per-drive artifact auto-protection | Core | `D:\WindowsApps` and `E:\XboxGames` excluded without user config |
| W10 | Config v2.1, validation, Duplicates-to-Copies mapping | Config, Core | invalid Scope or StartIndex throws at startup; v2.0 config loads with warning |
| W11 | Tests for W1-W10 | Tests | fixtures in section 14 all green in CI on PowerShell 5.1 |
| W12 | Migration preview from rev 2.0 trees | Plan, SysOrg.ps1 | `-Migrate` maps Photo to Pictures etc. as a previewable plan; existing `_Duplicates` folders untouched |

Milestone M4 (v2.1.0): W1-W12 after M1/M2. W3 depends on W1/W2; W6 depends on P1-1 and P1-3;
W8 depends on P1-5.

---

## 14. Test fixtures (extend Tests/)

| Fixture | Verifies |
|---|---|
| Report.docx + byte-identical Report - Copy.docx + Report final v2.docx | W6: (2) numbered, v2 keeps name, all in Documents\Report |
| Three identical files with different write times | W6/W7: keeper is oldest; (2),(3) order deterministic |
| holiday.jpg + holiday.mp4 | W5: two same-named families, no cross-type folder |
| `.dll` inside Documents; `.exe` in Downloads; `.exe` in Documents on C | W3: denied, allowed, denied |
| File at C:\Loose\notes.txt outside known folders | W3: denied with scope reason, absent from Actions |
| Mocked User Shell Folders with Pictures redirected to D:\Bilder | W2: scope follows redirection; D plan includes it |
| D:\WindowsApps\stub, E:\XboxGames\stub | W9: excluded on non-system drives |
| Unmapped extension with PerceivedType=image (registry mock) | W4: routes to Pictures |
| Names file (2).txt and file (10).txt at destination | W7: natural order in preview and numbering |
| OneDrive-rooted source, destination outside OneDrive | W8: warning listed, count in prompt |
| Cross-volume copy of a zoned file | rev 2.0 D7 still green: stream reattached |
| v2.0 tree with Photo\2024 and _Duplicates | W12: migration preview maps to Pictures\2024; quarantine folder untouched |

---

## 15. Migration and out of scope

Migration: layout changes are never applied implicitly. `-Migrate` builds a previewable,
journal-backed plan from old roots (Photo to Pictures, Video to Videos, Music extraction) using
the same MoveFolder/Move primitives. Existing `_Duplicates` folders from earlier runs are left
as-is; users can re-integrate them manually or via a future opt-in plan.

Out of scope for v2.1.0: archive extraction; perceptual media dedup; library membership edits
(`-AddToLibrary` later); writing desktop.ini localized names for organized folders; any whole-C
organizing mode; renaming known folders; content-based renaming beyond the copy numbering rule.
