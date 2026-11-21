# ---------------------------------------------------------------------------
# Diagnostics ("doctor")
# ---------------------------------------------------------------------------

function Get-SystemTimeSkewSeconds {
    # Pure comparison helper; positive means the local clock is ahead.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$LocalTime,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ReferenceTime
    )
    return [int][Math]::Round(($LocalTime.ToUniversalTime() - $ReferenceTime.ToUniversalTime()).TotalSeconds, [MidpointRounding]::AwayFromZero)
}

function Get-HttpsServerDate {
    # Fetch the HTTPS Date header with a strict connection/request timeout.
    [CmdletBinding()]
    param(
        [string]$Url = 'https://gstatic.com',
        [ValidateRange(1,10)][int]$TimeoutSec = 3
    )
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'HEAD'
    $request.AllowAutoRedirect = $true
    $request.MaximumAutomaticRedirections = 3
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.UserAgent = 'zapret-discord-youtube-diagnostics'
    $response = $null
    $dateText = $null
    try {
        $response = $request.GetResponse()
        $dateText = [string]$response.Headers['Date']
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $response = $_.Exception.Response
            $dateText = [string]$response.Headers['Date']
        }
    } finally {
        if ($response) { $response.Close() }
    }
    $serverDate = [DateTimeOffset]::MinValue
    if ([string]::IsNullOrWhiteSpace($dateText) -or -not [DateTimeOffset]::TryParse($dateText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$serverDate)) {
        return $null
    }
    return $serverDate.ToUniversalTime()
}

