# ---------------------------------------------------------------------------
# Rollback snapshots (restore strategy + ipset + hosts in one shot)
# ---------------------------------------------------------------------------

function Save-RollbackSnapshot {
    <#
        Saves the CURRENT ipset list, hosts file and installed strategy into
        $LogDir\rollback-<ts>\ and points config.json at the snapshot.
        Best effort - never throws; failures are logged and ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('strategy', 'ipset', 'hosts')][string]$Reason,
        [string]$Strategy = $null,
        [string]$HostsPath = $null,
        [string]$LogDir = $script:LogDir,
        [string]$IpsetFile = $script:IpsetFile,
        [string]$ConfigPath = $script:ConfigPath,
        [int]$Keep = 3
    )
    try {
        if (-not $HostsPath) { try { $HostsPath = Get-HostsFilePath } catch { $HostsPath = $null } }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $folder = Join-Path $LogDir ("rollback-{0}" -f $stamp)
        New-Item -ItemType Directory -Path $folder -Force | Out-Null

        $ipsetSaved = $false
        if (Test-Path -LiteralPath $IpsetFile) {
            Copy-Item -LiteralPath $IpsetFile -Destination (Join-Path $folder 'ipset-all.txt') -Force
            $ipsetSaved = $true
        }
        $hostsSaved = $false
        if ($HostsPath -and (Test-Path -LiteralPath $HostsPath)) {
            Copy-Item -LiteralPath $HostsPath -Destination (Join-Path $folder 'hosts') -Force
            $hostsSaved = $true
        }
        if (-not $Strategy) { try { $Strategy = (Get-ZapretServiceInfo).Strategy } catch { } }

        $meta = [pscustomobject]@{
            reason   = $Reason
            time     = (Get-Date -Format 's')
            strategy = $Strategy
            folder   = $folder
            ipset    = $ipsetSaved
            hosts    = $hostsSaved
        }
        [void](Update-Config -Changes @{ rollback = $meta } -Path $ConfigPath)

        try {
            $all = @(Get-ChildItem -LiteralPath $LogDir -Directory -Filter 'rollback-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            foreach ($old in @($all | Select-Object -Skip $Keep)) {
                Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        Write-Log "Rollback snapshot saved ($Reason): $folder"
        return $meta
    } catch {
        Write-Log "Rollback snapshot failed ($($_.Exception.Message))" 'WARN'
        return $null
    }
}

function Test-RollbackSnapshotPath {
    # Pure: true when $Folder is a rollback-* direct child of $LogDir.
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][string]$LogDir
    )
    try {
        $logFull  = [IO.Path]::GetFullPath($LogDir).TrimEnd('\', '/')
        $snapFull = [IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
        # Direct child only: the parent of the snapshot folder must be $LogDir itself
        $parent = Split-Path -Parent $snapFull
        if (-not [string]::Equals($parent, $logFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        return ((Split-Path -Leaf $snapFull).StartsWith('rollback-', [StringComparison]::OrdinalIgnoreCase))
    } catch {
        return $false
    }
}

function Restore-RollbackSnapshot {
    # Restores the snapshot recorded in config.json (ipset + hosts + service strategy).
    [CmdletBinding()]
    param(
        [string]$LogDir = $script:LogDir,
        [string]$IpsetFile = $script:IpsetFile,
        [string]$HostsPath = $null,
        [string]$ConfigPath = $script:ConfigPath,
        [bool]$ReinstallService = $true
    )
    $cfg = Get-Config -Path $ConfigPath
    $rb = $cfg.rollback
    if ($null -eq $rb -or -not $rb.folder) {
        Write-Info2 'Откатывать нечего: в config.json нет сохранённого снимка.'
        return $false
    }
    if (-not (Test-Path -LiteralPath $rb.folder)) {
        Write-Warn2 ("Папка снимка не найдена: {0}. Очищаю запись в config.json." -f $rb.folder)
        [void](Update-Config -Changes @{ rollback = $null } -Path $ConfigPath)
        return $false
    }
    # Containment: a snapshot may only be restored from our own logs\\rollback-* directory.
    # Otherwise a tampered config.json could point the restore at an attacker-controlled
    # folder and overwrite the system hosts file / ipset list with it.
    if (-not (Test-RollbackSnapshotPath -Folder $rb.folder -LogDir $LogDir)) {
        Write-Warn2 'Папка снимка находится вне logs\\rollback-* (похоже на подменённый config.json). Откат отменён.'
        [void](Update-Config -Changes @{ rollback = $null } -Path $ConfigPath)
        return $false
    }
    if (-not $HostsPath) { try { $HostsPath = Get-HostsFilePath } catch { $HostsPath = $null } }

    # Safety net: back up the CURRENT state before overwriting anything
    try {
        $safety = Join-Path $LogDir ("rollback-{0}-before-rollback" -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
        New-Item -ItemType Directory -Path $safety -Force | Out-Null
        if (Test-Path -LiteralPath $IpsetFile) { Copy-Item -LiteralPath $IpsetFile -Destination (Join-Path $safety 'ipset-all.txt') -Force }
        if ($HostsPath -and (Test-Path -LiteralPath $HostsPath)) { Copy-Item -LiteralPath $HostsPath -Destination (Join-Path $safety 'hosts') -Force }
        Write-Info2 ("Текущее состояние сохранено в {0}" -f $safety)
    } catch { }

    $restored = @()
    $snapIpset = Join-Path $rb.folder 'ipset-all.txt'
    if ($rb.ipset -and (Test-Path -LiteralPath $snapIpset)) {
        Copy-Item -LiteralPath $snapIpset -Destination $IpsetFile -Force
        $restored += 'ipset-all.txt'
    }
    $snapHosts = Join-Path $rb.folder 'hosts'
    if ($rb.hosts -and $HostsPath -and (Test-Path -LiteralPath $snapHosts)) {
        Copy-Item -LiteralPath $snapHosts -Destination $HostsPath -Force
        $restored += 'hosts'
    }
    if ($ReinstallService -and $rb.strategy -and (Get-Strategy $rb.strategy)) {
        if ($script:OnWindows) {
            try {
                Install-ZapretService -StrategyId $rb.strategy -NoSnapshot | Out-Null
                $restored += ("служба (strategy: {0})" -f $rb.strategy)
            } catch {
                Write-Warn2 ("Службу переустановить не удалось: {0}" -f $_.Exception.Message)
            }
        } else {
            Write-Info2 'Служба не переустанавливалась (не Windows).'
        }
    }
    [void](Update-Config -Changes @{ rollback = $null } -Path $ConfigPath)
    if ($restored.Count -gt 0) {
        Write-Ok ("Откат выполнен: {0}" -f ($restored -join ', '))
    } else {
        Write-Warn2 'В снимке не оказалось файлов для восстановления (но стратегия могла быть сохранена).'
    }
    Write-Info2 ("Снимок: причина '{0}', создан {1}" -f $rb.reason, $rb.time)
    Write-Log "Rollback restored: ipset=$($rb.ipset) hosts=$($rb.hosts) strategy=$($rb.strategy)"
    return $true
}

# ---------------------------------------------------------------------------
# Restart prompt after settings that require a service bounce
# ---------------------------------------------------------------------------

function Invoke-ZapretServiceRestartPrompt {
    # Called after Game Filter / IPSet / fakes changes. Offers an immediate
    # service restart when zapret is installed (the #1 newbie mistake is
    # changing a filter and wondering why nothing happened).
    [CmdletBinding()]
    param([string]$Reason = 'Настройки изменены')
    if (-not $script:OnWindows) { return $false }
    $info = $null
    try { $info = Get-ZapretServiceInfo } catch { return $false }
    if (-not $info.Installed) { return $false }
    # surface known conflicts first - they are the usual reason the service
    # "turns off and never comes back" after changing settings or fakes
    $conflictItems = @()
    try { $conflictItems = @((Get-ZapretConflictReport).Items) } catch { }
    if ($conflictItems.Count -gt 0) {
        Write-Warn2 (Get-UiText -Russian ('Возможные конфликты: {0}' -f ($conflictItems -join '; ')) -English ('Possible conflicts: {0}' -f ($conflictItems -join '; ')))
    }
    $verb = if ($info.WinwsRunning) { 'перезапустить службу zapret' } else { 'запустить службу zapret' }
    $answer = $null
    if (Get-ZapretNonInteractive) {
        # the GUI confirms before calling; treat the prompt as accepted
        $answer = 'y'
    } else {
        try { $answer = Read-Host (Get-UiText -Russian ("  {0}: {1} сейчас? [д/н]" -f $Reason, $(if ($verb -eq 'restart') { 'перезапустить службу' } else { 'установить изменения' })) -English ("  {0}: {1} now? [y/N]" -f $Reason, ($verb.Substring(0,1).ToUpper() + $verb.Substring(1)))) } catch { return $false }
    }
    if (-not [string]::IsNullOrWhiteSpace($answer) -and ($answer.Trim() -notmatch '^(y|yes|д|да)$')) {
        Write-Info2 'Не перезапущено. Изменения вступят в силу после перезапуска службы.'
        return $false
    }
    & (Get-WindowsSystemToolPath -Name 'sc.exe') stop zapret 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    & (Get-WindowsSystemToolPath -Name 'sc.exe') start zapret 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Start-Sleep -Milliseconds 1200
        $infoAfter = $null
        try { $infoAfter = Get-ZapretServiceInfo } catch { }
        if ($infoAfter -and $infoAfter.WinwsRunning) {
            Write-Ok 'Служба zapret перезапущена.'
            Write-Log 'Service restarted after settings change'
            return $true
        }
        # silent failure protection: the service is "started" but the bypass
        # process died immediately - usually a conflicting program holds WinDivert
        Write-Warn2 (Get-UiText -Russian 'Служба запущена, но winws.exe не работает - обход не активен.' -English 'The service is started, but winws.exe is not running - the bypass is inactive.')
        if ($conflictItems.Count -gt 0) {
            Write-Host (Get-UiText -Russian '  Скорее всего мешают конфликты, перечисленные выше.' -English '  The conflicts listed above are the likely cause.') -ForegroundColor Yellow
        }
        Write-Host (Get-UiText -Russian '  Уберите конфликтующие программы и выполните: zapret.ps1 run (или: sc start zapret)' -English '  Remove the conflicting software and run: zapret.ps1 run (or: sc start zapret)') -ForegroundColor Yellow
        Write-Log 'Service restarted but winws.exe is not running' 'WARN'
        return $false
    }
    Write-Warn2 'Не удалось перезапустить службу (проверьте: sc.exe query zapret).'
    if ($conflictItems.Count -gt 0) {
        Write-Host (Get-UiText -Russian ('  Возможная причина: {0}' -f ($conflictItems -join '; ')) -English ('  Likely cause: {0}' -f ($conflictItems -join '; '))) -ForegroundColor Yellow
    }
    return $false
}

# ---------------------------------------------------------------------------
# User domain lists (add/exclude sites without touching lists\ manually)
# ---------------------------------------------------------------------------

function ConvertTo-Domain {
    # Normalizes 'https://www.Example.com/watch?v=123' -> 'example.com'.
    # Returns $null when the input is not a valid DNS hostname.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$InputText)
    $t = $InputText.Trim()
    if (-not $t) { return $null }
    $t = $t -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''
    $t = $t -replace '^[^/@\s]*@', ''
    $hostPart = ($t -split '[/?#\s]', 2)[0]
    $hostPart = $hostPart -replace ':\d+$', ''
    $hostPart = $hostPart.Trim().TrimEnd('.').ToLowerInvariant()
    $hostPart = $hostPart -replace '^www\.', ''
    if ($hostPart -match '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$') { return $hostPart }
    return $null
}

function Get-RecommendedSiteCatalog {
    # Small, explicit hostname presets for the My Sites menu. These are hints,
    # not exhaustive service inventories; the user must confirm before writing.
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{
            Id = 'youtube'; NameRu = 'YouTube'; NameEn = 'YouTube'
            Domains = [string[]]@('youtube.com','youtube-nocookie.com','youtube.googleapis.com','youtubei.googleapis.com','youtubeembeddedplayer.googleapis.com','youtube-ui.l.google.com','youtu.be','googlevideo.com','ytimg.com','ytimg.l.google.com')
            NoteRu = 'Основные домены сайта, коротких ссылок и видео/CDN; перечень может быть неполным.'
            NoteEn = 'Core site, short-link, and video/CDN hostnames; the list may be incomplete.'
        }
        [pscustomobject]@{
            Id = 'discord'; NameRu = 'Discord'; NameEn = 'Discord'
            Domains = [string[]]@('discord.com','discord.gg','discord.app','discord.co','discord.design','discord.dev','discord.gift','discord.gifts','discord.media','discord.new','discord.store','discord.status','discord-activities.com','discordactivities.com','discordapp.com','discordapp.net','discordcdn.com','discordmerch.com','discordpartygames.com','discordsays.com','discordsez.com','discordstatus.com','discord-attachments-uploads-prd.storage.googleapis.com')
            NoteRu = 'Основные домены сайта и приложения; перечень может быть неполным.'
            NoteEn = 'Core website and app hostnames; the list may be incomplete.'
        }
        [pscustomobject]@{
            Id = 'whatsapp'; NameRu = 'WhatsApp'; NameEn = 'WhatsApp'
            Domains = [string[]]@('whatsapp.com','whatsapp.net','whatsapp.biz','wa.me')
            NoteRu = 'Основные веб-домены и короткие ссылки; звонки и медиа могут обращаться к дополнительным адресам.'
            NoteEn = 'Core web hostnames and short links; calls and media may use additional hosts.'
        }
        [pscustomobject]@{
            Id = 'instagram'; NameRu = 'Instagram'; NameEn = 'Instagram'
            Domains = [string[]]@('instagram.com','instagram.net','cdninstagram.com')
            NoteRu = 'Основные домены сайта и CDN; перечень может быть неполным.'
            NoteEn = 'Core website and CDN hostnames; the list may be incomplete.'
        }
        [pscustomobject]@{
            Id = 'facebook'; NameRu = 'Facebook'; NameEn = 'Facebook'
            Domains = [string[]]@('facebook.com','facebook.net','fb.com','fbcdn.net','fbsbx.com','messenger.com','m.me')
            NoteRu = 'Основные домены сайта, медиа/CDN и ссылок; перечень может быть неполным.'
            NoteEn = 'Core website, media/CDN, and link hostnames; the list may be incomplete.'
        }
        [pscustomobject]@{
            Id = 'tiktok'; NameRu = 'TikTok'; NameEn = 'TikTok'
            Domains = [string[]]@('tiktok.com','tiktokv.com','tiktokcdn.com','tiktokcdn-us.com','tiktokcdn-eu.com','tiktokcdn-in.com','byteoversea.com','ibytedtos.com')
            NoteRu = 'Основные домены сайта, приложения и CDN; региональные адреса могут отличаться.'
            NoteEn = 'Core website, app, and CDN hostnames; regional hosts may differ.'
        }
        [pscustomobject]@{
            Id = 'x'; NameRu = 'X (Twitter)'; NameEn = 'X (Twitter)'
            Domains = [string[]]@('x.com','twitter.com','t.co','twimg.com','twitterusercontent.com')
            NoteRu = 'Основные домены сайта, коротких ссылок и медиа; перечень может быть неполным.'
            NoteEn = 'Core website, short-link, and media hostnames; the list may be incomplete.'
        }
        [pscustomobject]@{
            Id = 'twitch'; NameRu = 'Twitch'; NameEn = 'Twitch'
            Domains = [string[]]@('twitch.tv','twitchcdn.net','ttvnw.net')
            NoteRu = 'Основные домены сайта и видео/CDN; перечень может быть неполным.'
            NoteEn = 'Core website and video/CDN hostnames; the list may be incomplete.'
        }
    )
}

function Select-DiscoveredDomains {
    # Pure DNS-cache filter: normalize hosts, drop noisy system domains and deduplicate.
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$RawNames = @())
    $blockedDomains = @(
        'localhost', 'local', 'arpa', 'microsoft.com', 'windowsupdate.com',
        'msftconnecttest.com', 'msftncsi.com', 'bing.com'
    )
    $seen = @{}
    foreach ($rawName in $RawNames) {
        if ($null -eq $rawName) { continue }
        $domain = ConvertTo-Domain -InputText ([string]$rawName)
        if (-not $domain) { continue }
        $systemDomain = $false
        foreach ($blocked in $blockedDomains) {
            if ($domain -eq $blocked -or $domain.EndsWith(('.' + $blocked), [StringComparison]::OrdinalIgnoreCase)) {
                $systemDomain = $true
                break
            }
        }
        if (-not $systemDomain) { $seen[$domain] = $true }
    }
    $sorted = @($seen.Keys | Sort-Object)
    return $sorted
}

function ConvertFrom-DomainDiscoverySelection {
    # Pure, strict parser for selections like 1,3,5, 2-4 or all; returns 1-based indexes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Selection,
        [Parameter(Mandatory = $true)][ValidateRange(0,100000)][int]$ItemCount
    )
    $text = $Selection.Trim()
    if (-not $text) { return @() }
    if ($text -match '^(?i:all)$') {
        $all = @()
        for ($index = 1; $index -le $ItemCount; $index++) { $all += $index }
        return $all
    }
    $selected = New-Object System.Collections.Generic.List[int]
    $seen = @{}
    foreach ($part in ($text -split ',')) {
        $token = $part.Trim()
        $match = [regex]::Match($token, '^(\d+)(?:\s*-\s*(\d+))?$')
        if (-not $match.Success) { throw "Неверный выбор '$token'. Используйте номера через запятую, диапазон (например, 1-3) или all." }
        $first = 0
        if (-not [int]::TryParse($match.Groups[1].Value, [ref]$first)) { throw "Номер '$token' вне допустимого диапазона." }
        $last = $first
        if ($match.Groups[2].Success -and -not [int]::TryParse($match.Groups[2].Value, [ref]$last)) { throw "Номер '$token' вне допустимого диапазона." }
        if ($first -lt 1 -or $last -lt $first -or $last -gt $ItemCount) { throw "Номер '$token' вне списка 1-$ItemCount." }
        for ($number = $first; $number -le $last; $number++) {
            if (-not $seen.ContainsKey($number)) {
                $seen[$number] = $true
                $selected.Add($number)
            }
        }
    }
    return $selected.ToArray()
}

