# ---------------------------------------------------------------------------
# Import config from an old install (seamless 2.x update)
# ---------------------------------------------------------------------------

function Get-MigrationFileList {
    # Relative paths (with backslashes) of files to migrate, if present in $SourcePath.
    param([Parameter(Mandatory = $true)][string]$SourcePath)
    $files = @()
    if (Test-Path (Join-Path $SourcePath 'config.json')) { $files += 'config.json' }
    foreach ($rel in @('lists\list-general-user.txt', 'lists\list-exclude-user.txt', 'lists\ipset-exclude-user.txt')) {
        if (Test-Path (Join-Path $SourcePath $rel)) { $files += $rel }
    }
    $listsDir = Join-Path $SourcePath 'lists'
    if (Test-Path $listsDir) {
        Get-ChildItem -LiteralPath $listsDir -Filter '*-user.txt' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = 'lists\' + $_.Name
            if ($files -notcontains $rel) { $files += $rel }
        }
    }
    if (Test-Path (Join-Path $SourcePath 'lists\ipset-all.txt')) { $files += 'lists\ipset-all.txt' }
    $binDir = Join-Path $SourcePath 'bin'
    if (Test-Path $binDir) {
        Get-ChildItem -LiteralPath $binDir -Filter 'ACTIVE_*.bin' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $files += 'bin\' + $_.Name
        }
    }
    return @($files)
}

function Test-ExternalConfigSource {
    # Heuristic: does $SourcePath look like a zapret install folder?
    param([Parameter(Mandatory = $true)][string]$SourcePath)
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { return $false }
    foreach ($marker in @('strategies.json', 'zapret.bat', 'zapret.ps1', '.service\version.txt', 'src\Zapret.psm1')) {
        if (Test-Path (Join-Path $SourcePath $marker)) { return $true }
    }
    # Export package made by 'zapret.ps1 export-config'.
    $manifest = Join-Path $SourcePath 'export-manifest.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try {
            $data = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
            if ([string]$data.Kind -eq 'zapret-config-export') { return $true }
        } catch { }
    }
    return $false
}

function Get-ExportConfigDefaultPath {
    # Desktop, falling back to the install root.
    $desktop = $null
    try { $desktop = Get-DesktopPath } catch { }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $name = 'zapret-config-{0}.zip' -f $stamp
    if ($desktop) { return (Join-Path $desktop $name) }
    return (Join-Path $script:Root $name)
}

