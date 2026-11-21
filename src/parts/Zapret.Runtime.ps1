# ---------------------------------------------------------------------------
# Console output and logging
# ---------------------------------------------------------------------------

function Get-LogFilePath {
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    return (Join-Path $script:LogDir ('zapret-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd')))
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Level = 'INFO')
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath (Get-LogFilePath) -Value $line -Encoding UTF8
    } catch {
        # Logging must never break the tool.
    }
}

function Write-Ok    { param([string]$Text) Write-Host ('  [OK] {0}' -f (ConvertTo-UiMessage -Text $Text)) -ForegroundColor Green;  Write-Log "[OK] $Text" 'OK' }
function Write-Warn2 { param([string]$Text) Write-Host ('  [?]  {0}' -f (ConvertTo-UiMessage -Text $Text)) -ForegroundColor Yellow; Write-Log "[WARN] $Text" 'WARN' }
function Write-Fail  { param([string]$Text) Write-Host ('  [X]  {0}' -f (ConvertTo-UiMessage -Text $Text)) -ForegroundColor Red;    Write-Log "[FAIL] $Text" 'FAIL' }
function Write-Info2 { param([string]$Text) Write-Host ('  [i]  {0}' -f (ConvertTo-UiMessage -Text $Text)) -ForegroundColor Cyan;   Write-Log "[INFO] $Text" 'INFO' }
function Write-PreviewInfo { param([string]$Text) Write-Host ('  [preview] {0}' -f (ConvertTo-UiMessage -Text $Text)) -ForegroundColor Cyan }
function Write-HostTable {
    # Renders a table through Write-Host line by line so it reaches both the
    # console and the in-app journal; hostless runspace output is invisible.
    param([Parameter(Mandatory = $true)]$InputObject)
    $text = ($InputObject | Format-Table -AutoSize | Out-String)
    foreach ($line in ($text -split "\r?\n")) { Write-Host $line }
}

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

function Get-LocalVersion {
    if ($script:LocalVersion) { return $script:LocalVersion }
    try {
        $v = [IO.File]::ReadAllText((Join-Path $script:ServiceDir 'version.txt')).Trim()
        if ($v) { $script:LocalVersion = $v; return $v }
    } catch { }
    $script:LocalVersion = '0.0.0'
    return $script:LocalVersion
}

function ConvertTo-VersionOrNull {
    param([string]$Text)
    if (-not $Text) { return $null }
    $clean = ($Text.Trim() -replace '^[vV]', '') -replace '[^0-9.]', ''
    if (-not $clean) { return $null }
    try { return [version]$clean } catch { return $null }
}

function Compare-VersionTexts {
    param([string]$Remote, [string]$Local)
    $r = ConvertTo-VersionOrNull $Remote
    $l = ConvertTo-VersionOrNull $Local
    if (-not $r -or -not $l) { return $null }
    return $r.CompareTo($l)
}

# ---------------------------------------------------------------------------
# Configuration (config.json with migration from legacy marker files)
# ---------------------------------------------------------------------------

function Get-DefaultConfig {
    return [ordered]@{
        version      = 1
        checkUpdates = $true
        uiLanguage   = 'ru'
        gameFilter   = [ordered]@{
            mode = 'disabled'          # disabled | all | tcp | udp
            tcp  = '1024-65535'
            udp  = '1024-65535'
        }
        carrierStrategies = [ordered]@{
            mts      = $null
            megafon  = $null
            tele2    = $null
            yota     = $null
        }                            # last live-tested narrow strategy per selected mobile carrier
        rollback     = $null           # set by Save-RollbackSnapshot; see Rollback section
        updateFeed        = 'https://raw.githubusercontent.com/Orlovsky1504/OpenZapret/main/update-manifest.json'  # update-manifest.json feed (project repo)
        autoInstallUpdates = $false     # install feed updates automatically after the hard gates pass
    }
}

function ConvertFrom-LegacyConfig {
    $cfg = Get-DefaultConfig

    # utils\game_filter.enabled: lines like mode=all / tcp=... / udp=...
    $gameFile = Join-Path $script:UtilsDir 'game_filter.enabled'
    if (Test-Path $gameFile) {
        try {
            foreach ($raw in (Get-Content $gameFile)) {
                $line = $raw.Trim()
                if (-not $line) { continue }
                if ($line -notmatch '=') {
                    # bare keyword: 'all' | 'tcp' | 'udp' | 'mode' -> enables that mode
                    switch ($line.ToLowerInvariant()) {
                        'all'  { $cfg.gameFilter.mode = 'all' }
                        'tcp'  { $cfg.gameFilter.mode = 'tcp' }
                        'udp'  { $cfg.gameFilter.mode = 'udp' }
                        'mode' { $cfg.gameFilter.mode = 'all' }
                    }
                    continue
                }
                $key, $value = $line.Split('=', 2)
                $key = $key.Trim().ToLowerInvariant(); $value = $value.Trim()
                switch ($key) {
                    'mode' { if ($value -in @('disabled','all','tcp','udp')) { $cfg.gameFilter.mode = $value } }
                    'all'  { if ($value) { if (Test-PortRange $value) { $cfg.gameFilter.tcp = $value; $cfg.gameFilter.udp = $value } } else { $cfg.gameFilter.mode = 'all' } }
                    'tcp'  { if ($value) { if (Test-PortRange $value) { $cfg.gameFilter.tcp = $value } } }
                    'udp'  { if ($value) { if (Test-PortRange $value) { $cfg.gameFilter.udp = $value } } }
                }
            }
        } catch { }
    }

    # utils\check_updates.enabled: presence == enabled.
    # Only applies when legacy marker files exist (i.e. this is an upgrade, not a fresh install).
    $gameFileExists = Test-Path (Join-Path $script:UtilsDir 'game_filter.enabled')
    $marker = Join-Path $script:UtilsDir 'check_updates.enabled'
    if ($gameFileExists -or (Test-Path $marker)) {
        $cfg.checkUpdates = [bool](Test-Path $marker)
    }

    return $cfg
}

function Set-ZapretNonInteractive {
    # GUI hosts have no console input: a Read-Host would hang the app. The
    # panel confirms actions up front and runs module functions with this set,
    # so prompts auto-accept their default/expected answer.
    param([bool]$Enabled = $true)
    $script:ZapretNonInteractive = $Enabled
}

function Get-ZapretNonInteractive {
    return [bool]$script:ZapretNonInteractive
}

function Get-Config {
    param([string]$Path = $null)
    $path = if ($Path) { $Path } else { $script:ConfigPath }

    $defaults = Get-DefaultConfig

    if (-not (Test-Path $path)) {
        $cfg = ConvertFrom-LegacyConfig
        try { Save-Config -Config $cfg -Path $path } catch { }
        return [pscustomobject]$cfg
    }

    try {
        $raw = [IO.File]::ReadAllText($path)
        $json = $raw | ConvertFrom-Json
    } catch {
        Write-Log "config.json is unreadable ($($_.Exception.Message)); falling back to defaults" 'WARN'
        return [pscustomobject]$defaults
    }

    $cfg = Get-DefaultConfig
    if ($null -ne $json) {
        if ($null -ne $json.checkUpdates) { $cfg.checkUpdates = [bool]$json.checkUpdates }
        if ($json.PSObject.Properties['uiLanguage'] -and [string]$json.uiLanguage -in @('ru','en')) { $cfg.uiLanguage = [string]$json.uiLanguage }
        if ($json.PSObject.Properties['carrierStrategies'] -and $null -ne $json.carrierStrategies) {
            foreach ($carrierId in @('mts', 'megafon', 'tele2', 'yota')) {
                $savedProperty = $json.carrierStrategies.PSObject.Properties[$carrierId]
                if ($savedProperty -and [string]$savedProperty.Value -match '^[A-Za-z0-9][A-Za-z0-9-]{1,40}$') {
                    $cfg.carrierStrategies[$carrierId] = ([string]$savedProperty.Value).ToLowerInvariant()
                }
            }
        }
        if ($null -ne $json.gameFilter) {
            $gf = $json.gameFilter
            if ($gf.PSObject.Properties['mode'] -and $gf.mode -in @('disabled','all','tcp','udp')) { $cfg.gameFilter.mode = [string]$gf.mode }
            if ($gf.PSObject.Properties['tcp'] -and (Test-PortRange ([string]$gf.tcp))) { $cfg.gameFilter.tcp = [string]$gf.tcp }
            if ($gf.PSObject.Properties['udp'] -and (Test-PortRange ([string]$gf.udp))) { $cfg.gameFilter.udp = [string]$gf.udp }
        }
        if ($json.PSObject.Properties['updateFeed']) {
            $feed = ([string]$json.updateFeed -replace '[\x00-\x1F\x7F]', '').Trim()
            if ($feed.Length -gt 0 -and $feed.Length -le 2048) { $cfg.updateFeed = $feed } elseif ($feed.Length -eq 0) { $cfg.updateFeed = $null }
        }
        if ($json.PSObject.Properties['autoInstallUpdates']) { $cfg.autoInstallUpdates = [bool]$json.autoInstallUpdates }
        if ($json.PSObject.Properties['rollback'] -and $null -ne $json.rollback) {
            $rb = $json.rollback
            $scrub = { param($v) if ($null -eq $v) { return $null }; ([string]$v -replace '[\x00-\x1F\x7F]', '').Trim() }
            if ($rb.PSObject.Properties['folder'] -and $rb.folder) {
                $cfg.rollback = [pscustomobject]@{
                    reason   = (& $scrub $rb.reason)
                    time     = (& $scrub $rb.time)
                    strategy = (& $scrub $(if ($rb.PSObject.Properties['strategy']) { $rb.strategy } else { $null }))
                    folder   = (& $scrub $rb.folder)
                    ipset    = [bool]$rb.ipset
                    hosts    = [bool]$rb.hosts
                }
            }
        }
    }
    return [pscustomobject]$cfg
}

function Save-Config {
    param([Parameter(Mandatory = $true)]$Config, [string]$Path = $null)
    $path = if ($Path) { $Path } else { $script:ConfigPath }
    $json = $Config | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "Configuration saved to $path"
}

function Update-Config {
    param([hashtable]$Changes, [string]$Path = $null)
    $path = if ($Path) { $Path } else { $script:ConfigPath }
    $cfg = Get-Config -Path $path
    $rollbackValue = $null
    try { if ($cfg.rollback) { $rollbackValue = $cfg.rollback } } catch { }
    $hash = [ordered]@{
        version      = 1
        checkUpdates = [bool]$cfg.checkUpdates
        uiLanguage   = [string]$cfg.uiLanguage
        carrierStrategies = [ordered]@{
            mts      = $cfg.carrierStrategies.mts
            megafon  = $cfg.carrierStrategies.megafon
            tele2    = $cfg.carrierStrategies.tele2
            yota     = $cfg.carrierStrategies.yota
        }
        gameFilter   = [ordered]@{
            mode = [string]$cfg.gameFilter.mode
            tcp  = [string]$cfg.gameFilter.tcp
            udp  = [string]$cfg.gameFilter.udp
        }
        rollback     = $rollbackValue
        updateFeed         = $cfg.updateFeed
        autoInstallUpdates = [bool]$cfg.autoInstallUpdates
    }
    foreach ($key in $Changes.Keys) {
        switch ($key) {
            'checkUpdates' { $hash.checkUpdates = [bool]$Changes[$key] }
            'uiLanguage'    { if ([string]$Changes[$key] -in @('ru','en')) { $hash.uiLanguage = [string]$Changes[$key] } }
            'carrierStrategy' {
                $carrierKey = ([string]$Changes['carrier']).ToLowerInvariant()
                $strategyId = ([string]$Changes['carrierStrategy']).ToLowerInvariant()
                if ($carrierKey -in @('mts','megafon','tele2','yota') -and $strategyId -match '^[a-z0-9][a-z0-9-]{1,40}$') {
                    $hash.carrierStrategies[$carrierKey] = $strategyId
                }
            }
            'gameFilterMode' { $hash.gameFilter.mode = [string]$Changes[$key] }
            'gameFilterTcp'  { $hash.gameFilter.tcp  = [string]$Changes[$key] }
            'gameFilterUdp'  { $hash.gameFilter.udp  = [string]$Changes[$key] }
            'rollback'       { $hash['rollback'] = $Changes[$key] }
            'updateFeed' {
                $feedValue = $Changes[$key]
                if ($null -eq $feedValue -or [string]::IsNullOrWhiteSpace([string]$feedValue)) { $hash.updateFeed = $null }
                else {
                    $feedClean = ([string]$feedValue -replace '[\x00-\x1F\x7F]', '').Trim()
                    if ($feedClean.Length -le 2048) { $hash.updateFeed = $feedClean }
                }
            }
            'autoInstallUpdates' { $hash.autoInstallUpdates = [bool]$Changes[$key] }
        }
    }
    Save-Config -Config $hash -Path $path
    return Get-Config -Path $path
}

function Get-UiLanguage {
    # Read the preference without creating config.json; first-run onboarding
    # must still be able to detect a genuinely fresh installation.
    [CmdletBinding()]
    param([string]$Path = $null)
    $path = if ($Path) { $Path } else { $script:ConfigPath }
    $language = 'ru'
    if (Test-Path -LiteralPath $path) {
        try {
            $json = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            if ($json -and $json.PSObject.Properties['uiLanguage'] -and [string]$json.uiLanguage -in @('ru','en')) {
                $language = [string]$json.uiLanguage
            }
        } catch { }
    }
    if (-not $PSBoundParameters.ContainsKey('Path')) { $script:UiLanguage = $language }
    return $language
}