function Add-DomainToList {
    # Adds $Domain to list-general-user.txt (general) or list-exclude-user.txt
    # (exclude). Returns 'added' | 'exists'. Throws on invalid input.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][ValidateSet('general', 'exclude')][string]$Kind,
        [string]$ListsDir = $script:ListsDir
    )
    $normalized = ConvertTo-Domain -InputText $Domain
    if (-not $normalized) { throw "Домен '$Domain' не распознан. Пример: discord.com или https://www.youtube.com/watch?v=123" }
    $fileName = if ($Kind -eq 'general') { 'list-general-user.txt' } else { 'list-exclude-user.txt' }
    $file = Join-Path $ListsDir $fileName
    if (-not (Test-Path -LiteralPath $ListsDir)) { New-Item -ItemType Directory -Path $ListsDir -Force | Out-Null }
    $existing = @()
    if (Test-Path -LiteralPath $file) {
        $existing = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim([char]0xFEFF).Trim().ToLowerInvariant() } | Where-Object { $_ -and $_ -notmatch '^#' })
    }
    if ($existing -contains $normalized) {
        Write-Info2 ("{0} уже есть в lists\{1} - ничего не меняю." -f $normalized, $fileName)
        return 'exists'
    }
    [IO.File]::AppendAllText($file, $normalized + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ("Добавлен домен: {0} -> lists\{1}" -f $normalized, $fileName)
    Write-Log "Domain added to ${Kind}: $normalized"
    return 'added'
}

