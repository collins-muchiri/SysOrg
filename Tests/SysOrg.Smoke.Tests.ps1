# ---------------------------------------------------------------------------
# v3.0.2 A2: the PLAN-BUILD CRASH smoke test.
#
# The real Windows run failed twice, identically, right after
# 'Code project folders detected: 3' with 'Argument types do not match' -
# and only when the run had duplicate groups, version pairs, project folders
# and preserved dependency dirs. Root cause (proven in this session): @()
# collecting the walk's New-Object-created List[object] $walkPreserved hits
# PSToObjectArrayBinder -> PSEnumerableBinder.MaybeDebase, which builds an
# Expression.Condition with mismatched branch types. The site lives in the
# menu/CLI scan FLOW (SysOrg.ps1), which no module-level test executed - the
# suite stayed green while option 3 crashed.
#
# This file closes that hole: it extracts the REAL Invoke-SysOrgScanFlow (and
# the two timing helpers it calls) from SysOrg.ps1, stubs only the drive
# layer (no real drives on portable hosts) and runs the whole
# profile -> scan -> duplicates -> version pairs -> projects -> collections ->
# fingerprint -> plan -> preview pipeline over a fixture that combines ALL the
# real-run triggers:
#   - exact duplicate groups, including a duplicate KEEPER inside a project unit
#   - nested project folders: 'proj-main (1)\proj-main' next to 'proj-main'
#   - re-download version pairs (identical and differing)
#   - a user collection with a nested subfolder
#   - a legacy junction (real, Windows only) and a mocked cloud-reparse folder
#   - names containing parentheses
#   - a file-state cache that is reused on the second run
#
# The child-process variant (real PowerShell 5.1 / 7 invocation of SysOrg.ps1
# -ScanDrive through the exact CLI path) runs on the Windows CI legs.
# ---------------------------------------------------------------------------
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1')        -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.KnownFolders.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Drives.psm1')      -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Layout.psm1')      -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Metadata.psm1')    -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Classify.psm1')    -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Cache.psm1')       -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Catalog.psm1')     -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Scan.psm1')        -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Audit.psm1')       -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1')        -Force -DisableNameChecking

    # --- extract the REAL flow functions from SysOrg.ps1 (the menu option 3 path) ---
    $sysAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'SysOrg.ps1'), [ref]$null, [ref]$null)
    foreach($fnName in @('Invoke-SysOrgScanFlow','Get-SysOrgPhaseStart','Stop-SysOrgPhase','Offer-SysOrgDiagnosticsBundle','Invoke-SysOrgDiagnosticsBundle','Get-SysOrgDisplayVersion')){
        $fd = $sysAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { $_.Name -eq $fnName } | Select-Object -First 1
        if(-not $fd){ throw "SysOrg.ps1 no longer defines $fnName - the smoke test must follow the real code path" }
        Invoke-Expression $fd.Extent.Text
    }

    # --- the crash-fixture tree ---
    $script:smokeRoot   = Join-Path $TestDrive ('smoke-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    $script:smokeApp    = Join-Path $TestDrive ('smokeapp-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $script:smokeApp -Force | Out-Null
    $docs  = Join-Path $smokeRoot 'Documents'
    $pics  = Join-Path $smokeRoot 'Pictures'
    $dls   = Join-Path $smokeRoot 'Downloads'
    foreach($d in @($docs, $pics, $dls)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }

    # user collection with a nested subfolder (moves as ONE unit)
    $col = Join-Path $docs 'UNDP Field Programme'
    New-Item -ItemType Directory -Path (Join-Path $col 'Workshop') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $col 'Narrative Report 2026.docx') -Value ('C' * 300)
    Set-Content -LiteralPath (Join-Path $col 'Workshop\Agenda.txt') -Value 'agenda'

    # version pairs: identical (collapses into the copies policy) and differing (report-only)
    Set-Content -LiteralPath (Join-Path $dls 'Invoice 2026.pdf') -Value 'same-bytes'
    Set-Content -LiteralPath (Join-Path $dls 'Invoice 2026 (1).pdf') -Value 'same-bytes'
    Set-Content -LiteralPath (Join-Path $pics 'Holiday Photo.jpg') -Value 'photo-v1-bytes'
    Set-Content -LiteralPath (Join-Path $pics 'Holiday Photo (1).jpg') -Value 'photo-v2-bytes-differ'

    # parentheses names that must survive the whole pipeline
    Set-Content -LiteralPath (Join-Path $dls 'tool (setup).txt') -Value 'tool'
    Set-Content -LiteralPath (Join-Path $dls 'readme (final).md') -Value 'readme'

    # project unit + a duplicate KEEPER inside it (the real run's trigger)
    $proj = Join-Path $smokeRoot 'proj-main'
    New-Item -ItemType Directory -Path (Join-Path $proj 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $proj '.git') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $proj '.git\HEAD') -Value 'ref: refs/heads/main'
    Set-Content -LiteralPath (Join-Path $proj 'src\main.ps1') -Value 'Write-Host 1'
    Set-Content -LiteralPath (Join-Path $proj 'Invoice 2026.pdf') -Value 'same-bytes'

    # nested project: 'proj-main (1)\proj-main' next to 'proj-main'
    $projWrap = Join-Path $smokeRoot 'proj-main (1)'
    New-Item -ItemType Directory -Path (Join-Path $projWrap 'proj-main\src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $projWrap 'proj-main\.git') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $projWrap 'proj-main\.git\HEAD') -Value 'ref: refs/heads/main'
    Set-Content -LiteralPath (Join-Path $projWrap 'proj-main\src\lib.py') -Value 'x = 1'

    # dependency dir OUTSIDE any project - pruned without enumeration
    New-Item -ItemType Directory -Path (Join-Path $smokeRoot 'node_modules\left-pad') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $smokeRoot 'node_modules\left-pad\index.js') -Value 'module.exports=1'

    # mocked cloud-reparse folder: the tag resolves through the v3.0.2 seam
    # (in-process mock here, env-var mock in the child-process run). Classification
    # behaviour lands in B1; the folder is part of the fixture from A2 on.
    $script:smokeCloud = Join-Path $docs 'OneDrive Library'
    New-Item -ItemType Directory -Path $script:smokeCloud -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:smokeCloud 'cloud notes.txt') -Value 'cloud'
    Set-SysOrgReparseTagMock -Path $script:smokeCloud -Tag 0x90000001

    # legacy junction (real, Windows only; junctions need no admin)
    $script:smokeJunction = $null
    if($env:OS -eq 'Windows_NT'){
        try{
            $jp = Join-Path $docs 'My Pictures'
            $null = New-Item -ItemType Junction -Path $jp -Target $pics -ErrorAction Stop
            $script:smokeJunction = $jp
        } catch { $script:smokeJunction = $null }
    }

    # --- harness: stub ONLY the drive layer; everything else is the real pipeline ---
    function Get-SysOrgDriveProfile { param($Config,[string[]]$Letters)
        return @([pscustomobject]@{ Letter='X'; Root='X:\'; Role='Data'; ProposedScope='FullDrive'
            KnownFolders=@(); DownloadRoots=@(); Artifacts=@(); TopLevelDirs=@() }) }
    function Get-SysOrgScanRoots { param([string]$Letter,$Config,[switch]$DefaultScope,[string[]]$Roots,[object[]]$KnownFolders)
        return [pscustomobject]@{ Scope='custom'; Initial=@($script:smokeRoot) } }
    # the review flow prompts interactively - the fixture config must never reach it
    function Invoke-SysOrgReviewFlow { throw 'review flow reached - the smoke config must not trigger it' }

    $script:smokeFolders = New-SysOrgAppFolders -AppRoot $script:smokeApp
    # remembered scan roots (v3.0.1 D2): the flow adopts them for -WholeDrive runs
    # (v3.0.2 A2: they now REACH the walk instead of only suppressing the prompt)
    New-Item -ItemType Directory -Path (Join-Path $script:smokeApp 'Config') -Force | Out-Null
    @{ 'X' = @(("$script:smokeRoot" -replace '\\','\\')) } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $script:smokeApp 'Config\ScanRoots.json') -Encoding UTF8
    $script:smokeConfig = @{
        AppRoot        = $script:smokeApp
        LayoutProfile  = 'Windows'
        OrganizedRoots = @{ 'X' = (Join-Path $script:smokeRoot '_Organized') }
        Copies         = @{ Policy='NumberCopies'; MinFileSizeKB=0; DocMinFileSizeKB=0; HeaderHashKB=64 }
        Classify       = @{ MinConfidence=0.40; ReviewConfidence=0.0 }
        Review         = @{ Mode='Report' }
        Learn          = @{ Enabled=$false }
        Families       = @{ Enabled=$false }
        Downloads      = @{ UseZoneIdentifier=$false }
        Move           = @{ AllowCrossVolume = $true }
        ExcludedPaths  = @()
        ExcludedFilePatterns = @()
        SkipHiddenSystemFiles = $true
        ExcludeDestinations = $true
        PreserveExistingFolders = $false
        DateFolders    = 'Year'
        FolderAudit    = @{ Enabled = $true }
        TypeMap        = @{}
        Plans          = @{ ReuseIdentical = $true }
    }
    # script-scope variables the REAL flow reads (same names as in SysOrg.ps1)
    $script:appRoot     = $script:smokeApp
    $script:Config      = $script:smokeConfig
    $script:folders     = $script:smokeFolders
    $script:logFolder   = $script:smokeFolders.Logs
    $script:Timing      = $false
    $script:Parallelism = 0
    $script:SysOrgPhase = 'preview'
}

