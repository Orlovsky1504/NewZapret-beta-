function Measure-PingStats {
    <# Pure summary of RTT samples; NaN, infinity, and negative values represent lost requests. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][double[]]$Samples)

    $values = @($Samples)
    $received = New-Object 'System.Collections.Generic.List[double]'
    $deltas = New-Object 'System.Collections.Generic.List[double]'
    $havePrevious = $false
    $previous = 0.0
    foreach ($sample in $values) {
        if ([double]::IsNaN($sample) -or [double]::IsInfinity($sample) -or $sample -lt 0) {
            $havePrevious = $false
            continue
        }
        $received.Add([double]$sample)
        if ($havePrevious) { $deltas.Add([Math]::Abs(([double]$sample) - $previous)) }
        $previous = [double]$sample
        $havePrevious = $true
    }

    $minimum = $null; $average = $null; $maximum = $null; $jitter = $null
    if ($received.Count -gt 0) {
        $summary = $received | Measure-Object -Minimum -Average -Maximum
        $minimum = [Math]::Round([double]$summary.Minimum, 2)
        $average = [Math]::Round([double]$summary.Average, 2)
        $maximum = [Math]::Round([double]$summary.Maximum, 2)
        if ($deltas.Count -gt 0) { $jitter = [Math]::Round((($deltas | Measure-Object -Average).Average), 2) }
    }
    $loss = 0.0
    if ($values.Count -gt 0) { $loss = [Math]::Round((100.0 * ($values.Count - $received.Count) / $values.Count), 2) }
    return [pscustomobject]@{
        Min         = $minimum
        Avg         = $average
        Max         = $maximum
        Jitter      = $jitter
        LossPercent = $loss
        Sent        = $values.Count
        Received    = $received.Count
    }
}

function Get-IpInterfaceMtuBytes {
    <# Read the MTU from Get-NetIPInterface across output-property variants. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Interface)

    foreach ($propertyName in @('NlMtu', 'NlMtuBytes', 'NlMtu(Bytes)')) {
        $property = $Interface.PSObject.Properties[$propertyName]
        if (-not $property) { continue }
        $mtu = [long]0
        if ([long]::TryParse([string]$property.Value, [ref]$mtu)) { return $mtu }
    }
    throw 'Could not determine the MTU of the active IPv4 interface.'
}

function Get-DefaultIPv4Network {
    <# Returns the interface selected by the active IPv4 default route. Windows-only. #>
    [CmdletBinding()]
    param()
    if (-not $script:OnWindows) { throw 'Network interface discovery requires Windows.' }
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.NextHop) -and [string]$_.NextHop -ne '0.0.0.0'
    })
    if ($routes.Count -eq 0) { throw 'No active IPv4 default route/gateway was found.' }
    $adapters = @(Get-NetAdapter -ErrorAction Stop)
    $candidates = @()
    foreach ($route in $routes) {
        $index = 0
        if (-not [int]::TryParse([string]$route.InterfaceIndex, [ref]$index) -or $index -lt 1) { continue }
        $ipInterface = $null
        try { $ipInterface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1 } catch { }
        if ($null -eq $ipInterface) { continue }
        $adapter = @($adapters | Where-Object { [int]$_.ifIndex -eq $index -and [string]$_.Status -eq 'Up' } | Select-Object -First 1)
        if ($adapter.Count -eq 0) { continue }
        $routeMetric = 0.0; $interfaceMetric = 0.0
        [void][double]::TryParse([string]$route.RouteMetric, [ref]$routeMetric)
        [void][double]::TryParse([string]$ipInterface.InterfaceMetric, [ref]$interfaceMetric)
        $mtu = Get-IpInterfaceMtuBytes -Interface $ipInterface
        $candidates += [pscustomobject]@{
            Metric          = $routeMetric + $interfaceMetric
            InterfaceIndex  = $index
            InterfaceName   = [string]$adapter[0].Name
            InterfaceGuid   = [string]$adapter[0].InterfaceGuid
            Gateway         = [string]$route.NextHop
            Mtu             = $mtu
            AdapterStatus   = [string]$adapter[0].Status
        }
    }
    $selected = $candidates | Sort-Object Metric, InterfaceIndex | Select-Object -First 1
    if (-not $selected) { throw 'Could not resolve the active IPv4 interface from the default route.' }
    if (-not (Test-IPv4AddressText -Address $selected.Gateway)) { throw 'The active IPv4 route returned an invalid gateway address.' }
    if ([int]$selected.Mtu -lt 576 -or [int]$selected.Mtu -gt 65535) { throw 'The active interface returned an invalid IPv4 MTU.' }
    return $selected
}

