# ---------------------------------------------------------------------------
# Weekly auto re-check of strategies (what works today can stop working in a
# few weeks as censorship adapts)
# ---------------------------------------------------------------------------

$script:AutoSelectTaskName = 'Zapret-AutoSelect'

function Test-AutoSelectSchedule {
    if (-not $script:OnWindows) { return $false }
    # schtasks writes "task not found" to stderr; never merge that stream into
    # the pipeline or Windows PowerShell 5.1 turns it into a terminating error.
    $out = (& (Get-WindowsSystemToolPath -Name 'schtasks.exe') /Query /TN $script:AutoSelectTaskName /FO CSV /NH 2>$null | Out-String)
    return ($LASTEXITCODE -eq 0 -and $out -match $script:AutoSelectTaskName)
}

function Set-AutoSelectSchedule {
    param(
        [switch]$Enable,
        [switch]$Disable,
        [ValidateSet('MON','TUE','WED','THU','FRI','SAT','SUN')]
        [string]$Day = 'SUN',
        [string]$Time = '03:30'
    )
    if (-not $script:OnWindows) { throw 'schedule-autoselect requires Windows.' }
    Assert-Admin

    if ($Enable -and $Disable) { throw 'Use only one of -Enable or -Disable.' }
    if (-not $Enable -and -not $Disable) { throw 'Specify -Enable or -Disable.' }

    if ($Disable) {
        if (-not (Test-AutoSelectSchedule)) { Write-Info2 'The weekly auto re-check is not scheduled.'; return }
        & (Get-WindowsSystemToolPath -Name 'schtasks.exe') /Delete /TN $script:AutoSelectTaskName /F 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'schtasks could not delete the task.' }
        Write-Ok 'Weekly auto re-check removed.'
        Write-Log 'Auto-select schedule removed'
        return
    }

    if ($Time -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') { throw "Invalid -Time '$Time' (expected HH:mm, 00:00-23:59)." }
    $psExe = Get-WindowsSystemToolPath -Name 'powershell.exe'
    if (-not $psExe) { throw 'powershell.exe not found.' }
    $scriptPath = Join-Path $script:Root 'zapret.ps1'
    $tr = Get-AutoSelectTaskArguments -PowerShellPath $psExe -ScriptPath $scriptPath

    & (Get-WindowsSystemToolPath -Name 'schtasks.exe') /Create /TN $script:AutoSelectTaskName /TR $tr /SC WEEKLY /D $Day /ST $Time /RU SYSTEM /RL HIGHEST /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'schtasks could not create the task (run as Administrator).' }
    Write-Ok ("Weekly auto re-check scheduled: every {0} at {1} (SYSTEM)." -f $Day, $Time)
    Write-Info2 'If the current strategy still reaches everything, the task exits in seconds and winws.exe is NOT restarted.'
    Write-Warn2 'The benchmark stops the bypass for ~2-5 minutes during the run. Remove with: zapret.ps1 schedule-autoselect disable'
    Write-Log "Auto-select schedule enabled ($Day $Time)"
}

# ---------------------------------------------------------------------------
# Post-install: hosts + ipset so the setup is actually complete
# ---------------------------------------------------------------------------

function Invoke-PostInstallConfiguration {
    param([switch]$Ask, [switch]$DefaultNo)

    $doIt = -not $Ask
    if ($Ask) {
        if ($DefaultNo) {
            $prompt = Get-UiText -Russian '   Также обновить записи hosts и список IP? [д/н, по умолчанию нет]' -English '   Also update hosts entries and the IP list? [y/N; default no]'
        } else {
            $prompt = Get-UiText -Russian '   Также обновить записи hosts и список IP? [д/н]' -English '   Also update the hosts entries and IP list now? [Y/n]'
        }
        try {
            $answer = Read-Host $prompt
            if ($DefaultNo) {
                $doIt = $answer -and ($answer.Trim() -match '^(?i:y|yes|д|да)$')
            } else {
                $doIt = ([string]::IsNullOrWhiteSpace($answer)) -or ($answer.Trim() -match '^(y|yes|д|да)$')
            }
        } catch { $doIt = $false }
    }
    if (-not $doIt) { Write-Info2 'Skipped hosts/ipset setup (run them later from the menu).'; return }

    try { Update-HostsFile | Out-Null; Write-Ok 'hosts: managed block installed/updated' }
    catch { Write-Warn2 "hosts update failed: $($_.Exception.Message)" }

    try { Update-IpsetList | Out-Null; Write-Ok 'IPSet: list updated' }
    catch { Write-Warn2 "IPSet update failed: $($_.Exception.Message)" }

    Write-Info2 'If sites still do not open, the problem is likely plain-DNS poisoning. Try: zapret.ps1 dns doh cloudflare'
}
# ---------------------------------------------------------------------------
# Launch-path validation (Cyrillic / spaces / OneDrive break winws.exe)
# ---------------------------------------------------------------------------