function Select-GlobalIPv6Addresses {
    # Pure filter so the address-selection rules remain testable off Windows.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Addresses = @())
    $seen = @{}
    foreach ($entry in $Addresses) {
        if ($null -eq $entry -or [string]$entry.AddressState -ne 'Preferred') { continue }
        $addressText = ([string]$entry.IPAddress).Trim()
        if (-not $addressText -or $addressText -match '^(?i:fe80:)' -or $addressText -eq '::1') { continue }
        $parsedAddress = $null
        if (-not [System.Net.IPAddress]::TryParse($addressText, [ref]$parsedAddress)) { continue }
        if ($parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { continue }
        $seen[$addressText] = $true
    }
    return @($seen.Keys | Sort-Object)
}

function Test-HvciDriverWarningCondition {
    # Pure condition used by diagnostics; Enabled is read only on Windows.
    [CmdletBinding()]
    param([bool]$ServiceInstalled, [bool]$WinwsRunning, [int]$Enabled = 0)
    return ($ServiceInstalled -and -not $WinwsRunning -and $Enabled -eq 1)
}

$script:DiagPass = 0
$script:DiagWarn = 0
$script:DiagFail = 0

function Write-DiagPass { param([string]$Text) $script:DiagPass++; Write-Host ('  [OK] {0}' -f (ConvertTo-UiMessage -Text $Text)) -ForegroundColor Green; Write-Log "diag OK: $Text" }
function Write-DiagWarn { param([string]$Text) $script:DiagWarn++; Write-Host ('  [?]  {0}' -f (ConvertTo-UiMessage -Text $Text)) -ForegroundColor Yellow; Write-Log "diag WARN: $Text" }
function Write-DiagFail { param([string]$Text) $script:DiagFail++; Write-Host ('  [X]  {0}' -f (ConvertTo-UiMessage -Text $Text)) -ForegroundColor Red; Write-Log "diag FAIL: $Text" 'WARN' }
function Write-DiagSkip { param([string]$Text) $skipLabel = Get-UiText -Russian 'пропущено' -English 'skipped'; Write-Host ('  [-]  {0} ({1})' -f (ConvertTo-UiMessage -Text $Text), $skipLabel) -ForegroundColor DarkGray }

function Get-WindowsServiceNames {
    try {
        return @(Get-Service -ErrorAction Stop | ForEach-Object { $_.Name })
    } catch {
        try {
            $out = & (Get-WindowsSystemToolPath -Name 'sc.exe') query type= service state= all 2>&1 | Out-String
            return @([regex]::Matches($out, 'SERVICE_NAME:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
        } catch {
            return @()
        }
    }
}

function Test-ServiceExists {
    param([string]$Name)
    if (-not $script:OnWindows) { return $false }
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($Name.Replace("'", "''"))'" -ErrorAction Stop
        return [bool]$svc
    } catch {
        $names = Get-WindowsServiceNames
        return ($names -contains $Name)
    }
}

function Read-YesNo {
    param([string]$Question, [bool]$DefaultYes = $false, [switch]$NoInteractive)
    $suffix = if ($DefaultYes) { Get-UiText -Russian '[Д/н]' -English '[Y/n]' } else { Get-UiText -Russian '[д/Н]' -English '[y/N]' }
    if ($NoInteractive -or (Get-ZapretNonInteractive)) { return $DefaultYes }
    $questionText = ConvertTo-UiMessage -Text $Question
    $answer = Read-Host ("  {0} {1}" -f $questionText, $suffix)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return ($answer.Trim().ToLowerInvariant() -in @('y','yes','д','да'))
}

function Invoke-Diagnostics {
    param([switch]$NoInteractive, [switch]$ReadOnly)

    if (-not $script:OnWindows) {
        Write-Warn2 'Diagnostics target Windows. Running the platform-independent checks only.'
    }

    $script:DiagPass = 0; $script:DiagWarn = 0; $script:DiagFail = 0

    Write-Host ''
    Write-Host (Get-UiText -Russian '  ДИАГНОСТИКА ZAPRET' -English '  ZAPRET DIAGNOSTICS') -ForegroundColor Cyan
    Write-Host (Get-UiText -Russian ("  Папка программы: {0}" -f $script:Root) -English ("  Install folder: {0}" -f $script:Root)) -ForegroundColor DarkGray
    Write-Host ''

    # --- System clock (TLS / DoH depend on a reasonably accurate time) ------
    try {
        $serverDate = Get-HttpsServerDate -Url 'https://www.gstatic.com/generate_204' -TimeoutSec 3
        if ($null -eq $serverDate) {
            Write-DiagSkip 'System clock comparison (HTTPS Date header unavailable)'
        } else {
            $clockSkew = Get-SystemTimeSkewSeconds -LocalTime ([DateTimeOffset]::Now) -ReferenceTime $serverDate
            if ([Math]::Abs($clockSkew) -gt 120) {
                $clockDirection = if ($clockSkew -gt 0) { 'спешат' } else { 'отстают' }
                Write-DiagWarn ("Системные часы {0} примерно на {1} сек. Неверное время может ломать TLS-подключения и DoH; проверьте дату, время и часовой пояс." -f $clockDirection, [Math]::Abs($clockSkew))
            } else {
                Write-DiagPass ("System clock is within 2 minutes of HTTPS time (difference: {0} sec)" -f $clockSkew)
            }
        }
    } catch {
        Write-DiagSkip 'System clock comparison (HTTPS Date request failed)'
    }

    # --- Extraction path: Cyrillic ------------------------------------------
    if ($script:Root -match '[\u0410-\u044F\u0401\u0451]') {
        Write-DiagWarn 'Install path contains Cyrillic characters. If the bypass does not work, move zapret to a path like C:\zapret'
    } else {
        Write-DiagPass 'Install path has no Cyrillic characters'
    }

    # --- Extraction path: OneDrive ------------------------------------------
    $oneDrive = $env:OneDrive
    if ($oneDrive -and $script:Root.StartsWith($oneDrive, [StringComparison]::OrdinalIgnoreCase)) {
        Write-DiagFail 'Zapret is installed inside a OneDrive folder. Move it elsewhere, e.g. C:\zapret'
    } else {
        Write-DiagPass 'Not installed in OneDrive'
    }

    # --- bin folder and driver ----------------------------------------------
    if (Test-Path (Join-Path $script:BinDir 'winws.exe')) {
        Write-DiagPass 'bin\winws.exe found'
    } else {
        Write-DiagFail 'bin\winws.exe NOT found. Re-extract the archive completely.'
    }

    $sysFile = Join-Path $script:BinDir 'WinDivert64.sys'
    if (Test-Path $sysFile) {
        Write-DiagPass 'WinDivert64.sys found'
    } else {
        Write-DiagFail 'WinDivert64.sys NOT found. The driver is required for the bypass.'
    }

    # --- Shipped binary signatures --------------------------------------------
    $sigReport = Get-BinarySignatureReport
    $sigBad   = @($sigReport | Where-Object { $_.Severity -eq 'FAIL' })
    $sigWarn  = @($sigReport | Where-Object { $_.Severity -eq 'WARN' })
    if (@($sigReport | Where-Object { $_.Severity -eq 'SKIP' }).Count -gt 0) {
        Write-DiagSkip 'Authenticode signature verification'
    } elseif ($sigBad.Count -gt 0) {
        foreach ($b in $sigBad) { Write-DiagFail ("BINARY TAMPERED: {0} ({1}) - file was modified after signing. Re-download from the official release page!" -f $b.File, $b.Status) }
    } elseif ($sigWarn.Count -gt 0) {
        Write-DiagWarn ("Some binaries are not Authenticode-signed: {0}. Normal for unsigned builds - if in doubt, re-download from the official release page." -f (($sigWarn | ForEach-Object { $_.File }) -join ', '))
    } else {
        Write-DiagPass 'All shipped binaries have valid Authenticode signatures'
    }

    if ($script:OnWindows) {
        # --- Base Filtering Engine -------------------------------------------
        $bfe = Get-Service -Name 'BFE' -ErrorAction SilentlyContinue
        if ($bfe -and $bfe.Status -eq 'Running') {
            Write-DiagPass 'Base Filtering Engine is running'
        } else {
            Write-DiagFail 'Base Filtering Engine is NOT running. Start the BFE service - zapret cannot work without it.'
        }

        # --- System proxy -----------------------------------------------------
        $proxyEnabled = $false; $proxyServer = ''
        try {
            $ips = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
            if ($ips.PSObject.Properties['ProxyEnable'] -and $ips.ProxyEnable -eq 1) {
                $proxyEnabled = $true
                if ($ips.PSObject.Properties['ProxyServer']) { $proxyServer = [string]$ips.ProxyServer }
            }
        } catch { }
        if ($proxyEnabled) {
            Write-DiagWarn "System proxy is enabled ($proxyServer). Make sure it is valid, or disable it if you don't use a proxy"
        } else {
            Write-DiagPass 'System proxy is not enabled'
        }

        # --- TCP timestamps ---------------------------------------------------
        if (Enable-TcpTimestamps) {
            Write-DiagPass 'TCP timestamps are enabled'
        } else {
            Write-DiagWarn 'TCP timestamps could not be enabled automatically'
        }

        # --- IPv6 Dual-Stack (some providers filter IPv4 only) -----------------
        try {
            $ipv6Addresses = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction Stop)
            $globalIPv6 = @(Select-GlobalIPv6Addresses -Addresses $ipv6Addresses)
            if ($globalIPv6.Count -gt 0) {
                Write-DiagWarn ("Найдены активные глобальные IPv6-адреса ({0}). Если фильтрация работает только по IPv4, часть трафика может обходить её через IPv6." -f $globalIPv6.Count)
            } else {
                Write-DiagPass 'No preferred global IPv6 addresses found'
            }
        } catch {
            Write-DiagSkip 'IPv6 Dual-Stack check (Get-NetIPAddress unavailable)'
        }

        # --- HVCI / Memory integrity may block WinDivert -----------------------
        try {
            $serviceForHvci = Get-ZapretServiceInfo
            if (-not $serviceForHvci.Installed) {
                Write-DiagSkip 'HVCI / WinDivert load check (zapret service is not installed)'
            } elseif ($serviceForHvci.WinwsRunning) {
                Write-DiagPass 'WinDivert is not currently blocking the running winws.exe process'
            } else {
                $hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
                $hvciEnabled = 0
                $hvciReadable = $true
                try {
                    if (Test-Path -LiteralPath $hvciPath) {
                        $hvciValue = Get-ItemProperty -LiteralPath $hvciPath -Name Enabled -ErrorAction Stop
                        if ($hvciValue.PSObject.Properties['Enabled']) { $hvciEnabled = [int]$hvciValue.Enabled }
                    }
                } catch { $hvciReadable = $false }
                if (-not $hvciReadable) {
                    Write-DiagSkip 'HVCI / WinDivert load check (registry value could not be read)'
                } elseif (Test-HvciDriverWarningCondition -ServiceInstalled ([bool]$serviceForHvci.Installed) -WinwsRunning ([bool]$serviceForHvci.WinwsRunning) -Enabled $hvciEnabled) {
                    Write-DiagWarn 'Служба zapret установлена, но winws.exe не запущен. «Целостность памяти» Windows (HVCI) может блокировать загрузку драйвера WinDivert64.sys.'
                } else {
                    Write-DiagPass 'HVCI is not reported as blocking WinDivert'
                }
            }
        } catch {
            Write-DiagSkip 'HVCI / WinDivert load check'
        }

        # --- AdGuard -----------------------------------------------------------
        if (Get-Process -Name 'AdguardSvc' -ErrorAction SilentlyContinue) {
            Write-DiagFail 'AdGuard process found. AdGuard can break Discord. See https://github.com/Flowseal/zapret-discord-youtube/issues/417'
        } else {
            Write-DiagPass 'AdGuard is not running'
        }

        # --- Conflicting software (service scan) -------------------------------
        $serviceNames = Get-WindowsServiceNames
        $has = { param($pattern) [bool]($serviceNames | Where-Object { $_ -match $pattern } | Select-Object -First 1) }

        if (& $has '(?i)killer') {
            Write-DiagFail 'Killer services found. Killer conflicts with zapret: https://github.com/Flowseal/zapret-discord-youtube/issues/2512#issuecomment-2821119513'
        } else { Write-DiagPass 'Killer not found' }

        if (& $has '(?i)intel.*connectivity.*network|connectivity.*network.*intel') {
            Write-DiagFail 'Intel Connectivity Network Service found. It conflicts with zapret: https://github.com/ValdikSS/GoodbyeDPI/issues/541#issuecomment-2661670982'
        } else { Write-DiagPass 'Intel Connectivity Network Service not found' }

        if ((Test-ServiceExists 'TracSrvWrapper') -or (Test-ServiceExists 'EPWD')) {
            Write-DiagFail 'Check Point services found. Check Point conflicts with zapret - uninstall it'
        } else { Write-DiagPass 'Check Point not found' }

        if (& $has '(?i)smartbyte') {
            Write-DiagFail 'SmartByte services found. Uninstall SmartByte or disable it via services.msc'
        } else { Write-DiagPass 'SmartByte not found' }

        # --- VPN / WireGuard / WARP / OpenVPN (common conflict source) --------
        $vpnRegex = Get-ZapretConflictServicePattern
        $vpnServices = @($serviceNames | Where-Object { $_ -match $vpnRegex })
        $genericVpnServices = @($serviceNames | Where-Object { $_ -match '(?i)vpn|happservice' })
        $vpnRelatedServices = @($vpnServices + $genericVpnServices | Select-Object -Unique)
        $vpnProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match (Get-ZapretConflictProcessPattern) } | ForEach-Object { $_.Name } | Select-Object -Unique)
        if ($vpnRelatedServices.Count -gt 0 -or $vpnProcesses.Count -gt 0) {
            Write-DiagWarn ("VPN/WireGuard/WARP detected - services: {0}; processes: {1}" -f $(if ($vpnRelatedServices.Count) { $vpnRelatedServices -join ', ' } else { 'none' }), $(if ($vpnProcesses.Count) { $vpnProcesses -join ', ' } else { 'none' }))
            if ($ReadOnly) { Write-DiagSkip 'Stopping VPN/WireGuard-related services (read-only mode)' }
            elseif ($vpnServices.Count -eq 0) { Write-DiagSkip 'Automatic stop skipped; no recognized VPN service name was found' }
            elseif (Read-YesNo -Question 'Stop and DISABLE these recognized VPN/WireGuard services temporarily?' -DefaultYes $false -NoInteractive:$NoInteractive) {
                foreach ($svc in $vpnServices) {
                    if ($svc -notmatch '^[A-Za-z0-9_. -]+$') { Write-DiagSkip ("Skipping odd service name: {0}" -f $svc); continue }
                    $svcQuoted = '"{0}"' -f $svc   # service names may contain spaces
                    & (Get-WindowsSystemToolPath -Name 'sc.exe') stop $svcQuoted 2>&1 | Out-Null
                    & (Get-WindowsSystemToolPath -Name 'sc.exe') config $svcQuoted start= disabled 2>&1 | Out-Null
                    Write-Info2 ("Stopped and disabled: {0} (re-enable via services.msc when needed)" -f $svc)
                }
            }
        } else { Write-DiagPass 'No VPN/WireGuard/WARP tooling detected' }

        # --- WinINET system proxy: offer to disable it -------------------------
        if ($proxyEnabled) {
            if ($ReadOnly) { Write-DiagSkip 'WinINET proxy reset (read-only mode)' }
            elseif (Read-YesNo -Question ("Disable the WinINET system proxy ({0}) for the current user?" -f $proxyServer) -DefaultYes $false -NoInteractive:$NoInteractive) {
                try {
                    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value 0 -ErrorAction Stop
                    Write-DiagPass 'WinINET system proxy disabled (current user)'
                } catch { Write-DiagWarn ("Could not disable the proxy: {0}" -f $_.Exception.Message) }
            }
        }

        # --- WinHTTP proxy (informational only) ---------------------------------
        try {
            $wh = (& (Get-WindowsSystemToolPath -Name 'netsh.exe') winhttp show proxy 2>&1 | Out-String)
            if ($wh -match '127\.0\.0\.1|localhost|http=|https=') { Write-DiagWarn 'WinHTTP proxy is configured (netsh winhttp show proxy). Usually irrelevant for zapret - leave it unless you use it deliberately.' } else { Write-DiagPass 'WinHTTP proxy: not configured' }
        } catch { }

        # --- Secure DNS / DoH hint ---------------------------------------------
        $dohCount = 0
        try {
            $dohCount = @(Get-ChildItem -Recurse -Path 'HKLM:System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\' -ErrorAction Stop |
                Get-ItemProperty -ErrorAction SilentlyContinue |
                Where-Object { $_.PSObject.Properties['DohFlags'] -and $_.DohFlags -gt 0 }).Count
        } catch { $dohCount = 0 }
        if ($dohCount -gt 0) {
            Write-DiagPass 'Encrypted DNS (DoH) is configured on this PC'
        } else {
            Write-DiagWarn 'Secure DNS is not configured. Enable DNS-over-HTTPS in the browser (or Windows 11 encrypted DNS), otherwise the bypass may not work'
        }
    } else {
        Write-DiagSkip 'BFE / proxy / TCP timestamps / AdGuard / conflicting software / DoH'
    }

    # --- Game filter: keep game traffic out of winws for the lowest ping ------
    $gameFilterNow = Get-GameFilterPorts
    if ($gameFilterNow.status -ne 'disabled') {
        Write-DiagWarn 'Game filter is enabled - winws intercepts game traffic. For the lowest ping keep it disabled (zapret.ps1 game-filter off).'
    } else {
        Write-DiagPass 'Game filter is disabled (game traffic is not intercepted)'
    }

    # --- Hosts: youtube entries -------------------------------------------------
    try {
        $hostsPath = Get-HostsFilePath
        if (Test-Path $hostsPath) {
            $hostsText = [IO.File]::ReadAllText($hostsPath)
            $userLines = ($hostsText -split "`r?`n" | Where-Object { $_ -notmatch [regex]::Escape($script:HostsBeginMarker) })
            $userText = ($userLines -join "`n")
            if ($userText -match '(?im)^\s*[^#\s]\S*\s+[^#\s]*youtube\.com' -or $userText -match '(?im)^\s*[^#\s]\S*\s+[^#\s]*youtu\.be') {
                Write-DiagWarn 'Hosts file contains entries for youtube.com or youtu.be - this can break YouTube access'
            } else {
                Write-DiagPass 'Hosts file has no YouTube overrides'
            }
        }
    } catch {
        Write-DiagSkip 'Hosts file check'
    }

    if ($script:OnWindows) {
        # --- WinDivert conflict --------------------------------------------------
        $winwsRunning = [bool](Get-WinwsProcess | Select-Object -First 1)
        $windivert = Get-CimInstance -ClassName Win32_Service -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue
        $wdState = if ($windivert) { $windivert.State } else { $null }

        if ($ReadOnly -and -not $winwsRunning -and $wdState -in @('Running','Stop Pending')) {
            Write-DiagSkip 'WinDivert service is active but winws.exe is not running (read-only mode - not touching it)'
        } elseif (-not $winwsRunning -and $wdState -in @('Running','Stop Pending')) {
            Write-DiagWarn 'winws.exe is not running but the WinDivert service is active. Attempting to remove it...'
            & (Get-WindowsSystemToolPath -Name 'sc.exe') stop WinDivert 2>&1 | Out-Null
            & (Get-WindowsSystemToolPath -Name 'sc.exe') delete WinDivert 2>&1 | Out-Null
            Start-Sleep -Seconds 1
            $windivert = Get-CimInstance -ClassName Win32_Service -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue
            if ($windivert) {
                if (Test-ServiceExists 'GoodbyeDPI') {
                    Write-DiagWarn 'Found conflicting service: GoodbyeDPI. Stopping and removing it...'
                    & (Get-WindowsSystemToolPath -Name 'sc.exe') stop GoodbyeDPI 2>&1 | Out-Null
                    & (Get-WindowsSystemToolPath -Name 'sc.exe') delete GoodbyeDPI 2>&1 | Out-Null
                }
                & (Get-WindowsSystemToolPath -Name 'sc.exe') stop WinDivert 2>&1 | Out-Null
                & (Get-WindowsSystemToolPath -Name 'sc.exe') delete WinDivert 2>&1 | Out-Null
                $windivert = Get-CimInstance -ClassName Win32_Service -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue
                if ($windivert) {
                    Write-DiagFail 'WinDivert cannot be deleted. Check manually whether another bypass uses it'
                } else {
                    Write-DiagPass 'WinDivert removed'
                }
            } else {
                Write-DiagPass 'WinDivert removed'
            }
        } else {
            Write-DiagPass 'No WinDivert conflict (winws and WinDivert are in a consistent state)'
        }

        # --- Conflicting bypass services ------------------------------------------
        # Keep the filtered output as an array even when zero or one services match.
        # With module StrictMode v2, an unwrapped $null has no .Count property.
        $conflicts = @(@('GoodbyeDPI', 'discordfix_zapret', 'winws1', 'winws2') | Where-Object { Test-ServiceExists $_ })
        if ($conflicts.Count -gt 0) {
            Write-DiagFail ("Conflicting bypass services found: {0}" -f ($conflicts -join ', '))
            if ($ReadOnly) { Write-DiagSkip 'Removal of conflicting services (read-only mode)' }
            elseif (Read-YesNo -Question 'Remove these conflicting services?' -DefaultYes $false -NoInteractive:$NoInteractive) {
                foreach ($svc in $conflicts) {
                    & (Get-WindowsSystemToolPath -Name 'sc.exe') stop $svc 2>&1 | Out-Null
                    & (Get-WindowsSystemToolPath -Name 'sc.exe') delete $svc 2>&1 | Out-Null
                    Write-Info2 "Removed service: $svc"
                }
                & (Get-WindowsSystemToolPath -Name 'sc.exe') stop WinDivert 2>&1 | Out-Null; & (Get-WindowsSystemToolPath -Name 'sc.exe') delete WinDivert 2>&1 | Out-Null
                & (Get-WindowsSystemToolPath -Name 'sc.exe') stop WinDivert14 2>&1 | Out-Null; & (Get-WindowsSystemToolPath -Name 'sc.exe') delete WinDivert14 2>&1 | Out-Null
            }
        } else {
            Write-DiagPass 'No conflicting bypass services'
        }

        # --- Discord cache ---------------------------------------------------------
        if ($ReadOnly) { Write-DiagSkip 'Discord cache clear (read-only mode)' }
        elseif (Read-YesNo -Question 'Clear the Discord cache (Stable/PTB/Canary/Development)?' -DefaultYes $true -NoInteractive:$NoInteractive) {
            Clear-DiscordCache
        }
    }

    Write-Host ''
    $color = if ($script:DiagFail -gt 0) { 'Red' } elseif ($script:DiagWarn -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host (Get-UiText -Russian ("  Диагностика завершена: пройдено — {0}, предупреждений — {1}, проблем — {2}" -f $script:DiagPass, $script:DiagWarn, $script:DiagFail) -English ("  Diagnostics complete: {0} passed, {1} warnings, {2} problems" -f $script:DiagPass, $script:DiagWarn, $script:DiagFail)) -ForegroundColor $color
    Write-Host ''
}

