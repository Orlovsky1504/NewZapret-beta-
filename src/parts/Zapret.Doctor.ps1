# ---------------------------------------------------------------------------
# Installation doctor ("zapret.ps1 doctor"): read-only self-check of an
# installed tree. Finds the failures users hit in the wild: missing files,
# version drift, antivirus/MOTW-blocked winws, stale WinDivert services,
# service/process incoherence and broken lists. Optional -Fix repairs what is
# safe to repair (unblock files, clean stale driver services).
# ---------------------------------------------------------------------------

function Get-DoctorCriticalFiles {
    # Pure: the inventory every healthy install must contain. Paths are
    # relative to the install root; Role explains what breaks without it.
    return @(
        [pscustomobject]@{ Path = 'winws.exe'; Role = 'обход (winws.exe)' }
        [pscustomobject]@{ Path = 'WinDivert.dll'; Role = 'перехват трафика (WinDivert.dll)' }
        [pscustomobject]@{ Path = 'WinDivert64.sys'; Role = 'драйвер WinDivert (WinDivert64.sys)' }
        [pscustomobject]@{ Path = 'zapret.ps1'; Role = 'командная строка (zapret.ps1)' }
        [pscustomobject]@{ Path = 'Zapret-Control.exe'; Role = 'панель управления (Zapret-Control.exe)' }
        [pscustomobject]@{ Path = 'Zapret-Tray.exe'; Role = 'индикатор трея (Zapret-Tray.exe)' }
        [pscustomobject]@{ Path = 'src/Zapret.psm1'; Role = 'модуль (src/Zapret.psm1)' }
        [pscustomobject]@{ Path = 'strategies.json'; Role = 'каталог стратегий (strategies.json)' }
        [pscustomobject]@{ Path = 'ИНСТРУКЦИЯ.txt'; Role = 'инструкция (ИНСТРУКЦИЯ.txt)' }
    )
}

function Get-DoctorVersionProblems {
    # Pure: compares the three shipped version markers. Each input is the raw
    # text of the file (or $null when the file is missing). Returns problems.
    param(
        [AllowNull()][string]$VersionText,
        [AllowNull()][string]$RcText,
        [AllowNull()][string]$InstructionText
    )
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $versions = @{}
    if ($VersionText) {
        $m = [regex]::Match($VersionText, '\d+\.\d+\.\d+')
        if ($m.Success) { $versions['version.txt'] = $m.Value } else { $problems.Add('version.txt не содержит версию X.Y.Z.') }
    } else { $problems.Add('Нет файла .service/version.txt.') }
    if ($RcText) {
        # tools/zapret-control.rc живёт только в репозитории (в zip его нет) —
        # сверяем версию лишь когда файл присутствует.
        $m = [regex]::Match($RcText, 'FILEVERSION\s+(\d+),(\d+),(\d+)')
        if ($m.Success) { $versions['zapret-control.rc'] = '{0}.{1}.{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value }
        else { $problems.Add('tools/zapret-control.rc не содержит FILEVERSION.') }
    }
    if ($InstructionText) {
        $m = [regex]::Match($InstructionText, '\d+\.\d+\.\d+')
        if ($m.Success) { $versions['ИНСТРУКЦИЯ'] = $m.Value } else { $problems.Add('ИНСТРУКЦИЯ.txt не содержит версию X.Y.Z.') }
    } else { $problems.Add('Нет файла ИНСТРУКЦИЯ.txt.') }
    $distinct = @($versions.Values | Select-Object -Unique)
    if ($distinct.Count -gt 1) {
        $parts = @($versions.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
        $problems.Add(('Версии не совпадают: {0}.' -f ($parts -join ', ')))
    }
    return $problems.ToArray()
}

function Convert-DoctorRowsToExitCode {
    # Pure: 0 = everything fine (skips allowed), 1 = warnings, 2 = failures.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows)
    foreach ($row in $Rows) { if ($row.Status -eq 'fail') { return 2 } }
    foreach ($row in $Rows) { if ($row.Status -eq 'warn') { return 1 } }
    return 0
}

function Test-DoctorFileLocks {
    # Files downloaded from the Internet carry a Zone.Identifier stream; the
    # antivirus or SmartScreen may then refuse to start winws (exit code 177
    # family). Returns the blocked relative paths.
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RelativePaths
    )
    $blocked = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rel in $RelativePaths) {
        $full = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        # get-item -stream кидает ParameterBindingException там, где ADS нет
        # (не-Windows, старые системы) - SilentlyContinue такое не гасит.
        $stream = $null
        try { $stream = Get-Item -LiteralPath $full -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue } catch { $stream = $null }
        if ($stream) { $blocked.Add($rel) }
    }
    return $blocked.ToArray()
}