function Set-UiLanguage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('ru','en')][string]$Language, [string]$Path = $null)
    $changes = @{ uiLanguage = $Language }
    if ($Path) { [void](Update-Config -Path $Path -Changes $changes) }
    else { [void](Update-Config -Changes $changes) }
    $script:UiLanguage = $Language
    return $Language
}

function Get-UiText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Russian,
        [Parameter(Mandatory = $true)][string]$English,
        [ValidateSet('ru','en')][string]$Language = $script:UiLanguage
    )
    if ($Language -eq 'en') { return $English }
    return $Russian
}

# Load a saved preference without creating config.json on first run.
$script:UiLanguage = Get-UiLanguage
# Console messages are translated here so the engine, CLI, and menu use the
# same wording. Logs keep the original text for easier troubleshooting.
$script:UiMessageRules = @(
    @{ Pattern = '^Could not write the strategy name to the registry \(non-fatal\): ([\s\S]+)$'; ru = 'Не удалось сохранить название стратегии в реестре Windows (это не влияет на работу): $1'; en = 'Could not save the strategy name in the Windows registry (this does not affect operation): $1' }
    @{ Pattern = '^Service ''zapret'' installed \(strategy: ([^)]+)\) and started\.$'; ru = 'Служба zapret установлена и запущена. Стратегия: $1.'; en = 'Service zapret installed and started. Strategy: $1.' }
    @{ Pattern = '^Service ''([^'']+)'' removed\.$'; ru = 'Служба $1 удалена.'; en = 'Service $1 removed.' }
    @{ Pattern = '^Service ''([^'']+)'' stopped and removed\.$'; ru = 'Служба $1 остановлена и удалена.'; en = 'Service $1 stopped and removed.' }
    @{ Pattern = '^Stopped (\d+) winws process\(es\); verified that none remain\.$'; ru = 'Остановлено процессов winws.exe: $1. Проверено: запущенных процессов не осталось.'; en = 'Stopped $1 winws.exe process(es). Verified that no processes remain.' }
    @{ Pattern = '^Служба zapret всё ещё работает; не удаляю её регистрацию, чтобы не сообщать об успехе преждевременно\.$'; ru = 'Служба zapret всё ещё работает. Её регистрация не удалена; отключите службу и повторите попытку.'; en = 'The zapret service is still running. Its registration was not removed; stop the service and retry.' }
    @{ Pattern = '^Не удалось остановить службу zapret \(sc\.exe exit (\d+)\)\. ([\s\S]*) Перезагрузите Windows и повторите удаление\.$'; ru = 'Не удалось остановить службу zapret (код sc.exe $1). $2Перезагрузите Windows и повторите удаление.'; en = 'Could not stop the zapret service (sc.exe exit $1). $2Restart Windows and retry uninstall.' }
    @{ Pattern = '^Не удалось удалить регистрацию службы zapret \(sc\.exe exit (\d+)\)\. ([\s\S]*) Если служба помечена к удалению, закройте services\.msc и перезагрузите Windows\.$'; ru = 'Не удалось удалить регистрацию службы zapret (код sc.exe $1). $2Если служба помечена к удалению, закройте services.msc и перезагрузите Windows.'; en = 'Could not delete the zapret service registration (sc.exe exit $1). $2If it is marked for deletion, close services.msc and restart Windows.' }
    @{ Pattern = '^Не удалось остановить winws\.exe перед удалением службы\.$'; ru = 'Не удалось остановить winws.exe перед удалением службы.'; en = 'Could not stop winws.exe before deleting the service.' }
    @{ Pattern = '^После удаления службы в системе всё ещё запущен winws\.exe\. Проверьте процессы и перезагрузите Windows, если остановить его не удаётся\.$'; ru = 'После удаления службы winws.exe всё ещё работает. Проверьте процессы или перезагрузите Windows.'; en = 'winws.exe is still running after service removal. Check the process or restart Windows.' }
    @{ Pattern = '^Удаление выполнено не полностью: служба WinDivert не очищена\. ([\s\S]+)$'; ru = 'Удаление не завершено: не удалось очистить службу WinDivert. $1'; en = 'Uninstall is incomplete: the WinDivert service could not be removed. $1' }
    @{ Pattern = '^Service ''([^'']+)'' is not installed\.$'; ru = 'Служба $1 не установлена.'; en = 'Service $1 is not installed.' }
    @{ Pattern = '^winws\.exe is not running\.$'; ru = 'winws.exe сейчас не запущен.'; en = 'winws.exe is not running.' }
    @{ Pattern = '^Weekly auto re-check task \(Zapret-AutoSelect\) removed\.$'; ru = 'Задача еженедельной проверки удалена.'; en = 'Weekly re-check task removed.' }
    @{ Pattern = '^Could not remove the Zapret-AutoSelect scheduled task - remove it manually: (.+)$'; ru = 'Не удалось удалить задачу проверки автоматически. Удалите её вручную командой: $1'; en = 'Could not remove the scheduled task automatically. Remove it manually with: $1' }
    @{ Pattern = '^Also remove the managed block from hosts\? \[Y/n\]$'; ru = 'Также удалить записи zapret из файла hosts? [Д/н]'; en = 'Also remove the zapret entries from the hosts file? [Y/n]' }
    @{ Pattern = '^Hosts block left in place\.$'; ru = 'Записи zapret в файле hosts оставлены без изменений.'; en = 'The zapret entries in the hosts file were left unchanged.' }
    @{ Pattern = '^Could not remove the managed hosts block: ([\s\S]+)$'; ru = 'Не удалось удалить записи zapret из hosts: $1'; en = 'Could not remove the zapret entries from hosts: $1' }
    @{ Pattern = '^Драйвер (.+) оставлен: путь не совпадает с bin этой установки или не распознан \(возможно, он нужен другой программе\)\.$'; ru = 'Драйвер $1 оставлен: путь не совпадает с bin этой установки или не распознан; возможно, он нужен другой программе.'; en = 'Driver $1 was left in place because its path does not match this install or could not be recognized; another program may need it.' }
    @{ Pattern = '^Драйвер (.+) из папки zapret выгружен, регистрация службы удалена\.$'; ru = 'Драйвер $1 выгружен и регистрация его службы удалена.'; en = 'Driver $1 was unloaded and its service registration removed.' }
    @{ Pattern = '^Не удалось полностью выгрузить драйвер (.+); восстанавливаю обход\.$'; ru = 'Не удалось выгрузить драйвер $1. Восстанавливаю обход.'; en = 'Could not unload driver $1 completely. Restoring the bypass.' }
    @{ Pattern = '^Не удалось выгрузить принадлежащий zapret драйвер (.+) \(sc\.exe exit (\d+)\)\. ([\s\S]*)$'; ru = 'Не удалось выгрузить принадлежащий zapret драйвер $1 (код sc.exe $2). $3'; en = 'Could not unload the zapret-owned driver $1 (sc.exe exit $2). $3' }
    @{ Pattern = '^Не удалось удалить регистрацию принадлежащего zapret драйвера (.+) \(sc\.exe exit (\d+)\)\. ([\s\S]*)$'; ru = 'Не удалось удалить регистрацию принадлежащего zapret драйвера $1 (код sc.exe $2). $3'; en = 'Could not delete the zapret-owned driver $1 registration (sc.exe exit $2). $3' }
    @{ Pattern = '^Пауза: (\d+) мин\. Нажмите любую клавишу, чтобы возобновить раньше\.$'; ru = 'Обход приостановлен на $1 мин. Нажмите любую клавишу, чтобы возобновить его раньше.'; en = 'The bypass is paused for $1 min. Press any key to resume it sooner.' }
    @{ Pattern = '^До возобновления: (.+)$'; ru = 'До возобновления: $1'; en = 'Time until resume: $1' }
    @{ Pattern = '^Пауза zapret для игры/античита$'; ru = 'Пауза обхода для игры или античита'; en = 'Pause bypass for a game or anti-cheat' }
    @{ Pattern = '^Получен ввод с клавиатуры — возобновляю раньше таймера\.$'; ru = 'Клавиша нажата — возобновляю обход.'; en = 'Key pressed — resuming the bypass.' }
    @{ Pattern = '^Сейчас не работает ни служба zapret, ни winws\.exe — пауза не требуется\.$'; ru = 'Обход уже остановлен — приостанавливать нечего.'; en = 'The bypass is already stopped; there is nothing to pause.' }
    @{ Pattern = '^Обход приостановлен\. Стратегия ''([^'']+)'' будет восстановлена через (\d+) мин\.$'; ru = 'Обход приостановлен. Стратегия $1 будет восстановлена через $2 мин.'; en = 'The bypass is paused. Strategy $1 will resume in $2 minutes.' }
    @{ Pattern = '^Обход приостановлен\. Стратегия ''([^'']+)'' будет восстановлена после Enter\.$'; ru = 'Обход приостановлен. Стратегия $1 будет восстановлена после нажатия Enter.'; en = 'The bypass is paused. Strategy $1 will resume after you press Enter.' }
    @{ Pattern = '^Возобновляю прежнюю службу zapret со стратегией ''([^'']+)''\.\.\.$'; ru = 'Восстанавливаю службу zapret со стратегией $1…'; en = 'Restoring the zapret service with strategy $1…' }
    @{ Pattern = '^Возобновляю запущенный вручную winws\.exe со стратегией ''([^'']+)''\.\.\.$'; ru = 'Снова запускаю winws.exe со стратегией $1…'; en = 'Restarting winws.exe with strategy $1…' }
    @{ Pattern = '^zapret возобновлён\.$'; ru = 'Обход возобновлён.'; en = 'The bypass has resumed.' }
    @{ Pattern = '^Не удалось возобновить обход автоматически: ([\s\S]+)$'; ru = 'Не удалось автоматически возобновить обход: $1'; en = 'Could not resume the bypass automatically: $1' }
    @{ Pattern = '^Попробуйте вручную: zapret\.ps1 (install|run) (.+)$'; ru = 'Чтобы запустить обход вручную, выполните: zapret.ps1 $1 $2'; en = 'To start the bypass manually, run: zapret.ps1 $1 $2' }
    @{ Pattern = '^IPSet switched to ''none'' \(match nothing\)\.$'; ru = 'Фильтр IP отключён: список не содержит адресов.'; en = 'IP filter set to none: the list matches no addresses.' }
    @{ Pattern = '^IPSet switched to ''any'' \(match everything\)\. Avoid leaving it on permanently - many sites may break\.$'; ru = 'Фильтр IP настроен на все адреса. Не оставляйте этот режим включённым: часть сайтов может перестать работать.'; en = 'IP filter set to all addresses. Do not leave this on: some sites may stop working.' }
    @{ Pattern = '^IPSet switched to the downloaded list\.$'; ru = 'Фильтр IP использует загруженный список.'; en = 'IP filter is using the downloaded list.' }
    @{ Pattern = '^Downloading the latest IPSet list\.\.\.$'; ru = 'Скачиваю свежий список IP-адресов…'; en = 'Downloading the latest IP address list…' }
    @{ Pattern = '^IPSet list updated \((\d+) entries\)\.$'; ru = 'Список IP обновлён: адресов — $1.'; en = 'IP address list updated: $1 entries.' }
    @{ Pattern = '^Previous list saved to (.+)$'; ru = 'Предыдущая версия списка сохранена: $1'; en = 'Previous list saved to $1' }
    @{ Pattern = '^Downloading the recommended hosts entries\.\.\.$'; ru = 'Скачиваю рекомендованные записи для файла hosts…'; en = 'Downloading the recommended hosts entries…' }
    @{ Pattern = '^Hosts file already contains the latest managed block\.$'; ru = 'Файл hosts уже содержит актуальные записи zapret.'; en = 'The hosts file already has the latest zapret entries.' }
    @{ Pattern = '^Dry run - would (.+) the managed hosts block\.$'; ru = 'Предварительная проверка: будут выполнены действия — $1 записи zapret в hosts.'; en = 'Preview only: this would $1 the zapret entries in hosts.' }
    @{ Pattern = '^Hosts file updated \(([^)]+)\)\. Backup: (.+)$'; ru = 'Файл hosts обновлён ($1). Резервная копия: $2'; en = 'Hosts file updated ($1). Backup: $2' }
    @{ Pattern = '^Hosts file not found - nothing to remove\.$'; ru = 'Файл hosts не найден — удалять нечего.'; en = 'Hosts file not found; nothing to remove.' }
    @{ Pattern = '^The managed zapret block is not present in hosts - nothing to remove\.$'; ru = 'Записей zapret в файле hosts нет — удалять нечего.'; en = 'No zapret entries were found in hosts; nothing to remove.' }
    @{ Pattern = '^The managed hosts markers are unbalanced\. Refusing to touch hosts - remove the stray marker line manually, then retry\.$'; ru = 'Метки записей zapret в hosts повреждены. Файл не изменён. Удалите лишнюю строку с меткой вручную и повторите попытку.'; en = 'The zapret markers in hosts are mismatched. The file was not changed. Remove the stray marker line manually, then try again.' }
    @{ Pattern = '^Dry run - would remove (\d+) line\(s\) of managed hosts entries\.$'; ru = 'Предварительная проверка: будет удалено строк с записями zapret — $1.'; en = 'Preview only: this would remove $1 zapret entry line(s).' }
    @{ Pattern = '^Managed hosts block removed\. Backup: (.+)$'; ru = 'Записи zapret удалены из hosts. Резервная копия: $1'; en = 'Zapret entries removed from hosts. Backup: $1' }
    @{ Pattern = '^(.+) This does not affect zapret operation\.$'; ru = '$1 Это не мешает работе zapret.'; en = '$1 This does not affect zapret.' }
    @{ Pattern = '^New version available: (.+) \(current: (.+)\)$'; ru = 'Доступна новая версия: $1 (установлена: $2).'; en = 'A new version is available: $1 (installed: $2).' }
    @{ Pattern = '^Download: (.+)$'; ru = 'Скачать обновление: $1'; en = 'Download the update: $1' }
    @{ Pattern = '^Latest version installed \((.+)\)\.$'; ru = 'У вас установлена последняя версия ($1).'; en = 'You have the latest version ($1).' }
    @{ Pattern = '^Active (discord|game) fake replaced with ''([^'']+)''\.$'; ru = 'Файл-фейк для $1 заменён на «$2».'; en = 'The active $1 fake file is now $2.' }
    @{ Pattern = '^Отчёт сохранён: (.+)$'; ru = 'Отчёт сохранён: $1'; en = 'Report saved to $1' }
    @{ Pattern = '^Report saved to (.+)$'; ru = 'Отчёт сохранён: $1'; en = 'Report saved to $1' }
    @{ Pattern = '^Check the connection to the test CDNs and the DPI-checker result; run "zapret\.ps1 diagnostics"\.$'; ru = 'Проверьте подключение к тестовым серверам и результат диагностики DPI. Затем выполните zapret.ps1 diagnostics.'; en = 'Check your connection to the test servers and the DPI check. Then run zapret.ps1 diagnostics.' }
    @{ Pattern = '^Check your internet connection and DNS \(enable DoH\), and run "zapret\.ps1 diagnostics"\.$'; ru = 'Проверьте интернет и DNS. Если нужно, включите DoH, затем выполните zapret.ps1 diagnostics.'; en = 'Check your internet connection and DNS. Enable DoH if needed, then run zapret.ps1 diagnostics.' }
    @{ Pattern = '^Best strategy for this PC: (.+) \((\d+)/(\d+) targets OK\)$'; ru = 'Подходящая стратегия: $1 (доступно целей: $2 из $3).'; en = 'Best strategy for this PC: $1 ($2 of $3 targets reachable).' }
    @{ Pattern = '^No strategy completed the full 64 KB TCP data-transfer check\. The current/previous bypass will be restored; no candidate will be installed\.$'; ru = 'Ни одна стратегия не передала все 64 КБ данных. Текущая стратегия будет восстановлена; новую устанавливать не буду.'; en = 'No strategy completed the 64 KB data transfer. The current strategy will be restored; no new one will be installed.' }
    @{ Pattern = '^No strategy could reach the Discord/YouTube endpoints from this PC\.$'; ru = 'Ни одна стратегия не смогла подключиться к проверочным адресам Discord и YouTube.'; en = 'No strategy could reach the Discord and YouTube test endpoints.' }
    @{ Pattern = '^Fast mode: no 100% candidate among installed/general/alt/fake-tls-auto - full ranking is used\.$'; ru = 'Быстрый режим: первые стратегии не прошли все проверки. Сравниваю полный список.'; en = 'Fast mode: the first candidates did not pass every check. Ranking all strategies.' }
    @{ Pattern = '^Current strategy ''([^'']+)'' passes (\d+)/(\d+) targets - keeping it\. winws\.exe was not restarted\.$'; ru = 'Текущая стратегия $1 открывает все проверочные адреса ($2 из $3). Оставляю её без перезапуска.'; en = 'Current strategy $1 reaches all test endpoints ($2/$3). Keeping it; winws.exe was not restarted.' }
    @{ Pattern = '^Current bypass passes only (\d+)/(\d+) targets - running the full benchmark\.\.\.$'; ru = 'Текущая стратегия открывает только $1 из $2 проверочных адресов. Запускаю полную проверку…'; en = 'The current bypass reaches only $1 of $2 test endpoints. Running the full benchmark…' }
    @{ Pattern = '^Best strategy for this PC: (.+) \((\d+)/(\d+) targets OK\)$'; ru = 'Подходящая стратегия: $1 (доступно целей: $2 из $3).'; en = 'Best strategy for this PC: $1 ($2 of $3 targets reachable).' }
    @{ Pattern = '^No reachable DoH provider with a measured response time was found\.$'; ru = 'Не удалось измерить скорость ни одного доступного DNS-провайдера.'; en = 'Could not measure the response time of any reachable DNS provider.' }
    @{ Pattern = '^Install/restore curl\.exe or check the network, then repeat the benchmark\.$'; ru = 'Установите или восстановите curl.exe, проверьте подключение и запустите проверку ещё раз.'; en = 'Install or restore curl.exe, check your connection, and run the test again.' }
    @{ Pattern = '^Fastest reachable provider: (.+) \(([\d.,]+) ms average, (.+); (.+)\)\.$'; ru = 'Самый быстрый доступный DNS: $1 (среднее время $2 мс, $3; адрес $4).'; en = 'Fastest reachable DNS provider: $1 (average $2 ms, $3; address $4).' }
    @{ Pattern = '^To apply it interactively, run: zapret\.ps1 dns doh (.+)$'; ru = 'Чтобы включить его, выполните: zapret.ps1 dns doh $1'; en = 'To enable it, run: zapret.ps1 dns doh $1' }
    @{ Pattern = '^Apply DoH provider ''([^'']+)'' now\? This saves a DNS rollback snapshot first\. \[y/N\]$'; ru = 'Включить DNS-провайдер «$1»? Сначала сохраню текущие настройки для отката. [д/Н]'; en = 'Enable DNS provider $1? Current settings will be backed up first. [y/N]' }
    @{ Pattern = '^No DNS settings were changed\.$'; ru = 'Настройки DNS не изменены.'; en = 'DNS settings were not changed.' }
    @{ Pattern = '^DNS for ''([^'']+)'' applied to (\d+) of (\d+) adapter\(s\): (.+) / (.+)$'; ru = 'DNS-провайдер $1 настроен на адаптерах: $2 из $3 ($4 и $5).'; en = 'DNS provider $1 set on $2 of $3 adapters ($4 and $5).' }
    @{ Pattern = '^Could not set DNS on: (.+)$'; ru = 'Не удалось изменить DNS на адаптерах: $1'; en = 'Could not change DNS on these adapters: $1' }
    @{ Pattern = '^DoH template registered in the OS \(encrypted upgrade preferred\)\.$'; ru = 'В Windows зарегистрирован шаблон защищённого DNS (DoH).'; en = 'The encrypted DNS (DoH) template is registered in Windows.' }
    @{ Pattern = '^This OS did not register the DoH template automatically \(Windows 11 is required for system DoH\)\.$'; ru = 'Windows не зарегистрировала шаблон DoH автоматически. Системный DoH поддерживается в Windows 11.'; en = 'Windows did not register the DoH template automatically. System DoH requires Windows 11.' }
    @{ Pattern = '^Enable DoH in the browser as well \(Chrome/Edge/Firefox\) - that alone bypasses DNS poisoning\.$'; ru = 'Также включите защищённый DNS в браузере (Chrome, Edge или Firefox) — это может решить проблему подмены DNS.'; en = 'You can also enable Secure DNS in Chrome, Edge, or Firefox to avoid DNS tampering in the browser.' }
    @{ Pattern = '^Restore previous DNS with: zapret\.ps1 dns rollback; use dns reset to switch to DHCP\.$'; ru = 'Чтобы отменить изменение, выполните zapret.ps1 dns rollback. Команда zapret.ps1 dns reset вернёт автоматический DNS.'; en = 'Undo this with zapret.ps1 dns rollback. Run zapret.ps1 dns reset to return to automatic DNS.' }
    @{ Pattern = '^DNS on all active adapters returned to automatic \(DHCP\)\.$'; ru = 'Для всех активных сетевых адаптеров восстановлены автоматические настройки DNS (DHCP).'; en = 'DNS is back to automatic (DHCP) on all active adapters.' }
    @{ Pattern = '^DNS settings restored on (\d+) adapter\(s\)\.$'; ru = 'Настройки DNS восстановлены на адаптерах: $1.'; en = 'DNS settings restored on $1 adapter(s).' }
    @{ Pattern = '^No DNS rollback snapshot was found\.$'; ru = 'Резервная копия DNS не найдена — восстановить прежние настройки не удалось.'; en = 'No DNS backup was found, so the previous settings could not be restored.' }
    @{ Pattern = '^DoH provider ''([^'']+)'' is not reachable \((.+)\) - your ISP may be blocking it\.$'; ru = 'DNS-провайдер $1 недоступен ($2). Возможно, доступ к нему блокирует провайдер интернета.'; en = 'DNS provider $1 is unreachable ($2). Your ISP may be blocking it.' }
    @{ Pattern = '^Probing fallback provider: (.+) \.\.\.$'; ru = 'Проверяю запасной DNS-провайдер: $1…'; en = 'Checking backup DNS provider: $1…' }
    @{ Pattern = '^Switch to ''([^'']+)'' instead\? \[Y/n\]$'; ru = 'Переключиться на запасной DNS «$1»? [д/н]'; en = 'Switch to the backup DNS provider $1? [Y/n]' }
    @{ Pattern = '^No console input available - keeping ''([^'']+)''\. Run ''dns doh (.+)'' to switch manually\.$'; ru = 'Нет доступа к вводу с клавиатуры — оставляю $1. Чтобы сменить вручную, выполните dns doh $2.'; en = 'No console input is available; keeping $1. To switch manually, run dns doh $2.' }
    @{ Pattern = '^Switching to fallback provider: (.+)$'; ru = 'Переключаюсь на запасной DNS: $1'; en = 'Switching to backup DNS provider: $1' }
    @{ Pattern = '^No DoH provider answers \(cloudflare, google, quad9, adguard, yandex\) - your ISP appears to block DoH entirely\.$'; ru = 'Ни один из пяти DNS-провайдеров не ответил. Возможно, провайдер интернета блокирует DoH.'; en = 'None of the five DNS providers responded. Your ISP may be blocking DoH.' }
    @{ Pattern = '^Enable Secure DNS in the browser \(Chrome/Edge/Firefox\) - that bypasses filtering at the browser level\.$'; ru = 'Включите защищённый DNS в браузере (Chrome, Edge или Firefox), чтобы он отправлял DNS-запросы напрямую.'; en = 'Enable Secure DNS in Chrome, Edge, or Firefox so the browser can send DNS requests directly.' }
    @{ Pattern = '^Could not probe the DoH endpoint \((.+)\) - continuing with ''([^'']+)''\.$'; ru = 'Не удалось проверить DoH-адрес ($1). Продолжаю с текущим провайдером $2.'; en = 'Could not test the DoH endpoint ($1). Continuing with the current provider, $2.' }
    @{ Pattern = '^DoH provider ''([^'']+)'' answered \((.+)\)\.$'; ru = 'DNS-провайдер $1 доступен ($2).'; en = 'DNS provider $1 responded ($2).' }
    @{ Pattern = '^Предыдущие DNS-настройки сохранены: (.+)$'; ru = 'Предыдущие настройки DNS сохранены для отката: $1'; en = 'Previous DNS settings saved for rollback: $1' }
    @{ Pattern = '^IPv4 MTU on ''([^'']+)'' set to (\d+)\.$'; ru = 'MTU IPv4 для подключения «$1» изменён на $2.'; en = 'IPv4 MTU for $1 set to $2.' }
    @{ Pattern = '^Network rollback partially failed: (.+)$'; ru = 'Не все сетевые настройки удалось восстановить: $1'; en = 'Some network settings could not be restored: $1' }
    @{ Pattern = '^Network settings restored: (.+)$'; ru = 'Восстановлены сетевые настройки: $1'; en = 'Restored network settings: $1' }
    @{ Pattern = '^Snapshot: (.+)$'; ru = 'Резервная копия: $1'; en = 'Backup: $1' }
    @{ Pattern = '^Network settings were restored, but the snapshot could not be archived: (.+)$'; ru = 'Сетевые настройки восстановлены, но не удалось переместить резервную копию: $1'; en = 'Network settings were restored, but the backup could not be archived: $1' }
    @{ Pattern = '^No network rollback snapshot was found\.$'; ru = 'Резервная копия сетевых настроек не найдена.'; en = 'No network settings backup was found.' }
    @{ Pattern = '^Automatic rollback also reported an error: (.+)$'; ru = 'При автоматическом откате возникла дополнительная ошибка: $1'; en = 'Automatic rollback reported an additional error: $1' }
    @{ Pattern = '^Network optimization applied: TcpAckFrequency/TCPNoDelay, multimedia scheduling, RSS\.$'; ru = 'Сетевые настройки для уменьшения задержки применены (TCP и RSS).'; en = 'Network settings to reduce latency have been applied (TCP and RSS).' }
    @{ Pattern = '^Rollback snapshot: (.+) \(revert with: zapret\.ps1 net-optimize -Revert\)$'; ru = 'Резервная копия сохранена: $1. Чтобы отменить изменения, выполните zapret.ps1 net-optimize -Revert.'; en = 'Backup saved to $1. To undo the changes, run zapret.ps1 net-optimize -Revert.' }
    @{ Pattern = '^No non-fragmenting reply was received for payloads 1200\.\.1472; MTU was not changed\.$'; ru = 'Не удалось определить MTU по ответам сети. Настройки не менял.'; en = 'Could not determine the MTU from network replies. No settings were changed.' }
    @{ Pattern = '^Maximum non-fragmenting payload: (\d+) bytes; recommended IPv4 MTU: (\d+) bytes\.$'; ru = 'Максимальный размер пакета без фрагментации: $1 байт. Рекомендуемый MTU IPv4: $2 байт.'; en = 'Largest packet without fragmentation: $1 bytes. Recommended IPv4 MTU: $2 bytes.' }
    @{ Pattern = '^Current MTU already matches the measured value\.$'; ru = 'Текущий MTU уже совпадает с найденным значением.'; en = 'The current MTU already matches the measured value.' }
    @{ Pattern = '^Non-interactive mode: not applying MTU\. Run mtu-check interactively to review and apply\.$'; ru = 'Настройку MTU не применял: запущен неинтерактивный режим. Запустите mtu-check вручную, чтобы проверить и применить значение.'; en = 'MTU was not changed in non-interactive mode. Run mtu-check interactively to review and apply the value.' }
    @{ Pattern = '^Apply MTU (\d+) to ''([^'']+)''\? A rollback snapshot will be saved first\. \[y/N\]$'; ru = 'Установить MTU $1 для подключения «$2»? Сначала сохраню копию настроек. [д/н]'; en = 'Set MTU $1 for $2? Current settings will be backed up first. [y/N]' }
    @{ Pattern = '^MTU was not changed\.$'; ru = 'MTU не изменён.'; en = 'MTU was not changed.' }
    @{ Pattern = '^MTU rollback snapshot: (.+)$'; ru = 'Резервная копия MTU: $1'; en = 'MTU backup: $1' }
    @{ Pattern = '^The weekly auto re-check is not scheduled\.$'; ru = 'Еженедельная автоматическая проверка не настроена.'; en = 'The weekly automatic re-check is not scheduled.' }
    @{ Pattern = '^Weekly auto re-check removed\.$'; ru = 'Еженедельная проверка удалена.'; en = 'Weekly re-check removed.' }
    @{ Pattern = '^Weekly auto re-check scheduled: every (.+) at (.+) \(SYSTEM\)\.$'; ru = 'Еженедельная проверка запланирована: $1 в $2 от имени SYSTEM.'; en = 'Weekly re-check scheduled for $1 at $2 as SYSTEM.' }
    @{ Pattern = '^If the current strategy still reaches everything, the task exits in seconds and winws\.exe is NOT restarted\.$'; ru = 'Если текущая стратегия работает, проверка завершится за несколько секунд и не будет перезапускать winws.exe.'; en = 'If the current strategy still works, the check exits within seconds without restarting winws.exe.' }
    @{ Pattern = '^The benchmark stops the bypass for ~2-5 minutes during the run\. Remove with: zapret\.ps1 schedule-autoselect disable$'; ru = 'При проверке обход будет временно остановлен примерно на 2–5 минут. Отключить задачу: zapret.ps1 schedule-autoselect disable'; en = 'The bypass pauses for about 2–5 minutes during testing. Disable the task with: zapret.ps1 schedule-autoselect disable' }
    @{ Pattern = '^Also update the hosts block and the IPSet list now\? \[Y/n\]$'; ru = 'Также сейчас обновить записи hosts и список IP? [д/н]'; en = 'Also update the hosts entries and IP list now? [Y/n]' }
    @{ Pattern = '^Skipped hosts/ipset setup \(run them later from the menu\)\.$'; ru = 'Настройку hosts и списка IP пропустил. Её можно выполнить позже из меню.'; en = 'Skipped the hosts and IP list setup. You can run it later from the menu.' }
    @{ Pattern = '^hosts: managed block installed/updated$'; ru = 'Записи zapret в файле hosts установлены или обновлены.'; en = 'Zapret entries in the hosts file installed or updated.' }
    @{ Pattern = '^hosts update failed: ([\s\S]+)$'; ru = 'Не удалось обновить файл hosts: $1'; en = 'Could not update the hosts file: $1' }
    @{ Pattern = '^IPSet: list updated$'; ru = 'Список IP обновлён.'; en = 'IP list updated.' }
    @{ Pattern = '^IPSet update failed: ([\s\S]+)$'; ru = 'Не удалось обновить список IP: $1'; en = 'Could not update the IP list: $1' }
    @{ Pattern = '^If sites still do not open, the problem is likely plain-DNS poisoning\. Try: zapret\.ps1 dns doh cloudflare$'; ru = 'Если сайты по-прежнему не открываются, попробуйте защищённый DNS: zapret.ps1 dns doh cloudflare'; en = 'If sites still do not open, try encrypted DNS: zapret.ps1 dns doh cloudflare' }
    @{ Pattern = '^Переношу папку (.+) -> (.+) \.\.\.$'; ru = 'Переношу папку из $1 в $2…'; en = 'Moving folder from $1 to $2…' }
    @{ Pattern = '^Папка перенесена в (.+)$'; ru = 'Папка перенесена: $1'; en = 'Folder moved to $1' }
    @{ Pattern = '^Служба ''zapret'' \(стратегия: (.+)\) по-прежнему указывает на старую папку\.$'; ru = 'Служба zapret по-прежнему ссылается на старую папку (стратегия: $1).'; en = 'The zapret service still points to the old folder (strategy: $1).' }
    @{ Pattern = '^В новой папке выполните: zapret\.ps1 install (.+)$'; ru = 'В новой папке переустановите службу: zapret.ps1 install $1'; en = 'In the new folder, reinstall the service: zapret.ps1 install $1' }
    @{ Pattern = '^Если включена еженедельная перепроверка, пересоздайте задачу: zapret\.ps1 schedule-autoselect disable; zapret\.ps1 schedule-autoselect enable$'; ru = 'Если настроена еженедельная проверка, пересоздайте задачу командами: zapret.ps1 schedule-autoselect disable; затем zapret.ps1 schedule-autoselect enable'; en = 'If weekly re-check is enabled, recreate the task with: zapret.ps1 schedule-autoselect disable, then zapret.ps1 schedule-autoselect enable' }
    @{ Pattern = '^DNS-кэш очищен\.$'; ru = 'Кэш DNS очищен.'; en = 'DNS cache cleared.' }
    @{ Pattern = '^Сейчас будет очищен системный DNS-кэш Windows\. Затем откройте нужный сайт или запустите игру; в кэш попадут только новые DNS-запросы\.$'; ru = 'Сейчас очищу кэш DNS Windows. Затем откройте нужный сайт или игру, чтобы в кэш попали свежие адреса.'; en = 'The Windows DNS cache will now be cleared. Open the site or game you need so its fresh DNS entries are cached.' }
    @{ Pattern = '^Откройте нужный сайт или запустите игру, затем нажмите Enter для просмотра DNS-кэша$'; ru = 'Откройте нужный сайт или игру, затем нажмите Enter, чтобы посмотреть кэш DNS'; en = 'Open the site or game, then press Enter to view the DNS cache' }
    @{ Pattern = '^Подходящие домены не найдены\. Попробуйте открыть сайт ещё раз, затем повторите поиск\.$'; ru = 'Новых доменов в кэше нет. Откройте нужный сайт ещё раз и повторите поиск.'; en = 'No matching domains were found in the cache. Open the site again and repeat the search.' }
    @{ Pattern = '^Найденные домены:$'; ru = 'Найденные домены:'; en = 'Domains found:' }
    @{ Pattern = '^Введите номера через запятую \(1,3,5\), диапазон \(1-3\), all или оставьте пустым для отмены$'; ru = 'Введите номера через запятую (например 1,3,5), диапазон (1-3), all — выбрать все; Enter — отмена'; en = 'Enter numbers separated by commas (1,3,5), a range (1-3), all to select every domain, or press Enter to cancel' }
    @{ Pattern = '^Добавление отменено\.$'; ru = 'Добавление доменов отменено.'; en = 'Adding domains was cancelled.' }
    @{ Pattern = '^Домен (.+) удалён: обход=(\d+), исключения=(\d+)\.$'; ru = 'Домен $1 удалён из списков: обход — $2, исключения — $3.'; en = 'Domain $1 removed from the lists: bypass list — $2, exclusions — $3.' }
    @{ Pattern = '^Домен (.+) в пользовательских списках не найден\.$'; ru = 'Домен $1 не найден в пользовательских списках.'; en = 'Domain $1 was not found in your lists.' }
    @{ Pattern = '^Пользовательские списки сайтов возвращены к исходным шаблонам; встроенные списки и IPSet не затронуты\.$'; ru = 'Ваши списки сайтов очищены. Встроенные списки и фильтр IP не изменены.'; en = 'Your site lists were cleared. Built-in lists and the IP filter were not changed.' }
    @{ Pattern = '^Пользовательские списки сайтов уже соответствуют исходным шаблонам\.$'; ru = 'Ваши списки сайтов уже пусты — изменений не требуется.'; en = 'Your site lists are already empty; no changes were needed.' }
    @{ Pattern = '^Код стратегии скопирован в буфер обмена\.$'; ru = 'Код стратегии скопирован.'; en = 'Strategy code copied to the clipboard.' }
    @{ Pattern = '^Буфер обмена недоступен; скопируйте строку из консоли\.$'; ru = 'Не удалось открыть буфер обмена. Скопируйте код стратегии прямо из окна.'; en = 'The clipboard is unavailable. Copy the strategy code from the console.' }
    @{ Pattern = '^Не удалось записать в буфер обмена; скопируйте строку из консоли\.$'; ru = 'Не удалось скопировать код. Выделите его в окне и скопируйте вручную.'; en = 'Could not copy the code. Select it in the console and copy it manually.' }
    @{ Pattern = '^Импортирована пользовательская стратегия ''([^'']+)''\.$'; ru = 'Стратегия «$1» добавлена.'; en = 'Strategy $1 imported.' }
    @{ Pattern = '^Создана пользовательская стратегия ''([^'']+)'' \(копия ''([^'']+)''\)\.$'; ru = 'Создана стратегия «$1» на основе «$2».'; en = 'Created strategy $1 from $2.' }
    @{ Pattern = '^Файл: (.+) \(не затирается обновлениями; настройка — через меню Clone Strategy\)$'; ru = 'Файл настроек: $1. Обновления его не затронут; изменить стратегию можно в меню «Создать или импортировать стратегию».'; en = 'Settings file: $1. Updates will not overwrite it. Edit the strategy from the Create or Import Strategy menu.' }
    @{ Pattern = '^(.+) -> (.+) у стратегии ''([^'']+)''\.$'; ru = 'Параметр $1 стратегии «$3» изменён на $2.'; en = 'Strategy $3: changed $1 to $2.' }
    @{ Pattern = '^ACTIVE_\*\.bin-фейки у ''([^'']+)'' заменены на ''([^'']+)''\.$'; ru = 'Файлы-фейки в стратегии «$1» заменены на «$2».'; en = 'Fake files in strategy $1 replaced with $2.' }
    @{ Pattern = '^Импортирована пользовательская стратегия ''([^'']+)''\.$'; ru = 'Стратегия «$1» импортирована.'; en = 'Imported strategy $1.' }
    @{ Pattern = '^Добавлен домен: (.+) -> lists\\+(.+)$'; ru = 'Домен $1 добавлен в список $2.'; en = 'Domain $1 added to the $2 list.' }
    @{ Pattern = '^(.+) уже есть в lists\\+(.+) - ничего не меняю\.$'; ru = 'Домен $1 уже есть в списке $2 — изменений не требуется.'; en = 'Domain $1 is already in $2; no changes were made.' }
    @{ Pattern = '^No active physical adapters found\.$'; ru = 'Активные физические сетевые адаптеры не найдены.'; en = 'No active physical network adapters were found.' }
    @{ Pattern = '^Could not restore the previous service: ([\s\S]+)$'; ru = 'Не удалось восстановить прежнюю службу: $1'; en = 'Could not restore the previous service: $1' }
    @{ Pattern = '^The test stopped a manually started winws\. Start it again with: (.+)$'; ru = 'Проверка остановила вручную запущенный winws.exe. Чтобы запустить его снова, выполните: $1'; en = 'The test stopped a manually started winws.exe. Start it again with: $1' }
    @{ Pattern = '^No changes were applied\.$'; ru = 'Изменения не применялись.'; en = 'No changes were applied.' }
    @{ Pattern = '^The weekly auto re-check is not scheduled\.$'; ru = 'Еженедельная проверка не настроена.'; en = 'The weekly re-check is not scheduled.' }
    @{ Pattern = '^Stopped and disabled: (.+) \(re-enable via services\.msc when needed\)$'; ru = 'Служба $1 остановлена и отключена. При необходимости включите её в окне «Службы» (services.msc).'; en = 'Service $1 stopped and disabled. Re-enable it in Services (services.msc) if needed.' }
    @{ Pattern = '^Removed service: (.+)$'; ru = 'Удалена служба: $1'; en = 'Removed service: $1' }
    @{ Pattern = '^Служба не переустанавливалась \(-NoInstall\)\.$'; ru = 'Служба не переустанавливалась (параметр -NoInstall).'; en = 'The service was not reinstalled (-NoInstall).' }
    @{ Pattern = '^Перенесён: (.+)$'; ru = 'Перенесён файл: $1'; en = 'Moved file: $1' }
    @{ Pattern = '^Перезаписанные файлы сохранены в (.+)$'; ru = 'Резервные копии заменённых файлов сохранены в $1'; en = 'Backups of replaced files were saved to $1' }
    @{ Pattern = '^Перенесено файлов: (\d+)$'; ru = 'Перенесено файлов: $1'; en = 'Files moved: $1' }
    @{ Pattern = '^Переустанавливаю службу на новую папку \(стратегия: (.+)\)\.\.\.$'; ru = 'Настраиваю службу для новой папки (стратегия: $1)…'; en = 'Reconfiguring the service for the new folder (strategy: $1)…' }
    @{ Pattern = '^Службу ''zapret'' переустановлена со стратегией (.+)$'; ru = 'Служба zapret настроена на стратегию $1.'; en = 'The zapret service is now using strategy $1.' }
    @{ Pattern = '^Службу переустановить не удалось: ([\s\S]+)$'; ru = 'Не удалось переустановить службу: $1'; en = 'Could not reinstall the service: $1' }
    @{ Pattern = '^Выполните вручную: zapret\.ps1 install (.+)$'; ru = 'Установите службу вручную: zapret.ps1 install $1'; en = 'Install the service manually: zapret.ps1 install $1' }
    @{ Pattern = '^Установленная ранее стратегия не найдена - служба не переустанавливалась\.$'; ru = 'Не нашёл прежнюю стратегию, поэтому службу не переустанавливал.'; en = 'The previous strategy was not found, so the service was not reinstalled.' }
    @{ Pattern = '^Если служба нужна, установите: zapret\.ps1 install <id>  \(см\. zapret\.ps1 list\)$'; ru = 'Чтобы установить службу, выберите стратегию командой zapret.ps1 list, затем выполните zapret.ps1 install <id>.'; en = 'To install the service, choose a strategy with zapret.ps1 list, then run zapret.ps1 install <id>.' }
    @{ Pattern = '^Откатывать нечего: в config\.json нет сохранённого снимка\.$'; ru = 'Резервной копии для отката нет.'; en = 'There is no saved backup to restore.' }
    @{ Pattern = '^Папка снимка не найдена: (.+)\. Очищаю запись в config\.json\.$'; ru = 'Папка резервной копии не найдена: $1. Удаляю устаревшую запись из настроек.'; en = 'Backup folder not found: $1. Removing the outdated entry from settings.' }
    @{ Pattern = '^Папка снимка находится вне [\s\S]+Откат отменён\.$'; ru = 'Резервная копия находится вне допустимой папки. Это может указывать на повреждённые настройки; откат отменён.'; en = 'The backup is outside the allowed folder. Settings may have been tampered with; rollback cancelled.' }
    @{ Pattern = '^Текущее состояние сохранено в (.+)$'; ru = 'Текущее состояние сохранено отдельно: $1'; en = 'Current state backed up separately to $1' }
    @{ Pattern = '^Служба не переустанавливалась \(не Windows\)\.$'; ru = 'Служба не переустанавливалась: эта операция доступна только в Windows.'; en = 'The service was not reinstalled; this operation is available only on Windows.' }
    @{ Pattern = '^Откат выполнен: (.+)$'; ru = 'Восстановлены файлы: $1'; en = 'Restored files: $1' }
    @{ Pattern = '^В снимке не оказалось файлов для восстановления \(но стратегия могла быть сохранена\)\.$'; ru = 'В резервной копии нет файлов для восстановления. Стратегия могла быть сохранена.'; en = 'The backup contains no files to restore. The strategy may still have been saved.' }
    @{ Pattern = '^Снимок: причина ''(.+)'', создан (.+)$'; ru = 'Резервная копия: $1; создана $2'; en = 'Backup: $1; created $2' }
    @{ Pattern = '^Не перезапущено\. Изменения вступят в силу после перезапуска службы\.$'; ru = 'Службу не перезапускал. Изменения вступят в силу при следующем запуске службы.'; en = 'The service was not restarted. Changes will take effect the next time it starts.' }
    @{ Pattern = '^Служба zapret перезапущена\.$'; ru = 'Служба zapret перезапущена.'; en = 'The zapret service has restarted.' }
    @{ Pattern = '^Не удалось перезапустить службу \(проверьте: sc\.exe query zapret\)\.$'; ru = 'Не удалось перезапустить службу. Проверьте её состояние командой sc.exe query zapret.'; en = 'Could not restart the service. Check its status with sc.exe query zapret.' }
    @{ Pattern = '^Папка .+ уже существует\. Удалите или переименуйте её, либо перенесите zapret вручную\.$'; ru = '$0'; en = '$0' }
    @{ Pattern = '^Код стратегии скопирован в буфер обмена\.$'; ru = 'Код стратегии скопирован в буфер обмена.'; en = 'Strategy code copied to the clipboard.' }
    @{ Pattern = '^Could not disable the proxy: ([\s\S]+)$'; ru = 'Не удалось отключить прокси: $1'; en = 'Could not disable the proxy: $1' }
    @{ Pattern = '^Diagnostics target Windows\. Running the platform-independent checks only\.$'; ru = 'Полная диагностика рассчитана на Windows. Сейчас выполню только проверки, доступные на этой системе.'; en = 'Full diagnostics are designed for Windows. Running only the checks available on this system.' }
    @{ Pattern = '^Диагностика завершена: (\d+) проверок пройдено, (\d+) предупреждений, (\d+) проблем$'; ru = 'Диагностика завершена: пройдено — $1, предупреждений — $2, проблем — $3.'; en = 'Diagnostics complete: $1 passed, $2 warnings, $3 problems.' }
    @{ Pattern = '^No Discord installations were found\.$'; ru = 'Установленные копии Discord не найдены.'; en = 'No Discord installations were found.' }
    @{ Pattern = '^APPDATA is not defined - cannot locate Discord installations\.$'; ru = 'Переменная APPDATA не задана — не могу найти папки Discord.'; en = 'APPDATA is not set, so Discord folders cannot be located.' }
    @{ Pattern = '^(.+) was closed\.$'; ru = 'Приложение $1 закрыто.'; en = 'Closed $1.' }
    @{ Pattern = '^Deleted (.+)$'; ru = 'Удалено: $1'; en = 'Deleted: $1' }
    @{ Pattern = '^Failed to delete (.+)$'; ru = 'Не удалось удалить: $1'; en = 'Could not delete: $1' }
    @{ Pattern = '^DNS settings were restored, but the snapshot could not be archived: ([\s\S]+)$'; ru = 'Настройки DNS восстановлены, но не удалось переместить копию: $1'; en = 'DNS settings were restored, but the backup could not be archived: $1' }
    @{ Pattern = '^DNS rollback partially failed \((\d+)/(\d+) adapters restored\): (.+)$'; ru = 'Не все настройки DNS удалось восстановить: $1 из $2 адаптеров. $3'; en = 'DNS rollback was incomplete: restored $1 of $2 adapters. $3' }
    @{ Pattern = '^Сетевые параметры|^Проверка завершена'; ru = '$0'; en = '$0' }
    @{ Pattern = '^No active physical adapters found\.$'; ru = 'Активные физические сетевые адаптеры не найдены.'; en = 'No active physical network adapters were found.' }
    @{ Pattern = '^Invalid fake name\.$'; ru = 'Недопустимое имя файла-фейка.'; en = 'Invalid fake file name.' }
    @{ Pattern = '^bin\\+(.+)\.bin не найден\.$'; ru = 'Файл bin\\$1.bin не найден.'; en = 'File bin\\$1.bin was not found.' }
    @{ Pattern = '^Стратегия ''([^'']+)'' не найдена в strategies-user\.json\. Сначала клонируйте: clone-strategy <base-id> <new-id>\.$'; ru = 'Пользовательская стратегия $1 не найдена. Сначала создайте её: zapret.ps1 clone-strategy <исходная> <новая>.'; en = 'User strategy $1 was not found. Create it first with: zapret.ps1 clone-strategy <base-id> <new-id>.' }
    @{ Pattern = '^В args стратегии ''([^'']+)'' нет ''([^'']+)'' - менять нечего\.$'; ru = 'У стратегии $1 нет параметра $2, поэтому изменить его нельзя.'; en = 'Strategy $1 has no $2 parameter to change.' }
    @{ Pattern = '^В args стратегии ''([^'']+)'' нет ACTIVE_\*\.bin-фейков - менять нечего\.$'; ru = 'В стратегии $1 не используются файлы ACTIVE_*.bin, поэтому заменять нечего.'; en = 'Strategy $1 does not use ACTIVE_*.bin files, so there is nothing to replace.' }
    @{ Pattern = '^Значение вне разумных пределов \(1\.\.100000\)\.$'; ru = 'Значение должно быть целым числом от 1 до 100000.'; en = 'Enter a whole number from 1 to 100000.' }
    @{ Pattern = '^Стратегия ''([^'']+)'' уже существует\. Выберите другое имя\.$'; ru = 'ID $1 уже используется. Выберите другое имя.'; en = 'The ID $1 is already in use. Choose another one.' }
    @{ Pattern = '^Стратегия ''([^'']+)'' уже есть в strategies-user\.json\. Выберите другое имя\.$'; ru = 'ID $1 уже есть в пользовательских стратегиях. Выберите другое имя.'; en = 'The ID $1 is already in your strategies. Choose another one.' }
    @{ Pattern = '^Базовая стратегия ''([^'']+)'' не найдена \(см\. zapret\.ps1 list\)\.$'; ru = 'Исходная стратегия $1 не найдена. Посмотрите доступные варианты: zapret.ps1 list.'; en = 'Base strategy $1 was not found. See available strategies with: zapret.ps1 list.' }
    @{ Pattern = '^Идентификатор ''([^'']+)'' не подходит: строчные латинские буквы, цифры и ''-'', первая — буква/цифра, 2-41 символ\.$'; ru = 'ID «$1» не подходит. Используйте 2–41 строчную латинскую букву, цифру или дефис; первый символ должен быть буквой или цифрой.'; en = 'ID $1 is invalid. Use 2–41 lowercase letters, numbers, or hyphens; start with a letter or number.' }
    @{ Pattern = '^Не удалось полностью выгрузить драйвер|^Пользовательская копия'; ru = '$0'; en = '$0' }
)