# ---------------------------------------------------------------------------
# Bypass profiles ("Профиль обхода"): narrow the bypass to chosen services by
# writing a managed block of domains into lists/list-exclude-user.txt. Lines the
# user wrote are preserved; profile 'all' removes the block entirely.
# ---------------------------------------------------------------------------

$script:ManagedProfileBeginPrefix = '# >>> zapret-managed profile'
$script:ManagedProfileEndMark = '# <<< zapret-managed profile <<<'

function Get-BypassProfiles {
    return @(
        [pscustomobject]@{ Id = 'all';          NameRu = 'Все сервисы (без ограничений)'; KeepIds = @();          ExcludeIds = @() }
        [pscustomobject]@{ Id = 'discord-only'; NameRu = 'Только Discord';                KeepIds = @('discord'); ExcludeIds = @() }
        [pscustomobject]@{ Id = 'youtube-only'; NameRu = 'Только YouTube';                KeepIds = @('youtube'); ExcludeIds = @() }
        [pscustomobject]@{ Id = 'no-whatsapp';  NameRu = 'Без WhatsApp';                  KeepIds = @();          ExcludeIds = @('whatsapp') }
    )
}

function Get-ProfileExcludeDomains {
    # Catalog domains the given profile excludes from the bypass.
    param([Parameter(Mandatory = $true)][string]$Profile)
    $def = @(Get-BypassProfiles | Where-Object { $_.Id -eq $Profile }) | Select-Object -First 1
    if (-not $def) { throw "Unknown bypass profile '$Profile'." }
    $excludedIds = New-Object 'System.Collections.Generic.List[string]'
    if ($def.ExcludeIds.Count -gt 0) {
        foreach ($id in $def.ExcludeIds) { $excludedIds.Add([string]$id) }
    } elseif ($def.KeepIds.Count -gt 0) {
        foreach ($c in @(Get-RecommendedSiteCatalog)) {
            if (@($def.KeepIds) -notcontains [string]$c.Id) { $excludedIds.Add([string]$c.Id) }
        }
    }
    $domains = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in @(Get-RecommendedSiteCatalog)) {
        if ($excludedIds -contains [string]$c.Id) {
            foreach ($d in $c.Domains) { if (-not $domains.Contains([string]$d)) { $domains.Add([string]$d) } }
        }
    }
    return $domains.ToArray()
}