function Clear-DiscordCache {
    if (-not $env:APPDATA) {
        Write-Warn2 'APPDATA is not defined - cannot locate Discord installations.'
        return
    }
    $variants = @(
        @{ Process = 'Discord';            Name = 'Discord';              Dir = 'discord' },
        @{ Process = 'DiscordPTB';         Name = 'Discord PTB';          Dir = 'discordptb' },
        @{ Process = 'DiscordCanary';      Name = 'Discord Canary';       Dir = 'discordcanary' },
        @{ Process = 'DiscordDevelopment'; Name = 'Discord Development';  Dir = 'discorddevelopment' }
    )
    $found = $false
    foreach ($v in $variants) {
        $dir = Join-Path $env:APPDATA $v.Dir
        if (-not (Test-Path $dir)) { continue }
        $found = $true

        $proc = Get-Process -Name $v.Process -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Name $v.Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Write-Info2 "$($v.Name) was closed."
        }
        foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) {
            $target = Join-Path $dir $sub
            if (-not (Test-Path $target)) { continue }
            try {
                Remove-Item $target -Recurse -Force -ErrorAction Stop
                Write-Ok "Deleted $target"
            } catch {
                Write-Fail "Failed to delete $target"
            }
        }
    }
    if (-not $found) { Write-Warn2 'No Discord installations were found.' }
}

