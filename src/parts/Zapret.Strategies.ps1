# ---------------------------------------------------------------------------
# Port range validation
# ---------------------------------------------------------------------------

function Test-PortRange {
    param([string]$Range)
    if (-not $Range) { return $false }
    $clean = $Range -replace '\s', ''
    if (-not $clean) { return $false }
    foreach ($item in $clean.Split(',')) {
        if ($item -notmatch '^\d+(-\d+)?$') { return $false }
        $parts = $item.Split('-')
        $start = 0; $end = 0
        try { $start = [int]$parts[0] } catch { return $false }
        if ($parts.Count -eq 2) { try { $end = [int]$parts[1] } catch { return $false } } else { $end = $start }
        if ($start -lt 1 -or $end -gt 65535 -or $start -gt $end) { return $false }
    }
    return $true
}

function Get-GameFilterPorts {
    # Returns @{ tcp; udp; status } - '12' is used as a harmless placeholder when disabled
    $cfg = Get-Config
    $mode = $cfg.gameFilter.mode
    $tcpRange = $cfg.gameFilter.tcp
    $udpRange = $cfg.gameFilter.udp
    switch ($mode) {
        'all' { return @{ tcp = $tcpRange; udp = $udpRange; status = "enabled (TCP and UDP)" } }
        'tcp' { return @{ tcp = $tcpRange; udp = '12';     status = 'enabled (TCP)' } }
        'udp' { return @{ tcp = '12';     udp = $udpRange; status = 'enabled (UDP)' } }
        default { return @{ tcp = '12';   udp = '12';      status = 'disabled' } }
    }
}

# ---------------------------------------------------------------------------
# User lists bootstrap
# ---------------------------------------------------------------------------

function Get-DefaultUserDomainListContent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('general','exclude')][string]$Kind)
    if ($Kind -eq 'general') { return "# Never leave this file empty`r`ndomain.example.abc`r`n" }
    return "domain.example.abc`r`n"
}

function Initialize-UserLists {
    $created = @()
    $general = Join-Path $script:ListsDir 'list-general-user.txt'
    if (-not (Test-Path $general)) {
        [IO.File]::WriteAllText($general, (Get-DefaultUserDomainListContent -Kind general), (New-Object System.Text.UTF8Encoding($false)))
        $created += 'list-general-user.txt'
    }
    $exclude = Join-Path $script:ListsDir 'list-exclude-user.txt'
    if (-not (Test-Path $exclude)) {
        [IO.File]::WriteAllText($exclude, (Get-DefaultUserDomainListContent -Kind exclude), (New-Object System.Text.UTF8Encoding($false)))
        $created += 'list-exclude-user.txt'
    }
    $ipsetExclude = Join-Path $script:ListsDir 'ipset-exclude-user.txt'
    if (-not (Test-Path $ipsetExclude)) {
        [IO.File]::WriteAllText($ipsetExclude, "$($script:IpsetSentinel)`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $created += 'ipset-exclude-user.txt'
    }
    return $created
}

# ---------------------------------------------------------------------------
# Strategies: loading and expansion
# ---------------------------------------------------------------------------

$script:Strategies = $null

function Get-Strategies {
    if ($script:Strategies) { return $script:Strategies }
    if (-not (Test-Path $script:StrategiesFile)) {
        throw "strategies.json not found next to $script:Root. The archive may be corrupted - re-extract it."
    }
    try {
        $json = [IO.File]::ReadAllText($script:StrategiesFile) | ConvertFrom-Json
    } catch {
        throw "strategies.json is not valid JSON: $($_.Exception.Message)"
    }
    $list = @($json.strategies)
    if ($list.Count -eq 0) { throw "strategies.json does not contain any strategies." }
    $merged = $list
    try {
        $userList = @(Read-UserStrategies)
        if ($userList.Count -gt 0) { $merged = Merge-StrategyLists -Base $list -User $userList }
    } catch {
        Write-Warn2 $_.Exception.Message
    }
    $script:Strategies = @($merged)
    return $script:Strategies
}

function Get-Strategy {
    param([Parameter(Mandatory = $true)][string]$Id)
    $needle = $Id.Trim().ToLowerInvariant()
    foreach ($s in (Get-Strategies)) {
        if ($s.id.ToLowerInvariant() -eq $needle -or $s.name.ToLowerInvariant() -eq $needle) { return $s }
    }
    # also allow legacy names like "general (ALT)" without extension or with .bat
    foreach ($s in (Get-Strategies)) {
        $legacy = ([string]$s.legacyFile).ToLowerInvariant()
        if ($legacy -eq $needle -or $legacy -eq ($needle + '.bat')) { return $s }
    }
    return $null
}

function Expand-StrategyArgs {
    <#
        Expands {BIN} {LISTS} {GAME_TCP} {GAME_UDP} placeholders in a
        strategy's argument template. Returns the final argument string,
        ready for winws.exe / a service PathName.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [string]$BinDir      = $script:BinDir,
        [string]$ListsDir    = $script:ListsDir,
        [string]$GameTcp     = $null,
        [string]$GameUdp     = $null
    )
    if (-not $GameTcp -or -not $GameUdp) {
        $ports = Get-GameFilterPorts
        if (-not $GameTcp) { $GameTcp = $ports.tcp }
        if (-not $GameUdp) { $GameUdp = $ports.udp }
    }
    $expanded = $Template
    $expanded = $expanded.Replace('{BIN}',      (Get-TrailingDir $BinDir))
    $expanded = $expanded.Replace('{LISTS}',    (Get-TrailingDir $ListsDir))
    $expanded = $expanded.Replace('{GAME_TCP}', $GameTcp)
    $expanded = $expanded.Replace('{GAME_UDP}', $GameUdp)
    if ($expanded -match '\{[A-Za-z_]+\}') {
        throw "Strategy argument template contains an unknown placeholder: $($Matches[0])"
    }
    # Structural gate: a broken/hand-written template (user strategies) must fail here with
    # a clear error instead of producing a half-broken winws command line.
    $problems = Test-StrategyArgs -Expanded $expanded -BinDir $BinDir -ListsDir $ListsDir
    if ($problems.Count -gt 0) {
        throw ('Strategy argument template failed validation: ' + (($problems) -join '; '))
    }
    return $expanded
}

