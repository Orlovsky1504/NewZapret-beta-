#requires -Version 4.0
<#
.SYNOPSIS
    Pre-flight validation for zapret-discord-youtube.
    Runs on Windows PowerShell 5.1+ and PowerShell 7+ (including Linux/macOS
    for the platform-independent checks).

.EXAMPLE
    powershell -File tests\Test-Build.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\Zapret.psm1') -Force
$testModuleLogRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret-test-module-logs-{0}' -f [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testModuleLogRoot -Force | Out-Null
$testZapretModule = Get-Module Zapret
& $testZapretModule { param($LogPath) $script:LogDir = $LogPath } $testModuleLogRoot

$script:failures = New-Object System.Collections.Generic.List[string]
$script:passes = 0

function Check {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:passes++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        $script:failures.Add($Name)
    }
}

function Test-ZipEntryHasUtf8NameFlag {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EntryName
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $lastHeaderOffset = $bytes.Length - 46
        for ($offset = 0; $offset -le $lastHeaderOffset; $offset++) {
            if ($bytes[$offset] -ne 0x50 -or $bytes[$offset + 1] -ne 0x4b -or
                $bytes[$offset + 2] -ne 0x01 -or $bytes[$offset + 3] -ne 0x02) { continue }
            $nameLength = [BitConverter]::ToUInt16($bytes, $offset + 28)
            $extraLength = [BitConverter]::ToUInt16($bytes, $offset + 30)
            $commentLength = [BitConverter]::ToUInt16($bytes, $offset + 32)
            $nextHeaderOffset = $offset + 46 + $nameLength + $extraLength + $commentLength
            if ($nextHeaderOffset -gt $bytes.Length) { return $false }
            $candidateName = [Text.Encoding]::UTF8.GetString($bytes, $offset + 46, $nameLength)
            if ($candidateName -eq $EntryName) {
                return (([int]$bytes[$offset + 9] -band 0x08) -ne 0)
            }
            $offset = $nextHeaderOffset - 1
        }
    } catch {
        return $false
    }
    return $false
}

function New-TestStrategySharePayload {
    param([Parameter(Mandatory = $true)][string]$StrategyArgs, [string]$StrategyId = 'unsafe-case')
    $record = [ordered]@{ id = $StrategyId; name = 'Unsafe Case'; description = ''; args = $StrategyArgs }
    $json = ConvertTo-Json -InputObject $record -Compress -Depth 4
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($json)
    $output = New-Object System.IO.MemoryStream
    $gzip = New-Object System.IO.Compression.GZipStream($output, [System.IO.Compression.CompressionMode]::Compress, $true)
    try { $gzip.Write($bytes, 0, $bytes.Length) } finally { $gzip.Dispose() }
    $encoded = [Convert]::ToBase64String($output.ToArray())
    $output.Dispose()
    return ('zapret1:' + $encoded)
}

Write-Host ''
Write-Host '== Strategies ==' -ForegroundColor Cyan