# Diagnostic findings are short and action-oriented; keep the technical names,
# but explain what the user should do.
$script:UiMessageRules += @(
    @{ Pattern = '^System clock comparison \(HTTPS Date header unavailable\)$'; ru = 'Не удалось сравнить системные часы со временем HTTPS'; en = 'Could not compare the system clock with HTTPS time' }
    @{ Pattern = '^System clock comparison \(HTTPS Date request failed\)$'; ru = 'Не удалось получить время с HTTPS-сервера'; en = 'Could not read the time from the HTTPS server' }
    @{ Pattern = '^System clock is within 2 minutes of HTTPS time \(difference: (-?\d+) sec\)$'; ru = 'Системное время совпадает со временем HTTPS (разница: $1 с)'; en = 'System clock is within 2 minutes of HTTPS time (difference: $1 sec)' }
    @{ Pattern = '^Системные часы (.+) примерно на (\d+) сек\. Неверное время может ломать TLS-подключения и DoH; проверьте дату, время и часовой пояс\.$'; ru = 'Часы компьютера отстают или спешат примерно на $2 с. Из-за неверного времени могут не работать защищённые подключения и DoH. Проверьте дату, время и часовой пояс.'; en = 'The system clock appears to be $1 by about $2 sec. Incorrect time can break secure connections and DoH. Check the date, time, and time zone.' }
    @{ Pattern = '^Install path contains Cyrillic characters\. If the bypass does not work, move zapret to a path like C:\zapret$'; ru = 'В пути к программе есть кириллица. Если обход не работает, перенесите папку, например, в C:\zapret.'; en = 'The install path contains Cyrillic. If the bypass does not work, move the folder to a path such as C:\zapret.' }
    @{ Pattern = '^Install path has no Cyrillic characters$'; ru = 'В пути к программе нет кириллицы'; en = 'The install path contains no Cyrillic characters' }
    @{ Pattern = '^Zapret is installed inside a OneDrive folder\. Move it elsewhere, e\.g\. C:\zapret$'; ru = 'Программа находится в папке OneDrive. Перенесите её, например, в C:\zapret.'; en = 'The tool is inside a OneDrive folder. Move it elsewhere, for example to C:\zapret.' }
    @{ Pattern = '^Not installed in OneDrive$'; ru = 'Папка программы не синхронизируется через OneDrive'; en = 'The tool is not installed in OneDrive' }
    @{ Pattern = '^bin\\winws\.exe found$'; ru = 'Файл bin\\winws.exe найден'; en = 'Found bin\\winws.exe' }
    @{ Pattern = '^bin\\winws\.exe NOT found\. Re-extract the archive completely\.$'; ru = 'Не найден bin\\winws.exe. Распакуйте архив полностью заново.'; en = 'bin\\winws.exe is missing. Re-extract the complete archive.' }
    @{ Pattern = '^WinDivert64\.sys found$'; ru = 'Драйвер WinDivert64.sys найден'; en = 'Found WinDivert64.sys' }
    @{ Pattern = '^WinDivert64\.sys NOT found\. The driver is required for the bypass\.$'; ru = 'Не найден WinDivert64.sys — этот драйвер нужен для работы обхода.'; en = 'WinDivert64.sys is missing. This driver is required for the bypass.' }
    @{ Pattern = '^Authenticode signature verification$'; ru = 'Проверка цифровых подписей файлов'; en = 'Checking file signatures' }
    @{ Pattern = '^BINARY TAMPERED: (.+) \((.+)\) - file was modified after signing\. Re-download from the official release page!$'; ru = 'Файл $1 изменён после подписания ($2). Скачайте архив заново с официальной страницы релизов.'; en = 'File $1 was changed after signing ($2). Download a fresh copy from the official releases page.' }
    @{ Pattern = '^Some binaries are not Authenticode-signed: (.+)\. Normal for unsigned builds - if in doubt, re-download from the official release page\.$'; ru = 'У этих файлов нет цифровой подписи: $1. Это бывает в неподписанных сборках. Если сомневаетесь, скачайте архив с официальной страницы релизов.'; en = 'These files are not digitally signed: $1. This is normal for unsigned builds. If unsure, download a fresh copy from the official releases page.' }
    @{ Pattern = '^All shipped binaries have valid Authenticode signatures$'; ru = 'Цифровые подписи всех файлов проверены'; en = 'All shipped files have valid digital signatures' }
    @{ Pattern = '^Base Filtering Engine is running$'; ru = 'Служба Base Filtering Engine работает'; en = 'Base Filtering Engine is running' }
    @{ Pattern = '^Base Filtering Engine is NOT running\. Start the BFE service - zapret cannot work without it\.$'; ru = 'Не работает служба Base Filtering Engine (BFE). Запустите её — без неё zapret не сможет работать.'; en = 'Base Filtering Engine (BFE) is not running. Start it; zapret needs this service.' }
    @{ Pattern = '^System proxy is enabled \((.+)\)\. Make sure it is valid, or disable it if you don''t use a proxy$'; ru = 'В Windows включён системный прокси ($1). Проверьте его настройки или выключите, если не используете.'; en = 'A Windows system proxy is enabled ($1). Check its settings or turn it off if you do not use one.' }
    @{ Pattern = '^System proxy is not enabled$'; ru = 'Системный прокси Windows выключен'; en = 'No Windows system proxy is enabled' }
    @{ Pattern = '^TCP timestamps are enabled$'; ru = 'Метки времени TCP включены'; en = 'TCP timestamps are enabled' }
    @{ Pattern = '^TCP timestamps could not be enabled automatically$'; ru = 'Не удалось автоматически включить метки времени TCP'; en = 'Could not enable TCP timestamps automatically' }
    @{ Pattern = '^Найдены активные глобальные IPv6-адреса \((\d+)\)\. Если фильтрация работает только по IPv4, часть трафика может обходить её через IPv6\.$'; ru = 'Найдены глобальные IPv6-адреса ($1). Если фильтр настроен только на IPv4, часть соединений может обходить его через IPv6.'; en = 'Found $1 global IPv6 addresses. If filtering is set up for IPv4 only, some connections may bypass it over IPv6.' }
    @{ Pattern = '^No preferred global IPv6 addresses found$'; ru = 'Активные глобальные IPv6-адреса не найдены'; en = 'No active global IPv6 addresses were found' }
    @{ Pattern = '^IPv6 Dual-Stack check \(Get-NetIPAddress unavailable\)$'; ru = 'Проверка IPv6 пропущена: команда Get-NetIPAddress недоступна'; en = 'IPv6 check skipped because Get-NetIPAddress is unavailable' }
    @{ Pattern = '^HVCI / WinDivert load check \(zapret service is not installed\)$'; ru = 'Проверка блокировки драйвера пропущена: служба zapret не установлена'; en = 'Driver-blocking check skipped because the zapret service is not installed' }
    @{ Pattern = '^WinDivert is not currently blocking the running winws\.exe process$'; ru = 'WinDivert не блокирует запущенный winws.exe'; en = 'WinDivert is not blocking the running winws.exe process' }
    @{ Pattern = '^HVCI / WinDivert load check \(registry value could not be read\)$'; ru = 'Не удалось прочитать настройки Windows для проверки блокировки драйвера'; en = 'Could not read the Windows setting used to check for driver blocking' }
    @{ Pattern = '^Служба zapret установлена, но winws\.exe не запущен\. «Целостность памяти» Windows \(HVCI\) может блокировать загрузку драйвера WinDivert64\.sys\.$'; ru = 'Служба zapret установлена, но winws.exe не запущен. Возможно, Windows блокирует драйвер WinDivert64.sys из-за функции «Целостность памяти» (HVCI).'; en = 'The zapret service is installed, but winws.exe is not running. Windows Memory Integrity (HVCI) may be blocking the WinDivert64.sys driver.' }
    @{ Pattern = '^HVCI is not reported as blocking WinDivert$'; ru = 'Windows не сообщает о блокировке драйвера WinDivert'; en = 'Windows does not report that WinDivert is blocked' }
    @{ Pattern = '^HVCI / WinDivert load check$'; ru = 'Проверка блокировки драйвера WinDivert'; en = 'WinDivert driver-blocking check' }
    @{ Pattern = '^AdGuard process found\. AdGuard can break Discord\. See (.+)$'; ru = 'Запущен AdGuard — он может мешать Discord. Подробнее: $1'; en = 'AdGuard is running and may interfere with Discord. Details: $1' }
    @{ Pattern = '^AdGuard is not running$'; ru = 'AdGuard не запущен'; en = 'AdGuard is not running' }
    @{ Pattern = '^Killer services found\. Killer conflicts with zapret: (.+)$'; ru = 'Обнаружены службы Killer, которые могут конфликтовать с zapret. Подробнее: $1'; en = 'Killer services were found and may conflict with zapret. Details: $1' }
    @{ Pattern = '^Killer not found$'; ru = 'Службы Killer не найдены'; en = 'Killer services were not found' }
    @{ Pattern = '^Intel Connectivity Network Service found\. It conflicts with zapret: (.+)$'; ru = 'Обнаружена служба Intel Connectivity Network Service, которая конфликтует с zapret. Подробнее: $1'; en = 'Intel Connectivity Network Service was found and conflicts with zapret. Details: $1' }
    @{ Pattern = '^Intel Connectivity Network Service not found$'; ru = 'Intel Connectivity Network Service не найдена'; en = 'Intel Connectivity Network Service was not found' }
    @{ Pattern = '^Check Point services found\. Check Point conflicts with zapret - uninstall it$'; ru = 'Обнаружены службы Check Point, конфликтующие с zapret. Удалите Check Point, если он вам не нужен.'; en = 'Check Point services were found and conflict with zapret. Uninstall Check Point if you do not need it.' }
    @{ Pattern = '^Check Point not found$'; ru = 'Службы Check Point не найдены'; en = 'Check Point services were not found' }
    @{ Pattern = '^SmartByte services found\. Uninstall SmartByte or disable it via services\.msc$'; ru = 'Обнаружены службы SmartByte. Удалите SmartByte или отключите его в окне «Службы» (services.msc).'; en = 'SmartByte services were found. Uninstall SmartByte or disable it in Services (services.msc).' }
    @{ Pattern = '^SmartByte not found$'; ru = 'Службы SmartByte не найдены'; en = 'SmartByte services were not found' }
    @{ Pattern = '^VPN/WireGuard/WARP detected - services: (.+); processes: (.+)$'; ru = 'Обнаружены VPN/WireGuard/WARP: службы — $1; процессы — $2.'; en = 'Detected VPN/WireGuard/WARP components: services — $1; processes — $2.' }
    @{ Pattern = '^Stopping VPN/WireGuard-related services \(read-only mode\)$'; ru = 'Остановка VPN-служб пропущена: включён режим только для чтения'; en = 'VPN services were not stopped because diagnostics are read-only' }
    @{ Pattern = '^Automatic stop skipped; no recognized VPN service name was found$'; ru = 'Автоматическая остановка пропущена: подходящие VPN-службы не найдены'; en = 'Automatic stop skipped because no recognized VPN service was found' }
    @{ Pattern = '^Skipping odd service name: (.+)$'; ru = 'Пропускаю необычное имя службы: $1'; en = 'Skipping an unusual service name: $1' }
    @{ Pattern = '^No VPN/WireGuard/WARP tooling detected$'; ru = 'Программы и службы VPN/WireGuard/WARP не найдены'; en = 'No VPN/WireGuard/WARP software or services were found' }
    @{ Pattern = '^WinINET proxy reset \(read-only mode\)$'; ru = 'Сброс прокси WinINET пропущен: режим только для чтения'; en = 'WinINET proxy reset skipped in read-only mode' }
    @{ Pattern = '^WinINET system proxy disabled \(current user\)$'; ru = 'Системный прокси WinINET выключен для текущего пользователя'; en = 'WinINET system proxy disabled for the current user' }
    @{ Pattern = '^Could not disable the proxy: (.+)$'; ru = 'Не удалось выключить прокси: $1'; en = 'Could not disable the proxy: $1' }
    @{ Pattern = '^WinHTTP proxy is configured \(netsh winhttp show proxy\)\. Usually irrelevant for zapret - leave it unless you use it deliberately\.$'; ru = 'Настроен прокси WinHTTP. Обычно он не влияет на zapret; не меняйте его, если не знаете, зачем он нужен.'; en = 'A WinHTTP proxy is configured. It usually does not affect zapret; leave it as is unless you set it intentionally.' }
    @{ Pattern = '^WinHTTP proxy: not configured$'; ru = 'Прокси WinHTTP не настроен'; en = 'No WinHTTP proxy is configured' }
    @{ Pattern = '^Encrypted DNS \(DoH\) is configured on this PC$'; ru = 'На компьютере настроен защищённый DNS (DoH)'; en = 'Encrypted DNS (DoH) is configured on this PC' }
    @{ Pattern = '^Secure DNS is not configured\. Enable DNS-over-HTTPS in the browser \(or Windows 11 encrypted DNS\), otherwise the bypass may not work$'; ru = 'Защищённый DNS не настроен. Включите DNS-over-HTTPS в браузере или настройте DoH в Windows 11 — иначе сайты могут не открываться.'; en = 'Secure DNS is not configured. Enable DNS-over-HTTPS in your browser or Windows 11; otherwise some sites may not load.' }
    @{ Pattern = '^BFE / proxy / TCP timestamps / AdGuard / conflicting software / DoH$'; ru = 'Проверки BFE, прокси, TCP, AdGuard, конфликтующих программ и защищённого DNS'; en = 'BFE, proxy, TCP, AdGuard, conflicting software, and Secure DNS checks' }
    @{ Pattern = '^Game filter is enabled - winws intercepts game traffic\. For the lowest ping keep it disabled \(zapret\.ps1 game-filter off\)\.$'; ru = 'Фильтр перехватывает игровой трафик и может увеличить задержку. Для минимального пинга отключите его: zapret.ps1 game-filter off.'; en = 'The filter intercepts game traffic and may increase latency. For the lowest ping, turn it off with: zapret.ps1 game-filter off.' }
    @{ Pattern = '^Game filter is disabled \(game traffic is not intercepted\)$'; ru = 'Игровой трафик не перехватывается'; en = 'Game traffic is not being intercepted' }
    @{ Pattern = '^Hosts file contains entries for youtube\.com or youtu\.be - this can break YouTube access$'; ru = 'В файле hosts найдены записи для YouTube. Они могут мешать доступу к сервису.'; en = 'The hosts file contains entries for YouTube that may block access.' }
    @{ Pattern = '^Hosts file has no YouTube overrides$'; ru = 'В файле hosts нет записей, меняющих адреса YouTube'; en = 'The hosts file does not override YouTube addresses' }
    @{ Pattern = '^Hosts file check$'; ru = 'Проверка файла hosts'; en = 'Hosts file check' }
    @{ Pattern = '^WinDivert service is active but winws\.exe is not running \(read-only mode - not touching it\)$'; ru = 'Служба WinDivert работает, а winws.exe остановлен. Ничего не меняю: включён режим только для чтения.'; en = 'WinDivert is running but winws.exe is stopped. No changes made in read-only mode.' }
    @{ Pattern = '^winws\.exe is not running but the WinDivert service is active\. Attempting to remove it\.\.\.$'; ru = 'winws.exe остановлен, но WinDivert работает. Пытаюсь остановить и удалить службу WinDivert…'; en = 'winws.exe is stopped but WinDivert is active. Attempting to stop and remove the service…' }
    @{ Pattern = '^Found conflicting service: GoodbyeDPI\. Stopping and removing it\.\.\.$'; ru = 'Найдена конфликтующая служба GoodbyeDPI. Останавливаю и удаляю её…'; en = 'Found the conflicting GoodbyeDPI service. Stopping and removing it…' }
    @{ Pattern = '^WinDivert cannot be deleted\. Check manually whether another bypass uses it$'; ru = 'Не удалось удалить службу WinDivert. Проверьте, не использует ли её другая программа обхода.'; en = 'Could not remove WinDivert. Check whether another bypass tool is using it.' }
    @{ Pattern = '^WinDivert removed$'; ru = 'Служба WinDivert удалена'; en = 'WinDivert service removed' }
    @{ Pattern = '^No WinDivert conflict \(winws and WinDivert are in a consistent state\)$'; ru = 'Конфликта WinDivert нет: состояния winws и драйвера согласованы'; en = 'No WinDivert conflict: winws and the driver are in a consistent state' }
    @{ Pattern = '^Conflicting bypass services found: (.+)$'; ru = 'Найдены службы других программ обхода: $1'; en = 'Found services from other bypass tools: $1' }
    @{ Pattern = '^Removal of conflicting services \(read-only mode\)$'; ru = 'Удаление конфликтующих служб пропущено: режим только для чтения'; en = 'Conflicting services were not removed in read-only mode' }
    @{ Pattern = '^No conflicting bypass services$'; ru = 'Конфликтующие службы обхода не найдены'; en = 'No conflicting bypass services were found' }
    @{ Pattern = '^Discord cache clear \(read-only mode\)$'; ru = 'Очистка кэша Discord пропущена: режим только для чтения'; en = 'Discord cache was not cleared in read-only mode' }
    @{ Pattern = '^APPDATA is not defined - cannot locate Discord installations\.$'; ru = 'Не задана переменная APPDATA — не могу найти папки Discord.'; en = 'APPDATA is not set, so Discord folders cannot be located.' }
    @{ Pattern = '^No Discord installations were found\.$'; ru = 'Установленные копии Discord не найдены.'; en = 'No Discord installations were found.' }
    @{ Pattern = '^Diagnostics complete: (\d+) passed, (\d+) warnings, (\d+) problems$'; ru = 'Диагностика завершена: пройдено — $1, предупреждений — $2, проблем — $3.'; en = 'Diagnostics complete: $1 passed, $2 warnings, $3 problems.' }
    @{ Pattern = '^HVCI / WinDivert load check \(registry value could not be read\)$'; ru = 'Настройку HVCI прочитать не удалось'; en = 'Could not read the HVCI setting' }
)

