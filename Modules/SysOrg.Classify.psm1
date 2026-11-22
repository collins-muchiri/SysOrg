#Requires -Version 5.1
# SysOrg.Classify.psm1 - the v3.0 scored classification pipeline (Phase 2).
#
# Every file gets a Decision record: Destination (leaf base for the Findable
# layout), Confidence (0..1), RuleId (which rule decided), and Signals[] (what
# was detected and why). The pipeline runs IN THIS ORDER, and the earlier stages
# always win:
#   1. Safety gates      - protected paths, mutability, reparse points, cloud
#                          placeholders, .sysorg-ignore, already-organized folders
#                          (the plan/scanner already enforce these; the pipeline
#                          records them as gates and never overrides them)
#   2. User rules        - Rules\UserRules.psd1 (validated at startup, fail closed)
#   3. Learned rules     - _Index\LearnedRules.psd1, ONLY when
#                          Rules.ApplyLearned = $true (never applied silently)
#   4. Context           - download root, source bucket, messaging / camera /
#                          screenshot / screen-recording filename patterns
#   5. True type         - extension first, magic-byte sniffing for missing or
#                          mismatched extensions (max 512 bytes)
#   6. Metadata          - EXIF / ID3 / MP4 mvhd / Office core.xml / PDF info /
#                          text snippet (mockable, fail-soft)
#   7. Date resolution   - metadata date > filename date > filesystem date
#   8. Lexicon scoring   - weighted tokens -> document category + confidence
#   9. Confidence gating - >= Confident (0.70) plan normally; 0.40..0.70 plan
#                          flagged 'review'; below MinConfidence (0.40) the file is
#                          NOT moved (needs a decision)
#
# Determinism: identical inputs produce identical decisions; no randomness.

function New-SysOrgDecision {
<#
.SYNOPSIS
    Creates an empty Decision record (v3.0 Phase 2.1).
.EXAMPLE
    New-SysOrgDecision -Path 'C:\x\a.pdf'   # -> decision skeleton
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [pscustomobject]@{
        Path          = $Path
        Category      = $null       # routing category (Documents, Pictures, ...)
        Subtype       = $null       # Findable subtype (Finance\Invoices, Camera, ...)
        Destination   = $null       # Findable leaf base (relative to the root)
        Confidence    = 0.0
        RuleId        = ''          # 'gate:*', 'user:<name>', 'learned:<name>', 'context:*', 'type:*', 'lexicon:*', 'default'
        Date          = $null
        DateSource    = ''
        Signals       = New-Object System.Collections.Generic.List[string]
        NeedsDecision = $false      # below Classify.MinConfidence -> left in place / _Review
        Flags         = New-Object System.Collections.Generic.List[string]   # 'review', 'gate', ...
        Gate          = $null       # gate denial reason (safety gates always win)
    }
}

function Add-SysOrgDecisionSignal {
<#
.SYNOPSIS
    Appends a signal to a Decision record.
.EXAMPLE
    Add-SysOrgDecisionSignal -Decision $d -Signal 'Context: messaging=WhatsApp'
#>
    param([Parameter(Mandatory)]$Decision,[Parameter(Mandatory)][string]$Signal)
    [void]$Decision.Signals.Add($Signal)
    return $Decision
}