AfterAll {
    Clear-SysOrgReparseTagMocks
}

Describe 'v3.0.2 A2 smoke: the menu-option-3 scan flow over the crash fixture' {

    It 'runs profile -> scan -> duplicates -> version pairs -> projects -> collections -> plan without "Argument types do not match"' {
        $plansDir = $script:smokeFolders.Plans
        $before = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        $out = Invoke-SysOrgScanFlow -Letter 'X' -PreviewOnly -WholeDrive 2>&1 3>&1 4>&1 5>&1 6>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n")
        $text | Should -Not -Match 'Argument types do not match'
        $text | Should -Not -Match '\[ERROR \]'
        $text | Should -Match 'Code project folders detected: 2'
        $after = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        $after | Should -Be ($before + 1) -Because 'the flow must save exactly one plan for this tree'
        $plans = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.json' -File)
        $planRaw = Get-Content -LiteralPath $plans[0].FullName -Raw
        $plan = $planRaw | ConvertFrom-Json
        @($plan.Actions).Count | Should -BeGreaterThan 0
        $kindTxt = ((@($plan.Actions) | ForEach-Object { "$($_.Action)/$($_.Kind)" }) -join ', ')
        @($plan.Actions | Where-Object { "$($_.Kind)" -eq 'Folder' }).Count | Should -BeGreaterThan 0 -Because "the user collection moves as ONE unit (actions: $kindTxt)"
    }

    It 'reuses the plan and the file-state cache on the identical second run' {
        $plansDir = $script:smokeFolders.Plans
        $before = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        $out = Invoke-SysOrgScanFlow -Letter 'X' -PreviewOnly -WholeDrive 2>&1 3>&1 4>&1 5>&1 6>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n")
        $text | Should -Not -Match 'Argument types do not match'
        $text | Should -Match 'Reusing existing plan'
        $after = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
        @($after).Count | Should -Be @($before).Count -Because 'an identical scan reuses the existing plan instead of duplicating it'
        Test-Path -LiteralPath (Join-Path $script:smokeFolders.Cache 'filestate.ndjson') | Should -BeTrue -Because 'the file-state cache must actually be persisted'
    }

    It 'prints the preserved counts and the report-only signals that the real run crashed after' {
        $out = Invoke-SysOrgScanFlow -Letter 'X' -PreviewOnly -WholeDrive 2>&1 3>&1 4>&1 5>&1 6>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n")
        # the exact line class that crashed the real run (@() on a New-Object List[object])
        $text | Should -Match 'Preserved without enumeration: 1 dependency folder\(s\), 2 project folder\(s\)'
        $text | Should -Match 'Possible newer-version pairs \(report only\): 1'
        $text | Should -Match 'Duplicate groups found: 1'
        $text | Should -Match 'User collections detected: 2'
    }
}