# ---------------------------------------------------------------------------
# Conflict report (read-only) and Discord voice connectivity check
# ---------------------------------------------------------------------------

function Enable-ZapretTcpTimestamps {
    <#
        The stock .bat configs call `service.bat status_zapret` before every run,
        which ends in :tcp_enable -> `netsh interface tcp set global timestamps=enabled`.
        Strategies using --dpi-desync-fooling=ts (general (ALT) family) physically
        need TCP timestamps to be on. Returns $true when they are enabled.
    #>
    if (-not $script:OnWindows) { return $false }
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    try {
        & $netsh interface tcp set global timestamps=enabled 2>$null | Out-Null
        $setOk = ($LASTEXITCODE -eq 0)
        $check = (& $netsh interface tcp show global 2>$null | Out-String)
        if ($check -match '(?i)(timestamps|отметки времени)\s*:\s*(enabled|включ)') { return $true }
        return $setOk
    } catch {
        return $false
    }
}

function Get-ZapretConflictServicePattern {
    # Pure regex (unit-tested off Windows): services of VPN/proxy clients whose
    # TUN or driver engines fight with winws/WinDivert - Happ, Xray, V2Ray,
    # sing-box, Clash, Hysteria and the classic VPN clients.
    return '(?i)wireguard|amnezia|openvpn|warp|nordvpn|expressvpn|surfshark|protonvpn|happ|xray|v2ray|sing-box|clash|hysteria|nekoray|nekobox'
}

function Get-ZapretConflictProcessPattern {
    # Pure regex (unit-tested off Windows). Anchored to whole process names so
    # short names like 'happ' never match unrelated programs.
    return '(?i)^(wireguard|openvpn|warp-svc|amnezia.*|goodbyedpi|happ|xray|v2ray|v2rayn|v2rayx|sing-box|singbox|nekoray|nekobox|clash|clash-meta|clash-verge|clash-verge-service|hysteria|hysteria2)$'
}

function Get-ZapretConflictReport {
    # Read-only aggregation of known conflict sources (other bypasses, VPN,
    # vendor "network optimizers", foreign winws processes). Used before
    # restarting the service after setting changes and by the voice check.
    [CmdletBinding()]
    param()
    $items = New-Object 'System.Collections.Generic.List[string]'
    $targets = New-Object 'System.Collections.Generic.List[object]'
    if (-not $script:OnWindows) { return [pscustomobject]@{ Items = @(); Targets = @() } }
    try {
        $serviceNames = @(Get-WindowsServiceNames)
        $serviceStates = @{}
        foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue)) {
            if ($svc -and $svc.PSObject.Properties['Name'] -and $svc.Name) { $serviceStates[[string]$svc.Name] = [string]$svc.Status }
        }
        $serviceActive = { param($name)
            if (-not $serviceStates.ContainsKey([string]$name)) { return $true }
            return ([string]$serviceStates[[string]$name] -eq 'Running')
        }
        $killerActive = @($serviceNames | Where-Object { $_ -match '(?i)killer' } | Where-Object { & $serviceActive $_ })
        if ($killerActive.Count -gt 0) {
            $items.Add('службы Killer (конфликтуют с WinDivert)')
            foreach ($svcName in $killerActive) { $targets.Add([pscustomobject]@{ Kind = 'service'; Name = $svcName }) }
        }
        $intelActive = @($serviceNames | Where-Object { $_ -match '(?i)intel.*connectivity.*network|connectivity.*network.*intel' } | Where-Object { & $serviceActive $_ })
        if ($intelActive.Count -gt 0) {
            $items.Add('Intel Connectivity Network Service')
            foreach ($svcName in $intelActive) { $targets.Add([pscustomobject]@{ Kind = 'service'; Name = $svcName }) }
        }
        $checkPointActive = @(@('TracSrvWrapper', 'EPWD') | Where-Object { (Test-ServiceExists $_) -and (& $serviceActive $_) })
        if ($checkPointActive.Count -gt 0) {
            $items.Add('Check Point (TracSrvWrapper/EPWD)')
            foreach ($svcName in $checkPointActive) { $targets.Add([pscustomobject]@{ Kind = 'service'; Name = $svcName }) }
        }
        $smartByteActive = @($serviceNames | Where-Object { $_ -match '(?i)smartbyte' } | Where-Object { & $serviceActive $_ })
        if ($smartByteActive.Count -gt 0) {
            $items.Add('SmartByte')
            foreach ($svcName in $smartByteActive) { $targets.Add([pscustomobject]@{ Kind = 'service'; Name = $svcName }) }
        }
        foreach ($svcName in @('GoodbyeDPI', 'discordfix_zapret', 'winws1', 'winws2')) {
            if ((Test-ServiceExists $svcName) -and (& $serviceActive $svcName)) { $items.Add(('служба {0}' -f $svcName)); $targets.Add([pscustomobject]@{ Kind = 'service'; Name = $svcName }) }
        }
        if (Get-Process -Name 'AdguardSvc' -ErrorAction SilentlyContinue) { $items.Add('AdGuard (AdguardSvc)'); $targets.Add([pscustomobject]@{ Kind = 'process'; Name = 'AdguardSvc' }) }
        $vpnRegex = '(?i)wireguard|amnezia|openvpn|warp|nordvpn|expressvpn|surfshark|protonvpn|happservice'
        foreach ($svcName in @($serviceNames | Where-Object { $_ -match $vpnRegex })) {
            if (-not (& $serviceActive $svcName)) { continue }
            $items.Add(('VPN/прокси-служба {0}' -f $svcName))
            $targets.Add([pscustomobject]@{ Kind = 'service'; Name = $svcName })
        }
        $vpnProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)wireguard|openvpn|warp-svc|amnezia|goodbyedpi' } | ForEach-Object { $_.Name } | Select-Object -Unique)
        foreach ($procName in $vpnProcesses) { $items.Add(('процесс {0}' -f $procName)); $targets.Add([pscustomobject]@{ Kind = 'process'; Name = $procName }) }
        # winws.exe from a different installation also holds WinDivert
        $ownBin = [string]$script:BinDir
        foreach ($proc in @(Get-WinwsProcess)) {
            $procPath = $null
            try { $procPath = [string]$proc.Path } catch { }
            if ($procPath -and $ownBin -and -not $procPath.StartsWith($ownBin, [StringComparison]::OrdinalIgnoreCase)) {
                $items.Add(('чужой winws.exe (PID {0}: {1})' -f $proc.Id, $procPath)); $targets.Add([pscustomobject]@{ Kind = 'process'; Name = 'winws'; Id = $proc.Id })
            }
        }
        # driver loaded while no winws of this install is running
        $wdServices = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='WinDivert'" -ErrorAction SilentlyContinue) + @(Get-CimInstance -ClassName Win32_Service -Filter "Name='WinDivert14'" -ErrorAction SilentlyContinue)
        $wdActive = @($wdServices | Where-Object { $_ -and [string]$_.State -in @('Running', 'Stop Pending') })
        if ($wdActive.Count -gt 0 -and @(Get-WinwsProcess).Count -eq 0) {
            $items.Add('драйвер WinDivert активен, но winws.exe не запущен')
        }
    } catch {
        $items.Add(('не удалось завершить проверку конфликтов: {0}' -f $_.Exception.Message))
    }
    return [pscustomobject]@{ Items = @($items.ToArray()); Targets = @($targets.ToArray()) }
}