$script:UiMessageRules += @(
    @{ Pattern = '^Stop and DISABLE these recognized VPN/WireGuard services temporarily\?$'; ru = 'Временно остановить и отключить найденные службы VPN/WireGuard?'; en = 'Temporarily stop and disable the detected VPN/WireGuard services?' }
    @{ Pattern = '^Disable the WinINET system proxy \((.+)\) for the current user\?$'; ru = 'Выключить системный прокси WinINET ($1) для текущего пользователя?'; en = 'Turn off the WinINET system proxy ($1) for the current user?' }
    @{ Pattern = '^Remove these conflicting services\?$'; ru = 'Удалить найденные службы, конфликтующие с zapret?'; en = 'Remove the services that conflict with zapret?' }
    @{ Pattern = '^Clear the Discord cache \(Stable/PTB/Canary/Development\)\?$'; ru = 'Очистить кэш Discord (Stable/PTB/Canary/Development)?'; en = 'Clear the Discord cache for Stable, PTB, Canary, and Development?' }
)

$script:UiMessageRules += @(
    @{ Pattern = '^Benchmark produced no results\.$'; ru = 'Проверка не дала результатов. Проверьте подключение и попробуйте ещё раз.'; en = 'The benchmark returned no results. Check your connection and try again.' }
    @{ Pattern = '^Restoring the previous service \(strategy: (.+)\)\.\.\.$'; ru = 'Восстанавливаю прежнюю службу (стратегия: $1)…'; en = 'Restoring the previous service (strategy: $1)…' }
    @{ Pattern = '^Support bundle сохранён: (.+)$'; ru = 'Отчёт для поддержки сохранён: $1'; en = 'Support report saved to: $1' }
    @{ Pattern = '^Прикрепите этот архив к issue на GitHub - в нём всё, что просит шаблон бага\.$'; ru = 'Прикрепите этот ZIP к сообщению об ошибке на GitHub. В архиве собраны нужные для разбора сведения.'; en = 'Attach this ZIP to your GitHub issue. It contains the information needed to investigate the problem.' }
    @{ Pattern = '^В старой папке не нашлось файлов для переноса \(config\.json, \*-user\.txt, ipset-all\.txt, ACTIVE_\*\.bin\)\.$'; ru = 'В старой папке не найдены настройки или пользовательские файлы для переноса.'; en = 'No settings or user files were found to import from the old folder.' }
    @{ Pattern = '^Could not fetch the latest version\.txt from GitHub\.$'; ru = 'Не удалось получить сведения о версии с GitHub. Проверьте подключение и повторите попытку.'; en = 'Could not fetch the version information from GitHub. Check your connection and try again.' }
    @{ Pattern = '^No strategies found \(strategies\.json is empty\)\.$'; ru = 'Список стратегий пуст. Восстановите файл strategies.json и повторите попытку.'; en = 'The strategy list is empty. Restore strategies.json and try again.' }
    @{ Pattern = '^Administrator rights are required for this operation\. Run zapret\.bat \(or ''zapret\.ps1'' from an elevated console\)\.$'; ru = 'Для этой операции нужны права администратора. Запустите zapret.bat от имени администратора.'; en = 'Administrator rights are required. Run zapret.bat as an administrator.' }
    @{ Pattern = '^pause requires Windows\.$'; ru = 'Временно приостановить обход можно только в Windows.'; en = 'The bypass can only be paused on Windows.' }
    @{ Pattern = '^pause without minutes needs an interactive console; use pause <Minutes> instead\.$'; ru = 'Чтобы приостановить обход без таймера, запустите команду в интерактивном окне. Или укажите время: pause <Minutes>.'; en = 'To pause without a timer, run this command in an interactive console. Or set a duration: pause <Minutes>.' }
    @{ Pattern = '^auto-select requires Windows: it launches winws\.exe against this PC''s network\.$'; ru = 'Автоподбор работает только в Windows: он запускает winws.exe для проверки этой сети.'; en = 'Auto-select requires Windows because it runs winws.exe to test this network.' }
    @{ Pattern = '^dns status requires Windows\.$'; ru = 'Проверка DNS через эту команду доступна только в Windows.'; en = 'DNS status is available only on Windows.' }
    @{ Pattern = '^mtu-check requires Windows\.$'; ru = 'Проверка MTU доступна только в Windows.'; en = 'MTU checks are available only on Windows.' }
    @{ Pattern = '^Line quality check requires Windows\.$'; ru = 'Проверка качества соединения доступна только в Windows.'; en = 'Connection quality checks are available only on Windows.' }
    @{ Pattern = '^Usage: (.+)$'; ru = 'Использование: $1'; en = 'Usage: $1' }
    @{ Pattern = '^Invalid (TCP|UDP) port range ''([^'']+)''$'; ru = 'Неверный диапазон портов $1: «$2». Укажите число от 1 до 65535 или диапазон, например 1024-65535.'; en = 'Invalid $1 port range: $2. Enter a port from 1 to 65535 or a range such as 1024-65535.' }
    @{ Pattern = '^Unknown game-filter mode ''([^'']+)'' \(expected: off\|all\|tcp\|udp\)$'; ru = 'Неизвестный режим игрового фильтра: $1. Допустимые варианты: off, all, tcp или udp.'; en = 'Unknown game filter mode: $1. Use off, all, tcp, or udp.' }
    @{ Pattern = '^Unknown provider ''([^'']+)'' \(expected: cloudflare\|google\|quad9\|adguard\|yandex\)$'; ru = 'DNS-провайдер $1 не поддерживается. Выберите cloudflare, google, quad9, adguard или yandex.'; en = 'DNS provider $1 is not supported. Choose cloudflare, google, quad9, adguard, or yandex.' }
    @{ Pattern = '^Unknown dns sub-command ''([^'']+)'' \(expected: status\|benchmark\|doh\|reset\|rollback\)$'; ru = 'Неизвестная команда DNS: $1. Допустимо: status, benchmark, doh, reset или rollback.'; en = 'Unknown DNS command: $1. Use status, benchmark, doh, reset, or rollback.' }
    @{ Pattern = '^Unknown domain sub-command ''([^'']+)'' \(expected: add\|exclude\|remove\|list\)$'; ru = 'Неизвестная команда для сайтов: $1. Допустимо: add, exclude, remove или list.'; en = 'Unknown site-list command: $1. Use add, exclude, remove, or list.' }
    @{ Pattern = '^Unknown schedule-autoselect sub-command ''([^'']+)'' \(expected: enable\|disable\|status\)$'; ru = 'Неизвестная команда для расписания: $1. Допустимо: enable, disable или status.'; en = 'Unknown schedule command: $1. Use enable, disable, or status.' }
)