# ---------------------------------------------------------------------------
# Windows CI legs only: the REAL end-to-end invocation - a child PowerShell
# process running SysOrg.ps1 -ScanDrive <subst-drive> -ReportOnly through the
# exact CLI path, over a fixture with a real junction and a mocked
# cloud-reparse tag via the environment seam.
# ---------------------------------------------------------------------------
Describe 'v3.0.2 A2 smoke: child-process SysOrg.ps1 -ScanDrive -ReportOnly (Windows)' -Skip:($env:OS -ne 'Windows_NT') {

    It 'exits 0 on Windows PowerShell 5.1 and pwsh 7 with no exception in the output' {
        $repo = Split-Path $PSScriptRoot -Parent
        # per-child fixture on a subst drive (real drive letter, no admin needed)
        $tree = Join-Path $TestDrive 'substfix'
        $src  = Join-Path $tree 'src'
        New-Item -ItemType Directory -Path (Join-Path $src 'proj\.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $src 'Pictures') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'proj\.git\HEAD') -Value 'ref: refs/heads/main'
        Set-Content -LiteralPath (Join-Path $src 'Report Final.docx') -Value 'r'
        Set-Content -LiteralPath (Join-Path $src 'Report Final (1).docx') -Value 'r'
        Set-Content -LiteralPath (Join-Path $src 'Budget 2026.xlsx') -Value 'budget-v1'
        Set-Content -LiteralPath (Join-Path $src 'Budget 2026 (1).xlsx') -Value 'budget-v2'
        Set-Content -LiteralPath (Join-Path $src 'Data (backup).csv') -Value 'd'
        $null = New-Item -ItemType Junction -Path (Join-Path $src 'Documents\My Pictures') -Target (Join-Path $src 'Pictures') -Force -ErrorAction SilentlyContinue

        # a PRIVATE copy of the app so the child's Plans/Cache/Logs stay out of the repo
        $appDir = Join-Path $tree 'app'
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'SysOrg.ps1') -Destination (Join-Path $appDir 'SysOrg.ps1')
        Copy-Item -Path (Join-Path $repo 'Modules') -Destination (Join-Path $appDir 'Modules') -Recurse
        if(Test-Path -LiteralPath (Join-Path $repo 'Rules')){ Copy-Item -Path (Join-Path $repo 'Rules') -Destination (Join-Path $appDir 'Rules') -Recurse }

        $letter = $null
        foreach($cand in @('X','Y','Z','W','V')){
            if(-not (Test-Path -LiteralPath "$cand`:")){ $letter = $cand; break }
        }
        if(-not $letter){ Set-ItResult -Inconclusive -Because 'no free drive letter for subst'; return }
        $null = cmd /c "subst $letter`: `"$src`""
        try{
            if(-not (Test-Path -LiteralPath "$letter`:\")){ Set-ItResult -Inconclusive -Because 'subst mapping failed'; return }
            $cfgPath = Join-Path $appDir 'SysOrg.config.psd1'
            @(
                '@{'
                "    Version        = '3.0.2'"
                "    AppRoot        = '$appDir'"
                "    OrganizedRoots = @{ '*' = '$letter`:\_Organized' }"
                "    Copies         = @{ Policy='NumberCopies'; MinFileSizeKB=0; DocMinFileSizeKB=0; HeaderHashKB=64 }"
                "    Classify       = @{ MinConfidence=0.40; ReviewConfidence=0.0 }"
                "    Review         = @{ Mode='Report' }"
                "    Learn          = @{ Enabled=`$false }"
                "    Families       = @{ Enabled=`$false }"
                "    Downloads      = @{ UseZoneIdentifier=`$false }"
                "    ExcludedPaths  = @()"
                "    ExcludedFilePatterns = @()"
                "    DateFolders    = 'Year'"
                "    FolderAudit    = @{ Enabled = `$true }"
                "    TypeMap        = @{}"
                "    Plans          = @{ ReuseIdentical = `$true }"
                '}'
            ) | Set-Content -LiteralPath $cfgPath -Encoding UTF8

            $env:SYSORG_REPARSE_MOCK = ('{0}=90000001' -f ((Join-Path $src 'Pictures') -replace '\\','\\'))
            try{
                $hosts517 = @(@{ Exe=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); Label='PS 5.1' })
                $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)
                if($pwshExe){ $hosts517 += @{ Exe=$pwshExe.Source; Label='pwsh 7' } }
                foreach($h in $hosts517){
                    $out = & $h.Exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $appDir 'SysOrg.ps1') -ScanDrive $letter -ReportOnly -ConfigPath $cfgPath -Timing 2>&1
                    $exit = $LASTEXITCODE
                    $text = (($out | ForEach-Object { "$_" }) -join "`n")
                    $exit | Should -Be 0 -Because ("{0} child run must succeed" -f $h.Label)
                    $text | Should -Not -Match 'Argument types do not match'
                    $text | Should -Match 'Code project folders detected: 1'
                    $text | Should -Match 'Plan saved:'
                }
            } finally {
                Remove-Item Env:SYSORG_REPARSE_MOCK -ErrorAction SilentlyContinue
            }
        } finally {
            $null = cmd /c "subst $letter`: /d"
        }
    }
}

