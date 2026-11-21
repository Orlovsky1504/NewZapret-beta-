#requires -Version 4.0
<#
.SYNOPSIS
    zapret-discord-youtube - TUI and CLI for the zapret DPI bypass.

.DESCRIPTION
    Double-click zapret.bat for the interactive menu, or use the CLI:

      zapret.ps1 list                          List available strategies
      zapret.ps1 run <id>                      Start a strategy in the background
      zapret.ps1 install <id>                  Install a strategy as an autostart service
      zapret.ps1 uninstall [-RemoveHostsBlock] Remove services; flag also removes hosts block without prompting
      zapret.ps1 status                        Show current status
      zapret.ps1 test                          Run the connectivity test suite
      zapret.ps1 diagnostics                   Run environment checks ("doctor")
      zapret.ps1 auto-select [-Install] [-NoInteractive] [-Deep] [-CheckFreeze] [-Fast] [-Scheduled] [-TimeoutSec N]  Benchmark strategies
      zapret.ps1 auto-setup [-Carrier mts|megafon|tele2|yota] [-Fast] [-Deep] [-CheckFreeze] [-Install] [-NoInteractive] [-EnableSchedule]  Guided setup; asks regular/mobile and carrier
      zapret.ps1 auto-select -Carrier <mts|megafon|tele2|yota> [-Fast]        Test a narrow mobile-carrier profile
      zapret.ps1 pause [Minutes]             Temporarily stop and restore the bypass
      zapret.ps1 export-strategy <id>         Export a strategy as zapret1: Base64
      zapret.ps1 import-strategy <payload> [-NewId <id>]  Safely import a strategy
      zapret.ps1 dns status | dns doh <cloudflare|google|quad9|adguard|yandex> | dns reset | dns rollback
      zapret.ps1 dns benchmark              Benchmark five DoH endpoints and offer the fastest
      zapret.ps1 net-optimize [-Revert]      Apply latency tweaks or restore the saved snapshot
      zapret.ps1 mtu-check                   Measure path MTU and optionally apply it
      zapret.ps1 ping-test                   Measure loss/jitter to gateway, Cloudflare and Discord
      zapret.ps1 domain add|exclude|remove <domain> | domain list
      zapret.ps1 discover-domains             Discover domains from the Windows DNS cache
      zapret.ps1 rollback                    Restore the previous strategy/ipset/hosts snapshot
      zapret.ps1 clone-strategy <base> <id>  Clone a strategy into strategies-user.json
      zapret.ps1 schedule-autoselect <enable|disable|status>
      zapret.ps1 health-check                Probe every bypass endpoint once (read-only)
      zapret.ps1 doctor [-Fix] [-Deep]       Installation self-check (files, versions, driver, lists)
      zapret.ps1 voice-check [check|fix|next-fake]  Discord voice: diagnose, auto-repair, or cycle the voice fake (5000 ms ping)
      zapret.ps1 fallback [status|on|off]    Verified backup strategies: watchdog failover ladder
      zapret.ps1 watchdog [run|enable|disable|status]  Автозащита: periodic health checks + gated auto-heal
      zapret.ps1 profile [all|discord-only|youtube-only|no-whatsapp]  Narrow the bypass to chosen services
      zapret.ps1 speed-test                   Measure download speed through the current bypass
      zapret.ps1 site-check <url|domain>      Where a site flows (lists/profile) and does it load
      zapret.ps1 tray-autostart [enable|disable|status]  Start Zapret-Tray.exe with Windows
      zapret.ps1 support-bundle [-IncludeSensitive]  Create a redacted diagnostics ZIP (opt-in removes redaction)
      zapret.ps1 import-config <path|zip> [-NoInstall]  Migrate config/lists from an old install or an export zip
      zapret.ps1 export-config [path]          Pack settings/lists into a zip (restorable via import-config)
      zapret.ps1 ipset [loaded|none|any]       Show or switch the IPSet filter
      zapret.ps1 ipset-update                  Download the latest IPSet list
      zapret.ps1 hosts-update [-DryRun]        Install the recommended hosts entries
      zapret.ps1 check-updates [-Soft] [-OpenBrowser]   Check for a newer version
      zapret.ps1 game-filter <off|all|tcp|udp> [-TcpPorts X] [-UdpPorts Y]
      zapret.ps1 fakes <discord|game> <fake-name>   Replace an active UDP fake
      zapret.ps1 menu                          Interactive menu (default)
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Action = 'menu',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    [string]$TcpPorts,
    [string]$UdpPorts,
    [string]$Mode,
    [string]$HostsPath,
    [string]$NewId,
    [ValidateSet('mts','megafon','tele2','yota')][string]$Carrier,
    [switch]$DryRun,
    [switch]$Preview,
    [switch]$IncludeSensitive,
    [switch]$Soft,
    [switch]$OpenBrowser,
    [switch]$NoInteractive,
    [switch]$Install,
    [switch]$Deep,
    [switch]$CheckFreeze,
    [switch]$Fix,
    [switch]$Fast,
    [switch]$Scheduled,
    [int]$TimeoutSec = 0,
    [switch]$EnableSchedule,
    [switch]$NoInstall,
    [switch]$RemoveHostsBlock,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Build a safe Windows command line for a Start-Process relaunch. Windows
# requires backslashes before quotes (and trailing backslashes inside quotes)
# to be doubled according to the CommandLineToArgvW rules.
function ConvertTo-WindowsCommandLineArgument {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) { $Value = '' }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount++
            continue
        }
        if ($character -eq [char]34) {
            for ($i = 0; $i -lt (2 * $backslashCount + 1); $i++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append([char]34)
        } else {
            for ($i = 0; $i -lt $backslashCount; $i++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append($character)
        }
        $backslashCount = 0
    }
    for ($i = 0; $i -lt (2 * $backslashCount); $i++) {
        [void]$builder.Append([char]92)
    }
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Get-ZapretRestartArgumentLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string[]]$RemainingArguments,
        [System.Collections.IDictionary]$BoundParameters
    )

    $commandArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, $Action)
    if ($null -ne $RemainingArguments -and $RemainingArguments.Count -gt 0) {
        $commandArguments += $RemainingArguments
    }
    if ($null -ne $BoundParameters) {
        foreach ($parameterName in $BoundParameters.Keys) {
            if ($parameterName -in @('Action', 'Rest')) { continue }
            $parameterValue = $BoundParameters[$parameterName]
            if ($parameterValue -is [System.Management.Automation.SwitchParameter]) {
                if ($parameterValue.IsPresent) { $commandArguments += ('-{0}' -f $parameterName) }
            } else {
                $commandArguments += ('-{0}' -f $parameterName)
                $commandArguments += [string]$parameterValue
            }
        }
    }

    $quotedArguments = @()
    foreach ($commandArgument in $commandArguments) {
        $quotedArguments += ConvertTo-WindowsCommandLineArgument -Value ([string]$commandArgument)
    }
    return ($quotedArguments -join ' ')
}

$root = $PSScriptRoot
$modulePath = Join-Path $root 'src\Zapret.psm1'
if (-not (Test-Path $modulePath)) {
    Write-Host 'Не найден модуль src\Zapret.psm1. Распакуйте архив заново. / Missing src\Zapret.psm1. Please extract the archive again.' -ForegroundColor Red
    exit 1
}
Import-Module $modulePath -Force
$script:UiLanguage = Get-UiLanguage

function T {
    param([Parameter(Mandatory = $true)][string]$Russian, [Parameter(Mandatory = $true)][string]$English)
    return (Get-UiText -Russian $Russian -English $English -Language $script:UiLanguage)
}

function Set-InterfaceLanguage {
    param([Parameter(Mandatory = $true)][ValidateSet('ru','en')][string]$Language)
    try {
        [void](Set-UiLanguage -Language $Language)
        $script:UiLanguage = $Language
        return $true
    } catch {
        Write-Host (T ("Не удалось сохранить язык интерфейса: {0}" -f $_.Exception.Message) ("Could not save the interface language: {0}" -f $_.Exception.Message)) -ForegroundColor Red
        return $false
    }
}

function Write-UiError {
    param([Parameter(Mandatory = $true)][string]$Message)
    $localizedMessage = ConvertTo-UiMessage -Text $Message
    Write-Host (T ("  Не удалось выполнить действие: {0}" -f $localizedMessage) ("  Could not complete the action: {0}" -f $localizedMessage)) -ForegroundColor Red
}

# Launch-path sanity check: non-ASCII / spaces / OneDrive break winws.exe.
$scriptOnWindowsEarly = $true
if ($PSVersionTable.PSVersion.Major -ge 6) { $scriptOnWindowsEarly = [bool]$IsWindows }
$pathIssues = @()
try { $pathIssues = @(Test-ZapretInstallPath -Path $root) } catch { }
if ($pathIssues.Count -gt 0) {
    Write-Host ''
    Write-Host (T '  Путь к папке zapret может мешать запуску:' '  The zapret folder path may prevent the tool from starting:') -ForegroundColor Yellow
    foreach ($issue in $pathIssues) {
        $uiIssue = switch -Exact ($issue) {
            'путь пуст' { T 'не удалось определить путь к папке' 'the folder path could not be determined' }
            'путь содержит не-ASCII символы (например, кириллицу)' { T 'в пути есть кириллица или другие неанглийские символы' 'the path contains non-English characters' }
            'путь содержит спецсимволы' { T 'в пути есть специальные символы' 'the path contains special characters' }
            'путь содержит пробелы' { T 'в пути есть пробелы' 'the path contains spaces' }
            'папка находится внутри OneDrive (синхронизация ломает файлы обхода)' { T 'папка находится в OneDrive; синхронизация может повредить рабочие файлы' 'the folder is inside OneDrive; syncing may interfere with the tool files' }
            default { $issue }
        }
        Write-Host ("    - {0}" -f $uiIssue) -ForegroundColor Yellow
    }
    Write-Host (T '  В пути есть кириллица, пробел или спецсимвол. winws.exe может из-за этого не запуститься.' '  The path has Cyrillic, spaces, or special characters. winws.exe may fail to start.') -ForegroundColor Yellow
    Write-Host (T '  Рекомендуемая папка: C:\zapret' '  Recommended folder: C:\zapret') -ForegroundColor Yellow
    if ($scriptOnWindowsEarly -and -not $NoInteractive -and $Action -notin @('help', 'list', 'version')) {
        if (Test-IsAdmin) {
            $moveAnswer = $null
            $unsafeArgs = ($Action -match '["`]') -or ($Rest | Where-Object { $_ -match '["`]' })
            try { if (-not $unsafeArgs) { $moveAnswer = Read-Host (T '  Перенести папку в C:\zapret и запустить программу оттуда? [д/н]' '  Move the folder to C:\zapret and restart from there? [Y/n]') } } catch { }
            if ($moveAnswer -and ($moveAnswer.Trim() -match '^(y|yes|д|да)$')) {
                try {
                    $newRoot = Move-ZapretToRoot -Source $root -Target 'C:\zapret'
                    $psExe = Get-WindowsSystemToolPath -Name 'powershell.exe'
                    $restartArgs = Get-ZapretRestartArgumentLine -ScriptPath (Join-Path $newRoot 'zapret.ps1') -Action $Action -RemainingArguments $Rest -BoundParameters $PSBoundParameters
                    Start-Process -FilePath $psExe -ArgumentList $restartArgs | Out-Null
                    exit 0
                } catch {
                    Write-UiError ("Не удалось перенести папку: $($_.Exception.Message)")
                    Write-Host (T '  Продолжаю из текущей папки.' '  Continuing from the current folder.') -ForegroundColor DarkGray
                }
            }
        } else {
            Write-Host (T '  Запустите zapret.bat от имени администратора, чтобы программа могла перенести папку сама.' '  Run zapret.bat as administrator so the tool can move the folder automatically.') -ForegroundColor Yellow
        }
    }
    Write-Host ''
}