function Get-BypassProfile {
    # Reads the managed block header; 'all' when no block is present.
    param([string]$ListsDir = $script:ListsDir)
    $file = Join-Path $ListsDir 'list-exclude-user.txt'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return 'all' }
    foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        $t = ([string]$line).Trim()
        if ($t.StartsWith($script:ManagedProfileBeginPrefix)) {
            if ($t -match 'profile:\s*([a-z0-9-]+)') { return [string]$Matches[1] }
            return 'custom'
        }
    }
    return 'all'
}

function Set-BypassProfile {
    <#
        Rewrites ONLY the managed block in list-exclude-user.txt; every line the
        user wrote is preserved. Profile 'all' removes the block entirely.
        Returns @{ Profile; Domains; Path }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('all', 'discord-only', 'youtube-only', 'no-whatsapp')][string]$Profile,
        [string]$ListsDir = $script:ListsDir
    )
    $file = Join-Path $ListsDir 'list-exclude-user.txt'
    if (-not (Test-Path -LiteralPath $ListsDir)) { New-Item -ItemType Directory -Path $ListsDir -Force | Out-Null }
    $kept = New-Object 'System.Collections.Generic.List[string]'
    $inside = $false
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
            $t = ([string]$line).Trim()
            if ($t.StartsWith($script:ManagedProfileBeginPrefix)) { $inside = $true; continue }
            if ($inside -and $t -eq $script:ManagedProfileEndMark) { $inside = $false; continue }
            if (-not $inside) { $kept.Add([string]$line) }
        }
        if ($inside) {
            throw ('Файл {0} повреждён: маркер открылся, но не закрылся. Исправьте строку "{1}" вручную.' -f $file, $script:ManagedProfileEndMark)
        }
    }
    $domains = @()
    if ($Profile -ne 'all') { $domains = @(Get-ProfileExcludeDomains -Profile $Profile) }
    $outLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in $kept) { if (-not [string]::IsNullOrWhiteSpace($l)) { $outLines.Add($l) } }
    if ($domains.Count -gt 0) {
        $outLines.Add(('{0}: {1} >>>' -f $script:ManagedProfileBeginPrefix, $Profile))
        foreach ($d in $domains) { $outLines.Add([string]$d) }
        $outLines.Add($script:ManagedProfileEndMark)
    }
    [IO.File]::WriteAllText($file, (($outLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ("Профиль обхода: {0} (доменов исключено: {1})" -f $Profile, $domains.Count)
    Write-Log ("Bypass profile set: {0} ({1} domains)" -f $Profile, $domains.Count)
    return [pscustomobject]@{ Profile = $Profile; Domains = $domains; Path = $file }
}

# ---------------------------------------------------------------------------
# Speed test ("Тест скорости"): 64 KB range downloads through the current state
# ---------------------------------------------------------------------------

function Invoke-SpeedTest {
    param([int]$TimeoutSec = 15)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in (Get-FreezeTargets)) {
        $r = Test-DataTransferUrl -Url ([string]$t.Url) -TimeoutSec $TimeoutSec
        $rows.Add([pscustomobject]@{ Name = [string]$t.Name; Ok = [bool]$r.Ok; SpeedKBs = [double]$r.SpeedKBs; Ms = [int]$r.Ms })
    }
    $best = 0.0
    foreach ($row in $rows) { if ($row.SpeedKBs -gt $best) { $best = $row.SpeedKBs } }
    $verdict = if ($best -ge 500) { 'excellent' } elseif ($best -ge 100) { 'ok' } elseif ($best -gt 0) { 'slow' } else { 'failed' }
    Write-Log ("Speed test: best {0:N1} KB/s ({1})" -f $best, $verdict)
    return [pscustomobject]@{ Rows = $rows.ToArray(); BestKBs = $best; Verdict = $verdict }
}

# ---------------------------------------------------------------------------
# Site check ("Проверка сайта"): where does a domain flow - the bypass lists,
# the exclusions or the active profile - and does it actually load.
# ---------------------------------------------------------------------------

function Test-DomainListMatch {
    # winws hostlist entries cover the domain and its subdomains (suffix match).
    param([string]$Domain, [string[]]$Entries)
    foreach ($e in $Entries) {
        $entry = [string]$e
        if (-not $entry) { continue }
        if ($Domain -eq $entry) { return $entry }
        if ($Domain.EndsWith('.' + $entry, [StringComparison]::OrdinalIgnoreCase)) { return $entry }
    }
    return $null
}

function Get-SiteRouteInfo {
    # Classifies a domain against the four host lists and the profile block.
    # Exclude lists win over general lists, exactly like the winws chains.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [string]$ListsDir = $script:ListsDir
    )
    $domain = ConvertTo-Domain -InputText $InputText
    if (-not $domain) { throw ("Домен '{0}' не распознан. Пример: discord.com или https://www.youtube.com/watch?v=123" -f $InputText) }
    $lists = @{}
    $profileDomains = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('list-general.txt', 'list-exclude.txt', 'list-general-user.txt', 'list-exclude-user.txt')) {
        $entries = New-Object 'System.Collections.Generic.List[string]'
        $file = Join-Path $ListsDir $name
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $inside = $false
            foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
                $t = ([string]$line).Trim([char]0xFEFF).Trim()
                if (-not $t -or $t.StartsWith('#')) {
                    if ($t.StartsWith($script:ManagedProfileBeginPrefix)) { $inside = $true }
                    elseif ($inside -and $t -eq $script:ManagedProfileEndMark) { $inside = $false }
                    continue
                }
                if ($inside -and $name -eq 'list-exclude-user.txt') {
                    $profileDomains.Add($t.ToLowerInvariant())
                    continue
                }
                $entries.Add($t.ToLowerInvariant())
            }
        }
        $lists[$name] = $entries.ToArray()
    }
    $matchGeneral = Test-DomainListMatch -Domain $domain -Entries (@($lists['list-general.txt']) + @($lists['list-general-user.txt']))
    $matchExclude = Test-DomainListMatch -Domain $domain -Entries (@($lists['list-exclude.txt']) + @($lists['list-exclude-user.txt']))
    $profileHit = Test-DomainListMatch -Domain $domain -Entries $profileDomains.ToArray()
    $route = 'not-listed'
    $noteRu = 'Домен не найден в списках обхода - цепочки по домену его не обрабатывают.'
    if ($matchExclude) {
        $route = 'excluded'
        $noteRu = ("Домен '{0}' в списке исключений - обход его не обрабатывает." -f $matchExclude)
    } elseif ($profileHit) {
        $route = 'excluded'
        $noteRu = ("Домен '{0}' исключён активным профилем обхода." -f $profileHit)
    } elseif ($matchGeneral) {
        $route = 'bypass'
        $noteRu = ("Домен '{0}' идёт через обход." -f $matchGeneral)
    }
    return [pscustomobject]@{
        Domain = $domain
        Route = $route
        NoteRu = $noteRu
        MatchGeneral = $matchGeneral
        MatchExclude = $matchExclude
        ProfileExcluded = [bool]$profileHit
    }
}