function Disable-ZapretConflictPrograms {
    # Stops conflicting services and processes detected by
    # Get-ZapretConflictReport. Service startup type and running state are
    # backed up to .conflicts-backup.json so Restore-ZapretConflictPrograms can
    # bring everything back; killed processes are not auto-restarted.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Report
    )
    $disabled = New-Object 'System.Collections.Generic.List[object]'
    $stopped = New-Object 'System.Collections.Generic.List[string]'
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $backupPath = ''
    if (-not $script:OnWindows) {
        return [pscustomobject]@{ Services = @(); Processes = @(); Failed = @(); BackupPath = '' }
    }
    $targets = @()
    if ($Report -and $Report.PSObject.Properties['Targets']) { $targets = @(@($Report.Targets) | Where-Object { $_ }) }
    $backup = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in $targets) {
        if (-not $target.PSObject.Properties['Kind'] -or -not $target.PSObject.Properties['Name']) { continue }
        $kind = [string]$target.Kind
        $name = [string]$target.Name
        if (-not $name) { continue }
        if ($kind -eq 'service') {
            try {
                $svc = Get-Service -Name $name -ErrorAction Stop
                $prevStartup = [string]$svc.StartType
                $prevStatus = [string]$svc.Status
                if ($svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force -ErrorAction Stop }
                Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
                $entry = [pscustomobject]@{ Name = $name; StartupType = $prevStartup; Status = $prevStatus }
                $disabled.Add($entry)
                $backup.Add($entry)
            } catch {
                $failed.Add(('{0}: {1}' -f $name, $_.Exception.Message))
            }
        } elseif ($kind -eq 'process') {
            try {
                if ($target.PSObject.Properties['Id'] -and $target.Id) {
                    Stop-Process -Id ([int]$target.Id) -Force -ErrorAction Stop
                    $stopped.Add(('{0} (PID {1})' -f $name, $target.Id))
                } else {
                    Stop-Process -Name $name -Force -ErrorAction Stop
                    $stopped.Add($name)
                }
            } catch {
                $failed.Add(('{0}: {1}' -f $name, $_.Exception.Message))
            }
        }
    }
    if ($backup.Count -gt 0) {
        try {
            $backupPath = Join-Path $script:Root '.conflicts-backup.json'
            [pscustomobject]@{ DisabledAt = (Get-Date).ToString('o'); Services = @($backup.ToArray()) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        } catch {
            $backupPath = ''
            $failed.Add(('не удалось сохранить копию настроек служб: {0}' -f $_.Exception.Message))
        }
    }
    return [pscustomobject]@{ Services = @($disabled.ToArray()); Processes = @($stopped.ToArray()); Failed = @($failed.ToArray()); BackupPath = $backupPath }
}

function Restore-ZapretConflictPrograms {
    # Reverses Disable-ZapretConflictPrograms: restores each service's startup
    # type and restarts the ones that were running before. Returns Found=$false
    # when there is no backup (nothing was disabled yet).
    [CmdletBinding()]
    param()
    $restored = New-Object 'System.Collections.Generic.List[string]'
    $failed = New-Object 'System.Collections.Generic.List[string]'
    if (-not $script:OnWindows) {
        return [pscustomobject]@{ Restored = @(); Failed = @(); Found = $false }
    }
    $backupPath = Join-Path $script:Root '.conflicts-backup.json'
    if (-not (Test-Path -LiteralPath $backupPath)) {
        return [pscustomobject]@{ Restored = @(); Failed = @(); Found = $false }
    }
    try {
        $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ Restored = @(); Failed = @(('не удалось прочитать копию: {0}' -f $_.Exception.Message)); Found = $true }
    }
    foreach ($item in @($backup.Services)) {
        if (-not $item) { continue }
        try {
            Set-Service -Name $item.Name -StartupType $item.StartupType -ErrorAction Stop
            if ([string]$item.Status -eq 'Running') { Start-Service -Name $item.Name -ErrorAction Stop }
            $restored.Add([string]$item.Name)
        } catch {
            $failed.Add(('{0}: {1}' -f $item.Name, $_.Exception.Message))
        }
    }
    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Restored = @($restored.ToArray()); Failed = @($failed.ToArray()); Found = $true }
}

function New-StunBindingRequest {
    # RFC 5389 STUN Binding Request (20-byte header, no attributes).
    [CmdletBinding()]
    param([byte[]]$TransactionId)
    if ($null -eq $TransactionId -or $TransactionId.Length -ne 12) {
        $TransactionId = New-Object byte[] 12
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($TransactionId) } finally { $rng.Dispose() }
    }
    $packet = New-Object byte[] 20
    $packet[0] = 0x00; $packet[1] = 0x01
    $packet[2] = 0x00; $packet[3] = 0x00
    $packet[4] = 0x21; $packet[5] = 0x12; $packet[6] = 0xA4; $packet[7] = 0x42
    [Array]::Copy($TransactionId, 0, $packet, 8, 12)
    return ,$packet
}

function Test-StunResponseBytes {
    # Validates a STUN Binding response (success 0x0101 or error 0x0111)
    # against the transaction id of the request we sent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Response,
        [Parameter(Mandatory = $true)][byte[]]$TransactionId
    )
    if ($null -eq $Response -or $Response.Length -lt 20) { return $false }
    if ($null -eq $TransactionId -or $TransactionId.Length -ne 12) { return $false }
    if (($Response[0] -band 0xC0) -ne 0) { return $false }
    $type = ([int]$Response[0] -shl 8) -bor [int]$Response[1]
    if ($type -ne 0x0101 -and $type -ne 0x0111) { return $false }
    if ($Response[4] -ne 0x21 -or $Response[5] -ne 0x12 -or $Response[6] -ne 0xA4 -or $Response[7] -ne 0x42) { return $false }
    for ($i = 0; $i -lt 12; $i++) { if ($Response[8 + $i] -ne $TransactionId[$i]) { return $false } }
    return $true
}

function Invoke-UdpProbe {
    # Sends one UDP datagram and waits briefly for any reply. Used to verify
    # that substituted UDP packets (the active fake) leave the machine and get
    # answered - the path Discord voice depends on.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Payload,
        [int]$TimeoutMs = 3000
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $socket = $null
    try {
        $ip = [IPAddress]::Parse($Address)
        $socket = New-Object System.Net.Sockets.Socket($ip.AddressFamily, [Sockets.SocketType]::Dgram, [Sockets.ProtocolType]::Udp)
        $socket.ReceiveTimeout = $TimeoutMs
        $socket.Connect($ip, $Port)
        [void]$socket.Send($Payload)
        $buffer = New-Object byte[] 2048
        $received = $socket.Receive($buffer)
        $timer.Stop()
        $response = New-Object byte[] $received
        [Array]::Copy($buffer, $response, $received)
        return [pscustomobject]@{ Ok = $true; Bytes = $received; Response = $response; Ms = [int]$timer.ElapsedMilliseconds; Error = $null }
    } catch {
        $timer.Stop()
        return [pscustomobject]@{ Ok = $false; Bytes = 0; Response = @(); Ms = [int]$timer.ElapsedMilliseconds; Error = $_.Exception.Message }
    } finally {
        if ($socket) { try { $socket.Dispose() } catch { } }
    }
}