# Log rotation: keep logs\ bounded (14 days / 20 files)
try {
    $rotatedLogs = Invoke-LogRotation
    if ($rotatedLogs -gt 0) { Write-Log "Log rotation: removed $rotatedLogs file(s) from logs\" }
} catch { }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Invoke-ClearScreen {
    try { [System.Console]::Clear() } catch { Write-Host ("`n" * 25) }
}

function Show-Banner {
    $svc = Get-ZapretServiceInfo
    $strategyText = if ($svc.Strategy) { $svc.Strategy } else { T 'не выбрана' 'not selected' }
    $ipset = Get-IpsetState
    $ipsetColor = switch ($ipset) { 'any' { 'Yellow' } 'loaded' { 'Green' } 'none' { 'Gray' } default { 'Red' } }

    Write-Host ''
    Write-Host ((T "   МЕНЕДЖЕР ZAPRET v{0}" "   ZAPRET MANAGER v{0}") -f (Get-LocalVersion)) -ForegroundColor Cyan
    Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
    Write-Host ((T "   Стратегия: {0}" "   Strategy: {0}") -f $strategyText) -NoNewline -ForegroundColor Gray
    if ($svc.Installed) {
        $stateRaw = [string]$svc.State
        $serviceColor = switch ($stateRaw.ToUpperInvariant()) { 'RUNNING' { 'Green' } 'STOPPED' { 'Red' } default { 'Yellow' } }
        $state = switch ($stateRaw.ToUpperInvariant()) {
            'RUNNING' { T 'работает' 'running' }
            'STOPPED' { T 'остановлена' 'stopped' }
            default   { $stateRaw }
        }
        Write-Host (T '   [служба: ' '   [service: ') -NoNewline -ForegroundColor DarkGray
        Write-Host $state -NoNewline -ForegroundColor $serviceColor
        Write-Host ']' -ForegroundColor DarkGray
    } else {
        Write-Host (T '   [служба не установлена]' '   [service not installed]') -ForegroundColor DarkGray
    }
    $uiIpset = switch ($ipset) {
        'any'     { T 'все адреса (могут не открываться сайты)' 'all addresses (may affect sites)' }
        'loaded'  { T 'список загружен' 'list loaded' }
        'none'    { T 'фильтр отключён' 'filter off' }
        default   { T 'состояние неизвестно' 'state unknown' }
    }
    Write-Host (T '   Фильтр IP: ' '   IP filter: ') -NoNewline -ForegroundColor DarkGray
    Write-Host $uiIpset -ForegroundColor $ipsetColor
    Write-Host ''
}

function Read-MenuChoice {
    param([string]$Prompt = $null)
    if ([string]::IsNullOrWhiteSpace($Prompt) -or $Prompt -eq '   Select option') { $Prompt = T '   Выберите пункт' '   Choose an option' }
    $answer = Read-Host $Prompt
    if ($null -eq $answer) { return '0' }  # stdin closed (non-interactive) -> behave like "back/exit"
    return $answer.Trim()
}

function Pause-Menu {
    Write-Host ''
    try { [void](Read-Host (T '   Нажмите Enter, чтобы продолжить' '   Press Enter to continue')) } catch { }
}

function Get-UiStrategyDescription {
    param([Parameter(Mandatory = $true)]$Strategy)
    if ($script:UiLanguage -eq 'ru') {
        switch ([string]$Strategy.id) {
            'general'             { return 'Основной вариант. Начните с него; если не поможет, попробуйте альтернативы.' }
            'alt'                 { return 'Альтернатива с другим способом обработки соединений.' }
            'alt2'                { return 'Вариант основной стратегии с другими параметрами обработки трафика.' }
            'alt3'                { return 'Альтернатива с подменой имени сайта в тестовом соединении.' }
            'alt4'                { return 'Альтернатива с другим порядком обработки пакетов.' }
            'alt5'                { return 'Упрощённая стратегия для отдельных TCP-подключений.' }
            'alt6'                { return 'Основная стратегия с другим шаблоном обработки TLS-соединений.' }
            'alt7'                { return 'Вариант с разделением данных в другой позиции.' }
            'alt8'                { return 'Лёгкая подмена без дополнительного перекрытия пакетов.' }
            'alt9'                { return 'Вариант с подменой имени сайта; может подойти на отдельных сетях.' }
            'alt10'               { return 'Альтернатива с другими тестовыми данными.' }
            'alt11'               { return 'Альтернатива с другим шаблоном для сайтов и голосового чата.' }
            'alt12'               { return 'Альтернатива, настроенная в том числе для Discord.' }
            'alt13'               { return 'Вариант с дополнительной подменой имени сайта.' }
            'exp'                 { return 'Экспериментальная стратегия. Попробуйте её, если обычные варианты не подошли.' }
            'fake-tls-auto'       { return 'Автоматическая TLS-подмена, вариант 1.' }
            'fake-tls-auto-alt'   { return 'Автоматическая TLS-подмена, вариант 2.' }
            'fake-tls-auto-alt2'  { return 'Автоматическая TLS-подмена, вариант 3.' }
            'fake-tls-auto-alt3'  { return 'Автоматическая TLS-подмена, вариант 4.' }
            'carrier-mts'         { return 'Узкий вариант ALT11 для списка YouTube, Discord и WhatsApp; проверяйте на сети МТС.' }
            'carrier-megafon'     { return 'Узкий экспериментальный вариант EXP для списка мобильных сервисов; проверяйте на сети МегаФон.' }
            'carrier-tele2'       { return 'Узкий вариант ALT6 для списка мобильных сервисов; проверяйте на сети Tele2/T2.' }
            'carrier-yota'        { return 'Узкий вариант TLS ALT3 для списка мобильных сервисов; экспериментальный кандидат для Йоты.' }
            'simple-fake'         { return 'Простой вариант подмены для начала проверки.' }
            'simple-fake-alt'     { return 'Простая подмена с другими тестовыми данными.' }
            'simple-fake-alt2'    { return 'Простая подмена для обычного трафика и игр.' }
            default               { return 'Пользовательская стратегия.' }
        }
    }
    switch ([string]$Strategy.id) {
        'general'             { return 'Baseline: TCP multisplit, a Google/4PDA TLS pattern, and fake QUIC. Usually the first strategy to try.' }
        'alt'                 { return 'Alternative using fake + fakedsplit; often works on providers where the baseline does not.' }
        'alt2'                { return 'Baseline multisplit with different split parameters (split-pos=2, seqovl=652).' }
        'alt3'                { return 'TLS host-fake split with Google/Yandex host substitution and modified TLS fakes.' }
        'alt4'                { return 'Fake + multisplit with bad-sequence fooling.' }
        'alt5'                { return 'Minimal IPv4 setup using SYN data and multi-disorder for selected TCP ports.' }
        'alt6'                { return 'Baseline multisplit using the Google TLS pattern for every sequence overlap.' }
        'alt7'                { return 'Multisplit + SYN data with a split at the SNI extension.' }
        'alt8'                { return 'Fake without sequence overlap; uses bad-sequence fooling.' }
        'alt9'                { return 'Host-fake split using Google and Ozon host names.' }
        'alt10'               { return 'Fake + timestamp fooling with Google, 4PDA, and STUN fakes.' }
        'alt11'               { return 'Fake + multisplit using the Sferum pattern and extra QUIC repeats.' }
        'alt12'               { return 'Multisplit plus host-fake split for Discord-related domains.' }
        'alt13'               { return 'Multisplit with host-fake split for Google and general traffic.' }
        'exp'                 { return 'Experimental: QUIC, Discord/STUN, Google host-fake split, and a Sferum HTTP fake.' }
        'fake-tls-auto'       { return 'Automatic fake-TLS with modified SNI and bad-sequence fooling.' }
        'fake-tls-auto-alt'   { return 'Fake split with modified TLS fakes and bad-sequence fooling.' }
        'fake-tls-auto-alt2'  { return 'Multisplit with the Google TLS pattern and modified TLS fakes.' }
        'fake-tls-auto-alt3'  { return 'Multisplit with the Google TLS pattern and timestamp fooling.' }
        'carrier-mts'         { return 'Narrow ALT11-derived candidate for the app host list; test it on an MTS connection.' }
        'carrier-megafon'     { return 'Narrow experimental EXP-derived candidate for the app host list; test it on MegaFon.' }
        'carrier-tele2'       { return 'Narrow ALT6-derived candidate for the app host list; test it on Tele2/T2.' }
        'carrier-yota'        { return 'Narrow TLS ALT3-derived candidate for the app host list; experimental on Yota.' }
        'simple-fake'         { return 'Simple fake with timestamp fooling and Google host-fake split.' }
        'simple-fake-alt'     { return 'Simple fake with bad-sequence fooling and Google/STUN/Sferum payloads.' }
        'simple-fake-alt2'    { return 'Simple fake with timestamp fooling; game traffic uses only the fake.' }
        default               { return 'User-created strategy.' }
    }
}

function Show-StrategyList {
    $strategies = Get-Strategies
    Write-Host ''
    for ($i = 0; $i -lt $strategies.Count; $i++) {
        $s = $strategies[$i]
        $num = '{0,3}.' -f ($i + 1)
        Write-Host "   $num " -NoNewline -ForegroundColor DarkGray
        Write-Host ("{0,-20}" -f $s.id) -NoNewline -ForegroundColor White
        Write-Host (Get-UiStrategyDescription -Strategy $s) -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Resolve-StrategyArg {
    param([string[]]$StrategyArgs)

    if ($StrategyArgs -and $StrategyArgs.Count -ge 1 -and $StrategyArgs[0]) {
        $strategy = Get-Strategy $StrategyArgs[0]
        if ($strategy) { return $strategy }
        Write-Host (T ("Неизвестная стратегия '{0}'." -f $StrategyArgs[0]) ("Unknown strategy '{0}'." -f $StrategyArgs[0])) -ForegroundColor Red
        Write-Host (T 'Введите zapret.ps1 list, чтобы посмотреть доступные стратегии.' 'Run zapret.ps1 list to see the available strategies.') -ForegroundColor Yellow
        return $null
    }

    # Interactive picker
    Show-StrategyList
    $strategies = @(Get-Strategies)
    $choice = Read-Host (T '   Введите номер стратегии (Enter — отмена)' '   Enter a strategy number (Enter to cancel)')
    if ([string]::IsNullOrWhiteSpace($choice)) { return $null }
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index)) {
        Write-Host (T 'Неверный ввод. Введите номер из списка.' 'That input is not valid. Enter a number from the list.') -ForegroundColor Red
        return $null
    }
    if ($index -lt 1 -or $index -gt $strategies.Count) {
        Write-Host (T 'Такого номера нет в списке.' 'That number is not in the list.') -ForegroundColor Red
        return $null
    }
    return $strategies[$index - 1]
}

# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------

function Invoke-MenuInstall {
    $strategy = Resolve-StrategyArg -StrategyArgs @()
    if (-not $strategy) { return }
    Write-Host ''
    try {
        Install-ZapretService -StrategyId $strategy.id
    } catch {
        Write-UiError $_.Exception.Message
        Write-Log "Install failed: $($_.Exception.Message)" 'ERROR'
    }
    Pause-Menu
}

function Invoke-MenuUninstall {
    $confirm = Read-Host (T '   Удалить службы zapret и WinDivert и остановить winws? [д/Н]' '   Remove the zapret and WinDivert services and stop winws? [y/N]')
    if ($confirm -notmatch '^(y|yes|д|да)$') { Write-Host (T '   Ничего не меняю.' '   No changes were made.') -ForegroundColor DarkGray; return }
    try {
        [void](Remove-ZapretServices)
    } catch {
        Write-UiError $_.Exception.Message
    }
    Pause-Menu
}

function Invoke-MenuStatus {
    $svc   = Get-ZapretServiceInfo
    $ipset = Get-IpsetState
    $game  = Get-GameFilterPorts
    $winws = (Get-WinwsProcess | Select-Object -First 1)

    Write-Host ''
    Write-Host (T '   СОСТОЯНИЕ' '   STATUS') -ForegroundColor Cyan
    Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
    if ($svc.Installed) {
        $strategy = if ($svc.Strategy) { $svc.Strategy } else { T 'неизвестна' 'unknown' }
        $serviceState = switch ([string]$svc.State) {
            'Running' { T 'работает' 'running' }
            'Stopped' { T 'остановлена' 'stopped' }
            default   { [string]$svc.State }
        }
        $serviceColor = if ($svc.State -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host ((T '   Служба zapret: {0} (стратегия: {1})' '   zapret service: {0} (strategy: {1})') -f $serviceState, $strategy) -ForegroundColor $serviceColor
    } else {
        Write-Host (T '   Служба zapret не установлена.' '   The zapret service is not installed.') -ForegroundColor Yellow
    }
    $winDivertState = switch ([string]$svc.WinDivertState) {
        'Running'     { T 'работает' 'running' }
        'Stopped'     { T 'остановлена' 'stopped' }
        'NotInstalled' { T 'не установлена' 'not installed' }
        default       { [string]$svc.WinDivertState }
    }
    Write-Host ((T '   Служба WinDivert: {0}' '   WinDivert service: {0}') -f $winDivertState) -ForegroundColor Gray
    if ($winws) {
        Write-Host ((T '   winws.exe запущен (PID {0})' '   winws.exe is running (PID {0})') -f $winws.Id) -ForegroundColor Green
    } else {
        Write-Host (T '   winws.exe не запущен.' '   winws.exe is not running.') -ForegroundColor Yellow
    }
    $uiIpset = switch ($ipset) { 'any' { T 'все адреса' 'all addresses' } 'loaded' { T 'список загружен' 'list loaded' } 'none' { T 'отключён' 'off' } default { T 'неизвестно' 'unknown' } }
    $uiGame = switch ($game.status) { 'enabled (TCP and UDP)' { T 'TCP и UDP включены' 'TCP and UDP on' } 'enabled (TCP)' { T 'включён только TCP' 'TCP only' } 'enabled (UDP)' { T 'включён только UDP' 'UDP only' } default { T 'выключен' 'off' } }
    Write-Host ((T '   Фильтр IP: {0}   Игровой трафик: {1}' '   IP filter: {0}   Game traffic: {1}') -f $uiIpset, $uiGame) -ForegroundColor Gray
    $cfg = Get-Config
    $updateState = if ($cfg.checkUpdates) { T 'включена' 'on' } else { T 'выключена' 'off' }
    Write-Host ((T '   Проверка обновлений: {0}' '   Update check: {0}') -f $updateState) -ForegroundColor Gray
    Write-Host ''
}

function Invoke-MenuGameFilter {
    while ($true) {
        Invoke-ClearScreen
        $cfg  = Get-Config
        $mode = $cfg.gameFilter.mode

        $mark = @{ disabled = ' '; all = ' '; tcp = ' '; udp = ' ' }
        $mark[$mode] = '*'

        Write-Host ''
        Write-Host (T '   ФИЛЬТР ИГРОВОГО ТРАФИКА' '   GAME TRAFFIC FILTER') -ForegroundColor Cyan
        Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
        Write-Host ((T "   1. [{0}] Выключить фильтр" "   1. [{0}] Turn the filter off") -f $mark['disabled'])
        Write-Host ((T "   2. [{0}] TCP и UDP" "   2. [{0}] TCP and UDP") -f $mark['all'])
        Write-Host ((T "   3. [{0}] Только TCP" "   3. [{0}] TCP only") -f $mark['tcp'])
        Write-Host ((T "   4. [{0}] Только UDP" "   4. [{0}] UDP only") -f $mark['udp'])
        Write-Host ''
        Write-Host ((T '   5. Изменить порты TCP (сейчас: {0})' '   5. Change TCP ports (current: {0})') -f $cfg.gameFilter.tcp)
        Write-Host ((T '   6. Изменить порты UDP (сейчас: {0})' '   6. Change UDP ports (current: {0})') -f $cfg.gameFilter.udp)
        Write-Host (T '   7. Задать одинаковые порты для TCP и UDP' '   7. Set the same port range for TCP and UDP')
        Write-Host ''
        Write-Host (T '   0. Назад' '   0. Back')
        Write-Host ''
        $choice = Read-MenuChoice '   Select option'

        switch ($choice) {
            '1' { [void](Update-Config @{ gameFilterMode = 'disabled' }); }
            '2' { [void](Update-Config @{ gameFilterMode = 'all' }); }
            '3' { [void](Update-Config @{ gameFilterMode = 'tcp' }); }
            '4' { [void](Update-Config @{ gameFilterMode = 'udp' }); }
            '5' {
                $rangeInput = Read-Host (T '   Порты TCP (например, 1024-1934,1936-65535; по умолчанию 1024-65535)' '   TCP ports (for example, 1024-1934,1936-65535; default 1024-65535)')
                if ([string]::IsNullOrWhiteSpace($rangeInput)) { $rangeInput = '1024-65535' }
                if (Test-PortRange $rangeInput) { [void](Update-Config @{ gameFilterTcp = $rangeInput }) }
                else { Write-Host (T '   Диапазон портов указан неверно. Используйте числа от 1 до 65535, например 1024-65535.' '   Invalid port range. Use ports from 1 to 65535, for example 1024-65535.') -ForegroundColor Red; Start-Sleep 2 }
            }
            '6' {
                $rangeInput = Read-Host (T '   Порты UDP (например, 1024-1934,1936-65535; по умолчанию 1024-65535)' '   UDP ports (for example, 1024-1934,1936-65535; default 1024-65535)')
                if ([string]::IsNullOrWhiteSpace($rangeInput)) { $rangeInput = '1024-65535' }
                if (Test-PortRange $rangeInput) { [void](Update-Config @{ gameFilterUdp = $rangeInput }) }
                else { Write-Host (T '   Диапазон портов указан неверно. Используйте числа от 1 до 65535, например 1024-65535.' '   Invalid port range. Use ports from 1 to 65535, for example 1024-65535.') -ForegroundColor Red; Start-Sleep 2 }
            }
            '7' {
                $rangeInput = Read-Host (T '   Общий диапазон портов TCP и UDP' '   Port range to use for both TCP and UDP')
                if ([string]::IsNullOrWhiteSpace($rangeInput)) { $rangeInput = '1024-65535' }
                if (Test-PortRange $rangeInput) { [void](Update-Config @{ gameFilterTcp = $rangeInput; gameFilterUdp = $rangeInput }) }
                else { Write-Host (T '   Диапазон портов указан неверно. Используйте числа от 1 до 65535, например 1024-65535.' '   Invalid port range. Use ports from 1 to 65535, for example 1024-65535.') -ForegroundColor Red; Start-Sleep 2 }
            }
            '0' { return }
            default { Write-Host (T '   Неверный номер. Выберите пункт от 0 до 7.' '   Invalid choice. Select an option from 0 to 7.') -ForegroundColor Red; Start-Sleep 1; continue }
        }
        if ($choice -in @('1','2','3','4','5','6','7')) {
            [void](Invoke-ZapretServiceRestartPrompt -Reason 'Игровой фильтр изменён')
            Start-Sleep 1
        }
    }
}

function Invoke-MenuDns {
    while ($true) {
        Invoke-ClearScreen
        Write-Host ''
        Write-Host (T '   DNS И ЗАЩИЩЁННЫЙ DNS (DoH)' '   DNS AND ENCRYPTED DNS (DoH)') -ForegroundColor Cyan
        Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
        Write-Host (T '   Если провайдер подменяет обычные DNS-ответы, защищённый DNS' '   If your ISP tampers with ordinary DNS, encrypted DNS may help') -ForegroundColor DarkGray
        Write-Host (T '   может помочь открыть сайты, которые иначе не загружаются.' '   sites load when they would otherwise fail.') -ForegroundColor DarkGray
        Write-Host ''
        Write-Host (T '   1. Показать DNS для каждого сетевого адаптера' '   1. Show DNS settings for each network adapter')
        Write-Host (T '   2. Включить DoH и DNS Cloudflare (1.1.1.1)' '   2. Enable DoH and set Cloudflare DNS (1.1.1.1)')
        Write-Host (T '   3. Включить DoH и DNS Google (8.8.8.8)' '   3. Enable DoH and set Google DNS (8.8.8.8)')
        Write-Host (T '   4. Включить DoH и DNS Quad9 (9.9.9.9)' '   4. Enable DoH and set Quad9 DNS (9.9.9.9)')
        Write-Host (T '   5. Включить DoH и DNS AdGuard (94.140.14.14)' '   5. Enable DoH and set AdGuard DNS (94.140.14.14)')
        Write-Host (T '   6. Включить DoH и DNS Яндекса (77.88.8.8)' '   6. Enable DoH and set Yandex DNS (77.88.8.8)')
        Write-Host (T '   7. Вернуть автоматические настройки DNS (DHCP)' '   7. Restore automatic DNS settings (DHCP)')
        Write-Host (T '   8. Восстановить DNS из последней резервной копии' '   8. Restore DNS from the latest backup')
        Write-Host ''
        Write-Host (T '   0. Назад' '   0. Back')
        Write-Host ''
        $choice = Read-MenuChoice '   Select option'
        switch ($choice) {
            '1' { try { Write-DnsStatus } catch { Write-UiError $_.Exception.Message }; Pause-Menu }
            '2' { try { Enable-Doh -Provider cloudflare } catch { Write-UiError $_.Exception.Message }; Pause-Menu }
            '3' { try { Enable-Doh -Provider google }     catch { Write-UiError $_.Exception.Message }; Pause-Menu }
            '4' { try { Enable-Doh -Provider quad9 }      catch { Write-UiError $_.Exception.Message }; Pause-Menu }
            '5' { try { Enable-Doh -Provider adguard }    catch { Write-UiError $_.Exception.Message }; Pause-Menu }
            '6' { try { Enable-Doh -Provider yandex }     catch { Write-UiError $_.Exception.Message }; Pause-Menu }
            '7' { try { Reset-DnsToDhcp }                 catch { Write-UiError $_.Exception.Message }; Pause-Menu }
            '8' { try { [void](Restore-DnsRollbackSnapshot) } catch { Write-UiError $_.Exception.Message }; Pause-Menu }
            '0' { return }
            default { Write-Host (T '   Неверный номер. Выберите пункт от 0 до 8.' '   Invalid choice. Select an option from 0 to 8.') -ForegroundColor Red; Pause-Menu }
        }
    }
}

function Invoke-MenuNetworkTools {
    while ($true) {
        Invoke-ClearScreen
        Write-Host ''
        Write-Host (T '   СЕТЬ И КАЧЕСТВО СОЕДИНЕНИЯ' '   NETWORK AND CONNECTION QUALITY') -ForegroundColor Cyan
        Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
        Write-Host (T '   1. Сравнить скорость 5 DNS-провайдеров и выбрать быстрый' '   1. Compare 5 DNS providers and choose the fastest')
        Write-Host (T '   2. Применить сетевые настройки для меньшей задержки' '   2. Apply network settings to reduce latency')
        Write-Host (T '   3. Отменить последнее изменение сети' '   3. Undo the latest network change')
        Write-Host (T '      4. Проверить MTU (максимальный размер пакета) и при желании применить' '      4. Check MTU (maximum packet size) and optionally apply the recommended value')
        Write-Host (T '   5. Проверить связь с роутером, Cloudflare и Discord' '   5. Test the connection to your router, Cloudflare, and Discord')
        Write-Host ''
        Write-Host (T '   0. Назад' '   0. Back')
        Write-Host ''
        $choice = Read-MenuChoice '   Select option'
        switch ($choice) {
            '1' {
                try { [void](Invoke-DnsBenchmark) } catch { Write-UiError $_.Exception.Message }
                Pause-Menu
            }
            '2' {
                try { [void](Invoke-NetworkOptimize) } catch { Write-UiError $_.Exception.Message }
                Pause-Menu
            }
            '3' {
                try { [void](Invoke-NetworkOptimize -Revert) } catch { Write-UiError $_.Exception.Message }
                Pause-Menu
            }
            '4' {
                try { [void](Invoke-MtuCheck) } catch { Write-UiError $_.Exception.Message }
                Pause-Menu
            }
            '5' {
                try { [void](Invoke-LineQualityTest) } catch { Write-UiError $_.Exception.Message }
                Pause-Menu
            }
            '0' { return }
            default { Write-Host (T '   Неверный номер. Выберите пункт от 0 до 5.' '   Invalid choice. Select an option from 0 to 5.') -ForegroundColor Red; Pause-Menu }
        }
    }
}

function Invoke-MenuSchedule {
    Write-Host ''
    try {
        if (Test-AutoSelectSchedule) {
            Write-Host (T '   Еженедельная автоматическая проверка включена.' '   Weekly automatic re-check is on.') -ForegroundColor Cyan
            $answer = Read-Host (T '   Выключить её? [д/Н]' '   Turn it off? [y/N]')
            if ($answer -and ($answer.Trim() -match '^(y|yes|д|да)$')) { Set-AutoSelectSchedule -Disable }
            else { Write-Host (T '   Оставляю включённой.' '   Leaving it on.') -ForegroundColor DarkGray }
        } else {
            Write-Host (T '   Раз в неделю программа проверяет все стратегии' '   Once a week, the tool tests all strategies') -ForegroundColor DarkGray
            Write-Host (T '   (в воскресенье в 03:30) и автоматически включает лучшую.' '   (Sunday at 03:30) and automatically enables the best one.') -ForegroundColor DarkGray
            $answer = Read-Host (T '   Включить проверку? [д/Н]' '   Turn it on? [y/N]')
            if ($answer -and ($answer.Trim() -match '^(y|yes|д|да)$')) { Set-AutoSelectSchedule -Enable }
            else { Write-Host (T '   Не включаю.' '   Leaving it off.') -ForegroundColor DarkGray }
        }
    } catch {
        Write-UiError $_.Exception.Message
        Write-Log "schedule-autoselect menu error: $($_.Exception.Message)" 'ERROR'
    }
    Pause-Menu
}

function Invoke-MenuAutoSelect {
    Write-Host ''
    Write-Host (T '   Проверю доступность YouTube, Discord и WhatsApp, затем предложу лучший вариант.' '   I will check YouTube, Discord, and WhatsApp, then offer the best option.') -ForegroundColor DarkGray
    Write-Host (T '   Проверяются веб-адреса и передача данных; это не заменяет проверку входа и звонков в самих приложениях.' '   The test checks web endpoints and data transfer; it does not replace testing sign-in or calls in the apps.') -ForegroundColor DarkGray
    try {
        [void](Invoke-AutoSelect)
    } catch {
        Write-UiError $_.Exception.Message
        Write-Log "auto-select failed: $($_.Exception.Message)" 'ERROR'
    }
    Pause-Menu
}

function Invoke-MenuAutoSetup {
    Write-Host ''
    Write-Host (T '   Мастер спросит, интернет обычный или мобильный; для мобильного попросит выбрать оператора.' '   The wizard asks whether the connection is regular or mobile; for mobile, it asks you to choose a carrier.') -ForegroundColor DarkGray
    Write-Host (T '   Затем предложит установить проверенную стратегию и настроить hosts/IPSet. Еженедельная перепроверка предлагается отдельно; DNS и системные сетевые параметры автоматически не меняются.' '   It then offers to install a verified strategy and configure hosts/IPSet. Weekly re-check is offered separately; DNS and system network settings are not changed automatically.') -ForegroundColor DarkGray
    try {
        [void](Invoke-AutoSetup)
    } catch {
        Write-UiError $_.Exception.Message
        Write-Log "auto-setup failed: $($_.Exception.Message)" 'ERROR'
    }
    Pause-Menu
}

function Invoke-MenuSupportBundle {
    Write-Host ''
    Write-Host (T '   Собираю отчёт для службы поддержки...' '   Preparing a support report...') -ForegroundColor DarkGray
    Write-Host (T '   По умолчанию пути, IP и секреты маскируются; пользовательские стратегии не включаются. Перед созданием будет показан состав.' '   By default, paths, IPs and secrets are redacted; custom strategies are omitted. The contents are previewed first.') -ForegroundColor DarkGray
    try {
        [void](New-SupportBundle)
    } catch {
        Write-UiError $_.Exception.Message
        Write-Log "support-bundle failed: $($_.Exception.Message)" 'ERROR'
    }
    Pause-Menu
}

function Invoke-MenuImportConfig {
    Write-Host ''
    Write-Host (T '   Перенос настроек из старой папки zapret в эту установку:' '   Import settings from an older zapret folder into this installation:') -ForegroundColor DarkGray
    Write-Host (T '   Настройки, пользовательские списки, IP-список и выбранные фейки.' '   Settings, your lists, the IP list, and active fake files.') -ForegroundColor DarkGray
    $src = Read-Host (T '   Укажите путь к старой папке (например, D:\zapret)' '   Enter the path to the older folder (for example, D:\zapret)')
    if ([string]::IsNullOrWhiteSpace($src)) { Write-Host (T '   Перенос отменён.' '   Import cancelled.') -ForegroundColor DarkGray; Pause-Menu; return }
    $src = $src.Trim().Trim('"')
    try {
        [void](Import-ExternalConfig -SourcePath $src)
    } catch {
        Write-UiError $_.Exception.Message
        Write-Log "import-config failed: $($_.Exception.Message)" 'ERROR'
    }
    Pause-Menu
}

function Invoke-MenuRollback {
    Write-Host ''
    $cfg = Get-Config
    $rb  = $cfg.rollback
    if ($null -eq $rb -or -not $rb.folder) {
        Write-Host (T '   Резервных копий пока нет. Перед изменением стратегии,' '   No backups yet. Before changing a strategy,') -ForegroundColor DarkGray
        Write-Host (T '   IP-списка или файла hosts программа сохранит копию для отката.' '   IP list, or hosts file, the tool saves a backup you can restore.') -ForegroundColor DarkGray
        Pause-Menu
        return
    }
    $reasonLabel = switch ([string]$rb.reason) {
        'strategy' { T 'смена стратегии' 'strategy change' }
        'ipset'    { T 'изменение IP-фильтра' 'IP filter change' }
        'hosts'    { T 'изменение файла hosts' 'hosts file change' }
        'dns'      { T 'изменение DNS' 'DNS change' }
        'mtu'      { T 'изменение MTU' 'MTU change' }
        default    { [string]$rb.reason }
    }
    $strategyPart = if ($rb.strategy) { T (", стратегия: $($rb.strategy)") (", strategy: $($rb.strategy)") } else { '' }
    Write-Host ((T "   Последняя копия создана {1}; причина: {0}{2}" "   Latest backup was created {1}; reason: {0}{2}") -f $reasonLabel, $rb.time, $strategyPart) -ForegroundColor Cyan
    if ($rb.ipset) { Write-Host (T '   - будет восстановлен IP-список' '   - the IP list will be restored') -ForegroundColor DarkGray }
    if ($rb.hosts) { Write-Host (T '   - будет восстановлен файл hosts' '   - the hosts file will be restored') -ForegroundColor DarkGray }
    $answer = Read-Host (T '   Восстановить эту копию? [д/Н]' '   Restore this backup? [y/N]')
    if ($answer -and ($answer.Trim() -match '^(y|yes|д|да)$')) {
        try { [void](Restore-RollbackSnapshot) } catch { Write-UiError $_.Exception.Message }
    } else {
        Write-Host (T '   Откат отменён.' '   Rollback cancelled.') -ForegroundColor DarkGray
    }
    Pause-Menu
}

function Invoke-MenuSiteRecommendations {
    $recommendations = @(Get-RecommendedSiteCatalog)
    Write-Host ''
    Write-Host (T '   РЕКОМЕНДАЦИИ САЙТОВ' '   RECOMMENDED SITES') -ForegroundColor Cyan
    Write-Host (T '   Выберите сервис: домены сначала покажутся для проверки, добавление — только после подтверждения.' '   Choose a service: review its hostnames first; nothing is added until you confirm.') -ForegroundColor DarkGray
    Write-Host ''
    for ($index = 0; $index -lt $recommendations.Count; $index++) {
        $label = Get-UiText -Russian $recommendations[$index].NameRu -English $recommendations[$index].NameEn
        Write-Host ('   {0}. {1}' -f ($index + 1), $label)
    }
    Write-Host (T '   0. Назад' '   0. Back')
    $choice = Read-MenuChoice (T '   Выберите рекомендацию' '   Choose a recommendation')
    if ($choice -eq '0') { return }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $recommendations.Count) {
        Write-Warn2 (T 'Неверный номер рекомендации.' 'Invalid recommendation number.')
        return
    }

    $recommendation = $recommendations[$number - 1]
    $label = Get-UiText -Russian $recommendation.NameRu -English $recommendation.NameEn
    $note = Get-UiText -Russian $recommendation.NoteRu -English $recommendation.NoteEn
    Write-Host ''
    Write-Host ((T '   Рекомендация: {0}' '   Recommendation: {0}') -f $label) -ForegroundColor Cyan
    Write-Host (T '   Основные домены (список может быть неполным):' '   Core hostnames (the list may be incomplete):') -ForegroundColor DarkGray
    foreach ($domain in $recommendation.Domains) { Write-Host ('   - {0}' -f $domain) }
    if (-not [string]::IsNullOrWhiteSpace($note)) { Write-Info2 $note }
    Write-Info2 (T 'Домены будут добавлены только в личный список list-general-user.txt; это не гарантирует работу сайта или приложения.' 'Hostnames will be added only to your list-general-user.txt; this does not guarantee the site or app will work.')

    $excludedDomains = @{}
    foreach ($excludeFile in @((Join-Path $root 'lists\list-exclude.txt'), (Join-Path $root 'lists\list-exclude-user.txt'))) {
        if (-not (Test-Path -LiteralPath $excludeFile -PathType Leaf)) { continue }
        foreach ($line in (Get-Content -LiteralPath $excludeFile -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace([string]$line) -or $line.Trim() -match '^#') { continue }
            $excludedDomain = ConvertTo-Domain -InputText ([string]$line)
            if ($excludedDomain) { $excludedDomains[$excludedDomain] = $true }
        }
    }
    $blockedDomains = @()
    foreach ($domain in $recommendation.Domains) {
        foreach ($excludedDomain in $excludedDomains.Keys) {
            if ($domain.Equals([string]$excludedDomain, [StringComparison]::OrdinalIgnoreCase) -or $domain.EndsWith(('.' + [string]$excludedDomain), [StringComparison]::OrdinalIgnoreCase)) {
                $blockedDomains += $domain
                break
            }
        }
    }
    if ($blockedDomains.Count -gt 0) {
        Write-Warn2 ((T 'Эти домены уже находятся в списке исключений: {0}. Добавление в список обхода не отменяет исключение; рекомендация не добавлена.' 'These hostnames are already in an exclusion list: {0}. Adding them to the bypass list does not override the exclusion; this recommendation was not added.') -f (($blockedDomains | Select-Object -Unique) -join ', '))
        return
    }

    $answer = Read-Host (T '   Добавить перечисленные домены в список обхода? [д/Н]' '   Add the listed hostnames to the bypass list? [y/N]')
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim() -notmatch '^(?i:y|yes|д|да)$') {
        Write-Info2 (T 'Добавление отменено; списки не изменены.' 'Addition cancelled; the lists were not changed.')
        return
    }

    $added = 0
    $existing = 0
    try {
        foreach ($domain in $recommendation.Domains) {
            $result = Add-DomainToList -Domain $domain -Kind general
            if ($result -eq 'added') { $added++ } else { $existing++ }
        }
    } catch {
        Write-UiError $_.Exception.Message
        if ($added -gt 0) { [void](Invoke-ZapretServiceRestartPrompt -Reason (T 'Список доменов изменён' 'Domain list changed')) }
        return
    }
    if ($added -eq 0) {
        Write-Info2 (T 'Все домены этой рекомендации уже есть в личном списке.' 'All hostnames in this recommendation are already in your personal list.')
        return
    }
    Write-Ok ((T 'Добавлено новых доменов: {0}; уже было: {1}.' 'New hostnames added: {0}; already present: {1}.') -f $added, $existing)
    [void](Invoke-ZapretServiceRestartPrompt -Reason (T 'Список доменов изменён' 'Domain list changed'))
}

