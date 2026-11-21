# ---------------------------------------------------------------------------
# DNS / DoH helpers (Russian ISPs poison plain DNS - encrypted DNS is often
# the difference between "nothing opens" and "bypass works")
# ---------------------------------------------------------------------------

function Get-DohProviderTable {
    param([string]$Provider)
    $table = [ordered]@{
        cloudflare = [pscustomobject]@{ Key = 'cloudflare'; Name = 'Cloudflare'; Primary = '1.1.1.1';      Secondary = '1.0.0.1';         Host = 'cloudflare-dns.com';   Template = 'https://cloudflare-dns.com/dns-query' }
        google     = [pscustomobject]@{ Key = 'google';     Name = 'Google';     Primary = '8.8.8.8';      Secondary = '8.8.4.4';         Host = 'dns.google';           Template = 'https://dns.google/dns-query' }
        quad9      = [pscustomobject]@{ Key = 'quad9';      Name = 'Quad9';      Primary = '9.9.9.9';      Secondary = '149.112.112.112'; Host = 'dns.quad9.net';        Template = 'https://dns.quad9.net/dns-query' }
        adguard    = [pscustomobject]@{ Key = 'adguard';    Name = 'AdGuard';    Primary = '94.140.14.14'; Secondary = '94.140.15.15';     Host = 'dns.adguard-dns.com';  Template = 'https://dns.adguard-dns.com/dns-query' }
        yandex     = [pscustomobject]@{ Key = 'yandex';     Name = 'Yandex';     Primary = '77.88.8.8';    Secondary = '77.88.8.1';       Host = 'common.dot.dns.yandex.net'; Template = 'https://common.dot.dns.yandex.net/dns-query' }
    }
    if ($Provider) {
        $key = $Provider.ToLowerInvariant()
        if ($table.Contains($key)) { return $table[$key] }
        return $null
    }
    return @($table.Values)
}

function Get-UpPhysicalIPv4Interfaces {
    try {
        return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    } catch {
        return @()
    }
}

function Get-DnsStatusReport {
    if (-not $script:OnWindows) { throw 'dns status requires Windows.' }
    $items = @()
    foreach ($iface in (Get-UpPhysicalIPv4Interfaces)) {
        $servers = @()
        $source  = 'unknown'
        try {
            $cfg = Get-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction Stop
            $servers = @($cfg.ServerAddresses)
        } catch { }
        try {
            $ipif = Get-NetIPInterface -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction Stop
            $source = [string]$ipif.Dhcp
        } catch { }
        $items += [pscustomobject]@{
            Interface  = $iface.Name
            IpPrefix   = [string]$iface.InterfaceDescription
            Servers    = ($servers -join ', ')
            DhcpStatus = $source
        }
    }
    return @($items)
}

