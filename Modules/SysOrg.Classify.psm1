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

# compiled-token regex cache (Phase 3.8: lexicon hotspot) - token -> [regex]
$script:SysOrgTokenRegexCache = @{}

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
        TakesDate     = $true        # false for event/music/installer leaves
        Meta          = $null        # metadata hashtable when -IncludeMetadata
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
    try {
        $tt = Get-SysOrgTrueType -Path $Path -Extension $ext -Category $cat
        if($tt -and $tt.Matched -and $tt.Corrected){
            $cat = $tt.Category
            [void]$d.Signals.Add(('TrueType: content is ' + $tt.SignatureType + '; extension said ' + $tt.ExtensionCategory + ' -> corrected to ' + $cat))
        } elseif($tt -and $tt.Matched) {
            [void]$d.Signals.Add(('TrueType: content confirms ' + $tt.SignatureType))
        }
    } catch { [void]$d.Signals.Add(('TrueType: failed soft (' + $_.Exception.Message + ')')) }
    $subtype = Get-SysOrgFindableSubtype -Category $cat -Name $name -Source "$($ctx.Source)"
    if($ctx.IsMessaging){ $subtype = 'Messaging' }
    elseif($ctx.IsScreenshot -and ($cat -in @('Pictures','Images'))){ $subtype = 'Screenshots' }
    elseif($ctx.IsScreenRecording -and ($cat -in @('Videos'))){ $subtype = 'Screen-Recordings' }
    elseif($ctx.IsVoiceNote -and ($cat -in @('Audio','Music'))){ $subtype = 'VoiceNote' }

    # --- stages 6-8: metadata, date resolution, lexicon (Phase 2.4+) ---
    $minConf = 0.40
    $revConf = 0.70
    if($Config){
        $minConf = [double](Get-SysOrgSetting $Config 'Classify.MinConfidence' 0.40)
        $revConf = [double](Get-SysOrgSetting $Config 'Classify.ReviewConfidence' 0.70)
    }
    $meta = $null
    $resolved = $null
    if($IncludeMetadata){
        try {
            $meta = Get-SysOrgFileMetadata -Path $Path -Extension $ext -Extractors $Extractors
            if($meta){ [void]$d.Signals.Add(('Metadata: ' + $meta.Source + ' -> ' + (Get-SysOrgMetadataSummary -Metadata $meta))) }
        } catch { [void]$d.Signals.Add(('Metadata: failed soft (' + $_.Exception.Message + ')')) }
        try {
            $resolved = Resolve-SysOrgFileDate -Path $Path -Metadata $meta -DateOverride $DateOverride
            $d.Date = $resolved.Date
            $d.DateSource = $resolved.Source
            [void]$d.Signals.Add(('Date: ' + $resolved.Source + ' -> ' + $resolved.Date.ToString('yyyy-MM-dd')))
        } catch { [void]$d.Signals.Add(('Date: failed soft (' + $_.Exception.Message + ')')) }
        if($cat -in @('Documents','Other','Spreadsheets','Databases') -and (Get-Command Get-SysOrgDocumentCategory -ErrorAction SilentlyContinue)){
            try {
                $lex = Get-SysOrgDocumentCategory -Path $Path -Name $name -Metadata $meta -Config $Config -AppRoot $AppRoot
                if($lex -and ($lex.Confidence -gt 0)){
                    $subtype = $lex.Subtype
                    # a WEAK lexicon match never dumps the file into a junk folder:
                    # below the threshold the document goes to Documents\General\<Year>
                    # (still previewed; the confidence stays honest in the plan)
                    if($lex.Confidence -lt $minConf){ $subtype = 'General' }
                    [void]$d.Signals.Add(('Lexicon: ' + $lex.Subtype + ' score=' + $lex.Matched + ' -> confidence=' + $lex.Confidence + $(if($subtype -eq 'General'){ ' -> General' })))
                }
            } catch { [void]$d.Signals.Add(('Lexicon: failed soft (' + $_.Exception.Message + ')')) }
        }
    }

    # --- stage 9: confidence ---
    $d.Category = $cat
    $d.Subtype = $subtype
    $d.RuleId = 'default'
    if($cat -eq 'Other'){
        # no extension, no magic match, no routing signal: NO confident placement -
        # below the threshold the file is left in place and reported (needs a decision)
        $d.Confidence = 0.3
    }
    elseif($cat -in @('Documents','Spreadsheets','Databases')){
        # documents: the lexicon score when one matched, otherwise the readable-document
        # baseline (still organized, into Documents\General\<Year>)
        if($lex){ $d.Confidence = [Math]::Max($lex.Confidence, 0.5); $d.RuleId = 'lexicon' }
        else { $d.Confidence = 0.5 }
    }
    else {
        if($meta){ $d.Confidence = 0.9 } else { $d.Confidence = 0.8 }
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
        $d.TakesDate = [bool]$rb.TakesDate
        if($meta){ $d.Meta = $meta }
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

# ---------------------------------------------------------------------------
# Stage 5: true type detection (v3.0 Phase 2.3). Extension first, then a
# magic-byte sniff of the first 512 bytes for missing, unknown or suspect
# extensions. Every signature maps to exactly ONE routing category (the same
# single-category rule the extension map follows since v2.1.1).
# NOTE: sniffing opens the file - callers must have already passed the cloud
# placeholder and reparse-point gates (the scanner and plan guarantee this).
# ---------------------------------------------------------------------------
$script:SysOrgSniffAlways = @('.dat','.bin','.msi','.doc','.xls','.ppt','.docx','.xlsx','.pptx',
                              '.txt','.md','.csv','.tsv','.log')
$script:SysOrgZipFamily = @('.zip','.docx','.xlsx','.pptx','.jar','.odt','.ods','.odp','.apk','.ipa')

function Get-SysOrgMagicCategory {
<#
.SYNOPSIS
    Reads at most 512 bytes and matches the built-in magic-byte signature table.
.DESCRIPTION
    Returns @{ Matched; SignatureType; Category; Offset } - $null-safe: unreadable,
    empty or shorter-than-signature files simply do not match (never throws).
    OLE compound files (D0 CF 11 E0: .msi / legacy .doc / .xls) map by EXTENSION
    family when present, so an .msi stays an installer and a .doc stays a document;
    without an extension the OLE signature maps to Documents.
.EXAMPLE
    Get-SysOrgMagicCategory -Path 'C:\x\file.bin'   # -> @{ Matched=$true; Category='Pictures'; ... }
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[AllowEmptyString()][string]$Extension)
    $ext = "$Extension".ToLowerInvariant()
    try{
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try{
            if($fs.Length -lt 4){ return [pscustomobject]@{ Matched=$false; SignatureType=''; Category=$null; Offset=0 } }
            $buf = New-Object byte[] 512
            $read = 0
            while($read -lt 512){
                $n = $fs.Read($buf, $read, 512 - $read)
                if($n -le 0){ break }
                $read += $n
            }
            if($read -lt 4){ return [pscustomobject]@{ Matched=$false; SignatureType=''; Category=$null; Offset=0 } }
            function Test-SysOrgMagicAt { param([byte[]]$Buf,[int]$Read,[byte[]]$Magic,[int]$Offset)
                if(($Offset + $Magic.Count) -gt $Read){ return $false }
                for($i=0; $i -lt $Magic.Count; $i++){ if($Buf[$Offset + $i] -ne $Magic[$i]){ return $false } }
                return $true
            }
            $ascii = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
            # signature table, checked in order
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0xFF,0xD8,0xFF)) -Offset 0){ return [pscustomobject]@{ Matched=$true; SignatureType='image/jpeg'; Category='Pictures'; Offset=0 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A)) -Offset 0){ return [pscustomobject]@{ Matched=$true; SignatureType='image/png'; Category='Pictures'; Offset=0 } }
            if($ascii.StartsWith('GIF8')){ return [pscustomobject]@{ Matched=$true; SignatureType='image/gif'; Category='Pictures'; Offset=0 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x42,0x4D)) -Offset 0){ return [pscustomobject]@{ Matched=$true; SignatureType='image/bmp'; Category='Pictures'; Offset=0 } }
            if((Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x49,0x49,0x2A,0x00)) -Offset 0) -or
               (Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x4D,0x4D,0x00,0x2A)) -Offset 0)){ return [pscustomobject]@{ Matched=$true; SignatureType='image/tiff'; Category='Pictures'; Offset=0 } }
            if($ascii.StartsWith('%PDF')){ return [pscustomobject]@{ Matched=$true; SignatureType='application/pdf'; Category='Documents'; Offset=0 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x50,0x4B,0x03,0x04)) -Offset 0){
                # zip family: the extension decides between Archives and Office containers
                $cat = 'Archives'
                if($script:SysOrgZipFamily -contains $ext -and $ext -ne '.zip'){ $cat = 'Documents' }
                if($ext -eq '.jar'){ $cat = 'Code' }
                if($ext -eq '.apk'){ $cat = 'Installers' }
                return [pscustomobject]@{ Matched=$true; SignatureType='application/zip'; Category=$cat; Offset=0 }
            }
            if($ascii.StartsWith('Rar!')){ return [pscustomobject]@{ Matched=$true; SignatureType='application/x-rar'; Category='Archives'; Offset=0 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x37,0x7A,0xAF,0xBC,0x27,0x1A)) -Offset 0){ return [pscustomobject]@{ Matched=$true; SignatureType='application/x-7z'; Category='Archives'; Offset=0 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x1F,0x8B)) -Offset 0){ return [pscustomobject]@{ Matched=$true; SignatureType='application/gzip'; Category='Archives'; Offset=0 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0xD0,0xCF,0x11,0xE0)) -Offset 0){
                # OLE compound document: .msi installers, legacy .doc/.xls/.ppt documents
                $cat = 'Documents'
                if($ext -eq '.msi'){ $cat = 'Installers' }
                elseif($ext -eq '.xls'){ $cat = 'Spreadsheets' }
                elseif($ext -eq '.ppt'){ $cat = 'Documents' }
                return [pscustomobject]@{ Matched=$true; SignatureType='application/x-ole'; Category=$cat; Offset=0 }
            }
            if(($read -ge 12) -and ($ascii.Substring(4,4) -eq 'ftyp')){ return [pscustomobject]@{ Matched=$true; SignatureType='video/mp4'; Category='Videos'; Offset=4 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x1A,0x45,0xDF,0xA3)) -Offset 0){ return [pscustomobject]@{ Matched=$true; SignatureType='video/x-matroska'; Category='Videos'; Offset=0 } }
            if($ascii.StartsWith('RIFF') -and ($read -ge 12) -and ($ascii.Substring(8,4) -eq 'WAVE')){ return [pscustomobject]@{ Matched=$true; SignatureType='audio/wav'; Category='Audio'; Offset=0 } }
            if($ascii.StartsWith('fLaC')){ return [pscustomobject]@{ Matched=$true; SignatureType='audio/flac'; Category='Audio'; Offset=0 } }
            if($ascii.StartsWith('OggS')){ return [pscustomobject]@{ Matched=$true; SignatureType='audio/ogg'; Category='Audio'; Offset=0 } }
            if($ascii.StartsWith('ID3')){ return [pscustomobject]@{ Matched=$true; SignatureType='audio/mpeg-id3'; Category='Audio'; Offset=0 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0xFF,0xFB)) -Offset 0){ return [pscustomobject]@{ Matched=$true; SignatureType='audio/mpeg'; Category='Audio'; Offset=0 } }
            if(Test-SysOrgMagicAt -Buf $buf -Read $read -Magic ([byte[]]@(0x4D,0x5A)) -Offset 0){ return [pscustomobject]@{ Matched=$true; SignatureType='application/x-executable'; Category='Installers'; Offset=0 } }
            if($ascii.StartsWith('SQLite format 3')){ return [pscustomobject]@{ Matched=$true; SignatureType='application/x-sqlite3'; Category='Databases'; Offset=0 } }
            return [pscustomobject]@{ Matched=$false; SignatureType=''; Category=$null; Offset=0 }
        } finally { $fs.Dispose() }
    } catch { return [pscustomobject]@{ Matched=$false; SignatureType=''; Category=$null; Offset=0 } }
}