function ConvertTo-RssState {
    # Pure parser for Get-NetOffloadGlobalSetting values.
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { if ($Value) { return 'enabled' }; return 'disabled' }
    $text = ([string]$Value).Trim()
    if ($text -match '^(?i)(enabled|true|1|включено|включен|включена|включены)$') { return 'enabled' }
    if ($text -match '^(?i)(disabled|false|0|отключено|отключен|отключена|отключены)$') { return 'disabled' }
    return $null
}

function ConvertFrom-RssNetshText {
    # Pure parser for English/Russian netsh output; returns enabled, disabled, or $null.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    foreach ($line in ($Text -split '[\r\n]+')) {
        if ($line -notmatch '(?i)(rss|receive.?side\s+scaling|масштабирован.*при[её]м|при[её]м.*масштабирован)') { continue }
        $match = [regex]::Match($line, '(?i)(enabled|disabled|включ[её]н\w*|отключ[её]н\w*)')
        if ($match.Success) { return (ConvertTo-RssState -Value $match.Value) }
    }
    return $null
}

function Get-RssGlobalState {
    [CmdletBinding()]
    param()
    if (-not $script:OnWindows) { throw 'RSS inspection requires Windows.' }
    if (Get-Command Get-NetOffloadGlobalSetting -ErrorAction SilentlyContinue) {
        try {
            $global = Get-NetOffloadGlobalSetting -ErrorAction Stop | Select-Object -First 1
            if ($global -and $global.PSObject.Properties['ReceiveSideScaling']) {
                $state = ConvertTo-RssState -Value $global.ReceiveSideScaling
                if ($state) { return $state }
            }
        } catch { }
    }
    $netsh = Get-WindowsSystemToolPath -Name 'netsh.exe'
    $output = & $netsh interface tcp show global 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Could not query the current RSS state with netsh.' }
    $parsed = ConvertFrom-RssNetshText -Text $output
    if (-not $parsed) { throw 'Could not determine the current RSS state; no network changes were made.' }
    return $parsed
}

function Get-NetworkRegistryValueSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $script:OnWindows) { throw 'Registry snapshots require Windows.' }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $false; Kind = $null; Value = $null }
    }
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    $exists = @($key.GetValueNames()) -contains $Name
    if (-not $exists) { return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $false; Kind = $null; Value = $null } }
    $kind = $key.GetValueKind($Name).ToString()
    $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return [pscustomobject]@{ Path = $Path; Name = $Name; Exists = $true; Kind = $kind; Value = $value }
}

function Test-NetworkRegistrySnapshotEntry {
    # Pure allow-list validation keeps a tampered rollback file out of arbitrary registry locations.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    $systemProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    if ([string]::Equals($Path, $systemProfile, [StringComparison]::OrdinalIgnoreCase)) {
        return ($Name -in @('NetworkThrottlingIndex', 'SystemResponsiveness'))
    }
    $interfaceMatch = [regex]::Match($Path, '(?i)^HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters\\Interfaces\\(?<guid>\{[0-9a-f-]{36}\})$')
    if (-not $interfaceMatch.Success) { return $false }
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($interfaceMatch.Groups['guid'].Value, [ref]$guid)) { return $false }
    return ($Name -in @('TcpAckFrequency', 'TCPNoDelay'))
}

function Set-NetworkRegistryDword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )
    if (-not $script:OnWindows) { throw 'Registry changes require Windows.' }
    Assert-Admin
    if (-not (Test-NetworkRegistrySnapshotEntry -Path $Path -Name $Name)) { throw 'Refusing to write outside the approved network registry values.' }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

function ConvertTo-NetworkRegistryRestoreValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Value, [Parameter(Mandatory = $true)][string]$Kind)
    switch ($Kind) {
        'String'       { return [string]$Value }
        'ExpandString' { return [string]$Value }
        'DWord'        { return [int]$Value }
        'QWord'        { return [long]$Value }
        'MultiString'  { return ,([string[]]@($Value | ForEach-Object { [string]$_ })) }
        'Binary'       { return ,([byte[]]@($Value | ForEach-Object { [byte]$_ })) }
        default        { throw ("Unsupported registry value kind '{0}'." -f $Kind) }
    }
}

function Test-NetworkRegistrySnapshotKind {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Kind)
    return ($Kind -in @('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary'))
}

