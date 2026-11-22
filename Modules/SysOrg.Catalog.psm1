#Requires -Version 5.1
# SysOrg.Catalog.psm1 - the findability layer (v3.0 Phase 4).
#
# _Index\catalog.ndjson: one JSON object per line, appended after every executed
# plan and updated by undo:
#   current path, original path, type, category, date + date source, source bucket,
#   family, hash, size, confidence, rule id, plan id.
# Find-SysOrgFile reads the catalog (instant on huge drives) and falls back to a
# live scan when no catalog exists. The offline browse page (_Index\Index.html)
# embeds the catalog as JSON with a client-side filter box - static, no network.
# Catalog corruption degrades like the file-state cache: malformed lines are
# skipped, never a crash.

function Get-SysOrgCatalogPath {
<#
.SYNOPSIS
    The catalog location for a destination root: <root>\_Index\catalog.ndjson.
.EXAMPLE
    Get-SysOrgCatalogPath -Root 'D:\_Organized'   # -> 'D:\_Organized\_Index\catalog.ndjson'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path ("$Root".TrimEnd('\')) '_Index\catalog.ndjson')
}

function Read-SysOrgCatalog {
<#
.SYNOPSIS
    Loads the catalog as a list of entries (malformed lines skipped).
.DESCRIPTION
    Entries are PSCustomObjects with the documented fields. Missing file -> empty.
.EXAMPLE
    $catalog = @(Read-SysOrgCatalog -Path 'D:\_Organized\_Index\catalog.ndjson')
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $entries = New-Object System.Collections.Generic.List[object]
    if(-not (Test-Path -LiteralPath $Path)){ return $entries.ToArray() }
    try{
        $reader = $null
        try { $reader = New-Object System.IO.StreamReader($Path, $true) } catch { return $entries.ToArray() }
        try{
            while($null -ne ($line = $reader.ReadLine())){
                if([string]::IsNullOrWhiteSpace($line)){ continue }
                try{
                    $o = ConvertFrom-Json $line
                    [void]$entries.Add($o)
                } catch { }
            }
        } finally { $reader.Dispose() }
    } catch { }
    return $entries.ToArray()
}

