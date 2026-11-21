# ---------------------------------------------------------------------------
# Auto-select: benchmark the strategies on this PC and pick the best one
# ---------------------------------------------------------------------------

# Web endpoints used as a lightweight reachability check for the four
# supported apps. They do not prove that sign-in, streaming, or voice calls work.
$script:BenchmarkTargets = @(
    @{ Name = 'DiscordMain';   Service = 'Discord';   Url = 'https://discord.com' },
    @{ Name = 'DiscordGW';     Service = 'Discord';   Url = 'https://gateway.discord.gg' },
    @{ Name = 'DiscordCDN';    Service = 'Discord';   Url = 'https://cdn.discordapp.com' },
    @{ Name = 'DiscordUpdate'; Service = 'Discord';   Url = 'https://updates.discord.com' },
    @{ Name = 'YouTube';       Service = 'YouTube';   Url = 'https://www.youtube.com' },
    @{ Name = 'YouTubeShort';  Service = 'YouTube';   Url = 'https://youtu.be' },
    @{ Name = 'YouTubeVideo';  Service = 'YouTube';   Url = 'https://redirector.googlevideo.com' },
    @{ Name = 'WhatsAppWeb';   Service = 'WhatsApp';  Url = 'https://web.whatsapp.com' },
    @{ Name = 'WhatsAppMain';  Service = 'WhatsApp';  Url = 'https://www.whatsapp.com' }
)

function Get-BenchmarkTargets {
    # An active bypass profile narrows the endpoint set so scans, the watchdog
    # and health checks only require the services the profile actually covers.
    $all = @($script:BenchmarkTargets | ForEach-Object { [pscustomobject]$_ })
    $profile = 'all'
    try { $profile = [string](Get-BypassProfile) } catch { }
    if ($profile -eq 'all' -or $profile -eq 'custom') { return $all }
    $def = @(Get-BypassProfiles | Where-Object { $_.Id -eq $profile }) | Select-Object -First 1
    if (-not $def) { return $all }
    return @($all | Where-Object {
        $svc = ([string](Get-BenchmarkTargetValue -Target $_ -Name 'Service')).ToLowerInvariant()
        if (@($def.ExcludeIds).Count -gt 0) { @($def.ExcludeIds) -notcontains $svc } else { @($def.KeepIds) -contains $svc }
    })
}

function Get-BenchmarkStrategyById {
    <# Resolve a ranked result back to the strategy definition used by winws.exe. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Strategies,
        [Parameter(Mandatory = $true)][string]$Id
    )
    foreach ($strategy in $Strategies) {
        $strategyId = [string](Get-BenchmarkTargetValue -Target $strategy -Name 'id')
        if ([string]::Equals($strategyId, $Id, [StringComparison]::OrdinalIgnoreCase)) { return $strategy }
    }
    return $null
}

function Get-BenchmarkTargetValue {
    # Read either a hashtable entry or an object property without triggering StrictMode
    # when an older/partial target entry lacks an optional field.
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Target,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Target) { return $null }
    if ($Target -is [System.Collections.IDictionary]) {
        if ($Target.Contains($Name)) { return $Target[$Name] }
        foreach ($key in $Target.Keys) {
            if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) { return $Target[$key] }
        }
    }
    $property = $Target.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-BenchmarkServiceName {
    [CmdletBinding()]
    param([AllowNull()][object]$Target)
    $service = [string](Get-BenchmarkTargetValue -Target $Target -Name 'Service')
    if (-not [string]::IsNullOrWhiteSpace($service)) { return $service }
    # Derive a safe fallback from the stable endpoint names for older target lists
    # that predate the explicit Service field.
    $name = [string](Get-BenchmarkTargetValue -Target $Target -Name 'Name')
    switch -Regex ($name) {
        '^Discord'  { return 'Discord' }
        '^YouTube'  { return 'YouTube' }
        '^WhatsApp' { return 'WhatsApp' }
    }
    return $null
}

function Get-BenchmarkServiceSummary {
    # Carrier scans require at least one successful web probe for each requested service.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$TargetResults,
        [AllowNull()][array]$Targets = $null
    )
    if ($null -eq $Targets -or $Targets.Count -eq 0) { $Targets = @(Get-BenchmarkTargets) }
    $serviceTargets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in $Targets) {
        $targetName = [string](Get-BenchmarkTargetValue -Target $target -Name 'Name')
        $serviceName = Get-BenchmarkServiceName -Target $target
        if ($targetName -and $serviceName) {
            $serviceTargets.Add([pscustomobject]@{ Name = $targetName; Service = $serviceName })
        }
    }
    $services = @()
    $serviceNames = @($serviceTargets | Select-Object -ExpandProperty Service -Unique)
    foreach ($serviceName in $serviceNames) {
        $targetNames = @($serviceTargets | Where-Object { $_.Service -eq $serviceName } | Select-Object -ExpandProperty Name)
        $matchingResults = @($TargetResults | Where-Object { $_.Name -in $targetNames })
        $passed = @($matchingResults | Where-Object { $_.Ok }).Count
        $services += [pscustomobject]@{
            Service = $serviceName
            Passed  = $passed
            Total   = $targetNames.Count
            Ok      = ($passed -ge 1)
        }
    }
    $passedServices = @($services | Where-Object { $_.Ok }).Count
    return [pscustomobject]@{
        PassedServices = $passedServices
        TotalServices  = $services.Count
        AllPassed      = ($services.Count -gt 0 -and $passedServices -eq $services.Count)
        Services       = @($services)
    }
}

function Get-MobileCarrierProfiles {
    # The order is an anecdotal starting point for live testing, not a claim
    # that any strategy always works on every region, SIM, or access point.
    return @(
        [pscustomobject]@{
            Id = 'mts'; RussianName = 'МТС'; EnglishName = 'MTS'
            StrategyOrder = @('carrier-mts', 'carrier-tele2', 'carrier-megafon', 'carrier-yota')
        }
        [pscustomobject]@{
            Id = 'megafon'; RussianName = 'МегаФон'; EnglishName = 'MegaFon'
            StrategyOrder = @('carrier-megafon', 'carrier-yota', 'carrier-mts', 'carrier-tele2')
        }
        [pscustomobject]@{
            Id = 'tele2'; RussianName = 'Tele2 / T2'; EnglishName = 'Tele2 / T2'
            StrategyOrder = @('carrier-tele2', 'carrier-mts', 'carrier-megafon', 'carrier-yota')
        }
        [pscustomobject]@{
            Id = 'yota'; RussianName = 'Йота'; EnglishName = 'Yota'
            StrategyOrder = @('carrier-yota', 'carrier-megafon', 'carrier-tele2', 'carrier-mts')
        }
    )
}

function Get-MobileCarrierProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('mts','megafon','tele2','yota')][string]$Carrier)
    $key = $Carrier.ToLowerInvariant()
    return (Get-MobileCarrierProfiles | Where-Object { $_.Id -eq $key } | Select-Object -First 1)
}

function Get-MobileCarrierBestStrategy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('mts','megafon','tele2','yota')][string]$Carrier,
        [string]$ConfigPath = $null
    )
    $config = Get-Config -Path $ConfigPath
    $strategyId = [string]$config.carrierStrategies[$Carrier.ToLowerInvariant()]
    if ($strategyId -match '^[a-z0-9][a-z0-9-]{1,40}$') { return $strategyId }
    return $null
}

function Set-MobileCarrierBestStrategy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('mts','megafon','tele2','yota')][string]$Carrier,
        [Parameter(Mandatory = $true)][string]$StrategyId,
        [string]$ConfigPath = $null
    )
    $normalizedId = $StrategyId.Trim().ToLowerInvariant()
    if (-not (Get-Strategy -Id $normalizedId)) { throw "Unknown strategy '$StrategyId' - cannot save a carrier profile." }
    Update-Config -Path $ConfigPath -Changes @{ carrier = $Carrier.ToLowerInvariant(); carrierStrategy = $normalizedId } | Out-Null
    return (Get-MobileCarrierBestStrategy -Carrier $Carrier -ConfigPath $ConfigPath)
}

function Get-WindowsSystemToolPath {
    <# Resolve a tightly allow-listed Windows binary from the OS system directory, never PATH. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('curl.exe', 'netsh.exe', 'ping.exe', 'sc.exe', 'schtasks.exe', 'robocopy.exe', 'powershell.exe', 'notepad.exe')][string]$Name)
    if (-not $script:OnWindows) { throw "$Name is available only on Windows." }
    $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    if ([string]::IsNullOrWhiteSpace($systemDirectory)) { throw 'Could not resolve the Windows system directory.' }
    if ($Name -eq 'powershell.exe') {
        $candidate = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
    } else {
        $candidate = Join-Path $systemDirectory $Name
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw ("Required Windows system tool was not found: {0}" -f $candidate) }
    return $candidate
}

function Get-CurlPath {
    if ($script:OnWindows) {
        try { return (Get-WindowsSystemToolPath -Name 'curl.exe') } catch { return $null }
    }
    $cmd = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { $cmd = Get-Command curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-CurlFailureReason {
    # Pure helper: map a curl exit code to a short failure token used by the
    # journal and the end-of-run hints (dns / timeout / reset / ...).
    param([int]$ExitCode)
    if ($ExitCode -eq 0) { return 'no-response' }
    if ($ExitCode -eq 6) { return 'dns' }
    if ($ExitCode -eq 7) { return 'refused' }
    if ($ExitCode -eq 28) { return 'timeout' }
    if ($ExitCode -eq 52) { return 'empty' }
    if ($ExitCode -in 35,51,53,54,56,58,60,77,90,91) { return 'reset' }
    return ('error-{0}' -f $ExitCode)
}

function Get-CurlFailureReasonText {
    # UI text for a failure token returned by Get-CurlFailureReason.
    param([string]$Reason)
    switch ([string]$Reason) {
        'dns'         { return (Get-UiText -Russian 'DNS не резолвит' -English 'DNS resolution failed') }
        'timeout'     { return (Get-UiText -Russian 'таймаут' -English 'timeout') }
        'refused'     { return (Get-UiText -Russian 'соединение отклонено' -English 'connection refused') }
        'reset'       { return (Get-UiText -Russian 'сброс соединения' -English 'connection reset') }
        'empty'       { return (Get-UiText -Russian 'пустой ответ' -English 'empty reply') }
        'no-response' { return (Get-UiText -Russian 'ответа не было' -English 'no reply') }
        'unknown'     { return (Get-UiText -Russian 'причина неизвестна' -English 'unknown reason') }
        default       { return [string]$Reason }
    }
}

function Get-ProxyEnvNames {
    # Returns proxy-related environment variables that curl would honour.
    # On Windows environment variables are case-insensitive: lower-case
    # aliases resolve to the same variables, so probe canonical names only.
    $names = if ($script:OnWindows) {
        @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')
    } else {
        @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy')
    }
    $found = @()
    foreach ($name in $names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $found += ('{0}={1}' -f $name, $value) }
    }
    return $found
}

function Test-ReachableUrl {
    # Single probe. Returns @{ Url; Ok; Code; Ms }.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSec = 6,
        [string[]]$ProtocolArgs = @(),
        [switch]$UseEnvironmentProxy
    )
    $curl = Get-CurlPath
    if (-not $curl) { throw 'curl not found (Windows 10+ ships curl.exe in System32).' }
    $nullDevice = if ($script:OnWindows) { 'NUL' } else { '/dev/null' }

    $curlArgs = @('-I', '-s', '-m', "$TimeoutSec", '--connect-timeout', "$TimeoutSec",
                  '-o', $nullDevice, '-w', '%{http_code} %{time_total}') + $ProtocolArgs + @($Url)
    try {
        # Direct probes suppress inherited proxy variables (NO_PROXY) so the
        # result reflects the real path to the endpoint. -UseEnvironmentProxy
        # deliberately keeps them for control probes.
        $savedNoProxy = $null
        $overrideProxy = -not $UseEnvironmentProxy
        if ($overrideProxy) {
            $savedNoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY')
            [Environment]::SetEnvironmentVariable('NO_PROXY', '*')
        }
        try {
            $out  = & $curl @curlArgs 2>$null
            $exitCode = [int]$LASTEXITCODE
        } finally {
            if ($overrideProxy) { [Environment]::SetEnvironmentVariable('NO_PROXY', $savedNoProxy) }
        }
        $text = (($out | Out-String)).Trim()
        $m    = [regex]::Match($text, '(\d{3})\s+([\d.]+)')
        if ($m.Success) {
            $code = [int]$m.Groups[1].Value
            $ms   = [Math]::Round(([double]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)) * 1000)
            $ok = Test-DohHttpCodeReachable -Code $code
            return @{ Url = $Url; Ok = $ok; Code = $code; Ms = $ms; Reason = $(if ($ok) { '' } else { Get-CurlFailureReason -ExitCode $exitCode }) }
        }
        return @{ Url = $Url; Ok = $false; Code = 0; Ms = -1; Reason = (Get-CurlFailureReason -ExitCode $exitCode) }
    } catch {
        return @{ Url = $Url; Ok = $false; Code = 0; Ms = -1; Reason = 'unknown' }
    }
}

$script:FreezeTargets = @(
    @{ Name = 'CloudflareSpeed'; Url = 'https://speed.cloudflare.com/__down?bytes=65536' },
    @{ Name = 'HetznerSpeed'; Url = 'https://ash-speed.hetzner.com/1MB.bin' }
)

function Get-FreezeTargets {
    return @($script:FreezeTargets | ForEach-Object { [pscustomobject]$_ })
}

function Test-TransferProbeResult {
    # Pure helper: require the full 64 KB range to rule out 16-20 KB freezes.
    param(
        [int]$StatusCode,
        [long]$BytesReceived,
        [long]$MinimumBytes = 65536,
        [long]$MaximumBytes = 65536
    )
    return ($StatusCode -in @(200,206) -and $BytesReceived -ge $MinimumBytes -and $BytesReceived -le $MaximumBytes)
}