function New-NetworkRollbackSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('optimization', 'mtu')][string]$Reason,
        [object[]]$Registry = @(),
        [AllowNull()][string]$Rss,
        [AllowNull()][object]$InterfaceMtu,
        [string]$LogDir = $script:LogDir
    )
    if ([string]::IsNullOrWhiteSpace($LogDir)) { throw 'LogDir cannot be empty.' }
    if ($Registry.Count -eq 0 -and -not $Rss -and $null -eq $InterfaceMtu) { throw 'A network rollback snapshot must contain at least one restorable value.' }
    foreach ($entry in @($Registry)) {
        if (-not (Test-NetworkRegistrySnapshotEntry -Path ([string]$entry.Path) -Name ([string]$entry.Name))) { throw 'Refusing to save an unexpected network registry path/value.' }
        if ([bool]$entry.Exists -and -not (Test-NetworkRegistrySnapshotKind -Kind ([string]$entry.Kind))) { throw 'Unsupported registry value type in network snapshot.' }
    }
    if ($Rss -and $Rss -notin @('enabled', 'disabled')) { throw 'Invalid RSS state for rollback snapshot.' }
    if ($null -ne $InterfaceMtu) {
        $guid = [Guid]::Empty; $interfaceIndex = 0; $previousMtu = 0
        if (-not [Guid]::TryParse([string]$InterfaceMtu.InterfaceGuid, [ref]$guid) -or
            -not [int]::TryParse([string]$InterfaceMtu.InterfaceIndex, [ref]$interfaceIndex) -or $interfaceIndex -lt 1 -or
            -not [int]::TryParse([string]$InterfaceMtu.PreviousMtu, [ref]$previousMtu) -or $previousMtu -lt 576 -or $previousMtu -gt 65535) {
            throw 'Invalid interface MTU rollback data.'
        }
    }
    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $path = Join-Path $LogDir ("rollback-net-{0}.json" -f $stamp)
    $suffix = 0
    while (Test-Path -LiteralPath $path) {
        $suffix++
        $path = Join-Path $LogDir ("rollback-net-{0}-{1}.json" -f $stamp, $suffix)
    }
    $snapshot = [ordered]@{
        Version      = 1
        Kind         = 'network'
        Reason       = $Reason
        CreatedAt    = (Get-Date -Format 's')
        Registry     = @($Registry)
        Rss          = $Rss
        InterfaceMtu = $InterfaceMtu
    }
    $json = ConvertTo-Json -InputObject $snapshot -Depth 8
    $tempPath = $path + '.tmp'
    try {
        [IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $path -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw ("Could not write network rollback snapshot: {0}" -f $_.Exception.Message)
    }
    Write-Log ("Network rollback snapshot saved ({0}): {1}" -f $Reason, $path)
    return $path
}

function Test-NetworkRollbackSnapshotPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$LogDir)
    try {
        $logFull = [IO.Path]::GetFullPath($LogDir).TrimEnd('\', '/')
        $fileFull = [IO.Path]::GetFullPath($Path)
        if (-not [string]::Equals((Split-Path -Parent $fileFull).TrimEnd('\', '/'), $logFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        return ((Split-Path -Leaf $fileFull) -match '^rollback-net-\d{8}-\d{9}(?:-\d+)?\.json$')
    } catch { return $false }
}

function Get-LatestNetworkRollbackSnapshotPath {
    [CmdletBinding()]
    param([string]$LogDir = $script:LogDir)
    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { return $null }
    $file = Get-ChildItem -LiteralPath $LogDir -File -Filter 'rollback-net-*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^rollback-net-\d{8}-\d{9}(?:-\d+)?\.json$' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($file) { return $file.FullName }
    return $null
}

function Invoke-NetworkNetshCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    if (-not $script:OnWindows) { throw 'Network netsh operations require Windows.' }
    Assert-Admin
    $netsh = Get-WindowsSystemToolPath -Name 'netsh.exe'
    $output = & $netsh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw ("netsh failed (exit {0}): {1}" -f $exitCode, (($output | Out-String).Trim())) }
}

function Set-NetworkInterfaceMtu {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$InterfaceIndex, [Parameter(Mandatory = $true)][int]$Mtu)
    if (-not $script:OnWindows) { throw 'Changing MTU requires Windows.' }
    Assert-Admin
    if ($InterfaceIndex -lt 1 -or $InterfaceIndex -gt 65535) { throw 'Invalid interface index.' }
    if ($Mtu -lt 576 -or $Mtu -gt 65535) { throw 'MTU must be in the range 576..65535.' }
    $adapter = Get-NetAdapter -ErrorAction Stop | Where-Object { [int]$_.ifIndex -eq $InterfaceIndex } | Select-Object -First 1
    if (-not $adapter) { throw ("Network interface index {0} was not found." -f $InterfaceIndex) }
    $name = [string]$adapter.Name
    $nameArg = Get-NetshInterfaceNameArgument -Name $name
    Invoke-NetworkNetshCommand -Arguments @('interface', 'ipv4', 'set', 'subinterface', $nameArg, ('mtu={0}' -f $Mtu), 'store=persistent')
    Write-Ok ("IPv4 MTU on '{0}' set to {1}." -f $name, $Mtu)
}

