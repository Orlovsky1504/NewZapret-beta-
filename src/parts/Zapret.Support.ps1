# ---------------------------------------------------------------------------
# Support bundle - one ZIP with everything a bug report needs
#   (diagnostics, dns status, status, config, latest auto-select report,
#    latest log) on the user's Desktop - for attaching to GitHub issues
# ---------------------------------------------------------------------------

function ConvertTo-SupportBundleSafeText {
    <# Redacts common personal identifiers and credentials from text before public sharing. #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [string]$InstallPath = $script:Root
    )
    if ($null -eq $Text) { return '' }
    $safe = $Text

    if ($InstallPath -and $InstallPath.Length -ge 4) {
        $safe = [regex]::Replace($safe, [regex]::Escape($InstallPath), '<INSTALL_PATH>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $profilePaths = @($env:USERPROFILE, $env:HOME)
    try { $profilePaths += [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) } catch { }
    foreach ($profilePath in @($profilePaths | Where-Object { $_ -and $_.Length -ge 4 } | Select-Object -Unique)) {
        $safe = [regex]::Replace($safe, [regex]::Escape([string]$profilePath), '<USER_HOME>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\Users\\[^\\/\s"''<>]+', 'C:\Users\<redacted>')
    $safe = [regex]::Replace($safe, '(?i)(?<![A-Za-z0-9._-])/(?:home|Users)/[^/\s"''<>]+', '/home/<redacted>')
    $safe = [regex]::Replace($safe, '(?i)(https?://)[^/@\s:]+:[^/@\s]+@', '$1<redacted>@')
    $safe = [regex]::Replace($safe, '(?im)(\bAuthorization\s*:\s*Bearer\s+)[^\s,;]+', '$1<redacted>')
    $safe = [regex]::Replace($safe, '(?i)([?&](?:token|secret|key|password|auth|access_token)=)[^&\s]+', '$1<redacted>')
    $safe = [regex]::Replace($safe, '(?im)(\b(?:password|passwd|token|secret|api[_-]?key|access[_-]?token|client[_-]?secret)\b\s*["'']?\s*[:=]\s*["'']?)[^"''\s,;}&]+', '$1<redacted>')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '<EMAIL>')
    $safe = [regex]::Replace($safe, '(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])', '<MAC>')

    $knownResolvers = @('1.1.1.1','1.0.0.1','8.8.8.8','8.8.4.4','9.9.9.9','149.112.112.112','94.140.14.14','94.140.15.15','77.88.8.8','77.88.8.1')
    $octet = '(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'
    $ipv4Pattern = "(?<![0-9.])$octet\.$octet\.$octet\.$octet(?![0-9.])"
    $ipv4Matches = [regex]::Matches($safe, $ipv4Pattern)
    for ($index = $ipv4Matches.Count - 1; $index -ge 0; $index--) {
        $match = $ipv4Matches[$index]
        if ($match.Value -notin $knownResolvers) { $safe = $safe.Remove($match.Index, $match.Length).Insert($match.Index, '<IPv4>') }
    }
    $ipv6Pattern = '(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![0-9a-f:])'
    $ipv6Matches = [regex]::Matches($safe, $ipv6Pattern)
    for ($index = $ipv6Matches.Count - 1; $index -ge 0; $index--) {
        $match = $ipv6Matches[$index]
        $parsedAddress = $null
        if ([Net.IPAddress]::TryParse($match.Value, [ref]$parsedAddress) -and $parsedAddress.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
            $safe = $safe.Remove($match.Index, $match.Length).Insert($match.Index, '<IPv6>')
        }
    }
    return $safe
}

function Get-DesktopPath {
    try {
        $d = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
        if ($d -and (Test-Path -LiteralPath $d)) { return $d }
    } catch { }
    if ($env:USERPROFILE) {
        $d = Join-Path $env:USERPROFILE 'Desktop'
        if (Test-Path -LiteralPath $d) { return $d }
    }
    if ($env:HOME) { return $env:HOME }
    return (Get-Location).Path
}

function Get-SupportBundlePlan {
    [CmdletBinding()]
    param([string]$DestinationPath, [switch]$IncludeSensitive)
    if (-not $DestinationPath) { $DestinationPath = Get-DesktopPath }
    $files = @('diagnostics.txt','dns-status.txt','status.txt','config.json','auto-select-latest.txt','zapret-latest.log','system.txt','privacy-report.txt','README.txt')
    if ($IncludeSensitive -and (Test-Path -LiteralPath $script:UserStrategiesFile)) { $files += 'strategies-user.json' }
    return [pscustomobject]@{
        Preview = $true
        DestinationPath = $DestinationPath
        PrivacyMode = if ($IncludeSensitive) { 'unredacted' } else { 'redacted' }
        Files = @($files)
        CustomStrategiesIncluded = [bool]($IncludeSensitive -and (Test-Path -LiteralPath $script:UserStrategiesFile))
    }
}

function New-SupportBundle {
    [CmdletBinding()]
    param(
        # Directory where the final ZIP is created. Defaults to the user's Desktop.
        [string]$DestinationPath,
        # Explicitly include unredacted config, custom strategies, paths and diagnostics.
        [switch]$IncludeSensitive,
        # Show the exact planned contents without creating files or collecting data.
        [switch]$Preview
    )
    if (-not $DestinationPath) { $DestinationPath = Get-DesktopPath }
    $plan = Get-SupportBundlePlan -DestinationPath $DestinationPath -IncludeSensitive:$IncludeSensitive
    if ($Preview) {
        Write-Host ("Support bundle preview ({0} mode): {1}" -f $plan.PrivacyMode, $plan.DestinationPath)
        $plan.Files | ForEach-Object { Write-Host ("  - {0}" -f $_) }
        Write-PreviewInfo 'Preview only: no bundle or diagnostic files were created.'
        return $plan
    }
    $privacyMode = if ($IncludeSensitive) { 'UNREDACTED - review carefully before sharing' } else { 'share-safe default with redaction' }
    Write-Host ("Support bundle contents ({0}): {1}" -f $plan.PrivacyMode, $plan.DestinationPath)
    $plan.Files | ForEach-Object { Write-Host ("  - {0}" -f $_) }
    if ($IncludeSensitive) { Write-Host 'Sensitive mode is enabled: paths, network identifiers, config and custom strategies may be included.' -ForegroundColor Yellow }
    else { Write-Host 'Default privacy mode masks common identifiers and omits custom strategies-user.json.' -ForegroundColor DarkGray }

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    $destFull = (Resolve-Path -LiteralPath $DestinationPath).Path

    $staging = Join-Path ([IO.Path]::GetTempPath()) ('zapret-support-{0}' -f ([Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $writeUtf8 = {
        param([string]$Name, [string]$Content)
        if (-not $IncludeSensitive) { $Content = ConvertTo-SupportBundleSafeText -Text $Content -InstallPath $script:Root }
        [IO.File]::WriteAllText((Join-Path $staging $Name), $Content, (New-Object System.Text.UTF8Encoding($false)))
    }
    $copyTextFile = {
        param([string]$SourcePath, [string]$Name)
        $content = [IO.File]::ReadAllText($SourcePath)
        & $writeUtf8 $Name $content
    }
    $capture = {
        param([scriptblock]$Block)
        try { return (& $Block *>&1 | Out-String) } catch { return "ERROR: $($_.Exception.Message)" }
    }

    Write-Info2 ("Collecting diagnostics and preparing the ZIP; privacy mode: {0}." -f $privacyMode)
    if ($IncludeSensitive) {
        Write-Warn2 'Sensitive mode is enabled: user paths, network identifiers, config and custom strategies may be included.'
    } else {
        Write-Info2 'The default redaction filter is best-effort; review the finished archive before sharing.'
    }
    $privacyReport = @(
        'Support bundle privacy report',
        ('Mode: {0}' -f $privacyMode),
        $(if ($IncludeSensitive) { 'No redaction was applied. Review every file before sharing.' } else { 'Redacted: install/user paths, private IP addresses, IPv6 addresses, MAC addresses, e-mail addresses, URL credentials and common token/password fields.' }),
        $(if ($IncludeSensitive) { 'Custom strategies: included when present.' } else { 'Custom strategies: omitted to protect custom domains and strategy details.' }),
        'This automated filter is best-effort. Review the archive before posting it publicly.'
    )
    & $writeUtf8 'privacy-report.txt' (($privacyReport -join "`r`n") + "`r`n")

    Write-Host (Get-UiText -Russian '  Собираю данные для диагностики…' -English '  Collecting diagnostic information…') -ForegroundColor DarkGray

    # 1) Diagnostics - READ-ONLY: support-bundle must never change the system
    $diag = & $capture { Invoke-Diagnostics -ReadOnly }
    & $writeUtf8 'diagnostics.txt' $diag

    # 2) DNS / DoH status per adapter
    $dns = & $capture { Write-DnsStatus }
    & $writeUtf8 'dns-status.txt' $dns

    # 3) Service / filter status (built here; zapret.ps1 has the pretty-print version)
    $statusLines = New-Object System.Collections.Generic.List[string]
    try {
        $svc = Get-ZapretServiceInfo
        [void]$statusLines.Add(('zapret service: {0} (strategy: {1})' -f $svc.State, $(if ($svc.Strategy) { $svc.Strategy } else { 'n/a' })))
        [void]$statusLines.Add(('WinDivert service: {0}' -f $svc.WinDivertState))
        [void]$statusLines.Add(('winws.exe running: {0}' -f $(if ($svc.WinwsRunning) { 'yes' } else { 'no' })))
    } catch { [void]$statusLines.Add(("service info unavailable: {0}" -f $_.Exception.Message)) }
    try {
        [void]$statusLines.Add(('IPSet: {0}' -f (Get-IpsetState)))
        $game = Get-GameFilterPorts
        [void]$statusLines.Add(('Game filter: {0} (tcp={1}, udp={2})' -f $game.status, $game.tcp, $game.udp))
        $cfg = Get-Config
        [void]$statusLines.Add(('Auto-update check: {0}' -f $(if ($cfg.checkUpdates) { 'enabled' } else { 'disabled' })))
    } catch { [void]$statusLines.Add(("filter status unavailable: {0}" -f $_.Exception.Message)) }
    [void]$statusLines.Add(('Install path: {0}' -f $script:Root))
    [void]$statusLines.Add(('zapret version: {0}' -f (Get-LocalVersion)))
    & $writeUtf8 'status.txt' (($statusLines -join "`r`n") + "`r`n")

    # 4) config.json - redact file paths/credentials unless the user explicitly opts out.
    if (Test-Path -LiteralPath $script:ConfigPath) {
        if ($IncludeSensitive) {
            Copy-Item -LiteralPath $script:ConfigPath -Destination (Join-Path $staging 'config.json') -Force
        } else {
            & $copyTextFile $script:ConfigPath 'config.json'
        }
    } else {
        & $writeUtf8 'config.json' "config.json not found at $script:ConfigPath (defaults apply)`r`n"
    }

    # 4b) Custom strategies can contain private domain lists. Include only by explicit opt-in.
    if ($IncludeSensitive -and (Test-Path -LiteralPath $script:UserStrategiesFile)) {
        Copy-Item -LiteralPath $script:UserStrategiesFile -Destination (Join-Path $staging 'strategies-user.json') -Force
    }

    # 5) Latest auto-select report
    $autoSelect = $null
    if (Test-Path -LiteralPath $script:LogDir) {
        $autoSelect = Get-ChildItem -LiteralPath $script:LogDir -Filter 'auto-select-*.txt' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($autoSelect) {
        & $copyTextFile $autoSelect.FullName 'auto-select-latest.txt'
    } else {
        & $writeUtf8 'auto-select-latest.txt' "No auto-select report found (run 'zapret.ps1 auto-select' first).`r`n"
    }

    # 6) Latest log file
    $logFile = $null
    if (Test-Path -LiteralPath $script:LogDir) {
        $logFile = Get-ChildItem -LiteralPath $script:LogDir -Filter 'zapret-*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($logFile) {
        & $copyTextFile $logFile.FullName 'zapret-latest.log'
    } else {
        & $writeUtf8 'zapret-latest.log' "No log file found in $script:LogDir yet.`r`n"
    }

    # 7) System information (no user name / no network identifiers)
    $sysLines = New-Object System.Collections.Generic.List[string]
    try { [void]$sysLines.Add(('OS: {0}' -f [Environment]::OSVersion.VersionString)) } catch { }
    if ($script:OnWindows) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            [void]$sysLines.Add(('Windows: {0} (build {1})' -f $os.Caption, $os.BuildNumber))
        } catch { }
    }
    [void]$sysLines.Add(('PowerShell: {0}' -f $PSVersionTable.PSVersion.ToString()))
    [void]$sysLines.Add(('Runtime: {0}' -f [Environment]::Version.ToString()))
    [void]$sysLines.Add(('64-bit process: {0}' -f [Environment]::Is64BitProcess))
    [void]$sysLines.Add(('Administrator: {0}' -f (Test-IsAdmin)))
    [void]$sysLines.Add(('Install path: {0}' -f $script:Root))
    & $writeUtf8 'system.txt' (($sysLines -join "`r`n") + "`r`n")

    # 8) Human readme for the issue author
    $readme = @(
        'zapret-discord-youtube - support bundle',
        ('Собрано: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        '',
        'Что внутри:',
        '  diagnostics.txt       - полный вывод Run Diagnostics (только чтение, ничего не менял)',
        '  dns-status.txt        - DNS по каждому сетевому адаптеру',
        '  status.txt            - служба zapret, winws, IPSet, Game Filter',
        '  config.json           - настройки; в безопасном режиме пути и секреты маскируются',
        '  auto-select-latest.txt- последний отчёт auto-select (если запускался)',
        '  zapret-latest.log     - последний лог работы (в безопасном режиме фильтруется)',
        '  system.txt            - версия Windows и PowerShell',
        '  privacy-report.txt    - режим обработки и список автоматически маскируемых данных',
        '',
        'Как отправить:',
        '  1. Откройте issue: https://github.com/Flowseal/zapret-discord-youtube/issues/new/choose',
        '  2. Прикрепите этот ZIP к сообщению (кнопка скрепки).',
        '  3. Опишите проблему: что не открывается, с какой стратегией, что пробовали.',
        '',
        'По умолчанию применяется фильтрация персональных идентификаторов; она может быть неполной.',
        'Для полного неотредактированного архива используйте zapret.ps1 support-bundle -IncludeSensitive.',
        'Перед публичной отправкой всегда проверьте содержимое ZIP и privacy-report.txt.'
    )
    if ($IncludeSensitive -and (Test-Path -LiteralPath $script:UserStrategiesFile)) {
        $readme += '  strategies-user.json  - пользовательские стратегии и домены (неотредактированные)'
    } else {
        $readme += 'Custom strategies-user.json is omitted in the default privacy-safe mode.'
    }
    & $writeUtf8 'README.txt' (($readme -join "`r`n") + "`r`n")

    $zipName = 'zapret-support-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff')
    $zipPath = Join-Path $destFull $zipName
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw "Support bundle already exists; refusing to overwrite $zipPath"
    }
    try {
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw "Не удалось создать $zipPath : $($_.Exception.Message)"
    }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Support bundle сохранён: $zipPath"
    Write-Info2 'Прикрепите этот архив к issue на GitHub - в нём всё, что просит шаблон бага.'
    Write-Log "Support bundle created: $zipPath"
    return $zipPath
}