$strategies = Get-Strategies
Check 'at least 22 strategies defined' ($strategies.Count -ge 22)
Check 'strategy ids are unique' (($strategies | Select-Object -ExpandProperty id -Unique).Count -eq $strategies.Count)
Check 'strategy names are unique' (($strategies | Select-Object -ExpandProperty name -Unique).Count -eq $strategies.Count)
$carrierCandidateIds = @('carrier-mts','carrier-megafon','carrier-tele2','carrier-yota')
$carrierCandidates = @($strategies | Where-Object { $_.id -in $carrierCandidateIds })
Check 'four narrowly scoped mobile-carrier strategies are defined' ($carrierCandidates.Count -eq 4)
$mobileListPath = Join-Path $repoRoot 'lists/list-mobile-apps.txt'
$mobileDomains = @(Get-Content -LiteralPath $mobileListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
Check 'mobile target list covers YouTube, Discord, and WhatsApp' (@('youtube.com','googlevideo.com','discord.com','discord.media','whatsapp.com','whatsapp.net' | Where-Object { $mobileDomains -contains $_ }).Count -eq 6)
Check 'carrier strategies use the narrow list and skip broad IPSet/game rules' (@($carrierCandidates | Where-Object { $_.args -notmatch 'list-mobile-apps\.txt' -or $_.args -match 'ipset-all\.txt|\{GAME_(TCP|UDP)\}|list-general\.txt|list-google\.txt' }).Count -eq 0)
$generalListPath = Join-Path $repoRoot 'lists/list-general.txt'
$generalDomains = @(Get-Content -LiteralPath $generalListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
Check 'default strategy host list includes WhatsApp domains' (@('whatsapp.com','whatsapp.net','wa.me' | Where-Object { $generalDomains -contains $_ }).Count -eq 3)
$telegramIpSetPath = Join-Path $repoRoot 'lists/ipset-telegram.txt'
$telegramCidrs = @(Get-Content -LiteralPath $telegramIpSetPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
Check 'Telegram IP set file stays as an empty compatibility stub' ((Test-Path -LiteralPath $telegramIpSetPath -PathType Leaf) -and $telegramCidrs.Count -eq 0)
$telegramHostDomains = @('telegram.org','telegram.me','telegram.dog','telegram-cdn.org','t.me','telegra.ph','telesco.pe')
Check 'general and mobile host lists contain no Telegram domains' (@($telegramHostDomains | Where-Object { $generalDomains -contains $_ -or $mobileDomains -contains $_ }).Count -eq 0)
Check 'no built-in strategy references Telegram rules, ports, or IP sets' (@($strategies | Where-Object { $_.args -match 'ipset-telegram|(?<![0-9])5222(?![0-9])' -or ($_.description -and $_.description -match 'Telegram') }).Count -eq 0)
Check 'carrier profiles skip broad IPSet and game rules' (@($carrierCandidates | Where-Object { $_.args -match 'ipset-all\.txt|\{GAME_(TCP|UDP)\}' }).Count -eq 0)

foreach ($s in $strategies) {
    try {
        $expanded = Expand-StrategyArgs -Template $s.args -GameTcp '1024-65535' -GameUdp '1024-65535'
        $problems = Test-StrategyArgs -Expanded $expanded
        Check ("expands cleanly: {0}" -f $s.id) ($problems.Count -eq 0)
        if ($problems.Count -gt 0) { Write-Host "         $($problems -join '; ')" -ForegroundColor DarkRed }
    } catch {
        Check ("expands cleanly: {0}" -f $s.id) $false
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}

$generalStrategy = $strategies | Where-Object { $_.id -eq 'general' } | Select-Object -First 1
$exp = Expand-StrategyArgs -Template $generalStrategy.args -BinDir 'C:\zapret\bin' -ListsDir 'C:\zapret\lists' -GameTcp '1024-65535' -GameUdp '12'
Check 'BIN placeholder expands to a directory prefix' ($exp -match 'C:\\zapret\\bin[\\/]quic_initial_www_google_com\.bin')
Check 'LISTS placeholder expands to a directory prefix' ($exp -match 'C:\\zapret\\lists[\\/]list-general\.txt')
Check 'GAME_TCP placeholder expands' ($exp -match '--filter-tcp=1024-65535')
Check 'GAME_UDP placeholder expands' ($exp -match '--filter-udp=12')
Check 'no placeholders remain' ($exp -notmatch '\{[A-Za-z_]+\}')

Write-Host ''
Write-Host '== Referenced payload files ==' -ForegroundColor Cyan

# user lists are created at runtime (they are gitignored); make sure they exist like a real run would
[void](Initialize-UserLists)

$referenced = @()
foreach ($s in $strategies) {
    $expanded = Expand-StrategyArgs -Template $s.args -BinDir (Join-Path $repoRoot 'bin') -ListsDir (Join-Path $repoRoot 'lists') -GameTcp '12' -GameUdp '12'
    foreach ($m in [regex]::Matches($expanded, '"([^"]+)"')) {
        $value = $m.Groups[1].Value
        if ($value -match '\.(bin|txt)$') { $referenced += $value }
    }
}
Check 'strategies reference payload files' ($referenced.Count -gt 0)
$missing = @($referenced | Where-Object { -not (Test-Path -LiteralPath $_) } | Sort-Object -Unique)
Check ("all {0} referenced payload files exist" -f $referenced.Count) ($missing.Count -eq 0)
$missing | ForEach-Object { Write-Host "         missing: $_" -ForegroundColor DarkRed }

Write-Host ''
Write-Host '== Port range validation ==' -ForegroundColor Cyan

Check '1024-65535 valid'            (Test-PortRange '1024-65535')
Check 'comma list valid'            (Test-PortRange '80,443,1024-1934')
Check 'single port valid'           (Test-PortRange '443')
Check 'spaces tolerated'            (Test-PortRange '1024 - 1934, 2000')
Check 'rejects port 0'              (-not (Test-PortRange '0-100'))
Check 'rejects reversed range'      (-not (Test-PortRange '500-100'))
Check 'rejects port > 65535'        (-not (Test-PortRange '1-65536'))
Check 'rejects garbage'             (-not (Test-PortRange 'abc'))
Check 'rejects empty'               (-not (Test-PortRange ''))
Check 'rejects mixed garbage'       (-not (Test-PortRange '80,foo'))

Write-Host ''
Write-Host '== IPSet state parsing ==' -ForegroundColor Cyan

Check "empty => 'any'"              ((Get-IpsetStateFromContent -Content '') -eq 'any')
Check "$($script:IpsetSentinel) => 'none'" ((Get-IpsetStateFromContent -Content "203.0.113.113/32`r`n") -eq 'none')
Check "CIDR list => 'loaded'"       ((Get-IpsetStateFromContent -Content "1.0.0.0/24`n2.0.0.0/24") -eq 'loaded')

Write-Host ''
Write-Host '== Preview plans and side-effect guards ==' -ForegroundColor Cyan
$previewModule = Get-Module Zapret
$previewRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret-preview-test-{0}' -f [Guid]::NewGuid().ToString('N'))
$previewListDir = Join-Path $previewRoot 'lists'
$previewLogDir = Join-Path $previewRoot 'logs'
$previewIpset = Join-Path $previewListDir 'ipset-all.txt'
$previewIpsetBackup = Join-Path $previewListDir 'ipset-all.txt.backup'
$previewHosts = Join-Path $previewRoot 'hosts'
$previewMissingHosts = Join-Path $previewRoot 'hosts-not-created'
New-Item -ItemType Directory -Path $previewListDir -Force | Out-Null
[IO.File]::WriteAllText($previewIpset, "198.51.100.1/32`r`n")
[IO.File]::WriteAllText($previewIpsetBackup, "203.0.113.1/32`r`n")
[IO.File]::WriteAllText($previewHosts, "127.0.0.1 localhost`r`n")
$previewIpsetBefore = [IO.File]::ReadAllText($previewIpset)
$previewBackupBefore = [IO.File]::ReadAllText($previewIpsetBackup)
$previewHostsBefore = [IO.File]::ReadAllText($previewHosts)
$savedPreviewModuleState = $null
try {
    $savedPreviewModuleState = & $previewModule {
        param($RootPath, $ListDirectory, $IpsetPath, $BackupPath, $LogPath, $CustomStrategiesPath)
        $saved = [pscustomobject]@{
            Root = $script:Root; ListsDir = $script:ListsDir; IpsetFile = $script:IpsetFile
            IpsetBackup = $script:IpsetBackup; LogDir = $script:LogDir; IpsetUrl = $script:IpsetUrl
            HostsUrl = $script:HostsUrl; UserStrategiesFile = $script:UserStrategiesFile
            OnWindows = $script:OnWindows; InvokeDownload = (Get-Command Invoke-Download).ScriptBlock
        }
        $script:Root = $RootPath; $script:ListsDir = $ListDirectory; $script:IpsetFile = $IpsetPath
        $script:IpsetBackup = $BackupPath; $script:LogDir = $LogPath; $script:UserStrategiesFile = $CustomStrategiesPath
        $script:IpsetUrl = 'https://unit.invalid/ipset'; $script:HostsUrl = 'https://unit.invalid/hosts'
        Set-Item Function:script:Invoke-Download -Value {
            param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 30, [switch]$NoLog)
            if ($Url -like '*ipset*') {
                $downloadLines = @(1..110 | ForEach-Object { '198.51.100.{0}/32' -f $_ })
                [IO.File]::WriteAllLines($OutFile, [string[]]$downloadLines)
            } else {
                [IO.File]::WriteAllText($OutFile, "198.51.100.9 example.com`r`n")
            }
            return $true
        }
        return $saved
    } $previewRoot $previewListDir $previewIpset $previewIpsetBackup $previewLogDir (Join-Path $previewRoot 'strategies-user.json')

    $modePlan = Set-IpsetMode -Mode any -Preview
    $listPlan = Update-IpsetList -Preview
    $hostsPlan = Update-HostsFile -Preview -HostsPath $previewHosts
    $missingHostsPlan = Update-HostsFile -Preview -HostsPath $previewMissingHosts
    $bundlePlan = New-SupportBundle -DestinationPath (Join-Path $previewRoot 'bundle') -Preview
    Check 'IPSet preview exposes target mode, paths, admin requirement and rollback' ($modePlan.TargetMode -eq 'any' -and $modePlan.IpsetPath -eq $previewIpset -and $modePlan.RequiresAdministrator -and $modePlan.RollbackCommand -eq 'zapret.ps1 rollback')
    Check 'IPSet-list preview reports validated entries and rollback' ($listPlan.Preview -and $listPlan.DownloadedEntries -eq 110 -and $listPlan.TargetPath -eq $previewIpset -and $listPlan.RequiresAdministrator -and $listPlan.RollbackCommand -eq 'zapret.ps1 rollback')
    Check 'hosts preview reports exact planned entry count and rollback' ($hostsPlan.Preview -and $hostsPlan.PlannedEntries -eq 1 -and $hostsPlan.HostsPath -eq $previewHosts -and $hostsPlan.RequiresAdministrator -and $hostsPlan.RollbackCommand -eq 'zapret.ps1 rollback')
    Check 'hosts preview does not create a missing hosts file' ($missingHostsPlan.Preview -and -not (Test-Path -LiteralPath $previewMissingHosts))
    Check 'support-bundle preview shows redaction mode and planned file list without writing' ($bundlePlan.PrivacyMode -eq 'redacted' -and $bundlePlan.Files -contains 'privacy-report.txt' -and -not (Test-Path -LiteralPath $bundlePlan.DestinationPath))
    Check 'IPSet/hosts previews leave target files, backups, rollback logs and logs unchanged' (([IO.File]::ReadAllText($previewIpset) -eq $previewIpsetBefore) -and ([IO.File]::ReadAllText($previewIpsetBackup) -eq $previewBackupBefore) -and ([IO.File]::ReadAllText($previewHosts) -eq $previewHostsBefore) -and -not (Test-Path -LiteralPath ($previewIpset + '.bak')) -and -not (Test-Path -LiteralPath $previewLogDir))
} catch {
    Check 'preview plans and side-effect guards execute successfully' $false
    Write-Host ("         {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
} finally {
    if ($savedPreviewModuleState) {
        & $previewModule {
            param($saved)
            $script:Root = $saved.Root; $script:ListsDir = $saved.ListsDir; $script:IpsetFile = $saved.IpsetFile
            $script:IpsetBackup = $saved.IpsetBackup; $script:LogDir = $saved.LogDir; $script:IpsetUrl = $saved.IpsetUrl
            $script:HostsUrl = $saved.HostsUrl; $script:UserStrategiesFile = $saved.UserStrategiesFile; $script:OnWindows = $saved.OnWindows
            Set-Item Function:script:Invoke-Download -Value $saved.InvokeDownload
        } $savedPreviewModuleState
    }
    Remove-Item -LiteralPath $previewRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '== Version comparison ==' -ForegroundColor Cyan

Check 'remote newer detected'       ((Compare-VersionTexts -Remote '2.0.0'  -Local '1.10.4') -gt 0)
Check 'equal versions detected'     ((Compare-VersionTexts -Remote '2.0.0'  -Local '2.0.0')  -eq 0)
Check 'local newer detected'        ((Compare-VersionTexts -Remote '1.0.0'  -Local '2.0.0')  -lt 0)
Check 'v prefix tolerated'          ((Compare-VersionTexts -Remote 'v2.0.0' -Local '2.0.0')  -eq 0)

Write-Host ''
Write-Host '== Config round-trip ==' -ForegroundColor Cyan

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('zapret-test-config-{0}.json' -f ([Guid]::NewGuid().ToString('N')))
try {
    $defaults = Get-Config -Path $tmp
    Check 'defaults: checkUpdates = true'      ([bool]$defaults.checkUpdates -eq $true)
    Check 'defaults: uiLanguage = ru'           ($defaults.uiLanguage -eq 'ru')
    Check 'defaults: no carrier strategy is preselected' (@('mts','megafon','tele2','yota' | Where-Object { $defaults.carrierStrategies[$_] }).Count -eq 0)
    Check "locale helper selects Russian or English text" ((Get-UiText -Russian 'Привет' -English 'Hello' -Language ru) -eq 'Привет' -and (Get-UiText -Russian 'Привет' -English 'Hello' -Language en) -eq 'Hello')
    Check "defaults: gameFilter.mode = 'disabled'" ($defaults.gameFilter.mode -eq 'disabled')
    Check 'defaults: tcp range 1024-65535'     ($defaults.gameFilter.tcp -eq '1024-65535')

    $cfg2 = Update-Config -Path $tmp -Changes @{ gameFilterMode = 'all'; gameFilterTcp = '2000-3000'; checkUpdates = $false; uiLanguage = 'en' }
    Check 'update: mode persisted'             ($cfg2.gameFilter.mode -eq 'all')
    Check 'update: interface language persisted' ($cfg2.uiLanguage -eq 'en' -and (Get-UiLanguage -Path $tmp) -eq 'en')
    Check 'update: tcp persisted'              ($cfg2.gameFilter.tcp -eq '2000-3000')
    Check 'update: checkUpdates persisted'     ([bool]$cfg2.checkUpdates -eq $false)

    $cfg3 = Get-Config -Path $tmp
    Check 'reload reads persisted values'      (($cfg3.gameFilter.mode -eq 'all') -and ($cfg3.gameFilter.tcp -eq '2000-3000') -and (-not $cfg3.checkUpdates) -and ($cfg3.uiLanguage -eq 'en'))

    $savedCarrier = Set-MobileCarrierBestStrategy -Carrier megafon -StrategyId carrier-megafon -ConfigPath $tmp
    Check 'live-tested carrier strategy is persisted per operator' ($savedCarrier -eq 'carrier-megafon' -and (Get-MobileCarrierBestStrategy -Carrier megafon -ConfigPath $tmp) -eq 'carrier-megafon' -and $null -eq (Get-MobileCarrierBestStrategy -Carrier mts -ConfigPath $tmp))
    $cfgCarrierReload = Get-Config -Path $tmp
    Check 'carrier strategy survives config reload and later updates' ($cfgCarrierReload.carrierStrategies.megafon -eq 'carrier-megafon')
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$tmpBad = Join-Path ([IO.Path]::GetTempPath()) ('zapret-test-bad-{0}.json' -f ([Guid]::NewGuid().ToString('N')))
try {
    [IO.File]::WriteAllText($tmpBad, '{ this is not json !!!')
    $cfgBad = Get-Config -Path $tmpBad
    Check 'broken config.json falls back to defaults' (($cfgBad.gameFilter.mode -eq 'disabled') -and [bool]$cfgBad.checkUpdates -and ($cfgBad.uiLanguage -eq 'ru'))
} finally {
    Remove-Item $tmpBad -Force -ErrorAction SilentlyContinue
}

$tmpLanguage = Join-Path ([IO.Path]::GetTempPath()) ('zapret-test-language-{0}.json' -f ([Guid]::NewGuid().ToString('N')))
try {
    [void](Set-UiLanguage -Language en -Path $tmpLanguage)
    Check 'Set-UiLanguage persists English' ((Get-UiLanguage -Path $tmpLanguage) -eq 'en' -and (Get-UiText -Russian 'Привет' -English 'Hello') -eq 'Hello')
    Check 'message catalog translates Russian pause text to English' ((ConvertTo-UiMessage -Text "Обход приостановлен. Стратегия 'alt' будет восстановлена через 5 мин.") -match 'bypass is paused.*resume in 5 minutes')
    Check 'message catalog localizes uninstall stop failures in English' ((ConvertTo-UiMessage -Text 'Не удалось остановить службу zapret (sc.exe exit 5). access denied Перезагрузите Windows и повторите удаление.') -match 'Could not stop the zapret service.*Restart Windows and retry uninstall')
    [void](Set-UiLanguage -Language ru -Path $tmpLanguage)
    Check 'message catalog translates English text to Russian' ((ConvertTo-UiMessage -Text 'Hosts file not found - nothing to remove.') -match 'Файл hosts не найден')
    Check 'message catalog localizes verified service removal status' ((ConvertTo-UiMessage -Text "Service 'zapret' stopped and removed.") -match 'Служба zapret остановлена и удалена')
    Check 'message catalog localizes missing MTU metadata' ((ConvertTo-UiMessage -Text 'Could not determine the MTU of the active IPv4 interface.') -match 'Не удалось прочитать MTU')
    Check 'Set-UiLanguage persists Russian' ((Get-UiLanguage -Path $tmpLanguage) -eq 'ru')
} finally {
    Remove-Item $tmpLanguage -Force -ErrorAction SilentlyContinue
    [void](Get-UiLanguage)
}

Write-Host ''
Write-Host ''
Write-Host '== Auto-select ==' -ForegroundColor Cyan

Check 'Invoke-AutoSelect exported'          ([bool](Get-Command Invoke-AutoSelect -ErrorAction SilentlyContinue))
Check 'Select-BestStrategy exported'        ([bool](Get-Command Select-BestStrategy -ErrorAction SilentlyContinue))

$repeatStrategyDefinitions = @(
    [pscustomobject]@{ id = 'general'; args = '--filter-tcp=443' },
    [pscustomobject]@{ id = 'fake-tls-auto-alt2'; args = '--filter-tcp=80,443 --dpi-desync=fake' }
)
$resolvedRepeatStrategy = Get-BenchmarkStrategyById -Strategies $repeatStrategyDefinitions -Id 'FAKE-TLS-AUTO-ALT2'
Check 'auto-select resolves the leaderboard ID back to the strategy definition and args' ($resolvedRepeatStrategy -and $resolvedRepeatStrategy.id -eq 'fake-tls-auto-alt2' -and $resolvedRepeatStrategy.args -eq '--filter-tcp=80,443 --dpi-desync=fake')
Check 'auto-select returns no strategy definition for an unknown result ID' ($null -eq (Get-BenchmarkStrategyById -Strategies $repeatStrategyDefinitions -Id 'missing'))

$mockResults = @(
    [pscustomobject]@{ Id = 'slow';    Name = 'slow';    Passed = 6; TotalMs = 9000;              StartFailed = $false; Targets = @() },
    [pscustomobject]@{ Id = 'best';    Name = 'best';    Passed = 6; TotalMs = 3000;              StartFailed = $false; Targets = @() },
    [pscustomobject]@{ Id = 'partial'; Name = 'partial'; Passed = 3; TotalMs = 1000;              StartFailed = $false; Targets = @() },
    [pscustomobject]@{ Id = 'broken';  Name = 'broken';  Passed = 0; TotalMs = [double]::MaxValue; StartFailed = $true;  Targets = @() }
)
$ranked = Select-BestStrategy -Results $mockResults
Check 'auto-select: fastest all-pass strategy ranks first'  ($ranked[0].Id -eq 'best')
Check 'auto-select: partial coverage outranked by full pass' (($ranked[1].Id -eq 'slow') -and ($ranked[2].Id -eq 'partial'))
Check 'auto-select: failed-to-start ranks last'             ($ranked[-1].Id -eq 'broken')
$speedRank = Select-BestStrategy -Results @(
    [pscustomobject]@{ Id = 'shaped'; Passed = 6; TotalMs = 100; StartFailed = $false; SpeedKBs = 199.9 },
    [pscustomobject]@{ Id = 'unshaped'; Passed = 6; TotalMs = 900; StartFailed = $false; SpeedKBs = 200.1 }
)
Check 'auto-select: at equal Passed, >200 KB/s outranks shaped strategies' ($speedRank[0].Id -eq 'unshaped')

$confidenceTargets = @([pscustomobject]@{ Name='DiscordMain'; Ok=$true }, [pscustomobject]@{ Name='YouTube'; Ok=$false })
$confidenceCandidate = [pscustomobject]@{ Id='candidate'; Passed=1; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$false; FreezeOk=$true; FreezePassed=0; SpeedKBs=0; ServicesPassed=1; AllServicesPassed=$false }
$confidenceRepeat = [pscustomobject]@{ Id='candidate'; Passed=1; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$false; FreezeOk=$true; FreezePassed=0; SpeedKBs=0; ServicesPassed=1; AllServicesPassed=$false }
$confidenceFirst = Get-AutoSelectConfidence -Candidate $confidenceCandidate -Verification $confidenceRepeat
Check 'auto-select confidence allows an identical repeatable result with no current service' ($confidenceFirst.Stable -and $confidenceFirst.CanInstall)
$driftRepeat = [pscustomobject]@{ Id='candidate'; Passed=1; StartFailed=$false; Targets=@([pscustomobject]@{Name='DiscordMain';Ok=$false},[pscustomobject]@{Name='YouTube';Ok=$true}); FreezeChecked=$false; FreezeOk=$true; FreezePassed=0; SpeedKBs=0; ServicesPassed=1; AllServicesPassed=$false }
Check 'auto-select confidence rejects a changed successful endpoint set' (-not (Get-AutoSelectConfidence -Candidate $confidenceCandidate -Verification $driftRepeat).CanInstall)
$currentSameCoverage = [pscustomobject]@{ Id='current'; Passed=1; ServicesPassed=1; SpeedKBs=0 }
$confidenceNoGain = Get-AutoSelectConfidence -Candidate $confidenceCandidate -Verification $confidenceRepeat -CurrentResult $currentSameCoverage -CurrentStrategy 'current'
Check 'auto-select confidence does not switch strategies without meaningful improvement' ($confidenceNoGain.Decision -eq 'no-improvement' -and -not $confidenceNoGain.CanInstall)
$currentCandidate = Get-AutoSelectConfidence -Candidate $confidenceCandidate -Verification $confidenceRepeat -CurrentResult $confidenceCandidate -CurrentStrategy 'candidate'
Check 'auto-select confidence keeps the already-winning installed strategy' ($currentCandidate.Decision -eq 'keep-current' -and -not $currentCandidate.CanInstall)
$unmeasuredCurrent = Get-AutoSelectConfidence -Candidate $confidenceCandidate -Verification $confidenceRepeat -CurrentStrategy 'installed-not-in-benchmark'
Check 'auto-select confidence blocks replacement when installed strategy has no measured baseline' ($unmeasuredCurrent.Stable -and $unmeasuredCurrent.Decision -eq 'unmeasured-current' -and -not $unmeasuredCurrent.CanInstall)
$unresolvedInstalled = Get-AutoSelectConfidence -Candidate $confidenceCandidate -Verification $confidenceRepeat -CurrentPresent
Check 'auto-select confidence fails closed when an installed service strategy cannot be resolved' ($unresolvedInstalled.Decision -eq 'unmeasured-current' -and -not $unresolvedInstalled.CanInstall)
$fastCandidate = [pscustomobject]@{ Id='candidate'; Passed=4; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$true; FreezeOk=$true; FreezePassed=1; SpeedKBs=300; ServicesPassed=2; AllServicesPassed=$false }
$fastRepeat = [pscustomobject]@{ Id='candidate'; Passed=4; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$true; FreezeOk=$true; FreezePassed=1; SpeedKBs=275; ServicesPassed=2; AllServicesPassed=$false }
$currentSlow = [pscustomobject]@{ Id='current'; Passed=4; ServicesPassed=2; SpeedKBs=200 }
Check 'auto-select confidence accepts a repeat-verified 25%+ transfer-speed improvement' ((Get-AutoSelectConfidence -Candidate $fastCandidate -Verification $fastRepeat -CurrentResult $currentSlow -CurrentStrategy 'current' -FreezeRequired).CanInstall)
$slowRepeat = [pscustomobject]@{ Id='candidate'; Passed=4; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$true; FreezeOk=$true; FreezePassed=1; SpeedKBs=240; ServicesPassed=2; AllServicesPassed=$false }
Check 'auto-select confidence rejects a speed gain that misses the improvement threshold' (-not (Get-AutoSelectConfidence -Candidate $fastCandidate -Verification $slowRepeat -CurrentResult $currentSlow -CurrentStrategy 'current' -FreezeRequired).CanInstall)
$failedFreeze = [pscustomobject]@{ Id='candidate'; Passed=4; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$true; FreezeOk=$false; FreezePassed=0; SpeedKBs=0; ServicesPassed=2; AllServicesPassed=$false }
Check 'auto-select confidence blocks an inconsistent 64 KB transfer test' (-not (Get-AutoSelectConfidence -Candidate $fastCandidate -Verification $failedFreeze -FreezeRequired).CanInstall)
Check 'Auto-Select restore resumes a service that was running before the test' ((Get-AutoSelectRestoreAction -ServiceInstalled $true -ServiceState 'Running') -eq 'resume-service')
Check 'Auto-Select restore leaves a previously stopped service stopped' ((Get-AutoSelectRestoreAction -ServiceInstalled $true -ServiceState 'Stopped') -eq 'leave-stopped')
Check 'Auto-Select restore resumes a known manual strategy without installing a service' ((Get-AutoSelectRestoreAction -ServiceInstalled $false -ServiceState 'NotInstalled' -ProcessWasRunning $true -ProcessStrategy 'general') -eq 'resume-manual')
Check 'Auto-Select restore requests help for an unknown manual process' ((Get-AutoSelectRestoreAction -ServiceInstalled $false -ProcessWasRunning $true) -eq 'manual-restart-required')
Check 'Auto-Select restore rejects an indeterminate service state' ((Get-AutoSelectRestoreAction -ServiceInstalled $true -ServiceState 'StartPending') -eq 'unknown-service-state')
$carrierCandidate = [pscustomobject]@{ Id='carrier'; Passed=6; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$true; FreezeOk=$true; FreezePassed=1; SpeedKBs=300; ServicesPassed=3; AllServicesPassed=$false }
$carrierRepeat = [pscustomobject]@{ Id='carrier'; Passed=6; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$true; FreezeOk=$true; FreezePassed=1; SpeedKBs=300; ServicesPassed=3; AllServicesPassed=$false }
Check 'auto-select confidence fails closed for carrier scans without all services passing twice' (-not (Get-AutoSelectConfidence -Candidate $carrierCandidate -Verification $carrierRepeat -Carrier -FreezeRequired).CanInstall)
$unstableTransferCandidate = [pscustomobject]@{ Id='candidate'; Passed=4; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$true; FreezeOk=$true; FreezePassed=1; FreezeTargets=@([pscustomobject]@{Name='CDN-A';Ok=$true},[pscustomobject]@{Name='CDN-B';Ok=$false}); SpeedKBs=300; ServicesPassed=2; AllServicesPassed=$false }
$unstableTransferRepeat = [pscustomobject]@{ Id='candidate'; Passed=4; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$true; FreezeOk=$true; FreezePassed=1; FreezeTargets=@([pscustomobject]@{Name='CDN-A';Ok=$false},[pscustomobject]@{Name='CDN-B';Ok=$true}); SpeedKBs=300; ServicesPassed=2; AllServicesPassed=$false }
Check 'auto-select confidence rejects a transfer leader that changes CDN between runs' (-not (Get-AutoSelectConfidence -Candidate $unstableTransferCandidate -Verification $unstableTransferRepeat -FreezeRequired).CanInstall)
$lowerCoverage = [pscustomobject]@{ Id='current'; Passed=5; ServicesPassed=3; SpeedKBs=180 }
$misleadingServiceGain = [pscustomobject]@{ Id='candidate'; Passed=4; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$false; FreezeOk=$true; FreezePassed=0; SpeedKBs=0; ServicesPassed=4; AllServicesPassed=$true }
$misleadingRepeat = [pscustomobject]@{ Id='candidate'; Passed=4; StartFailed=$false; Targets=$confidenceTargets; FreezeChecked=$false; FreezeOk=$true; FreezePassed=0; SpeedKBs=0; ServicesPassed=4; AllServicesPassed=$true }
Check 'auto-select confidence does not trade away endpoint coverage for a service-count gain' (-not (Get-AutoSelectConfidence -Candidate $misleadingServiceGain -Verification $misleadingRepeat -CurrentResult $lowerCoverage -CurrentStrategy 'current').CanInstall)
Check 'auto-setup requires a stable Auto-Select confidence decision before its consent gate' ((Get-Command Invoke-AutoSetup).ScriptBlock.ToString().Contains('AutoSelectConfidence') -and (Get-Command Invoke-AutoSetup).ScriptBlock.ToString().Contains('confidenceAccepted'))
$autoSelectBody = (Get-Command Invoke-AutoSelect).ScriptBlock.ToString()
Check 'Auto-Select repeats the resolved strategy definition rather than the leaderboard result object' ($autoSelectBody.Contains('Get-BenchmarkStrategyById -Strategies $allAvailable -Id ([string]$winner.Id)') -and $autoSelectBody.Contains('Invoke-BenchmarkStrategy -Strategy $winnerStrategy'))
Check 'carrier profile persistence is behind repeat verification' ($autoSelectBody.IndexOf('Set-MobileCarrierBestStrategy -Carrier $Carrier -StrategyId $winner.Id') -gt $autoSelectBody.IndexOf('Get-AutoSelectConfidence -Candidate $winner'))
Check 'Auto-Select measures a current strategy omitted from ranking as a baseline' ($autoSelectBody.Contains('Testing installed strategy') -and $autoSelectBody.Contains('Invoke-BenchmarkStrategy -Strategy $currentStrategyObject[0]'))
Check 'Auto-Select passes installed-service state to the fail-closed install gate' ($autoSelectBody.Contains('-CurrentPresent:$currentBaselineRequired'))
Check 'Auto-Select restores the prior service mode without reinstalling on a declined candidate' ($autoSelectBody.Contains('Get-AutoSelectRestoreAction') -and $autoSelectBody.Contains('Start-Service -Name ''zapret'''))
$benchmarkReportBody = (Get-Command Write-BenchmarkReport).ScriptBlock.ToString()
Check 'Auto-Select report records baseline, repeat verification, and install gate' ($benchmarkReportBody.Contains('Current baseline:') -and $benchmarkReportBody.Contains('Repeat verification:') -and $benchmarkReportBody.Contains('Install gate:'))
Check 'Auto-Select report captures the repeat-verification exception' ($benchmarkReportBody.Contains('Repeat verification error:') -and $benchmarkReportBody.Contains('$VerificationError'))
Check 'Auto-Select report records per-target results for the candidate and repeat' ($benchmarkReportBody.Contains('Target {0}: {1} {2}') -and $benchmarkReportBody.Contains("Label = 'candidate'") -and $benchmarkReportBody.Contains("Label = 'repeat'"))
$reportTestResult = [pscustomobject]@{ Id='candidate'; Name='candidate'; Passed=1; TotalMs=100; StartFailed=$false; SpeedKBs=0; FreezeChecked=$false; Targets=@([pscustomobject]@{Name='DiscordWeb';Ok=$false;Service='Discord'},[pscustomobject]@{Name='DiscordAlt';Ok=$true;Service='Discord'}) }
$repeatErrorReport = Write-BenchmarkReport -Ranked @($reportTestResult) -Winner $reportTestResult -Confidence $confidenceFirst -Verification $null -VerificationError 'repeat template binding failed' -CurrentStrategy '' -CurrentPresent:$false -CurrentResult $null
$repeatErrorReportText = if ($repeatErrorReport) { [IO.File]::ReadAllText($repeatErrorReport) } else { '' }
Check 'Auto-Select report states why repeat verification was not run' ($repeatErrorReportText.Contains('Repeat verification error: repeat template binding failed'))
Check 'Auto-Select report shows which web endpoint failed' ($repeatErrorReportText.Contains('Target candidate: DiscordWeb FAILED') -and $repeatErrorReportText.Contains('Target candidate: DiscordAlt OK'))
if ($repeatErrorReport) { Remove-Item -LiteralPath $repeatErrorReport -Force -ErrorAction SilentlyContinue }
Check 'Auto-Select report explains an installed service whose strategy could not be resolved' ($benchmarkReportBody.Contains('active strategy unresolved - not measured'))
$zapretPs1 = [IO.File]::ReadAllText((Join-Path $repoRoot 'zapret.ps1'))
$instructionText = [IO.File]::ReadAllText((Join-Path $repoRoot 'ИНСТРУКЦИЯ.txt'))
$readmeText = [IO.File]::ReadAllText((Join-Path $repoRoot 'README.md'))
$runtimePowerShellFiles = @(
    (Join-Path $repoRoot 'zapret.ps1'),
    (Join-Path $repoRoot 'src/Zapret.psm1'),
    (Join-Path $repoRoot 'utils/test zapret.ps1'),
    (Join-Path $repoRoot 'Zapret-Control.ps1'),
    (Join-Path $repoRoot 'Update-Zapret.ps1')
) + @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/parts') -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
$missingUtf8Bom = @()
foreach ($psFile in $runtimePowerShellFiles) {
    $psBytes = [IO.File]::ReadAllBytes($psFile)
    if ($psBytes.Length -lt 3 -or $psBytes[0] -ne 0xEF -or $psBytes[1] -ne 0xBB -or $psBytes[2] -ne 0xBF) {
        $missingUtf8Bom += [IO.Path]::GetFileName($psFile)
    }
}
Check 'all shipped PowerShell files keep UTF-8 BOM for Windows PowerShell 5.1' ($missingUtf8Bom.Count -eq 0)
Check 'Russian guide documents the regular/mobile choice and carrier prompt in one Auto-Setup' ($instructionText.Contains('выберите обычный или мобильный интернет') -and $instructionText.Contains('попросит выбрать оператора'))
Check 'Russian guide marks carrier profiles as experimental and unverified' ($instructionText.Contains('не подтверждены реальными испытаниями у операторов') -and $instructionText.Contains('не гарантируют работу'))
Check 'Russian guide explains fail-closed baseline comparison for an installed strategy' ($instructionText.Contains('как базовый вариант') -and $instructionText.Contains('install gate закрыт'))
Check 'Russian guide documents PowerShell and platform-native SHA-256 verification' ($instructionText.Contains('Get-FileHash -LiteralPath $name') -and $instructionText.Contains('shasum -a 256 -c'))
Check 'Russian guide explains that DNS benchmark and MTU Preview perform read-only probes' ($instructionText.Contains('dns benchmark -Preview` выполняет ICMP') -and $instructionText.Contains('mtu-check -Preview` отправляет ICMP'))
Check 'Russian guide documents preservation of the previous service state' ($instructionText.Contains('если служба была остановлена, она остаётся остановленной'))
Check 'Russian guide documents the no-prompt hosts removal flag' ($instructionText.Contains('zapret.ps1 uninstall -RemoveHostsBlock') -and $instructionText.Contains('без вопроса'))
Check 'Russian guide states that Telegram is excluded and unsupported' ($instructionText.Contains('С версии 2.1.27 Telegram исключён из проверок и стратегий') -and $instructionText.Contains('не работает и больше не предлагается'))
Check 'CLI wires the auto-select action'                    ($zapretPs1 -match "'auto-select'")
Check 'menu exposes Auto-Select in both locales'            ($zapretPs1.Contains('Find the best strategy automatically') -and $zapretPs1 -match "'13'\s+\{\s*Invoke-MenuAutoSelect\s*\}")
Check 'menu exposes one unified Auto-Setup instead of a separate mobile picker' ($zapretPs1.Contains('25. Guided auto-setup: regular or mobile internet') -and $zapretPs1 -match "'25'\s+\{\s*Invoke-MenuAutoSetup\s*\}" -and $zapretPs1.Contains('0–25') -and -not $zapretPs1.Contains('Tune a profile for a mobile carrier'))
Check 'CLI supports the four mobile-carrier profiles'       ($zapretPs1.Contains('[ValidateSet(''mts'',''megafon'',''tele2'',''yota'')][string]$Carrier') -and $zapretPs1.Contains('-Carrier $Carrier'))
Check 'menu includes a persistent language switch'            ($zapretPs1.Contains('24. Interface language') -and $zapretPs1 -match "'24'\s+\{\s*Invoke-MenuLanguage\s*\}" -and $zapretPs1.Contains('Set-InterfaceLanguage'))
Check 'menu range and documentation use unified Auto-Setup item 25' ($instructionText.Contains('ПУНКТЫ 0–25') -and $instructionText.Contains('25. Автонастройка: обычный или мобильный интернет'))
Check 'CLI wires auto-setup and its explicit schedule switch'  ($zapretPs1 -match "'auto-setup'\s*\{" -and $zapretPs1.Contains('Invoke-AutoSetup') -and $zapretPs1.Contains('-EnableSchedule:$EnableSchedule'))
Check 'CLI forwards NoInteractive to auto-select'              ($zapretPs1.Contains('-NoInteractive:$NoInteractive -Deep:$Deep'))
Check 'first-run language choice precedes onboarding'          ($zapretPs1.Contains('Язык интерфейса / Interface language') -and $zapretPs1.IndexOf('Set-InterfaceLanguage -Language $firstRunLanguage') -lt $zapretPs1.IndexOf('Welcome! This is your first time using zapret.'))
Check 'Russian guide documents unified Auto-Setup and default-no consent' ($instructionText.Contains('auto-setup') -and $instructionText.Contains('пустой ответ означает «нет»') -and $instructionText.Contains('zapret.ps1 auto-setup -Install'))
Check 'README describes mobile selection within the guided setup' ($readmeText.Contains('Guided Auto-Setup (меню 25)') -and $readmeText.Contains('обычный') -and $readmeText.Contains('предлагает выбрать МТС'))
Check 'Invoke-AutoSetup exported'                              ([bool](Get-Command Invoke-AutoSetup -ErrorAction SilentlyContinue))
$autoSetupBody = (Get-Command Invoke-AutoSetup).ScriptBlock.ToString()
Check 'guided setup prompts for connection type and carrier before benchmarking' ($autoSetupBody.Contains('Resolve-AutoSetupConnectionTypeChoice') -and $autoSetupBody.Contains('Resolve-AutoSetupCarrierChoice') -and $autoSetupBody.Contains('Invoke-AutoSelect -NoInteractive -Fast:$useFast'))
Check 'guided mobile setup uses the selected carrier and fail-closed carrier checks' ($autoSetupBody.Contains('$useFast = [bool]($Fast -or $Carrier)') -and $autoSetupBody.Contains('-Carrier $Carrier') -and $autoSetupBody.Contains('$Carrier -and (-not $winner.AllServicesPassed -or -not $winner.FreezeOk)') -and $autoSelectBody.Contains('$freezeRequired = [bool]($CheckFreeze -or $Deep -or $Carrier)'))
Check 'non-interactive setup defaults to regular candidates unless a carrier is supplied' ($autoSetupBody.Contains('Non-interactive mode: using the regular strategy set') -and $autoSetupBody.Contains('Specify -Carrier'))
Check 'guided setup applies service and hosts/IPSet only behind a consent gate' ($autoSetupBody.Contains('Get-AutoSetupApplyAction') -and $autoSetupBody.Contains('Install-ZapretService -StrategyId $winner.Id') -and $autoSetupBody.Contains('Invoke-PostInstallConfiguration -Ask -DefaultNo'))
Check 'guided setup does not change DNS or system network settings' (-not $autoSetupBody.Contains('Enable-Doh') -and -not $autoSetupBody.Contains('Invoke-NetworkOptimize') -and -not $autoSetupBody.Contains('Set-NetworkRegistryDword'))
Check 'Auto-Setup parses regular, mobile, and cancel choices' ((Resolve-AutoSetupConnectionTypeChoice '1') -eq 'regular' -and (Resolve-AutoSetupConnectionTypeChoice '2') -eq 'mobile' -and (Resolve-AutoSetupConnectionTypeChoice '0') -eq 'cancel')
Check 'Auto-Setup rejects an invalid connection choice' ($null -eq (Resolve-AutoSetupConnectionTypeChoice '3'))
Check 'Auto-Setup carrier choices map to MTS, MegaFon, Tele2/T2, and Yota' ((@('1','2','3','4' | ForEach-Object { Resolve-AutoSetupCarrierChoice $_ }) -join ',') -eq 'mts,megafon,tele2,yota')
Check 'Auto-Setup carrier parser accepts IDs and rejects invalid choices' ((Resolve-AutoSetupCarrierChoice 'yota') -eq 'yota' -and $null -eq (Resolve-AutoSetupCarrierChoice '5'))
$setupApplyBody = (Get-Command Get-AutoSetupApplyAction).ScriptBlock.ToString()
Check 'auto-setup apply decision helper fails closed for unusable results' ($setupApplyBody.Contains('if (-not $CandidateUsable)') -and $setupApplyBody.Contains('if ($NoInteractive)'))
Check 'auto-setup rejects an unusable winner even with -Install' ((Get-AutoSetupApplyAction -CandidateUsable $false -Install $true) -eq 'skip')
Check 'auto-setup -Install is explicit consent for a usable winner' ((Get-AutoSetupApplyAction -CandidateUsable $true -Install $true) -eq 'install')
Check 'auto-setup non-interactive mode never applies implicitly' ((Get-AutoSetupApplyAction -CandidateUsable $true -NoInteractive $true) -eq 'skip')
Check 'explicit -Install still grants consent when combined with -NoInteractive' ((Get-AutoSetupApplyAction -CandidateUsable $true -Install $true -NoInteractive $true) -eq 'install')
Check 'auto-setup asks before applying and empty input is not consent' ((Get-AutoSetupApplyAction -CandidateUsable $true) -eq 'prompt' -and (Get-AutoSetupApplyAction -CandidateUsable $true -AnswerProvided $true -Answer '') -eq 'skip' -and (Get-AutoSetupApplyAction -CandidateUsable $true -AnswerProvided $true -Answer 'no') -eq 'skip')
Check 'auto-setup accepts explicit yes in English and Russian' ((Get-AutoSetupApplyAction -CandidateUsable $true -AnswerProvided $true -Answer 'yes') -eq 'install' -and (Get-AutoSetupApplyAction -CandidateUsable $true -AnswerProvided $true -Answer 'да') -eq 'install')
$setupPostInstallBody = (Get-Command Invoke-PostInstallConfiguration).ScriptBlock.ToString()
Check 'hosts/IPSet prompt can require explicit yes without changing legacy defaults' ($setupPostInstallBody.Contains('[switch]$Ask, [switch]$DefaultNo') -and $setupPostInstallBody.Contains('if ($DefaultNo)'))
$setupScheduleBody = (Get-Command Get-AutoSetupScheduleAction).ScriptBlock.ToString()
Check 'auto-setup schedule decision requires an installed matching strategy' ($setupScheduleBody.Contains('if (-not $ServiceInstalled -or -not $StrategyMatches)'))
Check 'auto-setup schedule is skipped without a matching installed service' ((Get-AutoSetupScheduleAction -ServiceInstalled $false -StrategyMatches $false) -eq 'skip')
Check 'auto-setup honors an already-enabled schedule' ((Get-AutoSetupScheduleAction -ServiceInstalled $true -StrategyMatches $true -ScheduleExists $true) -eq 'already-enabled')
Check 'auto-setup enables schedule only after explicit flag or affirmative answer' ((Get-AutoSetupScheduleAction -ServiceInstalled $true -StrategyMatches $true -EnableSchedule $true) -eq 'enable' -and (Get-AutoSetupScheduleAction -ServiceInstalled $true -StrategyMatches $true -AnswerProvided $true -Answer 'yes') -eq 'enable' -and (Get-AutoSetupScheduleAction -ServiceInstalled $true -StrategyMatches $true -AnswerProvided $true -Answer '') -eq 'skip')
Check 'auto-setup does not prompt for weekly task in non-interactive or -Install mode' ((Get-AutoSetupScheduleAction -ServiceInstalled $true -StrategyMatches $true -Install $true) -eq 'skip' -and (Get-AutoSetupScheduleAction -ServiceInstalled $true -StrategyMatches $true -NoInteractive $true) -eq 'skip')
$testUtilityUiText = [IO.File]::ReadAllText((Join-Path $repoRoot 'utils\test zapret.ps1'))
Check 'strategy test utility loads the saved interface language' ($testUtilityUiText.Contains('$script:UiLanguage = Get-UiLanguage') -and $testUtilityUiText.Contains('Get-UiText -Russian $Russian -English $English'))

$targets = @(Get-BenchmarkTargets)
Check 'benchmark probes at least 3 Discord endpoints'       (@($targets | Where-Object { $_.Service -eq 'Discord' }).Count -ge 3)
Check 'benchmark probes at least 1 YouTube endpoint'        (@($targets | Where-Object { $_.Service -eq 'YouTube' }).Count -ge 1)
Check 'benchmark probes WhatsApp endpoints and no Telegram targets' (@($targets | Where-Object { $_.Service -eq 'WhatsApp' }).Count -ge 1 -and @($targets | Where-Object { $_.Service -eq 'Telegram' -or $_.Name -match '^Telegram' }).Count -eq 0)
$explicitServiceTarget = [pscustomobject]@{ Name='WhatsAppWeb'; Service='WhatsApp' }
$legacyServiceTarget = [pscustomobject]@{ Name='DiscordMain'; Url='https://discord.com' }
$unknownServiceTarget = [pscustomobject]@{ Name='OtherEndpoint'; Url='https://example.com' }
Check 'benchmark service resolver honors an explicit Service field' ((Get-BenchmarkServiceName -Target $explicitServiceTarget) -eq 'WhatsApp')
Check 'benchmark service resolver infers service from legacy target names' ((Get-BenchmarkServiceName -Target $legacyServiceTarget) -eq 'Discord')
Check 'benchmark service resolver ignores unknown target names safely' ([string]::IsNullOrEmpty([string](Get-BenchmarkServiceName -Target $unknownServiceTarget)))
$legacyTargets = @(
    [pscustomobject]@{ Name='DiscordMain'; Url='https://discord.com' },
    [pscustomobject]@{ Name='YouTube'; Url='https://youtube.com' },
    [pscustomobject]@{ Name='WhatsAppWeb'; Url='https://whatsapp.com' }
)
$legacyTargetResults = @($legacyTargets | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Ok=$true } })
$legacyCoverage = Get-BenchmarkServiceSummary -TargetResults $legacyTargetResults -Targets $legacyTargets
Check 'carrier summary supports target objects without optional Service properties' ($legacyCoverage.AllPassed -and $legacyCoverage.TotalServices -eq 3)
$carrierCoverage = Get-BenchmarkServiceSummary -TargetResults @(
    [pscustomobject]@{ Name='DiscordMain'; Ok=$true },
    [pscustomobject]@{ Name='YouTube'; Ok=$false }, [pscustomobject]@{ Name='YouTubeShort'; Ok=$true },
    [pscustomobject]@{ Name='WhatsAppWeb'; Ok=$false }, [pscustomobject]@{ Name='WhatsAppMain'; Ok=$true }
)
Check 'carrier coverage requires one reachable endpoint per service' ($carrierCoverage.AllPassed -and $carrierCoverage.PassedServices -eq 3 -and $carrierCoverage.TotalServices -eq 3)
$carrierCoverageFailed = Get-BenchmarkServiceSummary -TargetResults @([pscustomobject]@{Name='DiscordMain';Ok=$true})
Check 'carrier coverage fails closed when a service has no successful endpoint' (-not $carrierCoverageFailed.AllPassed -and $carrierCoverageFailed.PassedServices -lt 3)
$testTargetFile = [IO.File]::ReadAllText((Join-Path $repoRoot 'utils/targets.txt'))
Check 'manual test target list includes WhatsApp and no Telegram endpoints' ($testTargetFile.Contains('WhatsAppWeb') -and -not $testTargetFile.Contains('TelegramWeb'))

Write-Host ''
Write-Host '== TCP transfer freeze / pause / onboarding helpers ==' -ForegroundColor Cyan

$transferTargets = @(Get-FreezeTargets)
Check 'freeze probe uses two HTTPS transfer targets' (($transferTargets.Count -ge 2) -and (@($transferTargets | Where-Object { $_.Url -match '^https://' }).Count -eq $transferTargets.Count))
Check 'freeze probe accepts the full 64 KB range with HTTP 206' (Test-TransferProbeResult -StatusCode 206 -BytesReceived 65536)
Check 'freeze probe accepts a complete HTTP 200 response' (Test-TransferProbeResult -StatusCode 200 -BytesReceived 65536)
Check 'freeze probe accepts only HTTP 200 or 206' (-not (Test-TransferProbeResult -StatusCode 201 -BytesReceived 65536))
Check 'freeze probe rejects downloads shorter than 64 KB' (-not (Test-TransferProbeResult -StatusCode 200 -BytesReceived 65535))
Check 'freeze probe rejects downloads over 64 KB' (-not (Test-TransferProbeResult -StatusCode 200 -BytesReceived 65537))
Check 'freeze probe rejects non-success HTTP statuses' (-not (Test-TransferProbeResult -StatusCode 416 -BytesReceived 65536))
$transferBody = (Get-Command Test-DataTransferUrl).ScriptBlock.ToString()
Check 'curl transfer probe requests exactly bytes 0-65535 and caps output' (($transferBody.Contains("'--range','0-65535'") -or $transferBody.Contains("'--range', '0-65535'")) -and $transferBody.Contains('--max-filesize'))
Check 'curl transfer probe measures download speed in KB/s' ($transferBody.Contains('%{speed_download}') -and $transferBody.Contains('SpeedKBs'))
$autoSelectBody = (Get-Command Invoke-AutoSelect).ScriptBlock.ToString()
$benchmarkBody = (Get-Command Invoke-BenchmarkStrategy).ScriptBlock.ToString()
$reachableProbeBody = (Get-Command Test-ReachableUrl).ScriptBlock.ToString()
$probeBatchBody = (Get-Command Invoke-UrlProbeBatch).ScriptBlock.ToString()
$targetProgress = [regex]::Match($benchmarkBody, 'Write-Host\s+\([^)]*\$targetName[^)]*\$probeStatus\)')
Check 'Auto-Select shows per-target progress and bounds each HTTP probe' ($targetProgress.Success -and $targetProgress.Index -gt $benchmarkBody.IndexOf('Invoke-UrlProbeBatch -Items') -and $reachableProbeBody.Contains("'-m'") -and $reachableProbeBody.Contains('$TimeoutSec') -and $probeBatchBody.Contains("'-m'") -and $probeBatchBody.Contains('$TimeoutSec'))
Check 'batch probe stays in sync with the single-probe contract' ($probeBatchBody.Contains("'%{http_code} %{time_total}'") -and $probeBatchBody.Contains('NO_PROXY') -and $probeBatchBody.Contains('Test-DohHttpCodeReachable -Code $code') -and $probeBatchBody.Contains('Get-CurlFailureReason') -and $reachableProbeBody.Contains("'%{http_code} %{time_total}'"))
$batchSmokeOk = $false
try {
    $batchSmoke = @(Invoke-UrlProbeBatch -Items @(@{ Url = 'http://invalid.invalid/a' }, @{ Url = 'http://invalid.invalid/b' }, @{ Url = 'http://invalid.invalid/c' }) -TimeoutSec 2 -MaxParallel 2)
    $batchSmokeOk = ($batchSmoke.Count -eq 3 -and [string]$batchSmoke[0].Url -eq 'http://invalid.invalid/a' -and [string]$batchSmoke[2].Url -eq 'http://invalid.invalid/c' -and -not $batchSmoke[0].Ok -and [string]$batchSmoke[0].Reason)
} catch { $batchSmokeOk = $false }
Check 'batch probe returns one record per item, in order' $batchSmokeOk
Check 'Auto-Select initializes generated user lists before launching strategies' ($autoSelectBody.IndexOf('Initialize-UserLists') -ge 0 -and $autoSelectBody.IndexOf('Initialize-UserLists') -lt $autoSelectBody.IndexOf('Invoke-BenchmarkStrategy'))
Check 'Deep automatically enables transfer-freeze probes' ($autoSelectBody.Contains('$CheckFreeze -or $Deep') -and $autoSelectBody.Contains('-CheckFreeze:$freezeRequired'))
Check 'benchmark failure paths return one full-shape result helper' (([regex]::Matches($benchmarkBody, 'New-BenchmarkFailureResult')).Count -eq 2 -and ([regex]::Matches($autoSelectBody, 'New-BenchmarkFailureResult')).Count -eq 1)
Check 'benchmark mirrors the stock tester: kills every winws, starts it with its own minimized console, never redirects output' ($benchmarkBody.Contains("Get-Process -Name 'winws'") -and $benchmarkBody.Contains('Start-Process -FilePath $winws') -and $benchmarkBody.Contains('-WindowStyle Minimized') -and -not $benchmarkBody.Contains('RedirectStandardOutput = $true') -and -not $benchmarkBody.Contains('ReadToEndAsync'))
Check 'benchmark reports wall-clock probe time, not the sum of probe durations' ($benchmarkBody.Contains('ElapsedMilliseconds') -and $benchmarkBody.Contains('ProbeMsSum'))
$tcpTsBody = (Get-Command Enable-ZapretTcpTimestamps).ScriptBlock.ToString()
$installServiceBody = (Get-Command Install-ZapretService).ScriptBlock.ToString()
Check 'stock bat protocol: TCP timestamps are enabled before strategies run' ($tcpTsBody.Contains('netsh.exe') -and $tcpTsBody.Contains('netsh interface tcp set global timestamps=enabled') -and $benchmarkBody.Contains('Enable-ZapretTcpTimestamps') -and $installServiceBody.Contains('Enable-ZapretTcpTimestamps'))
# --- Stock .bat translation parity (golden forms derived from the reference bats) ---
$goldenPath = Join-Path $repoRoot 'tests/golden-bat-args.json'
$stratsRawText = [IO.File]::ReadAllText((Join-Path $repoRoot 'strategies.json'))
$goldenObj = Get-Content $goldenPath -Raw | ConvertFrom-Json
$stratsObj = ConvertFrom-Json $stratsRawText
$stratList = if ($stratsObj -is [array]) { $stratsObj } else { @($stratsObj.strategies) }
$normArgs = { param($s) (([string]$s).Replace('^!', '!').Replace('"', '') -replace '\s+', ' ').Trim() }
$mismatched = New-Object 'System.Collections.Generic.List[string]'
foreach ($g in $goldenObj.PSObject.Properties) {
    $match = $stratList | Where-Object { $_.name -eq $g.Name } | Select-Object -First 1
    if (-not $match) { $mismatched.Add($g.Name + ' (missing)'); continue }
    if ((& $normArgs $match.args) -ne (& $normArgs $g.Value)) { $mismatched.Add($g.Name) }
}
Check 'strategies.json is an exact translation of the stock .bat configs (golden parity)' ($mismatched.Count -eq 0)
Check 'no strategy starts an empty --new chain before the first --filter-' (-not ($stratsRawText -match '--wf-(tcp|udp)=[^"]*? --new'))
Check 'stock UDP ranges keep the Discord voice ports 19294-19344' (($stratsRawText -match '--wf-udp=443,19294-19344,50000-50100') -and ($stratsRawText -match '--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun'))
Check 'fast-mode probe mirrors the stock tester HTTP column (--http1.1)' ($benchmarkBody.Contains('$probes = @(@{ Label = ''HTTP''; Extra = @(''--http1.1'') })'))
Check 'Test-StrategyArgs rejects an empty leading --new chain' ((Get-Command Test-StrategyArgs).ScriptBlock.ToString().Contains('starts an empty leading chain'))
# --- Watchdog (Автозащита) and health probe ---
$watchdogBody = (Get-Command Invoke-WatchdogCheck).ScriptBlock.ToString()
Check 'watchdog decision state machine covers healthy/skip/transient/cooldown/heal' ((Get-WatchdogDecision -PassedCount 9 -TotalCount 9) -eq 'healthy' -and (Get-WatchdogDecision -PassedCount 5 -TotalCount 9 -CanHeal $false) -eq 'skip' -and (Get-WatchdogDecision -PassedCount 5 -TotalCount 9 -PreviousFailures 0) -eq 'transient' -and (Get-WatchdogDecision -PassedCount 5 -TotalCount 9 -PreviousFailures 2 -LastHealUtc ([datetime]::UtcNow.AddMinutes(-5))) -eq 'cooldown' -and (Get-WatchdogDecision -PassedCount 5 -TotalCount 9 -PreviousFailures 2) -eq 'heal')
Check 'watchdog heals only through the gated auto-select and only over a running service' ($watchdogBody.Contains('Invoke-AutoSelect -Install') -and $watchdogBody.Contains('Get-WatchdogCanHeal'))
Check 'watchdog task payload runs the watchdog verb' ((Get-WatchdogTaskArguments -PowerShellPath 'C:\x\powershell.exe' -ScriptPath 'C:\x\zapret.ps1') -match 'watchdog -Scheduled')
Check 'health probe mirrors the stock tester HTTP column' ((Get-Command Invoke-BypassHealthProbe).ScriptBlock.ToString().Contains('--http1.1'))
Check 'CLI exposes health-check and watchdog verbs' ($zapretPs1.Contains("'health-check'") -and $zapretPs1.Contains("'watchdog'") -and $zapretPs1.Contains('Invoke-WatchdogCheck'))
Check 'tray source and binary ship with the project' ((Test-Path -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c')) -and (Test-Path -LiteralPath (Join-Path $repoRoot 'Zapret-Tray.exe')))

# --- Bypass profiles (Профиль обхода), speed test and the tray indicator ---
$profileBody = (Get-Command Set-BypassProfile).ScriptBlock.ToString()
$speedBody = (Get-Command Invoke-SpeedTest).ScriptBlock.ToString()
$rollbackText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.Rollback.ps1'))
Check 'bypass profiles use a managed block with reserved markers' ($rollbackText.Contains('# >>> zapret-managed profile') -and $rollbackText.Contains('# <<< zapret-managed profile <<<') -and $profileBody.Contains('ManagedProfileBeginPrefix') -and (Get-Command Get-BypassProfiles).ScriptBlock.ToString().Contains("'discord-only'") -and (Get-Command Get-BypassProfiles).ScriptBlock.ToString().Contains("'youtube-only'") -and (Get-Command Get-BypassProfiles).ScriptBlock.ToString().Contains("'no-whatsapp'"))
Check 'bypass profile round-trip preserves user lines and restores all' (& {
    $tempLists = Join-Path ([IO.Path]::GetTempPath()) ('zapret-profile-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempLists -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $tempLists 'list-exclude-user.txt'), "user-keep.example`r`n`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $r1 = Set-BypassProfile -Profile 'discord-only' -ListsDir $tempLists
        $text1 = [IO.File]::ReadAllText((Join-Path $tempLists 'list-exclude-user.txt'))
        $ok1 = ($r1.Domains.Count -gt 0) -and $text1.Contains('user-keep.example') -and $text1.Contains('# >>> zapret-managed profile: discord-only >>>') -and $text1.Contains('youtube.com')
        $okProfile = ((Get-BypassProfile -ListsDir $tempLists) -eq 'discord-only')
        Set-BypassProfile -Profile 'all' -ListsDir $tempLists | Out-Null
        $text2 = [IO.File]::ReadAllText((Join-Path $tempLists 'list-exclude-user.txt'))
        $ok2 = $text2.Contains('user-keep.example') -and (-not $text2.Contains('zapret-managed')) -and ((Get-BypassProfile -ListsDir $tempLists) -eq 'all')
        $ok1 -and $okProfile -and $ok2
    } finally {
        Remove-Item -LiteralPath $tempLists -Recurse -Force -ErrorAction SilentlyContinue
    }
})
Check 'speed test measures the 64 KB transfer with 500/100 KB/s verdicts' ($speedBody.Contains('Test-DataTransferUrl') -and $speedBody.Contains('-ge 500') -and $speedBody.Contains('-ge 100'))
Check 'benchmark targets narrow to the active bypass profile' ((Get-Command Get-BenchmarkTargets).ScriptBlock.ToString().Contains('Get-BypassProfile'))
Check 'active profile really narrows benchmark targets to its services' (& {
    $lists = Join-Path $repoRoot 'lists'
    $file = Join-Path $lists 'list-exclude-user.txt'
    $saved = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { $null }
    try {
        Set-BypassProfile -Profile 'discord-only' -ListsDir $lists | Out-Null
        $narrow = @(Get-BenchmarkTargets)
        Set-BypassProfile -Profile 'all' -ListsDir $lists | Out-Null
        $full = @(Get-BenchmarkTargets)
        ($narrow.Count -eq 4) -and ($full.Count -eq 9) -and (@($narrow | Where-Object { (Get-BenchmarkTargetValue -Target $_ -Name 'Service') -ne 'Discord' }).Count -eq 0)
    } finally {
        if ($null -ne $saved) { [IO.File]::WriteAllText($file, $saved, (New-Object System.Text.UTF8Encoding($false))) }
        elseif (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
})
Check 'health-check exits healthy/degraded/broken as 0/1/2' (($zapretPs1.Contains('exit 0') -and $zapretPs1.Contains('exit 2') -and $zapretPs1.Contains('probe.Passed * 2 -ge $probe.Total')))
Check 'CLI exposes profile and speed-test verbs' ($zapretPs1.Contains("'profile'") -and $zapretPs1.Contains("'speed-test'") -and $zapretPs1.Contains('Invoke-SpeedTest'))
Check 'tray indicator draws status discs and refreshes on demand' ((Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw).Contains('MakeStatusIcon') -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw).Contains('Обновить индикатор') -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw).Contains('health-check'))
Check 'tray icon mask is zeroed memory, never uninitialized' ((Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw).Contains('ZeroMemory(maskBits'))
Check 'tray status palette matches the app colors as 0xAARRGGBB' ((Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw) -match '0xFF51D6A5' -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw) -match '0xFFF5B95F' -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw) -match '0xFFF28B82' -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw) -match '0xFF75849C' -and -not ((Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw) -match 'MakeStatusIcon\(RGB'))
Check 'CLI rejects unknown profile ids with a friendly message' (& {
    $out = & (Join-Path $repoRoot 'zapret.ps1') -Action 'profile' -Rest @('definitely-bogus') *>&1 | Out-String
    ($LASTEXITCODE -eq 1) -and $out.Contains('Неизвестный профиль')
})
Check 'bypass profile refuses to eat user lines behind an unbalanced marker' (& {
    $tempLists = Join-Path ([IO.Path]::GetTempPath()) ('zapret-corrupt-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempLists -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $tempLists 'list-exclude-user.txt'), ('keep.example' + "`r`n" + '# >>> zapret-managed profile: discord-only >>>' + "`r`n" + 'user-after.example' + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $threw = $false
        try { Set-BypassProfile -Profile 'all' -ListsDir $tempLists | Out-Null } catch { $threw = $true }
        $after = [IO.File]::ReadAllText((Join-Path $tempLists 'list-exclude-user.txt'))
        $threw -and $after.Contains('user-after.example')
    } finally {
        Remove-Item -LiteralPath $tempLists -Recurse -Force -ErrorAction SilentlyContinue
    }
})
Check 'profile and speed-test run without elevation' ($zapretPs1 -match "'profile'\s*\{ \x24needsAdmin = \x24false" -and $zapretPs1 -match "'speed-test'\s*\{ \x24needsAdmin = \x24false")
Check 'speed test runs end to end and returns the documented shape' (& {
    $speed = Invoke-SpeedTest -TimeoutSec 3
    ($speed.Rows.Count -eq 2) -and ($speed.Verdict -in @('excellent', 'ok', 'slow', 'failed')) -and ($null -ne $speed.BestKBs)
})
Check 'panel XAML stays well-formed' (& {
    $raw = [IO.File]::ReadAllText((Join-Path $repoRoot 'Zapret-Control.ps1'))
    $m = [regex]::Match($raw, "@'\r?\n(.+?)\r?\n'@", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { return $false }
    try { $doc = [xml]$m.Groups[1].Value; $null -ne $doc } catch { $false }
})
$strictFailureShape = & {
    Set-StrictMode -Version 2.0
    $r = New-BenchmarkFailureResult -Id 'carrier-mts' -Name 'carrier-mts' -FreezeChecked $true -FreezeTotal 2
    $coverage = [bool]$r.AllServicesPassed
    $services = '{0}/{1}' -f $r.ServicesPassed, $r.ServiceCount
    [pscustomobject]@{ Coverage = $coverage; Services = $services; FreezeChecked = $r.FreezeChecked; StartFailed = $r.StartFailed }
}
Check 'carrier reporting survives a start-failure result under StrictMode' ((-not $strictFailureShape.Coverage) -and $strictFailureShape.Services -eq '0/3' -and $strictFailureShape.FreezeChecked -and $strictFailureShape.StartFailed)
Check 'curl failure reason mapping distinguishes DNS, timeout, reset and unknown' ((Get-CurlFailureReason -ExitCode 6) -eq 'dns' -and (Get-CurlFailureReason -ExitCode 28) -eq 'timeout' -and (Get-CurlFailureReason -ExitCode 56) -eq 'reset' -and (Get-CurlFailureReason -ExitCode 0) -eq 'no-response' -and (Get-CurlFailureReason -ExitCode 999) -eq 'error-999')
Check 'HTTP probe surfaces failure reasons and allows a full-budget TLS handshake' ($reachableProbeBody.Contains('Get-CurlFailureReason') -and $reachableProbeBody.Contains('NO_PROXY') -and -not $reachableProbeBody.Contains('Min(2'))
Check 'benchmark failure result counts the current three services' ((New-BenchmarkFailureResult -Id 'x' -Name 'x').ServiceCount -eq 3)
Check 'auto-select widens the probe budget for slow links and prints failure hints' ($autoSelectBody.Contains('[int]$TimeoutSec = 6') -and $autoSelectBody.Contains('$endpointReasons') -and $autoSelectBody.Contains('dns doh cloudflare') -and $benchmarkBody.Contains('Get-CurlFailureReasonText'))
Check 'probe can honour or bypass proxy environment variables on demand' ($reachableProbeBody.Contains('UseEnvironmentProxy') -and $reachableProbeBody.Contains('NO_PROXY'))
$proxyEnvBody = (Get-Command Get-ProxyEnvNames).ScriptBlock.ToString()
$proxyBefore = [Environment]::GetEnvironmentVariable('HTTPS_PROXY')
try {
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://127.0.0.1:9999')
    $proxyDetected = @(Get-ProxyEnvNames | Where-Object { $_ -like 'HTTPS_PROXY=*' }).Count -eq 1
} finally {
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxyBefore)
}
Check 'proxy environment variables are detected before the scan' ($proxyDetected -and $proxyEnvBody.Contains('HTTPS_PROXY') -and $autoSelectBody.Contains('Get-ProxyEnvNames') -and $autoSelectBody.Contains('UseEnvironmentProxy') -and $autoSelectBody.Contains('Контрольная проба discord.com'))
Check 'CLI auto-select accepts -TimeoutSec for slow links' ($zapretPs1.Contains('[int]$TimeoutSec = 0') -and $zapretPs1.Contains('@tsArgs'))
Check 'auto-select calibrates the probe budget from a live handshake sample' ($autoSelectBody.Contains('gstatic.com/generate_204') -and $autoSelectBody.Contains('calibratedBudget'))
Check 'benchmark report appends failure reasons to target lines' ($benchmarkReportBody.Contains('Get-CurlFailureReasonText') -and $benchmarkReportBody.Contains('reasonSuffix'))
Check 'auto-select offers DoH and retries once when DNS dominates' ($autoSelectBody.Contains('DohRetryUsed') -and $autoSelectBody.Contains('Enable-Doh') -and $autoSelectBody.Contains('Read-Host'))
$controlPanelText = [IO.File]::ReadAllText((Join-Path $repoRoot 'Zapret-Control.ps1'))
Check 'panel offers one-click DoH retry on the benchmark result page' ($controlPanelText.Contains('btnWizDoh') -and $controlPanelText.Contains('WizardDohRerun') -and $controlPanelText.Contains('Start-WizardBenchmark -Carrier $script:WizardCarrier'))
Check 'result page warns when proxy environment variables may fake other tools' ($controlPanelText.Contains('прокси-переменные окружения') -and $controlPanelText.Contains('ложный успех'))
Check 'automation reasons are localized into Russian on the result page' ($controlPanelText.Contains('повторная проверка не прошла или проверялась другая стратегия') -and $controlPanelText.Contains('проверка передачи 64 КБ была нестабильна'))
Check 'bogus DNS answers are flagged as poisoned' ((Test-DnsAnswerIsBogus -Addresses @('127.0.0.1')) -and (Test-DnsAnswerIsBogus -Addresses @('0.0.0.0')) -and (Test-DnsAnswerIsBogus -Addresses @('255.255.255.255')) -and -not (Test-DnsAnswerIsBogus -Addresses @('151.101.1.140')) -and -not (Test-DnsAnswerIsBogus -Addresses @()))
Check 'auto-select pre-flights DNS trust and conflicts before scanning' ($autoSelectBody.Contains('Get-BenchmarkDnsHealth') -and $autoSelectBody.Contains('Get-ZapretConflictReport') -and $autoSelectBody.Contains('DnsSuspect'))
Check 'panel result page offers a plain retry and reads the pre-flight DNS verdict' ($controlPanelText.Contains('btnWizRetry') -and $controlPanelText.Contains('DnsSuspect'))
$conflictReportBody = (Get-Command Get-ZapretConflictReport).ScriptBlock.ToString()
$conflictDisableBody = (Get-Command Disable-ZapretConflictPrograms).ScriptBlock.ToString()
$conflictRestoreBody = (Get-Command Restore-ZapretConflictPrograms).ScriptBlock.ToString()
Check 'conflict report exposes structured targets for disabling' ($conflictReportBody.Contains('Targets') -and $conflictReportBody.Contains("'service'") -and $conflictReportBody.Contains("'process'"))
Check 'conflicting services can be disabled with a restorable backup' ($conflictDisableBody.Contains('Stop-Service') -and $conflictDisableBody.Contains('Set-Service') -and $conflictDisableBody.Contains('.conflicts-backup.json'))
Check 'conflict disable backup can be restored' ($conflictRestoreBody.Contains('Start-Service') -and $conflictRestoreBody.Contains('.conflicts-backup.json'))
Check 'panel offers one-click conflict disabling and undo' ($controlPanelText.Contains('btnWizConflicts') -and $controlPanelText.Contains('Disable-ZapretConflictPrograms') -and $controlPanelText.Contains('Restore-ZapretConflictPrograms'))
Check 'auto-select offers to disable conflicts interactively before scanning' ($autoSelectBody.Contains('Disable-ZapretConflictPrograms') -and $autoSelectBody.Contains('Отключить конфликтующие'))
Check 'panel offers conflict disabling right when the scan starts' ($controlPanelText.Contains('WizardConflictsOffered') -and $controlPanelText.Contains('Отключить их сейчас и запустить проверку') -and $controlPanelText.Contains('disable'))
Check 'panel shows the conflict button even when the scan produced no result' ($controlPanelText.Contains('Обнаружены конфликтующие программы|Conflicting software detected') -and $controlPanelText.Contains('Конфликтующие программы найдены'))
$autoSetupBody = (Get-Command Invoke-AutoSetup).ScriptBlock.ToString()
Check 'console auto-setup offers to disable conflicts before the scan' ($autoSetupBody.Contains('Disable-ZapretConflictPrograms') -and $autoSetupBody.Contains('Отключить конфликтующие программы сейчас'))
$conflictNoop = Disable-ZapretConflictPrograms -Report ([pscustomobject]@{ Items = @(); Targets = @() })
Check 'conflict disable is a safe no-op off Windows' (@($conflictNoop.Services).Count -eq 0 -and [string]$conflictNoop.BackupPath -eq '' -and @($conflictNoop.Failed).Count -eq 0)
# 2.1.32 regression: report/disable used List[object] values inside
# [pscustomobject]@{...} literals which threw 'Argument types do not match'
# on the Windows-only path. Run the real function bodies with mocked probes.
$zapretModuleForMocks = Get-Module -Name Zapret
$conflictTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('zapret-conflict-test-' + [guid]::NewGuid().ToString('N'))
$conflictMockReport = $null
$conflictMockError = ''
$conflictDisableResult = $null
$conflictDisableError = ''
$conflictRestoreResult = $null
if ($zapretModuleForMocks) {
    New-Item -ItemType Directory -Path $conflictTestRoot -Force | Out-Null
    & $zapretModuleForMocks {
        function script:Get-WindowsServiceNames { @('WarpSvc', 'WarpStopped', 'OpenVpnSvc', 'GoodbyeDPI') }
        function script:Test-ServiceExists { param($n) ($n -eq 'GoodbyeDPI') }
        function script:Get-WinwsProcess { @() }
        function script:Get-CimInstance { param($ClassName, $Filter) @() }
        function script:Get-Process { param($Name, $ErrorAction) @() }
        function script:Get-Service { param($Name, $ErrorAction)
            if ($Name) { return [pscustomobject]@{ Name = $Name; StartType = 'Automatic'; Status = 'Running' } }
            return @(
                [pscustomobject]@{ Name = 'WarpSvc'; StartType = 'Automatic'; Status = 'Running' },
                [pscustomobject]@{ Name = 'WarpStopped'; StartType = 'Disabled'; Status = 'Stopped' },
                [pscustomobject]@{ Name = 'OpenVpnSvc'; StartType = 'Automatic'; Status = 'Running' },
                [pscustomobject]@{ Name = 'GoodbyeDPI'; StartType = 'Automatic'; Status = 'Running' }
            )
        }
        function script:Stop-Service { param($Name, [switch]$Force, $ErrorAction) }
        function script:Set-Service { param($Name, $StartupType, $ErrorAction) }
        function script:Start-Service { param($Name, $ErrorAction) }
        $script:OnWindows = $true
    }
    & $zapretModuleForMocks { param($root) $script:Root = $root } $conflictTestRoot
    try { $conflictMockReport = Get-ZapretConflictReport } catch { $conflictMockError = $_.Exception.Message }
    if (-not $conflictMockError) {
        try { $conflictDisableResult = Disable-ZapretConflictPrograms -Report $conflictMockReport } catch { $conflictDisableError = $_.Exception.Message }
    }
    if (-not $conflictDisableError -and $conflictDisableResult -and [string]$conflictDisableResult.BackupPath) {
        try { $conflictRestoreResult = Restore-ZapretConflictPrograms } catch { $conflictRestoreResult = $null }
    }
}
Check 'conflict report builds targets from mocked Windows probes without throwing' ($conflictMockError -eq '' -and $null -ne $conflictMockReport -and [bool]$conflictMockReport.PSObject.Properties['Targets'] -and @($conflictMockReport.Items).Count -ge 2 -and @($conflictMockReport.Targets).Count -ge 2)
Check 'conflict disable backs up mocked services and restore round-trips' ($conflictDisableError -eq '' -and $null -ne $conflictDisableResult -and @($conflictDisableResult.Services).Count -ge 2 -and [string]$conflictDisableResult.BackupPath -ne '' -and $null -ne $conflictRestoreResult -and [bool]$conflictRestoreResult.Found -and @($conflictRestoreResult.Restored).Count -ge 2)
Check 'stopped services are not reported as conflicts' (@($conflictMockReport.Items | Where-Object { $_ -match 'WarpStopped' }).Count -eq 0 -and @($conflictMockReport.Targets | Where-Object { $_.Name -eq 'WarpStopped' }).Count -eq 0)
Check 'panel explains SNI blocking when transfers pass but endpoints time out' ($controlPanelText.Contains('DPI блокирует их по SNI') -and $controlPanelText.Contains('перебирает только 4 узкие стратегии'))
Check 'console verdict explains SNI blocking when transfers pass but endpoints time out' ($autoSelectBody.Contains('похожи на блокировку по SNI'))
Remove-Item -LiteralPath $conflictTestRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($zapretModuleForMocks) { Import-Module -Name $zapretModuleForMocks.Path -Force; $zapretModuleForMocks = Get-Module -Name Zapret }
Check 'CLI exposes -CheckFreeze for auto-select' ($zapretPs1.Contains('[switch]$CheckFreeze') -and $zapretPs1.Contains('-CheckFreeze:$CheckFreeze'))

$freezeRank = Select-BestStrategy -Results @(
    [pscustomobject]@{ Id='freeze-failed'; Passed=6; TotalMs=100; StartFailed=$false; FreezeChecked=$true; FreezeOk=$false },
    [pscustomobject]@{ Id='transfer-ok'; Passed=5; TotalMs=900; StartFailed=$false; FreezeChecked=$true; FreezeOk=$true }
)
Check 'auto-select ranks a transfer-proven strategy above a freeze failure' ($freezeRank[0].Id -eq 'transfer-ok')

$servicePausePlan = Get-ZapretPauseResumePlan -ServiceInstalled $true -ServiceState 'Running' -ServiceStrategy 'alt' -ProcessRunning $true -ProcessStrategy 'general'
Check 'pause plan preserves running service strategy' ($servicePausePlan.Active -and $servicePausePlan.ServiceWasRunning -and $servicePausePlan.StrategyId -eq 'alt')
$processPausePlan = Get-ZapretPauseResumePlan -ServiceInstalled $true -ServiceState 'Stopped' -ServiceStrategy 'general' -ProcessRunning $true -ProcessStrategy 'alt'
Check 'pause plan restores manual process when service is stopped' ($processPausePlan.Active -and -not $processPausePlan.ServiceWasRunning -and $processPausePlan.ProcessWasRunning -and $processPausePlan.StrategyId -eq 'alt')
Check 'WinDivert ownership accepts this install and rejects foreign/sibling paths' ( (Test-ZapretDriverPath -PathName '"C:\zapret\bin\WinDivert64.sys" -k' -BinDir 'C:\zapret\bin') -and (Test-ZapretDriverPath -PathName '\\?\C:\zapret\bin\WinDivert14.sys' -BinDir 'C:\zapret\bin') -and (Test-ZapretDriverPath -PathName '\??\C:\zapret\bin\WinDivert64.sys' -BinDir 'C:\zapret\bin') -and (-not (Test-ZapretDriverPath -PathName '"C:\Windows\System32\drivers\WinDivert64.sys"' -BinDir 'C:\zapret\bin')) -and (-not (Test-ZapretDriverPath -PathName 'C:\zapret\bin-other\WinDivert64.sys' -BinDir 'C:\zapret\bin')) -and (-not (Test-ZapretDriverPath -PathName 'C:\zapret\bin\evil.sys' -BinDir 'C:\zapret\bin')) )
Check 'CLI and menu expose temporary pause' ($zapretPs1.Contains("'pause'") -and $zapretPs1 -match "'22'\s+\{\s*Invoke-MenuPause\s*\}" -and $zapretPs1.Contains('Pause the bypass for a game'))
Check 'pause restores the original service in finally without reinstalling it' ((Get-Command Suspend-ZapretBypass).ScriptBlock.ToString().Contains('finally') -and (Get-Command Suspend-ZapretBypass).ScriptBlock.ToString().Contains("Get-WindowsSystemToolPath -Name 'sc.exe') start zapret") -and -not (Get-Command Suspend-ZapretBypass).ScriptBlock.ToString().Contains('Install-ZapretService'))
Check 'pause requires admin and rejects non-Windows platforms' ((Get-Command Suspend-ZapretBypass).ScriptBlock.ToString().Contains('Assert-Admin') -and (Get-Command Suspend-ZapretBypass).ScriptBlock.ToString().Contains('$script:OnWindows'))
$ownedDriversBody = (Get-Command Stop-ZapretOwnedDrivers).ScriptBlock.ToString()
Check 'owned-driver cleanup waits for stop and deletion to complete' ($ownedDriversBody.Contains("-DesiredState 'Stopped'") -and $ownedDriversBody.Contains("-DesiredState 'Absent'"))
Check 'pause/uninstall guard ownership before stopping or deleting driver services' ($ownedDriversBody.Contains('$scPath stop $name') -and $ownedDriversBody.Contains('$scPath delete $name') -and $ownedDriversBody.IndexOf('Test-ZapretDriverPath') -lt $ownedDriversBody.IndexOf('stop $name') -and $ownedDriversBody.IndexOf('Test-ZapretDriverPath') -lt $ownedDriversBody.IndexOf('delete $name'))
Check 'pause fails and restores if an owned driver cannot be unloaded' ($ownedDriversBody.Contains('throw ("Не удалось выгрузить принадлежащий zapret драйвер'))
$oldServiceBin = Get-ZapretServiceBinDirectory -PathName '"C:\Previous Zapret\bin\winws.exe" --wf-tcp=443'
Check 'service path parser resolves the bin directory from an older install with spaces' ([string]::Equals($oldServiceBin, 'C:\Previous Zapret\bin', [StringComparison]::OrdinalIgnoreCase))
$unquotedServiceBin = Get-ZapretServiceBinDirectory -PathName 'C:\Old\Zapret\bin\winws.exe --wf-tcp=443'
$extendedServiceBin = Get-ZapretServiceBinDirectory -PathName '\\?\C:\Old\Zapret\bin\winws.exe --wf-tcp=443'
Check 'service path parser supports unquoted and extended Windows paths' ([string]::Equals($unquotedServiceBin, 'C:\Old\Zapret\bin', [StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($extendedServiceBin, 'C:\Old\Zapret\bin', [StringComparison]::OrdinalIgnoreCase))
Check 'service path parser rejects unrelated executables' ([string]::IsNullOrEmpty([string](Get-ZapretServiceBinDirectory -PathName '"C:\Other\app.exe" --test')))
Check 'uninstall can identify the old install driver without accepting another app path' ((Test-ZapretDriverPath -PathName '"C:\Previous Zapret\bin\WinDivert64.sys"' -BinDir $oldServiceBin) -and (-not (Test-ZapretDriverPath -PathName '"C:\Other\bin\WinDivert64.sys"' -BinDir $oldServiceBin)))
$removeServicesBody = (Get-Command Remove-ZapretServices).ScriptBlock.ToString()
$serviceStopWait = $removeServicesBody.IndexOf("Wait-ZapretServiceState -Name 'zapret' -DesiredState 'Stopped'")
$serviceDelete = $removeServicesBody.IndexOf('$scPath delete zapret')
Check 'uninstall waits for the service to stop before deleting its registration' ($serviceStopWait -ge 0 -and $serviceDelete -gt $serviceStopWait)
Check 'uninstall verifies no winws process remains and throws on failure' ($removeServicesBody.Contains('Wait-ZapretProcessesStopped') -and $removeServicesBody.Contains('winws.exe перед удалением службы'))
Check 'uninstall recognizes the registered install path when cleaning drivers' ($removeServicesBody.Contains('Get-ZapretServiceBinDirectory') -and $removeServicesBody.Contains('-AdditionalBinDirs $additionalBinDirs'))
Check 'uninstall reuses the owned-driver guard instead of deleting WinDivert by name' ($removeServicesBody.Contains('Stop-ZapretOwnedDrivers -Quiet:$Quiet') -and -not $removeServicesBody.Contains("@('WinDivert', 'WinDivert14')"))
Check 'explicit RemoveHostsBlock bypasses the interactive prompt' ($removeServicesBody.Contains('if (-not $RemoveHostsBlock -and -not $Quiet)') -and $removeServicesBody.IndexOf('RemoveHostsBlock -and -not $Quiet') -lt $removeServicesBody.IndexOf('Read-Host'))
Check 'uninstall RemoveHostsBlock decision is forwarded by the CLI' ($zapretPs1.Contains('Remove-ZapretServices -RemoveHostsBlock:$RemoveHostsBlock'))
Check 'uninstall checks the actual Windows hosts path before prompting' ($removeServicesBody.Contains('Test-HostsManaged -Path (Get-HostsFilePath)'))
Check 'uninstall does not leak the Remove-ZapretServices return value to the console' ($zapretPs1.Contains('[void](Remove-ZapretServices)') -and $zapretPs1.Contains('[void](Remove-ZapretServices -RemoveHostsBlock:$RemoveHostsBlock)'))
$autoSelectScheduleBody = (Get-Command Test-AutoSelectSchedule).ScriptBlock.ToString()
Check 'weekly-task probe keeps schtasks stderr out of the pipeline' ($autoSelectScheduleBody.Contains('2>$null') -and -not $autoSelectScheduleBody.Contains('2>&1'))
$scheduleBody = (Get-Command Set-AutoSelectSchedule).ScriptBlock.ToString()
Check 'weekly-task create/delete keep schtasks stderr out of the pipeline' ($scheduleBody.Contains('2>$null') -and -not $scheduleBody.Contains('2>&1'))
Check 'uninstall deletes the weekly task only when present and verifies the exit code' ($removeServicesBody.Contains('if (Test-AutoSelectSchedule)') -and $removeServicesBody.Contains('schtasks could not delete the task.') -and $removeServicesBody.IndexOf('2>$null') -gt $removeServicesBody.IndexOf('Test-AutoSelectSchedule'))
Check 'hosts removal decision: explicit flag removes without an answer' (Test-RemoveHostsBlockDecision -RemoveHostsBlock)
Check 'hosts removal decision: quiet uninstall preserves hosts by default' (-not (Test-RemoveHostsBlockDecision -Quiet))
Check 'hosts removal decision: empty interactive answer keeps default yes' (Test-RemoveHostsBlockDecision -Answer '')
Check 'hosts removal decision: explicit no preserves hosts' (-not (Test-RemoveHostsBlockDecision -Answer 'n'))
$pauseBody = (Get-Command Suspend-ZapretBypass).ScriptBlock.ToString()
Check 'pause does not edit hosts, config or scheduled task' ($pauseBody -notmatch 'Update-Config|Save-RollbackSnapshot|Set-AutoSelectSchedule|Remove-HostsManagedBlock')

Check 'onboarding is required only when config and service are absent' ((Test-OnboardingRequired -ConfigExists $false -ServiceInstalled $false) -and (-not (Test-OnboardingRequired -ConfigExists $true -ServiceInstalled $false)) -and (-not (Test-OnboardingRequired -ConfigExists $false -ServiceInstalled $true)))
$clockReference = [DateTimeOffset]'2026-01-01T00:00:00Z'
Check 'clock-skew helper reports signed seconds' ((Get-SystemTimeSkewSeconds -LocalTime $clockReference.AddMinutes(3) -ReferenceTime $clockReference) -eq 180 -and (Get-SystemTimeSkewSeconds -LocalTime $clockReference.AddMinutes(-3) -ReferenceTime $clockReference) -eq -180)
$diagnosticsBody = (Get-Command Invoke-Diagnostics).ScriptBlock.ToString()
Check 'diagnostics keeps empty/single conflict results countable under StrictMode v2' ($diagnosticsBody.Contains('$conflicts = @(@(') -and $diagnosticsBody.Contains('$conflicts.Count -gt 0'))
$strictConflictCounts = & {
    Set-StrictMode -Version 2.0
    $none = @(@('GoodbyeDPI','winws1') | Where-Object { $false })
    $one = @(@('GoodbyeDPI','winws1') | Where-Object { $_ -eq 'winws1' })
    [pscustomobject]@{ NoneCount = $none.Count; OneCount = $one.Count; OneValue = $one[0] }
}
Check 'empty and single diagnostics conflict results do not throw under StrictMode v2' ($strictConflictCounts.NoneCount -eq 0 -and $strictConflictCounts.OneCount -eq 1 -and $strictConflictCounts.OneValue -eq 'winws1')
Check 'diagnostics checks HTTPS Date with 3-second timeout and warns after 2 minutes' ($diagnosticsBody.Contains("-TimeoutSec 3") -and $diagnosticsBody.Contains('[Math]::Abs($clockSkew) -gt 120') -and $diagnosticsBody.Contains('TLS') -and $diagnosticsBody.Contains('DoH') -and (Get-Command Get-HttpsServerDate).ScriptBlock.ToString().Contains('https://gstatic.com'))
$ipv6Selection = @(Select-GlobalIPv6Addresses -Addresses @(
    [pscustomobject]@{ IPAddress = '2001:db8::1'; AddressState = 'Preferred' },
    [pscustomobject]@{ IPAddress = 'fe80::1'; AddressState = 'Preferred' },
    [pscustomobject]@{ IPAddress = '::1'; AddressState = 'Preferred' },
    [pscustomobject]@{ IPAddress = '2001:db8::2'; AddressState = 'Tentative' },
    [pscustomobject]@{ IPAddress = '192.0.2.1'; AddressState = 'Preferred' }
))
Check 'IPv6 diagnostic keeps only preferred global IPv6 addresses' ($ipv6Selection.Count -eq 1 -and $ipv6Selection[0] -eq '2001:db8::1')
Check 'HVCI diagnostic warns only when service is installed, winws is stopped and Enabled is 1' ((Test-HvciDriverWarningCondition -ServiceInstalled $true -WinwsRunning $false -Enabled 1) -and (-not (Test-HvciDriverWarningCondition -ServiceInstalled $false -WinwsRunning $false -Enabled 1)) -and (-not (Test-HvciDriverWarningCondition -ServiceInstalled $true -WinwsRunning $true -Enabled 1)) -and (-not (Test-HvciDriverWarningCondition -ServiceInstalled $true -WinwsRunning $false -Enabled 0)))
Check 'Windows-only IPv6 and HVCI checks are wired into diagnostics' ($diagnosticsBody.Contains('Get-NetIPAddress -AddressFamily IPv6') -and $diagnosticsBody.Contains('HypervisorEnforcedCodeIntegrity') -and $diagnosticsBody.Contains('if ($script:OnWindows)'))
Check 'banner colors service state and IPSet any' ($zapretPs1.Contains("'RUNNING' { 'Green' }") -and $zapretPs1.Contains("'STOPPED' { 'Red' }") -and $zapretPs1.Contains("'any' { 'Yellow' }"))
Check 'first-run menu offers Auto-Select with default Yes' ($zapretPs1.Contains('Test-OnboardingRequired') -and $zapretPs1.Contains('[Y/n]'))

Write-Host ''
Write-Host ''
Write-Host '== Hosts block removal ==' -ForegroundColor Cyan

$markerBegin = '# >>> zapret-discord-youtube (managed) >>>'
$markerEnd   = '# <<< zapret-discord-youtube (managed) <<<'
$tmpHosts = Join-Path ([IO.Path]::GetTempPath()) ('zapret-test-hosts-{0}.txt' -f ([Guid]::NewGuid().ToString('N')))
try {
    $fake = "127.0.0.1 localhost`r`n# keep this comment`r`n`r`n$markerBegin`r`n149.154.167.220 t.me`r`n$markerEnd`r`n"
    [IO.File]::WriteAllText($tmpHosts, $fake)
    Check 'hosts ownership marker is detected when an explicit file path is supplied' (Test-HostsManaged -Path $tmpHosts)

    $dry = Remove-HostsManagedBlock -HostsPath $tmpHosts -DryRun
    Check 'hosts removal dry-run returns true'            ($dry -eq $true)
    Check 'dry-run leaves the block untouched'            (([IO.File]::ReadAllText($tmpHosts)).Contains($markerBegin))

    $removed = Remove-HostsManagedBlock -HostsPath $tmpHosts
    $content = [IO.File]::ReadAllText($tmpHosts)
    Check 'hosts removal returns true'                    ($removed -eq $true)
    Check 'hosts removal drops all managed lines'         ((-not $content.Contains($markerBegin)) -and (-not $content.Contains($markerEnd)) -and (-not $content.Contains('149.154.167.220')))
    Check 'hosts removal keeps user entries and comments' (($content -match '127\.0\.0\.1 localhost') -and ($content -match 'keep this comment'))

    $removedAgain = Remove-HostsManagedBlock -HostsPath $tmpHosts
    Check 'hosts removal is idempotent'                   ($removedAgain -eq $false)

    $missing = Remove-HostsManagedBlock -HostsPath (Join-Path ([IO.Path]::GetTempPath()) ('zapret-nonexistent-{0}.txt' -f ([Guid]::NewGuid().ToString('N'))))
    Check 'hosts removal on missing file returns false'   ($missing -eq $false)
} finally {
    Remove-Item $tmpHosts -Force -ErrorAction SilentlyContinue
    Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'zapret-test-hosts-*.zapret-bak-*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host '== DNS / DoH & scheduling ==' -ForegroundColor Cyan

$cf = Get-DohProviderTable -Provider cloudflare
Check 'DoH cloudflare primary is 1.1.1.1'              (($null -ne $cf) -and ($cf.Primary -eq '1.1.1.1'))
Check 'DoH cloudflare template set'                    (($null -ne $cf) -and ($cf.Template -match 'cloudflare-dns\.com/dns-query'))
Check 'DoH google primary is 8.8.8.8'                  ((Get-DohProviderTable -Provider google).Primary -eq '8.8.8.8')
Check 'DoH quad9 primary is 9.9.9.9'                   ((Get-DohProviderTable -Provider quad9).Primary -eq '9.9.9.9')
Check 'DoH AdGuard primary and endpoint are registered' (((Get-DohProviderTable -Provider adguard).Primary -eq '94.140.14.14') -and ((Get-DohProviderTable -Provider adguard).Host -eq 'dns.adguard-dns.com'))
Check 'DoH Yandex primary and endpoint are registered'  (((Get-DohProviderTable -Provider yandex).Primary -eq '77.88.8.8') -and ((Get-DohProviderTable -Provider yandex).Host -eq 'common.dot.dns.yandex.net') -and ((Get-DohProviderTable -Provider yandex).Template -match 'common\.dot\.dns\.yandex\.net/dns-query'))
Check 'DoH unknown provider returns null'              ($null -eq (Get-DohProviderTable -Provider bogus))
Check 'DoH provider table has 5 entries'               (@(Get-DohProviderTable).Count -eq 5)
$providerHosts = @(Get-DohProviderTable | Select-Object -ExpandProperty Host | Sort-Object)
Check 'DoH table includes all five exact endpoint hostnames' (($providerHosts -join ',') -eq 'cloudflare-dns.com,common.dot.dns.yandex.net,dns.adguard-dns.com,dns.google,dns.quad9.net')
Check 'Enable-Doh exported'                            ([bool](Get-Command Enable-Doh -ErrorAction SilentlyContinue))
Check 'Reset-DnsToDhcp exported'                       ([bool](Get-Command Reset-DnsToDhcp -ErrorAction SilentlyContinue))
Check 'Save and restore DNS rollback functions exported' (([bool](Get-Command Save-DnsRollbackSnapshot -ErrorAction SilentlyContinue)) -and ([bool](Get-Command Restore-DnsRollbackSnapshot -ErrorAction SilentlyContinue)))
Check 'Set-AutoSelectSchedule exported'                ([bool](Get-Command Set-AutoSelectSchedule -ErrorAction SilentlyContinue))
Check 'Invoke-PostInstallConfiguration exported'       ([bool](Get-Command Invoke-PostInstallConfiguration -ErrorAction SilentlyContinue))
Check 'DNS benchmark selector, latency helper and ping stats exported' (([bool](Get-Command Select-FastestDns -ErrorAction SilentlyContinue)) -and ([bool](Get-Command Get-DnsBenchmarkLatency -ErrorAction SilentlyContinue)) -and ([bool](Get-Command Measure-PingStats -ErrorAction SilentlyContinue)))

$zapretPs1 = [IO.File]::ReadAllText((Join-Path $repoRoot 'zapret.ps1'))
Check 'CLI wires the dns action and benchmark'         (($zapretPs1 -match "'dns'") -and ($zapretPs1 -match "'benchmark'"))
Check 'CLI wires schedule-autoselect'                  ($zapretPs1 -match 'schedule-autoselect')
Check 'menu exposes DNS / DoH in both locales'          ($zapretPs1.Contains('DNS AND ENCRYPTED DNS (DoH)') -and $zapretPs1 -match "'15'\s+\{\s*Invoke-MenuDns\s*\}")
Check 'menu exposes weekly re-check in both locales'      ($zapretPs1.Contains('Schedule a weekly re-check') -and $zapretPs1 -match "'16'\s+\{\s*Invoke-MenuSchedule\s*\}")

Write-Host ''
Write-Host '== Network / ping pure helpers ==' -ForegroundColor Cyan

$pingStats = Measure-PingStats -Samples ([double[]]@(10, 20, 30, 40))
Check 'ping stats: min/avg/max and mean absolute jitter' (($pingStats.Min -eq 10) -and ($pingStats.Avg -eq 25) -and ($pingStats.Max -eq 40) -and ($pingStats.Jitter -eq 10) -and ($pingStats.LossPercent -eq 0))
$pingLossStats = Measure-PingStats -Samples ([double[]]@([double]::NaN, [double]::NaN, [double]::NaN))
Check 'ping stats: 100% loss has no RTT values'          (($pingLossStats.LossPercent -eq 100) -and ($pingLossStats.Sent -eq 3) -and ($pingLossStats.Received -eq 0) -and ($null -eq $pingLossStats.Avg))
$pingPartialStats = Measure-PingStats -Samples ([double[]]@(10, [double]::NaN, 30))
Check 'ping stats: partial loss counted against sent samples' (($pingPartialStats.LossPercent -eq 33.33) -and ($pingPartialStats.Received -eq 2))
$pingSingleStats = Measure-PingStats -Samples ([double[]]@(15, [double]::NaN, [double]::NaN))
Check 'ping stats: one reply leaves jitter unknown' (($pingSingleStats.Received -eq 1) -and ($null -eq $pingSingleStats.Jitter))
$dnsWinner = Select-FastestDns -Results @(
    [pscustomobject]@{ Provider = 'slow'; Reachable = $true; AverageRttMs = 30 },
    [pscustomobject]@{ Provider = 'unavailable'; Reachable = $false; AverageRttMs = 1 },
    [pscustomobject]@{ Provider = 'fast'; Reachable = $true; AverageRttMs = 8 },
    [pscustomobject]@{ Provider = 'unknown'; Reachable = 'unknown'; AverageRttMs = 0 }
)
Check 'DNS selector chooses the fastest reachable provider only' ($dnsWinner.Provider -eq 'fast')
Check 'DNS selector ignores all unavailable providers' ($null -eq (Select-FastestDns -Results @([pscustomobject]@{ Provider = 'down'; Reachable = $false; AverageRttMs = 1 })))
Check 'DNS selector ignores reachable results without a measured RTT' ($null -eq (Select-FastestDns -Results @([pscustomobject]@{ Provider = 'no-rtt'; Reachable = $true; AverageRttMs = $null })))
$icmpLatency = Get-DnsBenchmarkLatency -IcmpSamples ([double[]]@(10, 20)) -HttpsSamples ([double[]]@(1, 3))
Check 'DNS latency prefers ICMP when an RTT exists' (($icmpLatency.RttSource -eq 'ICMP') -and ($icmpLatency.AverageRttMs -eq 15))
$httpsFallbackLatency = Get-DnsBenchmarkLatency -IcmpSamples ([double[]]@()) -HttpsSamples ([double[]]@(12, 14))
Check 'DNS latency falls back to HTTPS when ICMP is filtered' (($httpsFallbackLatency.RttSource -eq 'HTTPS') -and ($httpsFallbackLatency.AverageRttMs -eq 13))
$noLatency = Get-DnsBenchmarkLatency -IcmpSamples ([double[]]@([double]::NaN, -1)) -HttpsSamples ([double[]]@([double]::PositiveInfinity))
Check 'DNS latency is unavailable when all samples are invalid' (($noLatency.RttSource -eq 'n/a') -and ($null -eq $noLatency.AverageRttMs))
Check 'IPv4 validation accepts canonical dotted decimal' (Test-IPv4AddressText -Address '192.0.2.1')
Check 'IPv4 validation rejects shorthand and integer forms' ((-not (Test-IPv4AddressText -Address '127.1')) -and (-not (Test-IPv4AddressText -Address '1')) -and (-not (Test-IPv4AddressText -Address '0x7f000001')) -and (-not (Test-IPv4AddressText -Address ' 192.0.2.1 ')))
Check 'IPv4 validation rejects leading zeroes and out-of-range octets' ((-not (Test-IPv4AddressText -Address '010.0.0.1')) -and (-not (Test-IPv4AddressText -Address '1.2.3.256')))
Check 'netsh interface name keeps spaces in one argv token (PS 5.1-safe, no embedded quotes)' ((Get-NetshInterfaceNameArgument -Name 'Ethernet 2') -eq 'name=Ethernet 2')
$unsafeNameRejected = $false; try { [void](Get-NetshInterfaceNameArgument -Name 'bad"name') } catch { $unsafeNameRejected = $true }
$controlNameRejected = $false; try { [void](Get-NetshInterfaceNameArgument -Name ("bad`nname")) } catch { $controlNameRejected = $true }
Check 'netsh interface name rejects quote and control characters' ($unsafeNameRejected -and $controlNameRejected)
Check 'RSS state parser handles English and Russian output' ((ConvertTo-RssState -Value 'Enabled') -eq 'enabled' -and (ConvertFrom-RssNetshText -Text 'Receive-Side Scaling State : disabled') -eq 'disabled' -and (ConvertFrom-RssNetshText -Text 'Состояние масштабирования на стороне приема: включено') -eq 'enabled')
$interfaceRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{01234567-89ab-cdef-0123-456789abcdef}'
Check 'network rollback allow-list permits only intended registry values' ((Test-NetworkRegistrySnapshotEntry -Path $interfaceRegPath -Name TcpAckFrequency) -and (Test-NetworkRegistrySnapshotEntry -Path $interfaceRegPath -Name TCPNoDelay) -and (-not (Test-NetworkRegistrySnapshotEntry -Path $interfaceRegPath -Name Evil)) -and (Test-NetworkRegistrySnapshotEntry -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name NetworkThrottlingIndex))
$networkFunctionText = (Get-Command Invoke-NetworkOptimize).ScriptBlock.ToString()
$mtuFunctionText = (Get-Command Get-OptimalMtu).ScriptBlock.ToString()
$lineTestText = (Get-Command Invoke-LineQualityTest).ScriptBlock.ToString()
$dnsBenchmarkText = (Get-Command Invoke-DnsBenchmark).ScriptBlock.ToString()
$dnsRollbackText = (Get-Command Restore-DnsRollbackSnapshot).ScriptBlock.ToString()
$networkRollbackText = (Get-Command Restore-NetworkSnapshotFile).ScriptBlock.ToString()
$defaultNetworkText = (Get-Command Get-DefaultIPv4Network).ScriptBlock.ToString()
Check 'DNS benchmark measures 3 provider-IP pings and 3 DoH probes' ($dnsBenchmarkText.Contains('$provider.Primary') -and $dnsBenchmarkText.Contains('$sampleIndex -lt 3') -and $dnsBenchmarkText.Contains('Test-DohProviderAvailable -Provider $provider.Key -TimeoutSeconds 3'))
$dnsApplyText = (Get-Command Enable-Doh).ScriptBlock.ToString()
$dnsResetText = (Get-Command Reset-DnsToDhcp).ScriptBlock.ToString()
Check 'DoH apply checks netsh status and verifies both resolver addresses' ($dnsApplyText.Contains('Invoke-DnsNetshCommand') -and $dnsApplyText.Contains('$now -contains $p.Primary') -and $dnsApplyText.Contains('$now -contains $p.Secondary'))
Check 'DNS reset reports rejected netsh operations' ($dnsResetText.Contains('Invoke-DnsNetshCommand') -and $dnsResetText.Contains('DNS reset failed'))
$dnsPreviewText = (Get-Command Enable-Doh).ScriptBlock.ToString()
$dnsRollbackFunctionText = (Get-Command Restore-DnsRollbackSnapshot).ScriptBlock.ToString()
$resetPreviewIndex = $dnsResetText.IndexOf('if ($Preview)')
$netPreviewIndex = $networkFunctionText.IndexOf('if ($Preview)')
$mtuApplyText = (Get-Command Invoke-MtuCheck).ScriptBlock.ToString()
$dnsBenchPreviewText = (Get-Command Invoke-DnsBenchmark).ScriptBlock.ToString()
Check 'DoH preview lists resolver/template and returns administrator/rollback metadata before mutation' ($dnsPreviewText.Contains('AdapterChanges') -and $dnsPreviewText.Contains('DoHTemplateServers') -and $dnsPreviewText.Contains('RequiresAdministrator = $true') -and $dnsPreviewText.IndexOf('if ($Preview)') -lt $dnsPreviewText.IndexOf('Assert-Admin'))
Check 'DNS reset preview lists each adapter target and runs before administrator/mutation commands' ($dnsResetText.Contains('AdapterChanges') -and $dnsResetText.Contains("TargetSource = 'DHCP/automatic'") -and $resetPreviewIndex -lt $dnsResetText.IndexOf('Assert-Admin'))
Check 'DNS rollback preview resolves current-to-saved state without applying netsh commands' ($dnsRollbackFunctionText.Contains('AdapterChanges') -and $dnsRollbackFunctionText.Contains('RequiresAdministrator = $true') -and $dnsRollbackFunctionText.IndexOf('if ($Preview)') -lt $dnsRollbackFunctionText.IndexOf('Assert-Admin'))
Check 'network optimize preview reports exact registry/RSS targets before saving or writing' ($networkFunctionText.Contains('TargetRss') -and $networkFunctionText.Contains('RequiresAdministrator = $true') -and $netPreviewIndex -lt $networkFunctionText.IndexOf('New-NetworkRollbackSnapshot'))
Check 'MTU preview reports the measured interface/target and rollback without applying' ($mtuApplyText.Contains('InterfaceName = $network.InterfaceName') -and $mtuApplyText.Contains('RequiresAdministrator = [bool]$Preview') -and $mtuApplyText.IndexOf('if ($NoPrompt -or $Preview)') -lt $mtuApplyText.IndexOf('Set-NetworkInterfaceMtu'))
Check 'DNS benchmark preview delegates the exact resolver plan and does not apply it' ($dnsBenchPreviewText.Contains('Enable-Doh -Provider $fastest.Provider -Preview') -and $dnsBenchPreviewText.Contains('DnsPlan = $dnsPlan'))
Check 'CLI forwards preview flags for DNS, hosts, IPSet and network commands' ($zapretPs1.Contains('Update-IpsetList -Preview:$Preview') -and $zapretPs1.Contains('Update-HostsFile -DryRun:($DryRun -or $Preview)') -and $zapretPs1.Contains('Enable-Doh -Provider $provider -Preview:$Preview') -and $zapretPs1.Contains('Invoke-NetworkOptimize -Revert:$Revert -Preview:$Preview'))
Check 'DNS rollback consumes restored snapshots for stack-style undo' ($dnsRollbackText.Contains('$snapshotPath + ''.restored''') -and $dnsRollbackText.Contains('Move-Item -LiteralPath $snapshotPath'))
Check 'DNS rollback validates every snapshot entry before network changes' ($dnsRollbackText.IndexOf('$adapterEntries') -lt $dnsRollbackText.IndexOf('Get-NetAdapter -Physical') -and $dnsRollbackText.Contains('invalid adapter count') -and $dnsRollbackText.Contains('duplicate adapter'))
Check 'network rollback rejects empty/oversized snapshots and non-boolean flags' ($networkRollbackText.Contains('no restorable values') -and $networkRollbackText.Contains('too many registry entries') -and $networkRollbackText.Contains('-isnot [bool]'))
Check 'default-route discovery ignores down interfaces' ($defaultNetworkText.Contains('$_.Status') -and $defaultNetworkText.Contains("eq 'Up'"))
$mtuFromNlMtu = Get-IpInterfaceMtuBytes -Interface ([pscustomobject]@{ NlMtu = 1500 })
$mtuFromNlMtuBytes = Get-IpInterfaceMtuBytes -Interface ([pscustomobject]@{ NlMtuBytes = 1492 })
$mtuFromFormattedProperty = Get-IpInterfaceMtuBytes -Interface ([pscustomobject]@{ 'NlMtu(Bytes)' = 1472 })
$missingMtuRejected = $false
try { [void](Get-IpInterfaceMtuBytes -Interface ([pscustomobject]@{ InterfaceIndex = 7 })) }
catch { $missingMtuRejected = ($_.Exception.Message -eq 'Could not determine the MTU of the active IPv4 interface.') }
Check 'MTU reader supports the NlMtu property returned by NetTCPIP' ($mtuFromNlMtu -eq 1500)
Check 'MTU reader also supports the NlMtuBytes property variant' ($mtuFromNlMtuBytes -eq 1492)
Check 'MTU reader accepts the formatted NlMtu(Bytes) property name' ($mtuFromFormattedProperty -eq 1472)
Check 'missing MTU metadata fails with a clear error instead of a property exception' ($missingMtuRejected)
Check 'default-route discovery uses the safe MTU reader rather than direct property access' ($defaultNetworkText.Contains('Get-IpInterfaceMtuBytes -Interface $ipInterface') -and -not $defaultNetworkText.Contains('$ipInterface.NlMtuBytes'))
Check 'network optimize snapshots registry/RSS before writing' ($networkFunctionText.IndexOf('New-NetworkRollbackSnapshot') -lt $networkFunctionText.IndexOf('Set-NetworkRegistryDword') -and $networkFunctionText.Contains("'rss=enabled'"))
Check 'MTU probe binary-searches 1200..1472, retries a lost probe and uses DF ping' ($mtuFunctionText.Contains('-n 1 -w 1000 -f -l') -and $mtuFunctionText.Contains("'1.1.1.1'") -and $mtuFunctionText.Contains('$best + 28') -and $mtuFunctionText.Contains('$attemptIndex -lt 2'))
Check 'line test uses gateway, Cloudflare, Discord and ten samples' ($lineTestText.Contains('$network.Gateway') -and $lineTestText.Contains("'discord.com'") -and $lineTestText.Contains('$sampleIndex -lt 10'))
Check 'CLI and main menu expose Network & Ping Tools' ($zapretPs1.Contains("'net-optimize'") -and $zapretPs1.Contains("'mtu-check'") -and $zapretPs1.Contains("'ping-test'") -and $zapretPs1.Contains('Network and connection quality'))

Write-Host ''
Write-Host '== Elevated restart argument preservation ==' -ForegroundColor Cyan

$restartScriptPath = Join-Path $repoRoot 'zapret.ps1'
$restartTokens = $null
$restartParseErrors = $null
$restartAst = [System.Management.Automation.Language.Parser]::ParseFile($restartScriptPath, [ref]$restartTokens, [ref]$restartParseErrors)
$restartHelpersLoaded = ($restartParseErrors.Count -eq 0)
foreach ($helperName in @('ConvertTo-WindowsCommandLineArgument', 'Get-ZapretRestartArgumentLine')) {
    $capturedHelperName = $helperName
    $helperDefinition = $restartAst.Find({
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $capturedHelperName)
    }, $true)
    if ($null -eq $helperDefinition) {
        $restartHelpersLoaded = $false
    } else {
        . ([scriptblock]::Create($helperDefinition.Extent.Text))
    }
}
Check 'elevation argument helpers parse and load' $restartHelpersLoaded
if ($restartHelpersLoaded) {
    $restartBoundParameters = @{
        Action    = 'auto-select'
        Rest      = @()
        Fast      = [System.Management.Automation.SwitchParameter]$true
        Deep      = [System.Management.Automation.SwitchParameter]$true
        Install   = [System.Management.Automation.SwitchParameter]$true
        CheckFreeze = [System.Management.Automation.SwitchParameter]$true
        DryRun    = [System.Management.Automation.SwitchParameter]$false
        TcpPorts  = '80,443'
        HostsPath = 'C:\Program Files\zapret\hosts'
    }
    $restartLine = Get-ZapretRestartArgumentLine -ScriptPath 'C:\Program Files\zapret\zapret.ps1' -Action 'auto-select' -RemainingArguments @() -BoundParameters $restartBoundParameters
    Check 'UAC restart keeps auto-select action and switches' (($restartLine.Contains('"auto-select"')) -and ($restartLine.Contains('"-Fast"')) -and ($restartLine.Contains('"-Deep"')) -and ($restartLine.Contains('"-Install"')) -and ($restartLine.Contains('"-CheckFreeze"')))
    Check 'UAC restart keeps named values and quotes paths with spaces' (($restartLine.Contains('"-TcpPorts"')) -and ($restartLine.Contains('"80,443"')) -and ($restartLine.Contains('"C:\Program Files\zapret\hosts"')) -and ($restartLine.Contains('"C:\Program Files\zapret\zapret.ps1"')))
    Check 'UAC restart omits explicitly false switches' (-not $restartLine.Contains('"-DryRun"'))
    $autoSetupRestartLine = Get-ZapretRestartArgumentLine -ScriptPath 'C:\zapret\zapret.ps1' -Action 'auto-setup' -RemainingArguments @() -BoundParameters @{
        Action='auto-setup'; Rest=@(); Carrier='yota'
        Fast=[System.Management.Automation.SwitchParameter]$true
        NoInteractive=[System.Management.Automation.SwitchParameter]$true
        EnableSchedule=[System.Management.Automation.SwitchParameter]$true
    }
    Check 'UAC restart preserves auto-setup carrier, quiet and schedule options' (($autoSetupRestartLine.Contains('"auto-setup"')) -and ($autoSetupRestartLine.Contains('"-Carrier"')) -and ($autoSetupRestartLine.Contains('"yota"')) -and ($autoSetupRestartLine.Contains('"-NoInteractive"')) -and ($autoSetupRestartLine.Contains('"-EnableSchedule"')))
    Check 'Windows CLI quoting escapes embedded quotes' ((ConvertTo-WindowsCommandLineArgument -Value 'a"b') -eq '"a\"b"')
    Check 'Windows CLI quoting doubles trailing backslashes in paths' ((ConvertTo-WindowsCommandLineArgument -Value 'C:\Program Files\zapret\') -eq '"C:\Program Files\zapret\\"')
    $positionalRestartLine = Get-ZapretRestartArgumentLine -ScriptPath 'C:\zapret\zapret.ps1' -Action 'fakes' -RemainingArguments @('discord', 'fake with spaces') -BoundParameters @{}
    Check 'UAC restart keeps fakes positional arguments' (($positionalRestartLine.Contains('"discord"')) -and ($positionalRestartLine.Contains('"fake with spaces"')))
    $pauseRestartLine = Get-ZapretRestartArgumentLine -ScriptPath 'C:\zapret\zapret.ps1' -Action 'pause' -RemainingArguments @('15') -BoundParameters @{ Action='pause'; Rest=@('15') }
    Check 'UAC restart preserves pause minutes' (($pauseRestartLine.Contains('"pause"')) -and ($pauseRestartLine.Contains('"15"')))
    $shareForRestart = 'zapret1:QUJDRA=='
    $importRestartLine = Get-ZapretRestartArgumentLine -ScriptPath 'C:\zapret\zapret.ps1' -Action 'import-strategy' -RemainingArguments @($shareForRestart) -BoundParameters @{ Action='import-strategy'; Rest=@($shareForRestart); NewId='shared-general' }
    Check 'UAC restart preserves import payload and -NewId' (($importRestartLine.Contains('"import-strategy"')) -and ($importRestartLine.Contains('"zapret1:QUJDRA=="')) -and ($importRestartLine.Contains('"-NewId"')) -and ($importRestartLine.Contains('"shared-general"')))
    Check 'UAC and path-move restarts share the serializer' (([regex]::Matches($zapretPs1, 'Get-ZapretRestartArgumentLine -ScriptPath')).Count -eq 2)
}

Write-Host ''
Write-Host '== Launch path validation ==' -ForegroundColor Cyan

Check 'clean C:\zapret passes'                 ((Test-ZapretInstallPath -Path 'C:\zapret').Count -eq 0)
Check 'Cyrillic path is flagged'                ((Test-ZapretInstallPath -Path 'C:\Пользователи\zapret') -contains 'путь содержит не-ASCII символы (например, кириллицу)')
Check 'spaces are flagged'                      ((Test-ZapretInstallPath -Path 'C:\My Folder\zapret') -contains 'путь содержит пробелы')
Check 'OneDrive path is flagged'                ((Test-ZapretInstallPath -Path 'C:\Users\Ivan\OneDrive\zapret') -contains 'папка находится внутри OneDrive (синхронизация ломает файлы обхода)')
Check 'special characters are flagged'           (@(Test-ZapretInstallPath -Path 'C:\zapret(new)' | Where-Object { $_ -match 'спецсимволы' }).Count -ge 1)
Check 'linux path passes'                       ((Test-ZapretInstallPath -Path '/home/user/zapret').Count -eq 0)
Check 'empty path is flagged'                   ((Test-ZapretInstallPath -Path '').Count -ge 1)

Write-Host ''
Write-Host '== Fast auto-select ordering ==' -ForegroundColor Cyan

$allStrategies = @(Get-Strategies)
$orderedFast = @(Get-BenchmarkOrder -Available $allStrategies -Fast)
Check 'fast: general is benchmarked first'            ($orderedFast[0].id -eq 'general')
Check 'fast: alt is benchmarked second'               ($orderedFast[1].id -eq 'alt')
Check 'fast: fake-tls-auto is benchmarked third'      ($orderedFast[2].id -eq 'fake-tls-auto')
Check 'fast: no strategies are dropped'               ($orderedFast.Count -eq $allStrategies.Count)
$orderedCurrent = @(Get-BenchmarkOrder -Available $allStrategies -CurrentStrategy 'alt13' -Fast)
Check 'fast: installed strategy is checked before the trio' ($orderedCurrent[0].id -eq 'alt13')
Check 'fast: no duplicates when current is general'   (@(Get-BenchmarkOrder -Available $allStrategies -CurrentStrategy 'general' -Fast | Where-Object { $_.id -eq 'general' }).Count -eq 1)
$orderedNoFast = @(Get-BenchmarkOrder -Available $allStrategies)
Check 'no fast: original order is preserved'          ($orderedNoFast[0].id -eq $allStrategies[0].id)
$orderedUnknownCurrent = @(Get-BenchmarkOrder -Available $allStrategies -CurrentStrategy 'no-such-strategy' -Fast)
Check 'fast: unknown installed strategy is ignored'   ($orderedUnknownCurrent[0].id -eq 'general')
$carrierProfiles = @(Get-MobileCarrierProfiles)
Check 'MTS, MegaFon, Tele2/T2, and Yota profiles exist' ((@($carrierProfiles | Select-Object -ExpandProperty Id) -join ',') -eq 'mts,megafon,tele2,yota')
$carrierOrderChecks = 0
foreach ($profile in $carrierProfiles) {
    $profileOrder = @(Get-BenchmarkOrder -Available $allStrategies -Carrier $profile.Id -Fast)
    if (($profileOrder | Select-Object -First 4 | ForEach-Object { $_.id }) -join ',' -eq ($profile.StrategyOrder -join ',')) { $carrierOrderChecks++ }
}
Check 'each operator starts with its own narrow strategy and has automatic fallbacks' ($carrierOrderChecks -eq 4)
$rememberedOrder = @(Get-BenchmarkOrder -Available $allStrategies -Carrier 'mts' -PreferredStrategy 'carrier-yota' -Fast)
Check 'previously proven carrier choice is tried first next time' ($rememberedOrder[0].id -eq 'carrier-yota')
Check 'carrier profile uses a different four-strategy set, not the global list' (@(Get-BenchmarkOrder -Available $carrierCandidates -Carrier 'mts' -Fast).Count -eq 4)

Write-Host ''
Write-Host '== DoH provider probe ==' -ForegroundColor Cyan

Check 'http 000 means blocked (no response)'          ((Test-DohHttpCodeReachable -Code 0) -eq $false)
Check 'http 200 means reachable'                      ((Test-DohHttpCodeReachable -Code 200) -eq $true)
Check 'http 400 means reachable (endpoint answered)'  ((Test-DohHttpCodeReachable -Code 400) -eq $true)
Check 'http 503 means reachable (endpoint answered)'  ((Test-DohHttpCodeReachable -Code 503) -eq $true)
$reachableUrlBody = (Get-Command Test-ReachableUrl).ScriptBlock.ToString()
Check 'Auto-Select accepts HTTP 403/404 responses as reachable endpoints' ($reachableUrlBody.Contains('Test-DohHttpCodeReachable -Code $code') -and (Test-DohHttpCodeReachable -Code 403) -and (Test-DohHttpCodeReachable -Code 404))
Check 'Test-DohProviderAvailable exported'            ([bool](Get-Command Test-DohProviderAvailable -ErrorAction SilentlyContinue))
$moduleTextForDoh = (Get-Command Enable-Doh).ScriptBlock.ToString()
Check 'Enable-Doh probes the provider before applying' ($moduleTextForDoh -match 'Test-DohProviderAvailable -Provider \$Provider')

Write-Host ''
Write-Host '== Support bundle ==' -ForegroundColor Cyan

$bundleRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret-bundle-test-{0}' -f [Guid]::NewGuid().ToString('N'))
try {
    $zip = New-SupportBundle -DestinationPath $bundleRoot
    Check 'support-bundle creates a zip file'         ([IO.File]::Exists($zip))
    Check 'support-bundle zip is not empty'           ((Get-Item -LiteralPath $zip).Length -gt 500)
    $expandDir = Join-Path $bundleRoot 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expandDir -Force
    foreach ($expected in @('diagnostics.txt','dns-status.txt','status.txt','config.json','auto-select-latest.txt','zapret-latest.log','system.txt','README.txt')) {
        Check ("support-bundle contains {0}" -f $expected) (Test-Path (Join-Path $expandDir $expected))
    }
    $diagText = [IO.File]::ReadAllText((Join-Path $expandDir 'diagnostics.txt'))
    Check 'support-bundle diagnostics captured content' ($diagText.Length -gt 20)
    $readmeText = [IO.File]::ReadAllText((Join-Path $expandDir 'README.txt'))
    Check 'support-bundle readme explains how to file the issue' ($readmeText -match 'github.com/Flowseal')
} finally {
    Remove-Item -LiteralPath $bundleRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$supportBundleFunctionBody = (Get-Command New-SupportBundle).ScriptBlock.ToString()
Check 'support-bundle prints its exact file list before creating destination/staging' ($supportBundleFunctionBody.IndexOf('$plan.Files') -lt $supportBundleFunctionBody.IndexOf('New-Item -ItemType Directory -Path $DestinationPath'))
Check 'support-bundle preview returns before collection and file creation' ($supportBundleFunctionBody.IndexOf('if ($Preview)') -lt $supportBundleFunctionBody.IndexOf('$staging ='))
Check 'New-SupportBundle exported'                ([bool](Get-Command New-SupportBundle -ErrorAction SilentlyContinue))
Check 'CLI wires support-bundle'                  ($zapretPs1 -match "'support-bundle'")
Check 'menu exposes support report in both locales' ($zapretPs1.Contains('Create a support report') -and $zapretPs1 -match "'17'\s+\{\s*Invoke-MenuSupportBundle\s*\}")

Write-Host ''
Write-Host '== Import config (migration) ==' -ForegroundColor Cyan

$oldRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret-import-old-{0}' -f [Guid]::NewGuid().ToString('N'))
$newRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret-import-new-{0}' -f [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $oldRoot 'lists') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $oldRoot 'bin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $newRoot 'bin') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $oldRoot 'strategies.json'), '{"strategies":[]}')
    [IO.File]::WriteAllText((Join-Path $oldRoot 'config.json'), '{"version":1,"checkUpdates":false,"gameFilter":{"mode":"all","tcp":"1024-65535","udp":"1024-65535"}}')
    [IO.File]::WriteAllText((Join-Path $oldRoot 'lists\list-general-user.txt'), "example.com`r`n")
    [IO.File]::WriteAllText((Join-Path $oldRoot 'lists\ipset-all.txt'), "1.2.3.4/32`r`n")
    [IO.File]::WriteAllText((Join-Path $oldRoot 'bin\ACTIVE_discord.bin'), 'fake')
    [IO.File]::WriteAllText((Join-Path $newRoot 'config.json'), '{"version":1}')

    $result = Copy-ExternalConfigFiles -SourcePath $oldRoot -DestinationRoot $newRoot
    Check 'import copies config.json'               ((Test-Path (Join-Path $newRoot 'config.json')) -and (([IO.File]::ReadAllText((Join-Path $newRoot 'config.json'))) -match '"all"'))
    Check 'import copies user lists'                (Test-Path (Join-Path $newRoot 'lists\list-general-user.txt'))
    Check 'import copies ipset-all.txt'             (Test-Path (Join-Path $newRoot 'lists\ipset-all.txt'))
    Check 'import copies ACTIVE_*.bin'              (Test-Path (Join-Path $newRoot 'bin\ACTIVE_discord.bin'))
    Check 'import backs up overwritten destination' ($result.BackedUp -contains 'config.json' -and $result.BackupDir -and (Test-Path -LiteralPath $result.BackupDir))
    Check 'import reports all 4 copied files'       ($result.Copied.Count -eq 4)

    $list = @(Get-MigrationFileList -SourcePath $oldRoot)
    Check 'migration file list is complete'         ($list.Count -eq 4 -and ($list -contains 'config.json') -and ($list -contains 'lists\list-general-user.txt') -and ($list -contains 'lists\ipset-all.txt') -and ($list -contains 'bin\ACTIVE_discord.bin'))

    $threw = $false
    try { [void](Copy-ExternalConfigFiles -SourcePath $oldRoot -DestinationRoot $oldRoot) } catch { $threw = $true }
    Check 'import into itself is rejected'          $threw

    $emptyDir = Join-Path ([IO.Path]::GetTempPath()) ('zapret-import-empty-{0}' -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    $threw = $false
    try { [void](Copy-ExternalConfigFiles -SourcePath $emptyDir -DestinationRoot $newRoot) } catch { $threw = $true }
    Check 'non-zapret source folder is rejected'    $threw
    Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $oldRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $newRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'CLI wires import-config'                   ($zapretPs1 -match "'import-config'")
Check 'menu lists Import Config'                  ($zapretPs1.Contains('Import settings from an older folder'))
Check 'Import-ExternalConfig exported'             ([bool](Get-Command Import-ExternalConfig -ErrorAction SilentlyContinue))

Write-Host ''Write-Host ''
Write-Host '== Domain manager ==' -ForegroundColor Cyan

Check 'URL with scheme+www+path normalizes'     ((ConvertTo-Domain -InputText 'https://www.Example.com/watch?v=123') -eq 'example.com')
Check 'trailing dot stripped'                  ((ConvertTo-Domain -InputText 'youtube.com.') -eq 'youtube.com')
Check 'subdomains are preserved'               ((ConvertTo-Domain -InputText 'm.youtube.com') -eq 'm.youtube.com')
Check 'port is stripped'                       ((ConvertTo-Domain -InputText 'example.com:8443/path') -eq 'example.com')
Check 'userinfo is stripped'                   ((ConvertTo-Domain -InputText 'https://user:pass@example.com/') -eq 'example.com')
Check 'cyrillic domain is rejected'            ($null -eq (ConvertTo-Domain -InputText 'пример.рф'))
Check 'single-label host is rejected'          ($null -eq (ConvertTo-Domain -InputText 'localhost'))
Check 'garbage is rejected'                    ($null -eq (ConvertTo-Domain -InputText 'not a domain at all'))
Check 'punycode TLD is accepted (mail.xn--p1ai)' ((ConvertTo-Domain -InputText 'mail.xn--p1ai') -eq 'mail.xn--p1ai')
Check 'punycode TLD with subdomain accepted'    ((ConvertTo-Domain -InputText 'sait.xn--80aswg') -eq 'sait.xn--80aswg')
Check 'label with hyphen at end still rejected' ($null -eq (ConvertTo-Domain -InputText 'a-.bad.com'))
Check 'empty input is rejected'                ($null -eq (ConvertTo-Domain -InputText ''))
Check 'uppercase normalizes to lowercase'      ((ConvertTo-Domain -InputText 'DISCORD.COM') -eq 'discord.com')
$discovered = @(Select-DiscoveredDomains -RawNames @('WWW.Example.com', 'example.com', 'https://www.discord.com/channels', 'discord.com', 'github.com'))
Check 'domain discovery normalizes, deduplicates and sorts results' (($discovered -join ',') -eq 'discord.com,example.com,github.com')
$discoveryNoise = @(Select-DiscoveredDomains -RawNames @('localhost', 'host.local', 'router.arpa', 'edge.microsoft.com', 'microsoft.com', 'download.windowsupdate.com', 'probe.msftconnecttest.com', 'dns.msftncsi.com', 'www.bing.com', 'bing.com'))
Check 'domain discovery filters localhost and local/arpa suffixes' (@($discoveryNoise | Where-Object { $_ -match '^(localhost|.*\.local|.*\.arpa)$' }).Count -eq 0)
Check 'domain discovery filters Microsoft, Windows Update, NCSI and Bing domains' ($discoveryNoise.Count -eq 0)
$domainSelection = @(ConvertFrom-DomainDiscoverySelection -Selection '1,3,5' -ItemCount 5)
$domainRange = @(ConvertFrom-DomainDiscoverySelection -Selection '2-4' -ItemCount 5)
Check 'domain discovery selection parses lists, ranges and all' (($domainSelection -join ',') -eq '1,3,5' -and ($domainRange -join ',') -eq '2,3,4' -and (@(ConvertFrom-DomainDiscoverySelection -Selection 'all' -ItemCount 3) -join ',') -eq '1,2,3')
$threw = $false
try { [void](ConvertFrom-DomainDiscoverySelection -Selection '1;Remove-Item' -ItemCount 5) } catch { $threw = $true }
Check 'domain discovery selection rejects command-like input' $threw

$siteRecommendations = @(Get-RecommendedSiteCatalog)
$expectedRecommendationIds = @('youtube','discord','whatsapp','instagram','facebook','tiktok','x','twitch')
$actualRecommendationIds = @($siteRecommendations | ForEach-Object { [string]$_.Id })
Check 'recommended sites include eight selectable popular services' ($actualRecommendationIds.Count -eq $expectedRecommendationIds.Count -and @($expectedRecommendationIds | Where-Object { $_ -notin $actualRecommendationIds }).Count -eq 0 -and 'telegram' -notin $actualRecommendationIds)
$recommendationDomainsValid = $true
foreach ($siteRecommendation in $siteRecommendations) {
    $normalizedRecommendationDomains = @($siteRecommendation.Domains | ForEach-Object { ConvertTo-Domain -InputText ([string]$_) } | Where-Object { $_ })
    if ($normalizedRecommendationDomains.Count -ne $siteRecommendation.Domains.Count -or @($normalizedRecommendationDomains | Sort-Object -Unique).Count -ne $normalizedRecommendationDomains.Count) { $recommendationDomainsValid = $false }
}
Check 'recommended site hostnames are valid and unique within each service' $recommendationDomainsValid
$telegramRecommendation = $siteRecommendations | Where-Object { $_.Id -eq 'telegram' -or ($_.Domains | Where-Object { $_ -match 'telegram|(^|\.)t\.me$' }) } | Select-Object -First 1
Check 'recommended sites carry no Telegram entry or domains' ($null -eq $telegramRecommendation)
$siteMenuSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'zapret.ps1'))
Check 'My Sites exposes recommended services with confirmation before adding' ($siteMenuSource.Contains("'   8. Рекомендации сайтов'") -and $siteMenuSource.Contains('Invoke-MenuSiteRecommendations') -and $siteMenuSource.Contains('Add the listed hostnames to the bypass list?'))
Check 'site recommendations respect existing exclusion lists' ($siteMenuSource.Contains('list-exclude.txt') -and $siteMenuSource.Contains('Adding them to the bypass list does not override the exclusion'))
Check 'My Sites hides the empty-list template placeholder and comments' ($siteMenuSource.Contains("-ne 'domain.example.abc'") -and $siteMenuSource.Contains("-notmatch '^\s*#'"))

$listsTmp = Join-Path ([IO.Path]::GetTempPath()) ('zapret-domain-test-{0}' -f [Guid]::NewGuid().ToString('N'))
try {
    $added = Add-DomainToList -Domain 'https://www.OpenAI.com/blog/post' -Kind general -ListsDir $listsTmp
    Check 'domain added to list-general-user.txt' ($added -eq 'added' -and ((Get-Content -LiteralPath (Join-Path $listsTmp 'list-general-user.txt')) -contains 'openai.com'))
    $dup = Add-DomainToList -Domain 'openai.com' -Kind general -ListsDir $listsTmp
    Check 'duplicate domain is not re-added'      ($dup -eq 'exists' -and (@(Get-Content -LiteralPath (Join-Path $listsTmp 'list-general-user.txt') | Where-Object { $_ -eq 'openai.com' }).Count -eq 1))
    $added2 = Add-DomainToList -Domain 'rutube.ru' -Kind exclude -ListsDir $listsTmp
    Check 'exclude domain lands in list-exclude-user.txt' ($added2 -eq 'added' -and ((Get-Content -LiteralPath (Join-Path $listsTmp 'list-exclude-user.txt')) -contains 'rutube.ru'))
    $threw = $false
    try { [void](Add-DomainToList -Domain '!!!bogus!!!' -Kind general -ListsDir $listsTmp) } catch { $threw = $true }
    Check 'invalid domain is rejected'            $threw
    $added3 = Add-DomainToList -Domain 'openai.com' -Kind exclude -ListsDir $listsTmp
    Check 'same domain can be present in both user lists' ($added3 -eq 'added')
    [IO.File]::WriteAllText((Join-Path $listsTmp 'list-general-user.txt'), "openai.com # user comment`r`nopenai.com`r`n")
    $removed = Remove-DomainFromLists -Domain 'https://www.OpenAI.com/research' -ListsDir $listsTmp
    $generalNow = @(Get-Content -LiteralPath (Join-Path $listsTmp 'list-general-user.txt') | Where-Object { $_ -eq 'openai.com' })
    $excludeNow = @(Get-Content -LiteralPath (Join-Path $listsTmp 'list-exclude-user.txt') | Where-Object { $_ -eq 'openai.com' })
    $excludeKept = @(Get-Content -LiteralPath (Join-Path $listsTmp 'list-exclude-user.txt') | Where-Object { $_ -eq 'rutube.ru' })
    Check 'domain remove deletes exact normalized domain from both files' ($removed.TotalRemoved -eq 3 -and $removed.GeneralRemoved -eq 2 -and $removed.ExcludeRemoved -eq 1 -and $generalNow.Count -eq 0 -and $excludeNow.Count -eq 0 -and $excludeKept.Count -eq 1)

    [void](Add-DomainToList -Domain 'custom.example' -Kind general -ListsDir $listsTmp)
    [void](Add-DomainToList -Domain 'custom.example' -Kind exclude -ListsDir $listsTmp)
    $ipsetFile = Join-Path $listsTmp 'ipset-all.txt'
    [IO.File]::WriteAllText($ipsetFile, "1.2.3.0/24`r`n")
    $reset = Reset-UserDomainLists -ListsDir $listsTmp
    $defaultGeneral = Get-DefaultUserDomainListContent -Kind general
    $defaultExclude = Get-DefaultUserDomainListContent -Kind exclude
    Check 'domain reset restores default user-list templates' ($reset.Changed -and ([IO.File]::ReadAllText((Join-Path $listsTmp 'list-general-user.txt')) -ceq $defaultGeneral) -and ([IO.File]::ReadAllText((Join-Path $listsTmp 'list-exclude-user.txt')) -ceq $defaultExclude))
    Check 'domain reset leaves IPSet untouched' (([IO.File]::ReadAllText($ipsetFile)) -eq "1.2.3.0/24`r`n")
    Check 'domain reset is idempotent' (-not (Reset-UserDomainLists -ListsDir $listsTmp).Changed)
} finally {
    Remove-Item -LiteralPath $listsTmp -Recurse -Force -ErrorAction SilentlyContinue
}
$zapretPs1Text2 = [IO.File]::ReadAllText((Join-Path $repoRoot 'zapret.ps1'))
Check 'CLI wires the domain action'           ($zapretPs1Text2 -match "'domain'")
Check 'menu lists My Sites'                   ($zapretPs1Text2 -match 'My Sites')
Check 'My Sites exposes Notepad and reset actions' ($zapretPs1Text2.Contains('notepad.exe') -and $zapretPs1Text2.Contains('Reset-UserDomainLists'))
Check 'CLI wires domain remove'                 ($zapretPs1Text2.Contains("'remove' {") -and $zapretPs1Text2.Contains('Remove-DomainFromLists'))
Check 'domain discovery is wired to CLI and My Sites submenu' ($zapretPs1Text2.Contains("'discover-domains'") -and $zapretPs1Text2.Contains('Invoke-DomainDiscovery') -and $zapretPs1Text2.Contains('Find domains in the DNS cache'))
$discoveryBody = (Get-Command Invoke-DomainDiscovery).ScriptBlock.ToString()
Check 'DNS discovery guards Windows calls and requires admin' ($discoveryBody.Contains('$script:OnWindows') -and $discoveryBody.Contains('Assert-Admin') -and $discoveryBody.Contains('Clear-DnsClientCache') -and $discoveryBody.Contains('Get-DnsClientCache'))

Write-Host ''
Write-Host '== Rollback snapshots ==' -ForegroundColor Cyan

$rbTmp = Join-Path ([IO.Path]::GetTempPath()) ('zapret-rollback-test-{0}' -f [Guid]::NewGuid().ToString('N'))
try {
    $rbLog = Join-Path $rbTmp 'logs'
    New-Item -ItemType Directory -Path $rbLog -Force | Out-Null
    $ipset = Join-Path $rbTmp 'ipset-all.txt'
    $hostsF = Join-Path $rbTmp 'hosts'
    $cfgF   = Join-Path $rbTmp 'config.json'
    [IO.File]::WriteAllText($ipset, "1.1.1.1/32`r`n")
    [IO.File]::WriteAllText($hostsF, "127.0.0.1 localhost`r`n")
    [IO.File]::WriteAllText($cfgF, '{"version":1,"checkUpdates":true,"gameFilter":{"mode":"disabled","tcp":"1024-65535","udp":"1024-65535"}}')

    $meta = Save-RollbackSnapshot -Reason 'strategy' -Strategy 'alt' -HostsPath $hostsF -LogDir $rbLog -IpsetFile $ipset -ConfigPath $cfgF
    Check 'rollback: snapshot captures ipset and hosts' ($null -ne $meta -and (Test-Path -LiteralPath (Join-Path $meta.folder 'ipset-all.txt')) -and (Test-Path -LiteralPath (Join-Path $meta.folder 'hosts')))
    $rbCfg = Get-Config -Path $cfgF
    Check 'rollback: pointer written to config.json'   ($null -ne $rbCfg.rollback -and $rbCfg.rollback.strategy -eq 'alt' -and $rbCfg.rollback.reason -eq 'strategy')

    [IO.File]::WriteAllText($ipset, '9.9.9.9/32')
    [IO.File]::WriteAllText($hostsF, '# broken')
    $ok = Restore-RollbackSnapshot -LogDir $rbLog -IpsetFile $ipset -HostsPath $hostsF -ConfigPath $cfgF -ReinstallService:$false
    Check 'rollback: restore returns true'             ($ok -eq $true)
    Check 'rollback: ipset restored'                   (([IO.File]::ReadAllText($ipset)).Contains('1.1.1.1/32'))
    Check 'rollback: hosts restored'                   (([IO.File]::ReadAllText($hostsF)).Contains('localhost'))
    Check 'rollback: config pointer cleared'           ($null -eq (Get-Config -Path $cfgF).rollback)
    Check 'rollback: pre-restore safety backup exists' ((Get-ChildItem -LiteralPath $rbLog -Directory -Filter 'rollback-*-before-rollback').Count -ge 1)

    $second = Restore-RollbackSnapshot -LogDir $rbLog -IpsetFile $ipset -HostsPath $hostsF -ConfigPath $cfgF -ReinstallService:$false
    Check 'rollback: second restore is a no-op'        ($second -eq $false)
} finally {
    Remove-Item -LiteralPath $rbTmp -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'CLI wires the rollback action'         ($zapretPs1 -match "'rollback'")
Check 'menu lists Rollback'                   ($zapretPs1 -match 'Rollback')

Write-Host ''
Write-Host '== Log rotation ==' -ForegroundColor Cyan

$rotRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret-rotate-test-{0}' -f [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $rotRoot -Force | Out-Null
    foreach ($i in 1..6) { $f = Join-Path $rotRoot ("old-{0}.log" -f $i); [IO.File]::WriteAllText($f, 'x'); (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddDays(-30) }
    foreach ($i in 1..2) { [IO.File]::WriteAllText((Join-Path $rotRoot ("new-{0}.log" -f $i)), 'x') }
    $deleted = Invoke-LogRotation -LogDir $rotRoot -MaxAgeDays 14 -MaxFiles 20
    Check 'rotation deletes files older than 14 days' ($deleted -eq 6 -and @(Get-ChildItem -LiteralPath $rotRoot -Filter '*.log').Count -eq 2)
    foreach ($i in 1..5) { [IO.File]::WriteAllText((Join-Path $rotRoot ("bulk-{0}.log" -f $i)), 'x') }
    $deleted = Invoke-LogRotation -LogDir $rotRoot -MaxAgeDays 3650 -MaxFiles 3
    Check 'rotation keeps only the newest N files'    ($deleted -eq 4 -and @(Get-ChildItem -LiteralPath $rotRoot -Filter '*.log').Count -eq 3)
    $keep = Invoke-LogRotation -LogDir $rotRoot -MaxAgeDays 3650 -MaxFiles 20
    Check 'rotation is a no-op under the limits'      ($keep -eq 0)
    $none = Invoke-LogRotation -LogDir (Join-Path $rotRoot 'does-not-exist')
    Check 'rotation handles a missing logs directory' ($none -eq 0)
} finally {
    Remove-Item -LiteralPath $rotRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'log rotation is wired into zapret.ps1' ($zapretPs1 -match 'Invoke-LogRotation')

Write-Host ''
Write-Host '== Clone strategy (strategies-user.json) ==' -ForegroundColor Cyan

$baseList = @([pscustomobject]@{ id='base-a'; name='base-a' }, [pscustomobject]@{ id='base-b'; name='base-b' })
$userList = @([pscustomobject]@{ id='base-b'; name='base-b-user-override' }, [pscustomobject]@{ id='mine-c'; name='mine-c' })
$merged = @(Merge-StrategyLists -Base $baseList -User $userList)
Check 'overlay keeps base strategies'          (($merged | Where-Object id -eq 'base-a').Count -eq 1)
Check 'overlay overrides same-id user entries' (($merged | Where-Object id -eq 'base-b').name -eq 'base-b-user-override')
Check 'overlay appends new user strategies'    (($merged | Where-Object id -eq 'mine-c').Count -eq 1)
Check 'overlay with no user list keeps base'   (@(Merge-StrategyLists -Base $baseList -User @()).Count -eq 2)

Check 'clone id: valid passes'                 (Test-StrategyCloneId -Id 'my-general')
Check 'clone id: uppercase rejected'           (-not (Test-StrategyCloneId -Id 'MyId'))
Check 'clone id: leading dash rejected'        (-not (Test-StrategyCloneId -Id '-bad'))
Check 'clone id: single char rejected'         (-not (Test-StrategyCloneId -Id 'x'))

$cloneRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret-clone-test-{0}' -f [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null
    $userFile = Join-Path $cloneRoot 'strategies-user.json'
    $clone = New-UserStrategy -BaseId 'general' -NewId 'my-general' -UserFile $userFile
    Check 'clone: created with normalized id'     ($clone.id -eq 'my-general')
    Check 'clone: args inherited from base'       ($clone.args -match '--wf-tcp=')
    Check 'clone: written to strategies-user.json' ((Read-UserStrategies -UserFile $userFile).Count -eq 1)
    $threw = $false
    try { [void](New-UserStrategy -BaseId 'general' -NewId 'My Bad Id' -UserFile $userFile) } catch { $threw = $true }
    Check 'clone: invalid id rejected'             $threw
    $threw = $false
    try { [void](New-UserStrategy -BaseId 'general' -NewId 'my-general' -UserFile $userFile) } catch { $threw = $true }
    Check 'clone: duplicate id rejected'           $threw
    $threw = $false
    try { [void](New-UserStrategy -BaseId 'no-such-base' -NewId 'another' -UserFile $userFile) } catch { $threw = $true }
    Check 'clone: unknown base rejected'           $threw

    [void](Set-UserStrategyParam -Id 'my-general' -Param repeats -Value 99 -UserFile $userFile)
    $afterParam = @(Read-UserStrategies -UserFile $userFile)[0]
    Check 'clone: repeats replaced everywhere'     ($afterParam.args -notmatch '--dpi-desync-repeats=\d*[0-8](?!\d)' -and ([regex]::Matches($afterParam.args, '--dpi-desync-repeats=99')).Count -ge 2)
    [void](Set-UserStrategyParam -Id 'my-general' -Param seqovl -Value 700 -UserFile $userFile)
    $afterSeq = @(Read-UserStrategies -UserFile $userFile)[0]
    Check 'clone: split-seqovl replaced'           ($afterSeq.args -match '--dpi-desync-split-seqovl=700')
    $threw = $false
    try { [void](Set-UserStrategyParam -Id 'no-such' -Param repeats -Value 3 -UserFile $userFile) } catch { $threw = $true }
    Check 'clone: param edit on unknown clone rejected' $threw

    [void](Set-UserStrategyFake -Id 'my-general' -FakeBaseName 'stun' -UserFile $userFile)
    $afterFake = @(Read-UserStrategies -UserFile $userFile)[0]
    Check 'clone: ACTIVE_* fakes replaced'         ($afterFake.args -match 'stun\.bin' -and $afterFake.args -notmatch 'ACTIVE_(DISCORD|GAME)_UDP\.bin')
    $threw = $false
    try { [void](Set-UserStrategyFake -Id 'my-general' -FakeBaseName '..\..\evil' -UserFile $userFile) } catch { $threw = $true }
    Check 'clone: fake name traversal rejected'    $threw
} finally {
    Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'CLI wires clone-strategy'             ($zapretPs1 -match "'clone-strategy'")
Check 'menu lists Clone Strategy'            ($zapretPs1.Contains('Create or import a strategy'))

Write-Host ''
Write-Host ''
Write-Host '== Strategy export/import share code ==' -ForegroundColor Cyan

$shareTmp = Join-Path ([IO.Path]::GetTempPath()) ('zapret-share-test-{0}' -f [Guid]::NewGuid().ToString('N'))
try {
    $sourceStrategy = Get-Strategy -Id 'general'
    $shareCode = ConvertTo-StrategyShareString -Strategy $sourceStrategy
    $roundTrip = ConvertFrom-StrategyShareString -ShareString $shareCode
    Check 'strategy share code has zapret1 prefix' ($shareCode.StartsWith('zapret1:'))
Check 'legacy strategy share-code function aliases remain available' ((Get-Command ConvertTo-StrategyShareCode -ErrorAction SilentlyContinue) -and (Get-Command ConvertFrom-StrategyShareCode -ErrorAction SilentlyContinue))
    Check 'export/import round-trip preserves all required fields' ($roundTrip.id -eq $sourceStrategy.id -and $roundTrip.name -eq $sourceStrategy.name -and $roundTrip.description -eq $sourceStrategy.description -and $roundTrip.args -eq $sourceStrategy.args)
    $renamed = ConvertFrom-StrategyShareString -ShareString $shareCode -NewId 'shared-general'
    Check 'import -NewId changes only the normalized ID' ($renamed.id -eq 'shared-general' -and $renamed.name -eq $sourceStrategy.name -and $renamed.args -eq $sourceStrategy.args)
    $userStrategiesFile = Join-Path $shareTmp 'strategies-user.json'
    $imported = Import-UserStrategy -ShareString $shareCode -NewId 'shared-general' -UserFile $userStrategiesFile
    $stored = @(Read-UserStrategies -UserFile $userStrategiesFile)
    Check 'strategy import persists to strategies-user.json' ($imported.id -eq 'shared-general' -and $stored.Count -eq 1 -and $stored[0].args -eq $sourceStrategy.args)

    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString 'zapret1:@@@@') } catch { $threw = $true }
    Check 'strategy import rejects malformed Base64' $threw
    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString ('zapret2:' + $shareCode.Substring(8))) } catch { $threw = $true }
    Check 'strategy import rejects a foreign prefix' $threw
    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString ('zapret1:' + ('A' * 16377))) } catch { $threw = $true }
    Check 'strategy import rejects share strings over 16 KB' $threw
    $invalidIdPayload = New-TestStrategySharePayload -StrategyArgs '--wf-tcp=80' -StrategyId '../invalid'
    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString $invalidIdPayload) } catch { $threw = $true }
    Check 'strategy import rejects an invalid ID' $threw

    $unsafeShellPayload = New-TestStrategySharePayload -StrategyArgs '--wf-tcp=80;Write-Host x'
    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString $unsafeShellPayload) } catch { $threw = $true }
    Check 'strategy import rejects shell metacharacters in args' $threw
    $percentPayload = New-TestStrategySharePayload -StrategyArgs '--wf-tcp=%PATH%'
    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString $percentPayload) } catch { $threw = $true }
    Check 'strategy import rejects %PATH% batch expansion' $threw
    $quotePayload = New-TestStrategySharePayload -StrategyArgs '--wf-tcp=80 --filter-tcp="443'
    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString $quotePayload) } catch { $threw = $true }
    Check 'strategy import rejects unbalanced quotes' $threw

    $unsafeOptionPayload = New-TestStrategySharePayload -StrategyArgs '--wf-tcp=80 --evil=whoami'
    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString $unsafeOptionPayload) } catch { $threw = $true }
    Check 'strategy import rejects unsupported/dangerous args' $threw

    $unsafePathPayload = New-TestStrategySharePayload -StrategyArgs '--wf-tcp=80 --hostlist="C:\Windows\win.ini"'
    $threw = $false
    try { [void](ConvertFrom-StrategyShareString -ShareString $unsafePathPayload) } catch { $threw = $true }
    Check 'strategy import rejects paths outside BIN/LISTS placeholders' $threw
} finally {
    Remove-Item -LiteralPath $shareTmp -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'CLI wires export-strategy and import-strategy' ($zapretPs1.Contains("'export-strategy'") -and $zapretPs1.Contains("'import-strategy'") -and $zapretPs1.Contains('Export-UserStrategy') -and $zapretPs1.Contains('Import-UserStrategy -ShareString'))
Check 'strategy menu offers import and export in both locales' ($zapretPs1.Contains('Import a strategy from a zapret1:... code') -and $zapretPs1.Contains('Export a strategy as a share code'))

Write-Host '== Scheduled weekly re-check ==' -ForegroundColor Cyan

$tr = Get-AutoSelectTaskArguments -PowerShellPath 'C:\Windows\powershell.exe' -ScriptPath 'C:\zapret\zapret.ps1'
Check 'task payload runs smart scheduled mode' ($tr -match 'auto-select -Install -Scheduled')
$scheduledAutoSelectText = (Get-Command Invoke-AutoSelect).ScriptBlock.ToString()
Check 'auto-select supports -Scheduled'        ($scheduledAutoSelectText -match '\[switch\]\$Scheduled')
Check 'auto-select early exit keeps winws'     ($scheduledAutoSelectText -match 'NOT restarted')
Write-Host ''
Write-Host '== Integration smoke (CLI on a temp copy) ==' -ForegroundColor Cyan

$smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret-smoke-{0}' -f ([Guid]::NewGuid().ToString('N')))
try {
    New-Item -ItemType Directory -Path (Join-Path $smokeRoot 'src') -Force | Out-Null
    foreach ($item in @('zapret.ps1', 'strategies.json', 'service.bat', 'zapret.bat', '.service')) {
        Copy-Item (Join-Path $repoRoot $item) $smokeRoot -Recurse -Force
    }
    Copy-Item (Join-Path $repoRoot 'src\Zapret.psm1') (Join-Path $smokeRoot 'src\Zapret.psm1') -Force
    Copy-Item (Join-Path $repoRoot 'src\parts') (Join-Path $smokeRoot 'src\parts') -Recurse -Force

    $engine = (Get-Process -Id $PID).Path
    $smoke = {
        param([string[]]$CliArgs)
        & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $smokeRoot 'zapret.ps1') @CliArgs 2>&1 | Out-String
    }

    $out = & $smoke @('list')
    Check 'smoke: list shows strategies'              (($out -match 'general') -and ($out -match 'alt'))
    $out = & $smoke @('version')
    $expectedVersion = [IO.File]::ReadAllText((Join-Path $repoRoot '.service/version.txt')).Trim()
    Check 'smoke: version prints the local version'   ($out -match [regex]::Escape($expectedVersion))
    $out = & $smoke @('export-strategy', 'general')
    $shareMatch = [regex]::Match($out, '(?m)^zapret1:[A-Za-z0-9+/]+={0,2}(?=\r?$)')
    Check 'smoke: export-strategy emits a share code' ($shareMatch.Success)
    if ($shareMatch.Success) {
        $out = & $smoke @('import-strategy', $shareMatch.Value, '-NewId', 'cli-shared')
        $storedStrategy = $null
        try { $storedStrategy = [IO.File]::ReadAllText((Join-Path $smokeRoot 'strategies-user.json')) | ConvertFrom-Json } catch { }
        Check 'smoke: import-strategy parses -NewId and persists the imported strategy' (($out -match 'cli-shared') -and ($storedStrategy.strategies[0].id -eq 'cli-shared'))
    $out = & $smoke @('fallback')
    Check 'smoke: fallback prints the ladder status' ($out -match 'Запасные стратегии')
    $out = & $smoke @('doctor')
    Check 'smoke: doctor runs and prints its report' ($out -match 'ДОКТОР УСТАНОВКИ')
    New-Item -ItemType Directory -Path (Join-Path $smokeRoot 'lists') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $smokeRoot 'lists\list-general-user.txt') -Value 'smoke.example' -Encoding UTF8
    $smokeExportPath = Join-Path ([IO.Path]::GetTempPath()) ('smoke-export-{0}.zip' -f ([Guid]::NewGuid().ToString('N')))
    $out = & $smoke @('export-config', $smokeExportPath)
    Check 'smoke: export-config creates the archive' (Test-Path -LiteralPath $smokeExportPath)
    Remove-Item -LiteralPath $smokeExportPath -Force -ErrorAction SilentlyContinue
    $out = & $smoke @('domain', 'add', 'cli-domain.example')
    Check 'smoke: domain add creates a user-list entry' ($out -match 'cli-domain.example')
    $out = & $smoke @('domain', 'remove', 'cli-domain.example')
    Check 'smoke: domain remove deletes a CLI-added entry' ($out -match 'удалён' -and ([IO.File]::ReadAllText((Join-Path $smokeRoot 'lists\list-general-user.txt')) -notmatch 'cli-domain.example'))
    }
    $out = & $smoke @('game-filter', 'off')
    Check 'smoke: game-filter off applies'            ($out -match 'выключен|off')
    $out = & $smoke @('game-filter', 'all', '-TcpPorts', 'invalid-range')
    Check 'smoke: invalid port range is rejected'     ($out -match 'портов TCP|Invalid TCP port range')
    $out = & $smoke @('status')
    Check 'smoke: status runs'                        ($out -match 'SERVICE|STATUS|СОСТОЯНИЕ')
    $smokeConfigPath = Join-Path $smokeRoot 'config.json'
    $smokeConfig = [IO.File]::ReadAllText($smokeConfigPath) | ConvertFrom-Json
    $smokeConfig | Add-Member -NotePropertyName uiLanguage -NotePropertyValue 'en' -Force
    [IO.File]::WriteAllText($smokeConfigPath, ($smokeConfig | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    $out = & $smoke @('status')
    Check 'smoke: saved English locale localizes CLI status' ($out -match 'STATUS' -and $out -match 'Game traffic')
    $out = & $smoke @('help')
    Check 'smoke: help follows the saved English locale'    ($out -match 'command reference' -and $out -match 'Full documentation')
    $out = & $smoke @('bogus-action')
    Check 'smoke: unknown action is reported'         ($out -match 'Unknown command|Неизвестная команда')
} finally {
    Remove-Item $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '== Security checks ==' -ForegroundColor Cyan

# --- Static scan: shipped PowerShell sources contain no dynamic-eval helpers ---
$psSources = @(Join-Path $repoRoot 'zapret.ps1')
$psSources += @(Get-ChildItem (Join-Path $repoRoot 'src') -Recurse -File | Where-Object { $_.Extension -in @('.psm1','.ps1') } | Select-Object -ExpandProperty FullName)
$psSources += @(Get-ChildItem (Join-Path $repoRoot 'utils') -Filter '*.ps1' | Select-Object -ExpandProperty FullName)
foreach ($forbidden in @('Invoke-Expression', 'iex ', 'cmd.exe /c', '& cmd')) {
    $hits = @($psSources | Where-Object { ([IO.File]::ReadAllText($_)).Contains($forbidden) })
    Check ("no '{0}' in shipped sources" -f $forbidden) ($hits.Count -eq 0)
}

$moduleFiles = @(Get-ChildItem (Join-Path $repoRoot 'src') -Recurse -File | Where-Object { $_.Extension -in @('.psm1','.ps1') } | Sort-Object FullName)
$moduleText = (($moduleFiles | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
Check 'main module dot-sources every implementation part in a fixed order' (([IO.File]::ReadAllText((Join-Path $repoRoot 'src\Zapret.psm1')).Contains("'Zapret.Runtime.ps1'")) -and ($moduleFiles.Count -ge 13) -and ([bool](Get-Command Get-Strategies -ErrorAction SilentlyContinue)))
Check 'module explicitly exports the original function surface' ([IO.File]::ReadAllText((Join-Path $repoRoot 'src\Zapret.psm1')).Contains('Export-ModuleMember -Function *') -and @(Get-Command -Module Zapret).Count -ge 183)
$systemToolResolverText = (Get-Command Get-WindowsSystemToolPath).ScriptBlock.ToString()
$stopZapretText = (Get-Command Stop-Zapret).ScriptBlock.ToString()
Check 'Stop-Zapret handles a single running winws process' ($stopZapretText.Contains('$procs = @(Get-WinwsProcess)') -and $stopZapretText.Contains('return $procs.Count'))
Check 'Windows system tools resolve from the OS directory, not PATH' ($systemToolResolverText.Contains('SpecialFolder]::System') -and (-not $systemToolResolverText.Contains('Get-Command')))
Check 'privileged system commands do not use bare PATH lookups' (-not ($moduleText -match '(?im)&\s*(?:sc|schtasks|robocopy|netsh|ping)\.exe\b|&\s*netsh\b|Get-Command\s+(?:powershell|ping|netsh)\.exe'))
$zapretBatText = [IO.File]::ReadAllText((Join-Path $repoRoot 'zapret.bat'))
Check 'zapret.bat pins PowerShell to the Windows system directory' ($zapretBatText -match '(?i)%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe')
# --- Review follow-ups ---
$vpnDiagnostic = [regex]::Match($moduleText, '(?s)# --- VPN / WireGuard.*?No VPN/WireGuard/WARP tooling detected')
Check 'VPN diagnosis uses one unified warning' ($vpnDiagnostic.Success -and ([regex]::Matches($vpnDiagnostic.Value, 'Write-DiagWarn')).Count -eq 1)
Check 'VPN diagnosis still catches generic vpn service names' ($moduleText.Contains('$genericVpnServices = @($serviceNames | Where-Object { $_ -match ''(?i)vpn|happservice'' })'))
Check 'generic VPN names are warned but not auto-disabled' ($vpnDiagnostic.Value.Contains('$vpnServices.Count -eq 0') -and $vpnDiagnostic.Value.Contains('Automatic stop skipped'))
$testUtilityText = [IO.File]::ReadAllText((Join-Path $repoRoot 'utils\test zapret.ps1'))
Check 'test utility no longer shadows module Set-IpsetMode' (($testUtilityText.Contains('function Switch-TestIpsetMode')) -and (-not $testUtilityText.Contains('function Set-IpsetMode')))
$changelogText = [IO.File]::ReadAllText((Join-Path $repoRoot 'CHANGELOG.md'))
Check 'changelog uses the correct Russian spelling хосты' (($changelogText.Contains('хосты')) -and (-not $changelogText.Contains('хослы')))
Check 'changelog bullets are not glued into one line' (-not [regex]::IsMatch($changelogText, ',(?=(Исправлено|Исправлена|Исправлены|Поймано|Новое|Добавлено|Улучшено|Изменено|Удалено|Подтверждено|Найдено)[:\s])'))

# --- Administrative guards on privileged functions ---
foreach ($fn in @('Install-ZapretService', 'Remove-ZapretServices', 'Enable-Doh', 'Reset-DnsToDhcp', 'Set-AutoSelectSchedule', 'Invoke-NetworkOptimize', 'Set-NetworkInterfaceMtu', 'Restore-DnsRollbackSnapshot', 'Restore-NetworkSnapshotFile', 'Set-NetworkRegistryDword', 'Invoke-DnsNetshCommand', 'Invoke-NetworkNetshCommand')) {
    $m = [regex]::Match($moduleText, ('(?s)function\s+' + $fn + '\s*\{.*?\r?\n\}'))
    Check ("{0} asserts administrator rights" -f $fn) ($m.Success -and ($m.Value -match 'Assert-Admin'))
}

# --- Pure helpers: quoting and payload safety ---
Check 'PathName quotes paths with spaces'          ((Get-WinwsPathName -WinwsPath 'C:\Program Files\zapret\bin\winws.exe' -ExpandedArgs '--wf-tcp=80') -eq '"C:\Program Files\zapret\bin\winws.exe" --wf-tcp=80')
$threw = $false; try { [void](Get-WinwsPathName -WinwsPath 'C:\bad"x\winws.exe' -ExpandedArgs '--x') } catch { $threw = $true }
Check 'PathName rejects quotes in the path'        $threw
$tr = Get-AutoSelectTaskArguments -PowerShellPath 'C:\Windows\powershell.exe' -ScriptPath 'C:\zapret\zapret.ps1'
Check 'schtasks payload runs auto-select'          (($tr -match 'auto-select -Install') -and ($tr -match 'zapret\.ps1'))
$threw = $false; try { [void](Get-AutoSelectTaskArguments -PowerShellPath 'C:\bad"p.exe' -ScriptPath 'C:\x.ps1') } catch { $threw = $true }
Check 'schtasks payload rejects quotes'            $threw

# --- Signature severity mapping ---
Check 'Valid signature maps to OK'                 ((Get-SignatureSeverity -Status 'Valid') -eq 'OK')
Check 'HashMismatch maps to FAIL (tampered)'       ((Get-SignatureSeverity -Status 'HashMismatch') -eq 'FAIL')
Check 'NotSigned maps to WARN'                     ((Get-SignatureSeverity -Status 'NotSigned') -eq 'WARN')
Check 'Get-BinarySignatureReport runs'             ($null -ne (Get-BinarySignatureReport))

# --- Input validation ---
$fakeRejected = $false
try { [void](Set-ActiveFake -Target discord -FakeBaseName '..\..\evil') } catch { $fakeRejected = $true }
Check 'fake name rejects path traversal'           $fakeRejected

# --- GitHub Actions: no ${{ }} injection into run: blocks; release bundles .service ---
foreach ($wf in (Get-ChildItem (Join-Path $repoRoot '.github\workflows') -Filter '*.yml')) {
    $badInterp = $false; $inRun = $false
    foreach ($line in (Get-Content $wf.FullName)) {
        if ($line -match '^\s+- name:') { $inRun = $false }
        if ($line -match '^\s+run:') { $inRun = $true; continue }
        if ($inRun -and $line -match '\$\{\{') { $badInterp = $true; break }
    }
    Check ("workflow has no template injection in run: blocks: {0}" -f $wf.Name) (-not $badInterp)
}
$releaseText = [IO.File]::ReadAllText((Join-Path $repoRoot '.github\workflows\release.yml'))
$releaseBuilderPath = Join-Path $repoRoot 'tools\Build-Release.ps1'
$releaseBuilderText = if (Test-Path -LiteralPath $releaseBuilderPath) { [IO.File]::ReadAllText($releaseBuilderPath) } else { '' }
Check 'release workflow uses the clean release builder' ($releaseText.Contains('tools/Build-Release.ps1') -and $releaseBuilderText.Contains('git -C $repoRoot ls-files'))
Check 'release workflow uses the UTF-8 ZIP from the builder, not locale-dependent zip' ($releaseText.Contains('test -s "${NAME}.zip"') -and -not $releaseText.Contains('zip -qr'))
Check 'release package explicitly includes the mobile app list' ($releaseBuilderText.Contains('lists/list-mobile-apps.txt'))
Check 'release package explicitly includes the empty Telegram IP set compatibility stub' ($releaseBuilderText.Contains('lists/ipset-telegram.txt'))
Check 'release package ships the control panel icon' ($releaseBuilderText.Contains("'Zapret-Control.ico'"))
Check 'release package ships the native control launcher' ($releaseBuilderText.Contains("'Zapret-Control.exe'"))
Check 'release package explicitly includes modular PowerShell implementation parts' ($releaseBuilderText.Contains('src/parts/Zapret.Runtime.ps1') -and $releaseBuilderText.Contains('src/parts/Zapret.UserStrategies.ps1'))
Check 'release package validates version and requires .service, binary and instruction' ($releaseBuilderText.Contains('does not match .service/version.txt') -and $releaseBuilderText.Contains("'.service/version.txt'") -and $releaseBuilderText.Contains("'bin/winws.exe'") -and $releaseBuilderText.Contains("'ИНСТРУКЦИЯ.txt'"))
Check 'release workflow creates, verifies, and publishes SHA256SUMS.txt' ($releaseText.Contains('> SHA256SUMS.txt') -and $releaseText.Contains('sha256sum --check SHA256SUMS.txt') -and $releaseText.Contains('            SHA256SUMS.txt'))
Check 'release builder creates and verifies its own SHA256SUMS.txt' ($releaseBuilderText.Contains('Test-ChecksumManifest') -and $releaseBuilderText.Contains("Join-Path `$outputRoot 'SHA256SUMS.txt'"))
Check 'release workflow passes the tag via env' ($releaseText -match '(?m)^\s*TAG:')
if ((Test-Path -LiteralPath (Join-Path $repoRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $releaseBuildTemp = Join-Path ([IO.Path]::GetTempPath()) ('zapret-release-build-{0}' -f [Guid]::NewGuid().ToString('N'))
    try {
        $releaseTestVersion = Get-LocalVersion
        $releaseName = "zapret-discord-youtube-$releaseTestVersion"
        $builtReleasePath = [string](& $releaseBuilderPath -Version $releaseTestVersion -OutputDirectory $releaseBuildTemp)
        $expectedReleasePath = Join-Path $releaseBuildTemp $releaseName
        $expectedReleaseZip = Join-Path $releaseBuildTemp ($releaseName + '.zip')
        $expectedReleaseManifest = Join-Path $releaseBuildTemp 'SHA256SUMS.txt'
        Check 'release builder creates the versioned folder and ZIP' ($builtReleasePath -eq $expectedReleaseZip -and (Test-Path -LiteralPath $expectedReleasePath -PathType Container) -and (Test-Path -LiteralPath $expectedReleaseZip -PathType Leaf))
        $manifestLine = if (Test-Path -LiteralPath $expectedReleaseManifest -PathType Leaf) { [IO.File]::ReadAllText($expectedReleaseManifest).Trim() } else { '' }
        $manifestMatch = [regex]::Match($manifestLine, '^(?<hash>[a-fA-F0-9]{64})  (?<name>[^*]+)$')
        $zipHash = if (Test-Path -LiteralPath $expectedReleaseZip -PathType Leaf) { (Get-FileHash -LiteralPath $expectedReleaseZip -Algorithm SHA256).Hash } else { '' }
        Check 'release builder emits a valid SHA256SUMS.txt that matches the ZIP' ($manifestMatch.Success -and $manifestMatch.Groups['name'].Value -eq ($releaseName + '.zip') -and [string]::Equals($manifestMatch.Groups['hash'].Value, $zipHash, [StringComparison]::OrdinalIgnoreCase))
        $stagedRelativeFiles = @()
        if (Test-Path -LiteralPath $expectedReleasePath -PathType Container) {
            $stagedRelativeFiles = @(Get-ChildItem -LiteralPath $expectedReleasePath -File -Recurse -Force | ForEach-Object { $_.FullName.Substring($expectedReleasePath.Length + 1).Replace('\','/') })
        }
        $releaseRequired = @('zapret.ps1','zapret.bat','service.bat','Zapret-Control.ps1','Zapret-Control.bat','Zapret-Control.ico','Zapret-Control.exe','Update-Zapret.ps1','Update-Zapret.bat','strategies.json','src/Zapret.psm1','src/parts/Zapret.Runtime.ps1','src/parts/Zapret.Strategies.ps1','src/parts/Zapret.IpsetHosts.ps1','src/parts/Zapret.Diagnostics.ps1','src/parts/Zapret.AutoSelect.ps1','src/parts/Zapret.Dns.ps1','src/parts/Zapret.Network.ps1','src/parts/Zapret.Automation.ps1','src/parts/Zapret.Support.ps1','src/parts/Zapret.Maintenance.ps1','src/parts/Zapret.Rollback.ps1','src/parts/Zapret.UserStrategies.ps1','src/parts/Zapret.Watchdog.ps1','src/parts/Zapret.Doctor.ps1','.service/version.txt','bin/winws.exe','bin/WinDivert.dll','bin/WinDivert64.sys','lists/list-mobile-apps.txt','lists/ipset-telegram.txt','ИНСТРУКЦИЯ.txt')
        Check 'release builder includes required program files' (@($releaseRequired | Where-Object { $_ -notin $stagedRelativeFiles }).Count -eq 0)
        $releaseUnwanted = @($stagedRelativeFiles | Where-Object { $_ -match '(^|/)(\.github|tests|logs|uploads)(/|$)|^config\.json$|(^|/)[^/]+-user\.txt$|(?i)\.(zip|rar|7z)$' })
        Check 'release builder excludes workspace/user/development artifacts' ($releaseUnwanted.Count -eq 0)
        $archiveEntries = @()
        if (Test-Path -LiteralPath $expectedReleaseZip -PathType Leaf) {
            $releaseZip = [IO.Compression.ZipFile]::OpenRead($expectedReleaseZip)
            try { $archiveEntries = @($releaseZip.Entries | ForEach-Object { $_.FullName }) } finally { $releaseZip.Dispose() }
        }
        $expectedArchiveEntries = @($stagedRelativeFiles | ForEach-Object { '{0}/{1}' -f $releaseName, $_ })
        Check 'release ZIP contains exactly the staged files' ($archiveEntries.Count -eq $expectedArchiveEntries.Count -and @($expectedArchiveEntries | Where-Object { $_ -notin $archiveEntries }).Count -eq 0 -and @($archiveEntries | Where-Object { $_ -notin $expectedArchiveEntries }).Count -eq 0)
        Check 'release ZIP preserves the Russian instruction filename' ($archiveEntries -contains ($releaseName + '/ИНСТРУКЦИЯ.txt'))
        Check 'release ZIP marks the Russian instruction filename as UTF-8' (Test-ZipEntryHasUtf8NameFlag -Path $expectedReleaseZip -EntryName ($releaseName + '/ИНСТРУКЦИЯ.txt'))
        $wrongVersionRejected = $false
        try { [void](& $releaseBuilderPath -Version '0.0.0' -OutputDirectory $releaseBuildTemp) } catch { $wrongVersionRejected = $true }
        Check 'release builder refuses a version mismatch' ($wrongVersionRejected)
        $existingReleaseRejected = $false
        try { [void](& $releaseBuilderPath -Version $releaseTestVersion -OutputDirectory $releaseBuildTemp) } catch { $existingReleaseRejected = $true }
        Check 'release builder never overwrites an existing package' ($existingReleaseRejected -and (Test-Path -LiteralPath $expectedReleasePath -PathType Container) -and (Test-Path -LiteralPath $expectedReleaseZip -PathType Leaf))
        $whatIfRoot = Join-Path $releaseBuildTemp 'what-if'
        [void](& $releaseBuilderPath -Version $releaseTestVersion -OutputDirectory $whatIfRoot -WhatIf)
        Check 'release builder -WhatIf creates no output' (-not (Test-Path -LiteralPath $whatIfRoot))
    } catch {
        Check 'release builder integration on this Git checkout' $false
        Write-Host ("         {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
    } finally {
        if (Test-Path -LiteralPath $releaseBuildTemp) { Remove-Item -LiteralPath $releaseBuildTemp -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Host '  [SKIP] release builder integration requires a Git checkout.' -ForegroundColor DarkGray
}

# --- Entry points ---
$zapretBat = [IO.File]::ReadAllText((Join-Path $repoRoot 'zapret.bat'))
Check 'zapret.bat does not forward raw CLI args through cmd.exe' (-not $zapretBat.Contains('%*'))
Check 'zapret.bat launches zapret.ps1 via -File'         ($zapretBat -match 'zapret\.ps1')
$serviceBat = [IO.File]::ReadAllText((Join-Path $repoRoot 'service.bat'))
Check 'service.bat forwards to zapret.bat'               ($serviceBat -match 'zapret\.bat')
Check 'service.bat does not forward raw CLI args through cmd.exe' (-not $serviceBat.Contains('%*'))

# --- Standalone control panel (separate from zapret.bat) ---
$controlPanelPath = Join-Path $repoRoot 'Zapret-Control.ps1'
$controlLauncherPath = Join-Path $repoRoot 'Zapret-Control.bat'
$controlPanelText = if (Test-Path -LiteralPath $controlPanelPath) { [IO.File]::ReadAllText($controlPanelPath) } else { '' }
$controlLauncherText = if (Test-Path -LiteralPath $controlLauncherPath) { [IO.File]::ReadAllText($controlLauncherPath) } else { '' }
Check 'standalone control panel files exist' ((Test-Path -LiteralPath $controlPanelPath -PathType Leaf) -and (Test-Path -LiteralPath $controlLauncherPath -PathType Leaf))
$controlExePath = Join-Path $repoRoot 'Zapret-Control.exe'
$controlExeExists = Test-Path -LiteralPath $controlExePath -PathType Leaf
$controlExeHeader = if ($controlExeExists) { @([IO.File]::ReadAllBytes($controlExePath)[0..1]) } else { @() }
Check 'native control launcher exists as a Windows executable' ($controlExeExists -and $controlExeHeader.Count -eq 2 -and $controlExeHeader[0] -eq 0x4D -and $controlExeHeader[1] -eq 0x5A)
Check 'native launcher embeds the icon and launches the panel script' ((Get-Content -LiteralPath (Join-Path $repoRoot 'tools\zapret-control-stub.c') -Raw).Contains('Zapret-Control.ps1') -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools\zapret-control.rc') -Raw).Contains('IDI_APPICON') -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools\zapret-control.rc') -Raw).Contains('VERSIONINFO'))
Check 'control panel shortcut and batch launcher prefer the native executable' ($controlPanelText.Contains('Zapret-Control.exe') -and (Get-Content -LiteralPath $controlLauncherPath -Raw).Contains('Zapret-Control.exe'))
Check 'control panel launcher starts Zapret-Control.ps1 via -File' ($controlLauncherText -match 'Zapret-Control\.ps1' -and $controlLauncherText -match '-File')
Check 'control panel is a WPF window over the existing module' ($controlPanelText.Contains('PresentationFramework') -and $controlPanelText.Contains('src\Zapret.psm1') -and $controlPanelText.Contains('Get-ZapretServiceInfo'))
Check 'control panel keeps zapret.bat intact and offers the classic menu' ($controlPanelText.Contains('zapret.bat') -and $controlPanelText.Contains('btnClassicMenu') -and $zapretBat.Contains('zapret.ps1'))
Check 'control panel uses the custom icon for the window and the shortcut' ($controlPanelText.Contains('Zapret-Control.ico') -and $controlPanelText.Contains('BitmapFrame') -and $controlPanelText.Contains('IconLocation'))
Check 'control panel shortcut starts the app without a console window' ($controlPanelText.Contains('WScript.Shell') -and $controlPanelText.Contains('-WindowStyle Hidden') -and $controlPanelText.Contains('Zapret Control.lnk') -and $controlPanelText.Contains('Get-WindowsSystemToolPath'))
$autoSelectFileText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.AutoSelect.ps1'))
Check 'benchmark failures record why winws.exe failed to start' ($autoSelectFileText.Contains('Get-WinwsStartFailureText') -and $autoSelectFileText.Contains('StartError') -and $autoSelectFileText.Contains('ExitCode'))
Check 'wizard benchmark shows the winws start reason' ($controlPanelText.Contains('Причина: {0}'))
Check 'benchmark decodes winws exit codes and repairs the WinDivert driver' ($autoSelectFileText.Contains('Get-Win32ErrorHint') -and $autoSelectFileText.Contains('Repair-WinDivertService') -and $autoSelectFileText.Contains('ERROR_WRONG_DISK') -and $autoSelectFileText.Contains('StartExitCode'))
Check 'winws failure report keeps the output tail with the real error' ($autoSelectFileText.Contains('$lines.Count - 4'))
$autoSelectModule = (Get-Command Invoke-AutoSelect).Module
$repairFlagReady = $false
try { $repairFlagReady = ((& $autoSelectModule { $script:WinDivertRepairAttempted }) -eq $false) } catch { $repairFlagReady = $false }
Check 'winws driver repair state is initialized before use' $repairFlagReady
Check 'panel can cancel a running check and return to it from any page' ($controlPanelText.Contains('btnWizCancel') -and $controlPanelText.Contains('Stop-WizardRun') -and $controlPanelText.Contains('btnBackToWizard') -and $controlPanelText.Contains('Complete-WizardCancelled'))
Check 'manual run verifies winws and reports the real outcome' ($controlPanelText.Contains('Start-ZapretManualRun') -and $autoSelectFileText.Contains('Start-ZapretManualRun') -and $autoSelectFileText.Contains('winws.exe завершился сразу после запуска'))
Check 'probe results are printed one line per endpoint' ($autoSelectFileText.Contains('{0,-22} {1}') -and -not $autoSelectFileText.Contains('NoNewline'))
Check 'benchmark log shows strategy progress in the title' ($controlPanelText.Contains('WizardRunBaseTitle'))
Check 'cancel button is hidden for mutating actions and offered for checks' ($controlPanelText.Contains("`$script:BtnWizCancel.Visibility = 'Collapsed'") -and $controlPanelText.Contains("`$script:BtnWizCancel.Visibility = 'Visible'"))
Check 'cancelling a finished run keeps its result' ($controlPanelText.Contains('WizardAsync.IsCompleted) { return }'))
Check 'wizard log renders colored lines in a rich box' ($controlPanelText.Contains('<RichTextBox x:Name="txtWizLog"') -and $controlPanelText.Contains('Choose-WizardLogColor') -and $controlPanelText.Contains('Clear-WizardLog'))
Check 'auto setup inserts and launches the winner itself' ($controlPanelText.Contains('Install-ZapretService -StrategyId $winnerId') -and $controlPanelText.Contains('Лучший вариант выбран и запущен'))
Check 'result step continues to hosts after the auto install' ($controlPanelText.Contains('WizardAutoInstalled'))
Check 'in-app instruction window is wired' ($controlPanelText.Contains('function Show-ControlHelp') -and $controlPanelText.Contains("FindName('btnHelp')") -and $controlPanelText.Contains('Быстрый старт'))
Check 'done step reports the truth after every wizard path' ($controlPanelText.Contains('function Complete-WizardDone') -and $controlPanelText.Contains('Complete-WizardDone; Set-WizardStep') -and $controlPanelText.Contains('установлена в автозапуск и запущена. Мастер можно запустить снова'))
Check 'winner fields are read through guarded lookups' ($controlPanelText.Contains('$winnerId = if ($Winner.PSObject.Properties') -and $controlPanelText.Contains('$startFailed = [bool]($Winner.PSObject.Properties'))
Check 'voice summary fields are read through guarded lookups' ($controlPanelText.Contains('$tcpOk = [bool]($Summary.PSObject.Properties') -and $controlPanelText.Contains('$conflictItems = @()'))
Check 'tables render through the shared log instead of a host' ((Get-Command Write-HostTable).ScriptBlock.ToString().Contains('Out-String') -and (Get-Command Invoke-LineQualityTest).ScriptBlock.ToString().Contains('Write-HostTable') -and (Get-Command Invoke-DnsBenchmark).ScriptBlock.ToString().Contains('Write-HostTable'))
Check 'dns benchmark can apply the fastest provider without a console prompt' ((Get-Command Invoke-DnsBenchmark).ScriptBlock.ToString().Contains('ApplyFastest') -and $controlPanelText.Contains('Invoke-DnsBenchmark -ApplyFastest'))
Check 'fakes list binds plain display names' ($controlPanelText.Contains('BaseName = [string]$_.BaseName'))
Check 'page state sections fail independently' ($controlPanelText.Contains('$rbText = ''копий пока нет'''))
Check 'wizard journal survives the result step' ($controlPanelText.IndexOf('<RichTextBox x:Name="txtWizLog"') -gt $controlPanelText.IndexOf('<Border x:Name="wizStepRun"') -and $controlPanelText.IndexOf('<RichTextBox x:Name="txtWizLog"') -lt $controlPanelText.IndexOf('<Border x:Name="wizStepResult"') -and $controlPanelText.Contains('$script:TxtWizLog.Visibility = if ($Step -in'))
Check 'action crash is reported as failure' ($controlPanelText.Contains('$script:WizardErrIndex++') -and $controlPanelText.Contains("Add-WizardLog ('[x] ' +"))
Check 'run step description adapts to the mode' ($controlPanelText.Contains('txtWizRunBody') -and $controlPanelText.Contains('результаты появятся в журнале ниже'))
Check 'starting a run refuses while another run is active' (([regex]::Matches($controlPanelText, 'if \(\$script:WizardBusy\) \{ return \}')).Count -ge 2)
$panelButtonNames = @()
foreach ($m in [regex]::Matches($controlPanelText, '<Button x:Name="(btn[A-Za-z0-9]+)"')) { $panelButtonNames += $m.Groups[1].Value }
$unboundButtons = @($panelButtonNames | Where-Object { -not $controlPanelText.Contains(("FindName('{0}').Add_Click" -f $_)) })
Check 'every panel button has an explicit click handler' ($panelButtonNames.Count -gt 30 -and $unboundButtons.Count -eq 0)
Check 'combo boxes use the dark themed template everywhere' ($controlPanelText.Contains('TargetType="ComboBox"') -and $controlPanelText.Contains('PART_Popup') -and $controlPanelText.Contains('TargetType="ComboBoxItem"'))
Check 'control panel asks once before creating the desktop shortcut' ($controlPanelText.Contains('control-shortcut.asked') -and $controlPanelText.Contains('btnCreateShortcut'))
Check 'auto-setup runs inside the panel instead of opening a console' ($controlPanelText.Contains('pageWizard') -and $controlPanelText.Contains('btnWizRegular') -and $controlPanelText.Contains('btnWizMts') -and $controlPanelText.Contains('Start-WizardBenchmark') -and $controlPanelText.Contains('Invoke-AutoSelect -NoInteractive'))
Check 'wizard installs the service only from an explicit consent button' ($controlPanelText.Contains('btnWizInstall') -and $controlPanelText.Contains('Install-ZapretService') -and $controlPanelText.Contains("Set-WizardStep -Step 'hosts'"))
Check 'wizard keeps default-no consent for hosts/IPSet and the weekly schedule' ($controlPanelText.Contains('btnWizHostsNo') -and $controlPanelText.Contains('btnWizSchedNo') -and $controlPanelText.Contains('Invoke-PostInstallConfiguration') -and $controlPanelText.Contains('Set-AutoSelectSchedule'))
Check 'wizard mirrors the fail-closed install gate of the console master' ($controlPanelText.Contains("Properties['CanInstall']") -and $controlPanelText.Contains('candidateUsable') -and $controlPanelText.Contains('AllServicesPassed'))
Check 'panel wires bypass check, watchdog toggle, tray and watchdog status text' ($controlPanelText.Contains('btnCheckBypass') -and $controlPanelText.Contains('btnWatchdogToggle') -and $controlPanelText.Contains('txtWatchdogState') -and $controlPanelText.Contains('btnTray') -and $controlPanelText.Contains('Update-WatchdogCard'))
Check 'panel wires the bypass profile card and the speed test button' ($controlPanelText.Contains('btnProfileApply') -and $controlPanelText.Contains('cmbProfile') -and $controlPanelText.Contains('txtProfileState') -and $controlPanelText.Contains('btnSpeedTest') -and $controlPanelText.Contains('Update-ProfileCard'))
Check 'panel wires the site check card and the tray autostart toggle' ($controlPanelText.Contains('btnSiteCheck') -and $controlPanelText.Contains('txtSiteCheckInput') -and $controlPanelText.Contains('btnTrayAutostart') -and $controlPanelText.Contains('Update-TrayAutostartCard'))
Check 'site route decision honors list precedence and subdomains' (& {
    $tempLists = Join-Path ([IO.Path]::GetTempPath()) ('zapret-route-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempLists -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $tempLists 'list-general.txt'), ("discord.com`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $tempLists 'list-exclude-user.txt'), ("cdn.blocked.example`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $a = Get-SiteRouteInfo -InputText 'https://canary.discord.com/app' -ListsDir $tempLists
        $b = Get-SiteRouteInfo -InputText 'deep.cdn.blocked.example' -ListsDir $tempLists
        $c = Get-SiteRouteInfo -InputText 'nowhere.example' -ListsDir $tempLists
        ($a.Route -eq 'bypass') -and ($a.MatchGeneral -eq 'discord.com') -and ($b.Route -eq 'excluded') -and ($b.MatchExclude -eq 'cdn.blocked.example') -and ($c.Route -eq 'not-listed')
    } finally {
        Remove-Item -LiteralPath $tempLists -Recurse -Force -ErrorAction SilentlyContinue
    }
})
Check 'site route decision treats the profile block as exclusion' (& {
    $tempLists = Join-Path ([IO.Path]::GetTempPath()) ('zapret-route2-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempLists -Force | Out-Null
        Set-BypassProfile -Profile 'discord-only' -ListsDir $tempLists | Out-Null
        $hit = Get-SiteRouteInfo -InputText 'www.youtube.com' -ListsDir $tempLists
        $free = Get-SiteRouteInfo -InputText 'discord.com' -ListsDir $tempLists
        ($hit.Route -eq 'excluded') -and $hit.ProfileExcluded -and ($free.Route -eq 'not-listed')
    } finally {
        Remove-Item -LiteralPath $tempLists -Recurse -Force -ErrorAction SilentlyContinue
    }
})
Check 'site check verdict never calls a small page a TCP freeze' (& {
    $small = Get-SiteCheckVerdict -ProbeOk $true -Transfer @{ Ok = $false; Bytes = 2048; Code = 200; CurlExitCode = 0 }
    $freeze = Get-SiteCheckVerdict -ProbeOk $true -Transfer @{ Ok = $false; Bytes = 20480; Code = 200; CurlExitCode = 18 }
    $ok = Get-SiteCheckVerdict -ProbeOk $true -Transfer @{ Ok = $true; Bytes = 65536; Code = 206; CurlExitCode = 0 }
    $dead = Get-SiteCheckVerdict -ProbeOk $false -Transfer $null
    (Get-SiteTransferState -ProbeOk $true -Transfer @{ Ok = $false; Bytes = 2048; Code = 200; CurlExitCode = 0 }) -eq 'small' -and (Get-SiteTransferState -ProbeOk $true -Transfer @{ Ok = $false; Bytes = 20480; Code = 200; CurlExitCode = 18 }) -eq 'freeze' -and $small.Contains('меньше 64') -and $freeze.Contains('типичный TCP-фриз') -and $ok.Contains('скачиваются') -and $dead.Contains('не отвечает')
})
$shippedPsFiles = @(
    (Join-Path $repoRoot 'zapret.ps1'),
    (Join-Path $repoRoot 'Zapret-Control.ps1'),
    (Join-Path $repoRoot 'Update-Zapret.ps1'),
    (Join-Path $repoRoot 'src\Zapret.psm1')
) + @(Get-ChildItem -Path (Join-Path $repoRoot 'src\parts') -Filter '*.ps1' | ForEach-Object { $_.FullName })
Check 'shipped PowerShell keeps Windows PowerShell 5.1 syntax compatibility' (& {
    $settings = @{
        IncludeRules = @('PSUseCompatibleSyntax')
        Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
    }
    $compatTotal = 0
    foreach ($f in $shippedPsFiles) {
        $hits = @(Invoke-ScriptAnalyzer -Path $f -Settings $settings -ErrorAction SilentlyContinue)
        $compatTotal += $hits.Count
    }
    $compatTotal -eq 0
})
Check 'every module part shipped by Build-Release is covered by the checks' (& {
    $buildText = [IO.File]::ReadAllText((Join-Path $repoRoot 'tools\Build-Release.ps1'))
    $shippedNames = @([regex]::Matches($buildText, "src/parts/[A-Za-z.]+\.ps1") | ForEach-Object { $_.Value } | Select-Object -Unique)
    $covered = @($shippedPsFiles | ForEach-Object { ([string]$_).Replace('\', '/') })
    # every Build-Release part must exist on disk and appear in the covered set
    $bad = @()
    foreach ($name in $shippedNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $name))) { $bad += ('missing on disk: ' + $name); continue }
        $leaf = Split-Path $name -Leaf
        if (-not (@($covered | Where-Object { $_ -like ('*' + $leaf) }).Count -gt 0)) { $bad += ('not covered: ' + $name) }
    }
    ($bad.Count -eq 0) -and ($shippedNames.Count -ge 13)
})
Check 'site check probe runs and reports a verdict' (& {
    $check = Invoke-SiteCheck -InputText 'invalid.invalid' -TimeoutSec 3
    ($check.Route -eq 'not-listed') -and (-not $check.ProbeOk) -and ($check.VerdictRu -ne '')
})
Check 'tray autostart module and CLI are wired' ((Get-Command Set-TrayAutostart).ScriptBlock.ToString().Contains('ZapretTray') -and ((Get-Command Get-TrayAutostartState).ScriptBlock.ToString() -match 'CurrentVersion.Run') -and $zapretPs1.Contains("'tray-autostart'") -and $zapretPs1.Contains("'site-check'"))
Check 'windivert failure detector covers observed code 177 and its family' ((Test-WinDivertDriverFailure -ExitCode 177 -StartError '') -and (Test-WinDivertDriverFailure -ExitCode 1072 -StartError '') -and (Test-WinDivertDriverFailure -ExitCode 654 -StartError '') -and (Test-WinDivertDriverFailure -ExitCode 1275 -StartError '') -and (-not (Test-WinDivertDriverFailure -ExitCode 1 -StartError 'unknown option')) -and (Test-WinDivertDriverFailure -ExitCode 0 -StartError 'windivert: error opening filter: x'))
Check 'win32 hint table names the driver startup failures' ((Get-Win32ErrorHint -Code 177) -ne '' -and (Get-Win32ErrorHint -Code 654) -ne '' -and (Get-Win32ErrorHint -Code 1072) -ne '' -and (Get-Win32ErrorHint -Code 1275) -ne '' -and (Get-Win32ErrorHint -Code 577) -ne '')
Check 'benchmark and manual start capture winws stderr for the real reason' ((Get-Command Invoke-BenchmarkStrategy).ScriptBlock.ToString().Contains('RedirectStandardError') -and (Get-Command Start-ZapretStrategy).ScriptBlock.ToString().Contains('RedirectStandardError') -and (Get-Command Start-ZapretManualRun).ScriptBlock.ToString().Contains('Read-WinwsRunOutput') -and (Get-Command Read-WinwsRunOutput).ScriptBlock.ToString().Contains('1200'))
Check 'windivert repair budget resets on every new scan' ((Get-Command Invoke-AutoSelect).ScriptBlock.ToString().Contains('WinDivertRepairAttempted = $false'))
Check 'winws launch falls back to the stock start when stream redirect is rejected' (([regex]::Matches((Get-Command Invoke-BenchmarkStrategy).ScriptBlock.ToString(), 'Start-Process')).Count -ge 2 -and ([regex]::Matches((Get-Command Start-ZapretStrategy).ScriptBlock.ToString(), 'Start-Process')).Count -ge 2)
Check 'windivert repair cleans both driver service names' ((Get-Command Repair-WinDivertService).ScriptBlock.ToString().Contains('WinDivert14') -and (Get-Command Repair-WinDivertService).ScriptBlock.ToString().Contains('WinDivert'))
# --- Discord voice repair ladder ---
$doctorGuiText = [IO.File]::ReadAllText((Join-Path $repoRoot 'Zapret-Control.ps1'))
Check 'voice fake picker cycles through the sorted list' ((Get-NextDiscordFakeName -Names @('b','a','c') -CurrentName 'a') -eq 'b' -and (Get-NextDiscordFakeName -Names @('b','a','c') -CurrentName 'c') -eq 'a')
Check 'voice fake picker starts at the first name for unknown current' ((Get-NextDiscordFakeName -Names @('b','a') -CurrentName '(custom)') -eq 'a')
Check 'voice fake picker returns null when there is nothing new to try' ((Get-NextDiscordFakeName -Names @() -CurrentName 'x') -eq $null -and (Get-NextDiscordFakeName -Names @('only') -CurrentName 'only') -eq $null)
$diagText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.Diagnostics.ps1'))
Check 'voice repair ladder restarts and cycles fakes' (($diagText.Contains('function Repair-DiscordVoice')) -and $diagText.Contains('Restart-ZapretBypassService') -and $diagText.Contains("'fixed-by-fake:{0}'"))
Check 'voice repair restores the original fake when nothing helps' ($diagText.Contains('фейк возвращён'))
$tmpFakePath = Join-Path ([IO.Path]::GetTempPath()) ('fake-active-{0}.bin' -f ([Guid]::NewGuid().ToString('N')))
try {
    [IO.File]::WriteAllBytes($tmpFakePath, [byte[]](1, 2, 3, 4, 5))
    $savedBytes = Backup-ActiveDiscordFake -ActivePath $tmpFakePath
    [IO.File]::WriteAllBytes($tmpFakePath, [byte[]](9, 9, 9))
    $restored = Restore-ActiveDiscordFake -Bytes $savedBytes -ActivePath $tmpFakePath
    $afterBytes = [IO.File]::ReadAllBytes($tmpFakePath)
    Check 'custom fake bytes survive the repair ladder' ($restored -and $afterBytes.Count -eq 5 -and $afterBytes[4] -eq 5)
    $noBytes = Backup-ActiveDiscordFake -ActivePath (Join-Path ([IO.Path]::GetTempPath()) ('missing-{0}.bin' -f ([Guid]::NewGuid().ToString('N'))))
    Check 'fake backup is null for a missing file and restore refuses it' (($null -eq $noBytes) -and ((Restore-ActiveDiscordFake -Bytes $null -ActivePath $tmpFakePath) -eq $false))
} finally {
    Remove-Item -LiteralPath $tmpFakePath -Force -ErrorAction SilentlyContinue
}
Check 'manual mode swaps one fake and says so honestly' (($diagText.Contains('fake-switched-manual')) -and $diagText.Contains('без перезапуска — службы нет'))
Check 'voice-check cli offers check fix and next-fake' (($zapretPs1.Contains("'voice-check' {")) -and $zapretPs1.Contains('Repair-DiscordVoice') -and $zapretPs1.Contains('next-fake'))
Check 'voice repair is wired in the GUI' (($doctorGuiText.Contains('btnVoiceNextFake')) -and $doctorGuiText.Contains('Complete-VoiceRepairResult') -and $doctorGuiText.Contains('Repair-DiscordVoice'))

# --- Config export/import package (export-config zip) ---
$watchdogText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.Watchdog.ps1'))
$doctorGuiText = [IO.File]::ReadAllText((Join-Path $repoRoot 'Zapret-Control.ps1'))
$tmpBase = Join-Path ([IO.Path]::GetTempPath()) ('cfgpkg-{0}' -f ([Guid]::NewGuid().ToString('N')))
try {
    $fixture = Join-Path $tmpBase 'src-install'
    New-Item -ItemType Directory -Path (Join-Path $fixture 'lists') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixture 'bin') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixture 'config.json') -Value '{"ports": {}}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fixture 'lists\list-general-user.txt') -Value 'example.com' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fixture 'bin\ACTIVE_DISCORD_UDP.bin') -Value 'fake' -Encoding UTF8
    $zipPath = Join-Path $tmpBase 'backup.zip'
    $exported = Export-ZapretConfig -Destination $zipPath -SourceRoot $fixture
    Check 'export-config packs the user file set with a manifest' (($exported.FileCount -eq 3) -and (Test-Path -LiteralPath $zipPath))
    $extract = Expand-ExternalConfigArchive -ArchivePath $zipPath
    Check 'export package extracts with its manifest' (Test-Path -LiteralPath (Join-Path $extract.Path 'export-manifest.json'))
    Check 'export manifest marks the folder as an import source' (Test-ExternalConfigSource -SourcePath $extract.Path)
    $importDst = Join-Path $tmpBase 'dst-install'
    New-Item -ItemType Directory -Path $importDst -Force | Out-Null
    $copyResult = Copy-ExternalConfigFiles -SourcePath $extract.Path -DestinationRoot $importDst
    Check 'import copies every exported file' (@($copyResult.Copied).Count -eq 3 -and (Test-Path -LiteralPath (Join-Path $importDst 'lists\list-general-user.txt')))
    Remove-Item -LiteralPath $extract.WorkDir -Recurse -Force -ErrorAction SilentlyContinue

    # zip-slip: запись с .. должна отклоняться
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $evilZip = Join-Path $tmpBase 'evil.zip'
    $evil = [IO.Compression.ZipFile]::Open($evilZip, 'Create')
    $badEntry = $evil.CreateEntry('../evil.txt')
    $sw = New-Object System.IO.StreamWriter($badEntry.Open()); $sw.Write('x'); $sw.Close()
    $evil.Dispose()
    $threw = $false
    try { [void](Expand-ExternalConfigArchive -ArchivePath $evilZip) } catch { $threw = $true }
    Check 'import rejects zip-slip traversal entries' $threw

    # архив, обёрнутый в одну папку, тоже принимается
    $wrapDir = Join-Path $tmpBase 'wrapped'
    New-Item -ItemType Directory -Path (Join-Path $wrapDir 'folder') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $wrapDir 'folder\export-manifest.json') -Value '{"Kind": "zapret-config-export"}' -Encoding UTF8
    $wrapZip = Join-Path $tmpBase 'wrapped.zip'
    Compress-Archive -Path (Join-Path $wrapDir 'folder') -DestinationPath $wrapZip
    $wrapExtract = Expand-ExternalConfigArchive -ArchivePath $wrapZip
    Check 'import accepts a single-folder wrapped archive' (Test-Path -LiteralPath (Join-Path $wrapExtract.Path 'export-manifest.json'))
    Remove-Item -LiteralPath $wrapExtract.WorkDir -Recurse -Force -ErrorAction SilentlyContinue
} finally {
    Remove-Item -LiteralPath $tmpBase -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'export-config cli verb is wired' (($zapretPs1.Contains("'export-config' {")) -and $zapretPs1.Contains('Export-ZapretConfig'))
Check 'export button is wired in the GUI' (($doctorGuiText.Contains('btnExportConfig')) -and $doctorGuiText.Contains('Export-ZapretConfig'))
Check 'watchdog notices cover fallback and heal outcomes' (([regex]::Matches($watchdogText, 'Write-WatchdogNotice')).Count -ge 4)
$trayC = [IO.File]::ReadAllText((Join-Path $repoRoot 'tools\tray\zapret-tray.c'))
Check 'tray shows the watchdog notice balloon once' (($trayC.Contains('watchdog-notice.txt')) -and $trayC.Contains('CheckNotice'))

# --- Strategy fallback ladder (watchdog quick failover) ---
$now = [datetime]::UtcNow
$ladderObj = [pscustomobject]@{ SavedAtUtc = $now.ToString('o', [Globalization.CultureInfo]::InvariantCulture); WinnerId = 'alt1'; Candidates = @('alt1','alt2','alt3') }
$staleLadder = [pscustomobject]@{ SavedAtUtc = $now.AddDays(-30).ToString('o', [Globalization.CultureInfo]::InvariantCulture); WinnerId = 'alt1'; Candidates = @('alt1','alt2') }
Check 'fallback plan skips the current strategy and returns the next candidate' ((Get-StrategyFallbackPlan -Ladder $ladderObj -CurrentId 'alt1' -TriedIds @()) -eq 'alt2')
Check 'fallback plan never repeats tried candidates' ((Get-StrategyFallbackPlan -Ladder $ladderObj -CurrentId 'alt1' -TriedIds @('alt2','alt3')) -eq $null)
Check 'fallback plan ignores a stale ladder and a missing ladder' ((Get-StrategyFallbackPlan -Ladder $staleLadder -CurrentId 'alt1') -eq $null -and (Get-StrategyFallbackPlan -Ladder $null -CurrentId 'alt1') -eq $null)
$watchdogText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.Watchdog.ps1'))
$tmpLadderPath = Join-Path ([IO.Path]::GetTempPath()) ('fallback-ladder-{0}.json' -f ([Guid]::NewGuid().ToString('N')))
try {
    [void](Save-StrategyFallbackLadder -CandidateIds @('alt9','alt8','alt9') -WinnerId 'alt9' -Path $tmpLadderPath)
    $loadedLadder = Get-StrategyFallbackLadder -Path $tmpLadderPath
    Check 'fallback ladder round-trips and deduplicates candidates' (($loadedLadder.WinnerId -eq 'alt9') -and @($loadedLadder.Candidates).Count -eq 2 -and [string]$loadedLadder.SavedAtUtc)
} finally {
    Remove-Item -LiteralPath $tmpLadderPath -Force -ErrorAction SilentlyContinue
}
Check 'auto-select saves the fallback ladder' $moduleText.Contains('Save-StrategyFallbackLadder -CandidateIds')
Check 'watchdog failover is wired before the deep benchmark' (($watchdogText.Contains('fallback:{0}')) -and $watchdogText.Contains('Get-StrategyFallbackPlan') -and $watchdogText.Contains('Get-StrategyFallbackEnabled'))
Check 'fallback cli verb is wired' (($zapretPs1.Contains("'fallback' {")) -and $zapretPs1.Contains('Get-StrategyFallbackStatusText'))
$watchdogTail = $watchdogText.Substring($watchdogText.LastIndexOf('Save-WatchdogState'))
Check 'watchdog final state save keeps the fallback tried list' ($watchdogTail.Contains('FallbackTried'))
Check 'runtime state files stay out of the package' (([IO.File]::ReadAllText((Join-Path $repoRoot '.gitignore'))).Contains('watchdog-state.json') -and ([IO.File]::ReadAllText((Join-Path $repoRoot '.gitignore'))).Contains('backup-strategies.json'))
$doctorFileText = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.Doctor.ps1'))
Check 'doctor file lock probe tolerates missing NTFS streams' ($doctorFileText.Contains('catch { $stream = $null }'))

# --- Installation doctor + native WinProbe driver probe ---
Check 'doctor inventory covers the shipped binaries' ((Get-DoctorCriticalFiles | Where-Object { $_.Path -eq 'winws.exe' }).Count -eq 1 -and (Get-DoctorCriticalFiles | Where-Object { $_.Path -eq 'WinDivert.dll' }).Count -eq 1 -and (Get-DoctorCriticalFiles | Where-Object { $_.Path -eq 'WinDivert64.sys' }).Count -eq 1)
$vpOk = @(Get-DoctorVersionProblems -VersionText '2.5.0' -RcText 'FILEVERSION 2,5,0' -InstructionText 'x 2.5.0 y')
$vpBad = @(Get-DoctorVersionProblems -VersionText '2.5.0' -RcText 'FILEVERSION 2,4,0' -InstructionText 'x 2.5.0 y')
$vpNone = @(Get-DoctorVersionProblems -VersionText $null -RcText $null -InstructionText $null)
Check 'doctor version check passes on consistent markers' ($vpOk.Count -eq 0)
Check 'doctor version check flags drift and missing files' ($vpBad.Count -ge 1 -and $vpNone.Count -ge 1)
Check 'doctor exit codes map fail to 2 and warn to 1' ((Convert-DoctorRowsToExitCode -Rows @([pscustomobject]@{Status='warn'},[pscustomobject]@{Status='ok'})) -eq 1 -and (Convert-DoctorRowsToExitCode -Rows @([pscustomobject]@{Status='ok'},[pscustomobject]@{Status='fail'})) -eq 2 -and (Convert-DoctorRowsToExitCode -Rows @([pscustomobject]@{Status='ok'},[pscustomobject]@{Status='skip'})) -eq 0)
$winprobeText = [IO.File]::ReadAllText((Join-Path $repoRoot 'tools\winprobe\winprobe.c'))
Check 'winprobe opens WinDivert once and reports the error code' (($winprobeText.Contains('WinDivertOpen')) -and ($winprobeText.Contains('return 1')) -and ($winprobeText.Contains('return 2')))
Check 'doctor cli verb is wired' (($zapretPs1.Contains("'doctor' {")) -and $zapretPs1.Contains('Invoke-ZapretDoctor'))
$doctorGuiText = [IO.File]::ReadAllText((Join-Path $repoRoot 'Zapret-Control.ps1'))
Check 'doctor buttons are wired in the GUI' (($doctorGuiText.Contains('btnDoctor')) -and $doctorGuiText.Contains('btnDoctorFix') -and $doctorGuiText.Contains('Invoke-ZapretDoctor'))

Check 'tray warns when the bypass breaks and celebrates recovery' ((Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw).Contains('Обход перестал работать') -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw).Contains('Обход снова работает') -and (Get-Content -LiteralPath (Join-Path $repoRoot 'tools/tray/zapret-tray.c') -Raw).Contains('NIF_INFO'))

# --- Security hygiene files ---
Check 'SECURITY.md present'                        (Test-Path (Join-Path $repoRoot 'SECURITY.md'))
Check 'dependabot.yml present'                      (Test-Path (Join-Path $repoRoot '.github\dependabot.yml'))

Write-Host ''
Write-Host '== Security hardening ==' -ForegroundColor Cyan

$secTmp = Join-Path ([IO.Path]::GetTempPath()) ('zapret-sec-test-{0}' -f [Guid]::NewGuid().ToString('N'))
try {
    $secLogs = Join-Path $secTmp 'logs'
    New-Item -ItemType Directory -Path $secLogs -Force | Out-Null

    # --- rollback snapshot path containment (poisoned config.json must not pass) ---
    $inside  = Join-Path $secLogs 'rollback-20261118-000000000'
    $outside = Join-Path $secTmp 'attacker-folder'
    New-Item -ItemType Directory -Path $inside -Force | Out-Null
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    Check 'containment: rollback-* inside logs accepted'      (Test-RollbackSnapshotPath -Folder $inside -LogDir $secLogs)
    Check 'containment: folder outside logs rejected'        (-not (Test-RollbackSnapshotPath -Folder $outside -LogDir $secLogs))
    Check 'containment: non-rollback child rejected'         (-not (Test-RollbackSnapshotPath -Folder (Join-Path $secLogs 'evil') -LogDir $secLogs))
    $nested = Join-Path $secLogs 'sub\rollback-20261118-000000'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Check 'containment: nested rollback-* rejected'          (-not (Test-RollbackSnapshotPath -Folder $nested -LogDir $secLogs))

    $poisonIpset  = Join-Path $secTmp 'target-ipset.txt'
    $poisonHosts  = Join-Path $secTmp 'target-hosts'
    $poisonCfg    = Join-Path $secTmp 'config.json'
    [IO.File]::WriteAllText($poisonIpset, "9.9.9.9/32`r`n")
    [IO.File]::WriteAllText($poisonHosts, "# hosts original`r`n")
    [IO.File]::WriteAllText((Join-Path $outside 'ipset-all.txt'), "6.6.6.6/32`r`n")
    [IO.File]::WriteAllText((Join-Path $outside 'hosts'), "6.6.6.6 attacker.example.com`r`n")
    $poisonJson = '{"version":1,"checkUpdates":true,"gameFilter":{"mode":"disabled","tcp":"1024-65535","udp":"1024-65535"},"rollback":{"reason":"ipset","time":"2026-11-18T00:00:00","strategy":null,"folder":"' + $outside.Replace('\','\\') + '","ipset":true,"hosts":true}}'
    [IO.File]::WriteAllText($poisonCfg, $poisonJson, (New-Object System.Text.UTF8Encoding($false)))
    $poisonOk = Restore-RollbackSnapshot -LogDir $secLogs -IpsetFile $poisonIpset -HostsPath $poisonHosts -ConfigPath $poisonCfg -ReinstallService:$false
    Check 'containment: poisoned rollback pointer refused'   ($poisonOk -eq $false)
    Check 'containment: ipset file untouched'                (([IO.File]::ReadAllText($poisonIpset)).Contains('9.9.9.9'))
    Check 'containment: hosts file untouched'                (([IO.File]::ReadAllText($poisonHosts)).Contains('hosts original'))
    Check 'containment: poisoned pointer cleared'            ($null -eq (Get-Config -Path $poisonCfg).rollback)

    # --- rollback meta control-character scrub on read ---
    $scrubCfg = Join-Path $secTmp 'config-scrub.json'
    $scrubReason = 'evil' + [char]7 + [char]27 + 'x'
    $scrubJson = '{"version":1,"checkUpdates":true,"gameFilter":{"mode":"disabled","tcp":"1024-65535","udp":"1024-65535"},"rollback":{"reason":"' + $scrubReason + '","time":"t","strategy":"a' + [char]7 + 'b","folder":"' + $inside.Replace('\','\\') + '","ipset":false,"hosts":false}}'
    [IO.File]::WriteAllText($scrubCfg, $scrubJson, (New-Object System.Text.UTF8Encoding($false)))
    $scrubbed = Get-Config -Path $scrubCfg
    Check 'rollback meta: control chars stripped from reason'    ($scrubbed.rollback.reason -eq 'evilx')
    Check 'rollback meta: control chars stripped from strategy'  ($scrubbed.rollback.strategy -eq 'ab')

    # --- hosts fragment validation ---
    $goodFragment = @('# comment', '', '127.0.0.1 discord.com', '::1 localhost', '203.0.113.10 example.com www.example.com # note') -join "`r`n"
    Check 'hosts fragment: valid fragment passes'        ((@(Test-HostsFragment -Content $goodFragment)).Count -eq 0)
    Check 'hosts fragment: bad IPv4 octets rejected'     ((@(Test-HostsFragment -Content "999.999.1.1 discord.com")).Count -gt 0)
    Check 'hosts fragment: script line rejected'         ((@(Test-HostsFragment -Content "cmd.exe /c whoami")).Count -gt 0)
    Check 'hosts fragment: address without name rejected'((@(Test-HostsFragment -Content "127.0.0.1")).Count -gt 0)
    Check 'hosts fragment: bad hostname rejected'        ((@(Test-HostsFragment -Content "127.0.0.1 bad;host!")).Count -gt 0)
    Check 'hosts fragment: comments-only rejected'       ((@(Test-HostsFragment -Content "# nothing`r`n# here")).Count -gt 0)
    Check 'hosts fragment: empty rejected'               ((@(Test-HostsFragment -Content '')).Count -gt 0)
    $tooMany = (1..5100 | ForEach-Object { "10.0.$([int]($_ % 256)).$([int]($_ % 250) + 1) host$_.example.com" }) -join "`r`n"
    Check 'hosts fragment: oversized line count rejected'((@(Test-HostsFragment -Content $tooMany)).Count -gt 0)

    # --- hosts managed-block merge helper ---
    $beginMarker = '# >>> zapret-discord-youtube (managed) >>>'
    $endMarker   = '# <<< zapret-discord-youtube (managed) <<<'
    $block = $beginMarker + "`r`n" + '127.0.0.1 example.com' + "`r`n" + $endMarker
    $merged = Get-UpdatedHostsContent -Current "# my hosts`r`n" -Block $block
    Check 'hosts merge: fresh install appends block'    ($merged.Action -eq 'install' -and $merged.Content.Contains($beginMarker) -and $merged.Content.Contains('# my hosts'))
    $replaced = Get-UpdatedHostsContent -Current $merged.Content -Block $block
    Check 'hosts merge: existing block replaced'        ($replaced.Action -eq 'replace' -and $replaced.Content -eq $merged.Content)
    $unbalanced = "# hosts`r`n$beginMarker`r`n127.0.0.1 example.com`r`n"
    $threw = $false
    try { [void](Get-UpdatedHostsContent -Current $unbalanced -Block $block) } catch { $threw = $true }
    Check 'hosts merge: unbalanced begin marker throws' ($threw -eq $true)
    $threw = $false
    try { [void](Get-UpdatedHostsContent -Current "# hosts`r`n$endMarker`r`n" -Block $block) } catch { $threw = $true }
    Check 'hosts merge: stray end marker throws'        ($threw -eq $true)

    # --- hosts removal refuses unbalanced markers instead of deleting to EOF ---
    $hostsFile = Join-Path $secTmp 'hosts-unbalanced'
    $original = "# my hosts`r`n$beginMarker`r`n127.0.0.1 example.com`r`n8.8.8.8 keep.example.com`r`n"
    [IO.File]::WriteAllText($hostsFile, $original)
    $removed = Remove-HostsManagedBlock -HostsPath $hostsFile
    Check 'hosts removal: refuses unbalanced markers'   ($removed -eq $false)
    Check 'hosts removal: nothing deleted'              (([IO.File]::ReadAllText($hostsFile)) -eq $original)
    $balancedFile = Join-Path $secTmp 'hosts-balanced'
    [IO.File]::WriteAllText($balancedFile, "# my hosts`r`n" + $block + "`r`n8.8.8.8 keep.example.com`r`n")
    [void](Remove-HostsManagedBlock -HostsPath $balancedFile)
    $balancedNow = [IO.File]::ReadAllText($balancedFile)
    Check 'hosts removal: balanced block removed'       ((-not $balancedNow.Contains($beginMarker)) -and $balancedNow.Contains('keep.example.com') -and $balancedNow.Contains('# my hosts'))

    # --- expanded strategy args must pass the structural gate ---
    $threw = $false
    try { [void](Expand-StrategyArgs -Template '--wf-tcp=80 "unbalanced' -GameTcp '12' -GameUdp '12') } catch { $threw = $true }
    Check 'args gate: unbalanced quotes rejected'       ($threw -eq $true)
    $threw = $false
    try { [void](Expand-StrategyArgs -Template '--wf-tcp=80 %PATH%' -GameTcp '12' -GameUdp '12') } catch { $threw = $true }
    Check 'args gate: batch artifacts rejected'         ($threw -eq $true)
    $threw = $false
    try { [void](Expand-StrategyArgs -Template '--filter-tcp=80' -GameTcp '12' -GameUdp '12') } catch { $threw = $true }
    Check 'args gate: args must start with --wf-tcp='   ($threw -eq $true)
    $threw = $false
    try { [void](Expand-StrategyArgs -Template '--wf-tcp=80' -GameTcp '12' -GameUdp '12'); $threw = $false } catch { $threw = $true }
    Check 'args gate: minimal valid template accepted'  ($threw -eq $false)
    Check 'args gate: shell metacharacters rejected'      (@(Test-StrategyArgs -Expanded '--wf-tcp=80;Write-Host x' -Template).Count -gt 0)
    Check 'args gate: unsupported command option rejected'(@(Test-StrategyArgs -Expanded '--wf-tcp=80 --evil=whoami' -Template).Count -gt 0)
    Check 'args gate: external paths rejected'            (@(Test-StrategyArgs -Expanded '--wf-tcp=80 --hostlist="C:\Windows\win.ini"' -Template).Count -gt 0)
} finally {
    Remove-Item -LiteralPath $secTmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '== Same-folder updater ==' -ForegroundColor Cyan

# --- полная остановка обхода и конфликтующие VPN/прокси-клиенты (Happ/Xray/Clash) ---
$fullStopGuard = $false
& (Get-Module -Name Zapret) { $script:__savedOnWindows = $script:OnWindows; $script:OnWindows = $false }
try { [void](Stop-ZapretServiceRobust) } catch { $fullStopGuard = ($_.Exception.Message -match 'Windows') }
& (Get-Module -Name Zapret) { $script:OnWindows = $script:__savedOnWindows }
Check 'full stop exists and refuses non-Windows hosts' $fullStopGuard
$strategiesTextAll = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.Strategies.ps1'))
Check 'full stop falls back to killing winws when the service ignores stop' ($strategiesTextAll -match 'function Stop-ZapretServiceRobust' -and $strategiesTextAll -match "Stop-Service -Name 'zapret'" -and $strategiesTextAll -match 'Wait-ZapretServiceState' -and $strategiesTextAll -match 'Stop-ZapretOwnedDrivers')
Check 'removing the installation also removes the watchdog scheduled task' ($strategiesTextAll -match 'Test-WatchdogSchedule' -and $strategiesTextAll -match 'WatchdogTaskName')
$controlTextAll = [IO.File]::ReadAllText((Join-Path $repoRoot 'Zapret-Control.ps1'))
Check 'GUI stop button performs the full stop and reports what was stopped' ($controlTextAll -match 'Stop-ZapretServiceRobust' -and $controlTextAll -match 'OwnProcessesStopped')
Check 'GUI enables Stop for this install manual winws but never for foreign ones' ($controlTextAll -match 'BtnStopService.IsEnabled = \[bool\]\$ownRun' -and $controlTextAll -match 'не останавливает чужие процессы')
$autoSelectTextAll = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.AutoSelect.ps1'))
$noopPattern = '.Replace(' + [char]39 + [char]34 + [char]39 + ', ' + [char]39 + [char]34 + [char]39 + ')'
Check 'update version compare: letter build ranks after base' ((Compare-ZapretUpdateVersions -Left '2.8.1a' -Right '2.8.1') -eq 1)
Check 'update version compare: base below letter build' ((Compare-ZapretUpdateVersions -Left '2.8.1' -Right '2.8.1a') -eq -1)
Check 'update version compare: newer patch beats letter build' ((Compare-ZapretUpdateVersions -Left '2.8.2' -Right '2.8.1a') -eq 1)
Check 'update version compare: equal versions' ((Compare-ZapretUpdateVersions -Left '2.8.5' -Right '2.8.5') -eq 0)
Check 'update version compare: equal letter versions' ((Compare-ZapretUpdateVersions -Left '2.8.1a' -Right '2.8.1a') -eq 0)
Check 'update version compare: garbage is null' ($null -eq (Compare-ZapretUpdateVersions -Left 'нет' -Right '2.8.5'))

$goodManifestRaw = [pscustomobject]@{
    version = '2.9.1'; published = '2026-11-20'
    zipUrl  = 'https://example.com/zapret-discord-youtube-2.9.1.zip'
    sha256  = ('a' * 64); minVersion = '2.6.0'
    notes   = @('Исправлено: то', "строка`nс контролем", '')
}
$goodManifest = ConvertTo-ZapretUpdateManifest -Raw $goodManifestRaw
Check 'update manifest: valid payload passes' ($goodManifest.Ok -and $goodManifest.Manifest.Version -eq '2.9.1' -and $goodManifest.Manifest.Sha256 -eq ('A' * 64))
Check 'update manifest: notes lose control chars and empty lines' ($goodManifest.Manifest.Notes.Count -eq 2)
Check 'update manifest: bad sha256 rejected' (-not (ConvertTo-ZapretUpdateManifest -Raw ([pscustomobject]@{ version = '2.9.1'; zipUrl = 'https://e.com/a.zip'; sha256 = 'xyz' })).Ok)
Check 'update manifest: missing zipUrl rejected' (-not (ConvertTo-ZapretUpdateManifest -Raw ([pscustomobject]@{ version = '2.9.1'; sha256 = ('a' * 64) })).Ok)
Check 'update manifest: bad version rejected' (-not (ConvertTo-ZapretUpdateManifest -Raw ([pscustomobject]@{ version = 'vNext'; zipUrl = 'https://e.com/a.zip'; sha256 = ('a' * 64) })).Ok)
Check 'update manifest: bad minVersion rejected' (-not (ConvertTo-ZapretUpdateManifest -Raw ([pscustomobject]@{ version = '2.9.1'; zipUrl = 'https://e.com/a.zip'; sha256 = ('a' * 64); minVersion = '2' })).Ok)
Check 'update manifest: null payload rejected' (-not (ConvertTo-ZapretUpdateManifest -Raw $null).Ok)
Check 'update manifest: javascript: url rejected' (-not (ConvertTo-ZapretUpdateManifest -Raw ([pscustomobject]@{ version = '2.9.1'; zipUrl = 'javascript:alert(1)'; sha256 = ('a' * 64) })).Ok)

[void](Update-Config @{ updateFeed = $null; autoInstallUpdates = $false })
$repoManifestText = [IO.File]::ReadAllText((Join-Path $repoRoot 'update-manifest.json'))
$repoManifestCheck = ConvertTo-ZapretUpdateManifest -Raw ($repoManifestText | ConvertFrom-Json)
Check 'repo update-manifest.json is valid' ($repoManifestCheck.Ok -and $repoManifestCheck.Manifest.Sha256 -match '^[A-F0-9]{64}$')
Check 'repo update-manifest version tracks version.txt' ($repoManifestCheck.Manifest.Version -eq ([IO.File]::ReadAllText((Join-Path $repoRoot '.service\version.txt'))).Trim())
Check 'update offer without feed is honest about configuration' (-not (Get-ZapretUpdateOffer).Configured -and (Get-ZapretUpdateOffer).Error -match 'updateFeed')
$defaultsProbePath = Join-Path ([IO.Path]::GetTempPath()) ('zapret-defaults-' + [Guid]::NewGuid().ToString('N') + '.json')
$defaultsProbe = Get-Config -Path $defaultsProbePath
Check 'update config: default feed points at the NewZapret repo, auto-install off' ($defaultsProbe.updateFeed -eq 'https://raw.githubusercontent.com/Orlovsky1504/NewZapret-beta-/main/update-manifest.json' -and -not $defaultsProbe.autoInstallUpdates)
Remove-Item -LiteralPath $defaultsProbePath -Force -ErrorAction SilentlyContinue
[void](Update-Config @{ updateFeed = 'https://example.com/update-manifest.json'; autoInstallUpdates = $true })
Check 'update config: feed and auto-install round-trip' ((Get-Config).updateFeed -eq 'https://example.com/update-manifest.json' -and (Get-Config).autoInstallUpdates -eq $true)
[void](Update-Config @{ updateFeed = $null; autoInstallUpdates = $false })

$manifestFile = Join-Path ([IO.Path]::GetTempPath()) ('update-manifest-test-' + [Guid]::NewGuid().ToString('N') + '.json')
$manifestText = '{ "version": "2.9.1", "zipUrl": "https://example.com/z.zip", "sha256": "' + ('b' * 64) + '", "notes": ["x"] }'
[IO.File]::WriteAllText($manifestFile, $manifestText)
$fileFeed = 'file://' + ($manifestFile -replace '\\', '/')
$manifestFromFeed = Get-ZapretUpdateManifest -Url $fileFeed
Check 'update manifest: file feed downloads and validates' ($manifestFromFeed.Ok -and $manifestFromFeed.Manifest.Version -eq '2.9.1')
Remove-Item -LiteralPath $manifestFile -Force -ErrorAction SilentlyContinue

& (Get-Module -Name Zapret) { $script:__savedOnWindows = $script:OnWindows; $script:OnWindows = $false }
$winOnlyInstall = Install-ZapretUpdate -Manifest $goodManifest.Manifest
& (Get-Module -Name Zapret) { $script:OnWindows = $script:__savedOnWindows }
Check 'update install: refuses to run outside Windows' (-not $winOnlyInstall.Ok -and $winOnlyInstall.Error -match 'Windows')

$updaterTextAll = [IO.File]::ReadAllText((Join-Path $repoRoot 'Update-Zapret.ps1'))
Check 'updater supports -AssumeYes end to end' ($updaterTextAll -match '\[switch\]\$AssumeYes' -and $updaterTextAll -match '\$assumeArgument' -and $updaterTextAll -match 'автоматический режим не пропускает проверку')
Check 'updater auto mode still demands a verified checksum' ($updaterTextAll -match 'контрольная сумма ZIP не подтверждена файлом SHA256SUMS')

$controlTextAll = [IO.File]::ReadAllText((Join-Path $repoRoot 'Zapret-Control.ps1'))
Check 'gui wires auto-install toggle handler' ($controlTextAll -match "FindName\('btnToggleAutoInstall'\)\.Add_Click")
Check 'gui check-updates button runs the update probe with dialogs' ($controlTextAll -match "btnCheckUpdates'\)\.Add_Click\(\{\s*Start-UpdateOfferProbe -ShowDialog")
Check 'gui auto-install passes the manifest without closures' ($controlTextAll -match 'ArgumentList @\(\$Offer\.Manifest\)')

# --- Wave 6 fixes (2.9.1) ---
$spacePathManifest = ConvertTo-ZapretUpdateManifest -Raw ([pscustomobject]@{ version = '2.9.1'; zipUrl = 'C:\My Folder\z.zip'; sha256 = ('a' * 64) })
Check 'update manifest: zip paths keep their spaces' ($spacePathManifest.Ok -and $spacePathManifest.Manifest.ZipUrl -eq 'C:\My Folder\z.zip')

$feedManifestFile = Join-Path ([IO.Path]::GetTempPath()) ('update-manifest-test-' + [Guid]::NewGuid().ToString('N') + '.json')
$writeFeed = { param($Version, $Min)
    $json = '{ "version": "' + $Version + '", "zipUrl": "https://e.com/z.zip", "sha256": "' + ('c' * 64) + '"'
    if ($Min) { $json += ', "minVersion": "' + $Min + '"' }
    $json += ' }'
    [IO.File]::WriteAllText($feedManifestFile, $json)
    [void](Update-Config @{ updateFeed = ('file://' + ($feedManifestFile -replace '\\', '/')) })
}
& $writeFeed '9.9.9' '9.0.0'
$tooNew = Get-ZapretUpdateOffer
Check 'update offer: minVersion above installed blocks the offer with a reason' (-not $tooNew.UpdateAvailable -and $tooNew.Error -match 'не ниже')
& $writeFeed '9.9.9' $null
$plainOffer = Get-ZapretUpdateOffer
Check 'update offer: newer feed version is offered' ($plainOffer.UpdateAvailable -and $plainOffer.Remote -eq '9.9.9')
& $writeFeed (Get-LocalVersion) '9.0.0'
$noUpdateMin = Get-ZapretUpdateOffer
Check 'update offer: minVersion is silent when there is no update at all' (-not $noUpdateMin.UpdateAvailable -and -not $noUpdateMin.Error)
[void](Update-Config @{ updateFeed = $null; autoInstallUpdates = $false })
Remove-Item -LiteralPath $feedManifestFile -Force -ErrorAction SilentlyContinue

$ipsetTextAll = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\parts\Zapret.IpsetHosts.ps1'))
Check 'update install writes SHA256SUMS.txt next to the downloaded ZIP' ($ipsetTextAll -match 'SHA256SUMS\.txt' -and $ipsetTextAll -match 'WriteAllText\(\$sumsPath')
Check 'update install uses a private work dir, not shared TEMP' ($ipsetTextAll -match "zapret_update_' \+ \[Guid\]::NewGuid" -and $ipsetTextAll -match 'Remove-Item -LiteralPath \$workDir -Recurse')
Check 'update install keeps TargetRoot quoting intact on drive roots' ($ipsetTextAll -match 'rootArg -match')

$zapretTextAll = [IO.File]::ReadAllText((Join-Path $repoRoot 'zapret.ps1'))
Check 'check-updates and update-install no longer demand elevation up front' ($zapretTextAll.Contains("'check-updates' { `$needsAdmin = `$false }") -and $zapretTextAll.Contains("'update-install' { `$needsAdmin = `$false }"))

$controlTextAll2 = [IO.File]::ReadAllText((Join-Path $repoRoot 'Zapret-Control.ps1'))
Check 'update probe gives immediate feedback on the check button' ($controlTextAll2 -match 'Проверяю обновления')

Check 'probe batch has no no-op quote Replace left'   (-not $autoSelectTextAll.Contains($noopPattern))
$batchGuard = $null
try { $batchGuard = @(Invoke-UrlProbeBatch -Items @(@{ Url = ('http://example.com/' + [char]34 + 'evil') })) } catch { }
Check 'probe batch rejects an unsafe URL before launching curl' ($batchGuard -and $batchGuard.Count -eq 1 -and [string]$batchGuard[0].Reason -eq 'url contains unsafe characters')
Check 'strategy editor Done button really exits the editor loop' ($zapretPs1 -match 'break editorLoop' -and $zapretPs1 -match ':editorLoop while')
Check 'conflict detector covers modern proxy clients (Happ, Xray, sing-box, Clash, Hysteria)' ((Get-ZapretConflictServicePattern) -match 'happ' -and (Get-ZapretConflictServicePattern) -match 'xray' -and (Get-ZapretConflictProcessPattern) -match 'sing-box' -and (Get-ZapretConflictProcessPattern) -match 'clash' -and (Get-ZapretConflictProcessPattern) -match 'hysteria')
Check 'conflict process pattern is anchored to whole names (no substring hits)' ((Get-ZapretConflictProcessPattern) -match '\^\(' -and (Get-ZapretConflictProcessPattern) -match '\)\$')

$updaterScriptPath = Join-Path $repoRoot 'Update-Zapret.ps1'
$updaterLauncherPath = Join-Path $repoRoot 'Update-Zapret.bat'
Check 'same-folder updater script and launcher are present' ((Test-Path -LiteralPath $updaterScriptPath -PathType Leaf) -and (Test-Path -LiteralPath $updaterLauncherPath -PathType Leaf))
$updaterParseTokens = $null; $updaterParseErrors = $null
if (Test-Path -LiteralPath $updaterScriptPath -PathType Leaf) {
    [System.Management.Automation.Language.Parser]::ParseFile($updaterScriptPath, [ref]$updaterParseTokens, [ref]$updaterParseErrors) | Out-Null
}
$updaterParseOk = ((Test-Path -LiteralPath $updaterScriptPath -PathType Leaf) -and (($null -eq $updaterParseErrors) -or ($updaterParseErrors.Count -eq 0)))
Check 'updater parses as PowerShell 5.1-compatible syntax' $updaterParseOk
$updaterLoaded = $false
if ($updaterParseOk) {
    try { . $updaterScriptPath -NoRun; $updaterLoaded = $true }
    catch { Write-Host ("         updater load error: {0}" -f $_.Exception.Message) -ForegroundColor DarkRed }
}
Check 'updater helper functions load without starting the interactive workflow' $updaterLoaded

if ($updaterLoaded) {
    $updaterWindowsOnlyGuard = $true
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        $updaterWindowsOnlyGuard = $false
        try { [void](Invoke-ZapretUpdate -NoPause) } catch { $updaterWindowsOnlyGuard = ($_.Exception.Message -like '*только в Windows*') }
    }
    Check 'updater refuses to run on non-Windows hosts' $updaterWindowsOnlyGuard
    Check 'updater recognizes increasing versions' ((Compare-ZapretVersions -Left '2.1.8' -Right '2.1.7') -gt 0)
    Check 'updater understands the letter suffix (2.8.1a is newer than 2.8.1)' ((Compare-ZapretVersions -Left '2.8.1a' -Right '2.8.1') -gt 0 -and (Compare-ZapretVersions -Left '2.8.2' -Right '2.8.1a') -gt 0 -and ((Get-ZapretVersionParts -Version '2.8.1a').Build -eq 'a'))
    Check 'updater orders stable above prerelease' ((Compare-ZapretVersions -Left '2.1.7' -Right '2.1.7-rc1') -gt 0)
    Check 'updater accepts letter-suffix release folder names' ((Get-ZapretArchiveRootVersion -RootName 'zapret-discord-youtube-2.8.1a') -eq '2.8.1a' -and (Get-ZapretArchiveRootVersion -RootName 'zapret-discord-youtube-2.8.2') -eq '2.8.2' -and (Get-ZapretArchiveRootVersion -RootName 'zapret-discord-youtube-2.8.1-rc1') -eq '2.8.1-rc1' -and $null -eq (Get-ZapretArchiveRootVersion -RootName 'zapret-evil-1.2.3'))
    $updaterScriptText = [IO.File]::ReadAllText($updaterScriptPath)
    $psm1Parts = @([regex]::Matches(([IO.File]::ReadAllText((Join-Path $repoRoot 'src\Zapret.psm1'))), "'(Zapret\.[A-Za-z]+\.ps1)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $missingInUpdater = @($psm1Parts | Where-Object { $updaterScriptText -notmatch [regex]::Escape($_) })
    Check 'updater required-files list covers every module part (no drift with Zapret.psm1)' ($missingInUpdater.Count -eq 0)
    $badVersionRejected = $false
    try { [void](Get-ZapretVersionParts -Version '2.1') } catch { $badVersionRejected = $true }
    Check 'updater rejects malformed versions' $badVersionRejected
    Check 'archive path validator accepts safe release paths' (Test-ZapretSafeArchivePath -EntryName 'zapret-discord-youtube-2.1.8/lists/список.txt')
    Check 'archive path validator rejects traversal, absolute paths, and backslashes' ((-not (Test-ZapretSafeArchivePath -EntryName 'release/../escape')) -and (-not (Test-ZapretSafeArchivePath -EntryName '/absolute/file')) -and (-not (Test-ZapretSafeArchivePath -EntryName 'release\\file')))
    Check 'updater preservation policy distinguishes user state from package files' ((Get-ZapretPreserveMode -RelativePath 'config.json') -eq 'Always' -and (Get-ZapretPreserveMode -RelativePath 'strategies-user.json') -eq 'Always' -and (Get-ZapretPreserveMode -RelativePath 'logs/run.txt') -eq 'Always' -and (Get-ZapretPreserveMode -RelativePath 'lists/list-general-user.txt') -eq 'Always' -and (Get-ZapretPreserveMode -RelativePath 'lists/ipset-all.txt') -eq 'IfExists' -and (Get-ZapretPreserveMode -RelativePath 'bin/ACTIVE_GAME_UDP.bin') -eq 'IfExists' -and (Get-ZapretPreserveMode -RelativePath 'strategies.json') -eq '')

    $updateTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('zapret updater tests with spaces {0}' -f [Guid]::NewGuid().ToString('N'))
    try {
        $sourceRoot = Join-Path $updateTestRoot 'release files'
        $targetRoot = Join-Path $updateTestRoot 'installed zapret'
        $workRoot = Join-Path $updateTestRoot 'transaction work'
        $rollbackSource = Join-Path $updateTestRoot 'rollback release'
        $rollbackTarget = Join-Path $updateTestRoot 'rollback install'
        $rollbackWork = Join-Path $updateTestRoot 'rollback work'
        foreach ($directory in @($sourceRoot,$targetRoot,$workRoot,$rollbackSource,$rollbackTarget,$rollbackWork)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $newValues = @{
            'zapret.ps1' = 'new main script'
            '.service/version.txt' = '2.1.8'
            'strategies.json' = 'new built-in strategies'
            'bin/winws.exe' = 'new executable bytes'
            'bin/WinDivert64.sys' = 'new driver bytes'
            'bin/ACTIVE_GAME_UDP.bin' = 'release default fake'
            'config.json' = 'release must not overwrite config'
            'strategies-user.json' = 'release must not overwrite custom strategies'
            'lists/list-general-user.txt' = 'release must not overwrite user domains'
            'lists/ipset-all.txt' = 'release default IP set'
            'logs/auto-select.txt' = 'release must not overwrite logs'
            'utils/game_filter.enabled' = 'release default marker'
        }
        foreach ($relative in $newValues.Keys) {
            $path = Join-Path $sourceRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $parent = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllText($path, [string]$newValues[$relative])
        }
        $oldValues = @{
            '.service/version.txt' = '2.1.7'
            'strategies.json' = 'old built-in strategies'
            'bin/winws.exe' = 'old executable bytes'
            'bin/WinDivert64.sys' = 'old driver bytes'
            'bin/ACTIVE_GAME_UDP.bin' = 'user-selected fake'
            'config.json' = 'user config'
            'strategies-user.json' = 'user custom strategies'
            'lists/list-general-user.txt' = 'user domains'
            'lists/ipset-all.txt' = 'user IP set'
            'logs/auto-select.txt' = 'user log'
            'utils/game_filter.enabled' = 'user marker'
        }
        foreach ($relative in $oldValues.Keys) {
            $path = Join-Path $targetRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $parent = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllText($path, [string]$oldValues[$relative])
        }

        $updatePlan = @(Get-ZapretUpdateFilePlan -SourceRoot $sourceRoot -TargetRoot $targetRoot)
        $updatePlanPaths = @($updatePlan | ForEach-Object { $_.RelativePath })
        $mustPreserve = @('config.json','strategies-user.json','lists/list-general-user.txt','lists/ipset-all.txt','logs/auto-select.txt','utils/game_filter.enabled','bin/ACTIVE_GAME_UDP.bin')
        $mustUpdate = @('.service/version.txt','strategies.json','bin/winws.exe','bin/WinDivert64.sys')
        Check 'update plan excludes existing user settings, lists, logs, and active fakes' (@($mustPreserve | Where-Object { $_ -in $updatePlanPaths }).Count -eq 0)
        Check 'update plan includes version, strategy data, winws, and WinDivert' (@($mustUpdate | Where-Object { $_ -notin $updatePlanPaths }).Count -eq 0)
        $preflightPassed = $false
        try { Test-ZapretUpdatePreflight -Files $updatePlan; $preflightPassed = $true }
        catch { Write-Host ("         preflight error: {0}" -f $_.Exception.Message) -ForegroundColor DarkRed }
        Check 'update preflight verifies writable files and can rename the driver probe' $preflightPassed
        $transactionResult = $null
        try { $transactionResult = Invoke-ZapretFileTransaction -Files $updatePlan -WorkRoot $workRoot }
        catch { Write-Host ("         transaction error: {0}" -f $_.Exception.Message) -ForegroundColor DarkRed }
        Check 'same-folder transaction replaces package files and verifies hashes' ($null -ne $transactionResult -and $transactionResult.Succeeded)
        $newPayloadsCorrect = $false
        $userStatePreserved = $false
        if ($transactionResult -and $transactionResult.Succeeded) {
            $newPayloadsCorrect = ([IO.File]::ReadAllText((Join-Path $targetRoot 'strategies.json')) -eq $newValues['strategies.json'] -and [IO.File]::ReadAllText((Join-Path $targetRoot '.service/version.txt')) -eq $newValues['.service/version.txt'] -and [IO.File]::ReadAllText((Join-Path $targetRoot 'bin/winws.exe')) -eq $newValues['bin/winws.exe'] -and [IO.File]::ReadAllText((Join-Path $targetRoot 'bin/WinDivert64.sys')) -eq $newValues['bin/WinDivert64.sys'])
            $userStatePreserved = $true
            foreach ($relative in $mustPreserve) {
                $path = Join-Path $targetRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
                if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [IO.File]::ReadAllText($path) -ne $oldValues[$relative]) { $userStatePreserved = $false }
            }
        }
        Check 'transaction installs new package payloads in place' $newPayloadsCorrect
        Check 'transaction retains user config, custom strategies, lists, logs, and fakes' $userStatePreserved

        $targetBin = Join-Path $targetRoot 'bin'
        $foreignBin = Join-Path $updateTestRoot 'other driver folder'
        New-Item -ItemType Directory -Path $foreignBin -Force | Out-Null
        $driverSamples = @(
            [pscustomobject]@{ Name = 'WinDivert'; PathName = (Join-Path $targetBin 'WinDivert64.sys'); State = 'Running' },
            [pscustomobject]@{ Name = 'WinDivert14'; PathName = ('"{0}"' -f (Join-Path $foreignBin 'WinDivert64.sys')); State = 'Running' },
            [pscustomobject]@{ Name = 'OtherService'; PathName = (Join-Path $targetBin 'WinDivert64.sys'); State = 'Running' }
        )
        $ownedDriverServices = @(Get-ZapretDriverServices -Services $driverSamples -TargetBin $targetBin)
        $winwsPath = Join-Path $targetBin 'winws.exe'
        $winwsServiceSamples = @(
            [pscustomobject]@{ Name = 'zapret'; PathName = ('"{0}" --wf-tcp=80,443' -f $winwsPath); State = 'Running' },
            [pscustomobject]@{ Name = 'other'; PathName = ('"{0}" --wf-tcp=80' -f (Join-Path $foreignBin 'winws.exe')); State = 'Running' }
        )
        $ownedWinwsServices = @(Get-ZapretMatchingWinwsServices -Services $winwsServiceSamples -WinwsPath $winwsPath)
        Check 'runtime helper scopes stop/restore to this installation path only' ($ownedDriverServices.Count -eq 1 -and $ownedDriverServices[0].Name -eq 'WinDivert' -and $ownedWinwsServices.Count -eq 1 -and $ownedWinwsServices[0].Name -eq 'zapret')
        $manualExePath = 'C:\Program Files\Zapret\bin\winws.exe'
        $manualArgs = '--wf-tcp=80,443 --filter-tcp=443'
        $parsedManualArgs = Get-ZapretCommandArguments -CommandLine ('"{0}" {1}' -f $manualExePath, $manualArgs) -ExpectedExecutable $manualExePath
        $rejectedManualArgs = Get-ZapretCommandArguments -CommandLine ('"{0}" {1}' -f 'C:\Other\winws.exe', $manualArgs) -ExpectedExecutable $manualExePath
        Check 'manual winws restore preserves arguments only for the selected executable' ($parsedManualArgs -eq $manualArgs -and $null -eq $rejectedManualArgs)

        foreach ($relative in @('bin/WinDivert64.sys','bin/winws.exe','strategies.json','new-only.txt')) {
            $path = Join-Path $rollbackSource ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $parent = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllText($path, ('new ' + $relative))
        }
        foreach ($relative in @('bin/WinDivert64.sys','bin/winws.exe','strategies.json')) {
            $path = Join-Path $rollbackTarget ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $parent = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllText($path, ('old ' + $relative))
        }
        $rollbackPlan = @(Get-ZapretUpdateFilePlan -SourceRoot $rollbackSource -TargetRoot $rollbackTarget)
        foreach ($file in $rollbackPlan) { if ($file.RelativePath -eq 'strategies.json') { $file.Sha256 = ('0' * 64) } }
        $rollbackResult = Invoke-ZapretFileTransaction -Files $rollbackPlan -WorkRoot $rollbackWork
        $rollbackRestored = $true
        foreach ($relative in @('bin/WinDivert64.sys','bin/winws.exe','strategies.json')) {
            $path = Join-Path $rollbackTarget ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or [IO.File]::ReadAllText($path) -ne ('old ' + $relative)) { $rollbackRestored = $false }
        }
        Check 'failed checksum triggers complete rollback and restores old files' (-not $rollbackResult.Succeeded -and $rollbackResult.RollbackComplete -and $rollbackRestored)
        Check 'rollback removes files that did not exist before the update' (-not (Test-Path -LiteralPath (Join-Path $rollbackTarget 'new-only.txt')))

        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archiveVersion = '2.1.8'
        $releaseName = 'zapret-discord-youtube-' + $archiveVersion
        $archiveSource = Join-Path $updateTestRoot 'archive source'
        New-Item -ItemType Directory -Path $archiveSource -Force | Out-Null
        $archiveFiles = @{
            'zapret.ps1' = 'main'
            'zapret.bat' = 'launcher'
            'Zapret-Control.ps1' = 'control panel'
            'Zapret-Control.bat' = 'control panel launcher'
            'Zapret-Control.ico' = 'control panel icon'
            'Update-Zapret.ps1' = 'updater'
            'Update-Zapret.bat' = 'updater launcher'
            'strategies.json' = '{}'
            'src/Zapret.psm1' = 'module'
            'src/parts/Zapret.Runtime.ps1' = 'runtime'
            'src/parts/Zapret.Strategies.ps1' = 'strategies module'
            'src/parts/Zapret.IpsetHosts.ps1' = 'ipset module'
            'src/parts/Zapret.Diagnostics.ps1' = 'diagnostics'
            'src/parts/Zapret.AutoSelect.ps1' = 'auto select'
            'src/parts/Zapret.Dns.ps1' = 'dns'
            'src/parts/Zapret.Network.ps1' = 'network'
            'src/parts/Zapret.Automation.ps1' = 'automation'
            'src/parts/Zapret.Support.ps1' = 'support'
            'src/parts/Zapret.Maintenance.ps1' = 'maintenance'
            'src/parts/Zapret.Rollback.ps1' = 'rollback'
            'src/parts/Zapret.UserStrategies.ps1' = 'user strategies'
            'src/parts/Zapret.Watchdog.ps1' = 'watchdog'
            'src/parts/Zapret.Doctor.ps1' = 'doctor'
            '.service/version.txt' = $archiveVersion
            'bin/winws.exe' = 'nonempty executable'
            'bin/WinDivert.dll' = 'nonempty library'
            'bin/WinDivert64.sys' = 'nonempty driver'
'lists/list-general.txt' = 'whatsapp.com'
        }
        foreach ($relative in $archiveFiles.Keys) {
            $path = Join-Path $archiveSource ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $parent = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllText($path, [string]$archiveFiles[$relative])
        }
        $archivePath = Join-Path $updateTestRoot ($releaseName + '.zip')
        $zip = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            [void]$zip.CreateEntry($releaseName + '/')
            foreach ($relative in $archiveFiles.Keys) {
                $path = Join-Path $archiveSource ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $path, ($releaseName + '/' + $relative), [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $zip.Dispose() }
        $expandedRoot = Join-Path $updateTestRoot 'expanded release'
        $archiveInfo = Expand-ZapretReleaseArchive -Path $archivePath -DestinationRoot $expandedRoot
        Check 'updater validates and extracts a versioned release ZIP' ($archiveInfo.Version -eq $archiveVersion -and $archiveInfo.Files -eq $archiveFiles.Count -and (Test-Path -LiteralPath (Join-Path $expandedRoot 'bin/WinDivert64.sys') -PathType Leaf))
        $manifestPath = Join-Path $updateTestRoot 'SHA256SUMS.txt'
        $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        [IO.File]::WriteAllText($manifestPath, ($archiveHash + '  ' + [IO.Path]::GetFileName($archivePath) + "`r`n"))
        $checksum = Test-ZapretReleaseChecksum -Path $archivePath
        Check 'updater accepts a SHA256 manifest that matches the archive' $checksum.Verified
        [IO.File]::WriteAllText($manifestPath, (('0' * 64) + '  ' + [IO.Path]::GetFileName($archivePath) + "`r`n"))
        $badChecksumRejected = $false
        try { [void](Test-ZapretReleaseChecksum -Path $archivePath) } catch { $badChecksumRejected = $true }
        Check 'updater rejects an archive whose checksum does not match' $badChecksumRejected

        $unsafeArchivePath = Join-Path $updateTestRoot 'unsafe.zip'
        $unsafeZip = [IO.Compression.ZipFile]::Open($unsafeArchivePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            $unsafeEntry = $unsafeZip.CreateEntry($releaseName + '/../../escape.txt')
            $unsafeWriter = New-Object IO.StreamWriter($unsafeEntry.Open())
            try { $unsafeWriter.Write('unsafe') } finally { $unsafeWriter.Dispose() }
        } finally { $unsafeZip.Dispose() }
        $unsafeRejected = $false
        try { [void](Expand-ZapretReleaseArchive -Path $unsafeArchivePath -DestinationRoot (Join-Path $updateTestRoot 'unsafe extraction')) }
        catch { $unsafeRejected = $true }
        Check 'updater rejects ZIP path traversal before extraction' $unsafeRejected
    } catch {
        Check 'same-folder updater integration tests execute' $false
        Write-Host ("         updater test error: {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
    } finally {
        if (Test-Path -LiteralPath $updateTestRoot) { Remove-Item -LiteralPath $updateTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host '== Voice check and conflict report ==' -ForegroundColor Cyan

$stunTid = [byte[]](1..12)
$stunRequest = New-StunBindingRequest -TransactionId $stunTid
Check 'stun binding request has a valid 20-byte header' ($stunRequest.Length -eq 20 -and $stunRequest[0] -eq 0x00 -and $stunRequest[1] -eq 0x01 -and $stunRequest[4] -eq 0x21 -and $stunRequest[5] -eq 0x12 -and $stunRequest[6] -eq 0xA4 -and $stunRequest[7] -eq 0x42)
$stunResponse = [byte[]]$stunRequest.Clone()
$stunResponse[0] = 0x01
$stunResponse[1] = 0x01
Check 'stun validator accepts a matching binding success response' (Test-StunResponseBytes -Response $stunResponse -TransactionId $stunTid)
$stunTruncated = [byte[]]($stunResponse[0..9])
Check 'stun validator rejects a truncated response' (-not (Test-StunResponseBytes -Response $stunTruncated -TransactionId $stunTid))
$stunBadType = [byte[]]$stunResponse.Clone()
$stunBadType[1] = 0x02
Check 'stun validator rejects a non-response message type' (-not (Test-StunResponseBytes -Response $stunBadType -TransactionId $stunTid))
$stunBadTid = [byte[]](2..13)
Check 'stun validator rejects a foreign transaction id' (-not (Test-StunResponseBytes -Response $stunResponse -TransactionId $stunBadTid))
$stunError = [byte[]]$stunResponse.Clone()
$stunError[1] = 0x11
Check 'stun validator accepts an error response with the same transaction id' (Test-StunResponseBytes -Response $stunError -TransactionId $stunTid)

$voiceVerdict = Get-VoiceCheckVerdict -TcpOk $true -UdpFakeOk $false -UdpStunOk $true -UdpBaselineOk $false -DnsFailed $false
Check 'voice verdict ignores a blocked baseline when Discord UDP works' ($voiceVerdict.VoiceLikely -and $voiceVerdict.Code -eq 'ok')
$voiceVerdict = Get-VoiceCheckVerdict -TcpOk $true -UdpFakeOk $false -UdpStunOk $false -UdpBaselineOk $false -DnsFailed $false
Check 'voice verdict blames UDP-wide failure when no UDP path answers' ($voiceVerdict.Code -eq 'udp-wide' -and -not $voiceVerdict.VoiceLikely)
$voiceVerdict = Get-VoiceCheckVerdict -TcpOk $false -UdpFakeOk $false -UdpStunOk $false -UdpBaselineOk $false -DnsFailed $false
Check 'voice verdict blames UDP-wide on a total blackout' ($voiceVerdict.Code -eq 'udp-wide')
$voiceVerdict = Get-VoiceCheckVerdict -TcpOk $false -UdpFakeOk $true -UdpStunOk $false -UdpBaselineOk $false -DnsFailed $false
Check 'voice verdict blames signalling when only TCP is broken' ($voiceVerdict.Code -eq 'tcp' -and -not $voiceVerdict.VoiceLikely)
$voiceVerdict = Get-VoiceCheckVerdict -TcpOk $true -UdpFakeOk $false -UdpStunOk $false -UdpBaselineOk $true -DnsFailed $false
Check 'voice verdict blames Discord-only UDP when the baseline works' ($voiceVerdict.Code -eq 'discord-udp')
$voiceVerdict = Get-VoiceCheckVerdict -TcpOk $false -UdpFakeOk $false -UdpStunOk $false -UdpBaselineOk $false -DnsFailed $true
Check 'voice verdict reports DNS failure as its own cause' ($voiceVerdict.Code -eq 'dns' -and -not $voiceVerdict.VoiceLikely)

$conflictReport = Get-ZapretConflictReport
Check 'conflict report returns the standard result shape' ($null -ne $conflictReport -and $null -ne $conflictReport.Items -and @($conflictReport.Items).Count -ge 0)
$conflictStrictOk = $true
try {
    Set-StrictMode -Version 2.0
    $strictReport = Get-ZapretConflictReport
    if ($null -eq $strictReport.Items) { $conflictStrictOk = $false }
} catch {
    $conflictStrictOk = $false
} finally {
    Set-StrictMode -Off
}
Check 'conflict report is StrictMode-safe' $conflictStrictOk

$diagnosticsSource = [string](Get-Content -LiteralPath (Join-Path $repoRoot 'src\parts\Zapret.Diagnostics.ps1') -Raw)
Check 'voice runner probes the active fake, Discord and a UDP baseline' ($diagnosticsSource.Contains('ACTIVE_DISCORD_UDP.bin') -and $diagnosticsSource.Contains('discord.media') -and $diagnosticsSource.Contains('stun.l.google.com'))
$rollbackSource = [string](Get-Content -LiteralPath (Join-Path $repoRoot 'src\parts\Zapret.Rollback.ps1') -Raw)
Check 'service restart warns about conflicts and verifies the bypass process' ($rollbackSource.Contains('Get-ZapretConflictReport') -and $rollbackSource.Contains('winws.exe не работает'))
$zapretSource = [string](Get-Content -LiteralPath (Join-Path $repoRoot 'zapret.ps1') -Raw)
Check 'zapret.ps1 wires the voice-check command to the module probe' ($zapretSource.Contains("'voice-check'") -and $zapretSource.Contains('Test-DiscordVoiceConnection'))
Check 'voice-check is listed in the built-in help' ($zapretSource.Contains('voice-check                  Проверить голосовой путь Discord'))
$panelSource = [string](Get-Content -LiteralPath (Join-Path $repoRoot 'Zapret-Control.ps1') -Raw)
Check 'panel exposes the Discord voice check in the wizard' ($panelSource.Contains('btnVoiceCheck') -and $panelSource.Contains('Start-WizardVoiceCheck') -and $panelSource.Contains('Complete-VoiceCheck'))
Check 'wizard progress dispatches voice results to the voice view' ($panelSource.Contains("WizardMode -eq 'voice'"))

Write-Host '== Full console parity (GUI coverage) ==' -ForegroundColor Cyan

Set-ZapretNonInteractive $true
Check 'non-interactive mode turns on for GUI runspace actions' (Get-ZapretNonInteractive)
Set-ZapretNonInteractive $false
Check 'non-interactive mode turns back off' (-not (Get-ZapretNonInteractive))
$rollbackSource = [string](Get-Content -LiteralPath (Join-Path $repoRoot 'src\parts\Zapret.Rollback.ps1') -Raw)
Check 'service restart prompt cannot hang without a console' ($rollbackSource.Contains('Get-ZapretNonInteractive'))
$dnsSource = [string](Get-Content -LiteralPath (Join-Path $repoRoot 'src\parts\Zapret.Dns.ps1') -Raw)
Check 'DoH fallback prompt is gated for GUI runs' ($dnsSource.Contains('Get-ZapretNonInteractive'))
Check 'panel runs mutating actions through the in-app runner' ($panelSource.Contains('Start-ControlAction') -and $panelSource.Contains('Set-ZapretNonInteractive $true') -and $panelSource.Contains("WizardMode = 'action'"))
Check 'panel covers the strategy page end to end' ($panelSource.Contains('pageStrategies') -and $panelSource.Contains('btnInstallStrategy') -and $panelSource.Contains('Install-ZapretService') -and $panelSource.Contains('Start-ZapretManualRun') -and $panelSource.Contains('New-UserStrategy') -and $panelSource.Contains('Import-UserStrategy') -and $panelSource.Contains('Export-UserStrategy'))
Check 'panel covers DNS, DoH and network tools' ($panelSource.Contains('pageNetwork') -and $panelSource.Contains('Enable-Doh') -and $panelSource.Contains('Reset-DnsToDhcp') -and $panelSource.Contains('Restore-DnsRollbackSnapshot') -and $panelSource.Contains('Invoke-DnsBenchmark') -and $panelSource.Contains('Invoke-NetworkOptimize') -and $panelSource.Contains('Invoke-MtuCheck') -and $panelSource.Contains('Invoke-LineQualityTest'))
Check 'panel covers fakes, IPSet, hosts and game filter' ($panelSource.Contains('Set-ActiveFake') -and $panelSource.Contains('Set-IpsetMode') -and $panelSource.Contains('Update-IpsetList') -and $panelSource.Contains('Update-HostsFile') -and $panelSource.Contains('Update-Config @{ gameFilterMode'))
Check 'panel covers maintenance: pause, rollback, import, schedule, updates, support' ($panelSource.Contains('Suspend-ZapretBypass') -and $panelSource.Contains('Restore-RollbackSnapshot') -and $panelSource.Contains('Import-ExternalConfig') -and $panelSource.Contains('Set-AutoSelectSchedule') -and $panelSource.Contains('Get-ZapretUpdateOffer') -and $panelSource.Contains('Install-ZapretUpdate') -and $panelSource.Contains('New-SupportBundle'))
Check 'panel covers domain management and uninstall' ($panelSource.Contains('Add-DomainToList') -and $panelSource.Contains('Remove-DomainFromLists') -and $panelSource.Contains('Reset-UserDomainLists') -and $panelSource.Contains('Remove-ZapretServices'))
Check 'destructive uninstall asks for explicit consent twice' ($panelSource.Contains('btnUninstall') -and $panelSource.Contains('Remove-ZapretServices -Quiet -RemoveHostsBlock:$RemoveHosts'))
$panelButtonNames = @()
foreach ($m in [regex]::Matches($controlPanelText, 'x:Name="(btn[A-Za-z0-9]+|nav[A-Za-z0-9]+)"')) {
    $panelButtonNames += $m.Groups[1].Value
}
$panelButtonNames = @($panelButtonNames | Select-Object -Unique)
$templateParts = @()
foreach ($m in [regex]::Matches($controlPanelText, 'TargetName="([A-Za-z0-9]+)"')) { $templateParts += $m.Groups[1].Value }
$panelButtonNames = @($panelButtonNames | Where-Object { $templateParts -notcontains $_ })
$unwiredButtons = @($panelButtonNames | Where-Object { -not $controlPanelText.Contains(("FindName('{0}').Add_Click" -f $_)) })
Check 'every panel button is wired to a click handler' ($panelButtonNames.Count -gt 45 -and $unwiredButtons.Count -eq 0)
if ($unwiredButtons.Count -gt 0) { $unwiredButtons | ForEach-Object { Write-Host ('         unwired: {0}' -f $_) -ForegroundColor DarkRed } }

Write-Host '== PowerShell syntax ==' -ForegroundColor Cyan

$psFiles = @(
    (Join-Path $repoRoot 'zapret.ps1'),
    (Join-Path $repoRoot 'src\Zapret.psm1'),
    (Join-Path $repoRoot 'utils\test zapret.ps1'),
    (Join-Path $repoRoot 'tools\Build-Release.ps1'),
    (Join-Path $repoRoot 'Zapret-Control.ps1'),
    (Join-Path $repoRoot 'Update-Zapret.ps1')
) + @(Get-ChildItem (Join-Path $repoRoot 'src\parts') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
foreach ($file in $psFiles) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    Check ("parses: {0}" -f (Split-Path $file -Leaf)) (($null -eq $errors) -or ($errors.Count -eq 0))
    if ($errors) { $errors | ForEach-Object { Write-Host "         $($_.Message) (line $($_.Extent.StartLineNumber))" -ForegroundColor DarkRed } }
}
Remove-Item -LiteralPath $testModuleLogRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('-' * 60) -ForegroundColor DarkGray
if ($script:failures.Count -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:passes, $script:failures.Count) -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: all {0} checks passed" -f $script:passes) -ForegroundColor Green
exit 0
