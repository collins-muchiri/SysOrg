# ---------------------------------------------------------------------------
# v3.0.2 D1 + D2: the plan picker's list/empty state and the menu header's
# real version. The real run's option 5 asked for "number, plan id, full path,
# or folder" with NO list and NO explanation (typing 1 -> "No matching plan
# found"), and the header had said 'rev 2.1' since v2.1.
# ---------------------------------------------------------------------------
BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'Modules\SysOrg.Core.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'Modules\SysOrg.Plan.psm1') -Force -DisableNameChecking
    $sysAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'SysOrg.ps1'), [ref]$null, [ref]$null)
    foreach($fnName in @('Show-SysOrgPlanPickerList','Get-SysOrgDisplayVersion')){
        $fd = $sysAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { $_.Name -eq $fnName } | Select-Object -First 1
        if(-not $fd){ throw "SysOrg.ps1 no longer defines $fnName" }
        Invoke-Expression $fd.Extent.Text
    }
}

Describe 'option 5 plan picker list (v3.0.2 D1)' {

    It 'lists the newest plans with number, id, drive, moves, age and status BEFORE the prompt' {
        $plans = Join-Path $TestDrive ('plans-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $plans -Force | Out-Null
        foreach($n in 1..3){
            @{ PlanId="plan-20260101-09300$n-001"; Drive='C:'; Actions=@(@{ Action='Move'; Source='C:\a.txt'; Destination='C:\d\a.txt' }) } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $plans "plan-20260101-09300$n-001.json") -Encoding UTF8
        }
        Start-Sleep -Milliseconds 50   # distinct LastWriteTime for a deterministic order
        @{ PlanId='plan-20260101-093004-001'; Drive='D:'; Actions=@(@{ Action='Move'; Source='C:\b.txt'; Destination='C:\d\b.txt' }) } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $plans 'plan-20260101-093004-001.json') -Encoding UTF8
        $out = Show-SysOrgPlanPickerList -PlansFolder $plans -Top 10 2>&1 3>&1 4>&1 5>&1 6>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n")
        $text | Should -Match 'Newest plans in'
        $text | Should -Match '\[1\] plan-'
        $text | Should -Match '\[4\] plan-'   # all four listed, numbered
        $text | Should -Match 'not executed'
        @($out | Where-Object { $_ -is [pscustomobject] -and $_.PlanId }).Count | Should -Be 4 -Because 'the rows are returned for the picker'
    }

    It 'prints the honest empty state when there are no saved plans' {
        $empty = Join-Path $TestDrive ('emptyplans-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $out = Show-SysOrgPlanPickerList -PlansFolder $empty -Top 10 2>&1 3>&1 4>&1 5>&1 6>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n")
        $text | Should -Match ('No saved plans in ' + [regex]::Escape($empty))
        $text | Should -Match 'run option 3'
    }

    It 'an entirely missing plans folder is an empty state too, not an error' {
        $missing = Join-Path $TestDrive ('noplans-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $out = Show-SysOrgPlanPickerList -PlansFolder $missing -Top 10 2>&1 3>&1 4>&1 5>&1 6>&1
        $text = (($out | ForEach-Object { "$_" }) -join "`n")
        $text | Should -Match 'No saved plans in'
    }
}

Describe 'menu header version (v3.0.2 D2)' {

    It 'shows the version from the config' {
        Get-SysOrgDisplayVersion -Config @{ Version = '9.9.9-test' } | Should -Be '9.9.9-test'
    }

    It 'says the key is missing when the config has no Version' {
        Get-SysOrgDisplayVersion -Config @{} | Should -Match 'Version missing'
    }
}

# ---------------------------------------------------------------------------
# v3.0.2 D4: a plan that cannot be built offers the diagnostics bundle right
# where the user is (cause in one line + log path + optional bundle).
# ---------------------------------------------------------------------------
Describe 'diagnostics bundle offer on plan failure (v3.0.2 D4)' {

    BeforeAll {
        $repo2 = Split-Path $PSScriptRoot -Parent
        $sysAst2 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo2 'SysOrg.ps1'), [ref]$null, [ref]$null)
        foreach($fnName in @('Offer-SysOrgDiagnosticsBundle','Invoke-SysOrgDiagnosticsBundle')){
            $fd2 = $sysAst2.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                Where-Object { $_.Name -eq $fnName } | Select-Object -First 1
            if(-not $fd2){ throw "SysOrg.ps1 no longer defines $fnName" }
            Invoke-Expression $fd2.Extent.Text
        }
    }

    It 'prints the cause, the log path and creates the bundle when the user answers yes' {
        $logs = Join-Path $TestDrive ('d4logs-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        $appD = Join-Path $TestDrive ('d4app-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        New-Item -ItemType Directory -Path $appD -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $appD 'SysOrg.config.psd1') -Value "@{ Version = '9.9.9-test' }"
        $script:appRoot = $appD
        $script:logFolder = $logs
        $script:Config = @{ Version = '9.9.9-test' }
        $script:ConfigPath = (Join-Path $appD 'SysOrg.config.psd1')
        $script:SysOrgElevatedSession = $false
        function global:Read-Host { param([string]$Prompt) return 'y' }
        try {
            $out = Offer-SysOrgDiagnosticsBundle -Cause 'synthetic plan fault' -LogPath 'C:\fake\sysorg.log' 2>&1 3>&1 4>&1 5>&1 6>&1
            $text = (($out | ForEach-Object { "$_" }) -join "`n")
            $text | Should -Match 'Plan could not be built: synthetic plan fault'
            $text | Should -Match 'Nothing was modified\.'
            $text | Should -Match 'Diagnostics bundle written:'
            @(Get-ChildItem -LiteralPath $logs -Filter 'diagnostics-*.txt').Count | Should -Be 1
        } finally {
            Remove-Item function:global:Read-Host -ErrorAction SilentlyContinue
        }
    }

    It 'creates no bundle when the user declines' {
        $logs2 = Join-Path $TestDrive ('d4logs2-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $logs2 -Force | Out-Null
        $script:logFolder = $logs2
        $script:Config = @{}
        $script:ConfigPath = $null
        $script:appRoot = $TestDrive
        function global:Read-Host { param([string]$Prompt) return 'n' }
        try {
            $out2 = (Offer-SysOrgDiagnosticsBundle -Cause 'second fault' -LogPath $null 2>&1 3>&1 4>&1 5>&1 6>&1 | ForEach-Object { "$_" }) -join "`n"
            $out2 | Should -Match 'Plan could not be built: second fault'
            @(Get-ChildItem -LiteralPath $logs2 -Filter 'diagnostics-*.txt' -ErrorAction SilentlyContinue).Count | Should -Be 0
        } finally {
            Remove-Item function:global:Read-Host -ErrorAction SilentlyContinue
        }
    }
}