function Test-DataTransferUrl {
    # GET a bounded 64 KB range; unlike HEAD, this proves that the full response
    # continues to flow beyond the common 16-20 KB TCP freeze point.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSec = 6
    )
    $curl = Get-CurlPath
    if (-not $curl) { return @{ Url = $Url; Ok = $false; Code = 0; Bytes = 0; SpeedKBs = 0.0; Ms = -1; Error = 'curl not found' } }
    $nullDevice = if ($script:OnWindows) { 'NUL' } else { '/dev/null' }
    $connectTimeout = [Math]::Min(8, [Math]::Max(1, $TimeoutSec))
    $curlArgs = @('-L','-sS','-m',"$TimeoutSec",'--connect-timeout',"$connectTimeout",'--range','0-65535',
                  '--max-filesize','65536','-o',$nullDevice,'-w','%{http_code} %{size_download} %{speed_download} %{time_total}',$Url)
    try {
        $savedNoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY')
        [Environment]::SetEnvironmentVariable('NO_PROXY', '*')
        try {
            $output = & $curl @curlArgs 2>$null
            $exitCode = [int]$LASTEXITCODE
        } finally {
            [Environment]::SetEnvironmentVariable('NO_PROXY', $savedNoProxy)
        }
        $text = (($output | Out-String)).Trim()
        $m = [regex]::Match($text, '(\d{3})\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)')
        if (-not $m.Success) { return @{ Url = $Url; Ok = $false; Code = 0; Bytes = 0; SpeedKBs = 0.0; Ms = -1; CurlExitCode = $exitCode; Error = ('curl {0}: {1}' -f $exitCode, (Get-CurlFailureReason -ExitCode $exitCode)) } }
        $code = [int]$m.Groups[1].Value
        $bytesValue = [double]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
        $bytes = [long][Math]::Floor($bytesValue)
        $speedBytesPerSecond = [double]::Parse($m.Groups[3].Value, [Globalization.CultureInfo]::InvariantCulture)
        $speedKBs = [Math]::Round(($speedBytesPerSecond / 1024.0), 2)
        $ms = [Math]::Round(([double]::Parse($m.Groups[4].Value, [Globalization.CultureInfo]::InvariantCulture)) * 1000)
        $ok = Test-TransferProbeResult -StatusCode $code -BytesReceived $bytes
        return @{ Url = $Url; Ok = $ok; Code = $code; Bytes = $bytes; SpeedKBs = $speedKBs; Ms = $ms; CurlExitCode = $exitCode; Error = $(if ($ok) { $null } else { 'HTTP error or transfer stopped before 64 KB' }) }
    } catch {
        return @{ Url = $Url; Ok = $false; Code = 0; Bytes = 0; SpeedKBs = 0.0; Ms = -1; CurlExitCode = -1; Error = $_.Exception.Message }
    }
}

function Test-DnsAnswerIsBogus {
    # Pure helper: loopback/zero/broadcast answers always mean a broken or hijacked resolver.
    param([string[]]$Addresses = @())
    foreach ($a in $Addresses) {
        if ([string]$a -match '^(127\.|0\.0\.0\.0$|255\.255\.255\.255$)') { return $true }
    }
    return $false
}

function Get-DohResolvedIps {
    # Resolve a hostname through a DoH JSON endpoint (read-only curl probe).
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [string]$Resolver = 'https://cloudflare-dns.com/dns-query'
    )
    $curl = Get-CurlPath
    if (-not $curl) { return @() }
    try {
        $out = & $curl -sS --noproxy '*' -m 4 '-H' 'accept: application/dns-json' ('{0}?name={1}&type=A' -f $Resolver, $HostName) 2>$null
        $text = (($out | Out-String)).Trim()
        $ips = @()
        foreach ($m in [regex]::Matches($text, '"data"\s*:\s*"(\d{1,3}(?:\.\d{1,3}){3})"')) { $ips += $m.Groups[1].Value }
        return $ips
    } catch { return @() }
}

function Test-DnsMismatchConfirmed {
    # Verify a system-vs-DoH answer mismatch by probing the same hostname pinned
    # to each IP. Poisoning is confirmed only when the system-IP path fails while
    # the DoH-IP path works - plain CDN load-balancing differences stay unflagged.
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$SystemIp,
        [Parameter(Mandatory = $true)][string]$DohIp
    )
    $sysProbe = Test-ReachableUrl -Url ('https://{0}/' -f $HostName) -TimeoutSec 6 -ProtocolArgs @('--resolve', ('{0}:443:{1}' -f $HostName, $SystemIp))
    if ($sysProbe.Ok) { return $false }
    $dohProbe = Test-ReachableUrl -Url ('https://{0}/' -f $HostName) -TimeoutSec 6 -ProtocolArgs @('--resolve', ('{0}:443:{1}' -f $HostName, $DohIp))
    return [bool]($dohProbe.Ok)
}

function Get-BenchmarkDnsHealth {
    # Pre-flight DNS sanity for the benchmark hostnames: unresolvable names,
    # loopback/zero answers, and system-vs-DoH mismatches (poisoning pattern).
    param([string]$DohResolver = 'https://cloudflare-dns.com/dns-query')
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $notes = New-Object 'System.Collections.Generic.List[string]'
    $suspect = $false
    $checked = 0
    $mismatchChecked = $false
    $mismatchPoisoned = $false
    foreach ($t in (Get-BenchmarkTargets)) {
        $url = [string](Get-BenchmarkTargetValue -Target $t -Name 'Url')
        $targetName = [string](Get-BenchmarkTargetValue -Target $t -Name 'Name')
        $hostName = ''
        try { $hostName = ([uri]$url).Host } catch { }
        if (-not $hostName) { continue }
        $checked++
        $systemIps = @()
        try { $systemIps = @([System.Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.ToString() }) } catch { }
        if ($systemIps.Count -eq 0) {
            $issues.Add(('{0}: {1} не резолвится системным DNS' -f $targetName, $hostName))
            $suspect = $true
            continue
        }
        if (Test-DnsAnswerIsBogus -Addresses $systemIps) {
            $issues.Add(('{0}: {1} -> {2} (похоже на подмену DNS)' -f $targetName, $hostName, ($systemIps -join ', ')))
            $suspect = $true
            continue
        }
        $dohIps = @(Get-DohResolvedIps -HostName $hostName -Resolver $DohResolver)
        if ($dohIps.Count -gt 0 -and @($systemIps | Where-Object { $dohIps -contains $_ }).Count -eq 0) {
            if (-not $mismatchChecked) {
                $mismatchChecked = $true
                $sysV4 = @($systemIps | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) | Select-Object -First 1
                $dohV4 = @($dohIps | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }) | Select-Object -First 1
                if ($sysV4 -and $dohV4) {
                    $mismatchPoisoned = (Test-DnsMismatchConfirmed -HostName $hostName -SystemIp ([string]$sysV4) -DohIp ([string]$dohV4))
                }
            }
            if ($mismatchPoisoned) {
                $issues.Add(('{0}: адрес системного DNS ({1}) не отвечает, DoH ({2}) отвечает — DNS подменён' -f $targetName, ($systemIps[0]), ($dohIps[0])))
                $suspect = $true
            } else {
                $notes.Add(('{0}: ответы системного DNS и DoH различаются (обычная CDN-балансировка)' -f $targetName))
            }
        }
    }
    return [pscustomobject]@{ Suspect = $suspect; IssueCount = $issues.Count; Checked = $checked; Issues = @($issues); Notes = @($notes) }
}

function Get-BenchmarkServiceCount {
    # Distinct services across the current benchmark targets (3 since 2.1.27).
    $names = @()
    foreach ($t in (Get-BenchmarkTargets)) { $names += [string](Get-BenchmarkServiceName -Target $t) }
    $distinct = @($names | Where-Object { $_ } | Sort-Object -Unique)
    if ($distinct.Count -eq 0) { return 3 }
    return $distinct.Count
}

function New-BenchmarkFailureResult {
    # Uniform shape for any candidate that could not be benchmarked. Carrier
    # reporting reads AllServicesPassed/ServicesPassed/ServiceCount on every
    # result, so each failure path must expose them or StrictMode aborts the
    # whole scan on the first candidate that failed to start.
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$FreezeChecked = $false,
        [int]$FreezeTotal = 0,
        [string]$StartError = '',
        [int]$StartExitCode = 0
    )
    return [pscustomobject]@{
        Id = $Id; Name = $Name; Passed = 0; TotalMs = [double]::MaxValue
        StartFailed = $true; StartError = $StartError; StartExitCode = $StartExitCode; Targets = @(); SpeedKBs = 0.0
        FreezeChecked = $FreezeChecked; FreezePassed = 0; FreezeTotal = $FreezeTotal
        FreezeOk = $false; FreezeTargets = @()
        ServicesPassed = 0; ServiceCount = (Get-BenchmarkServiceCount); AllServicesPassed = $false; ServiceCoverage = @()
    }
}

function Get-Win32ErrorHint {
    # winws.exe returns the Win32 error of WinDivertOpen as its exit code
    # (nfqws.c: `return w_win32_error`), so the code identifies the failed part.
    param([int]$Code)
    switch ($Code) {
        2 { return 'ERROR_FILE_NOT_FOUND — не найден WinDivert64.sys (удалён антивирусом?)' }
        3 { return 'ERROR_PATH_NOT_FOUND — устаревшая служба драйвера WinDivert' }
        5 { return 'ERROR_ACCESS_DENIED — нет прав администратора или антивирус блокирует WinDivert' }
        34 { return 'ERROR_WRONG_DISK — устаревшая служба драйвера WinDivert (ImagePath ведёт на чужой диск)' }
        53 { return 'ERROR_BAD_NETPATH — устаревшая служба драйвера WinDivert' }
        577 { return 'ERROR_INVALID_IMAGE_HASH — подпись драйвера отклонена (Secure Boot)' }
        654 { return 'ERROR_DRIVER_FAILED_PRIOR_UNLOAD — загружен драйвер WinDivert другой версии (другая копия zapret или обхода)' }
        1056 { return 'ERROR_SERVICE_ALREADY_RUNNING — служба драйвера WinDivert уже выполняется' }
        1058 { return 'ERROR_SERVICE_DISABLED — служба драйвера WinDivert отключена политикой' }
        1072 { return 'ERROR_SERVICE_MARKED_FOR_DELETE — служба WinDivert помечена на удаление; помогает перезагрузка или удаление службы' }
        1114 { return 'ERROR_DLL_INIT_FAILED — WinDivert.dll или драйвер не инициализированы' }
        1275 { return 'ERROR_DRIVER_BLOCKED — антивирус или политика Windows блокирует драйвер WinDivert' }
        177 { return 'код WinDivertOpen 177 (нет имени в winerror.h) — типично плохое состояние службы/драйвера WinDivert или конфликт с другим обходом; служба WinDivert удаляется автоматически' }
        default { return '' }
    }
}

function Test-WinDivertDriverFailure {
    # True when winws died because of the WinDivert driver service, not because
    # of the strategy arguments (those fail with exit code 1 and a parse error).
    param([int]$ExitCode, [string]$StartError)
    if (@(2, 3, 34, 53, 177, 577, 654, 1056, 1058, 1072, 1114, 1275) -contains $ExitCode) { return $true }
    if ($StartError -match 'windivert|win_dark_init|error opening filter|driver') { return $true }
    return $false
}

# Set once per module load: the benchmark repairs the stale WinDivert driver
# service at most once per run. Declared at module scope because StrictMode
# forbids reading a variable that was never assigned.
$script:WinDivertRepairAttempted = $false

function Repair-WinDivertService {
    # A stale WinDivert driver service (left after another zapret install lived
    # on a USB drive or a folder that no longer exists) makes every winws.exe
    # start fail with Win32 errors such as 34 (ERROR_WRONG_DISK) or 3. Deleting
    # the service registration is safe: WinDivert reinstalls the driver next to
    # its own dll on the next start.
    [CmdletBinding()]
    param()
    if (-not $script:OnWindows) { return $false }
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    if (-not (Test-Path -LiteralPath $sc)) { return $false }
    try {
        foreach ($svcName in @('WinDivert', 'WinDivert14')) {
            & $sc stop $svcName 2>$null | Out-Null
            & $sc delete $svcName 2>$null | Out-Null
        }
        Write-Log 'Removed stale WinDivert driver services; winws reinstalls the driver on next start'
        return $true
    } catch {
        return $false
    }
}

function Start-ZapretManualRun {
    # Starts winws.exe manually and verifies it stays alive. On a driver-type
    # failure the stale WinDivert service is repaired and the start retried
    # once. Returns {Started; Pid; ExitCode; Error} instead of silently
    # reporting success for a process that died right away.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Strategy)
    $attempt = 0
    $last = $null
    while ($attempt -lt 2) {
        $attempt++
        $runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $outFile = Join-Path ([IO.Path]::GetTempPath()) ('zapret-winws-{0}.out' -f $runId)
        $errFile = Join-Path ([IO.Path]::GetTempPath()) ('zapret-winws-{0}.err' -f $runId)
        $proc = Start-ZapretStrategy -Strategy $Strategy -Hidden -OutFile $outFile -ErrFile $errFile
        Start-Sleep -Seconds 2
        if ($proc -and -not $proc.HasExited) {
            return [pscustomobject]@{ Started = $true; Pid = [int]$proc.Id; ExitCode = 0; Error = '' }
        }
        $code = 0
        try { if ($proc) { $code = [int]$proc.ExitCode } } catch { }
        $hint = Get-Win32ErrorHint -Code $code
        $captured = Read-WinwsRunOutput -Path $errFile
        if (-not $captured) { $captured = Read-WinwsRunOutput -Path $outFile }
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        $errText = if ($hint) { $hint } else { 'winws.exe завершился сразу после запуска' }
        if ($captured) { $errText = ('{0}; вывод winws: {1}' -f $errText, $captured) }
        $last = [pscustomobject]@{ Started = $false; Pid = 0; ExitCode = $code; Error = $errText }
        if ($attempt -eq 1 -and (Test-WinDivertDriverFailure -ExitCode $code -StartError $errText)) {
            [void](Repair-WinDivertService)
            Start-Sleep -Milliseconds 750
            continue
        }
        break
    }
    return $last
}

function Read-WinwsRunOutput {
    # Tail of a captured winws stream; safe when the file is missing or locked.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    try {
        $text = [IO.File]::ReadAllText($Path).Trim()
        if ($text.Length -gt 1200) { $text = $text.Substring($text.Length - 1200) }
        return $text
    } catch {
        return ''
    }
}