function Get-OptimalMtu {
    <# Binary-searches the largest non-fragmenting IPv4 ping payload from 1200 through 1472 bytes. #>
    [CmdletBinding()]
    param()
    if (-not $script:OnWindows) { throw 'mtu-check requires Windows and ping.exe.' }
    $pingCommand = Get-WindowsSystemToolPath -Name 'ping.exe'
    $low = 1200; $high = 1472; $best = 0; $probes = 0
    while ($low -le $high) {
        $payload = [int][Math]::Floor(($low + $high) / 2.0)
        $probeSucceeded = $false
        for ($attemptIndex = 0; $attemptIndex -lt 2; $attemptIndex++) {
            $null = & $pingCommand -n 1 -w 1000 -f -l $payload '1.1.1.1' 2>&1
            $probes++
            if ($LASTEXITCODE -eq 0) { $probeSucceeded = $true; break }
        }
        if ($probeSucceeded) {
            $best = $payload
            $low = $payload + 1
        } else {
            $high = $payload - 1
        }
    }
    $mtu = $null
    if ($best -gt 0) { $mtu = $best + 28 }
    return [pscustomobject]@{
        Target        = '1.1.1.1'
        MinPayload    = 1200
        MaxPayload    = 1472
        Payload       = $(if ($best -gt 0) { $best } else { $null })
        Mtu           = $mtu
        Probes        = $probes
        Reachable     = ($best -gt 0)
    }
}