function Get-SysOrgContextSignals {
<#
.SYNOPSIS
    Stage 2 (v3.0 Phase 2.2): context detection from the file's location and name.
.DESCRIPTION
    Returns @{ Signals=<string[]>; Source=<bucket or ''>; IsScreenshot; IsScreenRecording;
    IsMessaging; IsVoiceNote; InDownloads } - deterministic filename patterns:
      camera/screenshot/screen-recording patterns, messaging app names, voice notes.
    Download-root membership comes from the drive profile's DownloadRoots; the source
    bucket reuses the hardened v2.1.1 resolver (Zone.Identifier URLs are read by the
    caller - this function only inspects the name when no URL bucket exists).
.EXAMPLE
    Get-SysOrgContextSignals -Path 'C:\dl\WhatsApp Image 2024-01-01.jpg' -DownloadRoots @('C:\dl')
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[AllowEmptyCollection()][string[]]$DownloadRoots,[string]$UrlBucket)
    $signals = New-Object System.Collections.Generic.List[string]
    $name = Split-Path $Path -Leaf
    $stem = ([System.IO.Path]::GetFileNameWithoutExtension($name)).ToLowerInvariant()
    $inDownloads = $false
    $pn = ("$Path").Replace('/','\')
    foreach($r in @($DownloadRoots)){
        if([string]::IsNullOrWhiteSpace("$r")){ continue }
        $r2 = (("$r").Replace('/','\')).TrimEnd('\')
        if($pn.StartsWith($r2 + '\',[StringComparison]::OrdinalIgnoreCase)){ $inDownloads = $true; break }
    }
    if($inDownloads){ [void]$signals.Add('Context: inside a download root') }

    $isScreenshot = $false; $isScreenRecording = $false; $isMessaging = $false; $isVoiceNote = $false
    if($stem -match '(^|[^a-z])screenshot'){ $isScreenshot = $true; [void]$signals.Add('Context: screenshot filename pattern') }
    if($stem -match '(screen ?rec|screen ?capt|screenrecord)'){ $isScreenRecording = $true; [void]$signals.Add('Context: screen-recording filename pattern') }
    if($stem -match '^(whatsapp|wa\d{4})'){ $isMessaging = $true; [void]$signals.Add('Context: WhatsApp filename pattern') }
    elseif($stem -match '^(telegram)'){ $isMessaging = $true; [void]$signals.Add('Context: Telegram filename pattern') }
    elseif($stem -match '^(signal-)'){ $isMessaging = $true; [void]$signals.Add('Context: Signal filename pattern') }
    elseif("$UrlBucket" -in @('WhatsApp','Telegram','Signal')){ $isMessaging = $true; [void]$signals.Add(('Context: messaging source ' + $UrlBucket)) }
    if($stem -match '^(voice|voice ?note|voice ?memo|record|meeting|call)'){ $isVoiceNote = $true; [void]$signals.Add('Context: voice-recording filename pattern') }
    if($stem -match '^(img|vid|dsc|dji)_?\d'){ [void]$signals.Add('Context: camera filename pattern') }
    if("$UrlBucket"){ [void]$signals.Add(('Context: source bucket ' + $UrlBucket)) }

    return [pscustomobject]@{
        Signals=$signals; Source="$UrlBucket"; InDownloads=$inDownloads
        IsScreenshot=$isScreenshot; IsScreenRecording=$isScreenRecording
        IsMessaging=$isMessaging; IsVoiceNote=$isVoiceNote
    }
}

function Invoke-SysOrgClassifyPipeline {
<#
.SYNOPSIS
    Runs the scored classification pipeline for one file (v3.0 Phase 2).
.DESCRIPTION
    Stage order is fixed and documented in the module header; earlier stages always
    win over later ones. -IncludeMetadata enables the metadata extractors (stages
    6-8); without it the pipeline stops after context + true type, which is what the
    scan path uses for cheap routing decisions.
    Safety gates: -GateReason (a non-empty string from the plan/scanner) marks the
    file as gated - the Decision carries the gate reason and NO destination; gates
    always win over every organizing rule.
    The pipeline NEVER throws: a stage failure degrades to the next signal and is
    recorded as a signal line, so one malformed file cannot break a plan.
.EXAMPLE
    $d = Invoke-SysOrgClassifyPipeline -Path 'C:\dl\IMG_20240101_101010.jpg' -Extension '.jpg' -Category 'Pictures' -Config $cfg -DriveProfile $prof -IncludeMetadata
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Extension,
        [AllowEmptyString()][string]$Category,
        $Config,
        $DriveProfile,
        [string]$GateReason,
        [string]$UrlBucket,
        [switch]$IncludeMetadata,
        [hashtable]$Extractors,
        [hashtable]$DateOverride,
        $UserRules,
        $LearnedRules,
        [string]$AppRoot
    )
    $d = New-SysOrgDecision -Path $Path
    $ext = "$Extension".ToLowerInvariant()
    $name = Split-Path $Path -Leaf
    $meta = $null
    $lex = $null
    $resolved = $null

    # --- stage 1: safety gates (always win; the pipeline never moves gated files) ---
    if(-not [string]::IsNullOrWhiteSpace("$GateReason")){
        $d.Gate = "$GateReason"
        $d.RuleId = 'gate'
        [void]$d.Signals.Add(('Gate: ' + $GateReason))
        $d.Confidence = 0.0
        return $d
    }
    [void]$d.Signals.Add('Gate: passed (protected paths, mutability, reparse points, cloud placeholders, ignore markers)')

    $dlRoots = @()
    if($DriveProfile){ $dlRoots = @($DriveProfile.DownloadRoots) }
    $ctx = Get-SysOrgContextSignals -Path $Path -DownloadRoots $dlRoots -UrlBucket "$UrlBucket"
    foreach($s in $ctx.Signals){ [void]$d.Signals.Add($s) }

    # --- stage 2/3: user rules and learned rules (safety gates already passed) ---
    $ruleResult = $null
    try {
        $userRules = $UserRules
        if($null -eq $userRules){ $userRules = Get-SysOrgUserRules -Config $Config -AppRoot $AppRoot }
        $ruleResult = Get-SysOrgRuleMatch -Path $Path -Name $name -Extension $ext -Category "$Category" -UserRules $userRules -LearnedRules $LearnedRules -Config $Config
    } catch { [void]$d.Signals.Add(('Rules: ' + $_.Exception.Message)) }
    if($ruleResult){
        $d.Category = "$Category"
        $d.Subtype = $ruleResult.Subtype
        $d.Destination = $ruleResult.Destination
        $d.Confidence = 1.0
        $d.RuleId = $ruleResult.RuleId
        [void]$d.Signals.Add(('Rule: ' + $ruleResult.RuleId + ' -> ' + $ruleResult.Destination))
        if($ruleResult.IsLearned){ [void]$d.Flags.Add('learned') }
        return $d
    }

    # --- stage 4/5: category refinement from context, then true type ---
    $cat = "$Category"
    if(-not $cat){ $cat = 'Other' }
    $subtype = Get-SysOrgFindableSubtype -Category $cat -Name $name -Source "$($ctx.Source)"
    if($ctx.IsMessaging){ $subtype = 'Messaging' }
    elseif($ctx.IsScreenshot -and ($cat -in @('Pictures','Images'))){ $subtype = 'Screenshots' }
    elseif($ctx.IsScreenRecording -and ($cat -in @('Videos'))){ $subtype = 'Screen-Recordings' }
    elseif($ctx.IsVoiceNote -and ($cat -in @('Audio','Music'))){ $subtype = 'VoiceNote' }

    # --- stages 6-8: metadata, date resolution, lexicon (Phase 2.4+) ---
    $meta = $null
    $resolved = $null
    if($IncludeMetadata){
        try {
            $meta = Get-SysOrgFileMetadata -Path $Path -Extension $ext -Category $cat -Extractors $Extractors
            if($meta){ [void]$d.Signals.Add(('Metadata: ' + $meta.Source + ' -> ' + (Get-SysOrgMetadataSummary -Metadata $meta))) }
        } catch { [void]$d.Signals.Add(('Metadata: failed soft (' + $_.Exception.Message + ')')) }
        try {
            $resolved = Resolve-SysOrgFileDate -Path $Path -Metadata $meta -DateOverride $DateOverride
            $d.Date = $resolved.Date
            $d.DateSource = $resolved.Source
            [void]$d.Signals.Add(('Date: ' + $resolved.Source + ' -> ' + $resolved.Date.ToString('yyyy-MM-dd')))
        } catch { [void]$d.Signals.Add(('Date: failed soft (' + $_.Exception.Message + ')')) }
        if($cat -in @('Documents','Other','Spreadsheets','Databases')){
            try {
                $lex = Get-SysOrgDocumentCategory -Path $Path -Name $name -Metadata $meta -Config $Config
                if($lex -and ($lex.Confidence -gt 0)){
                    $subtype = $lex.Subtype
                    [void]$d.Signals.Add(('Lexicon: ' + $lex.Subtype + ' score=' + $lex.Matched + ' -> confidence=' + $lex.Confidence))
                }
            } catch { [void]$d.Signals.Add(('Lexicon: failed soft (' + $_.Exception.Message + ')')) }
        }
    }

    # --- stage 9: confidence ---
    $d.Category = $cat
    $d.Subtype = $subtype
    $d.RuleId = 'default'
    if($meta){ $d.Confidence = 0.9 } else { $d.Confidence = 0.8 }
    if($cat -eq 'Other'){ $d.Confidence = [Math]::Min($d.Confidence, 0.5) }
    if($IncludeMetadata -and $lex){
        $d.Confidence = $lex.Confidence
        $d.RuleId = 'lexicon'
    }
    $minConf = 0.40
    $revConf = 0.70
    if($Config){
        $minConf = [double](Get-SysOrgSetting $Config 'Classify.MinConfidence' 0.40)
        $revConf = [double](Get-SysOrgSetting $Config 'Classify.ReviewConfidence' 0.70)
    }
    if($d.Confidence -lt $minConf){
        $d.NeedsDecision = $true
        [void]$d.Flags.Add('needs-decision')
        [void]$d.Signals.Add(('Confidence ' + $d.Confidence + ' below ' + $minConf + ' -> needs a decision (never auto-moved)'))
    } elseif($d.Confidence -lt $revConf){
        [void]$d.Flags.Add('review')
        [void]$d.Signals.Add(('Confidence ' + $d.Confidence + ' below ' + $revConf + ' -> planned with a review flag'))
    }

    # destination leaf from the Findable routing table
    try {
        $rb = Get-SysOrgFindableRelBase -Category $d.Category -Subtype $d.Subtype -Source "$($ctx.Source)" -Name $name -InDownloads:$ctx.InDownloads -TypeLeaf (Get-SysOrgFindableTypeLeaf -Category $d.Category)
        if($meta -and ($d.Subtype -eq 'UntaggedMusic') -and $meta.Artist){
            $rb = Get-SysOrgFindableRelBase -Category 'Music' -Subtype 'TaggedMusic' -Artist "$($meta.Artist)" -Album "$($meta.Album)" -Name $name
            $d.Category = 'Music'
        }
        $d.Destination = $rb.RelBase
    } catch { [void]$d.Signals.Add(('Destination: failed soft (' + $_.Exception.Message + ')')) }

    return $d
}

# ---------------------------------------------------------------------------
# User rules (Rules\UserRules.psd1) and learned rules (_Index\LearnedRules.psd1).
# Precedence: safety gates > user rules > learned rules > built-in pipeline.
# Rules are VALIDATED AT STARTUP; an invalid rules file fails closed with a clear
# message. Learned rules are NEVER applied silently: they are only consulted when
# Rules.ApplyLearned = $true and a learned-rules path is provided.
# ---------------------------------------------------------------------------
$script:SysOrgRuleTokens = @('Year','Month','Day','Source','Artist','Album','Stem','Date')

function Test-SysOrgRuleDefinition {
<#
.SYNOPSIS
    Validates one rule definition; throws with a clear message on any problem.
.DESCRIPTION
    Fail closed: an invalid rule is a startup error, never a silent skip.
.EXAMPLE
    Test-SysOrgRuleDefinition -Rule @{ Name='r'; Priority=10; When=@{ NameRegex='(' }; Destination='X' }   # throws (bad regex)
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule,[int]$Index)
    if($null -eq $Rule -or -not ($Rule -is [hashtable])){ throw ("Rules[{0}]: every rule must be a hashtable." -f $Index) }
    $name = "$($Rule['Name'])"
    if([string]::IsNullOrWhiteSpace($name)){ throw ("Rules[{0}]: a rule is missing its Name." -f $Index) }
    if($Rule.ContainsKey('Priority') -and (-not (($Rule['Priority']) -is [int]) -and (-not (($Rule['Priority']) -is [long])))){
        throw ("Rule '{0}': Priority must be an integer (got '{1}')." -f $name, $Rule['Priority'])
    }
    $when = $Rule['When']
    if($null -eq $when -or -not ($when -is [hashtable])){ throw ("Rule '{0}': When must be a hashtable of match conditions." -f $name) }
    if($when.ContainsKey('Extension')){
        foreach($e in @($when['Extension'])){
            if(-not ("$e" -match '^\.[A-Za-z0-9]+$')){ throw ("Rule '{0}': Extension entries must look like '.pdf' (got '{1}')." -f $name, $e) }
        }
    }
    if($when.ContainsKey('NameRegex') -and ("$($when['NameRegex'])" -ne '')){
        try { [void]([regex]::new("$($when['NameRegex'])")) }
        catch { throw ("Rule '{0}': NameRegex is not a valid regular expression ({1})." -f $name, $_.Exception.Message) }
    }
    if($when.ContainsKey('MinSizeBytes') -and ([double]"$($when['MinSizeBytes'])" -lt 0)){ throw ("Rule '{0}': MinSizeBytes must be >= 0." -f $name) }
    if($when.ContainsKey('MaxSizeBytes') -and ([double]"$($when['MaxSizeBytes'])" -lt 0)){ throw ("Rule '{0}': MaxSizeBytes must be >= 0." -f $name) }
    if($when.ContainsKey('MetadataEquals') -and (-not ($when['MetadataEquals'] -is [hashtable]))){
        throw ("Rule '{0}': MetadataEquals must be a hashtable (e.g. @{ Artist = 'Sauti Sol' })." -f $name)
    }
    $dest = "$($Rule['Destination'])"
    if([string]::IsNullOrWhiteSpace($dest)){ throw ("Rule '{0}': Destination must not be empty." -f $name) }
    if("$dest" -match '\.\.'){ throw ("Rule '{0}': Destination must not contain '..' segments." -f $name) }
    foreach($seg in @("$dest".Split('\'))){
        if([string]::IsNullOrWhiteSpace($seg)){ throw ("Rule '{0}': Destination has an empty segment ('{1}')." -f $name, $dest) }
    }
    foreach($tok in [System.Text.RegularExpressions.Regex]::Matches("$dest", '\{([^}]+)\}')){
        if($script:SysOrgRuleTokens -notcontains $tok.Groups[1].Value){
            throw ("Rule '{0}': Destination token '{1}' is unknown (allowed: {2})." -f $name, $tok.Groups[1].Value, ($script:SysOrgRuleTokens -join ', '))
        }
    }
}

function Get-SysOrgRulesFile {
<#
.SYNOPSIS
    Loads and validates a rules file. Missing file -> empty; invalid -> THROW (fail closed).
.EXAMPLE
    Get-SysOrgRulesFile -Path 'C:\SysOrg\Rules\UserRules.psd1'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Kind)
    if(-not (Test-Path -LiteralPath $Path)){ return @() }
    $loaded = $null
    try { $loaded = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop }
    catch { throw ("{0} rules file '{1}' could not be parsed: {2}" -f $Kind, $Path, $_.Exception.Message) }
    if($loaded -isnot [hashtable] -or -not $loaded.ContainsKey('Rules')){
        throw ("{0} rules file '{1}' must be a hashtable with a Rules list." -f $Kind, $Path)
    }
    $rules = @()
    $i = 0
    foreach($r in @($loaded['Rules'])){
        Test-SysOrgRuleDefinition -Rule $r -Index $i
        $rules += [pscustomobject]@{
            Name="$($r['Name'])"; Priority=[int]("$($r['Priority'])" -as [int]); Index=$i
            When=$r['When']; Destination="$($r['Destination'])"
        }
        $i++
    }
    return ($rules | Sort-Object -Property @{e={$_.Priority}}, @{e={$_.Index}})
}

function Get-SysOrgUserRules {
<#
.SYNOPSIS
    Loads Rules\UserRules.psd1 (path from config Rules.UserRulesPath or <AppRoot>\Rules\UserRules.psd1).
.DESCRIPTION
    Missing file is fine (no user rules). A file that exists but is invalid THROWS -
    fail closed, per the Phase 2 contract.
.EXAMPLE
    Get-SysOrgUserRules -Config $cfg -AppRoot 'C:\SysOrg'
#>
    [CmdletBinding()]
    param($Config,[string]$AppRoot)
    $path = "$(Get-SysOrgSetting $Config 'Rules.UserRulesPath' '')"
    if([string]::IsNullOrWhiteSpace($path) -and $AppRoot){ $path = (Join-Path $AppRoot 'Rules\UserRules.psd1') }
    if([string]::IsNullOrWhiteSpace($path)){ return @() }
    return (Get-SysOrgRulesFile -Path $path -Kind 'User')
}

function Get-SysOrgLearnedRules {
<#
.SYNOPSIS
    Loads _Index\LearnedRules.psd1 - ONLY when Rules.ApplyLearned is $true.
.DESCRIPTION
    Learned rules are saved from user corrections (Phase 2 learning / Phase 4 catalog).
    They are never applied silently: an explicit config opt-in plus an explicit path
    is required, and every move a learned rule plans is flagged 'learned' in the preview.
.EXAMPLE
    Get-SysOrgLearnedRules -Config $cfg -Path 'C:\Org\_Index\LearnedRules.psd1'
#>
    [CmdletBinding()]
    param($Config,[string]$Path)
    $apply = [bool](Get-SysOrgSetting $Config 'Rules.ApplyLearned' $false)
    if(-not $apply){ return @() }
    if([string]::IsNullOrWhiteSpace($Path)){ return @() }
    return (Get-SysOrgRulesFile -Path $Path -Kind 'Learned')
}

function Save-SysOrgLearnedRule {
<#
.SYNOPSIS
    Appends a user-confirmed correction as a learned rule in _Index\LearnedRules.psd1.
.DESCRIPTION
    The rule is written with a When condition on the original name pattern and the
    destination the user chose. Saving does NOT apply anything - application requires
    Rules.ApplyLearned=$true and is flagged in the preview.
.EXAMPLE
    Save-SysOrgLearnedRule -Path 'C:\Org\_Index\LearnedRules.psd1' -Name 'tax-pdf' -NameRegex '(?i)kra' -Destination 'Documents\Finance\Tax\{Year}'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name,
          [Parameter(Mandatory)][string]$NameRegex,[Parameter(Mandatory)][string]$Destination)
    $rule = @{ Name="$Name"; Priority=1; When=@{ NameRegex="$NameRegex" }; Destination="$Destination" }
    Test-SysOrgRuleDefinition -Rule $rule -Index 0
    # Rebuild the whole file from existing (loadable) rules + the new one, so the file
    # is ALWAYS a complete, parseable PSD1 even after an interrupted earlier write.
    $existing = @()
    if(Test-Path -LiteralPath $Path){
        try { $existing = @(Get-SysOrgRulesFile -Path $Path -Kind 'Learned') } catch { $existing = @() }
    }
    $dir = Split-Path $Path -Parent
    if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    function ConvertTo-SysOrgPsd1String { param([string]$S)
        return ('''' + ($S -replace '''','''''') + '''')
    }
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('# Learned rules - saved from corrections you confirmed.')
    [void]$lines.Add('# NEVER applied automatically: set Rules.ApplyLearned = $true to use them.')
    [void]$lines.Add('@{')
    [void]$lines.Add('    Rules = @(')
    foreach($r in $existing){
        [void]$lines.Add(('        @{{ Name = {0}; Priority = {1}; When = @{{ NameRegex = {2} }}; Destination = {3} }}' -f `
            (ConvertTo-SysOrgPsd1String "$($r.Name)"), [int]$r.Priority, (ConvertTo-SysOrgPsd1String "$($r.When['NameRegex'])"), (ConvertTo-SysOrgPsd1String "$($r.Destination)")))
    }
    [void]$lines.Add(('        @{{ Name = {0}; Priority = 1; When = @{{ NameRegex = {1} }}; Destination = {2} }}' -f `
        (ConvertTo-SysOrgPsd1String $Name), (ConvertTo-SysOrgPsd1String $NameRegex), (ConvertTo-SysOrgPsd1String $Destination)))
    [void]$lines.Add('    )')
    [void]$lines.Add('}')
    [System.IO.File]::WriteAllLines($Path, $lines)
    return $Path
}

function Expand-SysOrgRuleTemplate {
<#
.SYNOPSIS
    Expands the destination template tokens of a rule ({Year}, {Month}, {Day},
    {Source}, {Artist}, {Album}, {Stem}, {Date}) into a concrete leaf path.
.DESCRIPTION
    Each path segment is sanitized separately (the safe-name sanitizer must never
    collapse the path separators themselves).
.EXAMPLE
    Expand-SysOrgRuleTemplate -Template 'Documents\Work\{Year}' -Context @{ Year='2024'; Stem='report' }
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Template,[hashtable]$Context)
    $segs = @("$Template".Split('\'))
    $out = New-Object System.Collections.Generic.List[string]
    foreach($seg in $segs){
        $s = $seg
        foreach($tok in $script:SysOrgRuleTokens){
            $v = ''
            if($Context -and $Context.ContainsKey($tok)){ $v = "$($Context[$tok])" }
            $s = $s.Replace(('{' + $tok + '}'), $v)
        }
        [void]$out.Add($(if([string]::IsNullOrWhiteSpace($s)){ '' } else { (Get-SysOrgSafeFolderName -Name $s -MaxLength 80) }))
    }
    return ($out -join '\')
}

function Get-SysOrgRuleMatch {
<#
.SYNOPSIS
    Stages 2-3: the first matching user or learned rule (priority order, then
    definition order). Returns $null when no rule matches.
.DESCRIPTION
    Conditions combine with AND; an absent condition means 'always'. A rule needing
    metadata (MetadataEquals) never matches when no metadata was supplied. Learned
    rules are consulted only after user rules, only when provided (the caller only
    passes them when Rules.ApplyLearned=$true).
.EXAMPLE
    Get-SysOrgRuleMatch -Path 'C:\dl\a.pdf' -Extension '.pdf' -Category 'Documents' -Name 'a.pdf' -SizeBytes 100 -Config $cfg -UserRules $rules
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name,
          [AllowEmptyString()][string]$Extension,[AllowEmptyString()][string]$Category,
          [long]$SizeBytes = -1,[hashtable]$Metadata,$UserRules,$LearnedRules,$Config)
    $setIndex = 0
    foreach($setRaw in @($UserRules, $LearnedRules)){
        $isLearnedSet = ($setIndex -eq 1)
        if($setRaw){
        foreach($rule in @($setRaw)){
            $w = $rule.When
            $match = $true
            if($w.ContainsKey('Extension') -and @($w['Extension']).Count -gt 0){
                if(@($w['Extension']) -notcontains $Extension){ $match = $false }
            }
            if($match -and $w.ContainsKey('NameRegex') -and ("$($w['NameRegex'])" -ne '')){
                if("$Name" -notmatch "$($w['NameRegex'])"){ $match = $false }
            }
            if($match -and $w.ContainsKey('PathGlob') -and ("$($w['PathGlob'])" -ne '')){
                if("$Path" -notlike "$($w['PathGlob'])"){ $match = $false }
            }
            if($match -and $w.ContainsKey('MinSizeBytes')){
                if(($SizeBytes -lt 0) -or ($SizeBytes -lt [long]$w['MinSizeBytes'])){ $match = $false }
            }
            if($match -and $w.ContainsKey('MaxSizeBytes') -and ([long]$w['MaxSizeBytes'] -gt 0)){
                if(($SizeBytes -lt 0) -or ($SizeBytes -gt [long]$w['MaxSizeBytes'])){ $match = $false }
            }
            if($match -and $w.ContainsKey('SourceBucket') -and ("$($w['SourceBucket'])" -ne '')){
                $sb = ''
                if($Metadata -and $Metadata.ContainsKey('SourceBucket')){ $sb = "$($Metadata['SourceBucket'])" }
                if("$sb" -ne "$($w['SourceBucket'])"){ $match = $false }
            }
            if($match -and $w.ContainsKey('MetadataEquals') -and ($w['MetadataEquals'] -is [hashtable]) -and ($w['MetadataEquals'].Count -gt 0)){
                if(-not $Metadata){ $match = $false }
                else {
                    foreach($k in $w['MetadataEquals'].Keys){
                        $mv = ''
                        if($Metadata.ContainsKey("$k")){ $mv = "$($Metadata["$k"])" }
                        if("$mv" -ne "$($w['MetadataEquals'][$k])"){ $match = $false; break }
                    }
                }
            }
            if($match){
                $prefix = 'user'
                if($isLearnedSet){ $prefix = 'learned' }
                return [pscustomobject]@{
                    RuleId=($prefix + ':' + $rule.Name)
                    Destination=$rule.Destination
                    Subtype=$null
                    IsLearned=$isLearnedSet
                }
            }
        }
        }
        $setIndex++
    }
    return $null
}

function Show-SysOrgDecision {
<#
.SYNOPSIS
    Prints a Decision record line by line (the -Explain output).
.EXAMPLE
    Show-SysOrgDecision -Decision $d
#>
    param([Parameter(Mandatory)]$Decision)
    Write-Host ("Decision for: {0}" -f $Decision.Path) -ForegroundColor White
    Write-Host ("  Category: {0}   Subtype: {1}   Destination: {2}" -f $Decision.Category, $Decision.Subtype, $Decision.Destination)
    Write-Host ("  Confidence: {0}   Rule: {1}   Date: {2} ({3})" -f $Decision.Confidence, $Decision.RuleId, $Decision.Date, $Decision.DateSource)
    if($Decision.NeedsDecision){ Write-Host '  NEEDS A DECISION - not planned automatically.' -ForegroundColor Yellow }
    if($Decision.Gate){ Write-Host ("  GATED: {0}" -f $Decision.Gate) -ForegroundColor Yellow }
    if(@($Decision.Flags).Count -gt 0){ Write-Host ("  Flags: {0}" -f (@($Decision.Flags) -join ', ')) }
    Write-Host '  Signals:' -ForegroundColor Gray
    foreach($s in @($Decision.Signals)){ Write-Host ('    ' + $s) -ForegroundColor DarkGray }
}

Export-ModuleMember -Function *-SysOrg*