function Get-SysOrgTrueType {
<#
.SYNOPSIS
    Stage 5: resolves the true type of a file - extension first, magic bytes second.
.DESCRIPTION
    Sniffs (max 512 bytes) when the extension is missing, when the extension routes
    to 'Other', or when the extension is in the always-sniff set (legacy Office and
    container formats whose extensions are frequently wrong). A matched signature
    that disagrees with the extension's category CORRECTS the category and reports
    the mismatch; a matching extension is confirmed silently. Nothing is ever
    renamed on disk - the correction only affects where the file is planned to go.
.EXAMPLE
    Get-SysOrgTrueType -Path 'C:\dl\photo.txt' -Extension '.txt' -Category 'Documents'   # PNG content -> Pictures
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[AllowEmptyString()][string]$Extension,[AllowEmptyString()][string]$Category)
    $ext = "$Extension".ToLowerInvariant()
    $cat = "$Category"
    $sniff = $false
    if([string]::IsNullOrWhiteSpace($ext)){ $sniff = $true }
    elseif($cat -eq 'Other'){ $sniff = $true }
    elseif($script:SysOrgSniffAlways -contains $ext){ $sniff = $true }
    if(-not $sniff){ return $null }
    $m = Get-SysOrgMagicCategory -Path $Path -Extension $ext
    if(-not ($m -and $m.Matched)){ return $null }
    $corrected = ($m.Category -ne $Category)
    return [pscustomobject]@{
        Matched=$true; SignatureType=$m.SignatureType; Category=$m.Category
        Corrected=$corrected; ExtensionCategory=$Category
    }
}