# ---------------------------------------------------------------------------
# v3.0.2 D4: a plan that cannot be built reports the cause in one line, points
# at the log and offers the diagnostics bundle - through the REAL flow.
# ---------------------------------------------------------------------------
Describe 'v3.0.2 D4: forced plan-build failure through the real scan flow' {

    It 'prints the cause, "Nothing was modified.", the log path - and saves no plan' {
        $env:SYSORG_FAULT_PLANBUILD = 'd4-fault'
        try {
            # the fixture changed (new file) so the identical-scan plan reuse misses
            # and the flow really calls New-SysOrgPlan, which now faults
            Set-Content -LiteralPath (Join-Path $script:smokeRoot 'Documents\d4 new file.txt') -Value 'd4'
            $plansDir = $script:smokeFolders.Plans
            $before = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
            $out = Invoke-SysOrgScanFlow -Letter 'X' -PreviewOnly -WholeDrive 2>&1 3>&1 4>&1 5>&1 6>&1
            $text = (($out | ForEach-Object { "$_" }) -join "`n")
            $text | Should -Match 'Plan could not be built: Synthetic plan-build fault'
            $text | Should -Match 'Nothing was modified\.'
            $text | Should -Match 'Full diagnostic:'
            $after = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
            $after | Should -Be $before -Because 'a failed plan build saves nothing'
        } finally {
            Remove-Item Env:SYSORG_FAULT_PLANBUILD -ErrorAction SilentlyContinue
        }
    }
}