function Invoke-TcpProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [int]$Port = 443,
        [int]$TimeoutMs = 3000
    )
    $client = $null
    try {
        $ip = [IPAddress]::Parse($Address)
        $client = New-Object System.Net.Sockets.TcpClient($ip.AddressFamily)
        $asyncResult = $client.BeginConnect($ip, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($asyncResult)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Dispose() } catch { } }
    }
}

function Get-VoiceCheckVerdict {
    # Pure decision helper shared by the CLI runner and the panel: maps probe
    # results to a verdict code ('ok', 'dns', 'udp-wide', 'tcp', 'discord-udp')
    # and to VoiceLikely. The Google-STUN baseline is informational only - a
    # blocked baseline must not fail a working Discord path.
    [CmdletBinding()]
    param(
        [bool]$TcpOk,
        [bool]$UdpFakeOk,
        [bool]$UdpStunOk,
        [bool]$UdpBaselineOk,
        [bool]$DnsFailed
    )
    $udpToDiscord = [bool]($UdpFakeOk -or $UdpStunOk)
    $voiceLikely = [bool]($TcpOk -and $udpToDiscord)
    $code = 'ok'
    if ($DnsFailed) {
        $code = 'dns'
    } elseif (-not $voiceLikely) {
        if (-not $TcpOk -and -not $UdpBaselineOk -and -not $udpToDiscord) { $code = 'udp-wide' }
        elseif (-not $TcpOk) { $code = 'tcp' }
        elseif (-not $UdpBaselineOk) { $code = 'udp-wide' }
        else { $code = 'discord-udp' }
    }
    return [pscustomobject]@{ VoiceLikely = $voiceLikely; Code = $code }
}