function Restore-NetworkSnapshotFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SnapshotPath, [string]$LogDir = $script:LogDir)
    if (-not $script:OnWindows) { throw 'Network rollback requires Windows.' }
    Assert-Admin
    if (-not (Test-NetworkRollbackSnapshotPath -Path $SnapshotPath -LogDir $LogDir)) { throw 'Network rollback snapshot is outside logs or has an invalid name; restore cancelled.' }
    $file = Get-Item -LiteralPath $SnapshotPath -ErrorAction Stop
    if ($file.Length -gt 524288) { throw 'Network rollback snapshot is unexpectedly large; restore cancelled.' }
    try { $snapshot = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($SnapshotPath)) -ErrorAction Stop }
    catch { throw ("Network rollback snapshot is invalid JSON: {0}" -f $_.Exception.Message) }
    foreach ($requiredField in @('Version', 'Kind', 'Registry', 'Rss', 'InterfaceMtu')) {
        if ($null -eq $snapshot.PSObject.Properties[$requiredField]) { throw 'Network rollback snapshot has an unsupported format.' }
    }
    if ($snapshot.Version -ne 1 -or $snapshot.Kind -ne 'network' -or $null -eq $snapshot.Registry) { throw 'Network rollback snapshot has an unsupported format.' }

    $registryEntries = @($snapshot.Registry)
    if ($registryEntries.Count -gt 256) { throw 'Network rollback snapshot contains too many registry entries.' }
    foreach ($entry in $registryEntries) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['Exists'] -or $entry.Exists -isnot [bool]) { throw 'Network snapshot contains an incomplete registry entry.' }
        if (-not (Test-NetworkRegistrySnapshotEntry -Path ([string]$entry.Path) -Name ([string]$entry.Name))) { throw 'Network snapshot contains an unapproved registry path/value.' }
        if ([bool]$entry.Exists) {
            if (-not (Test-NetworkRegistrySnapshotKind -Kind ([string]$entry.Kind)) -or $null -eq $entry.PSObject.Properties['Value'] -or $null -eq $entry.Value) { throw 'Network snapshot contains an invalid registry value.' }
            [void](ConvertTo-NetworkRegistryRestoreValue -Value $entry.Value -Kind ([string]$entry.Kind))
        }
    }
    $rss = $null
    if ($null -ne $snapshot.Rss -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.Rss)) {
        $rss = ([string]$snapshot.Rss).ToLowerInvariant()
        if ($rss -notin @('enabled', 'disabled')) { throw 'Network snapshot contains an invalid RSS state.' }
    }
    if ($registryEntries.Count -eq 0 -and -not $rss -and $null -eq $snapshot.InterfaceMtu) { throw 'Network rollback snapshot contains no restorable values.' }
    $mtuData = $null
    if ($null -ne $snapshot.InterfaceMtu) {
        $guid = [Guid]::Empty; $mtu = 0; $savedIndex = 0
        if (-not [Guid]::TryParse([string]$snapshot.InterfaceMtu.InterfaceGuid, [ref]$guid) -or
            -not [int]::TryParse([string]$snapshot.InterfaceMtu.PreviousMtu, [ref]$mtu) -or $mtu -lt 576 -or $mtu -gt 65535 -or
            -not [int]::TryParse([string]$snapshot.InterfaceMtu.InterfaceIndex, [ref]$savedIndex) -or $savedIndex -lt 1 -or $savedIndex -gt 65535) {
            throw 'Network snapshot contains invalid MTU rollback data.'
        }
        $mtuData = [pscustomobject]@{ InterfaceGuid = $guid; PreviousMtu = $mtu }
    }

    $errors = @(); $restored = @()
    foreach ($entry in $registryEntries) {
        try {
            if ([bool]$entry.Exists) {
                $value = ConvertTo-NetworkRegistryRestoreValue -Value $entry.Value -Kind ([string]$entry.Kind)
                New-ItemProperty -LiteralPath ([string]$entry.Path) -Name ([string]$entry.Name) -Value $value -PropertyType ([string]$entry.Kind) -Force -ErrorAction Stop | Out-Null
            } else {
                if (Test-Path -LiteralPath ([string]$entry.Path)) {
                    Remove-ItemProperty -LiteralPath ([string]$entry.Path) -Name ([string]$entry.Name) -Force -ErrorAction SilentlyContinue
                }
            }
            $restored += ([string]$entry.Name)
        } catch { $errors += ("{0}: {1}" -f $entry.Name, $_.Exception.Message) }
    }
    if ($rss) {
        try {
            Invoke-NetworkNetshCommand -Arguments @('interface', 'tcp', 'set', 'global', ('rss={0}' -f $rss))
            $restored += ('RSS ' + $rss)
        } catch { $errors += $_.Exception.Message }
    }
    if ($mtuData) {
        try {
            $adapters = @(Get-NetAdapter -ErrorAction Stop)
            $adapter = @($adapters | Where-Object {
                $candidateGuid = [Guid]::Empty
                [Guid]::TryParse([string]$_.InterfaceGuid, [ref]$candidateGuid) -and $candidateGuid -eq $mtuData.InterfaceGuid
            } | Select-Object -First 1)
            if ($adapter.Count -eq 0) { throw 'MTU rollback interface is no longer present.' }
            Set-NetworkInterfaceMtu -InterfaceIndex ([int]$adapter[0].ifIndex) -Mtu $mtuData.PreviousMtu
            $restored += ('MTU ' + $mtuData.PreviousMtu)
        } catch { $errors += $_.Exception.Message }
    }
    if ($errors.Count -gt 0) {
        Write-Warn2 ("Network rollback partially failed: {0}" -f ($errors -join '; '))
        return $false
    }
    Write-Ok ("Network settings restored: {0}" -f ($restored -join ', '))
    Write-Info2 ("Snapshot: {0}" -f $SnapshotPath)
    $archivePath = $SnapshotPath + '.restored'
    $archiveSuffix = 0
    while (Test-Path -LiteralPath $archivePath) {
        $archiveSuffix++
        $archivePath = $SnapshotPath + ('.restored-{0}' -f $archiveSuffix)
    }
    try { Move-Item -LiteralPath $SnapshotPath -Destination $archivePath -ErrorAction Stop }
    catch { Write-Warn2 ("Network settings were restored, but the snapshot could not be archived: {0}" -f $_.Exception.Message) }
    Write-Log ("Network rollback restored from {0}" -f $SnapshotPath)
    return $true
}

function Restore-NetworkRollbackSnapshot {
    [CmdletBinding()]
    param([string]$LogDir = $script:LogDir)
    if (-not $script:OnWindows) { throw 'Network rollback requires Windows.' }
    Assert-Admin
    $snapshotPath = Get-LatestNetworkRollbackSnapshotPath -LogDir $LogDir
    if (-not $snapshotPath) {
        Write-Info2 'No network rollback snapshot was found.'
        return $false
    }
    return (Restore-NetworkSnapshotFile -SnapshotPath $snapshotPath -LogDir $LogDir)
}

