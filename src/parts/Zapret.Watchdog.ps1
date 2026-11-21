# ---------------------------------------------------------------------------
# Watchdog ("Автозащита"): frequent cheap health probes of the bypass with a
# fail-closed auto-heal ladder. The weekly Zapret-AutoSelect task stays the
# deep re-check; this layer notices breakage within hours and only heals a
# service that is installed AND running (a deliberate user stop is respected).
# ---------------------------------------------------------------------------

$script:WatchdogTaskName = 'Zapret-Watchdog'

function Get-WatchdogStatePath {
    return (Join-Path (Join-Path $script:Root '.service') 'watchdog-state.json')
}

function Get-WatchdogState {
    # Returns a normalized state object; missing fields fall back to defaults so
    # StrictMode never trips over an older or hand-edited state file.
    $defaults = @{ ConsecutiveFailures = 0; LastCheckUtc = ''; LastResult = ''; LastAction = ''; LastHealUtc = ''; FallbackTried = ''; IntervalHours = 4 }
    $state = @{}
    foreach ($k in $defaults.Keys) { $state[$k] = $defaults[$k] }
    $path = Get-WatchdogStatePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            foreach ($k in $defaults.Keys) {
                $prop = $raw.PSObject.Properties[$k]
                if ($prop -and $null -ne $prop.Value) { $state[$k] = $prop.Value }
            }
        } catch { }
    }
    return [pscustomobject]$state
}