function Restart-ZapretBypassService {
    # Silent service restart for the repair ladder (no prompts).
    # Returns $true when the service was restarted.
    param()
    if (-not $script:OnWindows) { return $false }
    $info = $null
    try { $info = Get-ZapretServiceInfo } catch { return $false }
    if (-not $info -or -not $info.Installed) { return $false }
    try {
        Stop-Service -Name 'zapret' -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Start-Service -Name 'zapret' -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-Log 'Voice repair: bypass service restarted'
        return $true
    } catch {
        Write-Log ("Voice repair: service restart failed: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Backup-ActiveDiscordFake {
    # Returns the current bytes of the active fake (or $null when missing) so
    # the repair ladder can restore ANY payload - including a user's '(custom)'
    # one that has no library file to restore by name.
    param([Parameter(Mandatory = $true)][string]$ActivePath)
    if (Test-Path -LiteralPath $ActivePath -PathType Leaf) {
        return ,([IO.File]::ReadAllBytes($ActivePath))
    }
    return $null
}

function Restore-ActiveDiscordFake {
    # Writes the backed-up bytes back. Returns $false when there is nothing
    # to restore.
    param(
        [AllowNull()][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$ActivePath
    )
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return $false }
    [IO.File]::WriteAllBytes($ActivePath, $Bytes)
    return $true
}

function Get-NextDiscordFakeName {
    # Pure: the next fake name after $CurrentName in the sorted list, wrapping
    # around. $CurrentName may be '(custom)' or '(unknown)' - then the first
    # name wins. Returns $null when the list is empty or holds nothing NEW
    # (a single fake equal to the current one is not a switch).
    param(
        [AllowEmptyCollection()][string[]]$Names = @(),
        [string]$CurrentName
    )
    $sorted = @($Names | Where-Object { $_ } | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $index = -1
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if ($sorted[$i] -eq $CurrentName) { $index = $i; break }
    }
    $next = ($index + 1) % $sorted.Count
    if ($sorted[$next] -eq $CurrentName) { return $null }
    return [string]$sorted[$next]
}

function Test-VoiceQuickProbe {
    # Light re-probe used between repair steps: TCP signalling + STUN + active
    # fake, same addresses as the full check, shorter timeouts.
    param([int]$TimeoutMs = 3000)
    $voiceAddresses = @()
    try {
        $voiceAddresses = @([Net.Dns]::GetHostAddresses('discord.media') | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 2 | ForEach-Object { $_.IPAddressToString })
    } catch { }
    if ($voiceAddresses.Count -eq 0) { return [pscustomobject]@{ VoiceLikely = $false; TcpOk = $false; UdpOk = $false } }
    $tcpOk = $false
    foreach ($addr in $voiceAddresses) {
        if (Invoke-TcpProbe -Address $addr -Port 443 -TimeoutMs $TimeoutMs) { $tcpOk = $true; break }
    }
    $stunRequest = New-StunBindingRequest
    $udpOk = $false
    foreach ($addr in $voiceAddresses) {
        foreach ($port in @(3478, 443)) {
            $result = Invoke-UdpProbe -Address $addr -Port $port -Payload $stunRequest -TimeoutMs $TimeoutMs
            if ($result.Ok) { $udpOk = $true; break }
        }
        if ($udpOk) { break }
    }
    return [pscustomobject]@{ VoiceLikely = [bool]($tcpOk -and $udpOk); TcpOk = $tcpOk; UdpOk = $udpOk }
}

function Repair-DiscordVoice {
    <#
        Discord voice repair ladder ("чинит", not just reports):
          1. full read-only check (conflicts, TCP, UDP, STUN, fake);
          2. if broken: silent bypass restart -> quick re-probe;
          3. if still broken: cycle Discord UDP fakes (set -> restart -> probe);
          4. if nothing helps: restore the original fake and give guidance.
        -NextFakeOnly swaps to the next fake without probing (the manual tool
        for "voice connects but the ping is ~5000 ms" - cycle until it feels
        right). Returns the summary object extended with repair fields.
    #>
    [CmdletBinding()]
    param(
        [switch]$NextFakeOnly,
        [int]$MaxFakeTries = 5
    )
    $actions = New-Object 'System.Collections.Generic.List[string]'
    $inventory = Get-FakeInventory
    $originalFake = [string]$inventory.CurrentDiscordFake
    $fakeNames = @($inventory.Fakes | ForEach-Object { $_.BaseName })
    # Byte-level backup: a '(custom)' payload has no library file to restore
    # by name - without this the ladder would destroy the user's own fake.
    $originalBytes = Backup-ActiveDiscordFake -ActivePath $inventory.ActiveDiscordPath

    if ($NextFakeOnly) {
        $nextFake = Get-NextDiscordFakeName -Names $fakeNames -CurrentName $originalFake
        if (-not $nextFake) {
            Write-Host (Get-UiText -Russian '  Нет фейков в bin\ — менять нечего.' -English '  No fakes in bin\ - nothing to switch.') -ForegroundColor Yellow
            return [pscustomobject]@{ VoiceLikely = $false; Verdict = 'no-fakes'; Repaired = $false; Actions = @('нет фейков в bin'); CurrentFake = $originalFake; NextFakeTried = $true }
        }
        Write-Host ((Get-UiText -Russian '  Меняю UDP-фейк голоса: {0} → {1} и перезапускаю обход…' -English '  Switching the voice UDP fake: {0} -> {1} and restarting the bypass…') -f $originalFake, $nextFake) -ForegroundColor Cyan
        Set-ActiveFake -Target 'discord' -FakeBaseName $nextFake
        $actions.Add(('фейк {0} → {1}' -f $originalFake, $nextFake))
        $restarted = Restart-ZapretBypassService
        if ($restarted) {
            $actions.Add('перезапуск обхода')
            Write-Host (Get-UiText -Russian '  Готово. Переподключитесь к голосовому каналу и проверьте пинг. Если пинг снова огромный — повторите команду для следующего фейка.' -English '  Done. Reconnect to the voice channel and check the ping. If it spikes again - run the command once more for the next fake.') -ForegroundColor Green
        } else {
            Write-Host (Get-UiText -Russian '  Фейк заменён, но служба обхода не установлена — перезапустите обход вручную и проверьте голос.' -English '  The fake is swapped, but the bypass service is not installed - restart the bypass manually and test voice.') -ForegroundColor Yellow
        }
        return [pscustomobject]@{ VoiceLikely = $true; Verdict = 'fake-switched'; Repaired = $true; Actions = @($actions.ToArray()); CurrentFake = $nextFake; NextFakeTried = $true }
    }

    Write-Host (Get-UiText -Russian '  РЕМОНТ ГОЛОСОВОГО ПУТИ DISCORD' -English '  DISCORD VOICE REPAIR') -ForegroundColor Cyan
    $summary = Test-DiscordVoiceConnection
    if ($summary.VoiceLikely) {
        Write-Host (Get-UiText -Russian '  Путь жив — ремонтировать нечего. Если в Discord пинг ~5000 мс или войс не подключается: zapret.ps1 voice-check next-fake (сменит фейк и перезапустит обход; повторяйте, пока голос не станет нормальным).' -English '  The path is healthy - nothing to repair. If Discord shows ~5000 ms ping or voice fails: zapret.ps1 voice-check next-fake (swaps the fake and restarts; repeat until voice feels right).') -ForegroundColor Green
        return [pscustomobject]@{ VoiceLikely = $true; Verdict = $summary.Verdict; Repaired = $false; Actions = @('проверка без изменений — путь жив'); CurrentFake = $originalFake; NextFakeTried = $false; Conflicts = $summary.Conflicts }
    }

    # Step 1: silent bypass restart clears stale WinDivert/flow state.
    Write-Host (Get-UiText -Russian '  Шаг 1: перезапуск обхода (свежее состояние WinDivert)…' -English '  Step 1: restarting the bypass (fresh WinDivert state)…') -ForegroundColor DarkGray
    $restartWorks = Restart-ZapretBypassService
    if ($restartWorks) {
        $actions.Add('перезапуск обхода')
        $quick = Test-VoiceQuickProbe
        if ($quick.VoiceLikely) {
            Write-Host (Get-UiText -Russian '  Починено перезапуском обхода. Переподключитесь к голосу.' -English '  Fixed by restarting the bypass. Reconnect to voice.') -ForegroundColor Green
            return [pscustomobject]@{ VoiceLikely = $true; Verdict = 'fixed-by-restart'; Repaired = $true; Actions = @($actions.ToArray()); CurrentFake = $originalFake; NextFakeTried = $false; Conflicts = $summary.Conflicts }
        }
    } else {
        Write-Host (Get-UiText -Russian '  Служба обхода не установлена — перезапуск пропущен (ручной режим).' -English '  The bypass service is not installed - restart skipped (manual mode).') -ForegroundColor Yellow
        $actions.Add('служба не установлена — перезапуск пропущен')
    }

    # Step 2: cycle the Discord UDP fake, probing after each swap. Without a
    # service to restart, probes cannot change between swaps - so swap ONCE and
    # say so honestly instead of burning useless attempts.
    if (-not $restartWorks) {
        $nextFake = Get-NextDiscordFakeName -Names $fakeNames -CurrentName $originalFake
        if ($nextFake) {
            try {
                Set-ActiveFake -Target 'discord' -FakeBaseName $nextFake
                $actions.Add(('фейк {0} → {1} (без перезапуска — службы нет)' -f $originalFake, $nextFake))
                Write-Host ((Get-UiText -Russian '  Служба не установлена: заменил фейк на «{0}». Перезапустите обход вручную и повторите проверку.' -English '  No service installed: swapped the fake to "{0}". Restart the bypass manually and re-run the check.') -f $nextFake) -ForegroundColor Yellow
                return [pscustomobject]@{ VoiceLikely = $false; Verdict = 'fake-switched-manual'; Repaired = $false; Actions = @($actions.ToArray()); CurrentFake = $nextFake; NextFakeTried = $true; Conflicts = $summary.Conflicts }
            } catch { }
        }
        return [pscustomobject]@{ VoiceLikely = $false; Verdict = 'not-fixed'; Repaired = $false; Actions = @($actions.ToArray()); CurrentFake = $originalFake; NextFakeTried = $false; Conflicts = $summary.Conflicts }
    }
    Write-Host (Get-UiText -Russian '  Шаг 2: перебор UDP-фейков голоса (каждый с перезапуском и проверкой)…' -English '  Step 2: trying the voice UDP fakes (each with a restart and a probe)…') -ForegroundColor DarkGray
    $tried = 0
    foreach ($name in $fakeNames) {
        if ($name -eq $originalFake) { continue }
        if ($tried -ge $MaxFakeTries) { break }
        $tried++
        Write-Host ((Get-UiText -Russian '  Пробую фейк: {0} ({1}/{2})…' -English '  Trying fake: {0} ({1}/{2})…') -f $name, $tried, $MaxFakeTries) -ForegroundColor DarkGray
        try {
            Set-ActiveFake -Target 'discord' -FakeBaseName $name
        } catch {
            Write-Host ((Get-UiText -Russian '  Фейк {0} не применился: {1}' -English '  Fake {0} failed to apply: {1}') -f $name, $_.Exception.Message) -ForegroundColor Yellow
            continue
        }
        [void](Restart-ZapretBypassService)
        $quick = Test-VoiceQuickProbe
        if ($quick.VoiceLikely) {
            $actions.Add(('фейк {0} → {1}' -f $originalFake, $name))
            $actions.Add('перезапуск обхода')
            Write-Host ((Get-UiText -Russian '  Починено фейком «{0}». Переподключитесь к голосу; если пинг останется большим — voice-check next-fake.' -English '  Fixed with fake "{0}". Reconnect to voice; if the ping stays high - voice-check next-fake.') -f $name) -ForegroundColor Green
            return [pscustomobject]@{ VoiceLikely = $true; Verdict = ('fixed-by-fake:{0}' -f $name); Repaired = $true; Actions = @($actions.ToArray()); CurrentFake = $name; NextFakeTried = $false; Conflicts = $summary.Conflicts }
        }
    }

    # Step 3: nothing helped - restore the original fake BYTES (covers a
    # '(custom)' payload too) and explain.
    try {
        if (Restore-ActiveDiscordFake -Bytes $originalBytes -ActivePath $inventory.ActiveDiscordPath) {
            [void](Restart-ZapretBypassService)
            $actions.Add(('фейк возвращён: {0}' -f $originalFake))
        }
    } catch { }
    Write-Host (Get-UiText -Russian '  Автопочинка не помогла. Обычные причины: конфликтующие VPN/обходы (список в начале), фаервол/антивирус, или провайдер режет UDP. Уберите конфликт и повторите; если войс не нужен — можно оставить как есть.' -English '  Auto-repair did not help. Usual causes: conflicting VPN/bypass tools (listed above), firewall/antivirus, or the provider throttling UDP. Remove the conflict and retry.') -ForegroundColor Yellow
    return [pscustomobject]@{ VoiceLikely = $false; Verdict = 'not-fixed'; Repaired = $false; Actions = @($actions.ToArray()); CurrentFake = $originalFake; NextFakeTried = $false; Conflicts = $summary.Conflicts }
}

function Test-DiscordVoiceConnection {
    <#
        Verifies the paths Discord voice needs, without logging in:
        TCP signalling to *.discord.media, UDP reachability (STUN Binding),
        and the active UDP fake substitution (bin\ACTIVE_DISCORD_UDP.bin).
        Also reports conflicting software first. Read-only; safe to run any time.
    #>
    [CmdletBinding()]
    param([int]$TimeoutMs = 3000)
    Write-Host (Get-UiText -Russian '  ПРОВЕРКА ГОЛОСА DISCORD' -English '  DISCORD VOICE CHECK') -ForegroundColor Cyan
    $conflictReport = Get-ZapretConflictReport
    $conflictItems = @($conflictReport.Items)
    if ($conflictItems.Count -eq 0) {
        Write-Host (Get-UiText -Russian '  Конфликты с другими обходами/VPN не найдены.' -English '  No conflicting bypass/VPN software found.') -ForegroundColor DarkGray
    } else {
        foreach ($item in $conflictItems) {
            Write-Host ((Get-UiText -Russian '  [!] возможный конфликт: {0}' -English '  [!] possible conflict: {0}') -f $item) -ForegroundColor Yellow
        }
        Write-Host (Get-UiText -Russian '  Конфликты сами по себе могут рвать голосовой канал — закройте/уберите их и повторите проверку.' -English '  Conflicts alone can break the voice path - close or remove them and re-run this check.') -ForegroundColor Yellow
    }

    $voiceAddresses = @()
    try {
        $voiceAddresses = @([Net.Dns]::GetHostAddresses('discord.media') | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 2 | ForEach-Object { $_.IPAddressToString })
    } catch { }
    if ($voiceAddresses.Count -eq 0) {
        Write-Host (Get-UiText -Russian '  [x] DNS не разрешил discord.media — проверьте интернет и DNS.' -English '  [x] DNS failed to resolve discord.media - check connectivity and DNS.') -ForegroundColor Red
        return [pscustomobject]@{ TcpSignallingOk = $false; UdpFakeOk = $false; UdpStunOk = $false; UdpBaselineOk = $false; FakeTried = $false; Conflicts = $conflictItems; DnsFailed = $true; Verdict = 'dns'; VoiceLikely = $false }
    }
    Write-Host ((Get-UiText -Russian '  Адреса голосовой инфраструктуры: {0}' -English '  Voice infrastructure addresses: {0}') -f ($voiceAddresses -join ', ')) -ForegroundColor DarkGray

    $tcpOk = $false
    foreach ($addr in $voiceAddresses) {
        Write-Host ((Get-UiText -Russian '  Проверяю TCP 443 ({0}) — сигнальный канал голоса…' -English '  Probing TCP 443 ({0}) - voice signalling…') -f $addr) -ForegroundColor DarkGray
        if (Invoke-TcpProbe -Address $addr -Port 443 -TimeoutMs $TimeoutMs) { $tcpOk = $true; break }
    }
    Write-Host ((Get-UiText -Russian '  Сигнальный канал (TCP до discord.media): {0}' -English '  Signalling channel (TCP to discord.media): {0}') -f $(if ($tcpOk) { 'OK' } else { 'НЕ ПРОХОДИТ' })) -ForegroundColor $(if ($tcpOk) { 'Green' } else { 'Red' })

    $fakeTried = $false
    $fakeOk = $false
    $fakePath = Join-Path $script:BinDir 'ACTIVE_DISCORD_UDP.bin'
    if (Test-Path -LiteralPath $fakePath -PathType Leaf) {
        $fakeBytes = [IO.File]::ReadAllBytes($fakePath)
        if ($fakeBytes.Length -gt 0) {
            $fakeTried = $true
            Write-Host (Get-UiText -Russian '  Отправляю UDP-датаграммы с активным фейком (ACTIVE_DISCORD_UDP.bin)…' -English '  Sending UDP datagrams with the active fake (ACTIVE_DISCORD_UDP.bin)…') -ForegroundColor DarkGray
            foreach ($addr in $voiceAddresses) {
                foreach ($port in @(443, 3478)) {
                    $result = Invoke-UdpProbe -Address $addr -Port $port -Payload $fakeBytes -TimeoutMs $TimeoutMs
                    if ($result.Ok) { $fakeOk = $true; break }
                }
                if ($fakeOk) { break }
            }
        }
    }
    if (-not $fakeTried) {
        Write-Host (Get-UiText -Russian '  [!] bin\ACTIVE_DISCORD_UDP.bin не найден — проверка через фейк пропущена (выберите фейк в меню 7).' -English '  [!] bin\ACTIVE_DISCORD_UDP.bin is missing - fake probe skipped (pick a fake in menu 7).') -ForegroundColor Yellow
    } else {
        Write-Host ((Get-UiText -Russian '  UDP с активным фейком: {0}' -English '  UDP with the active fake: {0}') -f $(if ($fakeOk) { 'ответ получен (OK)' } else { 'ответа нет' })) -ForegroundColor $(if ($fakeOk) { 'Green' } else { 'Yellow' })
    }

    $stunRequest = New-StunBindingRequest
    $stunTransaction = $stunRequest[8..19]
    $stunOk = $false
    foreach ($addr in $voiceAddresses) {
        foreach ($port in @(3478, 443)) {
            $result = Invoke-UdpProbe -Address $addr -Port $port -Payload $stunRequest -TimeoutMs $TimeoutMs
            if ($result.Ok) {
                $stunOk = $true
                $validStun = Test-StunResponseBytes -Response $result.Response -TransactionId $stunTransaction
                Write-Host ((Get-UiText -Russian '  STUN-ответ от {0}:{1}: получен{2}' -English '  STUN reply from {0}:{1}: received{2}') -f $addr, $port, $(if ($validStun) { ' (валидный)' } else { ' (не STUN, но канал жив)' })) -ForegroundColor Green
                break
            }
        }
        if ($stunOk) { break }
    }
    Write-Host ((Get-UiText -Russian '  UDP до Discord (STUN): {0}' -English '  UDP to Discord (STUN): {0}') -f $(if ($stunOk) { 'OK' } else { 'ответа нет' })) -ForegroundColor $(if ($stunOk) { 'Green' } else { 'Yellow' })

    $baselineOk = $false
    try {
        $baselineAddress = @([Net.Dns]::GetHostAddresses('stun.l.google.com') | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1 | ForEach-Object { $_.IPAddressToString })
        if ($baselineAddress.Count -gt 0) {
            Write-Host ((Get-UiText -Russian '  Базовая UDP-проверка (Google STUN {0}:19302)…' -English '  UDP baseline probe (Google STUN {0}:19302)…') -f $baselineAddress[0]) -ForegroundColor DarkGray
            $result = Invoke-UdpProbe -Address $baselineAddress[0] -Port 19302 -Payload $stunRequest -TimeoutMs $TimeoutMs
            $baselineOk = [bool]$result.Ok
        }
    } catch { }
    Write-Host ((Get-UiText -Russian '  Базовый UDP (вообще): {0}' -English '  UDP baseline (in general): {0}') -f $(if ($baselineOk) { 'OK' } else { 'ответа нет' })) -ForegroundColor $(if ($baselineOk) { 'Green' } else { 'Red' })

    $verdict = Get-VoiceCheckVerdict -TcpOk $tcpOk -UdpFakeOk $fakeOk -UdpStunOk $stunOk -UdpBaselineOk $baselineOk -DnsFailed $false
    Write-Host ''
    if ($verdict.Code -eq 'ok') {
        Write-Host (Get-UiText -Russian '  ИТОГ: сигнальный и UDP-каналы проходят — голосовой путь выглядит рабочим. Если войс всё равно не подключается, смените фейк (меню 7) и проверьте, не мешает ли антивирус/фаервол.' -English '  RESULT: signalling and UDP paths work - the voice path looks healthy. If voice still fails, try another fake (menu 7) and check antivirus/firewall.') -ForegroundColor Green
    } elseif ($verdict.Code -eq 'udp-wide') {
        Write-Host (Get-UiText -Russian '  ИТОГ: UDP не проходит вообще — чаще всего мешает конфликтующая программа (список выше), фаервол или провайдер. Уберите конфликт и повторите проверку.' -English '  RESULT: UDP does not pass at all - usually a conflicting program (listed above), a firewall, or the provider. Remove the conflict and re-run the check.') -ForegroundColor Red
    } elseif ($verdict.Code -eq 'tcp') {
        Write-Host (Get-UiText -Russian '  ИТОГ: сигнальный канал до discord.media не проходит — проблема с TCP-трафиком/обходом, голос не установится.' -English '  RESULT: the signalling channel to discord.media does not pass - a TCP/bypass issue; voice cannot be established.') -ForegroundColor Red
    } else {
        Write-Host (Get-UiText -Russian '  ИТОГ: UDP в целом работает, но к Discord не проходит. Попробуйте другой фейк для Discord (меню 7), затем перезапустите службу и повторите проверку.' -English '  RESULT: UDP works in general but not towards Discord. Try another Discord fake (menu 7), restart the service, and re-run the check.') -ForegroundColor Yellow
    }
    return [pscustomobject]@{
        TcpSignallingOk = $tcpOk; UdpFakeOk = $fakeOk; UdpStunOk = $stunOk
        UdpBaselineOk = $baselineOk; FakeTried = $fakeTried
        Conflicts = $conflictItems; DnsFailed = $false
        Verdict = $verdict.Code; VoiceLikely = $verdict.VoiceLikely
    }
}