# ---------------------------------------------------------------------------
# Stage 8: document category scoring against Rules\Lexicon.psd1 (v3.0 Phase 2.6).
# The lexicon is extensible (multilingual tokens welcome). Missing file -> built-in
# defaults; a file that exists but cannot be parsed FAILS CLOSED (a broken lexicon
# is a broken rule set, like a broken config). Score becomes confidence:
#   matched / (matched + Confidence.Divider), with filename tokens at 1.2x,
#   metadata tokens at 1.0x and content tokens at 0.6x weight.
# ---------------------------------------------------------------------------

function Get-SysOrgLexicon {
<#
.SYNOPSIS
    Loads and validates the lexicon (config Rules.LexiconPath, or <AppRoot>\Rules\Lexicon.psd1).
.EXAMPLE
    Get-SysOrgLexicon -Config $cfg -AppRoot 'C:\SysOrg'
#>
    [CmdletBinding()]
    param($Config,[string]$AppRoot)
    $path = "$(Get-SysOrgSetting $Config 'Rules.LexiconPath' '')"
    if([string]::IsNullOrWhiteSpace($path) -and $AppRoot){ $path = (Join-Path $AppRoot 'Rules\Lexicon.psd1') }
    if([string]::IsNullOrWhiteSpace($path) -or (-not (Test-Path -LiteralPath $path))){
        # built-in minimal fallback so a missing file never breaks classification
        return @{
            Multiplier = @{ Filename = 1.2; Metadata = 1.0; Content = 0.6 }
            Confidence = @{ Divider = 1.5 }
            Entries = @(
                @{ Subtype='Finance\Invoices';  Filename=@('invoice'); Content=@('invoice','amount due','payment due') }
                @{ Subtype='Finance\Receipts';  Filename=@('receipt'); Content=@('receipt','received from','mpesa') }
                @{ Subtype='Finance\Statements';Filename=@('statement'); Content=@('statement of account','closing balance') }
                @{ Subtype='Finance\Tax';       Filename=@('tax','paye','kra'); Content=@('kra','paye','vat','tax return','itax') }
                @{ Subtype='Legal-Identity';    Filename=@('contract','certificate','passport'); Content=@('this agreement','certificate of','passport number') }
                @{ Subtype='Education';         Filename=@('thesis','syllabus','assignment'); Content=@('university','course outline','examination') }
                @{ Subtype='Work';              Filename=@('proposal','minutes','memo'); Content=@('meeting minutes','action items','deliverables') }
                @{ Subtype='Manuals';           Filename=@('manual','handbook','user guide'); Content=@('user manual','troubleshooting','quick start') }
                @{ Subtype='Books';             Filename=@('book','novel','textbook'); Content=@('chapter','isbn','published by') }
            )
        }
    }
    $loaded = $null
    try { $loaded = Import-PowerShellDataFile -LiteralPath $path -ErrorAction Stop }
    catch { throw ("Lexicon file '{0}' could not be parsed: {1} (fix the file or remove it to use the built-in defaults)." -f $path, $_.Exception.Message) }
    if($loaded -isnot [hashtable] -or (-not $loaded.ContainsKey('Entries'))){
        throw ("Lexicon file '{0}' must be a hashtable with an Entries list." -f $path)
    }
    return $loaded
}