function Get-SiteTransferState {
    # Pure: 'none' | 'full' | 'small' | 'freeze'. A complete response smaller
    # than 64 KB is NOT a freeze - the probe needs the full range to prove the
    # stream keeps flowing past the common 16-20 KB cut-off point.
    param(
        [Parameter(Mandatory = $true)][bool]$ProbeOk,
        [AllowNull()]$Transfer
    )
    if (-not $ProbeOk) { return 'none' }
    if ($Transfer -and $Transfer.Ok) { return 'full' }
    $code = if ($Transfer) { [int]$Transfer.Code } else { 0 }
    $exit = if ($Transfer -and $null -ne $Transfer.CurlExitCode) { [int]$Transfer.CurlExitCode } else { -1 }
    if ($exit -eq 0 -and $code -ge 200) { return 'small' }
    return 'freeze'
}

function Get-SiteCheckVerdict {
    param(
        [Parameter(Mandatory = $true)][bool]$ProbeOk,
        [AllowNull()]$Transfer
    )
    $state = Get-SiteTransferState -ProbeOk $ProbeOk -Transfer $Transfer
    switch ($state) {
        'none'  { return 'Сайт не отвечает через текущее подключение.' }
        'full'  { return 'Сайт открывается, данные скачиваются.' }
        'small' {
            $bytes = if ($Transfer) { [int]$Transfer.Bytes } else { 0 }
            $code = if ($Transfer) { [int]$Transfer.Code } else { 0 }
            return ('Ответ получен полностью (HTTP {0}, {1} байт) - это не зависание; страница меньше 64 КБ.' -f $code, $bytes)
        }
        default { return 'Страница отвечает, но передача данных зависает - типичный TCP-фриз.' }
    }
}