function Update-SysOrgCatalog {
<#
.SYNOPSIS
    Refreshes the catalog after an executed plan (v3.0 Phase 4.1).
.DESCRIPTION
    Reads the plan JSON + its undo journal and writes one catalog entry per Done
    journal row: the CURRENT location (post-move), the original path, and the
    decision provenance from the plan action (category, date + source, source
    bucket, family, hash, size, confidence, rule id, plan id). Rows without a
    matching plan action (legacy plans) still get an entry with the fields the
    journal carries. Existing entries for other plans are preserved; entries for
    the same original path are REPLACED by the newest (undo re-runs stay correct).
    Best effort: a failed catalog write warns and never fails the run.
.EXAMPLE
    Update-SysOrgCatalog -PlanPath 'C:\SysOrg\Plans\plan-x.json' -UndoPath 'C:\SysOrg\Undo\undo-plan-x.csv' -Root 'D:\_Organized'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlanPath,[string]$UndoPath,
          [Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$PlanId)
    try{
        $catalogPath = Get-SysOrgCatalogPath -Root $Root
        $plan = $null
        try { $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json } catch { $plan = $null }
        $actionBySource = @{}
        if($plan -and $plan.PSObject.Properties['Actions']){
            foreach($a in @($plan.Actions)){ $actionBySource["$($a.Source)"] = $a }
        }
        $rows = @()
        if($UndoPath -and (Test-Path -LiteralPath $UndoPath)){
            try { $rows = @(Import-Csv -LiteralPath $UndoPath) } catch { $rows = @() }
        }
        if($rows.Count -eq 0){ return $null }

        $existing = @(Read-SysOrgCatalog -Path $catalogPath)
        $byOriginal = @{}
        foreach($e in $existing){
            $k = ("$($e.OriginalPath)").Replace('/','\').ToLowerInvariant()
            if(-not $byOriginal.ContainsKey($k)){ $byOriginal[$k] = $e }
        }

        foreach($r in $rows){
            $st = ''
            if($r.PSObject.Properties['Status']){ $st = "$($r.Status)" }
            if(($st -ne '') -and ($st -ine 'Done')){ continue }    # Pending/Retried: nothing settled
            $orig = "$($r.OriginalSource)"
            $cur = "$($r.CurrentLocation)"
            $a = $actionBySource[$orig]
            $entry = [ordered]@{
                CurrentPath = $cur
                OriginalPath = $orig
                Type = $(if($r.PSObject.Properties['Kind'] -and "$($r.Kind)"){ "$($r.Kind)" } else { 'File' })
                Category = ''
                Date = ''
                DateSource = ''
                SourceBucket = ''
                Family = ''
                Hash = $(if($r.PSObject.Properties['ContentHash']){ "$($r.ContentHash)" } else { '' })
                SizeBytes = 0
                Confidence = $null
                RuleId = ''
                PlanId = "$PlanId"
            }
            if($a){
                if($a.PSObject.Properties['SourceBucket']){ $entry.SourceBucket = "$($a.SourceBucket)" }
                if($a.PSObject.Properties['Family']){ $entry.Family = "$($a.Family)" }
                if($a.PSObject.Properties['SizeBytes']){ $entry.SizeBytes = [long]$a.SizeBytes }
                if($a.PSObject.Properties['Confidence']){ $entry.Confidence = $a.Confidence }
                if($a.PSObject.Properties['RuleId']){ $entry.RuleId = "$($a.RuleId)" }
                # category/date live in the Reason ('Findable=<leaf>') and the decision data
                if($a.PSObject.Properties['Reason']){ $entry.Category = "$($a.Reason)" }
                if($a.PSObject.Properties['PlannedLastWriteTimeUtc']){ $entry.Date = "$($a.PlannedLastWriteTimeUtc)"; $entry.DateSource = 'plan' }
            }
            $k = $orig.Replace('/','\').ToLowerInvariant()
            if($byOriginal.ContainsKey($k)){ $byOriginal[$k] = [pscustomobject]$entry }
            else { $byOriginal[$k] = [pscustomobject]$entry }
        }

        # write back sorted by original path (deterministic file)
        $dir = Split-Path $catalogPath -Parent
        if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $fs = New-Object System.IO.FileStream("$catalogPath.tmp", [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 65536)
        $writer = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
        try{
            foreach($k in ($byOriginal.Keys | Sort-Object)){
                $e = $byOriginal[$k]
                $line = ($e | ConvertTo-Json -Depth 4 -Compress)
                $writer.WriteLine($line)
            }
            $writer.Flush()
        } finally { $writer.Dispose(); $fs.Dispose() }
        Move-Item -LiteralPath "$catalogPath.tmp" -Destination $catalogPath -Force
        return $catalogPath
    } catch {
        Write-Warning ("The catalog could not be updated: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Update-SysOrgCatalogOnUndo {
<#
.SYNOPSIS
    Points catalog entries back at the original locations after an undo (Phase 4.1).
.DESCRIPTION
    For every Done row of the undone plan, the entry whose CurrentPath matched the
    row's CurrentLocation gets its CurrentPath set back to the row's OriginalSource.
    Best effort: rows whose current file was not catalogued are ignored.
.EXAMPLE
    Update-SysOrgCatalogOnUndo -PlanId plan-x -AppRoot C:\SysOrg -Root D:\_Organized
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlanId,[Parameter(Mandatory)][string]$AppRoot,
          [Parameter(Mandatory)][string]$Root)
    try{
        $catalogPath = Get-SysOrgCatalogPath -Root $Root
        if(-not (Test-Path -LiteralPath $catalogPath)){ return $null }
        $undoPath = Join-Path (Join-Path $AppRoot 'Undo') ('undo-{0}.csv' -f $PlanId)
        if(-not (Test-Path -LiteralPath $undoPath)){
            # a FULLY successful undo renames the journal to .undone.csv - use it
            $undoPath = Join-Path (Join-Path $AppRoot 'Undo') ('undo-{0}.undone.csv' -f $PlanId)
        }
        if(-not (Test-Path -LiteralPath $undoPath)){ return $null }
        $rows = @(Import-Csv -LiteralPath $undoPath)
        $entries = @(Read-SysOrgCatalog -Path $catalogPath)
        $byCurrent = @{}
        foreach($e in $entries){
            $k = ("$($e.CurrentPath)").Replace('/','\').ToLowerInvariant()
            if(-not $byCurrent.ContainsKey($k)){ $byCurrent[$k] = $e }
        }
        $changed = $false
        foreach($r in $rows){
            $st = ''
            if($r.PSObject.Properties['Status']){ $st = "$($r.Status)" }
            if(($st -ne '') -and ($st -ine 'Done')){ continue }
            $cur = ("$($r.CurrentLocation)").Replace('/','\').ToLowerInvariant()
            if(-not $cur){ continue }
            if($byCurrent.ContainsKey($cur)){
                $e = $byCurrent[$cur]
                $e.CurrentPath = "$($r.OriginalSource)"
                $changed = $true
            }
        }
        if(-not $changed){ return $null }
        $dir = Split-Path $catalogPath -Parent
        if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $fs = New-Object System.IO.FileStream("$catalogPath.tmp", [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 65536)
        $writer = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($false)))
        try{
            foreach($e in ($entries | Sort-Object { "$($_.OriginalPath)" })){
                $writer.WriteLine(($e | ConvertTo-Json -Depth 4 -Compress))
            }
            $writer.Flush()
        } finally { $writer.Dispose(); $fs.Dispose() }
        Move-Item -LiteralPath "$catalogPath.tmp" -Destination $catalogPath -Force
        return $catalogPath
    } catch {
        Write-Warning ("The catalog could not be updated after undo: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Find-SysOrgFile {
<#
.SYNOPSIS
    Searches the catalog (instant on huge drives); falls back to a live scan.
.DESCRIPTION
    Filters combine with AND: -Name (wildcard, e.g. '*invoice*'), -NameRegex,
    -Type (routing category), -After/-Before (catalog date), -Source (bucket),
    -Family, -MinSizeKB/-MaxSizeKB, -DuplicatesOf (a path whose content hash
    should match). Without a catalog, -Live performs a fresh scan instead
    (Get-SysOrgInventory + duplicate hashes are NOT recomputed - the live path
    reports paths and categories only). Results sort by CurrentPath.
.EXAMPLE
    Find-SysOrgFile -Root 'D:\_Organized' -Name '*invoice*' -Type 'Documents' -After 2024-01-01
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,$Config,
          [string]$Name,[string]$NameRegex,[string]$Type,
          [datetime]$After,[datetime]$Before,
          [string]$Source,[string]$Family,
          [long]$MinSizeKB = -1,[long]$MaxSizeKB = -1,
          [string]$DuplicatesOf,[switch]$Live,[string]$Letter)
    if($Live -or (-not (Test-Path -LiteralPath (Get-SysOrgCatalogPath -Root $Root)))){
        if(-not $Live){ Write-Warning ("No catalog found under '{0}\_Index' - falling back to a LIVE scan (slower). Run an organize pass to build the catalog." -f $Root) }
        $invParams = @{ Letter=$(if($Letter){ $Letter } else { 'C' }); Config=$Config; Roots=@($Root) }
        $inv = @(Get-SysOrgInventory @invParams)
        $results = New-Object System.Collections.Generic.List[object]
        foreach($f in $inv){
            if($Name -and ("$($f.Name)" -notlike $Name)){ continue }
            if($NameRegex -and ("$($f.Name)" -notmatch $NameRegex)){ continue }
            if($Type -and ("$($f.Category)" -ine $Type)){ continue }
            if(($MinSizeKB -ge 0) -and ([long]$f.Length -lt ($MinSizeKB * 1KB))){ continue }
            if(($MaxSizeKB -ge 0) -and ([long]$f.Length -gt ($MaxSizeKB * 1KB))){ continue }
            [void]$results.Add([pscustomobject]@{ CurrentPath=$f.FullName; OriginalPath=''; Type='File'; Category=$f.Category
                Date=$f.LastWriteTime; DateSource='filesystem'; SourceBucket=''; Family=''; Hash=''; SizeBytes=[long]$f.Length
                Confidence=$null; RuleId=''; PlanId='' })
        }
        return @($results.ToArray() | Sort-Object -Property CurrentPath)
    }
    $catalog = @(Read-SysOrgCatalog -Path (Get-SysOrgCatalogPath -Root $Root))
    $dupHash = $null
    if($DuplicatesOf){
        $norm = "$DuplicatesOf".Replace('/','\').ToLowerInvariant()
        foreach($e in $catalog){
            if(("$($e.CurrentPath)").Replace('/','\').ToLowerInvariant() -eq $norm -or ("$($e.OriginalPath)").Replace('/','\').ToLowerInvariant() -eq $norm){
                if("$($e.Hash)"){ $dupHash = "$($e.Hash)" }
                break
            }
        }
        if(-not $dupHash){ Write-Warning ("'{0}' is not in the catalog (or has no hash) - no duplicate search." -f $DuplicatesOf) }
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach($e in $catalog){
        if($Name -and ("$([System.IO.Path]::GetFileName("$($e.CurrentPath)"))" -notlike $Name)){ continue }
        if($NameRegex -and ("$($e.CurrentPath)" -notmatch $NameRegex)){ continue }
        if($Type -and ("$($e.Category)" -ine $Type -and ("$($e.Category)" -notlike "*$Type*"))){ continue }
        if($Source -and ("$($e.SourceBucket)" -ine $Source)){ continue }
        if($Family -and ("$($e.Family)" -ine $Family)){ continue }
        if(($MinSizeKB -ge 0) -and ([long]$e.SizeBytes -lt ($MinSizeKB * 1KB))){ continue }
        if(($MaxSizeKB -ge 0) -and ([long]$e.SizeBytes -gt ($MaxSizeKB * 1KB))){ continue }
        if($dupHash -and ("$($e.Hash)" -ne $dupHash)){ continue }
        if(($After -and $e.Date) -or ($Before -and $e.Date)){
            try{
                $d = [datetime]::Parse("$($e.Date)", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if($After -and ($d -lt $After)){ continue }
                if($Before -and ($d -gt $Before)){ continue }
            } catch { }
        }
        [void]$results.Add($e)
    }
    return @($results.ToArray() | Sort-Object -Property CurrentPath)
}

function Save-SysOrgIndexPage {
<#
.SYNOPSIS
    Writes _Index\Index.html - a static offline browse page (no network).
.DESCRIPTION
    Embeds the catalog as compact JSON and renders counts per top-level folder plus
    a client-side filter box over the whole catalog (vanilla JavaScript). Opens in
    any browser from a USB stick; never phones home.
.EXAMPLE
    Save-SysOrgIndexPage -Root 'D:\_Organized'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $catalogPath = Get-SysOrgCatalogPath -Root $Root
    $entries = @(Read-SysOrgCatalog -Path $catalogPath)
    $json = '[]'
    try { $json = ($entries | ConvertTo-Json -Depth 3 -Compress) } catch { $json = '[]' }
    if($json -eq 'null'){ $json = '[]' }
    if(-not $json.StartsWith('[')){ $json = ('[' + $json + ']') }
    # counts per top-level folder
    $counts = @{}
    foreach($e in $entries){
        $rel = "$($e.CurrentPath)".Replace('/','\')
        $rootN = "$Root".TrimEnd('\')
        if($rel.StartsWith($rootN + '\',[StringComparison]::OrdinalIgnoreCase)){ $rel = $rel.Substring($rootN.Length + 1) }
        $top = ($rel.Split('\'))[0]
        if(-not $counts.ContainsKey($top)){ $counts[$top] = 0 }
        $counts[$top]++
    }
    $countRows = @()
    foreach($k in ($counts.Keys | Sort-Object)){ $countRows += ('<li><b>{0}</b>: {1} files</li>' -f ($k -replace '<','&lt;'), $counts[$k]) }
    $dir = Split-Path $catalogPath -Parent
    if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>SysOrg index - offline</title>
<style>
body { font-family: Segoe UI, sans-serif; margin: 1.5em; background: #fafafa; color: #222; }
h1 { font-size: 1.2em; } #q { padding: .4em; width: 30em; }
table { border-collapse: collapse; margin-top: 1em; width: 100%; }
td, th { border: 1px solid #ddd; padding: 3px 7px; font-size: .85em; text-align: left; }
tr:hover { background: #eef; }
</style></head><body>
<h1>SysOrg offline index</h1>
<p>Generated locally by SysOrg - no network, no tracking. Filter below.</p>
<ul id="counts">$($countRows -join '')</ul>
<p><input id="q" type="text" placeholder="filter by name, category, source..." oninput="filterRows()" autofocus></p>
<table id="t"><thead><tr><th>Path</th><th>Category</th><th>Date</th><th>Source</th><th>Family</th><th>Size</th><th>Confidence</th><th>Plan</th></tr></thead>
<tbody id="rows"></tbody></table>
<script>
var DATA = $json;
var tb = document.getElementById('rows');
for (var i = 0; i < DATA.length; i++) {
  var e = DATA[i];
  var tr = document.createElement('tr');
  tr.setAttribute('data-s', [e.CurrentPath, e.Category, e.SourceBucket, e.Family, e.RuleId].join(' ').toLowerCase());
  var cells = [e.CurrentPath, e.Category, e.Date, e.SourceBucket, e.Family, e.SizeBytes, (e.Confidence === null ? '' : e.Confidence), e.PlanId];
  for (var j = 0; j < cells.length; j++) { var td = document.createElement('td'); td.textContent = cells[j] === null ? '' : String(cells[j]); tr.appendChild(td); }
  tb.appendChild(tr);
}
function filterRows() {
  var q = document.getElementById('q').value.toLowerCase();
  var rows = tb.getElementsByTagName('tr');
  for (var i = 0; i < rows.length; i++) { rows[i].style.display = (!q || rows[i].getAttribute('data-s').indexOf(q) >= 0) ? '' : 'none'; }
}
</script>
</body></html>
"@
    $out = Join-Path $dir 'Index.html'
    [System.IO.File]::WriteAllText($out, $html, (New-Object System.Text.UTF8Encoding($false)))
    return $out
}

function Save-SysOrgIndexReadme {
<#
.SYNOPSIS
    Writes _Index\README.txt explaining the layout, Find and undo.
.EXAMPLE
    Save-SysOrgIndexReadme -Root 'D:\_Organized'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $dir = Join-Path ("$Root".TrimEnd('\')) '_Index'
    if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $out = Join-Path $dir 'README.txt'
    $text = @"
SysOrg - what is this folder?
=============================

This '_Index' folder is SysOrg's card catalogue for the organized tree around it.
It is generated locally - it never leaves this drive.

catalog.ndjson  One JSON line per organized file: where it is now, where it came
                from, its category, date (and which date source won), download
                source, family, content hash, size, classification confidence,
                deciding rule and the plan that moved it.
Index.html      A static, offline browse page (open in any browser): counts per
                folder plus a filter box over the whole catalog. No network.
LearnedRules.psd1  Corrections YOU confirmed are saved here. They are never
                applied automatically - set Rules.ApplyLearned = `$true in the
                config to use them, and every move they plan is flagged.

Find a file instantly (reads catalog.ndjson, no disk walk):

    .\SysOrg.ps1 -Find '*invoice*'            (wildcard name search)
    .\SysOrg.ps1 -Find '.*\.pdf$' -Type Documents -After 2024-01-01

Undo a organize run (preview-first, crash-safe journal):

    .\SysOrg.ps1 -UndoPlan plan-20260101-093000-123

Layout notes
------------
Files are filed under at most ten top-level roots (Documents, Pictures, Videos,
Music, Audio-Recordings, Data, Software, Archives, Code, Design) plus the
app-managed Downloads branch and this _Index folder. Folder depth stays at or
below four levels; ISO dates (YYYY / YYYY-MM / YYYY-MM-DD) adapt to how full a
folder gets. Files that could not be classified confidently were LEFT IN PLACE
and listed in the plan preview under "NEEDS A DECISION" - they are never dumped
into a junk folder unless you opt into Review.Mode = Move (_Review\<year>).
"@
    [System.IO.File]::WriteAllText($out, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $out
}

function Test-SysOrgSearchIndexStatus {
<#
.SYNOPSIS
    Best-effort check that the destination root is not hidden from Windows Search.
.DESCRIPTION
    WARN-ONLY: never changes system settings. Returns @{ Status; Reason } where
    Status is 'Disabled' (wsearch service off), 'Unknown' (non-Windows host, or the
    service state cannot be read), or 'Ok' (the search service runs; whether the
    root itself is excluded is governed by CrawlScope rules that are not publicly
    documented - the Reason says so plainly and points at the Settings page).
.EXAMPLE
    Test-SysOrgSearchIndexStatus -Root 'D:\_Organized'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    if($env:OS -ne 'Windows_NT'){
        return [pscustomobject]@{ Status='Unknown'; Reason='non-Windows host: Windows Search is not present here.' }
    }
    try{
        $svc = Get-Service -Name 'wsearch' -ErrorAction Stop
        if($svc.StartType -eq 'Disabled'){
            return [pscustomobject]@{ Status='Disabled'; Reason='the Windows Search service (wsearch) is DISABLED on this machine - new files will not appear in search results. Enable it in Services if you want the organized tree indexed.' }
        }
        return [pscustomobject]@{ Status='Ok'; Reason='the Windows Search service is running. Whether a specific folder is excluded is governed by CrawlScope rules (not publicly documented): check Settings > Searching Windows > Excluded folders and make sure the destination root is listed.' }
    } catch {
        return [pscustomobject]@{ Status='Unknown'; Reason=('the Windows Search service state could not be read: ' + $_.Exception.Message) }
    }
}

Export-ModuleMember -Function *-SysOrg*