function Invoke-MenuDomain {
    while ($true) {
        Invoke-ClearScreen
        Write-Host ''
        Write-Host (T '   МОИ САЙТЫ' '   MY SITES') -ForegroundColor Cyan
        Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
        $generalFile = Join-Path $root 'lists\list-general-user.txt'
        $excludeFile = Join-Path $root 'lists\list-exclude-user.txt'
        $gc = if (Test-Path $generalFile) { @(Get-Content $generalFile | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' -and $_.Trim([char]0xFEFF).Trim() -ne 'domain.example.abc' }).Count } else { 0 }
        $ec = if (Test-Path $excludeFile) { @(Get-Content $excludeFile | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' -and $_.Trim([char]0xFEFF).Trim() -ne 'domain.example.abc' }).Count } else { 0 }
        Write-Host ((T '   Сайтов в списке обхода: {0}   В исключениях: {1}' '   Sites to bypass: {0}   Excluded sites: {1}') -f $gc, $ec) -ForegroundColor Gray
        Write-Host ''
        Write-Host (T '   1. Добавить сайт в список обхода' '   1. Add a site to the bypass list')
        Write-Host (T '   2. Исключить сайт из обхода' '   2. Exclude a site from the bypass')
        Write-Host (T '   3. Удалить домен из обоих списков' '   3. Remove a domain from both lists')
        Write-Host (T '   4. Показать мои списки' '   4. Show my lists')
        Write-Host (T '   5. Открыть списки в Блокноте' '   5. Open the lists in Notepad')
        Write-Host (T '   6. Сбросить мои списки к пустым шаблонам' '   6. Clear my lists and restore the empty templates')
        Write-Host (T '   7. Найти домены в DNS-кэше' '   7. Find domains in the DNS cache')
        Write-Host (T '   8. Рекомендации сайтов' '   8. Recommended sites')
        Write-Host (T '   0. Назад' '   0. Back')
        Write-Host ''
        $choice = Read-MenuChoice '   Select option'
        switch ($choice) {
            '1' {
                $inp = Read-Host (T '   Введите домен или ссылку (например, https://www.site.com/watch?v=1)' '   Enter a domain or URL (for example, https://www.site.com/watch?v=1)')
                if (-not [string]::IsNullOrWhiteSpace($inp)) {
                    try { [void](Add-DomainToList -Domain $inp -Kind general); [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён') } catch { Write-UiError $_.Exception.Message }
                }
                Pause-Menu
            }
            '2' {
                $inp = Read-Host (T '   Введите домен или ссылку, которую нужно исключить' '   Enter the domain or URL to exclude')
                if (-not [string]::IsNullOrWhiteSpace($inp)) {
                    try { [void](Add-DomainToList -Domain $inp -Kind exclude); [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён') } catch { Write-UiError $_.Exception.Message }
                }
                Pause-Menu
            }
            '3' {
                $inp = Read-Host (T '   Введите домен или ссылку для удаления из обоих списков' '   Enter the domain or URL to remove from both lists')
                if (-not [string]::IsNullOrWhiteSpace($inp)) {
                    try {
                        $removed = Remove-DomainFromLists -Domain $inp
                        if ($removed.TotalRemoved -gt 0) { [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён') }
                    } catch { Write-UiError $_.Exception.Message }
                }
                Pause-Menu
            }
            '4' {
                foreach ($pair in @(@((T 'Сайты в списке обхода' 'Bypass list'), $generalFile), @((T 'Исключения' 'Excluded sites'), $excludeFile))) {
                    Write-Host ''
                    Write-Host ("   == {0} ({1}) ==" -f $pair[0], $pair[1]) -ForegroundColor DarkGray
                    if (Test-Path $pair[1]) {
                        $lines = @(Get-Content $pair[1] | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\s*#' -and $_.Trim([char]0xFEFF).Trim() -ne 'domain.example.abc' })
                        if ($lines.Count -eq 0) { Write-Host (T '   (список пуст)' '   (list is empty)') -ForegroundColor DarkGray } else { $lines | ForEach-Object { Write-Host "   $_" } }
                    } else { Write-Host (T '   (список ещё не создан)' '   (list has not been created yet)') -ForegroundColor DarkGray }
                }
                Pause-Menu
            }
            '5' {
                try {
                    Initialize-UserLists | Out-Null
                    $notepadArgs = @(
                        (ConvertTo-WindowsCommandLineArgument -Value $generalFile),
                        (ConvertTo-WindowsCommandLineArgument -Value $excludeFile)
                    )
                    Start-Process -FilePath (Get-WindowsSystemToolPath -Name 'notepad.exe') -ArgumentList ($notepadArgs -join ' ') | Out-Null
                } catch { Write-UiError (T ("Не удалось открыть Блокнот: {0}" -f $_.Exception.Message) ("Could not open Notepad: {0}" -f $_.Exception.Message)); Pause-Menu }
            }
            '6' {
                $answer = Read-Host (T '   Удалить все мои домены и восстановить пустые списки? IPSet и другие настройки не изменятся. [д/Н]' '   Remove all my domains and restore empty lists? IPSet and other settings will not change. [y/N]')
                if ($answer -match '^(y|yes|д|да)$') {
                    try {
                        $reset = Reset-UserDomainLists
                        if ($reset.Changed) { [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов сброшен') }
                    } catch { Write-UiError $_.Exception.Message }
                } else { Write-Host (T '   Откат отменён.' '   Rollback cancelled.') -ForegroundColor DarkGray }
                Pause-Menu
            }
            '7' {
                try { [void](Invoke-DomainDiscovery) } catch { Write-UiError $_.Exception.Message }
                Pause-Menu
            }
            '8' {
                Invoke-MenuSiteRecommendations
                Pause-Menu
            }
            '0' { return }
            default { Write-Host (T '   Неверный номер. Выберите пункт от 0 до 8.' '   Invalid choice. Select an option from 0 to 8.') -ForegroundColor Red; Pause-Menu }
        }
    }
}

function Invoke-MenuCloneStrategy {
    Write-Host ''
    Write-Host (T '   СОЗДАТЬ ИЛИ ПЕРЕДАТЬ СТРАТЕГИЮ' '   CREATE OR SHARE A STRATEGY') -ForegroundColor Cyan
    Write-Host (T '   1. Создать свою стратегию на основе встроенной' '   1. Create your own strategy from a built-in one')
    Write-Host (T '   2. Импортировать стратегию по коду zapret1:...' '   2. Import a strategy from a zapret1:... code')
    Write-Host (T '   3. Скопировать стратегию в виде кода' '   3. Export a strategy as a share code')
    Write-Host (T '   0. Назад' '   0. Back')
    $operation = Read-MenuChoice (T '   Выберите пункт' '   Choose an option')
    if ($operation -eq '0') { return }
    if ($operation -eq '2') {
        $shareString = Read-Host (T '   Вставьте код стратегии zapret1:...' '   Paste the zapret1:... strategy code')
        if ([string]::IsNullOrWhiteSpace($shareString)) { Write-Info2 (T 'Код не введён, импорт отменён.' 'No code was entered; import cancelled.'); Pause-Menu; return }
        try {
            $imported = Import-UserStrategy -ShareString $shareString
            $answer = Read-Host (T ("   Установить стратегию '{0}' как службу сейчас? [д/Н]" -f $imported.id) ("   Install strategy '{0}' as a service now? [y/N]" -f $imported.id))
            if ($answer -match '^(y|yes|д|да)$') { [void](Install-ZapretService -StrategyId $imported.id) }
        } catch { Write-UiError $_.Exception.Message }
        Pause-Menu
        return
    }
    if ($operation -eq '3') {
        Show-StrategyList
        $exportId = Read-Host (T '   Введите ID стратегии для экспорта' '   Enter the strategy ID to export')
        if (-not [string]::IsNullOrWhiteSpace($exportId)) {
            try { [void](Export-UserStrategy -Id $exportId.Trim()) } catch { Write-UiError $_.Exception.Message }
        }
        Pause-Menu
        return
    }
    if ($operation -ne '1') { Write-Warn2 (T 'Неизвестный пункт меню. Выберите 1, 2, 3 или 0.' 'Unknown menu option. Choose 1, 2, 3, or 0.'); return }

    Show-StrategyList
    $base = Read-Host (T '   Введите ID исходной стратегии (например, general)' '   Enter the ID of the base strategy (for example, general)')
    if ([string]::IsNullOrWhiteSpace($base)) { Write-Host (T '   Создание отменено.' '   Creation cancelled.') -ForegroundColor DarkGray; return }
    $newId = Read-Host (T '   Придумайте ID (строчные латинские буквы, цифры и дефис; например my-general)' '   Choose an ID (lowercase letters, numbers, and hyphens; for example, my-general)')
    if ([string]::IsNullOrWhiteSpace($newId)) { Write-Host (T '   Создание отменено.' '   Creation cancelled.') -ForegroundColor DarkGray; return }
    try {
        [void](New-UserStrategy -BaseId $base.Trim() -NewId $newId.Trim())
    } catch {
        Write-UiError $_.Exception.Message
        Pause-Menu
        return
    }
    $cloneId = $newId.Trim().ToLowerInvariant()
    while ($true) {
        Invoke-ClearScreen
        $s = Get-Strategy $cloneId
        Write-Host ''
        Write-Host ((T '   НАСТРОЙКА СТРАТЕГИИ: {0}' '   STRATEGY EDITOR: {0}') -f $s.id) -ForegroundColor Cyan
        Write-Host (T '   Текущие параметры:' '   Current parameters:') -ForegroundColor DarkGray
        $matchesFound = [regex]::Matches($s.args, '--dpi-desync-(repeats|split-pos|split-seqovl)=([0-9A-Za-z,+-]+)')
        $grouped = @{}
        foreach ($m in $matchesFound) { if (-not $grouped.ContainsKey($m.Groups[1].Value)) { $grouped[$m.Groups[1].Value] = @() }; $grouped[$m.Groups[1].Value] += $m.Groups[2].Value }
        if ($grouped.Count -eq 0) { Write-Host (T '   (настраиваемые параметры не найдены)' '   (no editable parameters found)') -ForegroundColor DarkGray }
        foreach ($kv in $grouped.GetEnumerator()) {
            Write-Host ("   --dpi-desync-{0,-12} {1}" -f $kv.Key, (($kv.Value | Select-Object -Unique) -join ', '))
        }
        Write-Host ''
        Write-Host (T '   1. Изменить число повторов (repeats)' '   1. Change the repeat count (repeats)')
        Write-Host (T '   2. Изменить позицию разделения (split-pos)' '   2. Change the split position (split-pos)')
        Write-Host (T '   3. Изменить перекрытие сегментов (split-seqovl)' '   3. Change the segment overlap (split-seqovl)')
        Write-Host (T '   4. Выбрать другой файл-фейк из папки bin' '   4. Choose a different fake file from the bin folder')
        Write-Host (T '   5. Готово' '   5. Done')
        Write-Host ''
        $c = Read-MenuChoice (T '   Выберите пункт' '   Choose an option')
        switch ($c) {
            '1' { $v = Read-Host (T '   Введите новое число повторов' '   Enter the new repeat count'); [int]$iv = 0; if ([int]::TryParse($v, [ref]$iv)) { try { [void](Set-UserStrategyParam -Id $cloneId -Param repeats -Value $iv) } catch { Write-UiError $_.Exception.Message } } else { Write-Host (T '   Введите целое число.' '   Enter a whole number.') -ForegroundColor Red } }
            '2' { $v = Read-Host (T '   Введите новую позицию разделения' '   Enter the new split position'); [int]$iv = 0; if ([int]::TryParse($v, [ref]$iv)) { try { [void](Set-UserStrategyParam -Id $cloneId -Param split-pos -Value $iv) } catch { Write-UiError $_.Exception.Message } } else { Write-Host (T '   Введите целое число.' '   Enter a whole number.') -ForegroundColor Red } }
            '3' { $v = Read-Host (T '   Введите новое перекрытие сегментов' '   Enter the new segment overlap'); [int]$iv = 0; if ([int]::TryParse($v, [ref]$iv)) { try { [void](Set-UserStrategyParam -Id $cloneId -Param seqovl -Value $iv) } catch { Write-UiError $_.Exception.Message } } else { Write-Host (T '   Введите целое число.' '   Enter a whole number.') -ForegroundColor Red } }
            '4' {
                $fakes = @(Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Filter '*.bin' -File | Sort-Object Name)
                for ($i = 0; $i -lt $fakes.Count; $i++) { Write-Host ('   {0,2}. {1}' -f ($i + 1), $fakes[$i].BaseName) }
                $pick = Read-Host (T '   Введите номер файла' '   Enter the file number')
                $iv = 0
                if ([int]::TryParse($pick, [ref]$iv) -and $iv -ge 1 -and $iv -le $fakes.Count) {
                    try { [void](Set-UserStrategyFake -Id $cloneId -FakeBaseName $fakes[$iv - 1].BaseName) } catch { Write-UiError $_.Exception.Message }
                } else {
                    Write-Host (T '   Такого номера нет в списке.' '   That number is not in the list.') -ForegroundColor Red
                }
            }
            '5' { break }
            default { Write-Host (T '   Выберите пункт от 1 до 5.' '   Choose an option from 1 to 5.') -ForegroundColor Red; Pause-Menu }
        }
    }
    $answer = Read-Host (T '   Установить эту стратегию как службу сейчас? [д/Н]' '   Install this strategy as a service now? [y/N]')
    if ($answer -and ($answer.Trim() -match '^(y|yes|д|да)$')) {
        try { [void](Install-ZapretService -StrategyId $cloneId) } catch { Write-UiError $_.Exception.Message }
    }
    Pause-Menu
}

function Invoke-MenuIpset {
    $state = Get-IpsetState
    Write-Host ''
    Write-Host (T '   ФИЛЬТР ПО IP-АДРЕСАМ' '   IP ADDRESS FILTER') -ForegroundColor Cyan
    Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
    $uiState = switch ($state) { 'loaded' { T 'список загружен' 'list loaded' } 'none' { T 'отключён' 'off' } 'any' { T 'все адреса (фильтр не ограничивает трафик)' 'all addresses (no filtering)' } default { T 'неизвестно' 'unknown' } }
    Write-Host ((T '   Сейчас: {0}' '   Current mode: {0}') -f $uiState)
    Write-Host ''
    Write-Host (T '   1. Использовать загруженный список адресов' '   1. Use the downloaded address list')
    Write-Host (T '   2. Не фильтровать IP-адреса' '   2. Do not filter IP addresses')
    Write-Host (T '   3. Фильтровать все адреса (может помешать сайтам)' '   3. Filter all addresses (may break some sites)')
    Write-Host (T '   0. Назад' '   0. Back')
    Write-Host ''
    $choice = Read-MenuChoice '   Select option'
    try {
        switch ($choice) {
            '1' { Set-IpsetMode -Mode loaded }
            '2' { Set-IpsetMode -Mode none }
            '3' { Set-IpsetMode -Mode any }
            '0' { }
            default { Write-Host (T '   Неверный номер. Выберите пункт от 0 до 3.' '   Invalid choice. Select an option from 0 to 3.') -ForegroundColor Red }
        }
        if ($choice -in @('1','2','3')) { [void](Invoke-ZapretServiceRestartPrompt -Reason 'IPSet изменён') }
    } catch {
        Write-UiError $_.Exception.Message
    }
    Pause-Menu
}

function Invoke-MenuCheckUpdatesSwitch {
    $cfg = Get-Config
    $new = -not $cfg.checkUpdates
    [void](Update-Config @{ checkUpdates = $new })
    $updateText = if ($new) { T 'включена' 'on' } else { T 'выключена' 'off' }
    Write-Host ((T '   Проверка обновлений {0}.' '   Update check is {0}.') -f $updateText) -ForegroundColor Yellow
    Pause-Menu
}

function Invoke-MenuFakes {
    $inventory = Get-FakeInventory
    Write-Host ''
    Write-Host (T '   ФАЙЛЫ ДЛЯ ПОДМЕНЫ UDP-ТРАФИКА' '   UDP TRAFFIC FAKE FILES') -ForegroundColor Cyan
    Write-Host (T '   Это небольшие образцы данных, которые используются при подмене UDP-пакетов.' '   These small sample files are used to disguise UDP packets.') -ForegroundColor DarkGray
    Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
    Write-Host ((T '   1. Для Discord (сейчас: {0})' '   1. For Discord (current: {0})') -f $inventory.CurrentDiscordFake)
    Write-Host ((T '   2. Для игр (сейчас: {0})' '   2. For games (current: {0})') -f $inventory.CurrentGameFake)
    Write-Host (T '   0. Назад' '   0. Back')
    Write-Host ''
    Write-Host (T '   Доступные файлы:' '   Available files:')
    for ($i = 0; $i -lt $inventory.Fakes.Count; $i++) {
        Write-Host ('   {0,2}. {1}' -f ($i + 1), $inventory.Fakes[$i].BaseName)
    }
    Write-Host ''
    $type = Read-MenuChoice (T '   Выберите назначение файла: 1 — Discord, 2 — игры, 0 — назад' '   Choose where to use the file: 1 — Discord, 2 — games, 0 — back')
    if ($type -eq '0') { return }
    if ($type -notin @('1', '2')) { Write-Host (T '   Введите 1, 2 или 0.' '   Enter 1, 2, or 0.') -ForegroundColor Red; Pause-Menu; return }
    $pick = Read-MenuChoice (T '   Введите номер файла' '   Enter the file number')
    $index = 0
    if (-not [int]::TryParse($pick, [ref]$index)) { Write-Host (T '   Введите номер из списка.' '   Enter a number from the list.') -ForegroundColor Red; Pause-Menu; return }
    if ($index -lt 1 -or $index -gt $inventory.Fakes.Count) { Write-Host (T '   Такого номера нет в списке.' '   That number is not in the list.') -ForegroundColor Red; Pause-Menu; return }
    $fakeApplied = $false
    try {
        Set-ActiveFake -Target $(if ($type -eq '1') { 'discord' } else { 'game' }) -FakeBaseName $inventory.Fakes[$index - 1].BaseName
        $fakeApplied = $true
    } catch {
        Write-UiError $_.Exception.Message
    }
    if ($fakeApplied) { [void](Invoke-ZapretServiceRestartPrompt -Reason 'Фейки заменены') }
    Pause-Menu
}

function Invoke-MenuPause {
    $inputMinutes = Read-Host (T '   На сколько минут приостановить обход? Введите 1–1440; пустая строка — до нажатия Enter.' '   How many minutes should the bypass pause? Enter 1–1440; leave blank to wait until you press Enter.')
    $minutes = 0
    if (-not [string]::IsNullOrWhiteSpace($inputMinutes)) {
        if (-not [int]::TryParse($inputMinutes.Trim(), [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 1440) {
            Write-Host (T '   Введите целое число от 1 до 1440 или оставьте поле пустым.' '   Enter a whole number from 1 to 1440, or leave the field blank.') -ForegroundColor Red
            Pause-Menu
            return
        }
    }
    try { [void](Suspend-ZapretBypass -Minutes $minutes) }
    catch { Write-UiError $_.Exception.Message; Write-Log "pause failed: $($_.Exception.Message)" 'ERROR'; Pause-Menu }
}

function Invoke-MenuLanguage {
    Write-Host ''
    Write-Host '   ЯЗЫК ИНТЕРФЕЙСА / INTERFACE LANGUAGE' -ForegroundColor Cyan
    Write-Host (T ("   Сейчас: {0}" -f $(if ($script:UiLanguage -eq 'ru') { 'Русский' } else { 'English' })) ("   Current: {0}" -f $(if ($script:UiLanguage -eq 'ru') { 'Russian' } else { 'English' }))) -ForegroundColor DarkGray
    Write-Host '   1. Русский / Russian'
    Write-Host '   2. English / Английский'
    Write-Host '   0. Назад / Back'
    $choice = Read-MenuChoice (T '   Выберите язык' '   Choose a language')
    switch ($choice) {
        '1' {
            if (Set-InterfaceLanguage -Language ru) { Write-Host (T '   Готово. Интерфейс переключён на русский.' '   Done. The interface is now in Russian.') -ForegroundColor Green }
        }
        '2' {
            if (Set-InterfaceLanguage -Language en) { Write-Host (T '   Готово. Интерфейс переключён на английский.' '   Done. The interface is now in English.') -ForegroundColor Green }
        }
        '0' { }
        default { Write-Host (T '   Введите 1, 2 или 0.' '   Enter 1, 2, or 0.') -ForegroundColor Red }
    }
    Pause-Menu
}

function Invoke-Menu {
    param([switch]$SkipUpdateCheck)

    $updateCheckDone = $SkipUpdateCheck
    while ($true) {
        Invoke-ClearScreen
        Show-Banner

        if (-not $updateCheckDone) {
            $cfg = Get-Config
            if ($cfg.checkUpdates) {
                try { Invoke-UpdateCheck -Soft | Out-Null } catch { }
            }
            $updateCheckDone = $true
        }

        $ipset = Get-IpsetState
        $game  = Get-GameFilterPorts
        $cfg   = Get-Config

        $uiGame = switch ($game.status) {
            'enabled (TCP and UDP)' { T 'включён: TCP и UDP' 'on: TCP and UDP' }
            'enabled (TCP)'         { T 'включён: только TCP' 'on: TCP only' }
            'enabled (UDP)'         { T 'включён: только UDP' 'on: UDP only' }
            default                 { T 'выключен' 'off' }
        }
        $uiIpset = switch ($ipset) {
            'any'     { T 'все IP (может мешать сайтам)' 'all IPs (may affect sites)' }
            'loaded'  { T 'список загружен' 'list loaded' }
            'none'    { T 'не фильтруется' 'no IP filtering' }
            default   { T 'неизвестно' 'unknown' }
        }
        $uiUpdates = if ($cfg.checkUpdates) { T 'включена' 'on' } else { T 'выключена' 'off' }

        Write-Host (T '   :: СЛУЖБА' '   :: SERVICE')
        Write-Host (T '      1. Установить службу и выбрать стратегию' '      1. Install service and choose a strategy')
        Write-Host (T '      2. Удалить службу и драйвер' '      2. Remove service and driver')
        Write-Host (T '      3. Проверить состояние' '      3. Check status')
        Write-Host ''
        Write-Host (T '   :: НАСТРОЙКИ' '   :: SETTINGS')
        Write-Host ((T '      4. Игровой трафик        [{0}]' '      4. Game traffic          [{0}]') -f $uiGame)
        Write-Host ((T '      5. Фильтр IP (IPSet)     [{0}]' '      5. IP filter (IPSet)     [{0}]') -f $uiIpset)
        Write-Host ((T '      6. Проверка обновлений   [{0}]' '      6. Check for updates     [{0}]') -f $uiUpdates)
        Write-Host (T '      7. Сменить файлы подмены для Discord или игр' '      7. Change fake files for Discord or games')
        Write-Host ''
        Write-Host (T '   :: ОБНОВЛЕНИЯ' '   :: UPDATES')
        Write-Host (T '      8. Обновить IP-список' '      8. Update IP list')
        Write-Host (T '      9. Обновить записи hosts' '      9. Update hosts entries')
        Write-Host (T '      10. Проверить новую версию' '      10. Check for a new version')
        Write-Host ''
        Write-Host (T '   :: ИНСТРУМЕНТЫ' '   :: TOOLS')
        Write-Host (T '      11. Диагностика' '      11. Diagnostics')
        Write-Host (T '      12. Проверить стратегии вручную' '      12. Test strategies manually')
        Write-Host (T '      13. Автоматически подобрать стратегию' '      13. Find the best strategy automatically')
        Write-Host (T '      14. Показать список стратегий' '      14. Show available strategies')
        Write-Host (T '      15. DNS и защищённый DNS (DoH)' '      15. DNS and encrypted DNS (DoH)')
        Write-Host (T '      16. Настроить еженедельную перепроверку' '      16. Schedule a weekly re-check')
        Write-Host (T '      17. Собрать отчёт для поддержки' '      17. Create a support report')
        Write-Host (T '      18. Перенести настройки из старой папки' '      18. Import settings from an older folder')
        Write-Host (T '      19. Откатить последние изменения' '      19. Roll back the latest changes')
        Write-Host (T '      20. Мои сайты: добавить или исключить' '      20. My sites: include or exclude domains')
        Write-Host (T '      21. Создать или импортировать стратегию' '      21. Create or import a strategy')
        Write-Host (T '      22. Приостановить обход на время игры' '      22. Pause the bypass for a game')
        Write-Host (T '      23. Проверить сеть и качество соединения' '      23. Network and connection quality')
        Write-Host (T '      24. Язык интерфейса' '      24. Interface language')
        Write-Host (T '      25. Автонастройка: обычный или мобильный интернет' '      25. Guided auto-setup: regular or mobile internet')
        Write-Host ''
        Write-Host '   ----------------------------------------' -ForegroundColor DarkGray
        Write-Host (T '      0. Выход' '      0. Exit')
        Write-Host ''

        $choice = Read-MenuChoice (T '   Введите номер пункта (0–25)' '   Choose an option (0–25)')
        try {
            switch ($choice) {
                '1'  { Invoke-MenuInstall }
                '2'  { Invoke-MenuUninstall }
                '3'  { Invoke-MenuStatus; Pause-Menu }
                '4'  { Invoke-MenuGameFilter }
                '5'  { Invoke-MenuIpset }
                '6'  { Invoke-MenuCheckUpdatesSwitch }
                '7'  { Invoke-MenuFakes }
                '8'  {
                    try { Update-IpsetList } catch { Write-UiError $_.Exception.Message }
                    Pause-Menu
                }
                '9'  {
                    try { Update-HostsFile | Out-Null } catch { Write-UiError $_.Exception.Message }
                    Pause-Menu
                }
                '10' { Invoke-UpdateCheck -OpenBrowser | Out-Null; Pause-Menu }
                '11' { Invoke-Diagnostics; Pause-Menu }
                '12' {
                    $tester = Join-Path $root 'utils\test zapret.ps1'
                    if (Test-Path $tester) {
                        $psHost = (Get-WindowsSystemToolPath -Name 'powershell.exe')
                        if (-not $psHost) { $psHost = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
                        & $psHost -NoProfile -ExecutionPolicy Bypass -File $tester
                    } else {
                        Write-Host (T '   Не найден тестовый файл utils\test zapret.ps1. Переустановите или распакуйте программу заново.' '   Test utility utils\test zapret.ps1 was not found. Reinstall or re-extract the tool.') -ForegroundColor Red
                        Pause-Menu
                    }
                }
                '13' { Invoke-MenuAutoSelect }
                '14' { Show-StrategyList; Pause-Menu }
                '15' { Invoke-MenuDns }
                '16' { Invoke-MenuSchedule }
                '17' { Invoke-MenuSupportBundle }
                '18' { Invoke-MenuImportConfig }
                '19' { Invoke-MenuRollback }
                '20' { Invoke-MenuDomain }
                '21' { Invoke-MenuCloneStrategy }
                '22' { Invoke-MenuPause }
                '23' { Invoke-MenuNetworkTools }
                '24' { Invoke-MenuLanguage }
                '25' { Invoke-MenuAutoSetup }
                '0'  { return }
                default {
                    Write-Host (T 'Неверный номер. Выберите пункт от 0 до 25.' 'That number is not in the menu. Choose an option from 0 to 25.') -ForegroundColor Red
                    Pause-Menu
                }
            }
        } catch {
            Write-UiError $_.Exception.Message
            Write-Log "Menu error: $($_.Exception.Message)" 'ERROR'
            Pause-Menu
        }
    }
}

# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------

$actionName  = ([string]$Action).ToLowerInvariant()
$argsRest    = @()
if ($Rest) { $argsRest = @($Rest) }

$needsAdmin = $true
switch ($actionName) {
    'list'          { $needsAdmin = $false }
    'version'       { $needsAdmin = $false }
    'help'          { $needsAdmin = $false }
    'status'        { $needsAdmin = $false }
    'dns'           { $needsAdmin = $false }   # status works without elevation; write actions are elevated below
    'ping-test'     { $needsAdmin = $false }
    'mtu-check'     { $needsAdmin = -not ($Preview -or $NoInteractive) }
    'net-optimize'  { $needsAdmin = -not $Preview }
    'ipset'         { $needsAdmin = -not $Preview }
    'ipset-update'  { $needsAdmin = -not $Preview }
    'hosts-update'  { $needsAdmin = -not ($Preview -or $DryRun) }
    'schedule-autoselect' { $needsAdmin = $false }
    'health-check'  { $needsAdmin = $false }   # read-only probes; watchdog stays admin because it may heal
    'doctor'        { $needsAdmin = $false }   # read-only by default; -Fix repair warns when elevation is missing
    'fallback'      { $needsAdmin = $false }   # status + config toggle
    'export-config' { $needsAdmin = $false }   # packs user files only
    'profile'       { $needsAdmin = $false }   # only rewrites the managed block in list-exclude-user.txt
    'speed-test'    { $needsAdmin = $false }   # read-only download measurement
    'site-check'    { $needsAdmin = $false }   # read-only route + reachability probe
    'tray-autostart' { $needsAdmin = $false }  # HKCU Run key only
    'support-bundle' { $needsAdmin = $false }  # read-only diagnostics; zip lands on Desktop
    'export-strategy' { $needsAdmin = $false }
}
if ($actionName -eq 'dns' -and $argsRest.Count -gt 0 -and $argsRest[0].ToLowerInvariant() -in @('doh', 'reset', 'rollback', 'benchmark')) {
    $dnsReadOnlyPreview = $Preview -and $argsRest[0].ToLowerInvariant() -in @('doh', 'reset', 'rollback', 'benchmark')
    $needsAdmin = -not $dnsReadOnlyPreview
}

$scriptOnWindows = $true
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $scriptOnWindows = [bool]$IsWindows
}

if ($needsAdmin -and $scriptOnWindows -and -not (Test-IsAdmin)) {
    # Self-elevate: relaunch the same command line elevated.
    # Rebuild the full invocation, including named parameters already bound by PowerShell.
    $argList = Get-ZapretRestartArgumentLine -ScriptPath $PSCommandPath -Action $Action -RemainingArguments $Rest -BoundParameters $PSBoundParameters
    try {
        Start-Process -FilePath (Get-WindowsSystemToolPath -Name 'powershell.exe') -Verb RunAs -ArgumentList $argList | Out-Null
        exit 0
    } catch {
        Write-Host (T 'Для этой команды нужны права администратора. Подтвердите запрос Windows и запустите программу снова.' 'Administrator rights are required. Approve the Windows prompt and try again.') -ForegroundColor Red
        exit 1
    }
}

try {
    switch ($actionName) {
        'menu' {
            $configExists = Test-Path -LiteralPath (Join-Path $root 'config.json')
            $serviceInfo = Get-ZapretServiceInfo
            $isFirstRun = ($scriptOnWindows -and -not $NoInteractive -and (Test-OnboardingRequired -ConfigExists $configExists -ServiceInstalled ([bool]$serviceInfo.Installed)))
            if ($isFirstRun) {
                $languageChoice = Read-Host 'Язык интерфейса / Interface language: [1] Русский (по умолчанию / default)  [2] English'
                $firstRunLanguage = if ($languageChoice -and $languageChoice.Trim() -match '^(2|en|english)$') { 'en' } else { 'ru' }
                [void](Set-InterfaceLanguage -Language $firstRunLanguage)

                Write-Host ''
                Write-Host (T '   Добро пожаловать! Это первый запуск zapret.' '   Welcome! This is your first time using zapret.') -ForegroundColor Cyan
                Write-Host (T '   Сначала можно автоматически проверить стратегии и выбрать подходящую для вашей сети.' '   First, you can test the strategies automatically and find one that works on your network.') -ForegroundColor DarkGray
                $answer = Read-Host (T '   Проверить стратегии сейчас? Это может занять несколько минут. [Д/н]' '   Test the strategies now? This may take a few minutes. [Y/n]')
                if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim() -match '^(y|yes|д|да)$') {
                    try { [void](Invoke-AutoSelect) }
                    catch { Write-UiError (T ("Автоподбор стратегии: {0}" -f $_.Exception.Message) ("Automatic strategy selection: {0}" -f $_.Exception.Message)); Write-Log "onboarding auto-select failed: $($_.Exception.Message)" 'ERROR' }
                }
            }
            Initialize-UserLists | Out-Null
            Invoke-Menu
        }
        'list' {
            Get-Strategies | ForEach-Object {
                Write-Host ('{0,-20} {1}' -f $_.id, (Get-UiStrategyDescription -Strategy $_))
            }
        }
        'run' {
            $strategy = Resolve-StrategyArg -StrategyArgs $argsRest
            if (-not $strategy) { exit 1 }
            Initialize-UserLists | Out-Null
            $proc = Start-ZapretStrategy -Strategy $strategy
            Write-Host (T ("Стратегия '{0}' запущена (PID {1})." -f $strategy.id, $proc.Id) ("Strategy '{0}' started (PID {1})." -f $strategy.id, $proc.Id)) -ForegroundColor Green
        }
        'install' {
            $strategy = Resolve-StrategyArg -StrategyArgs $argsRest
            if (-not $strategy) { exit 1 }
            Initialize-UserLists | Out-Null
            Install-ZapretService -StrategyId $strategy.id
        }
        'uninstall' {
            [void](Remove-ZapretServices -RemoveHostsBlock:$RemoveHostsBlock)
        }
        'status' {
            Invoke-MenuStatus
        }
        'test' {
            if (-not $scriptOnWindows) { Write-Host (T 'Ручная проверка стратегий работает только в Windows: для неё запускается winws.exe.' 'Manual strategy tests only run on Windows because they launch winws.exe.') -ForegroundColor Yellow; exit 0 }
            $tester = Join-Path $root 'utils\test zapret.ps1'
            if (-not (Test-Path $tester)) { throw "Test utility not found at $tester" }
            $psHost = (Get-WindowsSystemToolPath -Name 'powershell.exe')
            if (-not $psHost) { $psHost = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
            if (-not $psHost) { throw 'No PowerShell host found to run the test suite.' }
            & $psHost -NoProfile -ExecutionPolicy Bypass -File $tester
        }
        'diagnostics' {
            Invoke-Diagnostics -NoInteractive:$NoInteractive
        }
        'doctor' {
            $doctorReport = Invoke-ZapretDoctor -Fix:$Fix -Deep:$Deep
            exit $doctorReport.ExitCode
        }
        'fallback' {
            $sub = $Mode
            if (-not $sub -and $argsRest.Count -ge 1 -and $argsRest[0] -notmatch '^-') { $sub = $argsRest[0] }
            switch -Regex ($sub) {
                '^(on|enable|включить)$' {
                    [void](Update-Config -Changes @{ strategyFallback = $true })
                    Write-Host (T 'Быстрое переключение на запасные стратегии включено.' 'Quick failover to backup strategies is enabled.')
                }
                '^(off|disable|выключить)$' {
                    [void](Update-Config -Changes @{ strategyFallback = $false })
                    Write-Host (T 'Быстрое переключение на запасные стратегии выключено. Автозащита будет сразу запускать полный подбор.' 'Quick failover is disabled. The watchdog will run the full benchmark directly.')
                }
                default {
                    Write-Host (Get-StrategyFallbackStatusText)
                    Write-Host (T ('Режим: {0}.' -f $(if (Get-StrategyFallbackEnabled) { 'включён' } else { 'выключен' })) ('Mode: {0}.' -f $(if (Get-StrategyFallbackEnabled) { 'enabled' } else { 'disabled' })))
                }
            }
        }
        'ipset' {
            $mode = $Mode
            if (-not $mode -and $argsRest.Count -ge 1 -and $argsRest[0] -notmatch '^-') { $mode = $argsRest[0] }
            if (-not $mode) {
                $state = Get-IpsetState
            $uiState = switch ($state) { 'loaded' { T 'список загружен' 'list loaded' } 'none' { T 'отключён' 'off' } 'any' { T 'все адреса' 'all addresses' } default { T 'неизвестно' 'unknown' } }
            Write-Host ((T 'Фильтр IP: {0}' 'IP filter: {0}') -f $uiState)
            } else {
                Set-IpsetMode -Mode $mode.ToLowerInvariant() -Preview:$Preview
                if (-not $Preview) { [void](Invoke-ZapretServiceRestartPrompt -Reason 'IPSet изменён') }
            }
        }
        'ipset-update' {
            Update-IpsetList -Preview:$Preview
        }
        'hosts-update' {
            $hp = $HostsPath
            if (-not $hp -and $argsRest.Count -ge 1 -and $argsRest[0] -notmatch '^-') { $hp = $argsRest[0] }
            # Guard: the managed block must only ever be merged into a real 'hosts' file.
            # Arbitrary -HostsPath (writable by any caller as admin) could clobber other files.
            if ($hp -and -not $DryRun) {
                $leaf = Split-Path -Leaf $hp
                if ($leaf -ine 'hosts') { throw "-HostsPath only accepts a file named 'hosts' (got '$leaf'). Use -DryRun to preview other paths." }
            }
            Update-HostsFile -DryRun:($DryRun -or $Preview) -Preview:$Preview -HostsPath $hp | Out-Null
        }
        'check-updates' {
            Invoke-UpdateCheck -Soft:$Soft -OpenBrowser:$OpenBrowser | Out-Null
        }
        'game-filter' {
            $mode = $Mode
            if (-not $mode -and $argsRest.Count -ge 1 -and $argsRest[0] -notmatch '^-') { $mode = $argsRest[0].ToLowerInvariant() }
            $tcp = $TcpPorts
            $udp = $UdpPorts
            $changes = @{}
            switch ($mode) {
                'off'      { $changes['gameFilterMode'] = 'disabled' }
                'disable'  { $changes['gameFilterMode'] = 'disabled' }
                'all'      { $changes['gameFilterMode'] = 'all' }
                'tcp'      { $changes['gameFilterMode'] = 'tcp' }
                'udp'      { $changes['gameFilterMode'] = 'udp' }
                $null      { }
                default    { throw "Unknown game-filter mode '$mode' (expected: off|all|tcp|udp)" }
            }
            if ($tcp) { if (Test-PortRange $tcp) { $changes['gameFilterTcp'] = $tcp } else { throw "Invalid TCP port range '$tcp'" } }
            if ($udp) { if (Test-PortRange $udp) { $changes['gameFilterUdp'] = $udp } else { throw "Invalid UDP port range '$udp'" } }
            if ($changes.Count -gt 0) {
                $cfg = Update-Config $changes
                $gameModeLabel = switch ($cfg.gameFilter.mode) {
                    'disabled' { T 'выключен' 'off' }
                    'all'      { T 'TCP и UDP' 'TCP and UDP' }
                    'tcp'      { T 'только TCP' 'TCP only' }
                    'udp'      { T 'только UDP' 'UDP only' }
                }
                Write-Host ((T 'Игровой фильтр: {0} (TCP: {1}, UDP: {2})' 'Game traffic filter: {0} (TCP: {1}, UDP: {2})') -f $gameModeLabel, $cfg.gameFilter.tcp, $cfg.gameFilter.udp) -ForegroundColor Green
                [void](Invoke-ZapretServiceRestartPrompt -Reason 'Игровой фильтр изменён')
            } else {
                $cfg = Get-Config
                $gameModeLabel = switch ($cfg.gameFilter.mode) {
                    'disabled' { T 'выключен' 'off' }
                    'all'      { T 'TCP и UDP' 'TCP and UDP' }
                    'tcp'      { T 'только TCP' 'TCP only' }
                    'udp'      { T 'только UDP' 'UDP only' }
                    default    { T 'неизвестно' 'unknown' }
                }
                Write-Host ((T 'Игровой фильтр: {0} (TCP: {1}, UDP: {2})' 'Game traffic filter: {0} (TCP: {1}, UDP: {2})') -f $gameModeLabel, $cfg.gameFilter.tcp, $cfg.gameFilter.udp)
            }
        }
        'fakes' {
            if ($argsRest.Count -lt 2) { throw 'Usage: fakes <discord|game> <fake-name>   (fake-name: base name of a .bin file in bin\)' }
            Set-ActiveFake -Target $argsRest[0].ToLowerInvariant() -FakeBaseName $argsRest[1]
            [void](Invoke-ZapretServiceRestartPrompt -Reason 'Фейки заменены')
        }
        'voice-check' {
            $voiceSub = 'check'
            if ($argsRest.Count -ge 1 -and $argsRest[0] -notmatch '^-') { $voiceSub = $argsRest[0].ToLowerInvariant() }
            switch ($voiceSub) {
                'fix' {
                    $voiceRepair = Repair-DiscordVoice
                    if (-not $voiceRepair.VoiceLikely) { exit 1 }
                }
                'next-fake' {
                    $voiceRepair = Repair-DiscordVoice -NextFakeOnly
                    if (-not $voiceRepair.Repaired) { exit 1 }
                }
                'check' {
                    $voiceSummary = Test-DiscordVoiceConnection
                    if (-not $voiceSummary.VoiceLikely) { exit 1 }
                }
                default { throw 'Usage: voice-check [check|fix|next-fake]' }
            }
        }
        'auto-select' {
            $tsArgs = @{}
            if ($TimeoutSec -gt 0) { $tsArgs['TimeoutSec'] = $TimeoutSec }
            if ($Carrier) {
                Invoke-AutoSelect -Install:$Install -NoInteractive:$NoInteractive -Deep:$Deep -CheckFreeze:$CheckFreeze -Fast:$Fast -Scheduled:$Scheduled -Carrier $Carrier @tsArgs | Out-Null
            } else {
                Invoke-AutoSelect -Install:$Install -NoInteractive:$NoInteractive -Deep:$Deep -CheckFreeze:$CheckFreeze -Fast:$Fast -Scheduled:$Scheduled @tsArgs | Out-Null
            }
        }
        'auto-setup' {
            if ($argsRest.Count -gt 0) { throw 'Usage: auto-setup [-Carrier mts|megafon|tele2|yota] [-Fast] [-Deep] [-CheckFreeze] [-Install] [-EnableSchedule]; without -Carrier the wizard asks regular or mobile, then asks the carrier for mobile.' }
            if ($Carrier) {
                Invoke-AutoSetup -Install:$Install -NoInteractive:$NoInteractive -Fast:$Fast -Deep:$Deep -CheckFreeze:$CheckFreeze -EnableSchedule:$EnableSchedule -Carrier $Carrier | Out-Null
            } else {
                Invoke-AutoSetup -Install:$Install -NoInteractive:$NoInteractive -Fast:$Fast -Deep:$Deep -CheckFreeze:$CheckFreeze -EnableSchedule:$EnableSchedule | Out-Null
            }
        }
        'discover-domains' {
            if ($argsRest.Count -gt 0) { throw 'Usage: discover-domains' }
            [void](Invoke-DomainDiscovery)
        }
        'pause' {
            if ($argsRest.Count -gt 1) { throw 'Usage: pause [Minutes] (1..1440; omit Minutes to wait for Enter)' }
            $pauseMinutes = 0
            if ($argsRest.Count -eq 1 -and (-not [int]::TryParse($argsRest[0], [ref]$pauseMinutes) -or $pauseMinutes -lt 1 -or $pauseMinutes -gt 1440)) {
                throw 'Minutes must be a whole number from 1 to 1440.'
            }
            [void](Suspend-ZapretBypass -Minutes $pauseMinutes)
        }
        'export-strategy' {
            if ($argsRest.Count -ne 1) { throw 'Usage: export-strategy <id>' }
            [void](Export-UserStrategy -Id $argsRest[0])
        }
        'import-strategy' {
            if ($argsRest.Count -ne 1) { throw 'Usage: import-strategy <zapret1:Base64> [-NewId <id>]' }
            $strategy = Import-UserStrategy -ShareString $argsRest[0] -NewId $NewId
            $answer = $null
            try { $answer = Read-Host (T ("   Установить стратегию '{0}' как службу сейчас? [д/Н]" -f $strategy.id) ("   Install strategy '{0}' as a service now? [y/N]" -f $strategy.id)) } catch { }
            if ($answer -match '^(y|yes|д|да)$') { [void](Install-ZapretService -StrategyId $strategy.id) }
        }
        'rollback' {
            [void](Restore-RollbackSnapshot)
        }
        'domain' {
            $sub = if ($argsRest.Count -ge 1) { $argsRest[0].ToLowerInvariant() } else { 'list' }
            switch ($sub) {
                'add' {
                    if ($argsRest.Count -lt 2) { throw 'Usage: domain add <domain-or-url>' }
                    [void](Add-DomainToList -Domain $argsRest[1] -Kind general)
                    [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён')
                }
                'exclude' {
                    if ($argsRest.Count -lt 2) { throw 'Usage: domain exclude <domain-or-url>' }
                    [void](Add-DomainToList -Domain $argsRest[1] -Kind exclude)
                    [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён')
                }
                'remove' {
                    if ($argsRest.Count -ne 2) { throw 'Usage: domain remove <domain-or-url>' }
                    $removed = Remove-DomainFromLists -Domain $argsRest[1]
                    if ($removed.TotalRemoved -gt 0) { [void](Invoke-ZapretServiceRestartPrompt -Reason 'Список доменов изменён') }
                }
                'list' {
                    foreach ($kind in @('general', 'exclude')) {
                        $f = Join-Path $root ('lists\list-{0}-user.txt' -f $kind)
                        $kindLabel = if ($kind -eq 'general') { T 'Сайты в списке обхода' 'Bypass list' } else { T 'Исключённые сайты' 'Excluded sites' }
                        Write-Host ("== {0} ({1}) ==" -f $kindLabel, $f) -ForegroundColor Cyan
                        if (Test-Path $f) { Get-Content $f | ForEach-Object { Write-Host "   $_" } } else { Write-Host (T '   (список пуст)' '   (list is empty)') }
                    }
                }
                default { throw "Unknown domain sub-command '$sub' (expected: add|exclude|remove|list)" }
            }
        }
        'clone-strategy' {
            if ($argsRest.Count -lt 2) { throw 'Usage: clone-strategy <base-id> <new-id>' }
            [void](New-UserStrategy -BaseId $argsRest[0] -NewId $argsRest[1])
            Write-Host ((T 'Чтобы установить её, выполните: zapret.ps1 install {0}' 'To install it, run: zapret.ps1 install {0}') -f $argsRest[1].ToLowerInvariant()) -ForegroundColor DarkGray
        }
        'support-bundle' {
            [void](New-SupportBundle -IncludeSensitive:$IncludeSensitive -Preview:$Preview)
        }
        'import-config' {
            if ($argsRest.Count -lt 1) { throw 'Usage: import-config <old-zapret-folder|backup.zip> [-NoInstall]' }
            [void](Import-ExternalConfig -SourcePath $argsRest[0] -NoInstall:$NoInstall)
        }
        'export-config' {
            $dest = $null
            if ($argsRest.Count -ge 1 -and $argsRest[0] -notmatch '^-') { $dest = $argsRest[0] }
            [void](Export-ZapretConfig -Destination $dest)
        }
        'dns' {
            $sub = if ($argsRest.Count -ge 1) { $argsRest[0].ToLowerInvariant() } else { 'status' }
            switch ($sub) {
                'status' {
                    if ($argsRest.Count -gt 1) { throw 'Usage: dns status' }
                    Write-DnsStatus
                }
                'benchmark' {
                    if ($argsRest.Count -gt 1) { throw 'Usage: dns benchmark [-Preview]' }
                    [void](Invoke-DnsBenchmark -NoPrompt:$NoInteractive -Preview:$Preview)
                }
                'doh' {
                    if ($argsRest.Count -ne 2) { throw 'Usage: dns doh <cloudflare|google|quad9|adguard|yandex> [-Preview]' }
                    $provider = $argsRest[1].ToLowerInvariant()
                    if ($provider -notin @('cloudflare','google','quad9','adguard','yandex')) { throw "Unknown provider '$provider' (expected: cloudflare|google|quad9|adguard|yandex)" }
                    Enable-Doh -Provider $provider -Preview:$Preview
                }
                'reset' {
                    if ($argsRest.Count -gt 1) { throw 'Usage: dns reset [-Preview]' }
                    Reset-DnsToDhcp -Preview:$Preview
                }
                'rollback' {
                    if ($argsRest.Count -gt 1) { throw 'Usage: dns rollback [-Preview]' }
                    [void](Restore-DnsRollbackSnapshot -Preview:$Preview)
                }
                default { throw "Unknown dns sub-command '$sub' (expected: status|benchmark|doh|reset|rollback)" }
            }
        }
        'net-optimize' {
            if ($argsRest.Count -gt 0) { throw 'Usage: net-optimize [-Revert] [-Preview]' }
            [void](Invoke-NetworkOptimize -Revert:$Revert -Preview:$Preview)
        }
        'mtu-check' {
            if ($argsRest.Count -gt 0) { throw 'Usage: mtu-check [-Preview]' }
            [void](Invoke-MtuCheck -NoPrompt:$NoInteractive -Preview:$Preview)
        }
        'ping-test' {
            if ($argsRest.Count -gt 0) { throw 'Usage: ping-test' }
            [void](Invoke-LineQualityTest)
        }
        'schedule-autoselect' {
            $sub = if ($argsRest.Count -ge 1) { $argsRest[0].ToLowerInvariant() } else { 'status' }
            switch ($sub) {
                'enable'  { Set-AutoSelectSchedule -Enable }
                'disable' { Set-AutoSelectSchedule -Disable }
                'status'  {
                    if (Test-AutoSelectSchedule) { Write-Host (T 'Еженедельная проверка включена (по воскресеньям в 03:30 от имени SYSTEM).' 'Weekly re-check is on (Sundays at 03:30 as SYSTEM).') }
                    else { Write-Host (T 'Еженедельная проверка не настроена. Включить: zapret.ps1 schedule-autoselect enable' 'Weekly re-check is not scheduled. Enable it with: zapret.ps1 schedule-autoselect enable') }
                }
                default { throw "Unknown schedule-autoselect sub-command '$sub' (expected: enable|disable|status)" }
            }
        }
        'health-check' {
            if ($argsRest.Count -gt 0) { throw 'Usage: health-check' }
            $probe = Invoke-BypassHealthProbe
            foreach ($row in $probe.Rows) {
                $mark = if ($row.Ok) { 'OK ' } else { 'FAIL' }
                $tail = if ($row.Ok) { ('{0} ms' -f $row.Ms) } else { [string]$row.Reason }
                Write-Host (' [{0}] {1,-22} {2}' -f $mark, $row.Name, $tail) -ForegroundColor $(if ($row.Ok) { 'Green' } else { 'Red' })
            }
            Write-Host (T ("Обход отвечает: {0} из {1}." -f $probe.Passed, $probe.Total) ("The bypass answers on {0} of {1} endpoints." -f $probe.Passed, $probe.Total))
            if ($probe.Total -gt 0 -and $probe.Passed -ge ($probe.Total - 1)) { exit 0 }
            if ($probe.Total -gt 0 -and $probe.Passed * 2 -ge $probe.Total) { exit 1 }
            exit 2
        }
        'profile' {
            $sub = if ($argsRest.Count -ge 1) { $argsRest[0].ToLowerInvariant() } else { '' }
            if (-not $sub) {
                Write-Host (T ("Текущий профиль обхода: {0}." -f (Get-BypassProfile)) ("Current bypass profile: {0}." -f (Get-BypassProfile)))
                foreach ($p in (Get-BypassProfiles)) { Write-Host ("  {0,-15} {1}" -f $p.Id, $p.NameRu) }
                Write-Host (T 'Установка: zapret.ps1 profile <id>' 'Set with: zapret.ps1 profile <id>')
            } else {
                $knownIds = @((Get-BypassProfiles) | ForEach-Object { [string]$_.Id })
                if ($knownIds -notcontains $sub) {
                    throw (T ("Неизвестный профиль '{0}'. Доступные: {1}." -f $sub, ($knownIds -join ', ')) ("Unknown profile '{0}'. Available: {1}." -f $sub, ($knownIds -join ', ')))
                }
                $result = Set-BypassProfile -Profile $sub
                Write-Host (T ("Применён профиль '{0}': исключено доменов: {1}. Перезапустите службу, чтобы изменения вступили в силу." -f $result.Profile, $result.Domains.Count) ("Profile '{0}' applied: {1} domains excluded. Restart the service to apply." -f $result.Profile, $result.Domains.Count))
            }
        }
        'site-check' {
            if ($argsRest.Count -lt 1) { throw (T 'Использование: zapret.ps1 site-check <url|домен>' 'Usage: zapret.ps1 site-check <url|domain>') }
            $check = Invoke-SiteCheck -InputText ($argsRest -join ' ')
            Write-Host (T ("Сайт: {0}" -f $check.Domain) ("Site: {0}" -f $check.Domain))
            Write-Host ('  ' + $check.NoteRu)
            $probeLine = if ($check.ProbeOk) { (T ("отвечает, {0} мс" -f $check.ProbeMs) ("answers in {0} ms" -f $check.ProbeMs)) } else { T 'не отвечает' 'no answer' }
            $transferLine = switch ($check.TransferState) {
                'full'  { T (", передача {0:N1} КБ/с" -f $check.TransferKBs) (", transfer {0:N1} KB/s" -f $check.TransferKBs) }
                'small' { T ', страница меньше 64 КБ' ', page is smaller than 64 KB' }
                'freeze' { T ', передача зависает' ', transfer freezes' }
                default { '' }
            }
            Write-Host ('  ' + $probeLine + $transferLine)
            Write-Host (T ("Итог: {0}" -f $check.VerdictRu) ("Result: {0}" -f $check.VerdictRu)) -ForegroundColor Cyan
        }
        'tray-autostart' {
            $sub = if ($argsRest.Count -ge 1) { $argsRest[0].ToLowerInvariant() } else { 'status' }
            switch ($sub) {
                'enable'  { [void](Set-TrayAutostart -Mode 'enable') }
                'disable' { [void](Set-TrayAutostart -Mode 'disable') }
                'status'  {
                    $state = Get-TrayAutostartState
                    $text = if ($state.Enabled) { T 'Автозапуск трея включён.' 'Tray autostart is on.' } else { T 'Автозапуск трея выключен.' 'Tray autostart is off.' }
                    Write-Host $text
                }
                default   { throw (T 'Использование: zapret.ps1 tray-autostart [enable|disable|status]' 'Usage: zapret.ps1 tray-autostart [enable|disable|status]') }
            }
        }
        'speed-test' {
            if ($argsRest.Count -gt 0) { throw 'Usage: speed-test' }
            $speed = Invoke-SpeedTest
            foreach ($row in $speed.Rows) {
                $line = if ($row.Ok) { ('{0,10:N1} КБ/с' -f $row.SpeedKBs) } else { 'нет данных' }
                Write-Host (' {0,-16} {1}' -f $row.Name, $line) -ForegroundColor $(if ($row.Ok) { 'Green' } else { 'Red' })
            }
            $verdictText = switch ($speed.Verdict) {
                'excellent' { T 'Скорость отличная.' 'Speed is excellent.' }
                'ok'        { T 'Скорость нормальная.' 'Speed is normal.' }
                'slow'      { T 'Скорость низкая — обход или канал замедляет трафик.' 'Speed is low - the bypass or the channel slows things down.' }
                default     { T 'Скачать данные не удалось.' 'Could not download data.' }
            }
            Write-Host (T ("Итог: {0:N1} КБ/с. {1}" -f $speed.BestKBs, $verdictText) ("Result: {0:N1} KB/s. {1}" -f $speed.BestKBs, $verdictText))
        }
        'watchdog' {
            $sub = if ($argsRest.Count -ge 1) { $argsRest[0].ToLowerInvariant() } else { 'run' }
            switch ($sub) {
                'run'     { [void](Invoke-WatchdogCheck -Scheduled:$Scheduled -AutoHeal) }
                'enable'  { Set-WatchdogSchedule -Enable }
                'disable' { Set-WatchdogSchedule -Disable }
                'status'  { Write-Host (Get-WatchdogStatusText) }
                default { throw "Unknown watchdog sub-command '$sub' (expected: run|enable|disable|status)" }
            }
        }
        'version' {
            Write-Host "zapret-discord-youtube v$(Get-LocalVersion)"
        }
        'help' {
            $helpLines = @(
                (T 'zapret — команды' 'zapret — command reference'),
                (T 'Запустите zapret.bat, чтобы открыть меню.' 'Run zapret.bat to open the interactive menu.'),
                (T 'Основные команды:' 'Common commands:'),
                (T '  list                         Показать доступные стратегии' '  list                         Show available strategies'),
                (T '  status                       Показать состояние служб и фильтров' '  status                       Show service and filter status'),
                (T '  install <id>                 Установить стратегию как службу' '  install <id>                 Install a strategy as a service'),
                (T '  run <id>                     Запустить стратегию до закрытия окна' '  run <id>                     Run a strategy until the window closes'),
                (T '  auto-select                  Проверить и подобрать стратегию' '  auto-select                  Test and choose a strategy'),
                (T '  auto-setup                   Выбрать обычный/мобильный интернет, затем настроить; согласие на изменения отдельно' '  auto-setup                   Choose regular/mobile internet, then configure; changes require separate consent'),
                (T '  auto-setup -Carrier yota    Сразу выбрать мобильный профиль Йота' '  auto-setup -Carrier yota    Select the Yota mobile profile directly'),
                (T '  auto-setup -EnableSchedule  Явно включить еженедельную перепроверку' '  auto-setup -EnableSchedule  Explicitly enable the weekly re-check'),
                (T '  auto-setup -NoInteractive  Только подобрать; ничего не применять' '  auto-setup -NoInteractive  Benchmark only; do not apply changes'),
                (T '  diagnostics                  Проверить настройки и возможные конфликты' '  diagnostics                  Check settings and possible conflicts'),
                (T '  voice-check                  Проверить голосовой путь Discord и конфликты' '  voice-check                  Check the Discord voice path and conflicts'),
                (T '  test                         Запустить подробную проверку стратегий' '  test                         Run detailed strategy tests'),
                (T '  dns status                   Показать текущие DNS-настройки' '  dns status                   Show current DNS settings'),
                (T '  dns doh <провайдер>          Включить защищённый DNS (DoH)' '  dns doh <provider>           Enable encrypted DNS (DoH)'),
                (T '  pause [минуты]               Временно приостановить обход' '  pause [minutes]              Pause the bypass temporarily'),
                (T '  rollback                     Отменить последние изменения' '  rollback                     Undo the latest changes'),
                (T '  support-bundle               Собрать отчёт для поддержки' '  support-bundle               Create a support report'),
                (T 'Краткая справка: zapret.ps1 help. Полное руководство: README.md.' 'Quick help: zapret.ps1 help. Full guide: README.md.'),
                (T 'Полная документация: README.md' 'Full documentation: README.md')
            )
            $helpLines | ForEach-Object { Write-Host $_ }
        }
        default {
            Write-Host (T ("Неизвестная команда '{0}'." -f $Action) ("Unknown command '{0}'." -f $Action)) -ForegroundColor Red
            Write-Host (T 'Команды: menu, list, run, install, uninstall, status, test, diagnostics, auto-select, auto-setup, pause, discover-domains, dns, net-optimize, mtu-check, ping-test, schedule-autoselect,' 'Commands: menu, list, run, install, uninstall, status, test, diagnostics, auto-select, auto-setup, pause, discover-domains, dns, net-optimize, mtu-check, ping-test, schedule-autoselect,') -ForegroundColor Yellow
            Write-Host 'support-bundle, import-config, rollback, domain, clone-strategy, export-strategy, import-strategy' -ForegroundColor Yellow
            Write-Host 'health-check, watchdog, profile, speed-test, site-check, tray-autostart' -ForegroundColor Yellow
            Write-Host 'ipset, ipset-update, hosts-update, check-updates, game-filter, fakes, voice-check, version, help' -ForegroundColor Yellow
            exit 1
        }
    }
} catch {
    Write-Host ''
    Write-UiError (T ("Ошибка: {0}" -f $_.Exception.Message) ("Error: {0}" -f $_.Exception.Message))
    Write-Log "Fatal error in action '$actionName': $($_.Exception.Message)" 'ERROR'
    exit 1
}
