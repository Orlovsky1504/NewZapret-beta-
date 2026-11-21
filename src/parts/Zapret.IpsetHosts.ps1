# ---------------------------------------------------------------------------
# IPSet filter
# ---------------------------------------------------------------------------

function Get-IpsetStateFromContent {
    param([string]$Content)
    if ($null -eq $Content) { return 'none' }
    if ([string]::IsNullOrWhiteSpace($Content)) { return 'any' }
    if ($Content -match [regex]::Escape($script:IpsetSentinel)) { return 'none' }
    return 'loaded'
}

function Get-IpsetState {
    if (-not (Test-Path $script:IpsetFile)) { return 'none' }
    try {
        $content = [IO.File]::ReadAllText($script:IpsetFile)
    } catch {
        return 'unknown'
    }
    return (Get-IpsetStateFromContent -Content $content)
}

function Get-IpsetModePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('loaded','none','any')][string]$Mode,
        [Parameter(Mandatory = $true)][ValidateSet('loaded','none','any','unknown')][string]$CurrentState,
        [Parameter(Mandatory = $true)][string]$IpsetPath,
        [Parameter(Mandatory = $true)][string]$BackupPath
    )
    $description = switch ($Mode) {
        'none'   { 'write the match-nothing sentinel; keep a backup of the current list' }
        'any'    { 'write an empty list (match all); save the current list as a backup' }
        'loaded' { 'restore the downloaded list from its backup file' }
    }
    return [pscustomobject]@{
        CurrentState = $CurrentState
        TargetMode = $Mode
        Description = $description
        IpsetPath = $IpsetPath
        BackupPath = $BackupPath
        RollbackCommand = 'zapret.ps1 rollback'
        RequiresAdministrator = $true
    }
}

function Set-IpsetMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('loaded','none','any')][string]$Mode, [switch]$Preview)

    if ($Mode -eq 'loaded' -and -not (Test-Path $script:IpsetBackup)) {
        throw "No backup of the downloaded list was found (lists\\ipset-all.txt.backup). Use 'Update IPSet List' first."
    }
    $currentState = Get-IpsetState
    if ($Preview) {
        $plan = Get-IpsetModePlan -Mode $Mode -CurrentState $currentState -IpsetPath $script:IpsetFile -BackupPath $script:IpsetBackup
        Write-Host ("Preview: IPSet {0} -> {1}; will {2}." -f $plan.IpsetPath, $plan.TargetMode, $plan.Description)
        Write-PreviewInfo ("No file or service changes made. Applying requires administrator rights; rollback: {0}." -f $plan.RollbackCommand)
        return $plan
    }

    $plan = Get-IpsetModePlan -Mode $Mode -CurrentState $currentState -IpsetPath $script:IpsetFile -BackupPath $script:IpsetBackup
    Write-Info2 ("Applying IPSet {0} -> {1}; will {2}. Rollback: {3}." -f $plan.IpsetPath, $plan.TargetMode, $plan.Description, $plan.RollbackCommand)
    [void](Save-RollbackSnapshot -Reason 'ipset')
    switch ($Mode) {
        'none' {
            if (Test-Path $script:IpsetFile) {
                if (Test-Path $script:IpsetBackup) { Remove-Item $script:IpsetBackup -Force }
                Move-Item $script:IpsetFile $script:IpsetBackup -Force
            }
            [IO.File]::WriteAllText($script:IpsetFile, "$($script:IpsetSentinel)`r`n", (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok "IPSet switched to 'none' (match nothing)."
        }
        'any' {
            # Preserve the current list before truncating it (lossless switch)
            if (Test-Path $script:IpsetFile) {
                $cur = [IO.File]::ReadAllText($script:IpsetFile)
                if (-not [string]::IsNullOrWhiteSpace($cur) -and $cur -notmatch [regex]::Escape($script:IpsetSentinel)) {
                    Copy-Item $script:IpsetFile $script:IpsetBackup -Force
                }
            }
            [IO.File]::WriteAllText($script:IpsetFile, '', (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok "IPSet switched to 'any' (match everything). Avoid leaving it on permanently - many sites may break."
        }
        'loaded' {
            if (-not (Test-Path $script:IpsetBackup)) {
                throw "No backup of the downloaded list was found (lists\ipset-all.txt.backup). Use 'Update IPSet List' first."
            }
            if (Test-Path $script:IpsetFile) { Remove-Item $script:IpsetFile -Force }
            Copy-Item $script:IpsetBackup $script:IpsetFile -Force   # keep the backup available
            Write-Ok "IPSet switched to the downloaded list."
        }
    }
    Write-Log "IPSet mode set to $Mode"
}

function Invoke-Download {
    <#
        Downloads $Url to $OutFile. Prefers curl.exe (better TLS revocation
        handling on Windows), falls back to Invoke-WebRequest.
        Returns $true on success.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$TimeoutSec = 30,
        [switch]$NoLog
    )

    $tmp = "$OutFile.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $curl = Get-CurlPath

        $downloaded = $false
        if ($curl) {
            $attempts = New-Object System.Collections.Generic.List[string[]]
            if ($script:OnWindows) {
                # tolerate stale CRL on some Windows builds; drop Schannel flags on other platforms
                $attempts.Add(@('--ssl-revoke-best-effort', '-L', '-f', '-sS', '--retry', '2', '--connect-timeout', '10', '-m', "$TimeoutSec", '-o', $tmp, $Url))
                $attempts.Add(@('--ssl-no-revoke',          '-L', '-f', '-sS', '--retry', '2', '--connect-timeout', '10', '-m', "$TimeoutSec", '-o', $tmp, $Url))
            } else {
                $attempts.Add(@('-L', '-f', '-sS', '--retry', '2', '--connect-timeout', '10', '-m', "$TimeoutSec", '-o', $tmp, $Url))
            }

            foreach ($attempt in $attempts) {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                & $curl @attempt 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0 -and (Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) {
                    $downloaded = $true
                    break
                }
            }
        }

        if (-not $downloaded) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
            } catch { }
            Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{ 'Cache-Control' = 'no-cache' }
            if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) { $downloaded = $true }
        }

        if ($downloaded) {
            Move-Item $tmp $OutFile -Force
            return $true
        }
    } catch {
        if (-not $NoLog) { Write-Log "Download failed for $Url : $($_.Exception.Message)" 'WARN' }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    return $false
}