function Invoke-NetworkOptimize {
    <# Saves a timestamped rollback snapshot, applies latency tweaks, or previews/restores the latest snapshot. #>
    [CmdletBinding()]
    param([switch]$Revert, [switch]$Preview, [string]$LogDir = $script:LogDir)
    if (-not $script:OnWindows) { throw 'net-optimize requires Windows.' }
    if ($Revert) {
        if ($Preview) {
            $snapshotPath = Get-LatestNetworkRollbackSnapshotPath -LogDir $LogDir
            if (-not $snapshotPath) { Write-PreviewInfo 'Preview: no network rollback snapshot exists; nothing to restore.'; return $false }
            if (-not (Test-NetworkRollbackSnapshotPath -Path $snapshotPath -LogDir $LogDir)) { throw 'Network rollback snapshot is outside logs; preview cancelled.' }
            $file = Get-Item -LiteralPath $snapshotPath -ErrorAction Stop
            if ($file.Length -gt 1048576) { throw 'Network rollback snapshot is unexpectedly large; preview cancelled.' }
            $snapshot = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($snapshotPath)) -ErrorAction Stop
            if ($snapshot.Version -ne 1 -or $snapshot.Kind -ne 'network') { throw 'Network rollback snapshot has an unsupported format.' }
            foreach ($entry in @($snapshot.Registry)) { Write-PreviewInfo ("Preview rollback registry: {0}\\{1} <- {2}" -f $entry.Path, $entry.Name, $(if ($entry.Exists) { $entry.Value } else { '<not set>' })) }
            if ($snapshot.Rss) { Write-PreviewInfo ("Preview rollback RSS: {0}" -f $snapshot.Rss) }
            if ($snapshot.InterfaceMtu) { Write-PreviewInfo ("Preview rollback MTU: interface {0} -> {1}" -f $snapshot.InterfaceMtu.InterfaceGuid, $snapshot.InterfaceMtu.PreviousMtu) }
            Write-PreviewInfo ("No changes made. Applying the restore requires administrator rights; snapshot source: {0}." -f $snapshotPath)
            return [pscustomobject]@{ Preview = $true; SnapshotPath = $snapshotPath; RegistryChanges = @($snapshot.Registry); RssTarget = $snapshot.Rss; InterfaceMtuTarget = $snapshot.InterfaceMtu; RequiresAdministrator = $true; ReapplyCommand = 'zapret.ps1 net-optimize' }
        }
        Assert-Admin
        return (Restore-NetworkRollbackSnapshot -LogDir $LogDir)
    }

    $interfaces = @(Get-UpPhysicalIPv4Interfaces)
    if ($interfaces.Count -eq 0) { throw 'No active physical IPv4 adapters found; network settings were not changed.' }
    $registryValues = @()
    foreach ($iface in $interfaces) {
        $guid = [Guid]::Empty
        if (-not [Guid]::TryParse([string]$iface.InterfaceGuid, [ref]$guid)) { continue }
        $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{0}' -f $guid.ToString('B')
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $registryValues += Get-NetworkRegistryValueSnapshot -Path $path -Name 'TcpAckFrequency'
        $registryValues += Get-NetworkRegistryValueSnapshot -Path $path -Name 'TCPNoDelay'
    }
    if ($registryValues.Count -eq 0) { throw 'No valid active adapter GUID registry keys found; network settings were not changed.' }
    $profilePath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    $registryValues += Get-NetworkRegistryValueSnapshot -Path $profilePath -Name 'NetworkThrottlingIndex'
    $registryValues += Get-NetworkRegistryValueSnapshot -Path $profilePath -Name 'SystemResponsiveness'
    $rssState = Get-RssGlobalState
    $targets = @{ TcpAckFrequency = '1'; TCPNoDelay = '1'; NetworkThrottlingIndex = '0xffffffff'; SystemResponsiveness = '10' }
    if ($Preview) {
        Write-Host 'Network optimization preview (no changes applied):'
        $plannedRegistryChanges = @()
        foreach ($entry in $registryValues) {
            $current = if ($entry.Exists) { [string]$entry.Value } else { '<not set>' }
            $target = $targets[[string]$entry.Name]
            $plannedRegistryChanges += [pscustomobject]@{ Path = $entry.Path; Name = $entry.Name; Current = $current; Target = $target }
            Write-PreviewInfo ("{0}\\{1}: {2} -> {3}" -f $entry.Path, $entry.Name, $current, $target)
        }
        Write-PreviewInfo ("RSS global setting: {0} -> enabled." -f $rssState)
        Write-PreviewInfo 'Applying requires administrator rights; it first saves logs/rollback-net-*.json. Undo with zapret.ps1 net-optimize -Revert.'
        return [pscustomobject]@{ Preview = $true; Adapters = $interfaces.Count; RegistryChanges = @($plannedRegistryChanges); CurrentRss = $rssState; TargetRss = 'enabled'; RequiresAdministrator = $true; RollbackCommand = 'zapret.ps1 net-optimize -Revert' }
    }
    Write-Info2 'Applying network-optimization plan: TcpAckFrequency=1, TCPNoDelay=1, NetworkThrottlingIndex=0xffffffff, SystemResponsiveness=10, RSS=enabled.'
    foreach ($entry in $registryValues) {
        $current = if ($entry.Exists) { [string]$entry.Value } else { '<not set>' }
        Write-Info2 ("{0}\\{1}: {2} -> {3}" -f $entry.Path, $entry.Name, $current, $targets[[string]$entry.Name])
    }
    Write-Info2 'The rollback snapshot will be saved before the first setting is changed.'
    Assert-Admin
    $snapshotPath = New-NetworkRollbackSnapshot -Reason optimization -Registry $registryValues -Rss $rssState -LogDir $LogDir

    try {
        foreach ($iface in $interfaces) {
            $guid = [Guid]::Empty
            if (-not [Guid]::TryParse([string]$iface.InterfaceGuid, [ref]$guid)) { continue }
            $path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{0}' -f $guid.ToString('B')
            if (-not (Test-Path -LiteralPath $path)) { continue }
            Set-NetworkRegistryDword -Path $path -Name 'TcpAckFrequency' -Value 1
            Set-NetworkRegistryDword -Path $path -Name 'TCPNoDelay' -Value 1
        }
        # A signed DWORD of -1 is the registry representation of 0xffffffff.
        Set-NetworkRegistryDword -Path $profilePath -Name 'NetworkThrottlingIndex' -Value -1
        Set-NetworkRegistryDword -Path $profilePath -Name 'SystemResponsiveness' -Value 10
        Invoke-NetworkNetshCommand -Arguments @('interface', 'tcp', 'set', 'global', 'rss=enabled')
    } catch {
        $failure = $_.Exception.Message
        try { [void](Restore-NetworkSnapshotFile -SnapshotPath $snapshotPath -LogDir $LogDir) }
        catch { Write-Warn2 ("Automatic rollback also reported an error: {0}" -f $_.Exception.Message) }
        throw ("Network optimization failed; rollback was attempted. {0}" -f $failure)
    }
    Write-Ok 'Network optimization applied: TcpAckFrequency/TCPNoDelay, multimedia scheduling, RSS.'
    Write-Info2 ("Rollback snapshot: {0} (revert with: zapret.ps1 net-optimize -Revert)" -f $snapshotPath)
    Write-Log 'Network optimization applied'
    return [pscustomobject]@{ Applied = $true; SnapshotPath = $snapshotPath; Adapters = $interfaces.Count }
}