function Invoke-SiteCheck {
    # Route + one HTTP probe + a 64 KB transfer check for a single site.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InputText,
        [int]$TimeoutSec = 6
    )
    $route = Get-SiteRouteInfo -InputText $InputText
    $trimmed = $InputText.Trim()
    $url = if ($trimmed -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $trimmed } else { 'https://' + $route.Domain }
    $probe = Test-ReachableUrl -Url $url -TimeoutSec $TimeoutSec -ProtocolArgs @('--http1.1')
    $transfer = $null
    if ($probe.Ok) { $transfer = Test-DataTransferUrl -Url $url -TimeoutSec $TimeoutSec }
    $verdictRu = Get-SiteCheckVerdict -ProbeOk ([bool]$probe.Ok) -Transfer $transfer
    Write-Log ("Site check {0}: route={1} probe={2} transfer={3}" -f $route.Domain, $route.Route, [bool]$probe.Ok, [bool]($transfer -and $transfer.Ok))
    return [pscustomobject]@{
        Domain = $route.Domain
        Url = $url
        Route = $route.Route
        NoteRu = $route.NoteRu
        ProbeOk = [bool]$probe.Ok
        ProbeMs = [int]$probe.Ms
        TransferOk = [bool]($transfer -and $transfer.Ok)
        TransferKBs = if ($transfer) { [double]$transfer.SpeedKBs } else { 0.0 }
        TransferBytes = if ($transfer) { [int]$transfer.Bytes } else { 0 }
        TransferState = Get-SiteTransferState -ProbeOk ([bool]$probe.Ok) -Transfer $transfer
        VerdictRu = $verdictRu
    }
}



