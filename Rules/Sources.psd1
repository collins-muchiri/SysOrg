# Rules/Sources.psd1 - the download provenance bucket map (v3.0.1 A4).
#
# Maps download hosts to SOURCE bucket names for the Downloads branch and the
# catalog's Source field. This file is EXTENSIBLE: add hosts (exact host names),
# second-level public suffixes (registrable-domain awareness) or filename
# patterns here - they MERGE over the built-ins below, so you can add entries
# but never lose the shipped ones. A file that exists but cannot be parsed is a
# broken rule set: SysOrg fails closed on startup, like a broken config.
#
# Bucket names flow through Get-SysOrgSafeFolderName before they become folders,
# so reserved device names ('nul.com' -> _Nul) can never leak into the tree.
# AI/chat sources are included per the v3.0.1 source-bucket spec.

@{
    Version = '1.1'

    # Exact host -> bucket. Longest match wins order is irrelevant: use the exact
    # host as it appears in the Zone.Identifier URL.
    Hosts = @{
        # AI and chat assistants (v3.0.1 A4)
        'z.ai'                    = 'Z-AI'
        'chat.z.ai'               = 'Z-AI'
        'meta.ai'                 = 'Meta-AI'
        'claude.ai'               = 'Claude'
        'chatgpt.com'             = 'OpenAI'
        'openai.com'              = 'OpenAI'
        'gemini.google.com'       = 'Gemini'
        'gemini.googleusercontent.com' = 'Gemini'

        # code hosting
        'github.com'              = 'GitHub'
        'raw.githubusercontent.com' = 'GitHub'
        'objects.githubusercontent.com' = 'GitHub'
        'codeload.github.com'     = 'GitHub'
        'gist.github.com'         = 'GitHub'

        # messaging
        'whatsapp.com'            = 'WhatsApp'
        'web.whatsapp.com'        = 'WhatsApp'
        'cdn.whatsapp.net'        = 'WhatsApp'
        'telegram.org'            = 'Telegram'
        't.me'                    = 'Telegram'
        'cdn-telegram.org'        = 'Telegram'
        'signal.org'              = 'Signal'
        'updates.signal.org'      = 'Signal'
        'discord.com'             = 'Discord'
        'discordapp.com'          = 'Discord'
        'cdn.discordapp.com'      = 'Discord'

        # cloud and collaboration
        'dropbox.com'             = 'Dropbox'
        'dl.dropboxusercontent.com' = 'Dropbox'
        'drive.google.com'        = 'GoogleDrive'
        'docs.google.com'         = 'GoogleDrive'
        'onedrive.live.com'       = 'OneDrive'
        '1drv.ms'                 = 'OneDrive'
        'live.com'                = 'Microsoft'
        'sharepoint.com'          = 'Microsoft'
        'office.com'              = 'Microsoft'
        'microsoft.com'           = 'Microsoft'
        'slack.com'               = 'Slack'
        'files.slack.com'         = 'Slack'

        # media, communities, games, archives
        'reddit.com'              = 'Reddit'
        'i.redd.it'              = 'Reddit'
        'steamcontent.com'        = 'Steam'
        'steampowered.com'        = 'Steam'
        'zoom.us'                 = 'Zoom'
        'archive.org'             = 'InternetArchive'
    }

    # Public-suffix-aware second-level suffixes: for a host under one of these,
    # the registrable label sits BEFORE the two-part suffix
    # (www.kra.go.ke -> Kra, not Go).
    SecondLevelSuffixes = @{
        'co.uk'=$true;'org.uk'=$true;'ac.uk'=$true;'gov.uk'=$true;'me.uk'=$true;'net.uk'=$true;'ltd.uk'=$true;'plc.uk'=$true
        'com.au'=$true;'net.au'=$true;'org.au'=$true;'edu.au'=$true;'gov.au'=$true
        'co.nz'=$true;'net.nz'=$true;'org.nz'=$true
        'co.za'=$true;'org.za'=$true;'ac.za'=$true;'gov.za'=$true
        'co.ke'=$true;'or.ke'=$true;'go.ke'=$true;'ac.ke'=$true;'ne.ke'=$true;'sc.ke'=$true;'info.ke'=$true
        'com.ng'=$true;'org.ng'=$true;'gov.ng'=$true;'edu.ng'=$true;'net.ng'=$true
        'co.in'=$true;'net.in'=$true;'org.in'=$true;'gov.in'=$true;'ac.in'=$true;'firm.in'=$true
        'com.br'=$true;'net.br'=$true;'org.br'=$true;'gov.br'=$true
        'com.mx'=$true;'org.mx'=$true;'net.mx'=$true
        'com.tr'=$true;'net.tr'=$true;'org.tr'=$true
        'co.kr'=$true;'ne.kr'=$true;'or.kr'=$true
        'co.jp'=$true;'ne.jp'=$true;'or.jp'=$true;'ac.jp'=$true;'go.jp'=$true
        'com.sg'=$true;'net.sg'=$true;'org.sg'=$true;'gov.sg'=$true
        'com.cn'=$true;'net.cn'=$true;'org.cn'=$true;'gov.cn'=$true
        'com.ar'=$true;'net.ar'=$true;'org.ar'=$true
        'com.hk'=$true;'org.hk'=$true;'net.hk'=$true
        'co.id'=$true;'or.id'=$true;'web.id'=$true
        'com.my'=$true;'org.my'=$true;'net.my'=$true
        'com.ph'=$true;'org.ph'=$true;'net.ph'=$true
        'com.tw'=$true;'org.tw'=$true;'net.tw'=$true
        'com.vn'=$true;'net.vn'=$true;'org.vn'=$true
        'com.pk'=$true;'net.pk'=$true;'org.pk'=$true
        'com.eg'=$true;'net.eg'=$true;'org.eg'=$true
        'co.th'=$true;'or.th'=$true;'ac.th'=$true
        'com.ua'=$true;'net.ua'=$true;'org.ua'=$true
        'co.il'=$true;'org.il'=$true;'net.il'=$true;'ac.il'=$true
        'com.co'=$true;'net.co'=$true;'org.co'=$true
    }

    # Filename fallback patterns (evaluated in order; first match wins).
    FileNamePatterns = @(
        @{ Pattern = '^whatsapp';   Bucket = 'WhatsApp' }
        @{ Pattern = 'wa\d{4}';     Bucket = 'WhatsApp' }
        @{ Pattern = '^telegram';   Bucket = 'Telegram' }
        @{ Pattern = '^signal-';    Bucket = 'Signal' }
        @{ Pattern = '^screenshot'; Bucket = 'Screenshots' }
    )
}