function Test-DoctorLists {
    # User lists must exist and be readable; ipset-all.txt must carry data.
    param([Parameter(Mandatory = $true)][string]$Root)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $listsDir = Join-Path $Root 'lists'
    foreach ($name in @('list-general-user.txt', 'list-exclude-user.txt', 'ipset-exclude-user.txt')) {
        $file = Join-Path $listsDir $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $problems.Add(('Нет файла lists\{0} (создаётся кнопкой «Мои сайты» или первым запуском).' -f $name))
            continue
        }
        try { [void][IO.File]::ReadAllText($file) } catch { $problems.Add(('Файл lists\{0} не читается: {1}' -f $name, $_.Exception.Message)) }
    }
    $ipset = Join-Path $listsDir 'ipset-all.txt'
    if (Test-Path -LiteralPath $ipset -PathType Leaf) {
        try {
            $len = (Get-Item -LiteralPath $ipset).Length
            if ($len -lt 16) { $problems.Add('lists\ipset-all.txt почти пуст — обход по IP-адресам работать не будет.') }
        } catch { $problems.Add(('lists\ipset-all.txt не читается: {0}' -f $_.Exception.Message)) }
    } else {
        $problems.Add('Нет файла lists\ipset-all.txt (кнопка «IPSet → Обновить» восстановит).')
    }
    return $problems.ToArray()
}