function Invoke-MtuCheck {
    [CmdletBinding()]
    param([switch]$NoPrompt, [switch]$Preview, [string]$LogDir = $script:LogDir)
    if (-not $script:OnWindows) { throw 'mtu-check requires Windows.' }
    $network = Get-DefaultIPv4Network
    $result = Get-OptimalMtu
    Write-Host ''
    Write-Host (Get-UiText -Russian ('   Активное подключение: {0} (MTU {1}, шлюз {2})' -f $network.InterfaceName, $network.Mtu, $network.Gateway) -English ('   Active connection: {0} (MTU {1}, gateway {2})' -f $network.InterfaceName, $network.Mtu, $network.Gateway)) -ForegroundColor Cyan
    if (-not $result.Reachable) {
        if ($Preview) { Write-PreviewInfo 'Preview: no non-fragmenting reply was received for payloads 1200..1472; no MTU change is planned.' }
        else { Write-Warn2 'No non-fragmenting reply was received for payloads 1200..1472; MTU was not changed.' }
        return [pscustomobject]@{ CurrentMtu = $network.Mtu; RecommendedMtu = $null; Applied = $false; Preview = [bool]$Preview; RequiresAdministrator = $false }
    }
    if ($Preview) { Write-PreviewInfo ("Measured maximum non-fragmenting payload: {0} bytes; proposed IPv4 MTU: {1} bytes." -f $result.Payload, $result.Mtu) }
    else { Write-Ok ("Maximum non-fragmenting payload: {0} bytes; recommended IPv4 MTU: {1} bytes." -f $result.Payload, $result.Mtu) }
    if ([int]$network.Mtu -eq [int]$result.Mtu) {
        if ($Preview) { Write-PreviewInfo 'Preview: current MTU already matches the measured value; no change is planned.' }
        else { Write-Info2 'Current MTU already matches the measured value.' }
        return [pscustomobject]@{ CurrentMtu = $network.Mtu; RecommendedMtu = $result.Mtu; Applied = $false; Preview = [bool]$Preview; RequiresAdministrator = $false }
    }
    if ($NoPrompt -or $Preview) {
        Write-PreviewInfo ("Preview: would set MTU {0} -> {1} on {2}. Applying requires administrator rights; it saves logs/rollback-net-*.json first. Undo with zapret.ps1 net-optimize -Revert." -f $network.Mtu, $result.Mtu, $network.InterfaceName)
        if ($NoPrompt -and -not $Preview) { Write-Info2 'Non-interactive mode: not applying MTU.' }
        return [pscustomobject]@{ CurrentMtu = $network.Mtu; RecommendedMtu = $result.Mtu; InterfaceName = $network.InterfaceName; InterfaceGuid = $network.InterfaceGuid; Applied = $false; Preview = [bool]$Preview; RequiresAdministrator = [bool]$Preview; RollbackCommand = 'zapret.ps1 net-optimize -Revert' }
    }
    $answer = $null
    try { $answer = Read-Host (Get-UiText -Russian ("Установить MTU {0} для подключения «{1}»? Сначала сохраню копию настроек. [д/н]" -f $result.Mtu, $network.InterfaceName) -English ("Set MTU {0} for '{1}'? Current settings will be backed up first. [y/N]" -f $result.Mtu, $network.InterfaceName)) } catch { }
    if (-not ($answer -and $answer.Trim() -match '^(?i:y|yes|д|да)$')) {
        Write-Info2 'MTU was not changed.'
        return [pscustomobject]@{ CurrentMtu = $network.Mtu; RecommendedMtu = $result.Mtu; Applied = $false }
    }
    Assert-Admin
    $mtuSnapshot = [pscustomobject]@{
        InterfaceGuid = $network.InterfaceGuid
        InterfaceIndex = [int]$network.InterfaceIndex
        PreviousMtu = [int]$network.Mtu
    }
    $snapshotPath = New-NetworkRollbackSnapshot -Reason mtu -InterfaceMtu $mtuSnapshot -LogDir $LogDir
    Write-Info2 ("MTU rollback snapshot: {0}" -f $snapshotPath)
    Set-NetworkInterfaceMtu -InterfaceIndex ([int]$network.InterfaceIndex) -Mtu ([int]$result.Mtu)
    return [pscustomobject]@{ CurrentMtu = $network.Mtu; RecommendedMtu = $result.Mtu; Applied = $true; SnapshotPath = $snapshotPath }
}