function Test-StrategyPathValue {
    # Paths in strategy templates must be single files below {BIN}/{LISTS};
    # expanded paths must stay below the corresponding installation folder.
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('BIN','LISTS')][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateSet('.bin','.txt')][string]$Extension,
        [switch]$Template
    )
    $leafPattern = '^[A-Za-z0-9_.-]+' + [regex]::Escape($Extension) + '$'
    $prefixText = '{' + $Prefix + '}'
    if ($Value.StartsWith($prefixText, [StringComparison]::Ordinal)) {
        $leaf = $Value.Substring($prefixText.Length)
        return ($leaf -match $leafPattern -and $leaf -notmatch '\.\.')
    }
    if ($Template) { return $false }

    $pathValue = $Value.Replace('/', '\')
    $rootValue = $Root.Replace('/', '\').TrimEnd('\')
    if (-not $rootValue) { return $false }
    if ($pathValue -match '(^|\\)\.\.?($|\\)') { return $false }
    if (-not $pathValue.StartsWith(($rootValue + '\'), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $leaf = $pathValue.Substring($rootValue.Length + 1)
    return ($leaf -match $leafPattern -and $leaf -notmatch '\.\.')
}

function Test-StrategyArgs {
    # Strict allow-list validation. Imported strategy data is ultimately passed
    # to winws.exe / the Service Control Manager, so only known zapret options,
    # safe values and files rooted in this installation are accepted.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Expanded,
        [switch]$Template,
        [string]$BinDir = $script:BinDir,
        [string]$ListsDir = $script:ListsDir
    )
    $problems = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Expanded)) { $problems.Add('is empty') }
    if ($Expanded.Length -gt 16384) { $problems.Add('exceeds the 16 KB limit') }
    if ($Expanded -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') { $problems.Add('contains control characters') }
    if ($Expanded -notmatch '^--wf-tcp=') { $problems.Add('does not start with --wf-tcp=') }
    if (([regex]::Matches($Expanded, '"')).Count % 2 -ne 0) { $problems.Add('unbalanced quotes') }
    if ($Expanded -match '%[A-Za-z]|\^') { $problems.Add('contains batch artifacts (%VAR% or ^)') }
    if ($Expanded -match '[;&|<>`]') { $problems.Add('contains shell metacharacters') }
    if ($Expanded -match '\{(?!BIN\}|LISTS\}|GAME_TCP\}|GAME_UDP\})[^}]*\}') { $problems.Add('contains an unknown placeholder') }
    $mNew = [regex]::Match($Expanded, '(?<![\w-])--new(?![\w-])')
    $mFilter = [regex]::Match($Expanded, '--filter-')
    if ($mNew.Success -and ((-not $mFilter.Success) -or ($mNew.Index -lt $mFilter.Index))) {
        $problems.Add('--new starts an empty leading chain before the first --filter- (it would swallow all traffic undecorated)')
    }

    $allowedOptions = @(
        '--wf-tcp','--wf-udp','--filter-tcp','--filter-udp','--filter-l3','--filter-l7',
        '--hostlist','--hostlist-domains','--hostlist-exclude','--hostlist-exclude-domains',
        '--ipset','--ipset-exclude','--ip-id','--new','--dpi-desync',
        '--dpi-desync-any-protocol','--dpi-desync-badseq-increment','--dpi-desync-cutoff',
        '--dpi-desync-fake-discord','--dpi-desync-fake-http','--dpi-desync-fake-quic',
        '--dpi-desync-fake-stun','--dpi-desync-fake-tls','--dpi-desync-fake-tls-mod',
        '--dpi-desync-fake-unknown','--dpi-desync-fake-unknown-udp',
        '--dpi-desync-fakedsplit-pattern','--dpi-desync-fooling',
        '--dpi-desync-hostfakesplit-mod','--dpi-desync-repeats',
        '--dpi-desync-split-pos','--dpi-desync-split-seqovl',
        '--dpi-desync-split-seqovl-pattern'
    )
    $pathOptions = @{
        '--hostlist'                     = @{ Prefix = 'LISTS'; Root = $ListsDir; Extension = '.txt' }
        '--hostlist-exclude'             = @{ Prefix = 'LISTS'; Root = $ListsDir; Extension = '.txt' }
        '--ipset'                        = @{ Prefix = 'LISTS'; Root = $ListsDir; Extension = '.txt' }
        '--ipset-exclude'                = @{ Prefix = 'LISTS'; Root = $ListsDir; Extension = '.txt' }
        '--dpi-desync-fake-discord'      = @{ Prefix = 'BIN'; Root = $BinDir; Extension = '.bin' }
        '--dpi-desync-fake-http'         = @{ Prefix = 'BIN'; Root = $BinDir; Extension = '.bin' }
        '--dpi-desync-fake-quic'         = @{ Prefix = 'BIN'; Root = $BinDir; Extension = '.bin' }
        '--dpi-desync-fake-stun'         = @{ Prefix = 'BIN'; Root = $BinDir; Extension = '.bin' }
        '--dpi-desync-fake-tls'          = @{ Prefix = 'BIN'; Root = $BinDir; Extension = '.bin' }
        '--dpi-desync-fake-unknown'      = @{ Prefix = 'BIN'; Root = $BinDir; Extension = '.bin' }
        '--dpi-desync-fake-unknown-udp'  = @{ Prefix = 'BIN'; Root = $BinDir; Extension = '.bin' }
        '--dpi-desync-split-seqovl-pattern' = @{ Prefix = 'BIN'; Root = $BinDir; Extension = '.bin' }
    }

    $tokenPattern = '(?<!\S)(?<key>--[A-Za-z0-9-]+)(?:=(?<value>"[^"\r\n]*"|[^\s]+))?(?=\s|$)'
    $argumentMatches = [regex]::Matches($Expanded, $tokenPattern)
    $remainder = [regex]::Replace($Expanded, $tokenPattern, '').Trim()
    if ($argumentMatches.Count -eq 0) { $problems.Add('contains no valid zapret options') }
    if ($remainder) { $problems.Add('contains a non-option or malformed argument') }

    foreach ($match in $argumentMatches) {
        $key = $match.Groups['key'].Value
        $hasValue = $match.Groups['value'].Success
        if ($allowedOptions -notcontains $key) {
            $problems.Add("contains unsupported option $key")
            continue
        }
        if ($key -eq '--new') {
            if ($hasValue) { $problems.Add('--new must not have a value') }
            continue
        }
        if (-not $hasValue) {
            $problems.Add("$key requires a value")
            continue
        }

        $rawValue = $match.Groups['value'].Value
        $quoted = $rawValue.StartsWith('"') -and $rawValue.EndsWith('"')
        $value = if ($quoted) { $rawValue.Substring(1, $rawValue.Length - 2) } else { $rawValue }
        if ($value -match '[\x00-\x1F\x7F]') { $problems.Add("$key contains control characters"); continue }

        if ($pathOptions.ContainsKey($key)) {
            $spec = $pathOptions[$key]
            $isLiteralFake = ($key -like '--dpi-desync-fake-*') -and ($value -eq '!' -or $value -match '^0x[0-9A-Fa-f]{2,}$')
            if ($isLiteralFake) { continue }
            if (-not $quoted) { $problems.Add("$key path must be double-quoted"); continue }
            if (-not (Test-StrategyPathValue -Value $value -Prefix $spec.Prefix -Root $spec.Root -Extension $spec.Extension -Template:$Template)) {
                $problems.Add("$key path must be a single $($spec.Extension) file below {$($spec.Prefix)} or its expanded folder")
            }
            continue
        }
        if ($quoted) { $problems.Add("$key does not accept a quoted value"); continue }
        $valueForSafeCheck = $value
        if ($Template) { $valueForSafeCheck = $valueForSafeCheck -replace '\{GAME_(TCP|UDP)\}', '' }
        if ($valueForSafeCheck -match '[^A-Za-z0-9_.,:=+!-]') { $problems.Add("$key contains unsafe characters"); continue }

        switch ($key) {
            { $_ -in @('--wf-tcp','--wf-udp','--filter-tcp','--filter-udp') } {
                $ports = '^(?:\d{1,5}(?:-\d{1,5})?|\{GAME_TCP\}|\{GAME_UDP\})(?:,(?:\d{1,5}(?:-\d{1,5})?|\{GAME_TCP\}|\{GAME_UDP\}))*$'
                if ($value -notmatch $ports) { $problems.Add("$key has an invalid port range") }
                elseif (-not (Test-PortRange ($value -replace '\{GAME_(TCP|UDP)\}', '1'))) { $problems.Add("$key has a port outside 1-65535") }
                break
            }
            '--filter-l3' { if ($value -notin @('ipv4','ipv6')) { $problems.Add('--filter-l3 must be ipv4 or ipv6') }; break }
            '--filter-l7' { if ($value -notmatch '^(quic|discord|stun|unknown)(,(quic|discord|stun|unknown))*$') { $problems.Add('--filter-l7 has an unsupported protocol') }; break }
            { $_ -in @('--hostlist-domains','--hostlist-exclude-domains') } {
                if ($value -notmatch '^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?:,[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?)*$') { $problems.Add("$key has an invalid hostname list") }
                break
            }
            '--ip-id' { if ($value -ne 'zero') { $problems.Add('--ip-id only accepts zero') }; break }
            '--dpi-desync' { if ($value -notmatch '^[a-z]+(?:,[a-z]+)*$') { $problems.Add('--dpi-desync has an invalid mode list') }; break }
            '--dpi-desync-any-protocol' { if ($value -ne '1') { $problems.Add('--dpi-desync-any-protocol only accepts 1') }; break }
            { $_ -in @('--dpi-desync-repeats','--dpi-desync-split-seqovl','--dpi-desync-badseq-increment') } {
                $number = 0L
                if (-not [long]::TryParse($value, [ref]$number) -or $number -lt 1 -or $number -gt 10000000) { $problems.Add("$key is outside the allowed numeric range") }
                break
            }
            '--dpi-desync-cutoff' { if ($value -notmatch '^n[1-9]\d{0,2}$') { $problems.Add('--dpi-desync-cutoff must be n1..n999') }; break }
            '--dpi-desync-fake-tls-mod' { if ($value -notmatch '^(none|rnd(?:,dupsid)?(?:,sni=[a-z0-9.-]+)?)$') { $problems.Add('--dpi-desync-fake-tls-mod has an invalid value') }; break }
            '--dpi-desync-fakedsplit-pattern' { if ($value -notmatch '^0x[0-9A-Fa-f]{2,}$') { $problems.Add('--dpi-desync-fakedsplit-pattern must be a hex byte pattern') }; break }
            '--dpi-desync-fooling' { if ($value -notmatch '^(badseq|ts|md5sig)(,(badseq|ts|md5sig))*$') { $problems.Add('--dpi-desync-fooling has an unsupported value') }; break }
            '--dpi-desync-hostfakesplit-mod' { if ($value -notmatch '^host=[a-z0-9.-]+(?:,altorder=1)?$') { $problems.Add('--dpi-desync-hostfakesplit-mod has an invalid host setting') }; break }
            '--dpi-desync-split-pos' { if ($value -notmatch '^(?:\d+|sniext\+\d+|midsld)(?:,(?:\d+|sniext\+\d+|midsld))*$') { $problems.Add('--dpi-desync-split-pos has an invalid position') }; break }
            default { }
        }
    }
    return ,$problems.ToArray()
}

function Get-WinwsProcess {
    return @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
}

function Stop-Zapret {
    # Get-WinwsProcess emits pipeline output; a single process would otherwise
    # be assigned as a scalar on Windows PowerShell 5.1 and have no .Count.
    $procs = @(Get-WinwsProcess)
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    return $procs.Count
}

function Start-ZapretStrategy {
    param(
        [Parameter(Mandatory = $true)]$Strategy,
        [switch]$Hidden,
        [string]$OutFile,
        [string]$ErrFile
    )
    $winws = Join-Path $script:BinDir 'winws.exe'
    if (-not (Test-Path $winws)) {
        throw "bin\winws.exe was not found. Make sure the archive was fully extracted."
    }
    Initialize-UserLists | Out-Null
    [void](Stop-Zapret)

    $argString = Expand-StrategyArgs -Template $Strategy.args
    $style = if ($Hidden) { 'Hidden' } else { 'Minimized' }

    if ($OutFile -and $ErrFile) {
        try {
            $proc = Start-Process -FilePath $winws -ArgumentList $argString -WorkingDirectory $script:BinDir `
                                  -WindowStyle $style -PassThru -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile
        } catch {
            $proc = Start-Process -FilePath $winws -ArgumentList $argString -WorkingDirectory $script:BinDir `
                                  -WindowStyle $style -PassThru
        }
    } else {
        $proc = Start-Process -FilePath $winws -ArgumentList $argString -WorkingDirectory $script:BinDir `
                              -WindowStyle $style -PassThru
    }
    Write-Log "Started strategy '$($Strategy.id)' (pid $($proc.Id))"
    return $proc
}

# ---------------------------------------------------------------------------
# Service management
# ---------------------------------------------------------------------------

function Stop-ZapretServiceRobust {
    <#
        Full stop for the "Остановить" button: stops the 'zapret' service
        (tolerating a service binary that ignores SERVICE_CONTROL_STOP - winws
        is then killed as a fallback), stops winws.exe processes belonging to
        this installation and unloads this installation's WinDivert driver.
        Foreign winws.exe processes (other installations) are left alone and
        reported. Throws only when the service cannot be stopped at all.
    #>
    [CmdletBinding()]
    param([switch]$Quiet, [int]$TimeoutSec = 20)
    if (-not $script:OnWindows) { throw 'Остановка обхода поддерживается только в Windows.' }
    $report = [pscustomobject]@{
        ServiceWasInstalled = $false
        ServiceStopped      = $false
        OwnProcessesStopped = 0
        ForeignProcesses    = @()
        DriversStopped      = $false
        DriverNote          = ''
    }
    $record = Get-ZapretServiceRecord -Name 'zapret'
    $ownBin = [string]$script:BinDir
    $additionalBinDirs = @()
    if ($record) {
        $report.ServiceWasInstalled = $true
        $installedBinDir = Get-ZapretServiceBinDirectory -PathName ([string]$record.PathName)
        if ($installedBinDir -and -not [string]::Equals($installedBinDir, $ownBin, [StringComparison]::OrdinalIgnoreCase)) {
            $additionalBinDirs += $installedBinDir
        }
        if ([string]$record.State -ne 'Stopped') {
            try { Stop-Service -Name 'zapret' -Force -ErrorAction Stop } catch {
                & (Get-WindowsSystemToolPath -Name 'sc.exe') stop zapret 2>&1 | Out-Null
            }
            if (-not (Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Stopped' -TimeoutSec ([int][Math]::Min($TimeoutSec, 20)))) {
                # winws.exe may ignore SERVICE_CONTROL_STOP - kill it, then verify.
                [void](Stop-Zapret)
                if (-not (Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Stopped' -TimeoutSec 8)) {
                    throw 'Не удалось остановить службу zapret за отведённое время. Перезагрузите Windows и повторите.'
                }
            }
        }
        $report.ServiceStopped = $true
    }
    $foreign = @()
    $ownCount = 0
    foreach ($p in @(Get-WinwsProcess)) {
        $procPath = $null
        try { $procPath = [string]$p.Path } catch { }
        if ($procPath -and $ownBin -and -not $procPath.StartsWith($ownBin, [StringComparison]::OrdinalIgnoreCase)) {
            $foreign += [pscustomobject]@{ Id = $p.Id; Path = $procPath }
            continue
        }
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $ownCount++ } catch { }
    }
    $report.OwnProcessesStopped = $ownCount
    $report.ForeignProcesses = @($foreign)
    if ($ownCount -gt 0) {
        Start-Sleep -Milliseconds 300
        foreach ($p in @(Get-WinwsProcess)) {
            $procPath = $null
            try { $procPath = [string]$p.Path } catch { }
            $isForeign = ($procPath -and $ownBin -and -not $procPath.StartsWith($ownBin, [StringComparison]::OrdinalIgnoreCase))
            if (-not $isForeign) { throw 'winws.exe этой установки не завершается. Проверьте диспетчер задач и повторите.' }
        }
    }
    try {
        Stop-ZapretOwnedDrivers -Quiet:$Quiet -AdditionalBinDirs $additionalBinDirs
        $report.DriversStopped = $true
    } catch {
        $report.DriverNote = $_.Exception.Message
    }
    return $report
}

function Get-ZapretServiceRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('zapret','WinDivert','WinDivert14')][string]$Name)
    if (-not $script:OnWindows) { return $null }
    try {
        return (Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction Stop)
    } catch {
        throw ("Could not query Windows service '{0}': {1}" -f $Name, $_.Exception.Message)
    }
}

function Wait-ZapretServiceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('zapret','WinDivert','WinDivert14')][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Stopped','Absent')][string]$DesiredState,
        [ValidateRange(1,60)][int]$TimeoutSec = 10
    )
    if (-not $script:OnWindows) { return $true }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    do {
        $service = Get-ZapretServiceRecord -Name $Name
        if ($DesiredState -eq 'Absent') {
            if (-not $service) { return $true }
        } elseif (-not $service -or [string]$service.State -eq 'Stopped') {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Wait-ZapretProcessesStopped {
    [CmdletBinding()]
    param([ValidateRange(1,60)][int]$TimeoutSec = 8)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    do {
        if (@(Get-WinwsProcess).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return (@(Get-WinwsProcess).Count -eq 0)
}

function Get-ZapretServiceBinDirectory {
    # Resolve the bin directory from the registered zapret service before it is
    # removed. This lets uninstall recognize an owned WinDivert driver left by
    # an older install location without touching other applications' drivers.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$PathName)
    if ([string]::IsNullOrWhiteSpace($PathName)) { return $null }
    $commandLine = $PathName.Trim()
    if ($commandLine.StartsWith('"')) {
        $closingQuote = $commandLine.IndexOf('"', 1)
        if ($closingQuote -le 1) { return $null }
        $exePath = $commandLine.Substring(1, $closingQuote - 1)
    } else {
        # The package quotes executable paths that contain spaces. For old
        # unquoted entries, accept only the first whitespace-delimited token.
        $exePath = ($commandLine -split '\s+', 2)[0]
    }
    $exePath = [Environment]::ExpandEnvironmentVariables($exePath.Trim()).Replace('/', '\')
    if ($exePath.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $exePath = '\\' + $exePath.Substring(8)
    } elseif ($exePath.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $exePath = $exePath.Substring(4)
    } elseif ($exePath.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        $exePath = $exePath.Substring(4)
    }
    $separatorIndex = [Math]::Max($exePath.LastIndexOf('\'), $exePath.LastIndexOf('/'))
    if ($separatorIndex -lt 0 -or $exePath.Substring($separatorIndex + 1) -ine 'winws.exe') { return $null }
    $driveRooted = ($exePath.Length -ge 3 -and $exePath[1] -eq ':' -and $exePath[2] -eq '\')
    $uncRooted = $exePath.StartsWith('\\', [StringComparison]::OrdinalIgnoreCase)
    if (-not ($driveRooted -or $uncRooted)) { return $null }
    foreach ($pathComponent in $exePath.Split([char]92)) {
        if ($pathComponent -in @('.', '..')) { return $null }
    }

    $binDirectory = $exePath.Substring(0, $separatorIndex)
    if ([string]::IsNullOrWhiteSpace($binDirectory)) { return $null }
    return $binDirectory
}

function Get-ZapretServiceInfo {
    $info = [ordered]@{
        Installed   = $false
        State       = 'NotInstalled'
        Strategy    = $null
        WinwsRunning = ($null -ne (Get-WinwsProcess | Select-Object -First 1))
        WinDivertState = 'NotInstalled'
    }
    $serviceCommandLine = $null

    if ($script:OnWindows) {
        try {
            $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='zapret'" -ErrorAction Stop
            if ($svc) {
                $info.Installed = $true
                $info.State     = $svc.State
                $serviceCommandLine = [string]$svc.PathName
            }
        } catch {
            try {
                $scOut = & (Get-WindowsSystemToolPath -Name 'sc.exe') query zapret 2>&1 | Out-String
                if ($scOut -match 'STATE\s*:\s*\d+\s+(\w+)') { $info.Installed = $true; $info.State = $matches[1] }
            } catch { }
        }

        try {
            $prop = Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -ErrorAction Stop
            $info.Strategy = $prop.'zapret-discord-youtube'
        } catch { }
        if (-not $info.Strategy -and $serviceCommandLine) {
            try { $info.Strategy = Get-StrategyIdFromCommandLine -CommandLine $serviceCommandLine } catch { }
        }

        try {
            $wd = Get-CimInstance -ClassName Win32_Service -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue
            if ($wd) { $info.WinDivertState = $wd.State }
        } catch { }
    }
    return [pscustomobject]$info
}

function Install-ZapretService {
    param([Parameter(Mandatory = $true)][string]$StrategyId, [switch]$NoSnapshot)

    Assert-Admin

    # Stock bat protocol: TCP timestamps must be on for --dpi-desync-fooling=ts.
    [void](Enable-ZapretTcpTimestamps)

    # Snapshot the pre-change state so 'zapret.ps1 rollback' can undo this switch
    if (-not $NoSnapshot) {
        $prevStrategy = $null
        try { $prevStrategy = (Get-ZapretServiceInfo).Strategy } catch { }
        [void](Save-RollbackSnapshot -Reason 'strategy' -Strategy $prevStrategy)
    }
    $strategy = Get-Strategy $StrategyId
    if (-not $strategy) {
        $available = (Get-Strategies | ForEach-Object { $_.id }) -join ', '
        throw "Unknown strategy '$StrategyId'. Available: $available"
    }

    Write-Log "Installing service with strategy '$($strategy.id)'"

    # Remove previous installation if any
    & (Get-WindowsSystemToolPath -Name 'sc.exe') stop zapret 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & (Get-WindowsSystemToolPath -Name 'sc.exe') delete zapret 2>&1 | Out-Null
    [void](Stop-Zapret)
    if (-not (Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Absent' -TimeoutSec 10)) {
        Write-Log 'Anti-stuck: служба не удалилась, убиваю winws.exe этой установки и пробую снова' 'WARN'
        try { [void](Stop-Zapret) } catch { }
        Start-Sleep -Milliseconds 800
        & (Get-WindowsSystemToolPath -Name 'sc.exe') delete zapret 2>&1 | Out-Null
        if (-not (Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Absent' -TimeoutSec 5)) {
            $svc = Get-ZapretServiceRecord -Name 'zapret' -ErrorAction SilentlyContinue
            $state = if ($svc) { $svc.State } else { 'UNKNOWN' }
            throw "Не удалось удалить старую службу zapret (состояние: $state). Служба помечена к удалению — закройте services.msc/диспетчер задач и перезагрузите Windows, затем повторите."
        }
    }

    # Enable TCP timestamps (required by some strategies)
    Enable-TcpTimestamps | Out-Null

    $winwsPath  = Join-Path $script:BinDir 'winws.exe'
    if (-not (Test-Path $winwsPath)) { throw "bin\winws.exe not found. Re-extract the archive." }
    Initialize-UserLists | Out-Null

    $argString = Expand-StrategyArgs -Template $strategy.args
    $pathName  = Get-WinwsPathName -WinwsPath $winwsPath -ExpandedArgs $argString

    $created = $false
    try {
        $result = Invoke-CimMethod -ClassName Win32_Service -MethodName Create -Arguments @{
            Name          = 'zapret'
            DisplayName   = 'zapret'
            PathName      = $pathName
            ServiceType   = 16            # own process
            ErrorControl  = 1             # normal
            StartMode     = 'Automatic'
            DesktopInteract = $false
        } -ErrorAction Stop

        if ($result.ReturnValue -eq 0) {
            $created = $true
        } else {
            Write-Log "Win32_Service.Create returned $($result.ReturnValue); falling back to sc.exe" 'WARN'
        }
    } catch {
        Write-Log "CIM service creation failed: $($_.Exception.Message); falling back to sc.exe" 'WARN'
    }

    if (-not $created) {
        $scArgs = $argString -replace '"', '\"'
        $binPath = '"{0}" {1}' -f $winwsPath, $scArgs
        & (Get-WindowsSystemToolPath -Name 'sc.exe') create zapret binPath= $binPath start= auto DisplayName= zapret 2>&1 | ForEach-Object { Write-Log "sc.exe: $_" }
        if ($LASTEXITCODE -ne 0) { throw "sc.exe failed to create the service (exit code $LASTEXITCODE)." }
    }

    & (Get-WindowsSystemToolPath -Name 'sc.exe') description zapret 'Zapret DPI bypass for Discord and YouTube' 2>&1 | Out-Null
    $startOutput = (& (Get-WindowsSystemToolPath -Name 'sc.exe') start zapret 2>&1 | Out-String).Trim()
    $startExitCode = $LASTEXITCODE
    Start-Sleep -Milliseconds 800
    $svcInfo = $null; try { $svcInfo = Get-ZapretServiceInfo } catch { }
    if ($startExitCode -ne 0 -or ($svcInfo -and [string]$svcInfo.State -ne 'Running')) {
        $hint = ''
        try { $hint = Get-Win32ErrorHint -Code $startExitCode } catch { }
        $details = if ($startOutput) { $startOutput } else { "sc.exe exit $startExitCode" }
        if ($hint) { $details = "$details ($hint)" }
        # also check if winws.exe actually started
        $winwsRunning = $false; try { $winwsRunning = [bool](Get-WinwsProcess | Select-Object -First 1) } catch { }
        if (-not $winwsRunning) {
            throw "Не удалось запустить службу zapret: $details. Проверьте логи и выполните диагностику (проверка установки). Если служба помечена к удалению — перезагрузите Windows."
        }
    }

    try {
        New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' `
            -PropertyType String -Value $strategy.id -Force | Out-Null
    } catch {
        Write-Warn2 "Could not write the strategy name to the registry (non-fatal): $($_.Exception.Message)"
    }

    Write-Ok "Service 'zapret' installed (strategy: $($strategy.id)) and started."
    return $strategy
}

function Test-RemoveHostsBlockDecision {
    # Pure decision helper so the CLI flag, quiet mode, and menu default can be tested off Windows.
    [CmdletBinding()]
    param(
        [switch]$Quiet,
        [switch]$RemoveHostsBlock,
        [AllowNull()][AllowEmptyString()][string]$Answer
    )
    if ($RemoveHostsBlock) { return $true }
    if ($Quiet) { return $false }
    if ([string]::IsNullOrWhiteSpace($Answer)) { return $true }
    return ($Answer.Trim().ToLowerInvariant() -in @('y', 'yes', 'д', 'да'))
}

function Remove-ZapretServices {
    param([switch]$Quiet, [switch]$RemoveHostsBlock)

    Assert-Admin
    Write-Log 'Removing zapret services and winws processes'

    $scPath = Get-WindowsSystemToolPath -Name 'sc.exe'
    $installedService = Get-ZapretServiceRecord -Name 'zapret'
    $additionalBinDirs = @()
    if ($installedService) {
        $installedBinDir = Get-ZapretServiceBinDirectory -PathName ([string]$installedService.PathName)
        if ($installedBinDir -and -not [string]::Equals($installedBinDir, [string]$script:BinDir, [StringComparison]::OrdinalIgnoreCase)) {
            $additionalBinDirs += $installedBinDir
        }

        if ([string]$installedService.State -ne 'Stopped') {
            $stopOutput = (& $scPath stop zapret 2>&1 | Out-String).Trim()
            $stopExitCode = $LASTEXITCODE
            if (-not (Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Stopped' -TimeoutSec 8)) {
                # A service may ignore STOP while winws is wedged. Kill the
                # process only as a fallback, then verify the SCM state again.
                [void](Stop-Zapret)
                if (-not (Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Stopped' -TimeoutSec 5)) {
                    throw ("Не удалось остановить службу zapret (sc.exe exit {0}). {1} Перезагрузите Windows и повторите удаление." -f $stopExitCode, $stopOutput)
                }
            }
        }

        if (-not (Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Stopped' -TimeoutSec 2)) {
            throw 'Служба zapret всё ещё работает; не удаляю её регистрацию, чтобы не сообщать об успехе преждевременно.'
        }
        # Make sure a manually started winws.exe is also stopped before a
        # possible delete timeout leaves a service entry behind.
        [void](Stop-Zapret)
        if (-not (Wait-ZapretProcessesStopped -TimeoutSec 8)) {
            throw 'Не удалось остановить winws.exe перед удалением службы.'
        }
        $installedService = Get-ZapretServiceRecord -Name 'zapret'
        if ($installedService) {
            $deleteOutput = (& $scPath delete zapret 2>&1 | Out-String).Trim()
            $deleteExitCode = $LASTEXITCODE
            if (-not (Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Absent' -TimeoutSec 10)) {
                throw ("Не удалось удалить регистрацию службы zapret (sc.exe exit {0}). {1} Если служба помечена к удалению, закройте services.msc и перезагрузите Windows." -f $deleteExitCode, $deleteOutput)
            }
        }
        if (-not $Quiet) { Write-Ok "Service 'zapret' stopped and removed." }
    } elseif (-not $Quiet) {
        Write-Info2 "Service 'zapret' is not installed."
    }

    $killed = Stop-Zapret
    if (-not (Wait-ZapretProcessesStopped -TimeoutSec 8)) {
        throw 'После удаления службы в системе всё ещё запущен winws.exe. Проверьте процессы и перезагрузите Windows, если остановить его не удаётся.'
    }
    if (-not $Quiet) {
        if ($killed -gt 0) { Write-Ok "Stopped $killed winws process(es); verified that none remain." } else { Write-Info2 'winws.exe is not running.' }
    }

    # Reuse the ownership/path guard as the pause flow, including the bin path
    # recorded by the service in case this install was moved or upgraded.
    $driverCleanupError = $null
    try {
        Stop-ZapretOwnedDrivers -Quiet:$Quiet -AdditionalBinDirs $additionalBinDirs
    } catch {
        $driverCleanupError = $_.Exception.Message
        if (-not $Quiet) { Write-Warn2 ("Could not fully remove this installation's WinDivert driver service: {0}" -f $driverCleanupError) }
    }

    try {
        Remove-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -ErrorAction SilentlyContinue
    } catch { }

    # The weekly auto re-check task should not outlive the install
    try {
        if (Test-AutoSelectSchedule) {
            & (Get-WindowsSystemToolPath -Name 'schtasks.exe') /Delete /TN $script:AutoSelectTaskName /F 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'schtasks could not delete the task.' }
            if (-not $Quiet) { Write-Ok 'Weekly auto re-check task (Zapret-AutoSelect) removed.' }
        }
    } catch {
        Write-Warn2 'Could not remove the Zapret-AutoSelect scheduled task - remove it manually: schtasks /Delete /TN Zapret-AutoSelect /F'
    }

    # The watchdog ("Автозащита") task must not outlive the installation either -
    # otherwise it keeps probing a removed install every few hours.
    try {
        if (Test-WatchdogSchedule) {
            & (Get-WindowsSystemToolPath -Name 'schtasks.exe') /Delete /TN $script:WatchdogTaskName /F 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'schtasks could not delete the task.' }
            if (-not $Quiet) { Write-Ok 'Watchdog task (Zapret-Watchdog) removed.' }
        }
    } catch {
        Write-Warn2 'Could not remove the Zapret-Watchdog scheduled task - remove it manually: schtasks /Delete /TN Zapret-Watchdog /F'
    }

    # Offer to remove the managed hosts block (Discord/GitHub IPs)
    try {
        if (Test-HostsManaged -Path (Get-HostsFilePath)) {
            $answer = $null
            if (-not $RemoveHostsBlock -and -not $Quiet) {
                try { $answer = Read-Host (ConvertTo-UiMessage -Text 'Also remove the managed block from hosts? [Y/n]') } catch { $answer = $null }
            }
            $removeHosts = Test-RemoveHostsBlockDecision -Quiet:$Quiet -RemoveHostsBlock:$RemoveHostsBlock -Answer $answer
            if ($removeHosts) {
                [void](Remove-HostsManagedBlock)
            } elseif (-not $Quiet) {
                Write-Info2 'Hosts block left in place.'
            }
        }
    } catch {
        if (-not $Quiet) { Write-Warn2 "Could not remove the managed hosts block: $($_.Exception.Message)" }
    }

    if ($driverCleanupError) {
        throw ("Удаление выполнено не полностью: служба WinDivert не очищена. {0}" -f $driverCleanupError)
    }
    return $true
}

function Get-ZapretPauseResumePlan {
    # Pure state decision: pause an active service or process, then restore the
    # same mode (service vs. manually launched winws.exe) and strategy.
    [CmdletBinding()]
    param(
        [bool]$ServiceInstalled,
        [string]$ServiceState,
        [string]$ServiceStrategy,
        [bool]$ProcessRunning,
        [string]$ProcessStrategy
    )
    $serviceWasRunning = ($ServiceInstalled -and $ServiceState -match '^(?i:Running|Start Pending|Stop Pending)$')
    $active = ($serviceWasRunning -or $ProcessRunning)
    $strategy = if ($serviceWasRunning -and $ServiceStrategy) { $ServiceStrategy } elseif ($ProcessStrategy) { $ProcessStrategy } else { $ServiceStrategy }
    return [pscustomobject]@{
        Active = $active
        StrategyId = $strategy
        ServiceWasRunning = [bool]$serviceWasRunning
        ProcessWasRunning = [bool]$ProcessRunning
    }
}

function Get-StrategyIdFromCommandLine {
    # Resolve a manually launched winws.exe by matching its known expanded args.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CommandLine)
    foreach ($strategy in (Get-Strategies)) {
        try {
            $expanded = Expand-StrategyArgs -Template ([string]$strategy.args)
            if ($CommandLine.IndexOf($expanded, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$strategy.id }
        } catch { }
    }
    return $null
}

function Test-ZapretDriverPath {
    # Do not stop another application's WinDivert service. Only manage
    # a driver image explicitly located below this installation's bin folder.
    [CmdletBinding()]
    param([string]$PathName, [string]$BinDir = $script:BinDir)
    if ([string]::IsNullOrWhiteSpace($PathName)) { return $false }
    $path = $PathName.Trim()
    if ($path -match '^"([^"]+)"') { $path = $Matches[1] }
    else { $path = ($path -split '\s+', 2)[0] }
    foreach ($prefix in @('\\?\', '\??\')) {
        if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $path = $path.Substring($prefix.Length)
            break
        }
    }
    $path = [Environment]::ExpandEnvironmentVariables($path).Replace('/', '\')
    $root = $BinDir.Replace('/', '\').TrimEnd('\')
    if (-not $root -or $path -match '(^|\\)\.\.?($|\\)') { return $false }
    if (-not $path.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $leaf = $path.Substring($root.Length + 1)
    return ($leaf -match '^WinDivert(?:14)?(?:32|64)?\.sys$')
}

function Get-RunningZapretStrategyId {
    if (-not $script:OnWindows) { return $null }
    $processes = @(Get-WinwsProcess)
    foreach ($process in $processes) {
        try {
            $record = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $process.Id) -ErrorAction Stop
            if ($record -and $record.CommandLine) {
                $id = Get-StrategyIdFromCommandLine -CommandLine ([string]$record.CommandLine)
                if ($id) { return $id }
            }
        } catch { }
    }
    return $null
}

function Stop-ZapretOwnedDrivers {
    [CmdletBinding()]
    param([switch]$Quiet, [string[]]$AdditionalBinDirs = @())
    if (-not $script:OnWindows) { return }
    Assert-Admin
    $scPath = Get-WindowsSystemToolPath -Name 'sc.exe'
    $ownerBinDirs = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$script:BinDir)) { $ownerBinDirs += [string]$script:BinDir }
    foreach ($candidateBinDir in $AdditionalBinDirs) {
        if ([string]::IsNullOrWhiteSpace($candidateBinDir)) { continue }
        if (-not ($ownerBinDirs | Where-Object { [string]::Equals($_, $candidateBinDir, [StringComparison]::OrdinalIgnoreCase) })) {
            $ownerBinDirs += $candidateBinDir
        }
    }
    foreach ($name in @('WinDivert','WinDivert14')) {
        $service = Get-ZapretServiceRecord -Name $name
        if (-not $service) { continue }
        $isOwned = $false
        foreach ($ownerBinDir in $ownerBinDirs) {
            if (Test-ZapretDriverPath -PathName ([string]$service.PathName) -BinDir $ownerBinDir) { $isOwned = $true; break }
        }
        if (-not $isOwned) {
            if (-not $Quiet) { Write-Info2 ("Драйвер {0} оставлен: путь службы не принадлежит bin\ zapret или не распознан (возможно, он нужен другой программе)." -f $name) }
            continue
        }
        if ([string]$service.State -ne 'Stopped') {
            $stopOutput = (& $scPath stop $name 2>&1 | Out-String).Trim()
            $stopExitCode = $LASTEXITCODE
        } else {
            $stopOutput = ''
            $stopExitCode = 0
        }
        if (-not (Wait-ZapretServiceState -Name $name -DesiredState 'Stopped' -TimeoutSec 6)) {
            throw ("Не удалось выгрузить принадлежащий zapret драйвер {0} (sc.exe exit {1}). {2}" -f $name, $stopExitCode, $stopOutput)
        }
        $service = Get-ZapretServiceRecord -Name $name
        if ($service) {
            $deleteOutput = (& $scPath delete $name 2>&1 | Out-String).Trim()
            $deleteExitCode = $LASTEXITCODE
            if (-not (Wait-ZapretServiceState -Name $name -DesiredState 'Absent' -TimeoutSec 10)) {
                throw ("Не удалось удалить регистрацию принадлежащего zapret драйвера {0} (sc.exe exit {1}). {2}" -f $name, $deleteExitCode, $deleteOutput)
            }
        }
        if (-not $Quiet) { Write-Info2 ("Драйвер {0} из папки zapret выгружен, регистрация службы удалена." -f $name) }
    }
}

function Wait-ZapretPause {
    [CmdletBinding()]
    param([ValidateRange(0,1440)][int]$Minutes = 0)
    if ($Minutes -le 0) {
        [void](Read-Host (Get-UiText -Russian 'Нажмите Enter, чтобы возобновить обход' -English 'Press Enter to resume the bypass'))
        return
    }
    $duration = [TimeSpan]::FromMinutes($Minutes)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host (ConvertTo-UiMessage -Text ("Пауза: {0} мин. Нажмите любую клавишу, чтобы возобновить раньше." -f $Minutes)) -ForegroundColor Yellow
    while ($timer.Elapsed -lt $duration) {
        $remaining = $duration - $timer.Elapsed
        $secondsLeft = [Math]::Max(0, [int][Math]::Ceiling($remaining.TotalSeconds))
        $timeText = '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($remaining.TotalHours), $remaining.Minutes, $remaining.Seconds
        Write-Progress -Activity (Get-UiText -Russian 'Пауза обхода для игры или античита' -English 'Pause bypass for a game or anti-cheat') -Status (Get-UiText -Russian ("До возобновления: {0}" -f $timeText) -English ("Time until resume: {0}" -f $timeText)) -SecondsRemaining $secondsLeft
        try {
            if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                [void][Console]::ReadKey($true)
                Write-Info2 'Получен ввод с клавиатуры — возобновляю раньше таймера.'
                break
            }
        } catch { }
        Start-Sleep -Milliseconds 250
    }
    Write-Progress -Activity (Get-UiText -Russian 'Пауза обхода для игры или античита' -English 'Pause bypass for a game or anti-cheat') -Completed
}

function Suspend-ZapretBypass {
    # Temporarily stop zapret/winws for anti-cheat without uninstalling the
    # zapret service, touching hosts/config or changing the scheduled task.
    [CmdletBinding()]
    param([ValidateRange(0,1440)][int]$Minutes = 0)
    if (-not $script:OnWindows) { throw 'pause requires Windows.' }
    Assert-Admin
    if ($Minutes -eq 0) {
        try { if ([Console]::IsInputRedirected) { throw 'pause without minutes needs an interactive console; use pause <Minutes> instead.' } }
        catch { throw 'pause without minutes needs an interactive console; use pause <Minutes> instead.' }
    }

    $serviceInfo = Get-ZapretServiceInfo
    $processes = @(Get-WinwsProcess)
    $processStrategy = if ($processes.Count -gt 0) { Get-RunningZapretStrategyId } else { $null }
    $serviceStrategy = $null
    if ($serviceInfo.Strategy) {
        $known = Get-Strategy -Id ([string]$serviceInfo.Strategy)
        if ($known) { $serviceStrategy = [string]$known.id }
    }
    $plan = Get-ZapretPauseResumePlan -ServiceInstalled ([bool]$serviceInfo.Installed) `
        -ServiceState ([string]$serviceInfo.State) -ServiceStrategy $serviceStrategy `
        -ProcessRunning ($processes.Count -gt 0) -ProcessStrategy $processStrategy
    if (-not $plan.Active) {
        Write-Info2 'Сейчас не работает ни служба zapret, ни winws.exe — пауза не требуется.'
        return [pscustomobject]@{ Paused = $false; StrategyId = $null; Restored = $false }
    }
    if (-not $plan.StrategyId) { throw 'Не удалось определить активную стратегию; пауза отменена, чтобы не потерять возможность возобновления.' }
    $strategy = Get-Strategy -Id $plan.StrategyId
    if (-not $strategy) { throw "Стратегия '$($plan.StrategyId)' не найдена; пауза отменена." }

    $stateChanged = $false
    $pauseError = $null
    $restored = $false
    try {
        if ($plan.ServiceWasRunning) {
            $stateChanged = $true
            & (Get-WindowsSystemToolPath -Name 'sc.exe') stop zapret 2>&1 | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 300
                $current = Get-ZapretServiceInfo
            } while ($current.Installed -and $current.State -in @('Running','Stop Pending','Start Pending') -and [DateTime]::UtcNow -lt $deadline)
            if ($current.Installed -and $current.State -ne 'Stopped') { throw 'Не удалось полностью остановить службу zapret.' }
        } elseif ($plan.ProcessWasRunning) {
            $stateChanged = $true
        }
        $killed = Stop-Zapret
        $processDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 200
            $remainingProcesses = @(Get-WinwsProcess)
        } while ($remainingProcesses.Count -gt 0 -and [DateTime]::UtcNow -lt $processDeadline)
        if ($remainingProcesses.Count -gt 0) { throw 'Не удалось завершить все процессы winws.exe.' }
        Stop-ZapretOwnedDrivers
        Write-Ok ("Обход приостановлен. Стратегия '{0}' будет восстановлена {1}." -f $strategy.id, $(if ($Minutes -gt 0) { "через $Minutes мин." } else { 'после Enter' }))
        Write-Log ("Zapret paused: strategy={0}; service={1}; minutes={2}; killed={3}" -f $strategy.id, $plan.ServiceWasRunning, $Minutes, $killed)
        Wait-ZapretPause -Minutes $Minutes
    } catch {
        $pauseError = $_
    } finally {
        # Restore even if stop/unload/wait fails or the user interrupts the pause.
        if ($stateChanged) {
            try {
                if ($plan.ServiceWasRunning) {
                    Write-Info2 ("Возобновляю прежнюю службу zapret со стратегией '{0}'..." -f $strategy.id)
                    $serviceNow = Get-ZapretServiceInfo
                    if (-not $serviceNow.Installed) { throw 'Служба zapret исчезла во время паузы.' }
                    if ($serviceNow.State -ne 'Running') {
                        & (Get-WindowsSystemToolPath -Name 'sc.exe') start zapret 2>&1 | Out-Null
                        $deadline = [DateTime]::UtcNow.AddSeconds(20)
                        do {
                            Start-Sleep -Milliseconds 300
                            $serviceNow = Get-ZapretServiceInfo
                        } while ($serviceNow.Installed -and $serviceNow.State -ne 'Running' -and [DateTime]::UtcNow -lt $deadline)
                    }
                    if (-not $serviceNow.Installed -or $serviceNow.State -ne 'Running') { throw 'Служба zapret не перешла в состояние Running.' }
                } elseif ($plan.ProcessWasRunning) {
                    Write-Info2 ("Возобновляю запущенный вручную winws.exe со стратегией '{0}'..." -f $strategy.id)
                    [void](Start-ZapretStrategy -Strategy $strategy -Hidden)
                }
                $restored = $true
                Write-Ok 'zapret возобновлён.'
            } catch {
                $restoreError = $_
                Write-Fail ("Не удалось возобновить обход автоматически: {0}" -f $restoreError.Exception.Message)
                Write-Info2 ("Попробуйте вручную: zapret.ps1 {0} {1}" -f $(if ($plan.ServiceWasRunning) { 'install' } else { 'run' }), $strategy.id)
                if ($null -eq $pauseError) { $pauseError = $restoreError }
            }
        }
    }
    if ($pauseError) { throw $pauseError }
    return [pscustomobject]@{ Paused = $true; StrategyId = $strategy.id; Restored = $restored }
}

function Enable-TcpTimestamps {
    try {
        $out = & (Get-WindowsSystemToolPath -Name 'netsh.exe') interface tcp show global 2>&1 | Out-String
        if ($out -match 'timestamps\s*:\s*enabled') { return $true }
        & (Get-WindowsSystemToolPath -Name 'netsh.exe') interface tcp set global timestamps=enabled 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}