function Invoke-DomainDiscovery {
    # Clears and reads the Windows DNS cache, then offers a validated batch add.
    [CmdletBinding()]
    param()
    if (-not $script:OnWindows) { throw 'discover-domains requires Windows.' }
    Assert-Admin
    if (-not (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue)) { throw 'Clear-DnsClientCache is unavailable on this Windows installation.' }
    if (-not (Get-Command Get-DnsClientCache -ErrorAction SilentlyContinue)) { throw 'Get-DnsClientCache is unavailable on this Windows installation.' }

    Write-Warn2 'Сейчас будет очищен системный DNS-кэш Windows. Затем откройте нужный сайт или запустите игру; в кэш попадут только новые DNS-запросы.'
    try { Clear-DnsClientCache -ErrorAction Stop | Out-Null } catch { throw ("Не удалось очистить системный DNS-кэш: {0}" -f $_.Exception.Message) }
    Write-Ok 'DNS-кэш очищен.'
    [void](Read-Host (Get-UiText -Russian 'Откройте нужный сайт или игру, затем нажмите Enter, чтобы посмотреть кэш DNS' -English 'Open the site or game, then press Enter to view the DNS cache'))

    try { $cacheEntries = @(Get-DnsClientCache -ErrorAction Stop) } catch { throw ("Не удалось прочитать DNS-кэш: {0}" -f $_.Exception.Message) }
    $rawNames = @($cacheEntries | ForEach-Object {
        if ($null -ne $_ -and $null -ne $_.PSObject.Properties['Entry']) { [string]$_.Entry }
    })
    $domains = @(Select-DiscoveredDomains -RawNames $rawNames)
    if ($domains.Count -eq 0) {
        Write-Info2 'Подходящие домены не найдены. Попробуйте открыть сайт ещё раз, затем повторите поиск.'
        return [pscustomobject]@{ Discovered = 0; Selected = 0; Added = 0 }
    }

    Write-Host ''
    Write-Host (Get-UiText -Russian '   НАЙДЕННЫЕ ДОМЕНЫ:' -English '   DOMAINS FOUND:') -ForegroundColor Cyan
    for ($index = 0; $index -lt $domains.Count; $index++) {
        Write-Host ('   {0,3}. {1}' -f ($index + 1), $domains[$index])
    }
    $selection = Read-Host (Get-UiText -Russian 'Введите номера через запятую (например 1,3,5), диапазон (1-3), all — выбрать все; Enter — отмена' -English 'Enter numbers separated by commas (1,3,5), a range (1-3), all to select every domain, or press Enter to cancel')
    try { $indexes = @(ConvertFrom-DomainDiscoverySelection -Selection ([string]$selection) -ItemCount $domains.Count) }
    catch { Write-Fail $_.Exception.Message; return [pscustomobject]@{ Discovered = $domains.Count; Selected = 0; Added = 0 } }
    if ($indexes.Count -eq 0) {
        Write-Info2 'Добавление отменено.'
        return [pscustomobject]@{ Discovered = $domains.Count; Selected = 0; Added = 0 }
    }

    $added = 0
    foreach ($number in $indexes) {
        $result = Add-DomainToList -Domain $domains[$number - 1] -Kind general
        if ($result -eq 'added') { $added++ }
    }
    if ($added -gt 0) { [void](Invoke-ZapretServiceRestartPrompt -Reason 'Домены добавлены из DNS-кэша') }
    return [pscustomobject]@{ Discovered = $domains.Count; Selected = $indexes.Count; Added = $added }
}