function Test-ZapretInstallPath {
    # Returns a list of human-readable problems with the install path (empty = OK).
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    $issues = @()
    if ([string]::IsNullOrWhiteSpace($Path)) { return @('путь пуст') }
    if ($Path -match '[^\x00-\x7F]') {
        $issues += 'путь содержит не-ASCII символы (например, кириллицу)'
    } elseif ($Path -match '[^A-Za-z0-9_\\/:. -]') {
        $issues += 'путь содержит спецсимволы'
    }
    if ($Path -match '\s') { $issues += 'путь содержит пробелы' }
    if ($Path -match '(?i)onedrive') { $issues += 'папка находится внутри OneDrive (синхронизация ломает файлы обхода)' }
    return @($issues)
}

function Move-ZapretToRoot {
    <#
        Moves the install folder to C:\zapret (robocopy /E /MOVE; exit codes 0..7 are OK).
        Refuses to move a running winws (files would be locked). Windows + admin only.
        Returns the new path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$Target = 'C:\zapret'
    )
    if (-not $script:OnWindows) { throw 'Перенос в C:\zapret поддерживается только на Windows.' }
    Assert-Admin
    $src = $Source.TrimEnd('\')
    $dst = $Target.TrimEnd('\')
    if ($src -ieq $dst) { return $dst }
    if (Test-Path -LiteralPath $dst) { throw "Папка $dst уже существует. Удалите или переименуйте её, либо перенесите zapret вручную." }
    if (Get-WinwsProcess | Select-Object -First 1) {
        throw 'winws.exe сейчас запущен - файлы будут заблокированы. Сначала удалите службу (zapret.ps1 uninstall), затем повторите.'
    }
    $strategyBefore = $null
    try { $strategyBefore = (Get-ZapretServiceInfo).Strategy } catch { }

    Write-Info2 "Переношу папку $src -> $dst ..."
    & (Get-WindowsSystemToolPath -Name 'robocopy.exe') $src $dst /E /MOVE /NFL /NDL /NJH /NJS /NP | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw "robocopy завершился с кодом $code. Часть файлов могла быть перенесена - проверьте $dst и исходную папку вручную." }
    Write-Ok "Папка перенесена в $dst"

    if ($strategyBefore) {
        Write-Warn2 "Служба 'zapret' (стратегия: $strategyBefore) по-прежнему указывает на старую папку."
        Write-Info2 "В новой папке выполните: zapret.ps1 install $strategyBefore"
        Write-Info2 'Если включена еженедельная перепроверка, пересоздайте задачу: zapret.ps1 schedule-autoselect disable; zapret.ps1 schedule-autoselect enable'
    }
    Write-Log "Install folder moved: $src -> $dst"
    return $dst
}

# ---------------------------------------------------------------------------
# Auto-select -Fast (early exit when a known-good strategy passes everything)
# ---------------------------------------------------------------------------

function Get-BenchmarkOrder {
    # Pure ordering helper. Generic Fast keeps its historical order; a named
    # carrier starts with its last live-tested narrow result and profile order.
    param(
        [Parameter(Mandatory = $true)][array]$Available,
        [string]$CurrentStrategy,
        [string]$PreferredStrategy,
        [ValidateSet('mts','megafon','tele2','yota')][string]$Carrier,
        [switch]$Fast
    )
    $list = @($Available)
    if (-not $Fast -and -not $Carrier) { return $list }
    if ($Carrier) {
        $profile = Get-MobileCarrierProfile -Carrier $Carrier
        $candidatePriority = @($PreferredStrategy) + @($profile.StrategyOrder) + @($CurrentStrategy)
    } else {
        $candidatePriority = @($CurrentStrategy, 'general', 'alt', 'fake-tls-auto')
    }
    $priority = @()
    foreach ($id in $candidatePriority) {
        if (-not $id) { continue }
        if (($list | Where-Object { $_.id -eq $id } | Select-Object -First 1) -and ($priority -notcontains $id)) {
            $priority += $id
        }
    }
    $head = @(foreach ($id in $priority) { $list | Where-Object { $_.id -eq $id } | Select-Object -First 1 })
    $tail = @($list | Where-Object { $priority -notcontains $_.id })
    return @($head + $tail)
}