function Get-WinwsStartFailureText {
    # Turns a dead winws process into an actionable reason: exit code (Win32
    # error of WinDivertOpen) plus the output tail where winws prints its real
    # error (the head only carries version/banner lines).
    param($Process, [string]$StdOut, [string]$StdErr)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $exitCode = $null
    try { if ($Process -and $Process.HasExited) { $exitCode = [int]$Process.ExitCode } } catch { }
    if ($null -ne $exitCode) {
        $codeText = 'код выхода: {0}' -f $exitCode
        $hint = Get-Win32ErrorHint -Code $exitCode
        if ($hint) { $codeText += (' ({0})' -f $hint) }
        $parts.Add($codeText)
    }
    $text = ((@($StdOut, $StdErr) | Where-Object { $_ }) -join "`n").Trim()
    if ($text) {
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -le 6) {
            $parts.Add(($lines -join ' | '))
        } else {
            $shown = @($lines[0..1]) + @('…') + @($lines[($lines.Count - 4)..($lines.Count - 1)])
            $parts.Add(($shown -join ' | '))
        }
    }
    if ($parts.Count -eq 0) { return '' }
    return ($parts -join '; ')
}

function Invoke-UrlProbeBatch {
    # Runs several single-URL probes concurrently (curl.exe processes) and
    # returns the same @{ Url; Ok; Code; Ms; Reason } records as Test-ReachableUrl,
    # in input order. Concurrency matches the stock tester (8-16 workers).
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [int]$TimeoutSec = 6,
        [int]$MaxParallel = [Math]::Min(16, [Math]::Max(8, [Environment]::ProcessorCount * 2))
    )
    $curl = Get-CurlPath
    if (-not $curl) { throw 'curl not found (Windows 10+ ships curl.exe in System32).' }
    $nullDevice = if ($script:OnWindows) { 'NUL' } else { '/dev/null' }
    $results = New-Object 'System.Collections.Generic.List[object]'
    if ($Items.Count -eq 0) { return $results.ToArray() }
    $chunkSize = [Math]::Max(1, $MaxParallel)
    for ($offset = 0; $offset -lt $Items.Count; $offset += $chunkSize) {
        $lastIndex = [Math]::Min($offset + $chunkSize - 1, $Items.Count - 1)
        $chunk = @($Items[$offset..$lastIndex])
        $procs = New-Object 'System.Collections.Generic.List[object]'
        $savedNoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY')
        [Environment]::SetEnvironmentVariable('NO_PROXY', '*')
        try {
            foreach ($item in $chunk) {
                $itemUrl = [string]$item['Url']
                $protocolArgs = @()
                if ($item.ContainsKey('ProtocolArgs') -and $item['ProtocolArgs']) { $protocolArgs = @($item['ProtocolArgs']) }
                $curlArgs = @('-I', '-s', '-m', "$TimeoutSec", '--connect-timeout', "$TimeoutSec",
                              '-o', $nullDevice, '-w', '%{http_code} %{time_total}') + $protocolArgs + @($itemUrl)
                # Windows argument string: every token is quoted; quotes and
                # control characters in URLs/flags are refused because a raw
                # double quote would break out of the quoting (CommandLineToArgvW).
                $unsafeToken = $false
                foreach ($token in @($curlArgs)) { if ([string]$token -match '["\x00-\x1F\x7F]') { $unsafeToken = $true; break } }
                if ($unsafeToken) {
                    $results.Add(@{ Url = $itemUrl; Ok = $false; Code = 0; Ms = -1; Reason = 'url contains unsafe characters' })
                    continue
                }
                $argString = (@($curlArgs | ForEach-Object { '"' + [string]$_ + '"' }) -join ' ')
                $startInfo = New-Object System.Diagnostics.ProcessStartInfo
                $startInfo.FileName = $curl
                $startInfo.Arguments = $argString
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $startInfo
                [void]$proc.Start()
                $procs.Add(@{ Proc = $proc; Url = $itemUrl })
            }
        } catch {
            foreach ($entry in $procs) { try { if (-not $entry.Proc.HasExited) { $entry.Proc.Kill() } } catch { } }
            throw
        } finally {
            [Environment]::SetEnvironmentVariable('NO_PROXY', $savedNoProxy)
        }
        foreach ($entry in $procs) {
            $itemUrl = [string]$entry.Url
            $proc = $entry.Proc
            try {
                if (-not $proc.WaitForExit($TimeoutSec * 1000 + 5000)) { try { $proc.Kill() } catch { } }
                $out = ''
                try { $out = $proc.StandardOutput.ReadToEnd() } catch { }
                $exitCode = 0
                try { $exitCode = [int]$proc.ExitCode } catch { }
                $text = (($out | Out-String)).Trim()
                $m = [regex]::Match($text, '(\d{3})\s+([\d.]+)')
                if ($m.Success) {
                    $code = [int]$m.Groups[1].Value
                    $ms = [Math]::Round(([double]::Parse($m.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)) * 1000)
                    $ok = Test-DohHttpCodeReachable -Code $code
                    $results.Add(@{ Url = $itemUrl; Ok = $ok; Code = $code; Ms = $ms; Reason = $(if ($ok) { '' } else { Get-CurlFailureReason -ExitCode $exitCode }) })
                } else {
                    $results.Add(@{ Url = $itemUrl; Ok = $false; Code = 0; Ms = -1; Reason = (Get-CurlFailureReason -ExitCode $exitCode) })
                }
            } catch {
                $results.Add(@{ Url = $itemUrl; Ok = $false; Code = 0; Ms = -1; Reason = 'unknown' })
            } finally {
                try { $proc.Dispose() } catch { }
            }
        }
    }
    return $results.ToArray()
}