function Remove-DomainFromLines {
    # Pure list filter: keeps comments, blank lines and unrelated entries.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory = $true)][string]$Domain
    )
    $normalized = ConvertTo-Domain -InputText $Domain
    if (-not $normalized) { throw "Домен '$Domain' не распознан." }
    $remaining = New-Object System.Collections.Generic.List[string]
    $removed = 0
    foreach ($line in $Lines) {
        $trimmed = ([string]$line).Trim([char]0xFEFF).Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) {
            $remaining.Add([string]$line)
            continue
        }
        $lineDomain = ConvertTo-Domain -InputText $trimmed
        if ($lineDomain -eq $normalized) { $removed++ }
        else { $remaining.Add([string]$line) }
    }
    return [pscustomobject]@{ Lines = @($remaining.ToArray()); Removed = $removed; Domain = $normalized }
}

function Remove-DomainFromLists {
    # Removes all exact normalized matches from both personal host lists.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [string]$ListsDir = $script:ListsDir
    )
    $normalized = ConvertTo-Domain -InputText $Domain
    if (-not $normalized) { throw "Домен '$Domain' не распознан." }
    $counts = @{ general = 0; exclude = 0 }
    foreach ($kind in @('general','exclude')) {
        $file = Join-Path $ListsDir ("list-{0}-user.txt" -f $kind)
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $oldLines = [IO.File]::ReadAllLines($file)
        $filtered = Remove-DomainFromLines -Lines $oldLines -Domain $normalized
        if ($filtered.Removed -gt 0) {
            $temp = "$file.tmp-$([Guid]::NewGuid().ToString('N'))"
            try {
                [IO.File]::WriteAllLines($temp, [string[]]$filtered.Lines, (New-Object System.Text.UTF8Encoding($false)))
                Move-Item -LiteralPath $temp -Destination $file -Force
            } finally {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }
            $counts[$kind] = $filtered.Removed
            Write-Log "Domain removed from ${kind}: $normalized ($($filtered.Removed) entries)"
        }
    }
    $total = $counts.general + $counts.exclude
    if ($total -gt 0) { Write-Ok ("Домен {0} удалён: обход={1}, исключения={2}." -f $normalized, $counts.general, $counts.exclude) }
    else { Write-Info2 ("Домен {0} в пользовательских списках не найден." -f $normalized) }
    return [pscustomobject]@{ Domain = $normalized; GeneralRemoved = $counts.general; ExcludeRemoved = $counts.exclude; TotalRemoved = $total }
}

function Reset-UserDomainLists {
    # Reset only My Sites' general/exclude overlays; IPSet and other settings stay intact.
    [CmdletBinding()]
    param([string]$ListsDir = $script:ListsDir)
    if (-not (Test-Path -LiteralPath $ListsDir)) { New-Item -ItemType Directory -Path $ListsDir -Force | Out-Null }
    $changed = @()
    foreach ($kind in @('general','exclude')) {
        $fileName = "list-$kind-user.txt"
        $file = Join-Path $ListsDir $fileName
        $defaultContent = Get-DefaultUserDomainListContent -Kind $kind
        $old = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { $null }
        if ($null -eq $old -or $old -cne $defaultContent) {
            [IO.File]::WriteAllText($file, $defaultContent, (New-Object System.Text.UTF8Encoding($false)))
            $changed += $fileName
        }
    }
    if ($changed.Count -gt 0) { Write-Ok 'Пользовательские списки сайтов возвращены к исходным шаблонам; встроенные списки и IPSet не затронуты.' }
    else { Write-Info2 'Пользовательские списки сайтов уже соответствуют исходным шаблонам.' }
    return [pscustomobject]@{ Changed = ($changed.Count -gt 0); Files = @($changed) }
}