function Update-IpsetList {
    [CmdletBinding()]
    param([switch]$Preview)
    if ($Preview) { Write-PreviewInfo 'Preview: download and validate the new IPSet list without touching the installed list, backup, service, or rollback state.' }
    else { Write-Info2 'Downloading the latest IPSet list...' }
    $tmpTarget = if ($Preview) {
        Join-Path ([IO.Path]::GetTempPath()) ('zapret-ipset-preview-{0}.txt' -f [Guid]::NewGuid().ToString('N'))
    } else {
        Join-Path $script:ListsDir 'ipset-all.txt.download'
    }
    try {
        if (-not (Invoke-Download -Url $script:IpsetUrl -OutFile $tmpTarget -TimeoutSec 60 -NoLog:$Preview)) {
            throw "Failed to download $($script:IpsetUrl). Check your internet connection."
        }
        $content = [IO.File]::ReadAllText($tmpTarget)
        $lines = @($content -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
        if ($lines.Count -lt 100) {
            throw "Downloaded list looks invalid ($($lines.Count) entries). Keeping the current file."
        }
        foreach ($line in $lines) {
            if ($line.Trim() -notmatch '^[0-9a-fA-F:.\/]+$') {
                throw "Downloaded list contains an unexpected line: '$($line.Trim())'. Keeping the current file."
            }
        }
        if ($Preview) {
            $currentCount = 0
            if (Test-Path -LiteralPath $script:IpsetFile) {
                $currentContent = [IO.File]::ReadAllText($script:IpsetFile)
                if ($currentContent -notmatch [regex]::Escape($script:IpsetSentinel)) {
                    $currentCount = @($currentContent -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count
                }
            }
            Write-PreviewInfo ("Preview: validated {0} entries from {1}; current list has {2}. Target: {3}; backup would be {3}.bak. No changes were made." -f $lines.Count, $script:IpsetUrl, $currentCount, $script:IpsetFile)
            Write-PreviewInfo 'Applying requires administrator rights; the IPSet/list rollback is available with zapret.ps1 rollback.'
            return [pscustomobject]@{ Preview = $true; CurrentEntries = $currentCount; DownloadedEntries = $lines.Count; TargetPath = $script:IpsetFile; RequiresAdministrator = $true; RollbackCommand = 'zapret.ps1 rollback' }
        }
        Write-Info2 ("Applying validated IPSet list ({0} entries) to {1}; previous list backup: {1}.bak; rollback: zapret.ps1 rollback." -f $lines.Count, $script:IpsetFile)
        [void](Save-RollbackSnapshot -Reason 'ipset')
        if (Test-Path $script:IpsetFile) {
            Copy-Item $script:IpsetFile "$($script:IpsetFile).bak" -Force
        }
        Move-Item $tmpTarget $script:IpsetFile -Force
        Write-Ok "IPSet list updated ($($lines.Count) entries)."
        Write-Info2 "Previous list saved to lists\ipset-all.txt.bak"
    } finally {
        Remove-Item $tmpTarget -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Hosts file maintenance
# ---------------------------------------------------------------------------

$script:HostsBeginMarker = '# >>> zapret-discord-youtube (managed) >>>'
$script:HostsEndMarker   = '# <<< zapret-discord-youtube (managed) <<<'

function Get-HostsFilePath {
    $root = $env:SystemRoot
    if (-not $root) { $root = 'C:\Windows' }
    return (Join-Path $root 'System32\drivers\etc\hosts')
}

function Test-HostsManaged {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $text = [IO.File]::ReadAllText($Path)
    return $text.Contains($script:HostsBeginMarker)
}

function Test-HostsFragment {
    <#
        Validates a downloaded hosts fragment before it is merged into the system hosts file.
        Returns an array of problems (empty = fragment is fine). Pure function - unit-testable.
        Allows: blank lines, whole-line comments, IPv4/IPv6 address + hostnames [+ trailing # comment].
    #>
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Content,
        [int]$MaxBytes = 524288,
        [int]$MaxLines = 5000
    )
    $problems = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Content)) { $problems.Add('fragment is empty'); return $problems.ToArray() }
    if ($Content.Length -gt $MaxBytes) { $problems.Add("fragment is too large ($($Content.Length) bytes)") }
    $lines = $Content -split "`r?`n"
    if ($lines.Count -gt $MaxLines) { $problems.Add("fragment has too many lines ($($lines.Count))") }
    $ipv4 = '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
    $ipv6 = '^[0-9A-Fa-f:.%]+$'
    $hostRe = '^[A-Za-z0-9._-]+$'
    $checked = 0
    foreach ($raw in $lines) {
        if ($problems.Count -ge 5) { break }
        $t = $raw.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $checked++
        $parts = $t -split '\s+'
        $addr = $parts[0]
        $okAddr = ($addr -match $ipv4) -or (($addr -match ':') -and ($addr -match $ipv6))
        if (-not $okAddr) { $problems.Add("bad IP address: '$addr'"); continue }
        $names = @($parts | Select-Object -Skip 1)
        if ($names.Count -eq 0) { $problems.Add("address with no hostname: '$t'"); continue }
        foreach ($n in $names) {
            if ($n.StartsWith('#')) { break }   # trailing comment
            if ($n -notmatch $hostRe) { $problems.Add("bad hostname: '$n'"); break }
        }
    }
    if ($checked -eq 0 -and $problems.Count -eq 0) { $problems.Add('fragment contains no active entries') }
    return $problems.ToArray()
}

function Get-UpdatedHostsContent {
    # Pure: merges $Block into $Current hosts content. Handles fresh install, managed-block
    # replacement and the unbalanced-markers corruption case. Returns @{ Content; Action }.
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Current,
        [Parameter(Mandatory = $true)][string]$Block
    )
    $hasBegin = $Current.Contains($script:HostsBeginMarker)
    $hasEnd   = $Current.Contains($script:HostsEndMarker)
    if ($hasBegin -or $hasEnd) {
        $beginAt = $Current.IndexOf($script:HostsBeginMarker)
        $endAt   = $Current.IndexOf($script:HostsEndMarker)
        if ($beginAt -lt 0 -or $endAt -lt 0 -or $endAt -lt $beginAt) {
            throw 'The managed hosts block markers are unbalanced (a begin marker without an end marker). Remove the stray marker line from hosts manually, then retry.'
        }
        $pattern = [regex]::Escape($script:HostsBeginMarker) + '.*?' + [regex]::Escape($script:HostsEndMarker)
        $newContent = [regex]::Replace($Current, $pattern, $Block.Replace('$', '$$'), 'Singleline')
        return [pscustomobject]@{ Content = $newContent; Action = 'replace' }
    }
    $sep = if ($Current.EndsWith("`n") -or -not $Current) { "" } else { "`r`n" }
    return [pscustomobject]@{ Content = $Current + $sep + "`r`n" + $Block + "`r`n"; Action = 'install' }
}

function Update-HostsFile {
    <#
        Downloads the recommended hosts entries and installs them as a managed,
        idempotent block in the system hosts file (with a timestamped backup).
        A managed block is replaced on each update instead of duplicated.
    #>
    param([switch]$DryRun, [switch]$Preview, [string]$HostsPath)
    if ($Preview) { $DryRun = $true }

    if ($HostsPath) {
        $hostsPath = $HostsPath
    } else {
        if (-not $script:OnWindows) { throw 'Hosts file management is supported on Windows only.' }
        $hostsPath = Get-HostsFilePath
    }
    if (-not $DryRun -and -not $HostsPath) { Assert-Admin }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('zapret_hosts_{0}.txt' -f ([Guid]::NewGuid().ToString('N')))

    if ($DryRun) { Write-PreviewInfo 'Preview: downloading and validating the recommended hosts entries; no system files will be written.' }
    else { Write-Info2 'Downloading the recommended hosts entries...' }
    if (-not (Invoke-Download -Url $script:HostsUrl -OutFile $tmp -TimeoutSec 30 -NoLog:$DryRun)) {
        throw "Failed to download $($script:HostsUrl). Check your internet connection."
    }

    $downloaded = [IO.File]::ReadAllText($tmp).Trim()
    $fragmentProblems = @(Test-HostsFragment -Content $downloaded)
    if ($fragmentProblems.Count -gt 0) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw ('Downloaded hosts fragment failed validation: {0}. Aborting.' -f ($fragmentProblems -join '; '))
    }

    if (-not (Test-Path $hostsPath)) {
        if ($DryRun) { $current = '' }
        else { New-Item -ItemType File -Path $hostsPath -Force | Out-Null; $current = '' }
    } else {
        $current = [IO.File]::ReadAllText($hostsPath)
    }

    $block = @($script:HostsBeginMarker, $downloaded, $script:HostsEndMarker) -join "`r`n"

    try {
        $merged = Get-UpdatedHostsContent -Current $current -Block $block
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        throw
    }
    $newContent = $merged.Content
    $action = $merged.Action

    if ($newContent -eq $current) {
        if ($DryRun) { Write-PreviewInfo 'Preview: the hosts file already has the latest managed block; no changes or backups are needed.' }
        else { Write-Ok 'Hosts file already contains the latest managed block.' }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return $true
    }

    if ($DryRun) {
        $plannedEntries = @($downloaded -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count
        $currentManagedEntries = 0
        $managedMatch = [regex]::Match($current, [regex]::Escape($script:HostsBeginMarker) + '(.*?)' + [regex]::Escape($script:HostsEndMarker), [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($managedMatch.Success) { $currentManagedEntries = @($managedMatch.Groups[1].Value -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count }
        Write-PreviewInfo ("Preview: would {0} {1} validated host entries in {2} (managed entries now: {3})." -f $action, $plannedEntries, $hostsPath, $currentManagedEntries)
        Write-PreviewInfo ("Applying requires administrator rights; it creates a rollback snapshot and a side-by-side backup named {0}.zapret-bak-<timestamp>. No changes were made." -f $hostsPath)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Preview = $true; Action = $action; PlannedEntries = $plannedEntries; CurrentManagedEntries = $currentManagedEntries; HostsPath = $hostsPath; RequiresAdministrator = $true; RollbackCommand = 'zapret.ps1 rollback' }
    }

    $snapHosts = $HostsPath
    if (-not $snapHosts) { $snapHosts = $hostsPath }
    [void](Save-RollbackSnapshot -Reason 'hosts' -HostsPath $snapHosts)
    $plannedEntryCount = @($downloaded -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count
    Write-Info2 ("Applying managed hosts update ({0}, {1} entries) to {2}; rollback: zapret.ps1 rollback." -f $action, $plannedEntryCount, $hostsPath)
    $backup = '{0}.zapret-bak-{1}' -f $hostsPath, (Get-Date -Format 'yyyyMMdd-HHmmssfff')
    Copy-Item $hostsPath $backup -Force
    [IO.File]::WriteAllText($hostsPath, $newContent, (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue

    Write-Ok "Hosts file updated ($action). Backup: $backup"
    Write-Log "Hosts file updated ($action), backup at $backup"
    return $true
}

function Remove-HostsManagedBlock {
    <#
        Removes the managed zapret block (markers included) from the system
        hosts file. Idempotent. A timestamped backup is created before writing.
        Pass -HostsPath to operate on an arbitrary file (tests/dry runs).
    #>
    param(
        [string]$HostsPath,
        [switch]$DryRun
    )
    $path = if ($HostsPath) { $HostsPath } else { Get-HostsFilePath }
    if (-not (Test-Path $path)) {
        Write-Info2 'Hosts file not found - nothing to remove.'
        return $false
    }
    $current = [IO.File]::ReadAllText($path)
    $hasBegin = $current.Contains($script:HostsBeginMarker)
    $hasEnd   = $current.Contains($script:HostsEndMarker)
    if (-not $hasBegin -and -not $hasEnd) {
        Write-Info2 'The managed zapret block is not present in hosts - nothing to remove.'
        return $false
    }
    if (-not $hasBegin -or -not $hasEnd -or $current.IndexOf($script:HostsEndMarker) -lt $current.IndexOf($script:HostsBeginMarker)) {
        Write-Warn2 'The managed hosts markers are unbalanced. Refusing to touch hosts - remove the stray marker line manually, then retry.'
        return $false
    }

    # Line-based removal: drop everything between the markers (inclusive)
    $lines    = $current -split "`r?`n"
    $kept     = New-Object System.Collections.Generic.List[string]
    $inside   = $false
    $removed  = 0
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -eq $script:HostsBeginMarker) { $inside = $true;  $removed++; continue }
        if ($t -eq $script:HostsEndMarker)   { $inside = $false; continue }
        if ($inside) { $removed++; continue }
        $kept.Add($line)
    }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }
    $newContent = ($kept -join "`r`n")
    if ($newContent) { $newContent = $newContent + "`r`n" }
    $newContent = [regex]::Replace($newContent, '(\r?\n[ \t]*){3,}', "`r`n`r`n")

    if ($DryRun) {
        Write-Info2 ("Dry run - would remove {0} line(s) of managed hosts entries." -f $removed)
        return $true
    }

    $backup = '{0}.zapret-bak-{1}' -f $path, (Get-Date -Format 'yyyyMMdd-HHmmssfff')
    Copy-Item $path $backup -Force
    [IO.File]::WriteAllText($path, $newContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "Managed hosts block removed. Backup: $backup"
    Write-Log "Managed hosts block removed, backup at $backup"
    return $true
}

# ---------------------------------------------------------------------------
# Update check
# ---------------------------------------------------------------------------

function Test-UpdateAvailable {
    $local = Get-LocalVersion
    $result = [ordered]@{ Local = $local; Remote = $null; UpdateAvailable = $false; Error = $null }
    $tmp = $null
    try {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('zapret_version_{0}.txt' -f ([Guid]::NewGuid().ToString('N')))
        if (-not (Invoke-Download -Url $script:VersionUrl -OutFile $tmp -TimeoutSec 8)) {
            $result.Error = 'Could not fetch the latest version.txt from GitHub.'
            return [pscustomobject]$result
        }
        $remote = [IO.File]::ReadAllText($tmp).Trim()
        $result.Remote = $remote
        $cmp = Compare-VersionTexts -Remote $remote -Local $local
        if ($null -ne $cmp -and $cmp -gt 0) { $result.UpdateAvailable = $true }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Self-update: feed manifest -> download -> verify -> apply
# ---------------------------------------------------------------------------

function Compare-ZapretUpdateVersions {
    # Pure. Compares X.Y.Z versions with an optional letter build tag where the
    # letter ranks AFTER its base (2.8.1a > 2.8.1, 2.8.2 > 2.8.1a).
    # Returns -1 / 0 / 1, or $null when either side is not a valid version.
    param([string]$Left, [string]$Right)
    $parse = {
        param([string]$Text)
        if ($null -eq $Text) { return $null }
        $m = [regex]::Match($Text.Trim(), '^(?<core>\d+\.\d+\.\d+)(?<build>[A-Za-z])?$')
        if (-not $m.Success) { return $null }
        return [pscustomobject]@{
            Core  = [version]$m.Groups['core'].Value
            Build = [string]$m.Groups['build'].Value.ToUpperInvariant()
        }
    }
    $l = & $parse $Left
    $r = & $parse $Right
    if ($null -eq $l -or $null -eq $r) { return $null }
    $coreCmp = $l.Core.CompareTo($r.Core)
    if ($coreCmp -ne 0) { return [Math]::Sign($coreCmp) }
    return [Math]::Sign([string]::CompareOrdinal($l.Build, $r.Build))
}

function ConvertTo-ZapretUpdateManifest {
    # Pure. Validates a decoded update-manifest.json payload.
    # Returns { Ok; Manifest; Error }; Manifest = { Version; ZipUrl; Sha256; Published; Notes; MinVersion }.
    param($Raw)
    $result = [ordered]@{ Ok = $false; Manifest = $null; Error = $null }
    if ($null -eq $Raw) { $result.Error = 'манифест пуст'; return [pscustomobject]$result }

    $version = ''
    if ($Raw.PSObject.Properties['version']) { $version = [string]$Raw.version }
    if ($null -eq (Compare-ZapretUpdateVersions -Left $version -Right '0.0.0')) {
        $result.Error = "поле version имеет неверный формат: '$version' (ожидается X.Y.Z или X.Y.Za)"
        return [pscustomobject]$result
    }

    $zipUrl = ''
    if ($Raw.PSObject.Properties['zipUrl']) { $zipUrl = ([string]$Raw.zipUrl -replace '[\x00-\x1F\x7F]', '').Trim() }
    $zipLooksValid = ($zipUrl -match '^(https?|file)://') -or ($zipUrl -match '^[A-Za-z]:\\' -or $zipUrl -match '^\\\\')
    if (-not $zipLooksValid) {
        $result.Error = "поле zipUrl не похоже на ссылку или путь к ZIP: '$zipUrl'"
        return [pscustomobject]$result
    }

    $sha256 = ''
    if ($Raw.PSObject.Properties['sha256']) { $sha256 = ([string]$Raw.sha256).Trim() }
    if ($sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        $result.Error = 'поле sha256 должно содержать 64 шестнадцатеричных символа (SHA-256 ZIP)'
        return [pscustomobject]$result
    }

    $minVersion = $null
    if ($Raw.PSObject.Properties['minVersion'] -and [string]$Raw.minVersion) {
        $minVersion = ([string]$Raw.minVersion).Trim()
        if ($null -eq (Compare-ZapretUpdateVersions -Left $minVersion -Right '0.0.0')) {
            $result.Error = "поле minVersion имеет неверный формат: '$minVersion'"
            return [pscustomobject]$result
        }
    }

    $published = ''
    if ($Raw.PSObject.Properties['published']) { $published = ([string]$Raw.published -replace '[\x00-\x1F\x7F]', '').Trim() }
    $notes = @()
    if ($Raw.PSObject.Properties['notes'] -and $Raw.notes) {
        $notes = @($Raw.notes | ForEach-Object { ([string]$_ -replace '[\x00-\x1F\x7F]', ' ').Trim() } | Where-Object { $_ })
    }

    $result.Ok = $true
    $result.Manifest = [pscustomobject]@{
        Version    = ([string]$version).Trim()
        ZipUrl     = $zipUrl
        Sha256     = $sha256.ToUpperInvariant()
        Published  = $published
        Notes      = $notes
        MinVersion = $minVersion
    }
    return [pscustomobject]$result
}

function Get-ZapretUpdateFeedUrl {
    # config.json -> updateFeed wins; an explicit -Url is used as-is (tests).
    param([string]$Url)
    if ($Url) { return $Url.Trim() }
    $feed = ''
    try { $feed = [string](Get-Config).updateFeed } catch { }
    if ([string]::IsNullOrWhiteSpace($feed)) { return $null }
    return $feed.Trim()
}

function Get-ZapretUpdateManifest {
    # Downloads and validates update-manifest.json. Returns { Ok; Manifest; Error; FeedUrl }.
    param([string]$Url)
    $result = [ordered]@{ Ok = $false; Manifest = $null; Error = $null; FeedUrl = $null }
    $feed = Get-ZapretUpdateFeedUrl -Url $Url
    if (-not $feed) {
        $result.Error = 'Источник автообновлений не настроен (config.json -> updateFeed).'
        return [pscustomobject]$result
    }
    $result.FeedUrl = $feed
    $tmp = $null
    try {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('zapret_update_manifest_{0}.json' -f ([Guid]::NewGuid().ToString('N')))
        if (-not (Invoke-Download -Url $feed -OutFile $tmp -TimeoutSec 15)) {
            $result.Error = 'Не удалось скачать update-manifest.json (см. журнал).'
            return [pscustomobject]$result
        }
        $raw = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json
        $validated = ConvertTo-ZapretUpdateManifest -Raw $raw
        if (-not $validated.Ok) {
            $result.Error = ('Манифест обновлений некорректен: {0}' -f $validated.Error)
            return [pscustomobject]$result
        }
        $result.Manifest = $validated.Manifest
        $result.Ok = $true
    } catch {
        $result.Error = ('Не удалось прочитать манифест обновлений: {0}' -f $_.Exception.Message)
    } finally {
        if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]$result
}

function Get-ZapretUpdateOffer {
    # Feed-first update check. Returns
    # { Configured; Local; Remote; UpdateAvailable; Manifest; Error }.
    $local = Get-LocalVersion
    $result = [ordered]@{ Configured = $false; Local = $local; Remote = $null; UpdateAvailable = $false; Manifest = $null; Error = $null }
    $feed = Get-ZapretUpdateFeedUrl
    if (-not $feed) {
        $result.Error = 'Источник автообновлений не настроен (config.json -> updateFeed).'
        return [pscustomobject]$result
    }
    $result.Configured = $true
    $manifestResult = Get-ZapretUpdateManifest
    if (-not $manifestResult.Ok) {
        $result.Error = $manifestResult.Error
        return [pscustomobject]$result
    }
    $m = $manifestResult.Manifest
    $result.Remote = $m.Version
    $result.Manifest = $m
    $cmp = Compare-ZapretUpdateVersions -Left $m.Version -Right $local
    if ($null -eq $cmp) {
        $result.Error = ('Не удалось сравнить версии: манифест {0}, установлено {1}.' -f $m.Version, $local)
        return [pscustomobject]$result
    }
    if ($cmp -gt 0) { $result.UpdateAvailable = $true }
    if ($result.UpdateAvailable -and $m.MinVersion) {
        $minCmp = Compare-ZapretUpdateVersions -Left $local -Right $m.MinVersion
        if ($null -ne $minCmp -and $minCmp -lt 0) {
            $result.UpdateAvailable = $false
            $result.Error = ('Обновление {0} требует установленной версии не ниже {1}; у вас {2}.' -f $m.Version, $m.MinVersion, $local)
        }
    }
    return [pscustomobject]$result
}

function Install-ZapretUpdate {
    # Downloads the release ZIP, verifies its SHA-256 against the manifest and
    # runs the transactional updater (Update-Zapret.ps1 -AssumeYes) which keeps
    # config, logs and user lists. Returns { Ok; ExitCode; Error; NewVersion }.
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [switch]$Relaunch
    )
    $result = [ordered]@{ Ok = $false; ExitCode = -1; Error = $null; NewVersion = $null }
    if (-not $Manifest -or -not $Manifest.Sha256 -or -not $Manifest.ZipUrl -or -not $Manifest.Version) {
        $result.Error = 'Манифест неполный: нужны version, zipUrl и sha256.'
        return [pscustomobject]$result
    }
    if (-not $script:OnWindows) {
        $result.Error = 'Автоустановка обновлений поддерживается только в Windows.'
        return [pscustomobject]$result
    }
    $updater = Join-Path $script:Root 'Update-Zapret.ps1'
    if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
        $result.Error = 'Update-Zapret.ps1 не найден в папке установки.'
        return [pscustomobject]$result
    }

    $workDir = Join-Path ([IO.Path]::GetTempPath()) ('zapret_update_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $zip = Join-Path $workDir ('zapret-discord-youtube-{0}.zip' -f $Manifest.Version)
    try {
        Write-Info2 ('Скачиваю обновление {0}…' -f $Manifest.Version)
        if (-not (Invoke-Download -Url $Manifest.ZipUrl -OutFile $zip -TimeoutSec 600 -NoLog)) {
            $result.Error = 'Не удалось скачать ZIP обновления (см. журнал).'
            return [pscustomobject]$result
        }
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($hash -ne $Manifest.Sha256.ToUpperInvariant()) {
            $result.Error = ('Контрольная сумма ZIP не совпала с манифестом (файл: {0}). Обновление не установлено.' -f $hash)
            return [pscustomobject]$result
        }
        Write-Ok 'Контрольная сумма ZIP подтверждена.'
        Write-Log ('Update {0}: sha256 verified, applying via Update-Zapret.ps1' -f $Manifest.Version)
        # Update-Zapret.ps1 verifies the ZIP against SHA256SUMS.txt next to it;
        # write the already-verified hash so the transactional gate passes.
        $sumsPath = Join-Path $workDir 'SHA256SUMS.txt'
        [IO.File]::WriteAllText($sumsPath, ('{0}  {1}' -f $hash, (Split-Path -Leaf $zip)), (New-Object System.Text.UTF8Encoding($false)))

        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
            $result.Error = 'Не найден Windows PowerShell 5.1.'
            return [pscustomobject]$result
        }
        $rootArg = [string]$script:Root
        if ($rootArg -match '\\$') { $rootArg += '.' }   # keep the closing quote intact
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ArchivePath "{1}" -TargetRoot "{2}" -AssumeYes -NoPause' -f $updater, $zip, $rootArg
        $proc = Start-Process -FilePath $powershell -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
        $result.ExitCode = [int]$proc.ExitCode
        if ($proc.ExitCode -ne 0) {
            $result.Error = ('Обновление не завершилось (код {0}). Подробности — в окне обновления; настройки не изменены.' -f $proc.ExitCode)
            return [pscustomobject]$result
        }
        $result.Ok = $true
        $result.NewVersion = $Manifest.Version
        Write-Ok ('Обновление {0} установлено. Каталог и настройки сохранены.' -f $Manifest.Version)
        Write-Log ('Update {0} applied successfully' -f $Manifest.Version)

        if ($Relaunch) {
            $launcher = Join-Path $script:Root 'Zapret-Control.exe'
            if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { $launcher = Join-Path $script:Root 'Zapret-Control.bat' }
            if (Test-Path -LiteralPath $launcher -PathType Leaf) {
                try { Start-Process -FilePath $launcher | Out-Null } catch { }
            }
        }
    } catch {
        $result.Error = ('Автообновление не удалось: {0}' -f $_.Exception.Message)
        Write-Log ('Update failed: {0}' -f $_.Exception.Message) 'FAIL'
    } finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]$result
}

function Invoke-UpdateCheck {
    param([switch]$Soft, [switch]$OpenBrowser)
    $cfg = Get-Config
    if ($Soft -and -not $cfg.checkUpdates) { return $null }

    $offer = Get-ZapretUpdateOffer
    if ($offer.Configured) {
        if ($offer.Error) {
            if (-not $Soft) { Write-Warn2 "$($offer.Error) Это не влияет на работу обхода." }
            return $offer
        }
        if ($offer.UpdateAvailable) {
            Write-Warn2 ("Доступно обновление сборки: {0} (установлено: {1})" -f $offer.Remote, $offer.Local)
            Write-Info2 "Источник: $($offer.Manifest.ZipUrl)"
            Write-Info2 'Установка: панель управления -> «Проверить обновления» или zapret.ps1 update-install'
            if ($OpenBrowser -and $offer.Manifest.ZipUrl) { Start-Process $offer.Manifest.ZipUrl | Out-Null }
        } else {
            if (-not $Soft) { Write-Ok ("Установлена последняя версия сборки ({0})." -f $offer.Local) }
        }
        return $offer
    }

    # Feed not configured: informational check against the upstream project only.
    $info = Test-UpdateAvailable
    if ($info.Error) {
        if (-not $Soft) { Write-Warn2 "$($info.Error) Это не влияет на работу обхода." }
        return $info
    }
    if ($info.UpdateAvailable) {
        Write-Warn2 ("Проект-апстрим Flowseal выпустил версию {0} (ваша сборка: {1})" -f $info.Remote, $info.Local)
        Write-Info2 'Это ДРУГОЙ проект. Автообновление вашей сборки включается через config.json -> updateFeed.'
        if ($OpenBrowser) { Start-Process $script:ReleasesUrl | Out-Null }
    } else {
        if (-not $Soft) { Write-Ok ("Установлена последняя версия сборки ({0})." -f $info.Local) }
    }
    return $info
}

# ---------------------------------------------------------------------------
# Active fake replacement
# ---------------------------------------------------------------------------

function Get-FakeInventory {
    $bin = $script:BinDir
    $activeDiscord = Join-Path $bin 'ACTIVE_DISCORD_UDP.bin'
    $activeGame    = Join-Path $bin 'ACTIVE_GAME_UDP.bin'

    $currentDiscord = '(not found)'
    $currentGame    = '(not found)'
    $fakes          = @()

    $allBins = @(Get-ChildItem -LiteralPath $bin -Filter '*.bin' -File -ErrorAction SilentlyContinue)
    $hashes  = @{}
    foreach ($f in $allBins) {
        try { $hashes[$f.Name] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { }
    }

    $findMatch = {
        param($activePath)
        if (-not (Test-Path $activePath)) { return '(unknown)' }
        $activeName = Split-Path $activePath -Leaf
        if (-not $hashes.ContainsKey($activeName)) { return '(unknown)' }
        $hash = $hashes[$activeName]
        foreach ($f in $allBins) {
            if ($f.BaseName -like 'ACTIVE_*') { continue }
            if ($hashes[$f.Name] -eq $hash) { return $f.BaseName }
        }
        return '(custom)'
    }

    $currentDiscord = & $findMatch $activeDiscord
    $currentGame    = & $findMatch $activeGame

    $fakes = @($allBins | Where-Object { $_.BaseName -notlike 'ACTIVE_*' } | Sort-Object Name)

    return [pscustomobject]@{
        Fakes              = $fakes
        CurrentDiscordFake = $currentDiscord
        CurrentGameFake    = $currentGame
        ActiveDiscordPath  = $activeDiscord
        ActiveGamePath     = $activeGame
    }
}

function Set-ActiveFake {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('discord','game')][string]$Target,
        [Parameter(Mandatory = $true)][string]$FakeBaseName
    )
    if ($FakeBaseName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { throw "Invalid fake name '$FakeBaseName' (letters, digits, '.', '-' and '_' only)." }
    $inventory = Get-FakeInventory
    $source = @($inventory.Fakes | Where-Object { $_.BaseName -eq $FakeBaseName })
    if ($source.Count -ne 1) { throw "Fake '$FakeBaseName' was not found in bin\." }
    $destination = if ($Target -eq 'discord') { $inventory.ActiveDiscordPath } else { $inventory.ActiveGamePath }
    Copy-Item -LiteralPath $source[0].FullName -Destination $destination -Force
    Write-Ok "Active $Target fake replaced with '$($source[0].BaseName)'."
    Write-Log "Active fake for $Target replaced with $($source[0].Name)"
}