# ---------------------------------------------------------------------------
# DoH provider availability probe
# ---------------------------------------------------------------------------

function Test-DohHttpCodeReachable {
    # Any HTTP response (even 400/403/503) means the endpoint answered - only
    # a dead connection (curl reports 000) counts as 'blocked'.
    param([int]$Code)
    return ($Code -ge 100)
}

function Test-DohProviderAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 6
    )
    $p = Get-DohProviderTable -Provider $Provider
    if (-not $p) { throw "Unknown provider '$Provider'" }
    $curl = Get-CurlPath
    if (-not $curl) {
        return [pscustomobject]@{ Provider = $Provider; Reachable = $null; ElapsedMs = $null; Detail = 'curl not found - probe skipped' }
    }
    $nullDevice = if ($script:OnWindows) { 'NUL' } else { '/dev/null' }
    $connectTimeout = [Math]::Min(3, $TimeoutSeconds)
    $code = 0
    $elapsedMs = $null
    try {
        $out = & $curl -I -s -m $TimeoutSeconds --connect-timeout $connectTimeout -o $nullDevice -w '%{http_code} %{time_total}' $p.Template 2>$null
        $codeText = ($out | Out-String).Trim()
        $match = [regex]::Match($codeText, '^(?<code>\d{3})(?:\s+(?<seconds>(?:\d+(?:\.\d*)?|\.\d+)))?$')
        if ($match.Success) {
            [void][int]::TryParse($match.Groups['code'].Value, [ref]$code)
            if ($match.Groups['seconds'].Success) {
                $seconds = 0.0
                if ([double]::TryParse($match.Groups['seconds'].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$seconds)) {
                    $elapsedMs = [Math]::Round(($seconds * 1000.0), 2)
                }
            }
        }
    } catch {
        return [pscustomobject]@{ Provider = $Provider; Reachable = $false; ElapsedMs = $null; Detail = $_.Exception.Message }
    }
    return [pscustomobject]@{ Provider = $Provider; Reachable = (Test-DohHttpCodeReachable -Code $code); ElapsedMs = $elapsedMs; Detail = "HTTP $code" }
}