function Get-SysOrgTokenMatches {
<#
.SYNOPSIS
    Counts lexicon token hits in one text source (case-insensitive, word-ish match).
.DESCRIPTION
    Multi-word tokens match as substrings; single-word tokens match on word
    boundaries so 'tax' does not match 'taxi'. Returns the number of DISTINCT
    tokens found (each token counts once per source). The compiled regex per token
    is cached in the module scope (v3.0 Phase 3.8 hotspot: building ~60 regexes per
    file dominated plan-build on large corpora).
.EXAMPLE
    Get-SysOrgTokenMatches -Text 'Invoice number 42, payment due' -Tokens @('invoice','payment due')   # -> 2
#>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text,[AllowEmptyCollection()][string[]]$Tokens)
    if([string]::IsNullOrWhiteSpace("$Text")){ return 0 }
    $lower = "$Text".ToLowerInvariant()
    $hits = 0
    foreach($t in $Tokens){
        $tok = "$t".ToLowerInvariant().Trim()
        if([string]::IsNullOrWhiteSpace($tok)){ continue }
        if($tok.Contains(' ')){
            if($lower.Contains($tok)){ $hits++ }
        } else {
            $rx = $null
            if($script:SysOrgTokenRegexCache.ContainsKey($tok)){ $rx = $script:SysOrgTokenRegexCache[$tok] }
            else {
                try { $rx = [regex]::new(('(^|[^a-z0-9])' + [regex]::Escape($tok) + '([^a-z0-9]|$)'), 'IgnoreCase') } catch { $rx = $null }
                $script:SysOrgTokenRegexCache[$tok] = $rx
            }
            if($rx -and $rx.IsMatch("$lower")){ $hits++ }
        }
    }
    return $hits
}