function Invoke-BenchmarkStrategy {
    # Starts winws with $Strategy, probes the benchmark targets, stops winws.
    # Returns a result object (also used by tests with a mocked probe).
    param(
        [Parameter(Mandatory = $true)]$Strategy,
        [int]$TimeoutSec = 6,
        [switch]$Deep,
        [switch]$CheckFreeze
    )
    $winws = Join-Path $script:BinDir 'winws.exe'
    if (-not (Test-Path $winws)) { throw "bin\winws.exe was not found. Make sure the archive was fully extracted." }

    [void](Stop-Zapret)
    # Clean environment exactly like the stock tester (utils/test zapret.ps1):
    # every winws.exe from ANY install dies before the probe run. Two WinDivert
    # owners double-process the same flows and the desync breaks mid-probe.
    foreach ($foreignWinws in @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)) {
        $foreignPath = ''
        try { $foreignPath = [string]$foreignWinws.Path } catch { }
        Write-Host (Get-UiText -Russian ('  Останавливаю посторонний winws.exe (PID {0}, {1}) — как эталонный тестер.' -f $foreignWinws.Id, $foreignPath) -English ('  Stopping a foreign winws.exe (PID {0}, {1}) - stock tester protocol.' -f $foreignWinws.Id, $foreignPath)) -ForegroundColor Yellow
        try { Stop-Process -Id $foreignWinws.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    # Stock protocol part two: the .bat configs enable TCP timestamps before
    # every run (service.bat :tcp_enable). Strategies with --dpi-desync-fooling=ts
    # do not work without them.
    if (-not [bool](Get-Variable -Name TcpTimestampsEnsured -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
        $tsState = Enable-ZapretTcpTimestamps
        $script:TcpTimestampsEnsured = $true
        Write-Host (Get-UiText -Russian ('  TCP timestamps: {0} — нужны стратегиям с --dpi-desync-fooling=ts (как в эталонных bat-конфигах).' -f $(if ($tsState) { 'включены' } else { 'НЕ удалось включить' })) -English ('  TCP timestamps: {0} - required by --dpi-desync-fooling=ts strategies (stock bat protocol).' -f $(if ($tsState) { 'enabled' } else { 'FAILED to enable' }))) -ForegroundColor $(if ($tsState) { 'DarkGray' } else { 'Yellow' })
    }
    Start-Sleep -Milliseconds 250

    $argString = Expand-StrategyArgs -Template $Strategy.args
    $proc = $null
    $runId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('zapret-winws-{0}.out' -f $runId)
    $errFile = Join-Path ([IO.Path]::GetTempPath()) ('zapret-winws-{0}.err' -f $runId)
    Get-ChildItem -Path ([IO.Path]::GetTempPath()) -Filter 'zapret-winws-*.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    try {
        # Stock tester protocol (utils/test zapret.ps1): winws gets its own        # minimized console via Start-Process. A console-less CreateNoWindow
        # start leaves winws without a console at all, which changes how it        # initialises - the stock tester never does that and its runs work.
        # Streams are additionally redirected to temp files: when winws dies at
        # startup it prints the real reason ('windivert: error opening filter: ...')
        # to stderr, and those words are the only actionable diagnostic.
        $proc = Start-Process -FilePath $winws -ArgumentList $argString -WorkingDirectory $script:BinDir -PassThru -WindowStyle Minimized -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } catch {
        # Some hosts reject stream redirection; the stock launch must still work.
        try {
            $proc = Start-Process -FilePath $winws -ArgumentList $argString -WorkingDirectory $script:BinDir -PassThru -WindowStyle Minimized
        } catch {
            return (New-BenchmarkFailureResult -Id $Strategy.id -Name $Strategy.name -FreezeChecked ([bool]($Deep -or $CheckFreeze)) -StartError ('winws.exe не стартовал: {0}' -f $_.Exception.Message))
        }
    }

    try {
        # Give WinDivert/winws a moment to install its filter
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $alive = $false
        while ($timer.ElapsedMilliseconds -lt 5000) {
            if ($proc.HasExited) { Start-Sleep -Milliseconds 150; break }
            if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { $alive = $true; Start-Sleep -Milliseconds 300; break }
            Start-Sleep -Milliseconds 200
        }
        if ($proc.HasExited -or -not $alive) {
            $outText = Read-WinwsRunOutput -Path $outFile
            $errText = Read-WinwsRunOutput -Path $errFile
            $exitCode = 0
            try { if ($proc.HasExited) { $exitCode = [int]$proc.ExitCode } } catch { }
            $startError = Get-WinwsStartFailureText -Process $proc -StdOut $outText -StdErr $errText
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
            if ((-not $script:WinDivertRepairAttempted) -and (Test-WinDivertDriverFailure -ExitCode $exitCode -StartError $startError)) {
                $script:WinDivertRepairAttempted = $true
                if (Repair-WinDivertService) {
                    Start-Sleep -Milliseconds 750
                    return (Invoke-BenchmarkStrategy -Strategy $Strategy -TimeoutSec $TimeoutSec -Deep:$Deep -CheckFreeze:$CheckFreeze)
                }
            }
            return (New-BenchmarkFailureResult -Id $Strategy.id -Name $Strategy.name -FreezeChecked ([bool]($Deep -or $CheckFreeze)) -StartError $startError -StartExitCode $exitCode)
        }

        $wallTimer = [Diagnostics.Stopwatch]::StartNew()
        # Fast mode mirrors the stock tester's HTTP column exactly: curl --http1.1.
        # Deep mode adds its TLS1.2 / TLS1.3 columns on top.
        $probes = @(@{ Label = 'HTTP'; Extra = @('--http1.1') })
        if ($Deep) {
            $probes = @(@{ Label = 'HTTP';   Extra = @('--http1.1') },
                        @{ Label = 'TLS1.2'; Extra = @('--tlsv1.2', '--tls-max', '1.2') },
                        @{ Label = 'TLS1.3'; Extra = @('--tlsv1.3', '--tls-max', '1.3') })
        }

        $probeGrid = New-Object 'System.Collections.Generic.List[object]'
        foreach ($t in (Get-BenchmarkTargets)) {
            $gridUrl = [string](Get-BenchmarkTargetValue -Target $t -Name 'Url')
            foreach ($p in $probes) {
                $extra = if ($p -is [hashtable] -and $p.ContainsKey('Extra')) { $p.Extra } else { @() }
                $probeGrid.Add(@{ Url = $gridUrl; ProtocolArgs = $extra })
            }
        }
        # Concurrent probes: a dead endpoint costs one timeout per strategy
        # instead of one timeout per endpoint.
        $batchResults = @(Invoke-UrlProbeBatch -Items $probeGrid.ToArray() -TimeoutSec $TimeoutSec)

        $targetResults = @()
        $passed = 0
        $totalMs = [double]0
        $resultIndex = 0
        foreach ($t in (Get-BenchmarkTargets)) {
            $targetName = [string](Get-BenchmarkTargetValue -Target $t -Name 'Name')
            $oks = 0; $need = $probes.Count; $timeSum = [double]0; $timeCount = 0; $targetReasons = @()
            foreach ($p in $probes) {
                $r = $batchResults[$resultIndex]
                $resultIndex++
                if (-not $r.Ok -and $r.Reason) { $targetReasons += [string]$r.Reason }
                $failReason = if ($r.Ok -or -not $r.Reason) { '' } else { Get-CurlFailureReasonText -Reason ([string]$r.Reason) }
                $probeStatus = if ($r.Code -ge 100) { 'HTTP {0}' -f $r.Code } elseif ($failReason) { Get-UiText -Russian ('нет HTTP-ответа ({0})' -f $failReason) -English ('no HTTP response ({0})' -f $failReason) } else { Get-UiText -Russian 'нет HTTP-ответа' -English 'no HTTP response' }
                $probeColor = if ($r.Ok) { 'Green' } else { 'Red' }
                # One probe = one log record: GUI logs split records per call,
                # so endpoint name and status travel in a single Write-Host.
                Write-Host ('    {0,-22} {1}' -f $targetName, $probeStatus) -ForegroundColor $probeColor
                if ($r.Ok) { $oks++ }
                if ($r.Ms -ge 0) { $timeSum += $r.Ms; $timeCount++ }
            }
            $need2 = [Math]::Ceiling($need / 2.0)   # 1 of 1 in fast mode, >=2 of 3 in deep mode
            $targetOk = ($oks -ge $need2)
            if ($targetOk) { $passed++ }
            if ($timeCount -gt 0) { $totalMs += ($timeSum / $timeCount) }
            $targetResults += [pscustomobject]@{ Name = $targetName; Service = (Get-BenchmarkServiceName -Target $t); Ok = $targetOk; Reason = ($targetReasons | Select-Object -First 1) }
        }
        $serviceSummary = Get-BenchmarkServiceSummary -TargetResults @($targetResults) -Targets @(Get-BenchmarkTargets)

        $freezeChecked = [bool]($Deep -or $CheckFreeze)
        $freezeResults = @()
        $speedSamples = New-Object System.Collections.Generic.List[double]
        $freezePassed = 0
        $freezeTotal = 0
        $freezeOk = $true
        if ($freezeChecked) {
            foreach ($freezeTarget in $script:FreezeTargets) {
                $transfer = Test-DataTransferUrl -Url $freezeTarget.Url -TimeoutSec ([Math]::Max(12, $TimeoutSec * 2))
                if ($transfer.Ok) { $freezePassed++ }
                $freezeTotal++
                if ($transfer.Ms -ge 0) { $totalMs += $transfer.Ms }
                if ($transfer.SpeedKBs -gt 0) { $speedSamples.Add([double]$transfer.SpeedKBs) }
                $freezeResults += [pscustomobject]@{
                    Name = $freezeTarget.Name; Url = $freezeTarget.Url; Ok = [bool]$transfer.Ok
                    Code = $transfer.Code; Bytes = $transfer.Bytes; SpeedKBs = [double]$transfer.SpeedKBs; Ms = $transfer.Ms; Error = $transfer.Error
                }
            }
            # One of two independent transfer hosts is enough to tolerate an
            # unrelated CDN outage; zero means this strategy did not prove data flow.
            $freezeOk = ($freezePassed -ge 1)
        }
        $speedKBs = [double]0
        if ($speedSamples.Count -gt 0) {
            $speedSum = [double]0
            foreach ($sample in $speedSamples) { $speedSum += $sample }
            $speedKBs = [Math]::Round(($speedSum / $speedSamples.Count), 2)
        }

        $wallTimer.Stop()
        return [pscustomobject]@{ Id = $Strategy.id; Name = $Strategy.name; Passed = $passed; TotalMs = [math]::Round($wallTimer.ElapsedMilliseconds); ProbeMsSum = [math]::Round($totalMs);
                                  StartFailed = $false; StartError = ''; StartExitCode = 0; Targets = @($targetResults); SpeedKBs = $speedKBs; FreezeChecked = $freezeChecked;
                                  FreezePassed = $freezePassed; FreezeTotal = $freezeTotal; FreezeOk = $freezeOk;
                                  ServicesPassed = $serviceSummary.PassedServices; ServiceCount = $serviceSummary.TotalServices;
                                  AllServicesPassed = $serviceSummary.AllPassed; ServiceCoverage = @($serviceSummary.Services);
                                  FreezeTargets = @($freezeResults) }
    } finally {
        [void](Stop-Zapret)
        if ($proc -and -not $proc.HasExited) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

function Select-BestStrategy {
    # Ranks benchmark results. Order: startable first, most targets passed,
    # then lowest total probe time. Pure function - unit-testable off Windows.
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Results)
    $ranked = @($Results | Sort-Object `
        @{ Expression = { if ($_.StartFailed) { 0 } else { 1 } }; Descending = $true },
        @{ Expression = { if ($_.PSObject.Properties['FreezeChecked'] -and $_.FreezeChecked -and -not $_.FreezeOk) { 0 } else { 1 } }; Descending = $true },
        @{ Expression = 'Passed';   Descending = $true },
        @{ Expression = { if ($_.PSObject.Properties['SpeedKBs'] -and [double]$_.SpeedKBs -gt 200) { 1 } else { 0 } }; Descending = $true },
        @{ Expression = { if ($_.PSObject.Properties['SpeedKBs']) { [double]$_.SpeedKBs } else { 0.0 } }; Descending = $true },
        @{ Expression = 'TotalMs';  Descending = $false })
    return ,$ranked
}

function Get-AutoSelectConfidence {
    <# Require an identical successful probe set on a second run and meaningful improvement before switching an installed strategy. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [AllowNull()][object]$Verification,
        [AllowNull()][object]$CurrentResult,
        [AllowEmptyString()][string]$CurrentStrategy,
        [switch]$CurrentPresent,
        [switch]$Carrier,
        [switch]$FreezeRequired
    )
    $stable = $true
    $reason = 'repeat verification matched'
    if ($Candidate.StartFailed -or [int]$Candidate.Passed -lt 1) { $stable = $false; $reason = 'candidate did not start or reach any endpoint' }
    if ($null -eq $Verification -or $Verification.StartFailed -or $Verification.Id -ne $Candidate.Id) { $stable = $false; $reason = 'repeat verification failed or tested a different strategy' }
    if ($stable -and $Candidate.PSObject.Properties['Targets'] -and $Verification.PSObject.Properties['Targets']) {
        $firstTargets = @($Candidate.Targets | Where-Object { $_.Ok } | ForEach-Object { [string]$_.Name } | Sort-Object)
        $secondTargets = @($Verification.Targets | Where-Object { $_.Ok } | ForEach-Object { [string]$_.Name } | Sort-Object)
        if (($firstTargets -join '|') -ne ($secondTargets -join '|')) { $stable = $false; $reason = 'the successful endpoint set changed between runs' }
    } elseif ($stable -and [int]$Verification.Passed -ne [int]$Candidate.Passed) {
        $stable = $false; $reason = 'the successful endpoint count changed between runs'
    }
    if ($stable -and $FreezeRequired) {
        if (-not $Candidate.FreezeChecked -or -not $Verification.FreezeChecked -or -not $Candidate.FreezeOk -or -not $Verification.FreezeOk -or [int]$Candidate.FreezePassed -ne [int]$Verification.FreezePassed) {
            $stable = $false; $reason = 'the 64 KB transfer check was not stable'
        } elseif ($Candidate.PSObject.Properties['FreezeTargets'] -and $Verification.PSObject.Properties['FreezeTargets']) {
            $firstTransfers = @($Candidate.FreezeTargets | Where-Object { $_.Ok } | ForEach-Object { [string]$_.Name } | Sort-Object)
            $secondTransfers = @($Verification.FreezeTargets | Where-Object { $_.Ok } | ForEach-Object { [string]$_.Name } | Sort-Object)
            if (($firstTransfers -join '|') -ne ($secondTransfers -join '|')) { $stable = $false; $reason = 'the successful 64 KB transfer endpoints changed between runs' }
        }
    }
    if ($stable -and $Carrier -and (-not $Candidate.AllServicesPassed -or -not $Verification.AllServicesPassed)) {
        $stable = $false; $reason = 'not every required service passed twice'
    }
    if (-not $stable) {
        return [pscustomobject]@{ Stable = $false; MeaningfulImprovement = $false; CanInstall = $false; Decision = 'unstable'; Reason = $reason }
    }
    if ($CurrentStrategy -and $Candidate.Id -eq $CurrentStrategy) {
        return [pscustomobject]@{ Stable = $true; MeaningfulImprovement = $false; CanInstall = $false; Decision = 'keep-current'; Reason = 'the current strategy already won' }
    }
    if (($CurrentPresent -or $CurrentStrategy) -and -not $CurrentResult) {
        return [pscustomobject]@{ Stable = $true; MeaningfulImprovement = $false; CanInstall = $false; Decision = 'unmeasured-current'; Reason = 'current bypass was not measured; comparison is unavailable' }
    }

    $improved = $true
    if ($CurrentResult) {
        $coverageGain = [int]$Candidate.Passed - [int]$CurrentResult.Passed
        $serviceGain = 0
        if ($Candidate.PSObject.Properties['ServicesPassed'] -and $CurrentResult.PSObject.Properties['ServicesPassed']) {
            $serviceGain = [int]$Candidate.ServicesPassed - [int]$CurrentResult.ServicesPassed
        }
        if ($coverageGain -ge 2 -or ($coverageGain -ge 0 -and $serviceGain -ge 1)) {
            $improved = $true
        } elseif ($coverageGain -eq 0 -and $FreezeRequired) {
            $currentSpeed = [double]$CurrentResult.SpeedKBs
            $minimumSpeed = [Math]::Max(($currentSpeed * 1.25), ($currentSpeed + 50.0))
            $improved = ($currentSpeed -gt 0 -and [double]$Candidate.SpeedKBs -ge $minimumSpeed -and [double]$Verification.SpeedKBs -ge $minimumSpeed)
        } else {
            $improved = $false
        }
    }
    if (-not $improved) {
        return [pscustomobject]@{ Stable = $true; MeaningfulImprovement = $false; CanInstall = $false; Decision = 'no-improvement'; Reason = 'no stable coverage gain (or verified 25%+ speed gain) over the current strategy' }
    }
    return [pscustomobject]@{ Stable = $true; MeaningfulImprovement = $true; CanInstall = $true; Decision = 'install'; Reason = 'repeatable result with meaningful improvement' }
}

function Get-AutoSelectRestoreAction {
    # Pure state decision: benchmarking must not start a service that was stopped before the scan.
    [CmdletBinding()]
    param(
        [bool]$ServiceInstalled,
        [AllowNull()][string]$ServiceState,
        [bool]$ProcessWasRunning,
        [AllowNull()][string]$ProcessStrategy
    )
    if ($ServiceInstalled) {
        if ($ServiceState -ieq 'Running') { return 'resume-service' }
        if ($ServiceState -ieq 'Stopped') {
            if ($ProcessWasRunning -and $ProcessStrategy) { return 'resume-manual' }
            if ($ProcessWasRunning) { return 'manual-restart-required' }
            return 'leave-stopped'
        }
        return 'unknown-service-state'
    }
    if ($ProcessWasRunning -and $ProcessStrategy) { return 'resume-manual' }
    if ($ProcessWasRunning) { return 'manual-restart-required' }
    return 'none'
}

function Write-BenchmarkReport {
    param(
        [Parameter(Mandatory = $true)][array]$Ranked,
        [object]$Winner,
        [string]$Carrier,
        [object]$Confidence,
        [object]$Verification,
        [AllowNull()][string]$VerificationError,
        [string]$CurrentStrategy,
        [switch]$CurrentPresent,
        [object]$CurrentResult
    )
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        $path = Join-Path $script:LogDir ("auto-select-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add('zapret-discord-youtube auto-select report')
        [void]$lines.Add((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        if ($CurrentPresent -and -not $CurrentStrategy) {
            [void]$lines.Add('Current baseline: active strategy unresolved - not measured')
        } elseif ($CurrentStrategy) {
            if ($CurrentResult) {
                $baselineState = if ($CurrentResult.StartFailed) { 'start failed' } else { ('{0}/{1} targets; {2:N0} KB/s' -f $CurrentResult.Passed, $script:BenchmarkTargets.Count, [double]$CurrentResult.SpeedKBs) }
                [void]$lines.Add(('Current baseline: {0} - {1}' -f $CurrentStrategy, $baselineState))
            } else {
                [void]$lines.Add(('Current baseline: {0} - not measured' -f $CurrentStrategy))
            }
        } else {
            [void]$lines.Add('Current baseline: none')
        }
        if ($Carrier) {
            $profile = Get-MobileCarrierProfile -Carrier $Carrier
            [void]$lines.Add(('Carrier profile: {0} ({1}) - narrow candidates only' -f $profile.Id, $profile.EnglishName))
        }
        [void]$lines.Add('Targets: ' + (($script:BenchmarkTargets | ForEach-Object { $_.Url }) -join ', '))
        [void]$lines.Add('')
        $rank = 0
        foreach ($r in $Ranked) {
            $rank++
            $state = if ($r.StartFailed) { 'winws failed to start' } else { ('{0}/{1} targets OK, total {2:N0} ms' -f $r.Passed, $script:BenchmarkTargets.Count, $r.TotalMs) }
            if ($r.PSObject.Properties['ServicesPassed']) { $state += ('; services {0}/{1}' -f $r.ServicesPassed, $r.ServiceCount) }
            if ($r.PSObject.Properties['FreezeChecked'] -and $r.FreezeChecked) { $state += ('; TCP transfer {0}/{1} {2}; avg {3:N0} KB/s' -f $r.FreezePassed, $r.FreezeTotal, $(if ($r.FreezeOk) { 'OK' } else { 'FAILED' }), [double]$r.SpeedKBs) }
            [void]$lines.Add(('{0,2}. {1,-18} {2}' -f $rank, $r.Id, $state))
        }
        [void]$lines.Add('')
        [void]$lines.Add('Initial leader: ' + $(if ($Winner) { $Winner.Id } else { '(none)' }))
        if ($Verification) {
            $verificationState = if ($Verification.StartFailed) { 'start failed' } else { ('{0}/{1} endpoints; {2:N0} KB/s' -f $Verification.Passed, $script:BenchmarkTargets.Count, [double]$Verification.SpeedKBs) }
            if ($Verification.PSObject.Properties['FreezeChecked'] -and $Verification.FreezeChecked) { $verificationState += ('; 64 KB {0}/{1}' -f $Verification.FreezePassed, $Verification.FreezeTotal) }
            [void]$lines.Add(('Repeat verification: {0} - {1}' -f $Verification.Id, $verificationState))
        } else {
            [void]$lines.Add('Repeat verification: not run')
            if (-not [string]::IsNullOrWhiteSpace($VerificationError)) {
                $verificationErrorLine = ([string]$VerificationError -replace '[\r\n]+', ' ').Trim()
                if ($verificationErrorLine.Length -gt 500) { $verificationErrorLine = $verificationErrorLine.Substring(0, 500) }
                [void]$lines.Add(('Repeat verification error: {0}' -f $verificationErrorLine))
            }
        }
        $reportRuns = @()
        if ($Winner) { $reportRuns += [pscustomobject]@{ Label = 'candidate'; Result = $Winner } }
        if ($Verification) { $reportRuns += [pscustomobject]@{ Label = 'repeat'; Result = $Verification } }
        if ($CurrentResult) { $reportRuns += [pscustomobject]@{ Label = 'baseline'; Result = $CurrentResult } }
        foreach ($run in $reportRuns) {
            if (-not $run.Result.PSObject.Properties['Targets']) { continue }
            foreach ($target in @($run.Result.Targets)) {
                $targetName = [string](Get-BenchmarkTargetValue -Target $target -Name 'Name')
                $targetOk = [bool](Get-BenchmarkTargetValue -Target $target -Name 'Ok')
                if ($targetName) {
                    $targetReason = [string](Get-BenchmarkTargetValue -Target $target -Name 'Reason')
                    $reasonSuffix = ''
                    if (-not $targetOk -and $targetReason) { $reasonSuffix = ' ({0})' -f (Get-CurlFailureReasonText -Reason $targetReason) }
                    [void]$lines.Add(('Target {0}: {1} {2}{3}' -f $run.Label, $targetName, $(if ($targetOk) { 'OK' } else { 'FAILED' }), $reasonSuffix))
                }
            }
        }
        if ($Confidence) {
            [void]$lines.Add(('Install gate: {0} ({1})' -f $Confidence.Decision, $Confidence.Reason))
        }
        [IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
        return $path
    } catch {
        return $null
    }
}

function Invoke-AutoSelect {
    <#
        Generic mode ranks the full strategy set. -Carrier tests only four
        narrow, app-scoped candidates in an operator-specific order, falls
        through after a failed check, and remembers a fully verified result.
        Windows-only. Stops any running bypass for the duration of the test.
    #>
    param(
        [switch]$Install,   # install the winner without prompting
        [switch]$NoInteractive, # run probes but never prompt/install unless -Install is also supplied
        [switch]$Deep,      # HTTP + TLS1.2 + TLS1.3 + TCP data-transfer probes
        [switch]$CheckFreeze, # verify that HTTPS transfers complete a 64 KB range
        [switch]$Fast,      # test the installed strategy + short list first; stop on a complete pass
        [switch]$Scheduled, # weekly task mode: if the CURRENT bypass passes 100%, exit without touching winws.exe
        [int]$TimeoutSec = 6,
        [ValidateSet('mts','megafon','tele2','yota')][string]$Carrier,
        [switch]$DohRetryUsed
    )

    # Fresh scan = fresh WinDivert repair budget: the user may have rebooted or
    # cleaned the machine between attempts and deserves another self-repair.
    $script:WinDivertRepairAttempted = $false

    if (-not $script:OnWindows) { throw 'auto-select requires Windows: it launches winws.exe against this PC''s network.' }
    if ($Scheduled -and $Carrier) { throw (Get-UiText -Russian 'В расписании нельзя выбрать SIM автоматически. Запустите профиль оператора вручную, подключившись к этой сети.' -English 'A scheduled scan cannot identify the active SIM. Run the carrier profile manually while connected to that network.') }
    Assert-Admin

    # Fresh ZIP installs do not include gitignored user lists. Create them before
    # starting winws; otherwise every strategy exits on missing hostlist/ipset files.
    Initialize-UserLists | Out-Null

    # Slow-link calibration: one live handshake sample sizes the per-endpoint
    # probe budget so narrow/mobile channels are not misread as dead strategies.
    $calibration = Test-ReachableUrl -Url 'https://www.gstatic.com/generate_204' -TimeoutSec 10
    if ($calibration.Ok -and $calibration.Ms -ge 0) {
        $calibratedBudget = 0
        if ($calibration.Ms -gt 4000) { $calibratedBudget = 12 }
        elseif ($calibration.Ms -gt 2500) { $calibratedBudget = 9 }
        elseif ($calibration.Ms -gt 1500) { $calibratedBudget = 7 }
        if ($calibratedBudget -gt $TimeoutSec) {
            $TimeoutSec = $calibratedBudget
            Write-Host (Get-UiText -Russian ('  Канал медленный (калибровка {0} мс) — бюджет адреса увеличен до {1} с.' -f $calibration.Ms, $TimeoutSec) -English ('  Slow link (calibration {0} ms) - per-endpoint budget raised to {1} s.' -f $calibration.Ms, $TimeoutSec)) -ForegroundColor DarkGray
        }
    }

    # Pre-flight health checks: conflicting software and DNS trust. Catching
    # DNS poisoning here saves a full scan that cannot pass anyway.
    $conflicts = $null
    try { $conflicts = Get-ZapretConflictReport } catch { $conflicts = $null }
    $conflictItems = @()
    try {
        if ($null -ne $conflicts -and $conflicts.PSObject.Properties['Items'] -and $null -ne $conflicts.Items) { $conflictItems = @($conflicts.Items) }
    } catch { $conflictItems = @() }
    if ($conflictItems.Count -gt 0) {
        Write-Warn2 (Get-UiText -Russian ('Обнаружены конфликтующие программы: {0}. Они могут мешать обходу — отключите их, если результаты выглядят странно.' -f ($conflictItems -join ', ')) -English ('Conflicting software detected: {0}. It may interfere with the bypass - disable it if results look wrong.' -f ($conflictItems -join ', ')))
        if (-not $NoInteractive -and -not $Scheduled -and $script:OnWindows) {
            $answer = Read-Host (Get-UiText -Russian 'Отключить конфликтующие программы сейчас? Изменение обратимо. [y/N]' -English 'Disable the conflicting programs now? The change is reversible. [y/N]')
            if ($answer -match '^[yY\u0434\u0414]') {
                try {
                    $disableResult = Disable-ZapretConflictPrograms -Report $conflicts
                    $disabledNames = @(@($disableResult.Services) | ForEach-Object { $_.Name })
                    if ($disabledNames.Count -gt 0) { Write-Ok (Get-UiText -Russian ('Отключены службы: {0}' -f ($disabledNames -join ', ')) -English ('Services disabled: {0}' -f ($disabledNames -join ', '))) }
                    if (@($disableResult.Processes).Count -gt 0) { Write-Ok (Get-UiText -Russian ('Завершены процессы: {0}' -f (@($disableResult.Processes) -join ', ')) -English ('Processes stopped: {0}' -f (@($disableResult.Processes) -join ', '))) }
                    foreach ($err in @($disableResult.Failed)) { Write-Warn2 (Get-UiText -Russian ('Не выполнено: {0}' -f $err) -English ('Not done: {0}' -f $err)) }
                    $conflicts = $null
                    try { $conflicts = Get-ZapretConflictReport } catch { $conflicts = $null }
                    $conflictItems = @()
                    try {
                        if ($null -ne $conflicts -and $conflicts.PSObject.Properties['Items'] -and $null -ne $conflicts.Items) { $conflictItems = @($conflicts.Items) }
                    } catch { $conflictItems = @() }
                } catch {
                    Write-Warn2 (Get-UiText -Russian ('Не удалось отключить конфликтующие программы: {0}' -f $_.Exception.Message) -English ('Could not disable the conflicting programs: {0}' -f $_.Exception.Message))
                }
            }
        }
    }
    $script:AutoSelectDnsSuspect = $false
    $script:AutoSelectDnsDetail = ''
    $dnsHealth = Get-BenchmarkDnsHealth
    if ($dnsHealth.Suspect) {
        $script:AutoSelectDnsSuspect = $true
        $script:AutoSelectDnsDetail = ($dnsHealth.Issues -join '; ')
        Write-Warn2 (Get-UiText -Russian ('Проблемы с DNS ({0} из {1} адресов): {2}' -f $dnsHealth.IssueCount, $dnsHealth.Checked, $script:AutoSelectDnsDetail) -English ('DNS problems ({0} of {1} endpoints): {2}' -f $dnsHealth.IssueCount, $dnsHealth.Checked, $script:AutoSelectDnsDetail))
        Write-Info2 (Get-UiText -Russian 'Стратегии не исправляют подмену DNS — сначала включите DoH.' -English 'Strategies cannot fix DNS poisoning - enable DoH first.')
        if (-not $NoInteractive -and -not $Scheduled -and -not $DohRetryUsed -and $script:OnWindows) {
            $answer = Read-Host (Get-UiText -Russian 'Включить DoH (Cloudflare) и повторить подбор? [y/N]' -English 'Enable DoH (Cloudflare) and re-run the scan? [y/N]')
            if ($answer -match '^[yY\u0434\u0414]') {
                try {
                    Enable-Doh -Provider 'cloudflare' | Out-Null
                    Write-Ok (Get-UiText -Russian 'DoH (Cloudflare) включён — повторяю подбор.' -English 'DoH (Cloudflare) enabled - re-running the scan.')
                } catch {
                    Write-Warn2 (Get-UiText -Russian ('Не удалось включить DoH: {0}' -f $_.Exception.Message) -English ('Could not enable DoH: {0}' -f $_.Exception.Message))
                    return $null
                }
                $rerunArgs = @{ Install = $Install; NoInteractive = $NoInteractive; Deep = $Deep; CheckFreeze = $CheckFreeze; Fast = $Fast; Scheduled = $Scheduled; TimeoutSec = $TimeoutSec; DohRetryUsed = $true }
                if ($Carrier) { $rerunArgs['Carrier'] = $Carrier }
                return (Invoke-AutoSelect @rerunArgs)
            }
        }
    }

    if ($Scheduled) {
        # Early exit: the weekly re-check must not bounce winws.exe (and the
        # user's calls/downloads) when everything already works.
        Write-Host ''
        Write-Host (Get-UiText -Russian '  ЕЖЕНЕДЕЛЬНАЯ ПРОВЕРКА: проверяю текущий обход (winws.exe не перезапускается)…' -English '  WEEKLY RE-CHECK: testing the current bypass (winws.exe is not restarted)…') -ForegroundColor Cyan
        $schedInfo = Get-ZapretServiceInfo
        $passedNow = 0
        foreach ($t in $script:BenchmarkTargets) {
            $probe = Test-ReachableUrl -Url $t.Url -TimeoutSec $TimeoutSec
            if ($probe -and $probe.Ok) { $passedNow++ }
        }
        if ($passedNow -eq $script:BenchmarkTargets.Count) {
            Write-Ok ("Current strategy '{0}' passes {1}/{1} targets - keeping it. winws.exe was not restarted." -f $(if ($schedInfo.Strategy) { $schedInfo.Strategy } else { '(unknown)' }), $passedNow)
            Write-Log ("Scheduled re-check: pass ({0}/{1}); nothing changed" -f $passedNow, $script:BenchmarkTargets.Count)
            return $null
        }
        Write-Warn2 ("Current bypass passes only {0}/{1} targets - running the full benchmark..." -f $passedNow, $script:BenchmarkTargets.Count)
    }

    $allAvailable = @(Get-Strategies)
    if ($Carrier) {
        $carrierProfile = Get-MobileCarrierProfile -Carrier $Carrier
        $candidateIds = @($carrierProfile.StrategyOrder)
        $available = @($allAvailable | Where-Object { $candidateIds -contains $_.id })
        $availableIds = @($available | ForEach-Object { $_.id })
        $missingCandidates = @($candidateIds | Where-Object { $_ -notin $availableIds })
        if ($missingCandidates.Count -gt 0) { Write-Warn2 ("Some narrow carrier candidates are missing and will be skipped: {0}" -f ($missingCandidates -join ', ')) }
        if ($available.Count -eq 0) { throw "No narrow strategies found for carrier '$Carrier'. Re-extract the complete archive." }
    } else {
        $available = $allAvailable
    }
    if ($available.Count -eq 0) { throw 'No strategies found (strategies.json is empty).' }

    # Capture enough state to compare and restore the exact pre-scan mode.
    $prevInstalled = $false; $prevStrategy = $null; $prevServiceState = 'NotInstalled'
    $prevWinwsRunning = $false; $prevManualStrategy = $null
    try {
        $info = Get-ZapretServiceInfo
        $prevInstalled = [bool]$info.Installed
        $prevStrategy = [string]$info.Strategy
        $prevServiceState = [string]$info.State
    } catch { }
    if ($prevInstalled -and $prevServiceState -notin @('Running', 'Stopped')) {
        throw ("Cannot safely benchmark while the installed zapret service state is '{0}'. Check diagnostics and retry when the service is Running or Stopped." -f $prevServiceState)
    }
    $prevWinwsRunning = [bool](Get-WinwsProcess | Select-Object -First 1)
    if ($prevWinwsRunning) {
        try { $prevManualStrategy = Get-RunningZapretStrategyId } catch { $prevManualStrategy = $null }
    }
    $currentBaselineRequired = [bool]($prevInstalled -or $prevWinwsRunning)
    $currentInstalled = if ($prevWinwsRunning -and $prevManualStrategy) { $prevManualStrategy } else { $prevStrategy }
    $savedCarrierStrategy = if ($Carrier) { Get-MobileCarrierBestStrategy -Carrier $Carrier } else { $null }
    if ($Carrier) {
        $ordered = Get-BenchmarkOrder -Available $available -CurrentStrategy $currentInstalled -PreferredStrategy $savedCarrierStrategy -Carrier $Carrier -Fast:$Fast
        # A carrier scan is scoped to its four narrow candidates; stop at the first that passes every service and transfer check.
        $fastIds = @($ordered | ForEach-Object { $_.id })
    } else {
        $ordered = Get-BenchmarkOrder -Available $available -CurrentStrategy $currentInstalled -Fast:$Fast
        $fastIds = @(@($currentInstalled, 'general', 'alt', 'fake-tls-auto') | Where-Object { $_ } | Select-Object -Unique)
    }
    $earlyExitDone = $false

    Write-Host ''
    Write-Host (Get-UiText -Russian '  АВТОПОДБОР: ищу подходящую стратегию для этого компьютера' -English '  AUTO-SELECT: finding the best strategy for this PC') -ForegroundColor Cyan
    if ($Carrier) {
        $carrierLabel = Get-UiText -Russian $carrierProfile.RussianName -English $carrierProfile.EnglishName
        Write-Host (Get-UiText -Russian ('  Профиль оператора: {0}. Проверяю только 4 узкие стратегии для заданных приложений.' -f $carrierLabel) -English ('  Carrier profile: {0}. Testing only the 4 narrowly scoped strategies for the selected apps.' -f $carrierLabel)) -ForegroundColor Cyan
        Write-Host (Get-UiText -Russian '  Убедитесь, что сейчас подключены именно к этому оператору (например, через USB-модем или точку доступа).' -English '  Make sure this PC is currently connected through the selected carrier (for example, tethering or a hotspot).') -ForegroundColor DarkGray
    }
    Write-Host (Get-UiText -Russian ('  Проверочные адреса: {0}' -f (($script:BenchmarkTargets | ForEach-Object { $_.Url }) -join ', ')) -English ('  Test endpoints: {0}' -f (($script:BenchmarkTargets | ForEach-Object { $_.Url }) -join ', '))) -ForegroundColor DarkGray
    $proxyEnv = @(Get-ProxyEnvNames)
    if ($proxyEnv.Count -gt 0) {
        Write-Warn2 (Get-UiText -Russian ('  В окружении заданы прокси-переменные: {0}. Все пробы здесь идут НАПРЯМУЮ (мимо прокси). Утилиты, учитывающие прокси (например, оригинальный тестер zapret), могут показывать ложный успех.' -f ($proxyEnv -join '; ')) -English ('  Proxy environment variables are set: {0}. Every probe here goes DIRECT (bypassing the proxy). Tools that honour the proxy (for example the stock zapret tester) may report false success.' -f ($proxyEnv -join '; ')))
        $directProbe = Test-ReachableUrl -Url 'https://discord.com' -TimeoutSec 4
        $proxiedProbe = Test-ReachableUrl -Url 'https://discord.com' -TimeoutSec 4 -UseEnvironmentProxy
        Write-Host (Get-UiText -Russian ('  Контрольная проба discord.com — напрямую: {0}; через прокси окружения: {1}.' -f $(if ($directProbe.Ok) { 'ОТВЕЧАЕТ' } else { 'нет ответа' }), $(if ($proxiedProbe.Ok) { 'ОТВЕЧАЕТ' } else { 'нет ответа' })) -English ('  Control probe discord.com - direct: {0}; via environment proxy: {1}.' -f $(if ($directProbe.Ok) { 'RESPONDS' } else { 'no response' }), $(if ($proxiedProbe.Ok) { 'RESPONDS' } else { 'no response' }))) -ForegroundColor Yellow
    }
    $freezeRequired = [bool]($CheckFreeze -or $Deep -or $Carrier)
    if ($freezeRequired) { Write-Host (Get-UiText -Russian '  Проверка передачи данных: хотя бы один из двух HTTPS-серверов должен отдать все 64 КБ.' -English '  Transfer check: at least one of two independent HTTPS endpoints must deliver the full 64 KB.') -ForegroundColor DarkGray }
    if ($Fast -and $Carrier) {
        Write-Host (Get-UiText -Russian '  Быстрый режим: пробую стратегии по порядку; при провале автоматически перехожу к следующей. Если все 4 не пройдут, ничего нового не установлю.' -English '  Fast mode: try candidates in order and automatically fall back to the next. If all four fail, nothing new will be installed.') -ForegroundColor DarkGray
    } elseif ($Fast) {
        Write-Host (Get-UiText -Russian '  Быстрый режим: сначала проверю текущую стратегию, затем general, alt и fake-tls-auto; остановлюсь на первой успешной.' -English '  Fast mode: test the current strategy, then general, alt, and fake-tls-auto; stop at the first one that passes every check.') -ForegroundColor DarkGray
    }
    Write-Host (Get-UiText -Russian ("  На каждый адрес отведено до {0} с. Ниже будут показаны ход проверки и HTTP-ответ. Если новую стратегию не применяю, восстанавливаю прежний режим; нераспознанный ручной запуск потребует перезапуска по показанной команде." -f $TimeoutSec) -English ("  Each endpoint has up to {0} seconds. Progress and HTTP status appear below. If no new strategy is applied, the previous mode is restored; an unrecognized manual run may need the command shown below." -f $TimeoutSec)) -ForegroundColor DarkGray
    Write-Host ''

    $results = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($s in $ordered) {
        $n++
        Write-Host ('  [{0,2}/{1}] {2,-18}' -f $n, $ordered.Count, $s.id)
        try {
            $r = Invoke-BenchmarkStrategy -Strategy $s -TimeoutSec $TimeoutSec -Deep:$Deep -CheckFreeze:$freezeRequired
        } catch {
            Write-Warn2 ("Could not test strategy '{0}': {1}" -f $s.id, $_.Exception.Message)
            $r = New-BenchmarkFailureResult -Id $s.id -Name $s.name -FreezeChecked $freezeRequired -FreezeTotal $(if ($freezeRequired) { $script:FreezeTargets.Count } else { 0 })
        }
        $results.Add($r)
        if ($r.StartFailed) {
            Write-Host (Get-UiText -Russian 'Не удалось запустить winws.exe.' -English 'Could not start winws.exe.') -ForegroundColor Red
            $startErrorText = if ($r.PSObject.Properties['StartError'] -and $r.StartError) { [string]$r.StartError } else { '' }
            if ($startErrorText) {
                Write-Host (Get-UiText -Russian ('  Причина: {0}' -f $startErrorText) -English ('  Reason: {0}' -f $startErrorText)) -ForegroundColor Yellow
            } else {
                Write-Host (Get-UiText -Russian '  Частые причины: антивирус удалил bin\winws.exe, конфликт WinDivert с другими обходами, нет прав администратора.' -English '  Common causes: antivirus removed bin\winws.exe, a WinDivert conflict with other bypass tools, missing administrator rights.') -ForegroundColor DarkGray
            }
        } else {
            $color = if (($Carrier -and $r.AllServicesPassed -and $r.FreezeOk) -or (-not $Carrier -and $r.Passed -ge 4 -and $r.FreezeOk)) { 'Green' } elseif ($r.Passed -ge 2) { 'Yellow' } else { 'Red' }
            $freezeSummary = if ($r.FreezeChecked) { Get-UiText -Russian ('; проверка 64 КБ: {0}/{1}, скорость {2:N0} КБ/с' -f $r.FreezePassed, $r.FreezeTotal, $r.SpeedKBs) -English ('; 64 KB transfer: {0}/{1}, speed {2:N0} KB/s' -f $r.FreezePassed, $r.FreezeTotal, $r.SpeedKBs) } else { '' }
            $serviceSummaryText = if ($Carrier) { Get-UiText -Russian ('; сервисы: {0}/{1}' -f $r.ServicesPassed, $r.ServiceCount) -English ('; services: {0}/{1}' -f $r.ServicesPassed, $r.ServiceCount) } else { '' }
            Write-Host (Get-UiText -Russian ('Доступно адресов: {0} из {1}{2}{3} (время: {4:N0} мс)' -f $r.Passed, $script:BenchmarkTargets.Count, $serviceSummaryText, $freezeSummary, $r.TotalMs) -English ('{0}/{1} endpoints reachable{2}{3} ({4:N0} ms total)' -f $r.Passed, $script:BenchmarkTargets.Count, $serviceSummaryText, $freezeSummary, $r.TotalMs)) -ForegroundColor $color
        }
        $coveragePassed = if ($Carrier) { [bool]$r.AllServicesPassed } else { ($r.Passed -eq $script:BenchmarkTargets.Count) }
        if ($Fast -and -not $r.StartFailed -and $coveragePassed -and (-not $freezeRequired -or $r.FreezeOk) -and ($fastIds -contains $s.id)) {
            Write-Host ''
            Write-Host (Get-UiText -Russian ("  Стратегия '{0}' прошла все проверки — останавливаю быстрый подбор." -f $s.id) -English ("  Strategy '{0}' passed every check — stopping the fast search." -f $s.id)) -ForegroundColor Green
            $earlyExitDone = $true
            break
        }
    }
    if ($Fast -and -not $earlyExitDone) {
        if ($Carrier) { Write-Info2 'Fast carrier scan: no narrow candidate passed all three service checks and the transfer test; reviewing the four results.' }
        else { Write-Info2 'Fast mode: no 100% candidate among installed/general/alt/fake-tls-auto - full ranking is used.' }
    }

    if (-not $earlyExitDone) {
        $endpointReasons = @()
        foreach ($res in $results) {
            foreach ($t in @($res.Targets)) {
                if ($t -and $t.PSObject.Properties['Reason'] -and $t.Reason) { $endpointReasons += [string]$t.Reason }
            }
        }
        if ($endpointReasons.Count -gt 0) {
            $failTotal = [Math]::Max(1, $endpointReasons.Count)
            $dnsCount = @($endpointReasons | Where-Object { $_ -eq 'dns' }).Count
            $timeoutCount = @($endpointReasons | Where-Object { $_ -eq 'timeout' }).Count
            $resetCount = @($endpointReasons | Where-Object { $_ -in 'reset','refused','empty' }).Count
            if ($dnsCount -gt 0 -and $dnsCount -ge [Math]::Max($timeoutCount, $resetCount)) {
                Write-Info2 (Get-UiText -Russian ('DNS не резолвит проверочные адреса ({0} из {1}). Включите DoH: zapret.ps1 dns doh cloudflare (меню DNS) и повторите подбор.' -f $dnsCount, $failTotal) -English ('DNS fails to resolve test endpoints ({0} of {1}). Enable DoH: zapret.ps1 dns doh cloudflare (DNS menu) and re-run the scan.' -f $dnsCount, $failTotal))
            } elseif ($timeoutCount -gt 0 -and $timeoutCount -ge $resetCount) {
                Write-Info2 (Get-UiText -Russian ('Адреса не ответили за отведённое время ({0} из {1}). Канал медленный или частично недоступен: повторите при лучшей связи; если подозреваете DNS, включите DoH (zapret.ps1 dns doh cloudflare).' -f $timeoutCount, $failTotal) -English ('Endpoints timed out ({0} of {1}). The link is slow or partially unreachable: retry with better signal; if DNS looks suspect, enable DoH (zapret.ps1 dns doh cloudflare).' -f $timeoutCount, $failTotal))
            } elseif ($resetCount -gt 0) {
                Write-Info2 (Get-UiText -Russian ('Соединения с этими адресами сбрасывались ({0} из {1}). Похоже, DPI активно блокирует трафик: попробуйте обычный подбор, другие fakes (Replace Active Fakes) или другой профиль.' -f $resetCount, $failTotal) -English ('Connections to these endpoints were cut ({0} of {1}). DPI is likely interfering: try the regular scan, other fakes (Replace Active Fakes), or a different carrier profile.' -f $resetCount, $failTotal))
            }
            if ($dnsCount -gt 0 -and $dnsCount -ge [Math]::Max($timeoutCount, $resetCount) -and -not $NoInteractive -and -not $Scheduled -and -not $DohRetryUsed -and $script:OnWindows) {
                $answer = Read-Host (Get-UiText -Russian 'Включить DoH (Cloudflare) и повторить подбор? [y/N]' -English 'Enable DoH (Cloudflare) and re-run the scan? [y/N]')
                if ($answer -match '^[yY\u0434\u0414]') {
                    try {
                        Enable-Doh -Provider 'cloudflare' | Out-Null
                        Write-Ok (Get-UiText -Russian 'DoH (Cloudflare) включён — повторяю подбор.' -English 'DoH (Cloudflare) enabled - re-running the scan.')
                    } catch {
                        Write-Warn2 (Get-UiText -Russian ('Не удалось включить DoH: {0}' -f $_.Exception.Message) -English ('Could not enable DoH: {0}' -f $_.Exception.Message))
                        return $null
                    }
                    $rerunArgs = @{ Install = $Install; NoInteractive = $NoInteractive; Deep = $Deep; CheckFreeze = $CheckFreeze; Fast = $Fast; Scheduled = $Scheduled; TimeoutSec = $TimeoutSec; DohRetryUsed = $true }
                    if ($Carrier) { $rerunArgs['Carrier'] = $Carrier }
                    return (Invoke-AutoSelect @rerunArgs)
                }
            }
        }
    }

    $ranked = Select-BestStrategy -Results @($results.ToArray())
    $winner = $ranked | Select-Object -First 1
    $freezeCandidates = @($ranked | Where-Object { -not $_.StartFailed -and (-not $_.PSObject.Properties['FreezeChecked'] -or -not $_.FreezeChecked -or $_.FreezeOk) })
    $noFreezeCandidate = ($freezeRequired -and $freezeCandidates.Count -eq 0)
    $noCarrierCandidate = [bool]($Carrier -and -not $winner.AllServicesPassed)

    Write-Host ''
    Write-Host (Get-UiText -Russian '  РЕЗУЛЬТАТЫ' -English '  RANKING') -ForegroundColor Cyan
    Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
    $rank = 0
    foreach ($r in $ranked) {
        $rank++
        $mark = if ($rank -eq 1) { '*' } else { ' ' }
        if ($r.StartFailed) {
            $uiState = Get-UiText -Russian 'winws.exe не запустился' -English 'winws.exe failed to start'
        } else {
            $uiState = Get-UiText -Russian ('доступно: {0}/{1}, время: {2:N0} мс' -f $r.Passed, $script:BenchmarkTargets.Count, $r.TotalMs) -English ('{0}/{1} reachable, {2:N0} ms' -f $r.Passed, $script:BenchmarkTargets.Count, $r.TotalMs)
            if ($r.PSObject.Properties['FreezeChecked'] -and $r.FreezeChecked) {
                $freezeResult = if ($r.FreezeOk) { Get-UiText -Russian 'передача данных пройдена' -English 'transfer passed' } else { Get-UiText -Russian 'обнаружена остановка передачи' -English 'transfer stalled' }
                $uiState += Get-UiText -Russian ('; 64 КБ: {0}/{1}, {2}, {3:N0} КБ/с' -f $r.FreezePassed, $r.FreezeTotal, $freezeResult, [double]$r.SpeedKBs) -English ('; 64 KB: {0}/{1}, {2}, {3:N0} KB/s' -f $r.FreezePassed, $r.FreezeTotal, $freezeResult, [double]$r.SpeedKBs)
            }
        }
        Write-Host ('   {0}{1,2}. {2,-18} {3}' -f $mark, $rank, $r.Id, $uiState)
    }
    Write-Host ''

    if (-not $winner) {
        Write-Fail 'Benchmark produced no results.'
        return $null
    }

    if ($noCarrierCandidate) {
        Write-Fail (Get-UiText -Russian 'Ни один из 4 узких вариантов не подтвердил доступность всех трёх сервисов. Не устанавливаю непроверенный вариант.' -English 'None of the 4 narrow candidates reached all three services. I will not install an unverified option.')
        Write-Info2 (Get-UiText -Russian 'Проверьте подключение к выбранной SIM, DNS и результаты диагностики. Для более широкого перебора запустите обычный пункт «Автоподбор стратегии».' -English 'Check the selected SIM connection, DNS, and diagnostics. To try the broader strategy set, run the standard Auto-Select option.')
    } elseif ($noFreezeCandidate) {
        Write-Fail 'No strategy completed the full 64 KB TCP data-transfer check. The current/previous bypass will be restored; no candidate will be installed.'
        Write-Info2 'Check the connection to the test CDNs and the DPI-checker result; run "zapret.ps1 diagnostics".'
    } elseif ($winner.StartFailed -or $winner.Passed -eq 0) {
        Write-Fail 'No strategy could reach the requested service endpoints from this PC.'
        if ((-not [bool]$winner.StartFailed) -and $winner.PSObject.Properties['FreezeChecked'] -and $winner.FreezeChecked -and $winner.PSObject.Properties['FreezePassed'] -and ([int]$winner.FreezePassed -gt 0)) {
            Write-Info2 (Get-UiText -Russian 'Передача 64 КБ при этом прошла — канал живой, а таймауты адресов сервисов похожи на блокировку по SNI. Попробуйте другие fakes или полный набор стратегий.' -English 'The 64 KB transfer passed - the link is alive, so endpoint timeouts look like SNI-based blocking. Try other fakes or the full strategy set.')
        }
        Write-Info2 'Check your internet connection and DNS (enable DoH), and run "zapret.ps1 diagnostics".'
    } else {
        if ($Carrier) {
            $carrierLabel = Get-UiText -Russian $carrierProfile.RussianName -English $carrierProfile.EnglishName
            Write-Info2 (Get-UiText -Russian ("Предварительный лидер для {0}: {1} ({2}/{3} адресов). Повторная проверка обязательна; до неё профиль не сохраняется и не устанавливается." -f $carrierLabel, $winner.Id, $winner.Passed, $script:BenchmarkTargets.Count) -English ("Initial leader for {0}: {1} ({2}/{3} endpoints). A repeat check is required; nothing is saved or installed before it passes." -f $carrierLabel, $winner.Id, $winner.Passed, $script:BenchmarkTargets.Count))
        } else {
            Write-Info2 ("Initial benchmark leader: {0} ({1}/{2} targets OK); repeat verification is required before installation." -f $winner.Id, $winner.Passed, $script:BenchmarkTargets.Count)
        }
    }

    $currentResult = $null
    if ($currentInstalled) {
        $currentMatch = @($results.ToArray() | Where-Object { $_.Id -eq $currentInstalled } | Select-Object -First 1)
        if ($currentMatch.Count -gt 0) {
            $currentResult = $currentMatch[0]
        } elseif (-not $noCarrierCandidate -and -not $noFreezeCandidate -and -not $winner.StartFailed -and [int]$winner.Passed -gt 0) {
            # A narrow carrier scan may omit the installed general strategy (or
            # Fast mode may stop before it). Measure it separately as a baseline;
            # never treat an unmeasured installed strategy as if none were active.
            $currentStrategyObject = @($allAvailable | Where-Object { $_.id -eq $currentInstalled } | Select-Object -First 1)
            if ($currentStrategyObject.Count -gt 0) {
                Write-Info2 ("Testing installed strategy '{0}' as the comparison baseline..." -f $currentInstalled)
                try {
                    $currentResult = Invoke-BenchmarkStrategy -Strategy $currentStrategyObject[0] -TimeoutSec $TimeoutSec -Deep:$Deep -CheckFreeze:$freezeRequired
                    if ($currentResult.StartFailed) { Write-Warn2 ("Installed strategy '{0}' could not start for comparison." -f $currentInstalled) }
                    else { Write-Info2 ("Current baseline: {0}/{1} endpoints, {2:N0} KB/s." -f $currentResult.Passed, $script:BenchmarkTargets.Count, [double]$currentResult.SpeedKBs) }
                } catch {
                    Write-Warn2 ("Could not test installed strategy '{0}' as a baseline: {1}" -f $currentInstalled, $_.Exception.Message)
                    $currentResult = $null
                }
            } else {
                Write-Warn2 ("Installed strategy '{0}' is not in the available strategy set; the install gate will stay closed without a measured baseline." -f $currentInstalled)
            }
        }
    }
    $verification = $null
    $verificationError = $null
    $confidence = [pscustomobject]@{ Stable = $false; MeaningfulImprovement = $false; CanInstall = $false; Decision = 'unverified'; Reason = 'candidate was not rechecked' }
    if (-not $noCarrierCandidate -and -not $noFreezeCandidate -and -not $winner.StartFailed -and [int]$winner.Passed -gt 0) {
        Write-Info2 ("Rechecking the leading strategy '{0}' before any installation..." -f $winner.Id)
        $winnerStrategy = Get-BenchmarkStrategyById -Strategies $allAvailable -Id ([string]$winner.Id)
        if (-not $winnerStrategy) {
            $verificationError = "Could not find strategy definition '$($winner.Id)' in the available strategy list."
            Write-Warn2 $verificationError
        } else {
            try { $verification = Invoke-BenchmarkStrategy -Strategy $winnerStrategy -TimeoutSec $TimeoutSec -Deep:$Deep -CheckFreeze:$freezeRequired }
            catch {
                $verificationError = $_.Exception.Message
                Write-Warn2 ("Repeat verification failed: {0}" -f $verificationError)
            }
        }
        $confidence = Get-AutoSelectConfidence -Candidate $winner -Verification $verification -CurrentResult $currentResult -CurrentStrategy $currentInstalled -CurrentPresent:$currentBaselineRequired -Carrier:([bool]$Carrier) -FreezeRequired:$freezeRequired
        if ($confidence.CanInstall) {
            Write-Ok ("Repeat check passed and the result improves coverage; install gate open ({0})." -f $confidence.Reason)
        } else {
            Write-Warn2 ("Keeping the current setup; automatic install blocked: {0}." -f $confidence.Reason)
        }
    } else {
        $confidence = Get-AutoSelectConfidence -Candidate $winner -Verification $null -CurrentResult $currentResult -CurrentStrategy $currentInstalled -CurrentPresent:$currentBaselineRequired -Carrier:([bool]$Carrier) -FreezeRequired:$freezeRequired
        Write-Warn2 ("Automatic install blocked: {0}." -f $confidence.Reason)
    }
    $winner | Add-Member -MemberType NoteProperty -Name AutoSelectConfidence -Value $confidence -Force
    # Strategy fallback ladder: remember the verified order so the watchdog can
    # fail over to a known-good candidate in seconds before the deep re-benchmark.
    try {
        if ($winner -and -not $winner.StartFailed -and [int]$winner.Passed -gt 0) {
            $ladderIds = New-Object 'System.Collections.Generic.List[string]'
            [void]$ladderIds.Add([string]$winner.Id)
            foreach ($cand in @($ranked | Where-Object { $_ -ne $winner -and -not $_.StartFailed -and [int]$_.Passed -gt 0 })) {
                if ($ladderIds.Count -ge 5) { break }
                $cid = [string]$cand.Id
                if (-not $ladderIds.Contains($cid)) { [void]$ladderIds.Add($cid) }
            }
            [void](Save-StrategyFallbackLadder -CandidateIds $ladderIds.ToArray() -WinnerId ([string]$winner.Id))
        }
    } catch { Write-Log ("Fallback ladder save failed: {0}" -f $_.Exception.Message) 'WARN' }
    if ($Carrier -and $confidence.Stable -and ($confidence.CanInstall -or $confidence.Decision -eq 'keep-current')) {
        try {
            [void](Set-MobileCarrierBestStrategy -Carrier $Carrier -StrategyId $winner.Id)
            Write-Info2 (Get-UiText -Russian 'Сохранил только повторно проверенный профиль для выбранного оператора.' -English 'Saved only the repeat-verified profile for the selected carrier.')
        } catch { Write-Warn2 ("Could not save the carrier profile: {0}" -f $_.Exception.Message) }
    }
    $report = Write-BenchmarkReport -Ranked $ranked -Winner $winner -Carrier $Carrier -Confidence $confidence -Verification $verification -VerificationError $verificationError -CurrentStrategy $currentInstalled -CurrentPresent:$currentBaselineRequired -CurrentResult $currentResult
    if ($report) { Write-Info2 "Report saved to $report" }

    # Read-Host throws or returns $null when stdin is not a console; treat that as "no"
    $safeRead = {
        param([string]$Prompt)
        try { return (Read-Host $Prompt) } catch { return $null }
    }

    $doInstall = $false
    if ($noCarrierCandidate -or $noFreezeCandidate -or -not $confidence.CanInstall) {
        $doInstall = $false
    } elseif ($Install) {
        $doInstall = (-not $winner.StartFailed)
    } elseif ($NoInteractive) {
        $doInstall = $false
    } else {
        if ($winner.Passed -gt 0) {
            if ($Carrier) {
                $carrierLabel = Get-UiText -Russian $carrierProfile.RussianName -English $carrierProfile.EnglishName
                $prompt = Get-UiText -Russian ("   Установить проверенный вариант для {0} как службу автозапуска? [д/н]" -f $carrierLabel) -English ("   Install the tested {0} option as the startup service? [Y/n]" -f $carrierLabel)
            } else {
                $prompt = Get-UiText -Russian '   Установить эту стратегию как службу автозапуска? [д/н]' -English '   Install this strategy as the startup service? [Y/n]'
            }
            $answer = & $safeRead $prompt
            $doInstall = ([string]::IsNullOrWhiteSpace($answer)) -or ($answer.Trim() -match '^(y|yes|д|да)$')
        } else {
            $answer = & $safeRead (Get-UiText -Russian '   Установить эту стратегию, хотя не все проверки прошли? [д/н]' -English '   Install this strategy even though some checks failed? [y/N]')
            $doInstall = (-not [string]::IsNullOrWhiteSpace($answer)) -and ($answer.Trim() -match '^(y|yes|д|да)$')
        }
    }

    if ($doInstall) {
        Install-ZapretService -StrategyId $winner.Id | Out-Null
        Invoke-PostInstallConfiguration -Ask:(-not $Install)
    } else {
        $restoreAction = Get-AutoSelectRestoreAction -ServiceInstalled:$prevInstalled -ServiceState $prevServiceState -ProcessWasRunning:$prevWinwsRunning -ProcessStrategy $prevManualStrategy
        switch ($restoreAction) {
            'resume-service' {
                Write-Info2 ("Restoring the previously running zapret service (strategy: {0})..." -f $prevStrategy)
                try {
                    $serviceState = [string](Get-Service -Name 'zapret' -ErrorAction Stop).Status
                    if ($serviceState -ne 'Running') { Start-Service -Name 'zapret' -ErrorAction Stop }
                    $deadline = [DateTime]::UtcNow.AddSeconds(12)
                    do {
                        $serviceState = [string](Get-Service -Name 'zapret' -ErrorAction Stop).Status
                        if ($serviceState -eq 'Running') { break }
                        Start-Sleep -Milliseconds 200
                    } while ([DateTime]::UtcNow -lt $deadline)
                    if ($serviceState -ne 'Running') { throw 'Service did not reach the Running state.' }
                    Write-Ok 'Previous zapret service resumed.'
                } catch {
                    Write-Warn2 ("Could not resume the previous service: {0}. You can retry with Start-Service zapret." -f $_.Exception.Message)
                }
            }
            'leave-stopped' { Write-Info2 'The zapret service was stopped before the benchmark and remains stopped.' }
            'resume-manual' {
                $manualStrategy = Get-Strategy -Id $prevManualStrategy
                if ($manualStrategy) {
                    try {
                        Start-ZapretStrategy -Strategy $manualStrategy -Hidden | Out-Null
                        Write-Ok ("Previously running manual strategy '{0}' resumed." -f $prevManualStrategy)
                    } catch {
                        Write-Warn2 ("Could not resume the previous manual strategy: {0}. Start it with: zapret.ps1 run {1}" -f $_.Exception.Message, $prevManualStrategy)
                    }
                } else {
                    Write-Info2 "The previously running manual winws could not be identified. Restart it with: zapret.ps1 run <strategy>"
                }
            }
            'manual-restart-required' { Write-Info2 'The previous manually started winws could not be identified. Restart it with: zapret.ps1 run <strategy>.' }
            'unknown-service-state' { Write-Warn2 'The previous service state could not be restored safely; check zapret diagnostics.' }
            default { Write-Info2 'No changes were applied.' }
        }
    }
    if ($null -ne $winner) {
        $winner | Add-Member -NotePropertyName DnsSuspect -NotePropertyValue ([bool]$script:AutoSelectDnsSuspect) -Force
        $winner | Add-Member -NotePropertyName DnsDetail -NotePropertyValue ([string]$script:AutoSelectDnsDetail) -Force
        $winner | Add-Member -NotePropertyName Conflicts -NotePropertyValue (@($conflictItems)) -Force
    }
    return $winner
}

function Get-AutoSetupApplyAction {
    # Pure consent gate used by the guided setup; empty input is never consent.
    [CmdletBinding()]
    param(
        [bool]$CandidateUsable,
        [bool]$Install,
        [bool]$NoInteractive,
        [bool]$AnswerProvided,
        [AllowNull()][AllowEmptyString()][string]$Answer
    )
    if (-not $CandidateUsable) { return 'skip' }
    if ($Install) { return 'install' }
    if ($NoInteractive) { return 'skip' }
    if (-not $AnswerProvided) { return 'prompt' }
    if ($Answer -and $Answer.Trim() -match '^(?i:y|yes|д|да)$') { return 'install' }
    return 'skip'
}

function Resolve-AutoSetupConnectionTypeChoice {
    # Pure parser for the unified Auto-Setup connection prompt.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Answer)
    switch (([string]$Answer).Trim()) {
        '1' { return 'regular' }
        '2' { return 'mobile' }
        '0' { return 'cancel' }
        default { return $null }
    }
}

function Resolve-AutoSetupCarrierChoice {
    # Pure parser for the operator submenu; numbers follow Get-MobileCarrierProfiles.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Answer)
    $choice = ([string]$Answer).Trim().ToLowerInvariant()
    if (-not $choice) { return $null }
    $profiles = @(Get-MobileCarrierProfiles)
    if ($choice -match '^[1-4]$') {
        $index = [int]$choice - 1
        if ($index -lt $profiles.Count) { return [string]$profiles[$index].Id }
        return $null
    }
    $profile = @($profiles | Where-Object { $_.Id -eq $choice } | Select-Object -First 1)
    if ($profile.Count -gt 0) { return [string]$profile[0].Id }
    return $null
}

function Get-AutoSetupScheduleAction {
    # Pure gate for the optional weekly task: never enable it without a matching installed strategy.
    [CmdletBinding()]
    param(
        [bool]$ServiceInstalled,
        [bool]$StrategyMatches,
        [bool]$ScheduleExists,
        [bool]$EnableSchedule,
        [bool]$Install,
        [bool]$NoInteractive,
        [bool]$AnswerProvided,
        [AllowNull()][AllowEmptyString()][string]$Answer
    )
    if (-not $ServiceInstalled -or -not $StrategyMatches) { return 'skip' }
    if ($ScheduleExists) { return 'already-enabled' }
    if ($EnableSchedule) { return 'enable' }
    if ($Install -or $NoInteractive) { return 'skip' }
    if (-not $AnswerProvided) { return 'prompt' }
    if ($Answer -and $Answer.Trim() -match '^(?i:y|yes|д|да)$') { return 'enable' }
    return 'skip'
}

function Invoke-AutoSetup {
    <#
        Guided setup: benchmark without allowing Auto-Select to install anything,
        then request explicit consent for service and hosts/IPSet changes. DNS and
        system network settings are deliberately not changed automatically.
    #>
    [CmdletBinding()]
    param(
        [switch]$Install,
        [switch]$NoInteractive,
        [switch]$Fast,
        [switch]$Deep,
        [switch]$CheckFreeze,
        [switch]$EnableSchedule,
        [ValidateSet('mts','megafon','tele2','yota')][string]$Carrier
    )
    if (-not $script:OnWindows) { throw 'auto-setup requires Windows: it launches winws.exe against this PC''s network.' }

    Write-Host ''
    Write-Host (Get-UiText -Russian '  АВТОНАСТРОЙКА' -English '  GUIDED AUTO-SETUP') -ForegroundColor Cyan
    Write-Info2 (Get-UiText -Russian 'Сначала выберите тип подключения и проверьте стратегии. Установка службы и hosts/IPSet выполняются только после явного согласия; DNS и системные сетевые параметры автоматически не меняются.' -English 'First choose the connection type and test strategies. Service installation and hosts/IPSet setup happen only after explicit consent; DNS and system network settings are not changed automatically.')

    $selectedCarrier = $Carrier
    if (-not $selectedCarrier -and -not $NoInteractive) {
        Write-Host ''
        Write-Host (Get-UiText -Russian '  Выберите тип интернета, к которому сейчас подключён этот компьютер:' -English '  Choose the type of connection currently used by this PC:') -ForegroundColor Cyan
        Write-Host (Get-UiText -Russian '    1. Обычный — домашний/офисный, Wi-Fi или кабель' -English '    1. Regular — home/office, Wi-Fi, or wired')
        Write-Host (Get-UiText -Russian '    2. Мобильный — SIM/eSIM, USB-модем или точка доступа телефона' -English '    2. Mobile — SIM/eSIM, USB modem, or phone hotspot')
        Write-Host (Get-UiText -Russian '    0. Отмена' -English '    0. Cancel')
        $connectionType = $null
        while ($null -eq $connectionType) {
            try { $connectionAnswer = Read-Host (Get-UiText -Russian '  Ваш выбор [1/2/0]' -English '  Choose [1/2/0]') }
            catch {
                Write-Info2 (Get-UiText -Russian 'Не удалось прочитать выбор; автонастройка отменена без изменений.' -English 'Could not read a choice; auto-setup was cancelled without changes.')
                return $null
            }
            if ($null -eq $connectionAnswer) {
                Write-Info2 (Get-UiText -Russian 'Выбор не получен; автонастройка отменена без изменений.' -English 'No choice was received; auto-setup was cancelled without changes.')
                return $null
            }
            $connectionType = Resolve-AutoSetupConnectionTypeChoice -Answer $connectionAnswer
            if ($null -eq $connectionType) {
                Write-Warn2 (Get-UiText -Russian 'Введите 1 для обычного интернета, 2 для мобильного или 0 для отмены.' -English 'Enter 1 for regular internet, 2 for mobile, or 0 to cancel.')
            }
        }
        if ($connectionType -eq 'cancel') {
            Write-Info2 (Get-UiText -Russian 'Автонастройка отменена; ничего не изменено.' -English 'Auto-setup cancelled; nothing was changed.')
            return $null
        }
        if ($connectionType -eq 'mobile') {
            Write-Host ''
            Write-Host (Get-UiText -Russian '  Выберите оператора текущей мобильной SIM/eSIM:' -English '  Choose the carrier for the currently connected mobile SIM/eSIM:') -ForegroundColor Cyan
            $carrierProfiles = @(Get-MobileCarrierProfiles)
            for ($i = 0; $i -lt $carrierProfiles.Count; $i++) {
                $carrierLabel = Get-UiText -Russian $carrierProfiles[$i].RussianName -English $carrierProfiles[$i].EnglishName
                Write-Host ('    {0}. {1}' -f ($i + 1), $carrierLabel)
            }
            Write-Host (Get-UiText -Russian '    0. Отмена' -English '    0. Cancel')
            $selectedCarrier = $null
            while (-not $selectedCarrier) {
                try { $carrierAnswer = Read-Host (Get-UiText -Russian '  Ваш выбор [1-4/0]' -English '  Choose [1-4/0]') }
                catch {
                    Write-Info2 (Get-UiText -Russian 'Не удалось прочитать оператора; автонастройка отменена без изменений.' -English 'Could not read the carrier; auto-setup was cancelled without changes.')
                    return $null
                }
                if ($null -eq $carrierAnswer) {
                    Write-Info2 (Get-UiText -Russian 'Оператор не выбран; автонастройка отменена без изменений.' -English 'No carrier was selected; auto-setup was cancelled without changes.')
                    return $null
                }
                if (([string]$carrierAnswer).Trim() -eq '0') {
                    Write-Info2 (Get-UiText -Russian 'Автонастройка отменена; ничего не изменено.' -English 'Auto-setup cancelled; nothing was changed.')
                    return $null
                }
                $selectedCarrier = Resolve-AutoSetupCarrierChoice -Answer $carrierAnswer
                if (-not $selectedCarrier) {
                    Write-Warn2 (Get-UiText -Russian 'Введите номер оператора от 1 до 4 или 0 для отмены.' -English 'Enter a carrier number from 1 to 4, or 0 to cancel.')
                }
            }
        }
    } elseif ($NoInteractive -and -not $selectedCarrier) {
        Write-Info2 (Get-UiText -Russian 'Неинтерактивный режим: использую обычный набор стратегий. Для мобильного профиля укажите -Carrier.' -English 'Non-interactive mode: using the regular strategy set. Specify -Carrier to use a mobile profile.')
    }
    $Carrier = $selectedCarrier

    # Auto-Select temporarily stops winws.exe while probing. -NoInteractive makes
    # it restore the previous state without asking to install or touching hosts/IPSet.
    # Mobile scans use the operator's narrow candidate list and require the full
    # transfer check; fast mode stops early only after all service checks pass.
    $autoSetupConflicts = @()
    try {
        $autoSetupReport = Get-ZapretConflictReport
        if ($autoSetupReport -and $autoSetupReport.PSObject.Properties['Items'] -and $null -ne $autoSetupReport.Items) { $autoSetupConflicts = @($autoSetupReport.Items) }
    } catch { $autoSetupConflicts = @() }
    if ($autoSetupConflicts.Count -gt 0) {
        Write-Warn2 (Get-UiText -Russian ('Обнаружены конфликтующие программы: {0}. Они могут мешать обходу.' -f ($autoSetupConflicts -join ', ')) -English ('Conflicting software detected: {0}. It may interfere with the bypass.' -f ($autoSetupConflicts -join ', ')))
        if (-not $NoInteractive) {
            $answer = Read-Host (Get-UiText -Russian 'Отключить конфликтующие программы сейчас? Изменение обратимо. [y/N]' -English 'Disable the conflicting programs now? The change is reversible. [y/N]')
            if ($answer -match '^[yY\u0434\u0414]') {
                try {
                    $disableResult = Disable-ZapretConflictPrograms -Report $autoSetupReport
                    $disabledNames = @(@($disableResult.Services) | ForEach-Object { $_.Name })
                    if ($disabledNames.Count -gt 0) { Write-Ok (Get-UiText -Russian ('Отключены службы: {0}' -f ($disabledNames -join ', ')) -English ('Services disabled: {0}' -f ($disabledNames -join ', '))) }
                    if (@($disableResult.Processes).Count -gt 0) { Write-Ok (Get-UiText -Russian ('Завершены процессы: {0}' -f (@($disableResult.Processes) -join ', ')) -English ('Processes stopped: {0}' -f (@($disableResult.Processes) -join ', '))) }
                    foreach ($err in @($disableResult.Failed)) { Write-Warn2 (Get-UiText -Russian ('Не выполнено: {0}' -f $err) -English ('Not done: {0}' -f $err)) }
                } catch {
                    Write-Warn2 (Get-UiText -Russian ('Не удалось отключить конфликтующие программы: {0}' -f $_.Exception.Message) -English ('Could not disable the conflicting programs: {0}' -f $_.Exception.Message))
                }
            }
        }
    }
    $useFast = [bool]($Fast -or $Carrier)
    if ($Carrier) {
        $winner = Invoke-AutoSelect -NoInteractive -Fast:$useFast -Deep:$Deep -CheckFreeze:$CheckFreeze -Carrier $Carrier
    } else {
        $winner = Invoke-AutoSelect -NoInteractive -Fast:$useFast -Deep:$Deep -CheckFreeze:$CheckFreeze
    }
    if (-not $winner) { return $winner }

    $confidenceAccepted = $false
    if ($winner.PSObject.Properties['AutoSelectConfidence']) {
        $confidenceAccepted = [bool]($winner.AutoSelectConfidence.CanInstall -or ($winner.AutoSelectConfidence.Stable -and $winner.AutoSelectConfidence.Decision -eq 'keep-current'))
    }
    $candidateUsable = [bool](-not $winner.StartFailed -and [int]$winner.Passed -gt 0 -and $confidenceAccepted)
    if (($Deep -or $CheckFreeze) -and -not $winner.FreezeOk) { $candidateUsable = $false }
    if ($Carrier -and (-not $winner.AllServicesPassed -or -not $winner.FreezeOk)) { $candidateUsable = $false }
    if (-not $candidateUsable) {
        Write-Info2 (Get-UiText -Russian 'Убедительного результата для применения нет; служба, hosts/IPSet и DNS не изменены.' -English 'There is no verified result to apply; the service, hosts/IPSet, and DNS were not changed.')
        return $winner
    }

    $applyAction = Get-AutoSetupApplyAction -CandidateUsable $candidateUsable -Install:$Install -NoInteractive:$NoInteractive
    if ($applyAction -eq 'prompt') {
        $answer = $null
        try { $answer = Read-Host (Get-UiText -Russian '   Установить выбранную стратегию как службу автозапуска? [д/н, по умолчанию нет]' -English '   Install the selected strategy as a startup service? [y/N; default no]') } catch { $answer = $null }
        $applyAction = Get-AutoSetupApplyAction -CandidateUsable $candidateUsable -AnswerProvided $true -Answer $answer
    }

    if ($applyAction -eq 'install') {
        Install-ZapretService -StrategyId $winner.Id | Out-Null
        if ($Install) {
            # The explicit -Install switch is consent to both service installation
            # and the existing post-install hosts/IPSet configuration.
            Invoke-PostInstallConfiguration
        } else {
            Invoke-PostInstallConfiguration -Ask -DefaultNo
        }
    } elseif ($NoInteractive) {
        Write-Info2 (Get-UiText -Russian 'Неинтерактивный режим: ничего не применено. Для установки и настройки запустите автонастройку без -NoInteractive.' -English 'Non-interactive mode: nothing was applied. Run auto-setup without -NoInteractive to install and configure.')
    } else {
        Write-Info2 (Get-UiText -Russian 'Установка пропущена; найденную стратегию можно применить позднее.' -English 'Installation skipped; you can apply the selected strategy later.')
    }

    $serviceInfo = $null
    try { $serviceInfo = Get-ZapretServiceInfo } catch { $serviceInfo = $null }
    $serviceInstalled = [bool]($serviceInfo -and $serviceInfo.Installed)
    $strategyMatches = [bool]($serviceInstalled -and $serviceInfo.Strategy -and $serviceInfo.Strategy -eq $winner.Id)
    $scheduleExists = [bool](Test-AutoSelectSchedule)
    $scheduleAction = Get-AutoSetupScheduleAction -ServiceInstalled $serviceInstalled -StrategyMatches $strategyMatches -ScheduleExists $scheduleExists -EnableSchedule:$EnableSchedule -Install:$Install -NoInteractive:$NoInteractive
    if ($scheduleAction -eq 'prompt') {
        $answer = $null
        try { $answer = Read-Host (Get-UiText -Russian '   Включить еженедельную перепроверку (воскресенье, 03:30)? [д/н, по умолчанию нет]' -English '   Enable the weekly re-check (Sunday, 03:30)? [y/N; default no]') } catch { $answer = $null }
        $scheduleAction = Get-AutoSetupScheduleAction -ServiceInstalled $serviceInstalled -StrategyMatches $strategyMatches -ScheduleExists $scheduleExists -AnswerProvided $true -Answer $answer
    }
    switch ($scheduleAction) {
        'enable' {
            Set-AutoSelectSchedule -Enable
        }
        'already-enabled' {
            Write-Info2 'Еженедельная перепроверка уже включена.'
        }
        default {
            if ($serviceInstalled -and $strategyMatches) {
                Write-Info2 'Еженедельную задачу не включаю автоматически. При необходимости используйте: zapret.ps1 schedule-autoselect enable'
            } else {
                Write-Info2 'Для еженедельной задачи сначала установите найденную стратегию как текущую службу.'
            }
        }
    }
    return $winner
}