function Invoke-ZapretDoctor {
    <#
        Installation self-check. Read-only by default; -Fix unblocks
        Internet-marked files and cleans stale WinDivert driver services.
        Returns a report object { Rows; Failures; Warnings; ExitCode; VerdictRu }.
    #>
    [CmdletBinding()]
    param(
        [switch]$Fix,
        [switch]$Deep   # additionally run bin\WinProbe.exe against the real driver
    )
    $root = $script:Root
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $add = {
        param($Status, $Name, $Detail)
        $rows.Add([pscustomobject]@{ Status = $Status; Name = $Name; Detail = $Detail })
        $symbol = switch ($Status) {
            'ok'   { '[OK]  ' }
            'warn' { '[?]   ' }
            'fail' { '[X]   ' }
            default{ '[skip]' }
        }
        $color = switch ($Status) {
            'ok'   { 'Green' }
            'warn' { 'Yellow' }
            'fail' { 'Red' }
            default{ 'DarkGray' }
        }
        Write-Host ('  {0} {1}: {2}' -f $symbol, $Name, $Detail) -ForegroundColor $color
    }

    Write-Host ''
    Write-Host (Get-UiText -Russian '   ДОКТОР УСТАНОВКИ — проверка файлов, версий, драйвера и списков' -English '   INSTALLATION DOCTOR - files, versions, driver and lists check') -ForegroundColor Cyan

    # 1. Critical files (bin\ prefix for the shipped binaries).
    foreach ($item in @(Get-DoctorCriticalFiles)) {
        $rel = $item.Path
        $full = if (@('winws.exe', 'WinDivert.dll', 'WinDivert64.sys') -contains $rel) { Join-Path $root ('bin\{0}' -f $rel) } else { Join-Path $root $rel }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            & $add 'ok' $item.Role 'файл на месте'
        } else {
            & $add 'fail' $item.Role ('файл отсутствует: {0}' -f $full)
        }
    }

    # 2. Module parts consistency (the loader refuses to start without them).
    $missingParts = New-Object 'System.Collections.Generic.List[string]'
    $psm1 = Join-Path $root 'src/Zapret.psm1'
    if (Test-Path -LiteralPath $psm1 -PathType Leaf) {
        $psm1Text = [IO.File]::ReadAllText($psm1)
        foreach ($m in [regex]::Matches($psm1Text, "'(Zapret\.[A-Za-z]+\.ps1)'")) {
            $partName = $m.Groups[1].Value
            if (-not (Test-Path -LiteralPath (Join-Path $root ('src\parts\{0}' -f $partName)) -PathType Leaf)) { $missingParts.Add($partName) }
        }
    }
    if ($missingParts.Count -eq 0) { & $add 'ok' 'Модуль (части)' 'все части модуля на месте' }
    else { & $add 'fail' 'Модуль (части)' ('отсутствуют: {0}' -f ($missingParts -join ', ')) }

    # 3. Version consistency.
    $versionFile = Join-Path $root '.service/version.txt'
    $rcFile = Join-Path $root 'tools/zapret-control.rc'
    $instFile = Join-Path $root 'ИНСТРУКЦИЯ.txt'
    $versionRaw = $null
    if (Test-Path -LiteralPath $versionFile) { $versionRaw = [IO.File]::ReadAllText($versionFile) }
    $rcRaw = $null
    if (Test-Path -LiteralPath $rcFile) { $rcRaw = [IO.File]::ReadAllText($rcFile) }
    $instRaw = $null
    if (Test-Path -LiteralPath $instFile) { $instRaw = [IO.File]::ReadAllText($instFile) }
    $versionProblems = @(Get-DoctorVersionProblems -VersionText $versionRaw -RcText $rcRaw -InstructionText $instRaw)
    if ($versionProblems.Count -eq 0) { & $add 'ok' 'Версии' 'version.txt, zapret-control.rc и ИНСТРУКЦИЯ совпадают' }
    else { & $add 'warn' 'Версии' ($versionProblems -join ' ') }

    # 4. Internet marks (MOTW) that block winws at startup.
    $binaries = @('bin\winws.exe', 'bin\WinDivert.dll', 'bin\WinDivert64.sys')
    $blocked = @(Test-DoctorFileLocks -Root $root -RelativePaths $binaries)
    if ($blocked.Count -eq 0) {
        & $add 'ok' 'Блокировка файлов' 'файлы обхода не помечены Windows как загруженные из интернета'
    } else {
        if ($Fix) {
            foreach ($rel in $blocked) {
                try { Unblock-File -LiteralPath (Join-Path $root $rel) -ErrorAction Stop } catch { }
            }
            $still = @(Test-DoctorFileLocks -Root $root -RelativePaths $binaries)
            if ($still.Count -eq 0) { & $add 'ok' 'Блокировка файлов' ('снята для: {0}' -f ($blocked -join ', ')) }
            else { & $add 'fail' 'Блокировка файлов' ('не удалось снять: {0}' -f ($still -join ', ')) }
        } else {
            & $add 'warn' 'Блокировка файлов' ('Windows помечает как загруженные из интернета: {0} — запустите doctor с флагом -Fix' -f ($blocked -join ', '))
        }
    }

    # 5. Stale WinDivert driver services (the 177 exit-code family).
    if ($script:OnWindows) {
        $stale = New-Object 'System.Collections.Generic.List[string]'
        $staleProbeError = $null
        try {
            $sc = Get-WindowsSystemToolPath -Name 'sc.exe'
            foreach ($svc in @('WinDivert', 'WinDivert14')) {
                $out = & $sc query $svc 2>&1 | Out-String
                if ($out -match 'STATE\s*:\s*\d+\s+(RUNNING|STOPPED|START_PENDING|STOP_PENDING)') { $stale.Add($svc) }
            }
        } catch { $staleProbeError = $_.Exception.Message }
        if ($staleProbeError) {
            & $add 'warn' 'Службы WinDivert' ('не удалось проверить: {0}' -f $staleProbeError)
        } elseif ($stale.Count -eq 0) {
            & $add 'ok' 'Службы WinDivert' 'устаревших служб драйвера нет'
        } else {
            if ($Fix) {
                try {
                    [void](Repair-WinDivertService)
                    & $add 'ok' 'Службы WinDivert' ('удалены: {0}' -f ($stale -join ', '))
                } catch {
                    & $add 'warn' 'Службы WinDivert' ('не удалось удалить {0}: {1}' -f ($stale -join ', '), $_.Exception.Message)
                }
            } else {
                & $add 'warn' 'Службы WinDivert' ('найдены устаревшие службы: {0} — они дают ошибки запуска winws; doctor с -Fix удалит их' -f ($stale -join ', '))
            }
        }
    } else {
        & $add 'skip' 'Службы WinDivert' 'проверка доступна только на Windows'
    }

    # 6. Service / process coherence.
    if ($script:OnWindows) {
        try {
            $info = Get-ZapretServiceInfo
            if (-not $info.Installed) {
                & $add 'skip' 'Служба обхода' 'служба не установлена (нормально для портативного режима)'
            } elseif ($info.State -eq 'RUNNING' -and -not $info.WinwsRunning) {
                & $add 'warn' 'Служба обхода' 'служба отчитывается о работе, но процесс winws не найден — нажмите «Включить обход» заново'
            } elseif ($info.State -ne 'RUNNING' -and -not $info.WinwsRunning) {
                & $add 'warn' 'Служба обхода' 'служба установлена, но не запущена — кнопка «Включить обход»'
            } elseif ($info.State -ne 'RUNNING' -and $info.WinwsRunning) {
                & $add 'warn' 'Служба обхода' 'процесс winws работает без службы (осиротевший процесс)'
            } else {
                & $add 'ok' 'Служба обхода' 'служба и процесс winws согласованы'
            }
        } catch {
            & $add 'warn' 'Служба обхода' ('не удалось получить состояние: {0}' -f $_.Exception.Message)
        }
    } else {
        & $add 'skip' 'Служба обхода' 'проверка доступна только на Windows'
    }

    # 7. Lists.
    $listProblems = @(Test-DoctorLists -Root $root)
    if ($listProblems.Count -eq 0) { & $add 'ok' 'Списки' 'пользовательские списки и ipset в порядке' }
    else { foreach ($p in $listProblems) { & $add 'warn' 'Списки' $p } }

    # 8. Deep driver probe (optional).
    if ($Deep) {
        $probe = Join-Path $root 'bin/WinProbe.exe'
        if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) {
            & $add 'skip' 'Проба драйвера' 'bin\WinProbe.exe не найден'
        } elseif (-not $script:OnWindows) {
            & $add 'skip' 'Проба драйвера' 'проверка доступна только на Windows'
        } else {
            try {
                $p = Start-Process -FilePath $probe -WindowStyle Hidden -Wait -PassThru
                if ($p.ExitCode -eq 0) { & $add 'ok' 'Проба драйвера' 'WinDivert открывается, драйвер работает' }
                else { & $add 'fail' 'Проба драйвера' ('WinDivert не открывается (код {0}) — смотрите вывод WinProbe, это та же ошибка, что даёт winws' -f $p.ExitCode) }
            } catch {
                & $add 'warn' 'Проба драйвера' ('не удалось запустить WinProbe.exe: {0}' -f $_.Exception.Message)
            }
        }
    }

    $rowArray = $rows.ToArray()
    $exitCode = Convert-DoctorRowsToExitCode -Rows $rowArray
    $verdictRu = switch ($exitCode) {
        0 { 'Установка в порядке.' }
        1 { 'Есть предупреждения — обход, скорее всего, работает, но стоит посмотреть пункты со знаком [?].' }
        default { 'Найдены проблемы, из-за которых обход не сможет работать — смотрите пункты со знаком [X].' }
    }
    Write-Host ('' ) -NoNewline
    Write-Host ''
    Write-Host ('  {0}' -f $verdictRu) -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } elseif ($exitCode -eq 1) { 'Yellow' } else { 'Red' })
    Write-Log ("Doctor finished: exit {0}" -f $exitCode)
    return [pscustomobject]@{
        Rows = $rowArray
        Failures = @($rowArray | Where-Object { $_.Status -eq 'fail' }).Count
        Warnings = @($rowArray | Where-Object { $_.Status -eq 'warn' }).Count
        ExitCode = $exitCode
        VerdictRu = $verdictRu
    }
}