function Get-SysOrgDocumentCategory {
<#
.SYNOPSIS
    Stage 8: scores a document against the lexicon and returns category + confidence.
.DESCRIPTION
    Combines stem tokens (1.2x), metadata title/creator tokens (1.0x) and the 2 KB
    text snippet tokens (0.6x) per lexicon entry; the best entry wins deterministically
    (ties break by list order). Returns @{ Subtype; Matched; Confidence } or $null when
    nothing matched. Fail soft: unreadable content simply contributes no tokens.
.EXAMPLE
    Get-SysOrgDocumentCategory -Path 'C:\x\tax return.pdf' -Name 'tax return.pdf' -Metadata $m -Config $cfg
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name,
          [hashtable]$Metadata,$Lexicon,$Config,[string]$AppRoot)
    try{
        if(-not $Lexicon){ $Lexicon = Get-SysOrgLexicon -Config $Config -AppRoot $AppRoot }
        $mult = @{ Filename = 1.2; Metadata = 1.0; Content = 0.6 }
        if($Lexicon -is [hashtable] -and $Lexicon.ContainsKey('Multiplier') -and ($Lexicon['Multiplier'] -is [hashtable])){
            foreach($k in @('Filename','Metadata','Content')){ if($Lexicon['Multiplier'].ContainsKey($k)){ $mult[$k] = [double]$Lexicon['Multiplier'][$k] } }
        }
        $divider = 1.5
        if($Lexicon -is [hashtable] -and $Lexicon.ContainsKey('Confidence') -and ($Lexicon['Confidence'] -is [hashtable]) -and $Lexicon['Confidence'].ContainsKey('Divider')){
            $divider = [double]$Lexicon['Confidence']['Divider']
        }
        $stem = ([System.IO.Path]::GetFileNameWithoutExtension($Name))
        $snippet = ''
        if($Metadata -and $Metadata.ContainsKey('Snippet')){ $snippet = "$($Metadata['Snippet'])" }
        else {
            try{
                $t = Get-SysOrgTextSnippet -Path $Path
                if($t){ $snippet = "$($t['Snippet'])" }
            } catch { $snippet = '' }
        }
        $metaText = ''
        if($Metadata){
            foreach($k in @('Title','Creator','Author')){
                if($Metadata.ContainsKey($k)){ $metaText += ' ' + "$($Metadata[$k])" }
            }
        }
        $best = $null; $bestMatched = -1.0
        foreach($entry in @($Lexicon['Entries'])){
            if(-not ($entry -is [hashtable]) -or (-not $entry.ContainsKey('Subtype'))){ continue }
            $m = 0.0
            $m += (Get-SysOrgTokenMatches -Text $stem -Tokens ([string[]]@($entry['Filename']))) * $mult.Filename
            $m += (Get-SysOrgTokenMatches -Text $metaText -Tokens ([string[]](@($entry['Filename']) + @($entry['Content'])))) * $mult.Metadata
            $m += (Get-SysOrgTokenMatches -Text $snippet -Tokens ([string[]]@($entry['Content']))) * $mult.Content
            if($m -gt $bestMatched){
                $bestMatched = $m
                $best = "$($entry['Subtype'])"
            }
        }
        if(($null -eq $best) -or ($bestMatched -le 0)){ return $null }
        $conf = $bestMatched / ($bestMatched + $divider)
        if($conf -gt 0.99){ $conf = 0.99 }
        return [pscustomobject]@{ Subtype=$best; Matched=[Math]::Round($bestMatched,2); Confidence=[Math]::Round($conf,3) }
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Stage 8b: event clustering for photos/videos (v3.0 Phase 2.7). Media files
# are grouped by GPS cell (when EXIF GPS exists) and by capture-time gaps; a
# cluster of at least Events.MinFiles becomes Pictures\Events\<date range>.
# Deterministic: records are sorted by (cell, time, path) before clustering.
# ---------------------------------------------------------------------------

function Get-SysOrgEventClusters {
<#
.SYNOPSIS
    Clusters media records into photo/video events by time gaps and GPS cells.
.DESCRIPTION
    Input records need Path, Date and optionally GpsLat/GpsLon. Records with GPS
    are clustered within their cell (3 decimals, ~100 m) by time gap; records
    without GPS are clustered purely by time gap (default Events.GapHours = 8).
    A cluster with at least Events.MinFiles (default 15) members becomes an event
    whose id is 'Events\<start> to <end>' (same-year ranges shorten the end to
    MM-DD). Smaller clusters stay in their Camera\<date> leaves. Deterministic.
.EXAMPLE
    $map = Get-SysOrgEventClusters -Records $mediaRecords -Config $cfg
    $map['C:\pics\IMG_0001.jpg']   # -> 'Events\2024-06-01 to 06-03' (or $null)
#>
    [CmdletBinding()]
    param([AllowEmptyCollection()]$Records,$Config)
    $gapHours = [double](Get-SysOrgSetting $Config 'Events.GapHours' 8)
    $minFiles = [int](Get-SysOrgSetting $Config 'Events.MinFiles' 15)
    $map = @{}
    $clusters = New-Object System.Collections.Generic.List[object]
    if(@($Records).Count -lt $minFiles){ return [pscustomobject]@{ Map=$map; Clusters=$clusters.ToArray() } }

    # sort deterministically: GPS cell (empty last), then time, then path
    $ordered = @($Records | Sort-Object -Property `
        @{e={ if($_.PSObject.Properties['GpsLat'] -and $null -ne $_.GpsLat){ ('{0:F3},{1:F3}' -f $_.GpsLat, $_.GpsLon) } else { '~~~' } }}, `
        @{e={ $_.Date.Ticks }}, @{e={ "$($_.Path)" }})

    $currentCell = $null
    $current = New-Object System.Collections.Generic.List[object]
    foreach($r in $ordered){
        $cell = ''
        if($r.PSObject.Properties['GpsLat'] -and ($null -ne $r.GpsLat)){ $cell = ('{0:F3},{1:F3}' -f $r.GpsLat, $r.GpsLon) }
        $newCluster = $false
        if($null -ne $currentCell -and $cell -ne $currentCell){ $newCluster = $true }
        elseif($current.Count -gt 0){
            $last = $current[$current.Count - 1]
            if((([datetime]$r.Date) - [datetime]$last.Date).TotalHours -gt $gapHours){ $newCluster = $true }
        }
        if($newCluster){
            [void]$clusters.Add([pscustomobject]@{ Cell=$currentCell; Members=$current.ToArray() })
            $current = New-Object System.Collections.Generic.List[object]
        }
        $currentCell = $cell
        [void]$current.Add($r)
    }
    if($current.Count -gt 0){ [void]$clusters.Add([pscustomobject]@{ Cell=$currentCell; Members=$current.ToArray() }) }

    foreach($c in $clusters){
        $members = @($c.Members)
        if($members.Count -lt $minFiles){ continue }
        $start = [datetime]$members[0].Date
        $end = [datetime]$members[$members.Count - 1].Date
        $endLabel = if($start.Year -eq $end.Year){ $end.ToString('MM-dd') } else { $end.ToString('yyyy-MM-dd') }
        # the Findable tree hosts events under Pictures\Events (photos and videos alike)
        $eventId = ('Pictures\Events\{0} to {1}' -f $start.ToString('yyyy-MM-dd'), $endLabel)
        foreach($m in $members){ $map["$($m.Path)"] = $eventId }
    }
    return [pscustomobject]@{ Map=$map; Clusters=$clusters.ToArray() }
}

# ---------------------------------------------------------------------------
# Stage 8c: near-duplicate IMAGE detection (v3.0 Phase 2.8) - REPORT ONLY.
# A small 64-bit dHash (9x8 grayscale gradient) per image, clustered by Hamming
# distance. Uses System.Drawing, which exists on Windows; on other hosts the
# function degrades to an empty result with a note (never throws). Near
# duplicates are listed in the plan preview - they are NEVER moved.
# ---------------------------------------------------------------------------

function Get-SysOrgImageDHash {
<#
.SYNOPSIS
    64-bit difference hash (dHash) of an image, as a 64-character bit string.
.DESCRIPTION
    Downscales to 9x8 grayscale and compares horizontally adjacent pixels.
    Returns $null when imaging is unavailable (non-Windows hosts) or the file
    cannot be read - never throws.
.EXAMPLE
    Get-SysOrgImageDHash -Path 'C:\pics\a.jpg'   # -> '111010...' (64 chars)
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try{
        if(-not ('SysOrg.ImagingProbe' -as [type])){
            try{
                Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            } catch {
                $script:SysOrgImagingAvailable = $false
                return $null
            }
            $script:SysOrgImagingAvailable = $true
        }
        if($script:SysOrgImagingAvailable -eq $false){ return $null }
        $bmp = $null
        try{
            $bmp = New-Object System.Drawing.Bitmap($Path)
        } catch { return $null }
        try{
            $bits = New-Object System.Text.StringBuilder
            for($y = 0; $y -lt 8; $y++){
                $prev = $null
                for($x = 0; $x -lt 9; $x++){
                    $sx = [int]($x * $bmp.Width / 9)
                    $sy = [int]($y * $bmp.Height / 8)
                    $c = $bmp.GetPixel($sx, $sy)
                    $gray = [int](0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B)
                    if($null -ne $prev){ [void]$bits.Append($(if($gray -gt $prev){ '1' } else { '0' })) }
                    $prev = $gray
                }
            }
            return $bits.ToString()
        } finally { $bmp.Dispose() }
    } catch {
        $script:SysOrgImagingAvailable = $false
        return $null
    }
}

function Get-SysOrgHammingDistance {
<#
.SYNOPSIS
    Hamming distance between two equal-length bit strings.
.EXAMPLE
    Get-SysOrgHammingDistance -A '1010' -B '1000'   # -> 1
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$A,[Parameter(Mandatory)][string]$B)
    if("$A".Length -ne "$B".Length){ return 64 }
    $d = 0
    for($i=0; $i -lt "$A".Length; $i++){ if("$A"[$i] -ne "$B"[$i]){ $d++ } }
    return $d
}