function Write-DnsStatus {
    $report = Get-DnsStatusReport
    Write-Host ''
    Write-Host (Get-UiText -Russian '  НАСТРОЙКИ DNS (для сетевых адаптеров)' -English '  DNS SETTINGS (per network adapter)') -ForegroundColor Cyan
    Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
    if ($report.Count -eq 0) { Write-Host (Get-UiText -Russian '  Активные сетевые адаптеры не найдены.' -English '  No active network adapters were found.') -ForegroundColor Yellow; return }
    foreach ($r in $report) {
        Write-Host ('   {0,-24} {1}' -f $r.Interface, $r.IpPrefix) -ForegroundColor DarkGray
        $dnsMode = switch -Regex ([string]$r.DhcpStatus) {
            '^(DHCP|Enabled|True)$' { Get-UiText -Russian 'автоматически (DHCP)' -English 'automatic (DHCP)' }
            '^(Static|Disabled|False)$' { Get-UiText -Russian 'вручную' -English 'manual' }
            default { [string]$r.DhcpStatus }
        }
        $dnsServers = if ($r.Servers) { $r.Servers } else { Get-UiText -Russian 'не заданы' -English 'not set' }
        Write-Host (Get-UiText -Russian ('      DNS: {0}   ({1})' -f $dnsServers, $dnsMode) -English ('      DNS: {0}   ({1})' -f $dnsServers, $dnsMode))
    }
    Write-Host ''
    Write-Host (Get-UiText -Russian '  Если сайты не открываются даже при включённом обходе, причина может быть в DNS.' -English '  If sites still do not open while the bypass is running, DNS may be the cause.') -ForegroundColor DarkGray
    Write-Host (Get-UiText -Russian '  Попробуйте включить защищённый DNS (DoH):' -English '  Try enabling encrypted DNS (DoH):') -ForegroundColor DarkGray
    Write-Host '     zapret.ps1 dns doh <cloudflare|google|quad9|adguard|yandex>' -ForegroundColor DarkGray
    Write-Host (Get-UiText -Russian '  Отменить изменение: zapret.ps1 dns rollback; вернуть автоматический DNS: zapret.ps1 dns reset' -English '  Undo the change: zapret.ps1 dns rollback; restore automatic DNS: zapret.ps1 dns reset') -ForegroundColor DarkGray
    Write-Host ''
}

function Test-IPv4AddressText {
    # Pure strict dotted-decimal IPv4 validator used before putting an address into netsh arguments.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $parts = $Address.Split('.')
    if ($parts.Count -ne 4) { return $false }
    foreach ($part in $parts) {
        if ($part -notmatch '^(0|[1-9][0-9]{0,2})$') { return $false }
        $octet = 0
        if (-not [int]::TryParse($part, [ref]$octet) -or $octet -gt 255) { return $false }
    }
    return $true
}