function Export-ZapretConfig {
    <#
        Packs the user's configuration (config.json, personal lists, ipset and
        active fake files) plus an export manifest into a single zip that
        'import-config' can consume on any machine.
    #>
    [CmdletBinding()]
    param([string]$Destination, [string]$SourceRoot)
    if (-not $SourceRoot) { $SourceRoot = $script:Root }
    if (-not $Destination) { $Destination = Get-ExportConfigDefaultPath }
    if (-not $Destination.ToLowerInvariant().EndsWith('.zip')) { $Destination = '{0}.zip' -f $Destination }
    $destinationFull = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $destinationFull) { throw ('Файл уже существует: {0}' -f $destinationFull) }
    $files = @(Get-MigrationFileList -SourcePath $SourceRoot)
    if ($files.Count -eq 0) { throw 'Нечего выгружать: пользовательские настройки и списки не найдены.' }
    $staging = Join-Path ([IO.Path]::GetTempPath()) ('zapret-export-{0}' -f ([Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        foreach ($rel in $files) {
            $src = Join-Path $SourceRoot $rel
            $dst = Join-Path $staging $rel
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        $version = ''
        try { $version = [string](Get-LocalVersion) } catch { }
        $manifest = [pscustomobject]@{
            Kind        = 'zapret-config-export'
            ExportedAt  = (Get-Date -Format 's')
            Version     = $version
            Files       = $files
        }
        [IO.File]::WriteAllText((Join-Path $staging 'export-manifest.json'), ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
        $destDir = Split-Path -Parent $destinationFull
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $destinationFull -ErrorAction Stop
        Write-Ok ('Резервная копия настроек: {0} (файлов: {1})' -f $destinationFull, $files.Count)
        Write-Log ("Config exported to {0} ({1} files)" -f $destinationFull, $files.Count)
        return [pscustomobject]@{ Path = $destinationFull; FileCount = $files.Count; Files = $files }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Expand-ExternalConfigArchive {
    <#
        Safe extraction of a config export zip: rejects rooted paths, '..'
        traversal and drive letters in entry names (zip-slip), then extracts
        into a fresh temp folder. Returns the folder that holds the files.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $work = Join-Path ([IO.Path]::GetTempPath()) ('zapret-import-{0}' -f ([Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $archiveFull = (Resolve-Path -LiteralPath $ArchivePath).Path
        $zip = [IO.Compression.ZipFile]::OpenRead($archiveFull)
        try {
            foreach ($entry in $zip.Entries) {
                $name = [string]$entry.FullName
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $normalized = $name.Replace('/', '\')
                if ([IO.Path]::IsPathRooted($normalized) -or $normalized -match '^[A-Za-z]:' -or $normalized -match '(^|\\)\.\.?(\\|$)' -or $normalized.Contains('..')) {
                    throw ('Архив отклонён: недопустимый путь в записи «{0}».' -f $name)
                }
            }
            [IO.Compression.ZipFile]::ExtractToDirectory($archiveFull, $work)
        } finally {
            $zip.Dispose()
        }
        # A re-zipped folder may wrap everything in one top directory.
        $root = $work
        if (-not (Test-Path -LiteralPath (Join-Path $work 'export-manifest.json'))) {
            $children = @(Get-ChildItem -LiteralPath $work)
            if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $root = $children[0].FullName }
        }
        return [pscustomobject]@{ Path = $root; WorkDir = $work }
    } catch {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Copy-ExternalConfigFiles {
    <#
        Copies config.json, lists\*-user.txt, lists\ipset-all.txt and bin\ACTIVE_*.bin
        from $SourcePath into $DestinationRoot, backing up overwritten files into
        logs\import-backup-<timestamp>\. Returns a summary object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )
    if (-not (Test-ExternalConfigSource -SourcePath $SourcePath)) {
        throw "Папка '$SourcePath' не похожа на установку zapret (нет strategies.json / zapret.bat / src\Zapret.psm1)."
    }
    $srcFull = (Resolve-Path -LiteralPath $SourcePath).Path.TrimEnd('\', '/')
    $dstFull = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\', '/')
    if ($srcFull -ieq $dstFull) { throw 'Исходная папка совпадает с текущей - нечего мигрировать.' }

    $files = Get-MigrationFileList -SourcePath $SourcePath
    $copied = @(); $backedUp = @(); $backupRoot = $null
    foreach ($rel in $files) {
        $src = Join-Path $SourcePath $rel
        $dst = Join-Path $dstFull $rel
        if ((Test-Path -LiteralPath $dst)) {
            if (-not $backupRoot) {
                $backupRoot = Join-Path $dstFull ('logs\import-backup-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            }
            $backupTarget = Join-Path $backupRoot $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupTarget) -Force | Out-Null
            Copy-Item -LiteralPath $dst -Destination $backupTarget -Force
            $backedUp += $rel
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copied += $rel
    }
    return [pscustomobject]@{
        Copied    = @($copied)
        BackedUp  = @($backedUp)
        BackupDir = $backupRoot
    }
}

function Import-ExternalConfig {
    <#
        Migrates config.json / user lists / ipset-all.txt / ACTIVE_*.bin from an old
        zapret folder into this install, then re-points the 'zapret' service at the
        same strategy it was installed with (Windows + admin).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [switch]$NoInstall
    )
    # Accept both an old install folder and an 'export-config' zip package.
    $cleanupDir = $null
    if ($SourcePath.ToLowerInvariant().EndsWith('.zip') -and (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        $extract = Expand-ExternalConfigArchive -ArchivePath $SourcePath
        $cleanupDir = [string]$extract.WorkDir
        $SourcePath = [string]$extract.Path
    }
    try {
    $result = Copy-ExternalConfigFiles -SourcePath $SourcePath -DestinationRoot $script:Root
    if ($result.Copied.Count -eq 0) {
        Write-Warn2 'В старой папке не нашлось файлов для переноса (config.json, *-user.txt, ipset-all.txt, ACTIVE_*.bin).'
        return $result
    }
    foreach ($rel in $result.Copied) { Write-Info2 ("Перенесён: {0}" -f $rel) }
    if ($result.BackedUp.Count -gt 0) {
        Write-Info2 ("Перезаписанные файлы сохранены в {0}" -f $result.BackupDir)
    }
    Write-Ok ("Перенесено файлов: {0}" -f $result.Copied.Count)

    if ($NoInstall) {
        Write-Info2 'Служба не переустанавливалась (-NoInstall).'
        return $result
    }
    $strategy = $null
    try { $strategy = (Get-ZapretServiceInfo).Strategy } catch { }
    if ($script:OnWindows -and $strategy -and (Get-Strategy $strategy)) {
        Write-Info2 ("Переустанавливаю службу на новую папку (стратегия: {0})..." -f $strategy)
        try {
            Install-ZapretService -StrategyId $strategy | Out-Null
            Write-Ok ("Служба 'zapret' переустановлена со стратегией {0}" -f $strategy)
        } catch {
            Write-Warn2 ("Службу переустановить не удалось: {0}" -f $_.Exception.Message)
            Write-Info2 ("Выполните вручную: zapret.ps1 install {0}" -f $strategy)
        }
        Write-Info2 'Если включена еженедельная перепроверка, пересоздайте задачу: zapret.ps1 schedule-autoselect disable; zapret.ps1 schedule-autoselect enable'
    } else {
        Write-Info2 'Установленная ранее стратегия не найдена - служба не переустанавливалась.'
        Write-Info2 'Если служба нужна, установите: zapret.ps1 install <id>  (см. zapret.ps1 list)'
    }
    Write-Log ("Import from '{0}': {1} file(s)" -f $SourcePath, $result.Copied.Count)
    return $result
    } finally {
        if ($cleanupDir) { Remove-Item -LiteralPath $cleanupDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
# ---------------------------------------------------------------------------
# Log rotation (logs\ must not grow forever with the weekly re-check on)
# ---------------------------------------------------------------------------

function Invoke-LogRotation {
    # Deletes *.log/*.txt files in $LogDir older than $MaxAgeDays, then trims
    # the folder to the $MaxFiles newest files. Returns deleted count.
    # Rollback/backup subdirectories are NOT touched.
    [CmdletBinding()]
    param(
        [string]$LogDir = $script:LogDir,
        [int]$MaxAgeDays = 14,
        [int]$MaxFiles = 20
    )
    if (-not (Test-Path -LiteralPath $LogDir)) { return 0 }
    $deleted = 0
    $match = '^\.(log|txt)$'
    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    $files = @(Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match $match })
    foreach ($f in @($files | Where-Object { $_.LastWriteTime -lt $cutoff })) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++ } catch { }
    }
    $rest = @(Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match $match } | Sort-Object LastWriteTime -Descending)
    foreach ($f in @($rest | Select-Object -Skip $MaxFiles)) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++ } catch { }
    }
    return $deleted
}