function Get-SysOrgImageNearDuplicates {
<#
.SYNOPSIS
    Groups near-duplicate images by dHash Hamming distance (REPORT ONLY).
.DESCRIPTION
    Deterministic: hashes are computed in natural path order and clusters grow
    greedily against the first member. Groups with at least 2 members are returned
    with their wasted bytes. On hosts without System.Drawing the result is empty
    with a Note (near-duplicate detection is a Windows-hosted feature).
    Nothing is ever moved or deleted based on this result.
.EXAMPLE
    $groups = Get-SysOrgImageNearDuplicates -ImagePaths $paths -Config $cfg
#>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$ImagePaths,$Config,[hashtable]$Sizes)
    $maxDist = [int](Get-SysOrgSetting $Config 'NearDuplicates.MaxHammingDistance' 8)
    $groups = New-Object System.Collections.Generic.List[object]
    $note = ''
    $paths = @($ImagePaths | Sort-Object)
    if($paths.Count -lt 2){ return [pscustomobject]@{ Groups=$groups.ToArray(); Note='fewer than 2 images' } }
    $hashes = @{}
    foreach($p in $paths){
        $h = Get-SysOrgImageDHash -Path $p
        if($h){ $hashes[$p] = $h }
    }
    if($hashes.Count -lt 2){
        return [pscustomobject]@{ Groups=$groups.ToArray(); Note='image hashing unavailable on this host (System.Drawing) or no readable images' }
    }
    $assigned = @{}
    foreach($p in ($hashes.Keys | Sort-Object)){
        if($assigned.ContainsKey($p)){ continue }
        $members = New-Object System.Collections.Generic.List[string]
        [void]$members.Add($p)
        $assigned[$p] = $true
        foreach($q in ($hashes.Keys | Sort-Object)){
            if($assigned.ContainsKey($q)){ continue }
            if((Get-SysOrgHammingDistance -A $hashes[$p] -B $hashes[$q]) -le $maxDist){
                [void]$members.Add($q)
                $assigned[$q] = $true
            }
        }
        if($members.Count -ge 2){
            $arr = @($members.ToArray())
            $bytes = [long]0
            if($Sizes){ foreach($m in $arr){ if($Sizes.ContainsKey($m)){ $bytes += [long]$Sizes[$m] } } }
            [void]$groups.Add([pscustomobject]@{ Paths=$arr; Bytes=$bytes })
        }
    }
    return [pscustomobject]@{ Groups=$groups.ToArray(); Note=$note }
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
