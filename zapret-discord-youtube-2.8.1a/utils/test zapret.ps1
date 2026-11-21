$hasErrors = $false

$rootDir = Split-Path $PSScriptRoot
$modulePath = Join-Path $rootDir 'src\Zapret.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
} else {
    Write-Host 'Не найден модуль src\Zapret.psm1. Распакуйте архив заново. / Missing src\Zapret.psm1. Please extract the archive again.' -ForegroundColor Red
    exit 1
}
$script:UiLanguage = Get-UiLanguage
function T {
    param([Parameter(Mandatory = $true)][string]$Russian, [Parameter(Mandatory = $true)][string]$English)
    return (Get-UiText -Russian $Russian -English $English -Language $script:UiLanguage)
}

$listsDir = Join-Path $rootDir "lists"
$utilsDir = Join-Path $rootDir "utils"
$resultsDir = Join-Path $utilsDir "test results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

# Define functions early
function Get-IpsetStatus {
    # Delegates to the module parser (single source of truth).
    return (Get-IpsetState)
}

function Wait-WinwsReady {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt 5000) {
        if (Get-Process -Name "winws" -ErrorAction SilentlyContinue) {
            Start-Sleep -Milliseconds 300
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Switch-TestIpsetMode {
    param([string]$mode)
    $listFile = Join-Path $listsDir "ipset-all.txt"
    $backupFile = Join-Path $listsDir "ipset-all.test-backup.txt"
    if ($mode -eq "any") {
        # Always backup current file (even if none)
        if (Test-Path $listFile) {
            Copy-Item $listFile $backupFile -Force
        } else {
            # If none, create empty backup
            "" | Out-File $backupFile -Encoding UTF8
        }
        # Make file empty
        "" | Out-File $listFile -Encoding UTF8
    } elseif ($mode -eq "restore") {
        if (Test-Path $backupFile) {
            Move-Item $backupFile $listFile -Force
        }
    }
}

# Pause that tolerates stray keystrokes and non-interactive hosts.
# Tests run for minutes, so any key pressed meanwhile stays in the console
# input buffer and would be swallowed instantly by a bare ReadKey.
function Wait-AnyKey {
    param([string]$message = $null)
    if ([string]::IsNullOrWhiteSpace($message)) { $message = T 'Нажмите любую клавишу, чтобы закрыть окно…' 'Press any key to close…' }
    Write-Host $message -ForegroundColor Yellow
    try {
        while ([System.Console]::KeyAvailable) { [void][System.Console]::ReadKey($true) }
        [void][System.Console]::ReadKey($true)
    } catch {
        # No interactive console (stdin redirected): ReadKey throws here
        [void](Read-Host)
    }
}

trap {
    Write-Host (T '[ОШИБКА] Проверка прервана. Восстанавливаю список IP…' '[ERROR] Test interrupted. Restoring the IP list…') -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Switch-TestIpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
    Wait-AnyKey
    break
}

function New-OrderedDict { New-Object System.Collections.Specialized.OrderedDictionary }
function Add-OrSet {
    param($dict, $key, $val)
    if ($dict.Contains($key)) { $dict[$key] = $val } else { $dict.Add($key, $val) }
}

# Convert raw target value to structured target (supports PING:ip for ping-only targets)
function Convert-Target {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value -like "PING:*") {
        $ping = $Value -replace '^PING:\s*', ''
        $url = $null
        $pingTarget = $ping
    } else {
        $url = $Value
        $pingTarget = $url -replace "^https?://", "" -replace "/.*$", ""
    }

    return (New-Object PSObject -Property @{
        Name       = $Name
        Url        = $url
        PingTarget = $pingTarget
    })
}

# DPI checker defaults (override via MONITOR_* env vars like in monitor.ps1)
$dpiTimeoutSeconds = 5
$dpiRangeBytes = 65536
$defaultMaxParallel = [Math]::Min(16, [Math]::Max(8, [Environment]::ProcessorCount * 2))
$dpiMaxParallel = $defaultMaxParallel
$dpiCustomHost = $env:MONITOR_HOST
if ($env:MONITOR_TIMEOUT) { [int]$dpiTimeoutSeconds = $env:MONITOR_TIMEOUT }
if ($env:MONITOR_RANGE) { [int]$dpiRangeBytes = $env:MONITOR_RANGE }
if ($env:MONITOR_MAX_PARALLEL) { [int]$dpiMaxParallel = $env:MONITOR_MAX_PARALLEL }
$standardCurlTimeout = 4
$standardMaxParallel = $defaultMaxParallel
if ($env:TEST_CURL_TIMEOUT) { [int]$standardCurlTimeout = $env:TEST_CURL_TIMEOUT }
if ($env:TEST_MAX_PARALLEL) { [int]$standardMaxParallel = $env:TEST_MAX_PARALLEL }

function Get-DpiSuite {
    # Suite sourced from https://github.com/hyperion-cs/dpi-checkers (Apache-2.0 license)
    # Original copyright retained from dpi-checkers repository
    $url = "https://hyperion-cs.github.io/dpi-checkers/ru/tcp-16-20/suite.v2.json"

    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        (Invoke-RestMethod -Uri $url -TimeoutSec $dpiTimeoutSeconds) |
            # The suite JSON drives which hosts we send 64 KB payloads to - only accept
            # plausible hostnames (no userinfo/ports/slashes), anything else is dropped.
            Where-Object { $_.host -is [string] -and $_.host -match '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' -and $_.host -match '\.' } |
            Select-Object `
                @{n='Id';       e={$_.id}},
                @{n='Provider'; e={$_.provider}},
                @{n='Country';  e={$_.country}},
                @{n='Host';     e={$_.host}}
    }
    catch {
        Write-Host (T '[ПРЕДУПРЕЖДЕНИЕ] Не удалось загрузить список DPI-проверок.' '[WARNING] Could not download the DPI test list.') -ForegroundColor Yellow
        @()
    }
}

function Build-DpiTargets {
    param(
        [string]$CustomHost
    )

    $suite = Get-DpiSuite
    $targets = @()

    if ($CustomHost) {
        $targets += @{ Id = "CUSTOM"; Provider = "Custom"; Country = "💡"; Host = $CustomHost }
    } else {
        foreach ($entry in $suite) {
            $targets += @{ Id = $entry.Id; Country = $entry.Country; Provider = $entry.Provider; Host = $entry.Host }
        }
    }

    return $targets
}

function Invoke-DpiSuite {
    param(
        [array]$Targets,
        [int]$TimeoutSeconds,
        [int]$RangeBytes,
        [int]$MaxParallel
    )

    $tests = @(
        @{ Label = "HTTP";   Args = @("--http1.1") },
        @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
        @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
    )

    $rangeSpec = "0-$($RangeBytes - 1)"
    $warnDetected = $false

    Write-Host (T ('[ИНФО] Адресов: {0} (свой адрес заменяет список). Диапазон: {1} байт; тайм-аут: {2} с' -f $Targets.Count, $rangeSpec, $TimeoutSeconds) ('[INFO] Targets: {0} (custom URL replaces the built-in list). Range: {1} bytes; timeout: {2}s' -f $Targets.Count, $rangeSpec, $TimeoutSeconds)) -ForegroundColor Cyan
    Write-Host (T ('[ИНФО] Запускаю проверки замирания TCP на 16–20 КБ (параллельно: {0})…' -f $MaxParallel) ('[INFO] Starting TCP 16–20 KB freeze checks (parallel workers: {0})…' -f $MaxParallel)) -ForegroundColor DarkGray

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $runspacePool.Open()

    $payload = New-Object byte[] $RangeBytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($payload)

    $payloadFile = New-TemporaryFile
    [IO.File]::WriteAllBytes($payloadFile, $payload)

    $scriptBlock = {
        param($payloadFile, $target, $tests, $rangeSpec, $TimeoutSeconds)

        $warned = $false
        $lines = @()

        foreach ($test in $tests) {
            $curlArgs = @(
                "--range", $rangeSpec,
                "-m", $TimeoutSeconds,
                "--connect-timeout", ([Math]::Min(3, $TimeoutSeconds)),
                "-w", "%{http_code} %{size_upload} %{size_download} %{time_total}",
                "-o", "NUL",
                "-X", "POST",
                "--data-binary", "@$payloadFile",
                "-s"
            ) + $test.Args + @("https://$($target.Host)")

            $output = & curl.exe @curlArgs 2>&1
            $exit = $LASTEXITCODE
            $text = ($output | Out-String).Trim()

            $code = "NA"
            $upBytes = 0
            $downBytes = 0
            $time = -1

            if ($text -match '^(?<code>\d{3})\s+(?<up>\d+)\s+(?<down>\d+)\s+(?<time>[\d\.]+)$') {
                $code = $matches['code']
                $upBytes = [int64]$matches['up']
                $downBytes = [int64]$matches['down']
                $time = [double]$matches['time']
            } elseif (($exit -eq 35) -or ($text -match "not supported|does not support|protocol\s+'.+'\s+not\s+supported|protocol\s+.+\s+not\s+supported|unsupported protocol|TLS.not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel|SSL")) {
                $code = "UNSUP"
            } elseif ($text) {
                $code = "ERR"
            }

            $upKB = [math]::Round($upBytes / 1024, 1)
            $downKB = [math]::Round($downBytes / 1024, 1)
            $status = "OK"
            $color = "Green"

            if ($code -eq "UNSUP") {
                $status = "UNSUPPORTED"
                $color = "Yellow"
            } elseif ($exit -ne 0 -or $code -eq "ERR" -or $code -eq "NA") {
                $status = "FAIL"
                $color = "Red"
            }

            if (($upBytes -gt 0) -and ($downBytes -eq 0) -and ($time -ge $TimeoutSeconds) -and ($exit -ne 0)) {
                $status = "LIKELY_BLOCKED"
                $color = "Yellow"
                $warned = $true
            }

            $lines += [PSCustomObject]@{
                TestLabel = $test.Label
                Code      = $code
                UpBytes   = $upBytes
                UpKB      = $upKB
                DownBytes = $downBytes
                DownKB    = $downKB
                Time      = $time
                Status    = $status
                Color     = $color
                Warned    = $warned
            }
        }

        return [PSCustomObject]@{
            TargetId = $target.Id
            Provider = $target.Provider
            Country   = $target.Country
            Lines    = $lines
            Warned   = $warned
        }
    }

    $runspaces = @()
    foreach ($target in $Targets) {
        $powershell = [powershell]::Create().AddScript($scriptBlock)
        [void]$powershell.AddArgument($payloadFile)
        [void]$powershell.AddArgument($target)
        [void]$powershell.AddArgument($tests)
        [void]$powershell.AddArgument($rangeSpec)
        [void]$powershell.AddArgument($TimeoutSeconds)
        $powershell.RunspacePool = $runspacePool

        $runspaces += [PSCustomObject]@{
            Powershell = $powershell
            Handle     = $powershell.BeginInvoke()
            TargetId   = $target.Id
        }
    }

    $results = @()
    foreach ($rs in $runspaces) {
        # Wait for the runspace to complete with a small grace period beyond curl's timeout
        try {
            $waitMs = (([int]$TimeoutSeconds * 3) + 5) * 1000
            $handle = $rs.Handle
            if ($handle -and $handle.AsyncWaitHandle) {
                $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                if (-not $completed) {
                    Write-Host (T ('[ПРЕДУПРЕЖДЕНИЕ] Проверка {0} превысила время ожидания ({1} мс); останавливаю её…' -f $rs.TargetId, $waitMs) ('[WARNING] Check {0} timed out after {1} ms; stopping it…' -f $rs.TargetId, $waitMs)) -ForegroundColor Yellow
                    try { $rs.Powershell.Stop() } catch {}
                }
            }
        } catch {
            # ignore wait errors and attempt to EndInvoke
        }

        try {
            $res = $rs.Powershell.EndInvoke($rs.Handle)
            $results += $res

            Write-Host (T ("`n=== [$($res.Country)][$($res.Provider)] $($res.TargetId) ===") ("`n=== [$($res.Country)][$($res.Provider)] $($res.TargetId) ===")) -ForegroundColor DarkCyan
            foreach ($line in $res.Lines) {
                $lineStatus = switch ($line.Status) { 'OK' { T 'пройдено' 'passed' } 'FAIL' { T 'ошибка' 'failed' } 'UNSUPPORTED' { T 'не поддерживается' 'unsupported' } 'LIKELY_BLOCKED' { T 'вероятна блокировка' 'likely blocked' } default { $line.Status } }
                $msg = T ('[{0}] код={1}; отправлено={2} байт ({3} КБ); получено={4} байт ({5} КБ); время={6} с; статус={7}' -f $line.TestLabel, $line.Code, $line.UpBytes, $line.UpKB, $line.DownBytes, $line.DownKB, $line.Time, $lineStatus) ('[{0}] code={1}; sent={2} bytes ({3} KB); received={4} bytes ({5} KB); time={6}s; status={7}' -f $line.TestLabel, $line.Code, $line.UpBytes, $line.UpKB, $line.DownBytes, $line.DownKB, $line.Time, $lineStatus)
                Write-Host $msg -ForegroundColor $line.Color
                if ($line.Status -eq "LIKELY_BLOCKED") {
                    Write-Host (T '  Передача замирает на 16–20 КБ. Возможно, провайдер обрывает соединение для этой стратегии.' '  Transfer stalls at 16–20 KB. The network may be interrupting this strategy.') -ForegroundColor Yellow
                }
            }

            if ($res.Warned) {
                $warnDetected = $true
            } else {
                Write-Host (T '  Замирания передачи на 16–20 КБ не обнаружено.' '  No 16–20 KB transfer freeze detected.') -ForegroundColor Green
            }
        } catch {
            Write-Host (T '[ПРЕДУПРЕЖДЕНИЕ] Проверка завершилась с ошибкой; считаю её неуспешной.' '[WARNING] A test worker failed; counting it as a failed check.') -ForegroundColor Yellow
            $failedLine = [PSCustomObject]@{
                TestLabel  = 'RUNSPACE'
                Code       = 'ERR'
                SizeBytes  = 0
                SizeKB     = 0
                Status     = 'FAIL'
                Color      = 'Red'
                Warned     = $false
            }
            $results += [PSCustomObject]@{ TargetId = 'UNKNOWN'; Provider = 'UNKNOWN'; Lines = @($failedLine); Warned = $false }
        }
        $rs.Powershell.Dispose()
    }
    $runspacePool.Close()
    $runspacePool.Dispose()
    Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue

    if ($warnDetected) {
        Write-Host ""
        Write-Host (T '[ПРЕДУПРЕЖДЕНИЕ] Возможно, сеть блокирует передачу данных на 16–20 КБ. Попробуйте другую стратегию или параметры SNI/IP.' '[WARNING] The network may be blocking TCP transfers at 16–20 KB. Try another strategy or SNI/IP settings.') -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host (T '[OK] Замирания на 16–20 КБ не обнаружены ни на одном адресе.' '[OK] No 16–20 KB freeze was detected on any target.') -ForegroundColor Green
    }

    return $results
}

function Test-ZapretServiceConflict {
    return [bool](Get-Service -Name "zapret" -ErrorAction SilentlyContinue)
}

# Check Admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host (T '[ОШИБКА] Запустите проверку от имени администратора.' '[ERROR] Run the test utility as an administrator.') -ForegroundColor Red
    $hasErrors = $true
} else {
    Write-Host (T '[OK] Права администратора получены.' '[OK] Administrator rights detected.') -ForegroundColor Green
}

# Check curl
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Host (T '[ОШИБКА] Не найден curl.exe.' '[ERROR] curl.exe was not found.') -ForegroundColor Red
    Write-Host (T 'Установите curl или добавьте его в PATH, затем запустите проверку снова.' 'Install curl or add it to PATH, then run the test again.') -ForegroundColor Yellow
    $hasErrors = $true
} else {
    Write-Host (T '[OK] curl.exe найден.' '[OK] curl.exe found.') -ForegroundColor Green
}

# Check for leftover ipset flag from previous interrupted run
$ipsetFlagFile = Join-Path $rootDir "ipset_switched.flag"
if (Test-Path $ipsetFlagFile) {
    Write-Host (T '[ИНФО] Найден признак незавершённой проверки. Восстанавливаю список IP…' '[INFO] Found a flag from an interrupted test. Restoring the IP list…') -ForegroundColor Yellow
    Switch-TestIpsetMode -mode "restore"
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
}

# Get original ipset status early
$originalIpsetStatus = Get-IpsetStatus

# Warn about ipset switching and X button behavior
if ($originalIpsetStatus -ne "any") {
    $ipsetStatusText = switch ($originalIpsetStatus) { 'any' { T 'все адреса' 'all addresses' } 'loaded' { T 'список загружен' 'list loaded' } 'none' { T 'фильтр отключён' 'filter off' } default { $originalIpsetStatus } }
    Write-Host (T ('[ИНФО] Сейчас IP-фильтр: {0}' -f $ipsetStatusText) ('[INFO] Current IP filter: {0}' -f $ipsetStatusText)) -ForegroundColor Cyan
    Write-Host (T '[ПРЕДУПРЕЖДЕНИЕ] Для точной проверки IP-фильтр временно переключится на все адреса.' '[WARNING] The IP filter will temporarily include all addresses for accurate DPI tests.') -ForegroundColor Yellow
    Write-Host (T '[ПРЕДУПРЕЖДЕНИЕ] Если закрыть окно крестиком, список IP восстановится только при следующем запуске проверки.' '[WARNING] If you close this window with the X button, the IP list will be restored only the next time the test utility runs.') -ForegroundColor Yellow
    Write-Host (T '[ПРЕДУПРЕЖДЕНИЕ] При следующем запуске проверки исходный список IP восстановится автоматически.' '[WARNING] The original IP list will be restored automatically the next time the test utility runs.') -ForegroundColor Yellow
}

# Check if zapret service installed
if (Test-ZapretServiceConflict) {
    Write-Host (T '[ОШИБКА] Служба zapret установлена и может помешать проверке.' '[ERROR] The zapret service is installed and may interfere with the test.') -ForegroundColor Red
    Write-Host (T '         Перед проверкой удалите службу из меню.' '         Remove the service from the menu before testing.') -ForegroundColor Yellow
    Write-Host (T '         Откройте zapret.bat и выберите «Удалить службу и драйвер».' '         Open zapret.bat and choose “Remove service and driver”.') -ForegroundColor Yellow
    $hasErrors = $true
}

if ($hasErrors) {
    Write-Host ""
    Write-Host (T 'Исправьте ошибки выше и запустите проверку снова.' 'Fix the errors above and run the test again.') -ForegroundColor Yellow
    Wait-AnyKey -message (T 'Нажмите любую клавишу, чтобы выйти…' 'Press any key to exit…')
    exit 1
}

$dpiTargets = @()

# Config - strategies are loaded from strategies.json (no more *.bat files)
$strategies = @(Get-Strategies)

$globalResults = @()

# Select top-level test type (standard vs DPI checkers)
function Read-TestType {
    while ($true) {
        Write-Host ""
        Write-Host (T 'Выберите тип проверки:' 'Choose a test type:') -ForegroundColor Cyan
        Write-Host (T '  [1] Обычная проверка (HTTP и ping)' '  [1] Standard checks (HTTP and ping)') -ForegroundColor Gray
        Write-Host (T '  [2] Проверка DPI (замирание TCP на 16–20 КБ)' '  [2] DPI checks (TCP freeze at 16–20 KB)') -ForegroundColor Gray
        $choice = Read-Host (T 'Введите 1 или 2' 'Enter 1 or 2')
        switch ($choice) {
            '1' { return 'standard' }
            '2' { return 'dpi' }
            default { Write-Host (T 'Неверный ввод. Выберите 1 или 2.' 'That entry is not valid. Choose 1 or 2.') -ForegroundColor Yellow }
        }
    }
}

# Select test mode: all configs or custom subset
function Read-ModeSelection {
    while ($true) {
        Write-Host ""
        Write-Host (T 'Выберите, какие стратегии проверять:' 'Choose which strategies to test:') -ForegroundColor Cyan
        Write-Host (T '  [1] Все стратегии' '  [1] All strategies') -ForegroundColor Gray
        Write-Host (T '  [2] Выбрать стратегии' '  [2] Select strategies') -ForegroundColor Gray
        $choice = Read-Host (T 'Введите 1 или 2' 'Enter 1 or 2')
        switch ($choice) {
            '1' { return 'all' }
            '2' { return 'select' }
            default { Write-Host (T 'Неверный ввод. Выберите 1 или 2.' 'That entry is not valid. Choose 1 or 2.') -ForegroundColor Yellow }
        }
    }
}

function Read-ConfigSelection {
    param([array]$allFiles)

    while ($true) {
        Write-Host "" 
        Write-Host (T 'Доступные стратегии:' 'Available strategies:') -ForegroundColor Cyan
        for ($i = 0; $i -lt $allFiles.Count; $i++) {
            $idx = $i + 1
            Write-Host "  [$idx] $($allFiles[$i].Name)" -ForegroundColor Gray
        }

        $selectionInput = Read-Host (T 'Введите номера через запятую (1,3,5) или диапазоны (2-7). 0 — выбрать все.' 'Enter numbers separated by commas (1,3,5) or ranges (2-7). Enter 0 to select all.')
        $trimmed = $selectionInput.Trim()
        
        if ($trimmed -eq '0') {
            return $allFiles
        }

        $parts = $selectionInput -split '[,\s]+' | Where-Object { $_ -match '^\d+(-\d+)?$' }
        if ($parts.Count -eq 0) {
            Write-Host ""
            Write-Host (T 'Неверный формат. Используйте номера или диапазоны, например 1,3-7,10.' 'Invalid format. Use numbers or ranges, for example 1,3-7,10.') -ForegroundColor Yellow
            continue
        }
        $selectedIndices = @()
        $hasErrors = $false
        
        foreach ($part in $parts) {
            if ($part -match '^(\d+)-(\d+)$') {
                $start = [int]$matches[1]
                $end = [int]$matches[2]
                
                if ($start -gt $end) {
                    Write-Host (T ('[ПРЕДУПРЕЖДЕНИЕ] Диапазон {0} задан наоборот — пропускаю.' -f $part) ('[WARNING] Range {0} is reversed; skipping it.' -f $part)) -ForegroundColor Yellow
                    $hasErrors = $true
                    continue
                }
                
                if ($start -lt 1 -or $end -gt $allFiles.Count) {
                    Write-Host (T ('[ПРЕДУПРЕЖДЕНИЕ] Диапазон {0} выходит за границы списка 1–{1}; пропускаю неверные номера.' -f $part, $allFiles.Count) ('[WARNING] Range {0} is outside 1–{1}; skipping invalid numbers.' -f $part, $allFiles.Count)) -ForegroundColor Yellow
                    $hasErrors = $true
                    $start = [Math]::Max($start, 1)
                    $end = [Math]::Min($end, $allFiles.Count)
                }
                
                for ($i = $start; $i -le $end; $i++) {
                    $selectedIndices += $i
                }
            } else {
                $num = [int]$part
                if ($num -ge 1 -and $num -le $allFiles.Count) {
                    $selectedIndices += $num
                } else {
                    Write-Host (T ('[ПРЕДУПРЕЖДЕНИЕ] Номер {0} вне диапазона 1–{1}; пропускаю.' -f $num, $allFiles.Count) ('[WARNING] Number {0} is outside 1–{1}; skipping it.' -f $num, $allFiles.Count)) -ForegroundColor Yellow
                    $hasErrors = $true
                }
            }
        }
        $valid = $selectedIndices | Sort-Object -Unique | Where-Object { $_ -ge 1 -and $_ -le $allFiles.Count }
        if ($valid.Count -eq 0) {
            Write-Host ""
            Write-Host (T 'Не выбрано ни одной стратегии. Попробуйте ещё раз.' 'No strategies were selected. Try again.') -ForegroundColor Yellow
            continue
        }

        # Checker
         Write-Host (T ('Выбраны стратегии: {0}' -f ($valid -join ', ')) ('Selected strategies: {0}' -f ($valid -join ', '))) -ForegroundColor Green
        if ($hasErrors) {
            Write-Host (T 'Часть пунктов пропущена из-за ошибок. См. предупреждения выше.' 'Some entries were skipped because of errors. See the warnings above.') -ForegroundColor Yellow
        }
        
        return $valid | ForEach-Object { $allFiles[$_ - 1] }
    }
}

while ($true) {
    $globalResults = @()
$testType = Read-TestType
$mode = Read-ModeSelection
if ($mode -eq 'select') {
    $selected = Read-ConfigSelection -allFiles $strategies
    $strategies = @($selected)
}

if ($testType -eq 'dpi') {
    $dpiTargets = Build-DpiTargets -CustomHost $dpiCustomHost
}

# Load targets once for standard mode
$targetList = @()
$maxNameLen = 10
if ($testType -eq 'standard') {
    $targetsFile = Join-Path $utilsDir "targets.txt"
    $rawTargets = New-OrderedDict
    if (Test-Path $targetsFile) {
        Get-Content $targetsFile | ForEach-Object {
            if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
                Add-OrSet -dict $rawTargets -key $matches[1] -val $matches[2]
            }
        }
    }

    if ($rawTargets.Count -eq 0) {
        Write-Host (T '[ИНФО] targets.txt не найден или пуст — использую стандартный список адресов.' '[INFO] targets.txt is missing or empty. Using the built-in target list.') -ForegroundColor Gray
        Add-OrSet $rawTargets "Discord Main"           "https://discord.com"
        Add-OrSet $rawTargets "Discord Gateway"        "https://gateway.discord.gg"
        Add-OrSet $rawTargets "Discord CDN"            "https://cdn.discordapp.com"
        Add-OrSet $rawTargets "Discord Updates"        "https://updates.discord.com"
        Add-OrSet $rawTargets "YouTube Web"            "https://www.youtube.com"
        Add-OrSet $rawTargets "YouTube Short"          "https://youtu.be"
        Add-OrSet $rawTargets "YouTube Image"          "https://i.ytimg.com"
        Add-OrSet $rawTargets "YouTube Video Redirect" "https://redirector.googlevideo.com"
        Add-OrSet $rawTargets "Google Main"            "https://www.google.com"
        Add-OrSet $rawTargets "Google Gstatic"         "https://www.gstatic.com"
        Add-OrSet $rawTargets "Cloudflare Web"         "https://www.cloudflare.com"
        Add-OrSet $rawTargets "Cloudflare CDN"         "https://cdnjs.cloudflare.com"
        Add-OrSet $rawTargets "Cloudflare DNS 1.1.1.1" "PING:1.1.1.1"
        Add-OrSet $rawTargets "Cloudflare DNS 1.0.0.1" "PING:1.0.0.1"
        Add-OrSet $rawTargets "Google DNS 8.8.8.8"     "PING:8.8.8.8"
        Add-OrSet $rawTargets "Google DNS 8.8.4.4"     "PING:8.8.4.4"
        Add-OrSet $rawTargets "Quad9 DNS 9.9.9.9"      "PING:9.9.9.9"
    } else {
        Write-Host ""
        Write-Host (T '[ИНФО] Адреса загружены из targets.txt.' '[INFO] Targets loaded from targets.txt.') -ForegroundColor Gray
        Write-Host (T ('[ИНФО] Адресов загружено: {0}' -f $rawTargets.Count) ('[INFO] Targets loaded: {0}' -f $rawTargets.Count)) -ForegroundColor Gray
    }

    foreach ($key in $rawTargets.Keys) {
        $targetList += Convert-Target -Name $key -Value $rawTargets[$key]
    }

    $maxNameLen = ($targetList | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    if (-not $maxNameLen -or $maxNameLen -lt 10) { $maxNameLen = 10 }
}

# Ensure we have configs to run
if (-not $strategies -or $strategies.Count -eq 0) {
    Write-Host (T '[ОШИБКА] В strategies.json не найдены стратегии.' '[ERROR] No strategies were found in strategies.json.') -ForegroundColor Red
    Wait-AnyKey -message (T 'Нажмите любую клавишу, чтобы выйти…' 'Press any key to exit…')
    exit 1
}

# Stop winws
function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

# Capture/restore running winws instances to return user ipset/config
function Get-WinwsSnapshot {
    try {
        return Get-CimInstance Win32_Process -Filter "Name='winws.exe'" |
            Select-Object ProcessId, CommandLine, ExecutablePath
    } catch {
        return @()
    }
}

function Restore-WinwsSnapshot {
    param($snapshot)

    if (-not $snapshot -or $snapshot.Count -eq 0) { return }

    $current = @()
    try { $current = (Get-WinwsSnapshot).CommandLine } catch { $current = @() }

    Write-Host (T '[ИНФО] Восстанавливаю ранее запущенные процессы winws.exe…' '[INFO] Restoring previously running winws.exe processes…') -ForegroundColor DarkGray
    foreach ($p in $snapshot) {
        if (-not $p.ExecutablePath) { continue }

        # Skip if an identical command line is already active
        if ($current -and $current -contains $p.CommandLine) { continue }

        $exe = $p.ExecutablePath

        # Split the program token off the command line to recover the arguments.
        # A quoted token is unambiguous; an unquoted one may contain spaces, so
        # fall back to the known executable path before guessing at whitespace.
        $processArgs = $null
        if ($p.CommandLine -match '^\s*"[^"]*"\s*(.*)$') {
            $processArgs = $matches[1].Trim()
        } elseif ($p.CommandLine -and $p.CommandLine.StartsWith($exe, [StringComparison]::OrdinalIgnoreCase)) {
            $processArgs = $p.CommandLine.Substring($exe.Length).Trim()
        } elseif ($p.CommandLine -match '^\s*\S+\s*(.*)$') {
            $processArgs = $matches[1].Trim()
        }

        if (-not $processArgs) {
            Write-Host (T ('[ПРЕДУПРЕЖДЕНИЕ] Не удалось прочитать параметры прежнего winws.exe ({0}); пропускаю восстановление.' -f $exe) ('[WARNING] Could not read the arguments of the previous winws.exe ({0}); skipping restore.' -f $exe)) -ForegroundColor Yellow
            continue
        }

        try {
            Start-Process -FilePath $exe -ArgumentList $processArgs -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null
        } catch {
            Write-Host (T ('[ПРЕДУПРЕЖДЕНИЕ] Не удалось восстановить прежний winws.exe ({0}): {1}' -f $exe, $_) ('[WARNING] Could not restore the previous winws.exe ({0}): {1}' -f $exe, $_)) -ForegroundColor Yellow
        }
    }
}

$env:NO_UPDATE_CHECK = "1"
Initialize-UserLists | Out-Null
$originalWinws = Get-WinwsSnapshot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host (T '                 ПРОВЕРКА СТРАТЕГИЙ ZAPRET' '                 ZAPRET STRATEGY TESTS') -ForegroundColor Cyan
$modeLabel = if ($testType -eq 'dpi') { T 'проверка DPI' 'DPI checks' } else { T 'обычная проверка' 'standard checks' }
Write-Host ((T '                 Режим: {0}' '                 Mode: {0}') -f $modeLabel) -ForegroundColor Cyan
Write-Host ((T '                 Стратегий: {0}' '                 Strategies: {0}') -f $strategies.Count.ToString().PadLeft(2)) -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

try {
    # Save original ipset status and switch to 'any' for accurate DPI tests
    if (($originalIpsetStatus -ne "any") -and ($testType -eq 'dpi')) {
        Write-Host (T ('[ПРЕДУПРЕЖДЕНИЕ] IP-фильтр сейчас: {0}. Для проверки временно включаю все адреса…' -f $ipsetStatusText) ('[WARNING] IP filter is set to {0}. Temporarily including all addresses for the test…' -f $ipsetStatusText)) -ForegroundColor Yellow
        Switch-TestIpsetMode -mode "any"
        # Create flag file to indicate ipset was switched
        "" | Out-File -FilePath $ipsetFlagFile -Encoding UTF8
    }
    Write-Host (T '[ПРЕДУПРЕЖДЕНИЕ] Проверка займёт несколько минут. Подождите…' '[WARNING] The test may take several minutes. Please wait…') -ForegroundColor Yellow

    $configNum = 0
    foreach ($strategy in $strategies) {
    $configNum++
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host ((T '  [Стратегия {0}/{1}] {2}' '  [Strategy {0}/{1}] {2}') -f $configNum, $strategies.Count, $strategy.name) -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
    
    # Cleanup
    Stop-Zapret
    
    # Stock bat protocol: TCP timestamps must be on for --dpi-desync-fooling=ts.
    [void](Enable-ZapretTcpTimestamps)
    
    # Start strategy directly via winws.exe (strategies live in strategies.json)
    Write-Host (T '  > Запускаю стратегию…' '  > Starting strategy…') -ForegroundColor Cyan
    $expandedArgs = Expand-StrategyArgs -Template $strategy.args
    $winwsPath = Join-Path (Get-ZapretBinDir) 'winws.exe'
    $proc = Start-Process -FilePath $winwsPath -ArgumentList $expandedArgs -WorkingDirectory (Get-ZapretBinDir) -PassThru -WindowStyle Minimized
    
    # Wait init
    if (-not (Wait-WinwsReady)) {
        Write-Host (T '  > Не удалось запустить стратегию: процесс winws.exe не найден. Пропускаю её.' '  > Could not start the strategy: winws.exe was not found. Skipping it.') -ForegroundColor Red
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
        continue
    }
    
    if ($testType -eq 'standard') {
        $curlTimeoutSeconds = $standardCurlTimeout

        # Parallel target checks via runspace pool (faster than jobs)
        $maxParallel = $standardMaxParallel
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxParallel)
        $runspacePool.Open()

        $scriptBlock = {
            param($t, $curlTimeoutSeconds)

            $httpPieces = @()

            if ($t.Url) {
                $tests = @(
                    @{ Label = "HTTP";   Args = @("--http1.1") },
                    @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
                    @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
                )

                $baseArgs = @("-I", "-s", "-m", $curlTimeoutSeconds, "--connect-timeout", ([Math]::Min(2, $curlTimeoutSeconds)), "-o", "NUL", "-w", "%{http_code}", "--show-error")
                foreach ($test in $tests) {
                    try {
                        $curlArgs = $baseArgs + $test.Args
                        $stderr = $null
                        & curl.exe @curlArgs $t.Url 2>&1 | ForEach-Object {
                            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                                $stderr += $_.Exception.Message + " "
                            } else {
                                $_
                            }
                        }
                        $dnsHijack = ($stderr -match "Could not resolve host|certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer certificate")                        
                        if ($dnsHijack) {
                            $httpPieces += "$($test.Label):SSL  "
                            continue
                        }
                        
                        $unsupported = (($LASTEXITCODE -eq 35) -or ($stderr -match "does not support|not supported|protocol\s+'?.+'?\s+not\s+supported|unsupported protocol|TLS.*not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel"))
                        if ($unsupported) {
                            $httpPieces += "$($test.Label):UNSUP"
                            continue
                        }

                        $ok = ($LASTEXITCODE -eq 0)
                        if ($ok) {
                            $httpPieces += "$($test.Label):OK   "
                        } else {
                            $httpPieces += "$($test.Label):ERROR"
                        }
                    } catch {
                        $httpPieces += "$($test.Label):ERROR"
                    }
                }
            }

            $pingResult = "n/a"
            if ($t.PingTarget) {
                $ping = $null
                try {
                    $ping = New-Object System.Net.NetworkInformation.Ping
                    $reply = $ping.Send($t.PingTarget, 1000)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $pingResult = "{0:N0} ms" -f $reply.RoundtripTime
                    } else {
                        $pingResult = "Timeout"
                    }
                } catch {
                    $pingResult = "Timeout"
                } finally {
                    if ($ping) { $ping.Dispose() }
                }
            }

            return (New-Object PSObject -Property @{
                Name       = $t.Name
                HttpTokens = $httpPieces
                PingResult = $pingResult
                IsUrl      = [bool]$t.Url
            })
        }

        $runspaces = @()
        foreach ($target in $targetList) {
            $ps = [powershell]::Create().AddScript($scriptBlock)
            [void]$ps.AddArgument($target)
            [void]$ps.AddArgument($curlTimeoutSeconds)
            $ps.RunspacePool = $runspacePool

            $runspaces += [PSCustomObject]@{
                Powershell = $ps
                Handle     = $ps.BeginInvoke()
            }
        }

        $script:currentLine = T '  > Проверяю адреса…' '  > Testing endpoints…'
        Write-Host $script:currentLine -ForegroundColor DarkGray

        $targetResults = @()
        foreach ($rs in $runspaces) {
            try {
                $waitMs = (([int]$curlTimeoutSeconds * 3) + 5) * 1000
                $handle = $rs.Handle
                if ($handle -and $handle.AsyncWaitHandle) {
                    $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                    if (-not $completed) {
                        Write-Host (T ('[ПРЕДУПРЕЖДЕНИЕ] Проверка адреса превысила время ожидания ({0} мс); останавливаю её…' -f $waitMs) ('[WARNING] Endpoint check timed out after {0} ms; stopping it…' -f $waitMs)) -ForegroundColor Yellow
                        try { $rs.Powershell.Stop() } catch {}
                    }
                }
            } catch {
                # ignore
            }

            try {
                $targetResults += $rs.Powershell.EndInvoke($rs.Handle)
            } catch {
                Write-Host (T '[ПРЕДУПРЕЖДЕНИЕ] Проверка завершилась с ошибкой; считаю её неуспешной.' '[WARNING] A test worker failed; counting it as a failed check.') -ForegroundColor Yellow
                $targetResults += [PSCustomObject]@{ Name = 'UNKNOWN'; HttpTokens = @('HTTP:ERROR'); PingResult = 'Timeout'; IsUrl = $true }
            }
            $rs.Powershell.Dispose()
        }

        $runspacePool.Close()
        $runspacePool.Dispose()

        $targetLookup = @{}
        foreach ($res in $targetResults) { $targetLookup[$res.Name] = $res }

        foreach ($target in $targetList) {
            $res = $targetLookup[$target.Name]
            if (-not $res) { continue }

            Write-Host "  $($target.Name.PadRight($maxNameLen))    " -NoNewline

            $pingDisplay = switch ([string]$res.PingResult) {
                'Timeout' { T 'нет ответа' 'timed out' }
                'n/a'     { T 'не проверялся' 'not tested' }
                default   { $res.PingResult }
            }
            if ($res.IsUrl -and $res.HttpTokens) {
                foreach ($tok in $res.HttpTokens) {
                    $tokColor = "Green"
                    if ($tok -match "UNSUP") { $tokColor = "Yellow" }
                    elseif ($tok -match "SSL") { $tokColor = "Red" }
                    elseif ($tok -match "ERR") { $tokColor = "Red" }
                    $displayToken = $tok
                    if ($script:UiLanguage -eq 'ru') {
                        $displayToken = $displayToken -replace ':UNSUP$', ':НЕ ПОДДЕРЖИВАЕТСЯ' -replace ':ERROR$', ':ОШИБКА' -replace ':ERR$', ':ОШИБКА'
                    }
                    Write-Host " $displayToken" -NoNewline -ForegroundColor $tokColor
                }
                Write-Host (T ' | Задержка: ' ' | Ping: ') -NoNewline -ForegroundColor DarkGray
                if ($res.PingResult -eq "Timeout") { $pingColor = "Yellow" } else { $pingColor = "Cyan" }
                Write-Host $pingDisplay -NoNewline -ForegroundColor $pingColor
                Write-Host ""
            } else {
                # Ping-only target
                Write-Host (T ' Задержка: ' ' Ping: ') -NoNewline -ForegroundColor DarkGray
                if ($res.PingResult -eq "Timeout") { $pingColor = "Red" } else { $pingColor = "Cyan" }
                Write-Host $pingDisplay -ForegroundColor $pingColor
            }

        }

        $globalResults += @{ Config = $strategy.name; Type = 'standard'; Results = $targetResults }
    } else {
        Write-Host (T '  > Выполняю DPI-проверки…' '  > Running DPI checks…') -ForegroundColor DarkGray
        $dpiResults = Invoke-DpiSuite -Targets $dpiTargets -TimeoutSeconds $dpiTimeoutSeconds -RangeBytes $dpiRangeBytes -MaxParallel $dpiMaxParallel
        $globalResults += @{ Config = $strategy.name; Type = 'dpi'; Results = $dpiResults }
    }
    
    # Stop
    Stop-Zapret
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

    Write-Host ""
    Write-Host (T 'Все проверки завершены.' 'All tests are complete.') -ForegroundColor Green

    # Analytics
    $analytics = @{}
    foreach ($res in $globalResults) {
        if ($res.Type -eq 'standard') {
            foreach ($targetRes in $res.Results) {
                $config = $res.Config
                if (-not $analytics.ContainsKey($config)) { $analytics[$config] = @{ OK = 0; ERROR = 0; UNSUP = 0; PingOK = 0; PingFail = 0 } }
                if ($targetRes.IsUrl) {
                    foreach ($tok in $targetRes.HttpTokens) {
                        if ($tok -match "OK") { $analytics[$config].OK++ }
                        elseif ($tok -match "SSL") { $analytics[$config].ERROR++ }
                        elseif ($tok -match "ERROR") { $analytics[$config].ERROR++ }
                        elseif ($tok -match "UNSUP") { $analytics[$config].UNSUP++ }
                    }
                }
                if ($targetRes.PingResult -ne "Timeout" -and $targetRes.PingResult -ne "n/a") { $analytics[$config].PingOK++ } else { $analytics[$config].PingFail++ }
            }
        } elseif ($res.Type -eq 'dpi') {
            foreach ($targetRes in $res.Results) {
                $config = $res.Config
                if (-not $analytics.ContainsKey($config)) { $analytics[$config] = @{ OK = 0; FAIL = 0; UNSUPPORTED = 0; LIKELY_BLOCKED = 0 } }
                foreach ($line in $targetRes.Lines) {
                    if ($line.Status -eq "OK") { $analytics[$config].OK++ }
                    elseif ($line.Status -eq "FAIL") { $analytics[$config].FAIL++ }
                    elseif ($line.Status -eq "UNSUPPORTED") { $analytics[$config].UNSUPPORTED++ }
                    elseif ($line.Status -eq "LIKELY_BLOCKED") { $analytics[$config].LIKELY_BLOCKED++ }
                }
            }
        }
    }

    Write-Host ""
    Write-Host (T '=== ИТОГИ ===' '=== ANALYTICS ===') -ForegroundColor Cyan
    $maxConfigLen = ($analytics.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $configPadded = $config.PadRight($maxConfigLen)
        if ($a.ContainsKey('PingOK')) {
            $line = T ('{0} : HTTP успешно: {1,3}, ошибки: {2,3}, не поддерживается: {3,3}, ping успешно: {4,3}, без ответа: {5,3}' -f `
                $configPadded, $a.OK, $a.ERROR, $a.UNSUP, $a.PingOK, $a.PingFail) ('{0} : HTTP OK: {1,3}, errors: {2,3}, unsupported: {3,3}, ping OK: {4,3}, no reply: {5,3}' -f `
                $configPadded, $a.OK, $a.ERROR, $a.UNSUP, $a.PingOK, $a.PingFail)
        } else {
            $line = T ('{0} : пройдено: {1,3}, ошибки: {2,3}, не поддерживается: {3,3}, вероятна блокировка: {4,3}' -f `
                $configPadded, $a.OK, $a.FAIL, $a.UNSUPPORTED, $a.LIKELY_BLOCKED) ('{0} : passed: {1,3}, failed: {2,3}, unsupported: {3,3}, likely blocked: {4,3}' -f `
                $configPadded, $a.OK, $a.FAIL, $a.UNSUPPORTED, $a.LIKELY_BLOCKED)
        }
        Write-Host $line -ForegroundColor Yellow
    }

    # Determine best strategy
    $bestConfig = $null
    $maxScore = 0
    $maxPing = -1
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $score = $a.OK
        $pingScore = 0
        if ($a.ContainsKey('PingOK')) {
            $pingScore = $a.PingOK
        }
        if ($score -gt $maxScore) {
            $maxScore = $score
            $maxPing = $pingScore
            $bestConfig = $config
        } elseif ($score -eq $maxScore) {
            if ($pingScore -gt $maxPing) {
                $maxPing = $pingScore
                $bestConfig = $config
            }
        }
    }
    Write-Host ""
    Write-Host (T ('Лучшая стратегия: {0}' -f $bestConfig) ('Best strategy: {0}' -f $bestConfig)) -ForegroundColor Green
    Write-Host ""

    # Save to file
    $dateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $resultFile = Join-Path $resultsDir "test_results_$dateStr.txt"
    $resultLines = New-Object System.Collections.Generic.List[string]
    foreach ($res in $globalResults) {
        $config = $res.Config
        $type = $res.Type
        $results = $res.Results
        [void]$resultLines.Add((T ("Стратегия: {0} (тип: {1})" -f $config, $(if ($type -eq 'dpi') { 'DPI' } else { 'обычная проверка' })) ("Strategy: {0} (type: {1})" -f $config, $type)))
        if ($type -eq 'standard') {
            foreach ($targetRes in $results) {
                $name = $targetRes.Name
                $http = $targetRes.HttpTokens -join ' '
                $ping = $targetRes.PingResult
                [void]$resultLines.Add((T ("  {0}: {1} | задержка: {2}" -f $name, $http, $(if ($ping -eq 'Timeout') { 'нет ответа' } elseif ($ping -eq 'n/a') { 'не проверялась' } else { $ping })) ("  {0}: {1} | ping: {2}" -f $name, $http, $ping)))
            }
        } elseif ($type -eq 'dpi') {
            foreach ($targetRes in $results) {
                $id = $targetRes.TargetId
                $provider = $targetRes.Provider
                $country = $targetRes.Country
                if ($country) {
                    [void]$resultLines.Add((T "  Адрес: [$country] $id ($provider)" "  Target: [$country] $id ($provider)"))
                } else {
                    [void]$resultLines.Add((T "  Адрес: $id ($provider)" "  Target: $id ($provider)"))
                }
                foreach ($line in $targetRes.Lines) {
                    $test = $line.TestLabel
                    $code = $line.Code
                    $up = $line.UpKB
                    $down = $line.DownKB
                    $time = $line.Time
                    $status = switch ($line.Status) {
                        'OK' { T 'пройдено' 'passed' }
                        'FAIL' { T 'ошибка' 'failed' }
                        'UNSUPPORTED' { T 'не поддерживается' 'unsupported' }
                        'LIKELY_BLOCKED' { T 'вероятна блокировка' 'likely blocked' }
                        default { $line.Status }
                    }
                    [void]$resultLines.Add((T ("    {0}: код={1}, отправлено={2} КБ, получено={3} КБ, время={4} с, статус={5}" -f $test, $code, $up, $down, $time, $status) ("    {0}: code={1}, sent={2} KB, received={3} KB, time={4}s, status={5}" -f $test, $code, $up, $down, $time, $status)))
                }
            }
        }
        [void]$resultLines.Add("")
    }

    # Add analytics
    [void]$resultLines.Add((T '=== ИТОГИ ===' '=== ANALYTICS ==='))
    $maxConfigLen = ($analytics.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($config in $analytics.Keys) {
        $a = $analytics[$config]
        $configPadded = $config.PadRight($maxConfigLen)
        if ($a.ContainsKey('PingOK')) {
            $line = T ('{0} : HTTP успешно: {1,3}, ошибки: {2,3}, не поддерживается: {3,3}, ping успешно: {4,3}, без ответа: {5,3}' -f `
                $configPadded, $a.OK, $a.ERROR, $a.UNSUP, $a.PingOK, $a.PingFail) ('{0} : HTTP OK: {1,3}, errors: {2,3}, unsupported: {3,3}, ping OK: {4,3}, no reply: {5,3}' -f `
                $configPadded, $a.OK, $a.ERROR, $a.UNSUP, $a.PingOK, $a.PingFail)
        } else {
            $line = T ('{0} : пройдено: {1,3}, ошибки: {2,3}, не поддерживается: {3,3}, вероятна блокировка: {4,3}' -f `
                $configPadded, $a.OK, $a.FAIL, $a.UNSUPPORTED, $a.LIKELY_BLOCKED) ('{0} : passed: {1,3}, failed: {2,3}, unsupported: {3,3}, likely blocked: {4,3}' -f `
                $configPadded, $a.OK, $a.FAIL, $a.UNSUPPORTED, $a.LIKELY_BLOCKED)
        }
        [void]$resultLines.Add($line)
    }

    [void]$resultLines.Add((T ("Лучшая стратегия: {0}" -f $bestConfig) ("Best strategy: {0}" -f $bestConfig)))
    $resultLines | Set-Content $resultFile -Encoding UTF8

    Write-Host (T ('Результаты сохранены: {0}' -f $resultFile) ('Results saved to: {0}' -f $resultFile)) -ForegroundColor Green

} catch {
    Write-Host (T '[ОШИБКА] Во время проверки произошла ошибка. Восстанавливаю список IP…' '[ERROR] The test encountered an error. Restoring the IP list…') -ForegroundColor Red
    if ($originalIpsetStatus -and $originalIpsetStatus -ne "any") {
        Switch-TestIpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
} finally {
    Stop-Zapret
    Restore-WinwsSnapshot -snapshot $originalWinws
    if ($originalIpsetStatus -ne "any") {
        Write-Host (T '[ИНФО] Восстанавливаю исходный IP-фильтр…' '[INFO] Restoring the original IP filter…') -ForegroundColor DarkGray
        Switch-TestIpsetMode -mode "restore"
    }
    Remove-Item -Path $ipsetFlagFile -ErrorAction SilentlyContinue
}

    Wait-AnyKey
    exit
}