function Select-FastestDns {
    <# Pure selector: returns the lowest-latency reachable DNS result, or $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Results)

    $candidates = @()
    foreach ($result in @($Results)) {
        if ($null -eq $result) { continue }
        $reachable = $null
        $reachableProperty = $result.PSObject.Properties['Reachable']
        if ($reachableProperty) {
            $reachableValue = $reachableProperty.Value
            if ($reachableValue -is [bool]) { $reachable = $reachableValue }
            elseif ($reachableValue -is [ValueType] -and $reachableValue -isnot [char]) {
                if ([double]$reachableValue -eq 1) { $reachable = $true }
                elseif ([double]$reachableValue -eq 0) { $reachable = $false }
            } elseif ($null -ne $reachableValue) {
                $reachableText = ([string]$reachableValue).Trim()
                if ($reachableText -match '^(?i:true|yes|1|reachable|available|online|ok|working|доступен|доступна|доступно)$') { $reachable = $true }
                elseif ($reachableText -match '^(?i:false|no|0|unavailable|offline|failed|недоступен|недоступна|недоступно)$') { $reachable = $false }
            }
        } elseif ($result.PSObject.Properties['Status']) {
            $statusText = [string]$result.PSObject.Properties['Status'].Value
            if ($statusText -match '^(?i)(reachable|available|online|ok|working|доступен|доступна|доступно)$') { $reachable = $true }
        }
        if ($reachable -ne $true) { continue }

        $latency = $null
        foreach ($propertyName in @('AverageRttMs', 'AvgRttMs', 'AvgMs', 'AverageMs', 'Ping', 'RttMs')) {
            $property = $result.PSObject.Properties[$propertyName]
            if ($null -eq $property -or $null -eq $property.Value) { continue }
            $parsed = 0.0
            if ($property.Value -is [bool] -or $property.Value -is [char]) { continue }
            if ($property.Value -is [ValueType]) { $parsed = [double]$property.Value }
            elseif (-not [double]::TryParse([string]$property.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { continue }
            if ([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or $parsed -lt 0) { continue }
            $latency = $parsed
            break
        }
        if ($null -eq $latency) { continue }
        $providerKey = ''
        if ($result.PSObject.Properties['Provider']) { $providerKey = [string]$result.PSObject.Properties['Provider'].Value }
        elseif ($result.PSObject.Properties['Name']) { $providerKey = [string]$result.PSObject.Properties['Name'].Value }
        $candidates += [pscustomobject]@{ Latency = $latency; Provider = $providerKey; Original = $result }
    }
    $winner = $candidates | Sort-Object Latency, Provider | Select-Object -First 1
    if ($winner) { return $winner.Original }
    return $null
}

function Get-DnsBenchmarkLatency {
    <# Prefer valid ICMP samples; use HTTPS timing only when ICMP yielded no RTTs. #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][double[]]$IcmpSamples = @(),
        [AllowEmptyCollection()][double[]]$HttpsSamples = @()
    )
    $samples = @($IcmpSamples | Where-Object { -not [double]::IsNaN($_) -and -not [double]::IsInfinity($_) -and $_ -ge 0 })
    $source = 'ICMP'
    if ($samples.Count -eq 0) {
        $samples = @($HttpsSamples | Where-Object { -not [double]::IsNaN($_) -and -not [double]::IsInfinity($_) -and $_ -ge 0 })
        $source = 'HTTPS'
    }
    if ($samples.Count -eq 0) { return [pscustomobject]@{ AverageRttMs = $null; RttSource = 'n/a' } }
    $average = [Math]::Round((($samples | Measure-Object -Average).Average), 2)
    return [pscustomobject]@{ AverageRttMs = $average; RttSource = $source }
}

function Invoke-DnsBenchmark {
    <# Tests each resolver with three IPv4 pings and each DoH HTTPS endpoint three times. #>
    [CmdletBinding()]
    param([switch]$NoPrompt, [switch]$Preview, [switch]$ApplyFastest)
    if (-not $script:OnWindows) { throw 'dns benchmark requires Windows.' }

    $results = @()
    foreach ($provider in (Get-DohProviderTable)) {
        $pingTimes = New-Object System.Collections.Generic.List[double]
        $pingReplies = 0
        $pinger = New-Object System.Net.NetworkInformation.Ping
        try {
            for ($sampleIndex = 0; $sampleIndex -lt 3; $sampleIndex++) {
                try {
                    $reply = $pinger.Send([string]$provider.Primary, 1000)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $pingReplies++
                        $pingTimes.Add([double]$reply.RoundtripTime)
                    }
                } catch { }
            }
        } finally { $pinger.Dispose() }

        $httpsTimes = New-Object System.Collections.Generic.List[double]
        $httpResponses = 0
        $unknown = 0
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            try { $probe = Test-DohProviderAvailable -Provider $provider.Key -TimeoutSeconds 3 }
            catch { $probe = [pscustomobject]@{ Reachable = $false; ElapsedMs = $null; Detail = $_.Exception.Message } }
            if ($probe.Reachable -eq $true) {
                $httpResponses++
                if ($null -ne $probe.ElapsedMs) { $httpsTimes.Add([double]$probe.ElapsedMs) }
            } elseif ($null -eq $probe.Reachable) {
                $unknown++
            }
        }
        $reachable = $false
        if ($httpResponses -gt 0) { $reachable = $true }
        elseif ($unknown -eq 3) { $reachable = $null }

        # HTTPS timings are a fallback only when no ICMP RTT was received.
        $latency = Get-DnsBenchmarkLatency -IcmpSamples ([double[]]$pingTimes.ToArray()) -HttpsSamples ([double[]]$httpsTimes.ToArray())
        $average = $latency.AverageRttMs
        $rttSource = $latency.RttSource
        $status = if ($reachable -eq $true) { 'Reachable' } elseif ($null -eq $reachable) { 'Unknown' } else { 'Unavailable' }
        $detail = ('DoH HTTP {0}/3; ICMP {1}/3' -f $httpResponses, $pingReplies)
        $results += [pscustomobject]@{
            Provider      = $provider.Key
            Name          = $provider.Name
            Primary       = $provider.Primary
            EndpointHost  = $provider.Host
            Reachable     = $reachable
            Status        = $status
            AverageRttMs  = $average
            RttSource     = $rttSource
            PingReplies   = $pingReplies
            HttpResponses = $httpResponses
            Attempts      = 3
            Detail        = $detail
        }
    }

    $ordered = @($results | Sort-Object `
        @{ Expression = 'Name'; Descending = $false },
        @{ Expression = { if ($_.Reachable -eq $true) { 0 } elseif ($null -eq $_.Reachable) { 1 } else { 2 } }; Descending = $false },
        @{ Expression = { if ($null -ne $_.AverageRttMs) { [double]$_.AverageRttMs } else { [double]::MaxValue } }; Descending = $false })
    Write-Host ''
    Write-Host (Get-UiText -Russian '   СРАВНЕНИЕ DNS / DoH (3 проверки связи и 3 HTTPS-запроса на провайдера)' -English '   DNS / DoH BENCHMARK (3 pings and 3 HTTPS probes per provider)') -ForegroundColor Cyan
    Write-HostTable -InputObject ($ordered | Select-Object `
        @{ Name = 'Provider'; Expression = { $_.Name } },
        @{ Name = 'Server IP'; Expression = { $_.Primary } },
        Status,
        @{ Name = 'Average RTT (ms)'; Expression = { if ($null -ne $_.AverageRttMs) { '{0:N2}' -f $_.AverageRttMs } else { 'n/a' } } },
        RttSource,
        @{ Name = 'ICMP'; Expression = { '{0}/{1}' -f $_.PingReplies, $_.Attempts } },
        @{ Name = 'DoH HTTP'; Expression = { '{0}/{1}' -f $_.HttpResponses, $_.Attempts } },
        EndpointHost)

    $fastest = Select-FastestDns -Results $results
    if (-not $fastest) {
        if ($Preview) { Write-PreviewInfo 'Preview: no reachable DoH provider with a measured response time was found; DNS would not be changed.' }
        else { Write-Warn2 'No reachable DoH provider with a measured response time was found.' }
        $unknownProviders = @($results | Where-Object { $null -eq $_.Reachable }).Count
        if ($unknownProviders -gt 0) {
            if ($Preview) { Write-PreviewInfo 'Preview: restore curl.exe or check connectivity before repeating the benchmark.' }
            else { Write-Info2 'Install/restore curl.exe or check the network, then repeat the benchmark.' }
        }
        return $ordered
    }
    if ($Preview) { Write-PreviewInfo ("Measured fastest reachable provider: {0} ({1:N2} ms average, {2}; {3})." -f $fastest.Name, $fastest.AverageRttMs, $fastest.RttSource, $fastest.Primary) }
    else { Write-Ok ("Fastest reachable provider: {0} ({1:N2} ms average, {2}; {3})." -f $fastest.Name, $fastest.AverageRttMs, $fastest.RttSource, $fastest.Primary) }
    if ($Preview) {
        $dnsPlan = Enable-Doh -Provider $fastest.Provider -Preview
        return [pscustomobject]@{ Preview = $true; Results = @($ordered); DnsPlan = $dnsPlan }
    }
    if ($NoPrompt) {
        Write-PreviewInfo ("Preview: would configure {0} ({1}, {2}) on active adapters and save a DNS rollback snapshot. No settings changed; run zapret.ps1 dns doh {0} to apply." -f $fastest.Provider, $fastest.Primary, (Get-DohProviderTable -Provider $fastest.Provider).Secondary)
        return $ordered
    }
    if ($ApplyFastest) {
        Enable-Doh -Provider $fastest.Provider
        return $ordered
    }
    $answer = $null
    try { $answer = Read-Host (Get-UiText -Russian ("Включить DNS-провайдер «{0}»? Сначала сохраню текущие настройки. [д/н]" -f $fastest.Name) -English ("Enable DNS provider '{0}'? Current settings will be backed up first. [y/N]" -f $fastest.Name)) } catch { }
    if ($answer -and $answer.Trim() -match '^(?i:y|yes|д|да)$') {
        Enable-Doh -Provider $fastest.Provider
    } else {
        Write-Info2 'No DNS settings were changed.'
    }
    return $ordered
}