$script:UiMessageRules += @(
    @{ Pattern = '^Потери или джиттер уже до шлюза: проверьте Wi-Fi \(сигнал/помехи\) или кабель/порт Ethernet\.$'; ru = 'Потери начинаются уже между компьютером и роутером. Проверьте сигнал Wi-Fi или подключение кабеля Ethernet.'; en = 'Packet loss starts between your computer and router. Check the Wi-Fi signal or Ethernet cable.' }
    @{ Pattern = '^Расписание авто-подбора удалено\.$'; ru = 'Еженедельная проверка удалена.'; en = 'Weekly re-check removed.' }
    @{ Pattern = '^Остановка службы завершена\.$'; ru = 'Служба остановлена.'; en = 'Service stopped.' }
)

$script:UiMessageRules += @(
    @{ Pattern = '^Не удалось определить активную стратегию; пауза отменена, чтобы не потерять возможность возобновления\.$'; ru = 'Не удалось определить текущую стратегию. Пауза отменена, чтобы обход можно было безопасно возобновить.'; en = 'Could not identify the active strategy. Pause cancelled so the bypass can be resumed safely.' }
    @{ Pattern = '^Не удалось полностью остановить службу zapret\.$'; ru = 'Не удалось полностью остановить службу zapret. Проверьте права администратора и состояние службы.'; en = 'Could not stop the zapret service completely. Check administrator rights and the service status.' }
    @{ Pattern = '^Не удалось завершить все процессы winws\.exe\.$'; ru = 'Не удалось остановить все процессы winws.exe. Проверьте права администратора.'; en = 'Could not stop every winws.exe process. Check administrator rights.' }
    @{ Pattern = '^Служба zapret исчезла во время паузы\.$'; ru = 'Служба zapret исчезла во время паузы. Проверьте её состояние перед продолжением.'; en = 'The zapret service disappeared while paused. Check its status before continuing.' }
    @{ Pattern = '^Служба zapret не перешла в состояние Running\.$'; ru = 'Служба zapret не запустилась. Проверьте состояние службы и запустите диагностику.'; en = 'The zapret service did not start. Check its status and run diagnostics.' }
    @{ Pattern = '^Перенос в C:.*только на Windows\.$'; ru = 'Автоматический перенос в C:\zapret доступен только в Windows.'; en = 'Automatic relocation to C:\zapret is available only on Windows.' }
    @{ Pattern = '^winws\.exe сейчас запущен - файлы будут заблокированы\. Сначала удалите службу \(zapret\.ps1 uninstall\), затем повторите\.$'; ru = 'Сейчас запущен winws.exe, поэтому файлы заняты. Сначала остановите службу командой zapret.ps1 uninstall, затем повторите перенос.'; en = 'winws.exe is running, so the files are in use. Stop the service with zapret.ps1 uninstall, then retry the move.' }
    @{ Pattern = '^Исходная папка совпадает с текущей - нечего мигрировать\.$'; ru = 'Вы указали текущую папку. Переносить настройки не нужно.'; en = 'You selected the current folder. There is nothing to import.' }
    @{ Pattern = '^strategies-user\.json: у каждой стратегии обязательны поля id и args\.$'; ru = 'В strategies-user.json у каждой стратегии должны быть поля id и args.'; en = 'Each strategy in strategies-user.json must include id and args fields.' }
    @{ Pattern = '^Строка стратегии превышает лимит 16 КБ\.$'; ru = 'Код стратегии слишком длинный (максимум 16 КБ).'; en = 'The strategy code is too long (maximum 16 KB).' }
    @{ Pattern = '^Неизвестный формат обмена стратегией \(ожидается префикс zapret1:\)\.$'; ru = 'Неизвестный формат кода стратегии. Код должен начинаться с zapret1:.'; en = 'Unknown strategy code format. The code must start with zapret1:.' }
    @{ Pattern = '^Строка Base64 повреждена или превышает лимит 16 КБ\.$'; ru = 'Код повреждён или превышает лимит 16 КБ.'; en = 'The code is invalid or exceeds the 16 KB limit.' }
    @{ Pattern = '^Строка Base64 повреждена\.$'; ru = 'Код повреждён. Проверьте, что скопировали его целиком.'; en = 'The code is invalid. Check that you copied it in full.' }
    @{ Pattern = '^Сжатый payload превышает лимит 16 КБ\.$'; ru = 'Сжатые данные превышают допустимый размер 16 КБ.'; en = 'The compressed data exceeds the 16 KB limit.' }
    @{ Pattern = '^Распакованный payload превышает лимит 32 КБ\.$'; ru = 'Распакованные данные превышают допустимый размер 32 КБ.'; en = 'The uncompressed data exceeds the 32 KB limit.' }
    @{ Pattern = '^Не удалось распаковать payload \(неверный gzip/Base64\)\.$'; ru = 'Не удалось прочитать код стратегии: неверный формат сжатых данных.'; en = 'Could not read the strategy code: the compressed data is invalid.' }
    @{ Pattern = '^Payload содержит некорректный JSON\.$'; ru = 'В коде стратегии повреждены настройки (неверный JSON).'; en = 'The strategy code contains invalid settings (malformed JSON).' }
    @{ Pattern = '^Payload должен быть одним JSON-объектом\.$'; ru = 'Код стратегии должен содержать один объект настроек.'; en = 'The strategy code must contain a single settings object.' }
    @{ Pattern = '^Payload должен содержать только поля id, name, description и args\.$'; ru = 'В коде стратегии должны быть только поля id, name, description и args.'; en = 'The strategy code may contain only id, name, description, and args fields.' }
    @{ Pattern = '^Test utility not found at (.+)$'; ru = 'Не найден файл проверки стратегий: $1. Распакуйте архив заново.'; en = 'Strategy test utility not found: $1. Re-extract the archive.' }
    @{ Pattern = '^No PowerShell host found to run the test suite\.$'; ru = 'Не удалось найти PowerShell для запуска проверки.'; en = 'Could not find PowerShell to run the test utility.' }
    @{ Pattern = '^Required Windows system tool was not found: (.+)$'; ru = 'В Windows не найден нужный системный инструмент: $1'; en = 'Required Windows system tool not found: $1' }
    @{ Pattern = '^The zapret path contains a double-quote character - move the folder to a path without quotes\.$'; ru = 'В пути к папке zapret есть кавычка. Переместите её в папку без кавычек.'; en = 'The zapret folder path contains a quote. Move it to a path without quotes.' }
    @{ Pattern = '^Path contains a double-quote character - move zapret to a path without quotes\.$'; ru = 'В пути к папке zapret есть кавычка. Переместите программу в папку без кавычек.'; en = 'The zapret folder path contains a quote. Move it to a path without quotes.' }
    @{ Pattern = '^strategies\.json not found next to (.+)\. The archive may be corrupted - re-extract it\.$'; ru = 'Не найден strategies.json рядом с $1. Возможно, архив повреждён — распакуйте его заново.'; en = 'strategies.json is missing next to $1. The archive may be damaged; re-extract it.' }
    @{ Pattern = '^strategies\.json is not valid JSON: ([\s\S]+)$'; ru = 'В strategies.json повреждены данные: $1'; en = 'strategies.json contains invalid data: $1' }
    @{ Pattern = '^strategies\.json does not contain any strategies\.$'; ru = 'В strategies.json нет ни одной стратегии.'; en = 'strategies.json does not contain any strategies.' }
    @{ Pattern = '^No active physical network adapters found; DNS changes were not made\.$'; ru = 'Активные физические сетевые адаптеры не найдены. DNS не менял.'; en = 'No active physical network adapters were found. DNS was not changed.' }
    @{ Pattern = '^No active physical IPv4 adapters found; network settings were not changed\.$'; ru = 'Активные сетевые адаптеры IPv4 не найдены. Настройки сети не менял.'; en = 'No active IPv4 network adapters were found. Network settings were not changed.' }
    @{ Pattern = '^Use only one of -Enable or -Disable\.$'; ru = 'Укажите только один параметр: -Enable или -Disable.'; en = 'Use either -Enable or -Disable, not both.' }
    @{ Pattern = '^Specify -Enable or -Disable\.$'; ru = 'Укажите -Enable или -Disable.'; en = 'Specify -Enable or -Disable.' }
    @{ Pattern = '^Invalid -Time ''([^'']+)'' \(expected HH:mm, 00:00-23:59\)\.$'; ru = 'Неверное время «$1». Используйте формат ЧЧ:ММ, например 03:30.'; en = 'Invalid time $1. Use HH:mm, for example 03:30.' }
    @{ Pattern = '^powershell\.exe not found\.$'; ru = 'Не найден powershell.exe. Проверьте установку Windows PowerShell.'; en = 'powershell.exe was not found. Check the Windows PowerShell installation.' }
)