function Save-DnsRollbackSnapshot {
    <# Saves DNS source and IPv4 server addresses for each active physical adapter. #>
    [CmdletBinding()]
    param([string]$LogDir = $script:LogDir)
    if (-not $script:OnWindows) { throw 'DNS rollback snapshots require Windows.' }
    if ([string]::IsNullOrWhiteSpace($LogDir)) { throw 'LogDir cannot be empty.' }
    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
        New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction Stop | Out-Null
    }
    $interfaces = @(Get-UpPhysicalIPv4Interfaces)
    if ($interfaces.Count -eq 0) { throw 'No active physical network adapters found; DNS changes were not made.' }

    $records = @()
    foreach ($iface in $interfaces) {
        $guid = [Guid]::Empty
        if (-not [Guid]::TryParse([string]$iface.InterfaceGuid, [ref]$guid)) { continue }
        $ifIndex = 0
        if (-not [int]::TryParse([string]$iface.ifIndex, [ref]$ifIndex) -or $ifIndex -lt 1) { continue }

        $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{0}' -f $guid.ToString('B')
        $nameServer = ''
        try {
            $reg = Get-ItemProperty -LiteralPath $registryPath -Name NameServer -ErrorAction SilentlyContinue
            if ($null -ne $reg -and $null -ne $reg.NameServer) { $nameServer = [string]$reg.NameServer }
        } catch { }

        $servers = @()
        try {
            $dnsConfig = Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $dnsConfig) { $servers = @($dnsConfig.ServerAddresses | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
        } catch { }
        if ($servers.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($nameServer)) {
            $servers = @($nameServer -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $validServers = @()
        foreach ($server in $servers) {
            if (Test-IPv4AddressText -Address $server) { $validServers += $server.Trim() }
        }
        $source = 'dhcp'
        if (-not [string]::IsNullOrWhiteSpace($nameServer) -and $validServers.Count -gt 0) { $source = 'static' }
        if ($source -eq 'static' -and $validServers.Count -gt 16) { throw 'An adapter has an unexpected number of DNS servers; snapshot aborted.' }
        $records += [pscustomobject]@{
            InterfaceGuid   = $guid.ToString('B')
            InterfaceIndex  = $ifIndex
            Source          = $source
            ServerAddresses = @($validServers)
        }
    }
    if ($records.Count -eq 0) { throw 'Could not identify active adapter GUIDs; DNS changes were not made.' }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $path = Join-Path $LogDir ("rollback-dns-{0}.json" -f $stamp)
    $suffix = 0
    while (Test-Path -LiteralPath $path) {
        $suffix++
        $path = Join-Path $LogDir ("rollback-dns-{0}-{1}.json" -f $stamp, $suffix)
    }
    $snapshot = [ordered]@{
        Version   = 1
        Kind      = 'dns'
        CreatedAt = (Get-Date -Format 's')
        Adapters  = @($records)
    }
    $json = ConvertTo-Json -InputObject $snapshot -Depth 6
    $tempPath = $path + '.tmp'
    try {
        [IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $path -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw ("Could not write the DNS rollback snapshot: {0}" -f $_.Exception.Message)
    }
    Write-Log ("DNS rollback snapshot saved: {0}" -f $path)
    return $path
}

function Test-DnsRollbackSnapshotPath {
    # Pure containment check: only timestamped direct children of logs are restorable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LogDir
    )
    try {
        $logFull = [IO.Path]::GetFullPath($LogDir).TrimEnd('\', '/')
        $fileFull = [IO.Path]::GetFullPath($Path)
        if (-not [string]::Equals((Split-Path -Parent $fileFull).TrimEnd('\', '/'), $logFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        return ((Split-Path -Leaf $fileFull) -match '^rollback-dns-\d{8}-\d{9}(?:-\d+)?\.json$')
    } catch { return $false }
}

function Get-LatestDnsRollbackSnapshotPath {
    [CmdletBinding()]
    param([string]$LogDir = $script:LogDir)
    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { return $null }
    $file = Get-ChildItem -LiteralPath $LogDir -File -Filter 'rollback-dns-*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^rollback-dns-\d{8}-\d{9}(?:-\d+)?\.json$' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($file) { return $file.FullName }
    return $null
}

function Get-NetshInterfaceNameArgument {
    # Returns a single netsh argv token. No embedded quotes on purpose: Windows
    # PowerShell 5.1 does not escape quotes inside native arguments, so
    # name="Ethernet 2" would arrive broken at netsh; name=Ethernet 2 (one argv
    # element) is correct under both PS 5.1 and PowerShell 7.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '["`\x00-\x1f]') { throw 'The network interface name contains unsupported characters.' }
    return ('name={0}' -f $Name)
}

function Invoke-DnsNetshCommand {
    # Arguments are passed as separate native arguments; only fixed verbs and validated IPs reach netsh.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    if (-not $script:OnWindows) { throw 'DNS netsh operations require Windows.' }
    Assert-Admin
    $netsh = Get-WindowsSystemToolPath -Name 'netsh.exe'
    $output = & $netsh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ("netsh DNS command failed (exit {0}): {1}" -f $exitCode, (($output | Out-String).Trim()))
    }
}

function Restore-DnsRollbackSnapshot {
    [CmdletBinding()]
    param([string]$LogDir = $script:LogDir, [switch]$Preview)
    if (-not $script:OnWindows) { throw 'DNS rollback requires Windows.' }
    $snapshotPath = Get-LatestDnsRollbackSnapshotPath -LogDir $LogDir
    if (-not $snapshotPath) {
        if ($Preview) { Write-PreviewInfo 'Preview: no DNS rollback snapshot was found; nothing to restore.' }
        else { Write-Info2 'No DNS rollback snapshot was found.' }
        return $false
    }
    if (-not (Test-DnsRollbackSnapshotPath -Path $snapshotPath -LogDir $LogDir)) { throw 'DNS rollback snapshot is outside the logs directory; restore cancelled.' }
    $file = Get-Item -LiteralPath $snapshotPath -ErrorAction Stop
    if ($file.Length -gt 262144) { throw 'DNS rollback snapshot is unexpectedly large; restore cancelled.' }
    try { $snapshot = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($snapshotPath)) -ErrorAction Stop }
    catch { throw ("DNS rollback snapshot is invalid JSON: {0}" -f $_.Exception.Message) }
    if ($snapshot.Version -ne 1 -or $snapshot.Kind -ne 'dns' -or $null -eq $snapshot.Adapters) {
        throw 'DNS rollback snapshot has an unsupported format.'
    }
    $adapterEntries = @($snapshot.Adapters)
    if ($adapterEntries.Count -lt 1 -or $adapterEntries.Count -gt 256) { throw 'DNS rollback snapshot has an invalid adapter count.' }
    $seenAdapterGuids = @{}
    foreach ($entry in $adapterEntries) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['InterfaceGuid'] -or $null -eq $entry.PSObject.Properties['Source'] -or $null -eq $entry.PSObject.Properties['ServerAddresses']) {
            throw 'DNS rollback snapshot contains an incomplete adapter entry.'
        }
        $entryGuid = [Guid]::Empty
        if (-not [Guid]::TryParse([string]$entry.InterfaceGuid, [ref]$entryGuid)) { throw 'Invalid adapter GUID in snapshot.' }
        $guidKey = $entryGuid.ToString('D')
        if ($seenAdapterGuids.ContainsKey($guidKey)) { throw 'DNS rollback snapshot contains a duplicate adapter.' }
        $seenAdapterGuids[$guidKey] = $true
        $source = ([string]$entry.Source).ToLowerInvariant()
        $entryServers = @($entry.ServerAddresses | ForEach-Object { [string]$_ })
        if ($source -eq 'static') {
            if ($entryServers.Count -lt 1 -or $entryServers.Count -gt 16) { throw 'Invalid static DNS server list in snapshot.' }
        } elseif ($source -eq 'dhcp') {
            if ($entryServers.Count -gt 16) { throw 'Invalid DNS server list in snapshot.' }
        } else { throw 'Invalid DNS source in snapshot.' }
        foreach ($server in $entryServers) { if (-not (Test-IPv4AddressText -Address $server)) { throw 'Invalid IPv4 DNS server in snapshot.' } }
    }

    if ($Preview) {
        $previewAdapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
        $previewChanges = @()
        foreach ($entry in $adapterEntries) {
            $guid = [Guid]::Empty
            if (-not [Guid]::TryParse([string]$entry.InterfaceGuid, [ref]$guid)) { continue }
            $adapter = @($previewAdapters | Where-Object {
                $candidateGuid = [Guid]::Empty
                [Guid]::TryParse([string]$_.InterfaceGuid, [ref]$candidateGuid) -and $candidateGuid -eq $guid
            } | Select-Object -First 1)
            if ($adapter.Count -eq 0) {
                Write-PreviewInfo ("Warning: adapter {0} is absent; this saved entry cannot be restored." -f $guid.ToString('B'))
                continue
            }
            $currentServers = @()
            try { $currentServers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter[0].ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch { }
            $target = if ([string]$entry.Source -eq 'dhcp') { 'DHCP/automatic' } else { $entry.ServerAddresses -join ', ' }
            $previewChanges += [pscustomobject]@{ InterfaceIndex = $adapter[0].ifIndex; InterfaceName = $adapter[0].Name; CurrentServers = @($currentServers); TargetSource = [string]$entry.Source; TargetServers = @($entry.ServerAddresses) }
            Write-PreviewInfo ("Preview DNS rollback: {0}: [{1}] -> [{2}]" -f $adapter[0].Name, ($currentServers -join ', '), $target)
        }
        Write-PreviewInfo ("No changes made. Applying requires administrator rights; snapshot: {0}; rollback command: zapret.ps1 dns rollback." -f $snapshotPath)
        return [pscustomobject]@{ Preview = $true; SnapshotPath = $snapshotPath; AdapterCount = $adapterEntries.Count; AdapterChanges = @($previewChanges); RequiresAdministrator = $true; RollbackCommand = 'zapret.ps1 dns rollback' }
    }
    Assert-Admin
    $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop)
    $restored = 0
    $errors = @()
    foreach ($entry in $adapterEntries) {
        try {
            $guid = [Guid]::Empty
            if (-not [Guid]::TryParse([string]$entry.InterfaceGuid, [ref]$guid)) { throw 'Invalid adapter GUID in snapshot.' }
            $adapter = @($adapters | Where-Object {
                $candidateGuid = [Guid]::Empty
                [Guid]::TryParse([string]$_.InterfaceGuid, [ref]$candidateGuid) -and $candidateGuid -eq $guid
            } | Select-Object -First 1)
            if ($adapter.Count -eq 0) { throw ("Adapter {0} is no longer present." -f $guid.ToString('B')) }
            $name = [string]$adapter[0].Name
            $nameArg = Get-NetshInterfaceNameArgument -Name $name
            $source = ([string]$entry.Source).ToLowerInvariant()
            if ($source -eq 'dhcp') {
                Invoke-DnsNetshCommand -Arguments @('interface', 'ipv4', 'set', 'dnsservers', $nameArg, 'source=dhcp', 'validate=no')
            } elseif ($source -eq 'static') {
                $servers = @($entry.ServerAddresses | ForEach-Object { [string]$_ })
                if ($servers.Count -lt 1 -or $servers.Count -gt 16) { throw 'Invalid static DNS server list in snapshot.' }
                foreach ($server in $servers) { if (-not (Test-IPv4AddressText -Address $server)) { throw 'Invalid IPv4 DNS server in snapshot.' } }
                Invoke-DnsNetshCommand -Arguments @('interface', 'ipv4', 'set', 'dnsservers', $nameArg, 'static', $servers[0], 'primary', 'validate=no')
                for ($index = 1; $index -lt $servers.Count; $index++) {
                    $dnsIndex = $index + 1
                    Invoke-DnsNetshCommand -Arguments @('interface', 'ipv4', 'add', 'dnsservers', $nameArg, $servers[$index], ('index={0}' -f $dnsIndex), 'validate=no')
                }
            } else { throw 'Invalid DNS source in snapshot.' }
            $restored++
        } catch {
            $errors += $_.Exception.Message
        }
    }
    if ($errors.Count -gt 0) {
        Write-Warn2 ("DNS rollback partially failed ({0}/{1} adapters restored): {2}" -f $restored, $adapterEntries.Count, ($errors -join '; '))
        return $false
    }
    Write-Ok ("DNS settings restored on {0} adapter(s)." -f $restored)
    Write-Info2 ("Snapshot: {0}" -f $snapshotPath)
    $archivePath = $snapshotPath + '.restored'
    $archiveSuffix = 0
    while (Test-Path -LiteralPath $archivePath) {
        $archiveSuffix++
        $archivePath = $snapshotPath + ('.restored-{0}' -f $archiveSuffix)
    }
    try { Move-Item -LiteralPath $snapshotPath -Destination $archivePath -ErrorAction Stop }
    catch { Write-Warn2 ("DNS was restored, but the snapshot could not be archived: {0}" -f $_.Exception.Message) }
    Write-Log ("DNS rollback restored from {0}" -f $snapshotPath)
    return $true
}


function Enable-Doh {
    <#
        Registers the chosen DoH template with the OS (Windows 11) and points
        all active physical IPv4 adapters at the provider's plain servers
        (UDP fallback allowed, encrypted upgrade preferred).
        This is a deliberate, reversible change - use 'dns rollback' to restore the previous DNS setup.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('cloudflare', 'google', 'quad9', 'adguard', 'yandex')]
        [string]$Provider,
        [switch]$Preview
    )
    if (-not $script:OnWindows) { throw 'dns doh requires Windows.' }
    if ($Preview) {
        $previewProvider = Get-DohProviderTable -Provider $Provider
        $previewInterfaces = @(Get-UpPhysicalIPv4Interfaces)
        if ($previewInterfaces.Count -eq 0) { throw 'No active physical network adapters found; DNS was not changed.' }
        Write-Host ("DNS preview: provider {0}; set IPv4 DNS to {1}, {2}; DoH template: {3}." -f $previewProvider.Name, $previewProvider.Primary, $previewProvider.Secondary, $previewProvider.Template)
        $adapterChanges = @()
        foreach ($iface in $previewInterfaces) {
            $currentServers = @()
            try { $currentServers = @((Get-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch { }
            $adapterChanges += [pscustomobject]@{ InterfaceIndex = $iface.ifIndex; InterfaceName = $iface.Name; CurrentServers = @($currentServers); TargetServers = @($previewProvider.Primary, $previewProvider.Secondary) }
            Write-PreviewInfo ("{0}: [{1}] -> [{2}, {3}]" -f $iface.Name, ($currentServers -join ', '), $previewProvider.Primary, $previewProvider.Secondary)
        }
        Write-PreviewInfo ("System change: register DoH template '{0}' for {1} and {2}; enable automatic upgrade with UDP fallback." -f $previewProvider.Template, $previewProvider.Primary, $previewProvider.Secondary)
        Write-PreviewInfo 'Preview does not probe the provider or register DoH. Applying requires administrator rights and saves a rollback-dns snapshot; undo with zapret.ps1 dns rollback.'
        return [pscustomobject]@{ Preview = $true; Provider = $previewProvider.Key; Primary = $previewProvider.Primary; Secondary = $previewProvider.Secondary; Template = $previewProvider.Template; AdapterCount = $previewInterfaces.Count; AdapterChanges = @($adapterChanges); DoHTemplateServers = @($previewProvider.Primary, $previewProvider.Secondary); RequiresAdministrator = $true; RollbackCommand = 'zapret.ps1 dns rollback' }
    }
    Assert-Admin

    # 0) Probe the provider first - some ISPs block the DoH endpoint itself while
    #    letting plain DNS through. Fall back to a provider that answers.
    $probe = Test-DohProviderAvailable -Provider $Provider
    if ($probe.Reachable -eq $false) {
        Write-Warn2 ("DoH provider '{0}' is not reachable ({1}) - your ISP may be blocking it." -f $Provider, $probe.Detail)
        $fallback = $null
        foreach ($alt in @('google', 'quad9', 'cloudflare', 'adguard', 'yandex')) {
            if ($alt -eq $Provider) { continue }
            Write-Info2 ("Probing fallback provider: {0} ..." -f $alt)
            $altProbe = Test-DohProviderAvailable -Provider $alt
            if ($altProbe.Reachable -ne $false) { $fallback = $alt; break }
        }
        if ($fallback) {
            $switch = $false
            if (Get-ZapretNonInteractive) {
                $switch = $true
                Write-Info2 ("No console input - switching to the reachable fallback '{0}'." -f $fallback)
            } else {
                try {
                    $answer = Read-Host (ConvertTo-UiMessage -Text ("Switch to '$fallback' instead? [Y/n]"))
                    $switch = [string]::IsNullOrWhiteSpace($answer) -or ($answer.Trim() -match '^(y|yes|д|да)$')
                } catch {
                    Write-Info2 ("No console input available - keeping '{0}'. Run 'dns doh {1}' to switch manually." -f $Provider, $fallback)
                }
            }
            if ($switch) {
                Write-Ok ("Switching to fallback provider: {0}" -f $fallback)
                $Provider = $fallback
            }
        } else {
            Write-Warn2 'No DoH provider answers (cloudflare, google, quad9, adguard, yandex) - your ISP appears to block DoH entirely.'
            Write-Info2 'Enable Secure DNS in the browser (Chrome/Edge/Firefox) - that bypasses filtering at the browser level.'
            throw 'DoH probe failed for all providers (cloudflare, google, quad9, adguard, yandex).'
        }
    } elseif ($null -eq $probe.Reachable) {
        Write-Warn2 ("Could not probe the DoH endpoint ({0}) - continuing with '{1}'." -f $probe.Detail, $Provider)
    } else {
        Write-Info2 ("DoH provider '{0}' answered ({1})." -f $Provider, $probe.Detail)
    }

    $p = Get-DohProviderTable -Provider $Provider
    $interfaces = @(Get-UpPhysicalIPv4Interfaces)
    if ($interfaces.Count -eq 0) { throw 'No active physical network adapters found; DNS was not changed.' }
    Write-Info2 ("Applying DNS plan for {0}: set {1} and {2}; register DoH template {3}." -f $p.Name, $p.Primary, $p.Secondary, $p.Template)
    foreach ($iface in $interfaces) {
        $currentServers = @()
        try { $currentServers = @((Get-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch { }
        Write-Info2 ("{0}: [{1}] -> [{2}, {3}]" -f $iface.Name, ($currentServers -join ', '), $p.Primary, $p.Secondary)
    }
    $dnsSnapshotPath = Save-DnsRollbackSnapshot
    Write-Info2 ("Предыдущие DNS-настройки сохранены: {0}" -f $dnsSnapshotPath)

    # 1) Register DoH templates (Windows 11 / Server 2022+; best effort elsewhere)
    $dohRegistered = $false
    $netshPath = Get-WindowsSystemToolPath -Name 'netsh.exe'
    foreach ($ip in @($p.Primary, $p.Secondary)) {
        $registrationError = $null
        try {
            Invoke-DnsNetshCommand -Arguments @('dns', 'add', 'encryption', ("server={0}" -f $ip), ("dohtemplate={0}" -f $p.Template), 'autoupgrade=yes', 'udpfallback=yes')
        } catch { $registrationError = $_.Exception.Message }
        try {
            # Query even after a failed add: the exact mapping may already exist.
            $check = (& $netshPath dns show encryption ("server={0}" -f $ip) 2>&1 | Out-String)
            $showExitCode = $LASTEXITCODE
            Write-Log ("netsh dns show encryption ${ip} (exit {0}): {1}" -f $showExitCode, $check.Trim())
            if ($showExitCode -eq 0 -and $check -match [regex]::Escape($p.Template)) { $dohRegistered = $true }
            elseif ($registrationError) { Write-Log ("DoH template registration failed for {0}: {1}" -f $ip, $registrationError) 'WARN' }
        } catch {
            $showError = $_.Exception.Message
            if ($registrationError) { $showError = $registrationError + '; ' + $showError }
            Write-Log ("DoH template verification failed for {0}: {1}" -f $ip, $showError) 'WARN'
        }
    }

    # 2) Point adapters at the provider (keeps DHCP for addresses themselves)
    $applied = 0; $failed = @()
    foreach ($iface in $interfaces) {
        try {
            $nameArg = Get-NetshInterfaceNameArgument -Name ([string]$iface.Name)
            Invoke-DnsNetshCommand -Arguments @('interface', 'ipv4', 'set', 'dnsservers', $nameArg, 'static', $p.Primary, 'primary', 'validate=no')
            Invoke-DnsNetshCommand -Arguments @('interface', 'ipv4', 'add', 'dnsservers', $nameArg, $p.Secondary, 'index=2', 'validate=no')
            Start-Sleep -Milliseconds 300
            # Read-back verification (locale-independent, includes both configured servers).
            $now = @((Get-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
            if (($now -contains $p.Primary) -and ($now -contains $p.Secondary)) { $applied++ }
            else { $failed += $iface.Name }
        } catch {
            $failed += $iface.Name
            Write-Log ("DoH DNS configuration failed for adapter '{0}': {1}" -f $iface.Name, $_.Exception.Message) 'WARN'
        }
    }

    Write-Host ''
    Write-Ok ("DNS for '{0}' applied to {1} of {2} adapter(s): {3} / {4}" -f $p.Name, $applied, $interfaces.Count, $p.Primary, $p.Secondary)
    if ($failed.Count -gt 0) { Write-Warn2 ("Could not set DNS on: {0}" -f ($failed -join ', ')) }
    if ($dohRegistered) {
        Write-Ok 'DoH template registered in the OS (encrypted upgrade preferred).'
    } else {
        Write-Warn2 'This OS did not register the DoH template automatically (Windows 11 is required for system DoH).'
        Write-Info2 'Enable DoH in the browser as well (Chrome/Edge/Firefox) - that alone bypasses DNS poisoning.'
    }
    Write-Info2 'Restore previous DNS with: zapret.ps1 dns rollback; use dns reset to switch to DHCP.'
    Write-Log "DoH setup for '$Provider': $applied/$($interfaces.Count) adapters OK"
}

function Reset-DnsToDhcp {
    [CmdletBinding()]
    param([switch]$Preview)
    if (-not $script:OnWindows) { throw 'dns reset requires Windows.' }
    $interfaces = @(Get-UpPhysicalIPv4Interfaces)
    if ($interfaces.Count -eq 0) { throw 'No active physical network adapters found.' }
    if ($Preview) {
        $adapterChanges = @()
        foreach ($iface in $interfaces) {
            $currentServers = @()
            try { $currentServers = @((Get-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch { }
            $adapterChanges += [pscustomobject]@{ InterfaceIndex = $iface.ifIndex; InterfaceName = $iface.Name; CurrentServers = @($currentServers); TargetSource = 'DHCP/automatic' }
            Write-PreviewInfo ("DNS reset preview: {0}: [{1}] -> [DHCP/automatic]" -f $iface.Name, ($currentServers -join ', '))
        }
        Write-PreviewInfo 'No changes made. Applying requires administrator rights and first saves rollback-dns-*.json; restore with zapret.ps1 dns rollback.'
        return [pscustomobject]@{ Preview = $true; AdapterCount = $interfaces.Count; AdapterChanges = @($adapterChanges); RequiresAdministrator = $true; RollbackCommand = 'zapret.ps1 dns rollback' }
    }
    Assert-Admin
    foreach ($iface in $interfaces) {
        $currentServers = @()
        try { $currentServers = @((Get-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch { }
        Write-Info2 ("Applying DNS reset plan: {0}: [{1}] -> [DHCP/automatic]." -f $iface.Name, ($currentServers -join ', '))
    }
    $dnsSnapshotPath = Save-DnsRollbackSnapshot
    Write-Info2 ("DNS rollback snapshot saved: {0}" -f $dnsSnapshotPath)
    $failed = @()
    foreach ($iface in $interfaces) {
        try {
            $nameArg = Get-NetshInterfaceNameArgument -Name ([string]$iface.Name)
            Invoke-DnsNetshCommand -Arguments @('interface', 'ipv4', 'set', 'dnsservers', $nameArg, 'source=dhcp', 'validate=no')
        } catch {
            $failed += ("{0}: {1}" -f $iface.Name, $_.Exception.Message)
        }
    }
    if ($failed.Count -gt 0) { throw ("DNS reset failed on {0} adapter(s): {1}. Restore previous DNS with zapret.ps1 dns rollback." -f $failed.Count, ($failed -join '; ')) }
    Write-Ok 'DNS on all active adapters returned to automatic (DHCP).'
    Write-Info2 ("Previous DNS snapshot: {0}; restore with zapret.ps1 dns rollback." -f $dnsSnapshotPath)
    Write-Log 'DNS reset to DHCP'
    return [pscustomobject]@{ Applied = $true; SnapshotPath = $dnsSnapshotPath; AdapterCount = $interfaces.Count }
}