function Invoke-LineQualityTest {
    <# Ten ICMP samples to the active gateway, Cloudflare, and Discord. Read-only. #>
    [CmdletBinding()]
    param()
    if (-not $script:OnWindows) { throw 'ping-test requires Windows.' }
    $network = Get-DefaultIPv4Network
    $targets = @(
        [pscustomobject]@{ Label = 'Gateway'; Host = $network.Gateway; IsGateway = $true },
        [pscustomobject]@{ Label = '1.1.1.1'; Host = '1.1.1.1'; IsGateway = $false },
        [pscustomobject]@{ Label = 'discord.com'; Host = 'discord.com'; IsGateway = $false }
    )
    $rows = @()
    foreach ($target in $targets) {
        $samples = New-Object 'System.Collections.Generic.List[double]'
        $pinger = New-Object System.Net.NetworkInformation.Ping
        try {
            for ($sampleIndex = 0; $sampleIndex -lt 10; $sampleIndex++) {
                try {
                    $reply = $pinger.Send([string]$target.Host, 1000)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $samples.Add([double]$reply.RoundtripTime) }
                    else { $samples.Add([double]::NaN) }
                } catch { $samples.Add([double]::NaN) }
            }
        } finally { $pinger.Dispose() }
        $stats = Measure-PingStats -Samples ([double[]]$samples.ToArray())
        $rows += [pscustomobject]@{
            Target      = $target.Label
            Host        = $target.Host
            Min         = $stats.Min
            Avg         = $stats.Avg
            Max         = $stats.Max
            Jitter      = $stats.Jitter
            LossPercent = $stats.LossPercent
            Sent        = $stats.Sent
            Received    = $stats.Received
            IsGateway   = $target.IsGateway
        }
    }
    Write-Host ''
    Write-Host (Get-UiText -Russian ('   Качество соединения (по 10 проверок; шлюз {0})' -f $network.Gateway) -English ('   Connection quality (10 pings each; gateway {0})' -f $network.Gateway)) -ForegroundColor Cyan
    Write-HostTable -InputObject ($rows | Select-Object Target, Host, Sent, Received, Min, Avg, Max, Jitter, LossPercent)
    $gateway = $rows | Where-Object { $_.IsGateway } | Select-Object -First 1
    if ($gateway -and ([double]$gateway.LossPercent -gt 0 -or ($null -ne $gateway.Jitter -and [double]$gateway.Jitter -gt 10))) {
        Write-Warn2 'Потери или джиттер уже до шлюза: проверьте Wi-Fi (сигнал/помехи) или кабель/порт Ethernet.'
    }
    return $rows
}