$script:UiMessageRules += @(
    @{ Pattern = '^Minutes must be a whole number from 1 to 1440\.$'; ru = 'Введите целое число минут от 1 до 1440.'; en = 'Enter a whole number of minutes from 1 to 1440.' }
    @{ Pattern = '^bin\\\\winws\.exe (?:was )?not found\. Make sure the archive was fully extracted\.$'; ru = 'Не найден bin\\winws.exe. Распакуйте архив полностью заново.'; en = 'bin\\winws.exe is missing. Re-extract the complete archive.' }
    @{ Pattern = '^Hosts file management is supported on Windows only\.$'; ru = 'Изменять файл hosts можно только в Windows.'; en = 'The hosts file can only be changed on Windows.' }
    @{ Pattern = '^Could not resolve the Windows system directory\.$'; ru = 'Не удалось определить системную папку Windows.'; en = 'Could not locate the Windows system folder.' }
    @{ Pattern = '^curl not found \(Windows 10\+ ships curl\.exe in System32\)\.$'; ru = 'Не найден curl.exe. В Windows 10 и новее он обычно находится в System32.'; en = 'curl.exe was not found. Windows 10 and later usually include it in System32.' }
    @{ Pattern = '^An adapter has an unexpected number of DNS servers; snapshot aborted\.$'; ru = 'У сетевого адаптера неожиданное число DNS-адресов. Изменения DNS отменены.'; en = 'A network adapter has an unexpected number of DNS servers. DNS changes were cancelled.' }
    @{ Pattern = '^Could not identify active adapter GUIDs; DNS changes were not made\.$'; ru = 'Не удалось определить активные сетевые адаптеры. DNS не менял.'; en = 'Could not identify the active network adapters. DNS was not changed.' }
    @{ Pattern = '^The network interface name contains unsupported characters\.$'; ru = 'В имени сетевого подключения есть неподдерживаемые символы.'; en = 'The network interface name contains unsupported characters.' }
    @{ Pattern = '^DNS rollback snapshot is outside the logs directory; restore cancelled\.$'; ru = 'Резервная копия DNS находится вне папки журналов. Восстановление отменено.'; en = 'The DNS backup is outside the logs folder. Restore cancelled.' }
    @{ Pattern = '^DNS rollback snapshot is unexpectedly large; restore cancelled\.$'; ru = 'Файл резервной копии DNS слишком большой. Восстановление отменено.'; en = 'The DNS backup file is unexpectedly large. Restore cancelled.' }
    @{ Pattern = '^DNS rollback snapshot has an unsupported format\.$'; ru = 'Формат резервной копии DNS не поддерживается.'; en = 'The DNS backup format is not supported.' }
    @{ Pattern = '^DNS rollback snapshot has an invalid adapter count\.$'; ru = 'В резервной копии DNS неверное число адаптеров.'; en = 'The DNS backup contains an invalid number of adapters.' }
    @{ Pattern = '^DNS rollback snapshot contains an incomplete adapter entry\.$'; ru = 'В резервной копии DNS есть неполная запись адаптера.'; en = 'The DNS backup contains an incomplete adapter entry.' }
    @{ Pattern = '^Invalid adapter GUID in snapshot\.$'; ru = 'В резервной копии указан неверный идентификатор адаптера.'; en = 'The backup contains an invalid adapter ID.' }
    @{ Pattern = '^DNS rollback snapshot contains a duplicate adapter\.$'; ru = 'В резервной копии DNS один адаптер указан дважды.'; en = 'The DNS backup contains a duplicate adapter.' }
    @{ Pattern = '^Invalid static DNS server list in snapshot\.$'; ru = 'В резервной копии неверный список DNS-серверов.'; en = 'The backup contains an invalid DNS server list.' }
    @{ Pattern = '^Invalid DNS server list in snapshot\.$'; ru = 'В резервной копии неверный список DNS-серверов.'; en = 'The backup contains an invalid DNS server list.' }
    @{ Pattern = '^Invalid DNS source in snapshot\.$'; ru = 'В резервной копии указан неверный источник DNS-настроек.'; en = 'The backup contains an invalid DNS configuration source.' }
    @{ Pattern = '^Invalid IPv4 DNS server in snapshot\.$'; ru = 'В резервной копии указан неверный IPv4-адрес DNS-сервера.'; en = 'The backup contains an invalid IPv4 DNS server address.' }
    @{ Pattern = '^Adapter (.+) is no longer present\.$'; ru = 'Сетевой адаптер $1 больше не подключён.'; en = 'Network adapter $1 is no longer present.' }
    @{ Pattern = '^DoH probe failed for all providers \(cloudflare, google, quad9, adguard, yandex\)\.$'; ru = 'Ни один DNS-провайдер не ответил. Проверьте интернет и повторите проверку.'; en = 'None of the DNS providers responded. Check your connection and try again.' }
    @{ Pattern = '^Could not resolve the active IPv4 interface from the default route\.$'; ru = 'Не удалось определить активное IPv4-подключение. Проверьте подключение к сети.'; en = 'Could not identify the active IPv4 connection. Check your network connection.' }
    @{ Pattern = '^The active IPv4 route returned an invalid gateway address\.$'; ru = 'Сеть вернула неверный адрес шлюза. Проверьте подключение к роутеру.'; en = 'The network returned an invalid gateway address. Check your router connection.' }
    @{ Pattern = '^Could not determine the MTU of the active IPv4 interface\.$'; ru = 'Не удалось прочитать MTU сетевого подключения. Настройки не изменял.'; en = 'Could not read the network interface MTU. No settings were changed.' }
    @{ Pattern = '^The active interface returned an invalid IPv4 MTU\.$'; ru = 'Сетевой адаптер вернул неверное значение MTU.'; en = 'The network adapter returned an invalid MTU value.' }
    @{ Pattern = '^Could not query the current RSS state with netsh\.$'; ru = 'Не удалось проверить состояние RSS через netsh.'; en = 'Could not read the current RSS state using netsh.' }
    @{ Pattern = '^Could not determine the current RSS state; no network changes were made\.$'; ru = 'Не удалось определить состояние RSS. Настройки сети не менял.'; en = 'Could not determine the RSS state. Network settings were not changed.' }
    @{ Pattern = '^Refusing to write outside the approved network registry values\.$'; ru = 'Изменение сетевых настроек отменено: запрошен недопустимый параметр реестра.'; en = 'Network change refused because it targeted an unapproved registry value.' }
    @{ Pattern = '^A network rollback snapshot must contain at least one restorable value\.$'; ru = 'В резервной копии нет сетевых настроек для восстановления.'; en = 'The backup contains no network settings to restore.' }
    @{ Pattern = '^Refusing to save an unexpected network registry path/value\.$'; ru = 'Не удалось сохранить резервную копию: обнаружен неизвестный параметр сети.'; en = 'Could not save the backup because it contains an unknown network setting.' }
    @{ Pattern = '^Unsupported registry value type in network snapshot\.$'; ru = 'В резервной копии указан неподдерживаемый тип сетевой настройки.'; en = 'The backup contains an unsupported network setting type.' }
    @{ Pattern = '^Invalid RSS state for rollback snapshot\.$'; ru = 'В резервной копии указано неверное состояние RSS.'; en = 'The backup contains an invalid RSS state.' }
    @{ Pattern = '^Network snapshot contains an incomplete registry entry\.$'; ru = 'В резервной копии сети есть неполная запись параметра.'; en = 'The network backup contains an incomplete setting entry.' }
    @{ Pattern = '^Network snapshot contains an unapproved registry path/value\.$'; ru = 'В резервной копии найден неподдерживаемый параметр сети.'; en = 'The network backup contains an unapproved setting.' }
    @{ Pattern = '^Network snapshot contains an invalid registry value\.$'; ru = 'В резервной копии найдено неверное значение сетевого параметра.'; en = 'The network backup contains an invalid setting value.' }
    @{ Pattern = '^Network rollback snapshot contains too many registry entries\.$'; ru = 'В резервной копии слишком много параметров сети.'; en = 'The network backup contains too many settings.' }
    @{ Pattern = '^Network rollback snapshot contains no restorable values\.$'; ru = 'В резервной копии нет параметров для восстановления.'; en = 'The backup contains no settings to restore.' }
    @{ Pattern = '^Invalid interface index\.$'; ru = 'Неверный номер сетевого адаптера.'; en = 'Invalid network interface index.' }
    @{ Pattern = '^MTU must be in the range 576\.\.65535\.$'; ru = 'MTU должен быть от 576 до 65535.'; en = 'MTU must be between 576 and 65535.' }
    @{ Pattern = '^Network rollback snapshot is outside logs or has an invalid name; restore cancelled\.$'; ru = 'Резервная копия сети находится вне допустимой папки или имеет неверное имя. Восстановление отменено.'; en = 'The network backup is outside the allowed folder or has an invalid name. Restore cancelled.' }
    @{ Pattern = '^schtasks could not delete the task\.$'; ru = 'Не удалось удалить задачу планировщика Windows.'; en = 'Could not delete the Windows scheduled task.' }
    @{ Pattern = '^schtasks could not create the task \(run as Administrator\)\.$'; ru = 'Не удалось создать задачу. Запустите программу от имени администратора и повторите попытку.'; en = 'Could not create the task. Run the tool as an administrator and try again.' }
    @{ Pattern = '^Clear-DnsClientCache is unavailable on this Windows installation\.$'; ru = 'Эта версия Windows не поддерживает очистку DNS-кэша.'; en = 'This Windows installation does not support clearing the DNS cache.' }
    @{ Pattern = '^Get-DnsClientCache is unavailable on this Windows installation\.$'; ru = 'Эта версия Windows не поддерживает чтение DNS-кэша.'; en = 'This Windows installation does not support reading the DNS cache.' }
    @{ Pattern = '^Network optimization failed; rollback was attempted\. ([\s\S]+)$'; ru = 'Не удалось применить сетевые настройки. Программа попыталась отменить изменения. Подробности: $1'; en = 'Network optimization failed. The tool attempted to roll back the changes. Details: $1' }
)