function Save-WatchdogState {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    $path = Get-WatchdogStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $merged = @{}
    try {
        $current = Get-WatchdogState
        foreach ($prop in $current.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
    } catch { }
    foreach ($k in $State.Keys) { $merged[$k] = $State[$k] }
    ($merged | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-WatchdogDecision {
    <#
        Pure decision state machine - unit-testable on any platform.
        healthy   : endpoints answer (one flaky endpoint is tolerated)
        skip      : nothing to protect / a deliberate stop - never auto-heal
        transient : first failed check - wait for a confirming one
        cooldown  : confirmed failure but a heal ran too recently
        heal      : confirmed failure - re-run the benchmark and reinstall
    #>
    param(
        [int]$PassedCount,
        [int]$TotalCount,
        [bool]$CanHeal = $true,
        [int]$PreviousFailures = 0,
        [datetime]$LastHealUtc = ([datetime]::MinValue),
        [datetime]$NowUtc = ([datetime]::UtcNow),
        [int]$CooldownMinutes = 30
    )
    if ($TotalCount -le 0) { return 'skip' }
    if ($PassedCount -ge $TotalCount) { return 'healthy' }
    if (($TotalCount -ge 2) -and ($PassedCount -ge ($TotalCount - 1))) { return 'healthy' }
    if (-not $CanHeal) { return 'skip' }
    if ($PreviousFailures -lt 1) { return 'transient' }
    if (($NowUtc - $LastHealUtc).TotalMinutes -lt $CooldownMinutes) { return 'cooldown' }
    return 'heal'
}

function Get-WatchdogCanHeal {
    # Heal only protects a working installation: the service must be installed
    # AND running. A stopped service means the user paused/stopped the bypass -
    # the watchdog must never fight that decision.
    try {
        $info = Get-ZapretServiceInfo
        return ([bool]$info.Installed -and [string]$info.State -eq 'Running')
    } catch { return $false }
}

function Get-StrategyFallbackPath {
    param([string]$Path)
    if ($Path) { return $Path }
    return (Join-Path (Join-Path $script:Root '.service') 'backup-strategies.json')
}

function Save-StrategyFallbackLadder {
    # Persists the verified candidate order from the last auto-select so the
    # watchdog can fail over in seconds before the deep re-benchmark runs.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$CandidateIds,
        [string]$WinnerId,
        [string]$Path
    )
    $ids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $CandidateIds) {
        $cid = [string]$id
        if ($cid -and -not $ids.Contains($cid)) { [void]$ids.Add($cid) }
        if ($ids.Count -ge 5) { break }
    }
    if ($ids.Count -eq 0) { throw 'Fallback ladder needs at least one candidate id.' }
    $payload = [pscustomobject]@{
        SavedAtUtc  = ([datetime]::UtcNow).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        WinnerId    = [string]$WinnerId
        Candidates  = @($ids.ToArray())
    }
    $target = Get-StrategyFallbackPath -Path $Path
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($target, ($payload | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    # A fresh ladder starts a fresh failover cycle.
    $state = Get-WatchdogState
    Save-WatchdogState @{ ConsecutiveFailures = [int]$state.ConsecutiveFailures; LastCheckUtc = [string]$state.LastCheckUtc; LastResult = [string]$state.LastResult; LastAction = [string]$state.LastAction; LastHealUtc = [string]$state.LastHealUtc; FallbackTried = '' }
    Write-Log ("Fallback ladder saved: {0} candidate(s), winner '{1}'" -f $ids.Count, $WinnerId)
    return $payload
}

function Get-StrategyFallbackLadder {
    param([string]$Path)
    $target = Get-StrategyFallbackPath -Path $Path
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { return $null }
    try {
        $data = [IO.File]::ReadAllText($target) | ConvertFrom-Json
        if (-not $data -or -not $data.Candidates) { return $null }
        return $data
    } catch { return $null }
}

function Get-StrategyFallbackPlan {
    # Pure: the next ladder candidate - fresh ladder only, never the current
    # strategy, never one already tried in this failover cycle.
    param(
        $Ladder,
        [string]$CurrentId,
        [AllowEmptyCollection()][string[]]$TriedIds = @(),
        [datetime]$NowUtc = ([datetime]::UtcNow),
        [int]$MaxAgeDays = 14
    )
    if ($null -eq $Ladder) { return $null }
    $saved = [datetime]::MinValue
    try {
        $saved = [datetime]::Parse([string]$Ladder.SavedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch { return $null }
    if (($NowUtc - $saved).TotalDays -gt $MaxAgeDays) { return $null }
    $tried = @($TriedIds | Where-Object { $_ } | ForEach-Object { [string]$_ })
    foreach ($id in @($Ladder.Candidates)) {
        $cid = [string]$id
        if (-not $cid) { continue }
        if ($CurrentId -and $cid -eq $CurrentId) { continue }
        if ($tried -contains $cid) { continue }
        return $cid
    }
    return $null
}

function Get-StrategyFallbackStatusText {
    # One short RU line for the console and the GUI watchdog state line.
    param($Ladder = (Get-StrategyFallbackLadder))
    if ($null -eq $Ladder) { return 'Запасные стратегии: лестница не сохранена (запустите автоподбор).' }
    $count = @($Ladder.Candidates).Count
    $savedAt = [string]$Ladder.SavedAtUtc
    if ($savedAt.Length -gt 10) { $savedAt = $savedAt.Substring(0, 10) }
    return ('Запасные стратегии: {0} провер. вариантов (сохранены {1}), при отказе автозащита переключается по очереди.' -f $count, $savedAt)
}

function Get-StrategyFallbackEnabled {
    # Config opt-out: strategyFallback = false disables the quick failover.
    try {
        $cfg = Get-Config
        $prop = $cfg.PSObject.Properties['strategyFallback']
        if ($prop -and $prop.Value -eq $false) { return $false }
    } catch { }
    return $true
}

function Invoke-BypassHealthProbe {
    <#
        Probes the nine benchmark endpoints through whatever bypass is
        currently active (stock tester HTTP column: curl --http1.1).
        Read-only: never changes the system state.
    #>
    param([int]$TimeoutSec = 5)
    $targets = @(Get-BenchmarkTargets)
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in $targets) {
        $items.Add(@{ Url = [string](Get-BenchmarkTargetValue -Target $t -Name 'Url'); ProtocolArgs = @('--http1.1') })
    }
    $results = @(Invoke-UrlProbeBatch -Items $items.ToArray() -TimeoutSec $TimeoutSec)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $passed = 0
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $r = $results[$i]
        $name = [string](Get-BenchmarkTargetValue -Target $targets[$i] -Name 'Name')
        if ($r.Ok) { $passed++ }
        $rows.Add([pscustomobject]@{ Name = $name; Ok = [bool]$r.Ok; Ms = [int]$r.Ms; Code = [int]$r.Code; Reason = [string]$r.Reason })
    }
    return [pscustomobject]@{ Passed = $passed; Total = $targets.Count; Rows = $rows.ToArray() }
}

function Invoke-WatchdogCheck {
    <#
        One watchdog pass: probe, decide, record the outcome and (with -AutoHeal)
        re-run the benchmark + install through the same fail-closed gates as the
        weekly task. Returns a small summary object for callers/CLI output.
    #>
    param([switch]$Scheduled, [switch]$AutoHeal)
    $state = Get-WatchdogState
    $probe = Invoke-BypassHealthProbe
    $lastHeal = [datetime]::MinValue
    try {
        if ([string]$state.LastHealUtc) {
            $lastHeal = [datetime]::Parse([string]$state.LastHealUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        }
    } catch { }
    $nowIso = ([datetime]::UtcNow).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    $decision = Get-WatchdogDecision -PassedCount $probe.Passed -TotalCount $probe.Total -CanHeal (Get-WatchdogCanHeal) -PreviousFailures ([int]$state.ConsecutiveFailures) -LastHealUtc $lastHeal
    Write-Log ("Watchdog check: {0}/{1} endpoints -> {2} ({3})" -f $probe.Passed, $probe.Total, $decision, $(if ($Scheduled) { 'scheduled' } else { 'manual' }))

    $failures = [int]$state.ConsecutiveFailures
    $action = 'ok'
    $healedNow = $false
    $fallbackTriedNow = [string]$state.FallbackTried
    switch ($decision) {
        'healthy'   { $failures = 0; $action = 'ok' }
        'skip'      { $action = 'skip-nothing-to-protect' }
        'transient' { $failures++; $action = 'first-failure' }
        'cooldown'  { $failures++; $action = 'cooldown' }
        'heal' {
            $failures++
            $action = 'healing'
            if (-not $AutoHeal) {
                $action = 'heal-required'
            } else {
                Save-WatchdogState @{ ConsecutiveFailures = $failures; LastCheckUtc = $nowIso; LastResult = ('{0}/{1}' -f $probe.Passed, $probe.Total); LastAction = 'healing'; LastHealUtc = [string]$state.LastHealUtc; FallbackTried = [string]$state.FallbackTried }
                $fallbackDone = $false
                if (Get-StrategyFallbackEnabled) {
                    try {
                        $ladder = Get-StrategyFallbackLadder
                        $triedIds = @(([string]$state.FallbackTried) -split ',' | Where-Object { $_ })
                        $currentId = $null
                        try { $currentId = [string](Get-ZapretServiceInfo).Strategy } catch { }
                        $nextId = Get-StrategyFallbackPlan -Ladder $ladder -CurrentId $currentId -TriedIds $triedIds
                        if ($nextId -and (Get-Strategy $nextId)) {
                            Install-ZapretService -StrategyId $nextId -NoSnapshot | Out-Null
                            $fallbackDone = $true
                            $healedNow = $true
                            $action = ('fallback:{0}' -f $nextId)
                            $triedIds += [string]$nextId
                            $fallbackTriedNow = ($triedIds -join ',')
                            Write-Log ("Watchdog fallback: switched to ladder candidate '{0}' (quick failover; deeper checks follow)" -f $nextId)
                            Write-WatchdogNotice ('Автозащита: обход переключён на запасную стратегию «{0}».' -f $nextId)
                            Save-WatchdogState @{ ConsecutiveFailures = $failures; LastCheckUtc = $nowIso; LastResult = ('{0}/{1}' -f $probe.Passed, $probe.Total); LastAction = $action; LastHealUtc = $nowIso; FallbackTried = ($triedIds -join ',') }
                        }
                    } catch {
                        Write-Log ("Watchdog fallback attempt failed: {0}" -f $_.Exception.Message) 'WARN'
                    }
                }
                if (-not $fallbackDone) {
                    try {
                        Invoke-AutoSelect -Install -NoInteractive -Scheduled | Out-Null
                        $action = 'healed'
                        $healedNow = $true
                        Write-Log 'Watchdog healed: benchmark re-run and the winner installed (fail-closed gates)'
                        Write-WatchdogNotice 'Автозащита: обход восстановлен (выполнен полный подбор).'
                    } catch {
                        $action = ('heal-failed: {0}' -f $_.Exception.Message)
                        Write-Log ("Watchdog heal failed: {0}" -f $_.Exception.Message) 'ERROR'
                        $notice = ('Автозащита: не удалось восстановить обход: {0}' -f $_.Exception.Message)
                        if ($notice.Length -gt 200) { $notice = $notice.Substring(0, 200) }
                        Write-WatchdogNotice $notice
                    }
                }
            }
        }
    }
    $healStamp = if ($healedNow) { $nowIso } else { [string]$state.LastHealUtc }
    Save-WatchdogState @{ ConsecutiveFailures = $failures; LastCheckUtc = $nowIso; LastResult = ('{0}/{1}' -f $probe.Passed, $probe.Total); LastAction = $action; LastHealUtc = $healStamp; FallbackTried = $fallbackTriedNow }
    return [pscustomobject]@{ Passed = $probe.Passed; Total = $probe.Total; Decision = $decision; Action = $action; Rows = $probe.Rows }
}


# ---------------------------------------------------------------------------
# Tray autostart ("Автозапуск трея"): HKCU Run key, no admin required.
# ---------------------------------------------------------------------------

function Get-TrayAutostartState {
    if (-not $script:OnWindows) { throw 'tray-autostart requires Windows.' }
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $item = Get-ItemProperty -Path $run -Name 'ZapretTray' -ErrorAction SilentlyContinue
    $value = if ($null -ne $item) { [string]$item.ZapretTray } else { '' }
    return [pscustomobject]@{ Enabled = [bool]$value; Value = $value }
}

function Set-TrayAutostart {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('enable', 'disable')][string]$Mode)
    if (-not $script:OnWindows) { throw 'tray-autostart requires Windows.' }
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($Mode -eq 'disable') {
        Remove-ItemProperty -Path $run -Name 'ZapretTray' -ErrorAction SilentlyContinue
        Write-Ok 'Автозапуск трея выключен.'
        Write-Log 'Tray autostart disabled'
        return [pscustomobject]@{ Enabled = $false }
    }
    $exe = Join-Path $script:Root 'Zapret-Tray.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw ("Zapret-Tray.exe не найден: {0}" -f $exe) }
    Set-ItemProperty -Path $run -Name 'ZapretTray' -Value ('"{0}"' -f $exe) -Type String
    Write-Ok 'Трей будет запускаться вместе с Windows.'
    Write-Log 'Tray autostart enabled'
    return [pscustomobject]@{ Enabled = $true }
}

function Test-WatchdogSchedule {
    if (-not $script:OnWindows) { return $false }
    # schtasks writes "task not found" to stderr; never merge that stream into
    # the pipeline or Windows PowerShell 5.1 turns it into a terminating error.
    $out = (& (Get-WindowsSystemToolPath -Name 'schtasks.exe') /Query /TN $script:WatchdogTaskName /FO CSV /NH 2>$null | Out-String)
    return ($LASTEXITCODE -eq 0 -and $out -match $script:WatchdogTaskName)
}

function Set-WatchdogSchedule {
    param(
        [switch]$Enable,
        [switch]$Disable,
        [ValidateRange(1, 24)][int]$IntervalHours = 4
    )
    if (-not $script:OnWindows) { throw 'watchdog schedule requires Windows.' }
    Assert-Admin
    if ($Enable -and $Disable) { throw 'Use only one of -Enable or -Disable.' }
    if (-not $Enable -and -not $Disable) { throw 'Specify -Enable or -Disable.' }

    if ($Disable) {
        if (-not (Test-WatchdogSchedule)) { Write-Info2 'Автозащита уже выключена.'; return }
        & (Get-WindowsSystemToolPath -Name 'schtasks.exe') /Delete /TN $script:WatchdogTaskName /F 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'schtasks could not delete the watchdog task.' }
        Write-Ok 'Автозащита выключена.'
        Write-Log 'Watchdog schedule removed'
        return
    }

    $psExe = Get-WindowsSystemToolPath -Name 'powershell.exe'
    if (-not $psExe) { throw 'powershell.exe not found.' }
    $scriptPath = Join-Path $script:Root 'zapret.ps1'
    $tr = Get-WatchdogTaskArguments -PowerShellPath $psExe -ScriptPath $scriptPath
    & (Get-WindowsSystemToolPath -Name 'schtasks.exe') /Create /TN $script:WatchdogTaskName /TR $tr /SC HOURLY /MO $IntervalHours /RU SYSTEM /RL HIGHEST /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'schtasks could not create the watchdog task (run as Administrator).' }
    Save-WatchdogState @{ IntervalHours = $IntervalHours }
    Write-Ok ("Автозащита включена: проверка обхода каждые {0} ч от имени SYSTEM." -f $IntervalHours)
    Write-Info2 'При двух подряд сбоях запускается автоподбор; служба переключается только на полностью подтверждённую стратегию.'
    Write-Log ("Watchdog schedule enabled (every {0}h)" -f $IntervalHours)
}

function Write-WatchdogNotice {
    # One-shot notice file for the tray: shown as a balloon once, then deleted
    # by Zapret-Tray.exe. Written atomically (temp + move).
    param([Parameter(Mandatory = $true)][string]$Text)
    try {
        $dir = Join-Path $script:Root '.service'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $target = Join-Path $dir 'watchdog-notice.txt'
        $temp = '{0}.tmp' -f $target
        [IO.File]::WriteAllText($temp, $Text, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $target -Force
    } catch { }
}

function Get-WatchdogStatusText {
    # One-line status for the console 'watchdog status' verb.
    $state = Get-WatchdogState
    $enabled = Test-WatchdogSchedule
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($enabled) { $parts.Add(('Автозащита включена (каждые {0} ч, SYSTEM).' -f [int]$state.IntervalHours)) } else { $parts.Add('Автозащита выключена.') }
    if ([string]$state.LastCheckUtc) {
        $parts.Add(('Последняя проверка: {0} — {1}.' -f $state.LastCheckUtc, $state.LastResult))
    }
    if ([string]$state.LastAction) {
        $parts.Add(('Последнее действие: {0}.' -f $state.LastAction))
    }
    $parts.Add((Get-StrategyFallbackStatusText))
    return ($parts -join ' ')
}