$script:UiMessageRules += @(
    @{ Pattern = '^LogDir cannot be empty\.$'; ru = 'Не удалось определить папку журналов.'; en = 'The log folder could not be determined.' }
    @{ Pattern = '^Invalid interface MTU rollback data\.$'; ru = 'В резервной копии указаны неверные данные MTU.'; en = 'The backup contains invalid MTU data.' }
    @{ Pattern = '^Network rollback snapshot is unexpectedly large; restore cancelled\.$'; ru = 'Резервная копия сети слишком большая. Восстановление отменено.'; en = 'The network backup is unexpectedly large. Restore cancelled.' }
    @{ Pattern = '^Network rollback snapshot has an unsupported format\.$'; ru = 'Формат резервной копии сети не поддерживается.'; en = 'The network backup format is not supported.' }
    @{ Pattern = '^Network snapshot contains an invalid RSS state\.$'; ru = 'В резервной копии указано неверное состояние RSS.'; en = 'The backup contains an invalid RSS state.' }
    @{ Pattern = '^Network snapshot contains invalid MTU rollback data\.$'; ru = 'В резервной копии указаны неверные данные MTU.'; en = 'The backup contains invalid MTU data.' }
)

$script:UiMessageRules += @(
    @{ Pattern = '^bin\\\\winws\.exe not found\. Re-extract the archive\.$'; ru = 'Не найден bin\\winws.exe. Распакуйте архив заново.'; en = 'bin\\winws.exe was not found. Re-extract the archive.' }
)
# Compile once at import time; diagnostics can emit many messages in quick succession.
foreach ($rule in $script:UiMessageRules) {
    $rule.Regex = New-Object System.Text.RegularExpressions.Regex -ArgumentList @(
        [string]$rule.Pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function ConvertTo-UiMessage {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text -or $Text.Length -eq 0) { return $Text }
    $language = if ($script:UiLanguage -in @('ru','en')) { $script:UiLanguage } else { 'ru' }
    foreach ($rule in $script:UiMessageRules) {
        if ($rule.Regex -and $rule.Regex.IsMatch($Text)) {
            return $rule.Regex.Replace($Text, [string]$rule[$language])
        }
    }
    return $Text
}
