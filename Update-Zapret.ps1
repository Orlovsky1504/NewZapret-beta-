#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ArchivePath,
    [string]$TargetRoot,
    [switch]$Elevated,
    [switch]$NoRun,
    [switch]$NoPause,
    [switch]$AssumeYes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:ZapretUpdateWorkRoot = $null
$script:ZapretUpdateKeepWork = $false
$script:ZapretUpdateChildHandledPause = $false

function Get-ZapretVersionParts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Version)
    $versionMatch = [regex]::Match($Version.Trim(), '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?<build>[A-Za-z])?(?:-(?<pre>[0-9A-Za-z.-]+))?$')
    if (-not $versionMatch.Success) { throw "Неверный номер версии '$Version'. Ожидается X.Y.Z, X.Y.Za или X.Y.Z-prerelease." }
    return [pscustomobject]@{
        Major = [long]$versionMatch.Groups['major'].Value
        Minor = [long]$versionMatch.Groups['minor'].Value
        Patch = [long]$versionMatch.Groups['patch'].Value
        Build = [string]$versionMatch.Groups['build'].Value
        Pre = [string]$versionMatch.Groups['pre'].Value
        Text = $Version.Trim()
    }
}

function Compare-ZapretVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    $a = Get-ZapretVersionParts -Version $Left
    $b = Get-ZapretVersionParts -Version $Right
    foreach ($field in @('Major','Minor','Patch')) {
        if ($a.$field -gt $b.$field) { return 1 }
        if ($a.$field -lt $b.$field) { return -1 }
    }
    # Буква после патча (2.8.1a) - это более новая сборка, а не prerelease.
    $aBuild = [string]$a.Build
    $bBuild = [string]$b.Build
    $buildCompare = [string]::Compare($aBuild, $bBuild, [StringComparison]::OrdinalIgnoreCase)
    if ($buildCompare -ne 0) { return $buildCompare }
    if (-not $a.Pre -and $b.Pre) { return 1 }
    if ($a.Pre -and -not $b.Pre) { return -1 }
    return [string]::Compare($a.Pre, $b.Pre, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ZapretArchiveRootVersion {
    # Extracts the version from a release folder name
    # (zapret-discord-youtube-2.8.1a -> '2.8.1a'). Returns $null for anything else.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$RootName)
    $rootMatch = [regex]::Match($RootName.Trim(), '^zapret-discord-youtube-(?<version>\d+\.\d+\.\d+[A-Za-z]?(?:-[0-9A-Za-z.-]+)?)$')
    if (-not $rootMatch.Success) { return $null }
    $version = $rootMatch.Groups['version'].Value
    try { [void](Get-ZapretVersionParts -Version $version) } catch { return $null }
    return $version
}

function Test-ZapretInstallRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($relative in @('zapret.ps1','strategies.json','.service/version.txt','src/Zapret.psm1','bin/winws.exe','bin/WinDivert64.sys')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) { return $false }
    }
    return $true
}

function Get-ZapretPreserveMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $relative = $RelativePath.Replace('\','/').TrimStart('/').ToLowerInvariant()
    if ($relative -eq 'config.json' -or $relative -eq 'strategies-user.json' -or $relative.StartsWith('logs/')) { return 'Always' }
    if ($relative -match '^lists/[^/]+-user\.txt$') { return 'Always' }
    if ($relative -in @('lists/ipset-all.txt','lists/ipset-all.txt.backup','utils/check_updates.enabled','utils/game_filter.enabled')) { return 'IfExists' }
    if ($relative -match '^bin/active_.+\.bin$') { return 'IfExists' }
    return ''
}

function Test-ZapretSafeArchivePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$EntryName)
    if ([string]::IsNullOrWhiteSpace($EntryName) -or $EntryName.Contains('\') -or $EntryName.StartsWith('/') -or $EntryName -match '^[A-Za-z]:') { return $false }
    $clean = $EntryName.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($clean)) { return $false }
    foreach ($segment in $clean.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.','..')) { return $false }
        if ($segment -match '[\x00-\x1f<>:"|?*]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) { return $false }
        if ($segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') { return $false }
    }
    return $true
}

function Expand-ZapretReleaseArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Архив не найден: $Path" }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    $rootName = $null
    $seen = @{}
    $files = New-Object 'System.Collections.Generic.List[object]'
    $maximumEntries = 10000
    $maximumExpandedBytes = [long]536870912
    $expandedBytes = [long]0
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        if ($zip.Entries.Count -gt $maximumEntries) { throw "ZIP содержит слишком много элементов (лимит: $maximumEntries)." }
        foreach ($entry in $zip.Entries) {
            $name = [string]$entry.FullName
            if (-not (Test-ZapretSafeArchivePath -EntryName $name)) { throw "В архиве обнаружен небезопасный путь: $name" }
            $unixMode = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixMode -eq 0xA000) { throw "Символические ссылки в архиве запрещены: $name" }
            if ($unixMode -ne 0 -and $unixMode -ne 0x8000 -and $unixMode -ne 0x4000) { throw "Неподдерживаемый тип элемента архива: $name" }
            $isDirectory = ($name.EndsWith('/') -or $unixMode -eq 0x4000)
            if ($isDirectory -and $unixMode -eq 0x8000) { throw "Тип файла не совпадает с его путём в ZIP: $name" }
            $trimmed = $name.TrimEnd('/')
            $segments = @($trimmed.Split('/'))
            if ($segments.Count -lt 1) { throw "Элемент архива находится вне папки релиза: $name" }
            if (-not $rootName) { $rootName = $segments[0] }
            if (-not [string]::Equals($segments[0], $rootName, [StringComparison]::OrdinalIgnoreCase)) { throw 'Архив должен содержать только одну верхнюю папку релиза.' }
            if ($segments.Count -eq 1) {
                if (-not $isDirectory) { throw "Файл находится вне папки релиза: $name" }
                continue
            }
            $relative = ($segments | Select-Object -Skip 1) -join '/'
            $key = $relative.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { throw "В архиве повторяется путь (без учёта регистра): $relative" }
            $seen[$key] = $true
            if ($isDirectory) { continue }
            if ($entry.Length -lt 0 -or $entry.Length -gt ($maximumExpandedBytes - $expandedBytes)) { throw 'Распакованный ZIP превышает безопасный лимит 512 МиБ.' }
            $expandedBytes += [long]$entry.Length
            $files.Add([pscustomobject]@{ Entry = $entry; RelativePath = $relative })
        }
        if (-not $rootName -or $files.Count -eq 0) { throw 'В ZIP нет файлов релиза.' }
        $rootVersion = Get-ZapretArchiveRootVersion -RootName $rootName
        if (-not $rootVersion) { throw "Неизвестная верхняя папка архива: $rootName" }
        $versionEntry = @($files | Where-Object { $_.RelativePath -ieq '.service/version.txt' } | Select-Object -First 1)
        if ($versionEntry.Count -ne 1) { throw 'В архиве отсутствует .service/version.txt.' }
        $reader = $null
        try {
            $reader = New-Object IO.StreamReader($versionEntry[0].Entry.Open(), [Text.Encoding]::UTF8, $true)
            $fileVersion = $reader.ReadToEnd().Trim()
        } finally {
            if ($reader) { $reader.Dispose() }
        }
        if (-not [string]::Equals($fileVersion, $rootVersion, [StringComparison]::OrdinalIgnoreCase)) { throw "Версия папки $rootVersion не совпадает с .service/version.txt ($fileVersion)." }
        $required = @(
            'zapret.ps1','zapret.bat','Zapret-Control.ps1','Zapret-Control.bat','Zapret-Control.ico','Update-Zapret.ps1','Update-Zapret.bat','strategies.json',
            'src/Zapret.psm1','.service/version.txt','bin/winws.exe','bin/WinDivert.dll','bin/WinDivert64.sys','lists/list-general.txt',
            'src/parts/Zapret.Runtime.ps1','src/parts/Zapret.Strategies.ps1','src/parts/Zapret.IpsetHosts.ps1',
            'src/parts/Zapret.Diagnostics.ps1','src/parts/Zapret.AutoSelect.ps1','src/parts/Zapret.Dns.ps1',
            'src/parts/Zapret.Network.ps1','src/parts/Zapret.Automation.ps1','src/parts/Zapret.Support.ps1',
            'src/parts/Zapret.Maintenance.ps1','src/parts/Zapret.Rollback.ps1','src/parts/Zapret.UserStrategies.ps1',
            'src/parts/Zapret.Watchdog.ps1','src/parts/Zapret.Doctor.ps1'
        )
        foreach ($relative in $required) {
            if (-not $seen.ContainsKey($relative.ToLowerInvariant())) { throw "В архиве отсутствует обязательный файл: $relative" }
        }
        if (Test-Path -LiteralPath $DestinationRoot) {
            if (@(Get-ChildItem -LiteralPath $DestinationRoot -Force -ErrorAction Stop).Count -gt 0) { throw "Временная папка извлечения не пуста: $DestinationRoot" }
        } else {
            New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
        }
        $destinationFull = [IO.Path]::GetFullPath($DestinationRoot)
        $destinationPrefix = $destinationFull.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)) + [IO.Path]::DirectorySeparatorChar
        foreach ($file in $files) {
            $relativeNative = $file.RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $destination = [IO.Path]::GetFullPath((Join-Path $destinationFull $relativeNative))
            if (-not $destination.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Путь распаковки выходит за пределы временной папки: $($file.RelativePath)" }
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            $inputStream = $null
            $outputStream = $null
            try {
                $inputStream = $file.Entry.Open()
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $inputStream.CopyTo($outputStream)
            } finally {
                if ($outputStream) { $outputStream.Dispose() }
                if ($inputStream) { $inputStream.Dispose() }
            }
        }
        $versionPath = Join-Path $DestinationRoot '.service/version.txt'
        if (([IO.File]::ReadAllText($versionPath).Trim()) -ne $rootVersion) { throw 'Проверка версии после распаковки не прошла.' }
        foreach ($requiredPath in @('bin/winws.exe','bin/WinDivert64.sys')) {
            $requiredFull = Join-Path $DestinationRoot $requiredPath
            if (-not (Test-Path -LiteralPath $requiredFull -PathType Leaf) -or (Get-Item -LiteralPath $requiredFull).Length -le 0) { throw "После распаковки отсутствует или пуст обязательный файл: $requiredPath" }
        }
        return [pscustomobject]@{ Root = $DestinationRoot; Version = $rootVersion; Files = $files.Count }
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Test-ZapretReleaseChecksum {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $manifest = Join-Path (Split-Path -Parent $Path) 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        return [pscustomobject]@{ Verified = $false; Manifest = $null; Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    }
    $leaf = [IO.Path]::GetFileName($Path)
    $checksumEntries = @()
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $manifestMatch = [regex]::Match($line.Trim(), '^(?<hash>[a-fA-F0-9]{64})\s{2,}(?:\*)?(?<name>.+)$')
        if (-not $manifestMatch.Success) { throw 'SHA256SUMS.txt содержит некорректную строку.' }
        if ([string]::Equals([IO.Path]::GetFileName($manifestMatch.Groups['name'].Value), $leaf, [StringComparison]::OrdinalIgnoreCase)) {
            $checksumEntries += $manifestMatch.Groups['hash'].Value
        }
    }
    if ($checksumEntries.Count -ne 1) { throw "В SHA256SUMS.txt должна быть ровно одна контрольная сумма для $leaf." }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if (-not [string]::Equals($actual, [string]$checksumEntries[0], [StringComparison]::OrdinalIgnoreCase)) { throw "SHA-256 архива не совпадает с SHA256SUMS.txt: $leaf" }
    return [pscustomobject]@{ Verified = $true; Manifest = $manifest; Hash = $actual }
}

function Get-ZapretUpdateFilePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot
    )
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($source in (Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force)) {
        $relative = $source.FullName.Substring(([IO.Path]::GetFullPath($SourceRoot).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))).Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/')
        $mode = Get-ZapretPreserveMode -RelativePath $relative
        if ($mode -eq 'Always') { continue }
        $destination = Join-Path $TargetRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ($mode -eq 'IfExists' -and (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }
        $hash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
        $plan.Add([pscustomobject]@{ RelativePath = $relative; SourcePath = $source.FullName; DestinationPath = $destination; Sha256 = $hash })
    }
    if (-not ($plan | Where-Object { $_.RelativePath -ieq 'bin/WinDivert64.sys' })) { throw 'План обновления не содержит bin/WinDivert64.sys.' }
    return $plan.ToArray()
}

function Get-ZapretComparablePath {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $value = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([IO.Path]::DirectorySeparatorChar -eq [char]92) { $value = $value.Replace('/', '\') }
    else { $value = $value.Replace('\', [string][IO.Path]::DirectorySeparatorChar) }
    if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $value = '\\' + $value.Substring(8) }
    elseif ($value.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase) -or $value.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) { $value = $value.Substring(4) }
    try {
        $full = [IO.Path]::GetFullPath($value)
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\','/') }
        return $full
    } catch { return $null }
}

function Get-ZapretCommandExecutablePath {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$CommandLine,
        [AllowNull()][string]$ExpectedExecutable
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $line = $CommandLine.Trim()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExecutable) -and $line.StartsWith($ExpectedExecutable, [StringComparison]::OrdinalIgnoreCase)) {
        if ($line.Length -eq $ExpectedExecutable.Length -or [char]::IsWhiteSpace($line[$ExpectedExecutable.Length])) { return $ExpectedExecutable }
    }
    if ($line.StartsWith('"')) {
        $end = $line.IndexOf('"', 1)
        if ($end -gt 1) { return $line.Substring(1, $end - 1) }
        return $null
    }
    $commandMatch = [regex]::Match($line, '^\s*(?<path>\S+)')
    if ($commandMatch.Success) { return $commandMatch.Groups['path'].Value }
    return $null
}

function Get-ZapretCommandArguments {
    [CmdletBinding()]
    param([AllowNull()][string]$CommandLine, [Parameter(Mandatory = $true)][string]$ExpectedExecutable)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $line = $CommandLine.Trim()
    if ($line.StartsWith('"')) {
        $end = $line.IndexOf('"', 1)
        if ($end -lt 1) { return $null }
        if (-not [string]::Equals($line.Substring(1, $end - 1), $ExpectedExecutable, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $line.Substring($end + 1).Trim()
    }
    if ($line.StartsWith($ExpectedExecutable, [StringComparison]::OrdinalIgnoreCase)) { return $line.Substring($ExpectedExecutable.Length).Trim() }
    return $null
}

function Get-ZapretDriverServices {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][array]$Services, [Parameter(Mandatory = $true)][string]$TargetBin)
    $bin = Get-ZapretComparablePath -Path $TargetBin
    $owned = @()
    foreach ($service in $Services) {
        if ([string]$service.Name -notin @('WinDivert','WinDivert14')) { continue }
        $executable = $null
        foreach ($leaf in @('WinDivert.sys','WinDivert32.sys','WinDivert64.sys','WinDivert14.sys','WinDivert1432.sys','WinDivert1464.sys')) {
            $expected = Get-ZapretComparablePath -Path (Join-Path $TargetBin $leaf)
            $candidate = Get-ZapretCommandExecutablePath -CommandLine ([string]$service.PathName) -ExpectedExecutable $expected
            $candidatePath = Get-ZapretComparablePath -Path $candidate
            if ($candidatePath -and [string]::Equals($candidatePath, $expected, [StringComparison]::OrdinalIgnoreCase)) {
                $executable = $expected
                break
            }
        }
        if (-not $executable) { $executable = Get-ZapretCommandExecutablePath -CommandLine ([string]$service.PathName) }
        $path = Get-ZapretComparablePath -Path $executable
        if (-not $path) { continue }
        $prefix = $bin.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([IO.Path]::GetFileName($path) -notmatch '^(?i:WinDivert(?:14)?(?:32|64)?\.sys)$') { continue }
        $owned += $service
    }
    return $owned
}

function Get-ZapretMatchingWinwsServices {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][array]$Services, [Parameter(Mandatory = $true)][string]$WinwsPath)
    $expected = Get-ZapretComparablePath -Path $WinwsPath
    $matchingServices = @()
    foreach ($service in $Services) {
        $executable = Get-ZapretCommandExecutablePath -CommandLine ([string]$service.PathName) -ExpectedExecutable $expected
        $path = Get-ZapretComparablePath -Path $executable
        if ($path -and [string]::Equals($path, $expected, [StringComparison]::OrdinalIgnoreCase)) { $matchingServices += $service }
    }
    return $matchingServices
}

function Get-ZapretMatchingWinwsProcesses {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WinwsPath)
    $expected = Get-ZapretComparablePath -Path $WinwsPath
    $found = @()
    foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='winws.exe'" -ErrorAction Stop)) {
        $executable = [string]$process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($executable)) {
            $executable = Get-ZapretCommandExecutablePath -CommandLine ([string]$process.CommandLine) -ExpectedExecutable $expected
        }
        if ([string]::IsNullOrWhiteSpace($executable)) { throw "Не удалось определить путь процесса winws.exe (PID $($process.ProcessId)); ничего не заменяю." }
        $path = Get-ZapretComparablePath -Path $executable
        if ($path -and [string]::Equals($path, $expected, [StringComparison]::OrdinalIgnoreCase)) { $found += $process }
    }
    return $found
}

function Get-ZapretServiceRecordByName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9_.-]+$') { throw "Недопустимое имя службы Windows: $Name" }
    return (Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction Stop)
}

function Wait-ZapretServiceState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$State, [int]$TimeoutSec = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    do {
        $record = Get-ZapretServiceRecordByName -Name $Name
        if (-not $record -or [string]$record.State -eq $State) { return $true }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Wait-ZapretWinwsStopped {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WinwsPath, [int]$TimeoutSec = 15)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    do {
        if (@(Get-ZapretMatchingWinwsProcesses -WinwsPath $WinwsPath).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return (@(Get-ZapretMatchingWinwsProcesses -WinwsPath $WinwsPath).Count -eq 0)
}

function Stop-ZapretRuntimeForUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TargetRoot, [Parameter(Mandatory = $true)][hashtable]$RuntimeState)
    $winwsPath = Join-Path $TargetRoot 'bin/winws.exe'
    $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    $zapretServices = @(Get-ZapretMatchingWinwsServices -Services $services -WinwsPath $winwsPath)
    $servicePids = @($zapretServices | Where-Object { [int]$_.ProcessId -gt 0 } | ForEach-Object { [int]$_.ProcessId })
    $processes = @(Get-ZapretMatchingWinwsProcesses -WinwsPath $winwsPath)
    foreach ($service in $zapretServices) {
        $wasRunning = ([string]$service.State -ne 'Stopped')
        $RuntimeState.Services.Add([pscustomobject]@{ Name = [string]$service.Name; WasRunning = $wasRunning })
    }
    foreach ($process in $processes) {
        if ([int]$process.ProcessId -in $servicePids) { continue }
        $arguments = Get-ZapretCommandArguments -CommandLine ([string]$process.CommandLine) -ExpectedExecutable $winwsPath
        if ($null -eq $arguments) { throw "Не удалось безопасно сохранить параметры вручную запущенного winws.exe (PID $($process.ProcessId)); ничего не заменяю." }
        $RuntimeState.ManualProcesses.Add([pscustomobject]@{ Arguments = [string]$arguments })
    }
    $driverServices = @(Get-ZapretDriverServices -Services $services -TargetBin (Join-Path $TargetRoot 'bin'))
    foreach ($service in $driverServices) {
        $RuntimeState.DriverServices.Add([pscustomobject]@{ Name = [string]$service.Name; WasRunning = ([string]$service.State -ne 'Stopped') })
    }
    # Закрываю панель/трей ПЕРВЫМ делом — они держат Zapret-Control.ps1/Update-Zapret.ps1
    # (в 2.9.13 панель не закрывалась сама, из-за чего апдейт падал с кодом 1)
    foreach ($leaf in @('Zapret-Control.exe','Zapret-Tray.exe')) {
        $exePath = Join-Path $TargetRoot $leaf
        if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { continue }
        try {
            $comparable = $exePath
            try { $comparable = [IO.Path]::GetFullPath($exePath).TrimEnd('\\','/') } catch { }
            foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
                $pPath = $null
                try { $pPath = $proc.Path } catch { continue }
                if (-not $pPath) { continue }
                $pComp = $pPath
                try { $pComp = [IO.Path]::GetFullPath($pPath).TrimEnd('\\','/') } catch { }
                if ([string]::Equals($pComp, $comparable, [StringComparison]::OrdinalIgnoreCase)) {
                    Write-Host ("Закрываю $leaf (PID $($proc.Id)) для обновления...") -ForegroundColor Yellow
                    try { $null = $proc.CloseMainWindow() } catch { }
                    for ($w = 0; $w -lt 15; $w++) {
                        if ($proc.HasExited) { break }
                        Start-Sleep -Milliseconds 200
                        try { $proc.Refresh() } catch { break }
                    }
                    if (-not $proc.HasExited) {
                        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
                        Start-Sleep -Milliseconds 500
                    }
                }
            }
        } catch { }
    }
    Start-Sleep -Milliseconds 300

    foreach ($service in $RuntimeState.Services) {
        if (-not $service.WasRunning) { continue }
        Write-Host ("Останавливаю службу '{0}', использующую этот winws.exe..." -f $service.Name) -ForegroundColor Yellow
        Stop-Service -Name $service.Name -Force -ErrorAction Stop
        if (-not (Wait-ZapretServiceState -Name $service.Name -State 'Stopped' -TimeoutSec 20)) { throw "Служба '$($service.Name)' не остановилась; файлы не заменены." }
    }
    foreach ($process in $processes) {
        if ([int]$process.ProcessId -in $servicePids) { continue }
        Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
    }
    if (-not (Wait-ZapretWinwsStopped -WinwsPath $winwsPath -TimeoutSec 15)) { throw 'Процессы winws.exe этой папки не остановились; файлы не заменены.' }
    foreach ($service in $RuntimeState.DriverServices) {
        if (-not $service.WasRunning) { continue }
        Write-Host ("Выгружаю принадлежащий этой папке драйвер-службу '{0}'..." -f $service.Name) -ForegroundColor Yellow
        Stop-Service -Name $service.Name -Force -ErrorAction Stop
        if (-not (Wait-ZapretServiceState -Name $service.Name -State 'Stopped' -TimeoutSec 15)) { throw "Драйвер-служба '$($service.Name)' не остановилась; файлы не заменены." }
    }

}

function Restore-ZapretRuntimeAfterUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TargetRoot, [Parameter(Mandatory = $true)][hashtable]$RuntimeState)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($service in $RuntimeState.Services) {
        if (-not $service.WasRunning) { continue }
        try {
            $current = Get-ZapretServiceRecordByName -Name $service.Name
            if ($current -and [string]$current.State -ne 'Running') {
                Start-Service -Name $service.Name -ErrorAction Stop
                if (-not (Wait-ZapretServiceState -Name $service.Name -State 'Running' -TimeoutSec 20)) { throw 'тайм-аут запуска' }
            }
        } catch { $errors.Add(("служба {0}: {1}" -f $service.Name, $_.Exception.Message)) }
    }
    $winwsPath = Join-Path $TargetRoot 'bin/winws.exe'
    foreach ($manual in $RuntimeState.ManualProcesses) {
        try {
            Start-Process -FilePath $winwsPath -ArgumentList $manual.Arguments -WorkingDirectory (Split-Path -Parent $winwsPath) -WindowStyle Hidden -ErrorAction Stop | Out-Null
        } catch { $errors.Add(("ручной winws.exe: {0}" -f $_.Exception.Message)) }
    }
    foreach ($service in $RuntimeState.DriverServices) {
        if (-not $service.WasRunning) { continue }
        try {
            $current = Get-ZapretServiceRecordByName -Name $service.Name
            if ($current -and [string]$current.State -ne 'Running') { Start-Service -Name $service.Name -ErrorAction Stop }
        } catch { $errors.Add(("драйвер-служба {0}: {1}" -f $service.Name, $_.Exception.Message)) }
    }
    return $errors.ToArray()
}

function Test-ZapretFileExclusiveAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$RelativePath)
    $lastError = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $stream = $null
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return
        } catch { $lastError = $_.Exception.Message }
        finally { if ($stream) { $stream.Dispose() } }
        if ($attempt -lt 2) { Start-Sleep -Milliseconds 1200 }
    }
    throw "Файл '$RelativePath' занят или недоступен ($lastError). Ничего не заменено. Закройте использующую его программу и повторите."
}

function Test-ZapretDriverReplaceability {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $probe = Join-Path (Split-Path -Parent $Path) ('.WinDivert64.sys.replace-check-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::Move($Path, $probe)
        [IO.File]::Move($probe, $Path)
    } catch {
        $renameError = $_.Exception.Message
        $restoreError = $null
        if ((Test-Path -LiteralPath $probe -PathType Leaf) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            try { [IO.File]::Move($probe, $Path) }
            catch { $restoreError = $_.Exception.Message }
        }
        if ($restoreError) { throw ("Не удалось вернуть WinDivert64.sys в исходное имя. Файл сохранён по пути '{0}'. Ошибка возврата: {1}" -f $probe, $restoreError) }
        throw ("WinDivert64.sys всё ещё занят или не может быть переименован. Файлы проекта не заменены. Закройте программы, использующие WinDivert, и повторите. Подробность: {0}" -f $renameError)
    }
}

function Test-ZapretUpdatePreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][array]$Files)
    foreach ($file in $Files) {
        if (Test-Path -LiteralPath $file.DestinationPath) {
            if (-not (Test-Path -LiteralPath $file.DestinationPath -PathType Leaf)) { throw "Путь назначения уже занят папкой или другим объектом: $($file.RelativePath). Файлы не заменены." }
            Test-ZapretFileExclusiveAccess -Path $file.DestinationPath -RelativePath $file.RelativePath
        }
    }
    $driver = @($Files | Where-Object { $_.RelativePath -ieq 'bin/WinDivert64.sys' } | Select-Object -First 1)
    if ($driver.Count -ne 1) { throw 'План обновления не содержит единственного файла WinDivert64.sys.' }
    Test-ZapretDriverReplaceability -Path $driver[0].DestinationPath
}

function Invoke-ZapretFileTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][array]$Files,
        [Parameter(Mandatory = $true)][string]$WorkRoot
    )
    $journal = New-Object 'System.Collections.Generic.List[object]'
    $backupRoot = Join-Path $WorkRoot 'backup'
    $failedRoot = Join-Path $WorkRoot 'failed-new'
    $ordered = @($Files | Where-Object { $_.RelativePath -ieq 'bin/WinDivert64.sys' }) + @($Files | Where-Object { $_.RelativePath -ine 'bin/WinDivert64.sys' } | Sort-Object RelativePath)
    try {
        foreach ($file in $ordered) {
            $destination = [string]$file.DestinationPath
            $source = [string]$file.SourcePath
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $backup = Join-Path $backupRoot ($file.RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
                $backupParent = Split-Path -Parent $backup
                if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
                $journal.Add([pscustomobject]@{ Destination = $destination; Backup = $backup; Created = $false })
                [IO.File]::Replace($source, $destination, $backup)
            } else {
                $journal.Add([pscustomobject]@{ Destination = $destination; Backup = $null; Created = $true })
                [IO.File]::Move($source, $destination)
            }
        }
        foreach ($file in $Files) {
            $actualHash = (Get-FileHash -LiteralPath $file.DestinationPath -Algorithm SHA256).Hash
            if (-not [string]::Equals($actualHash, [string]$file.Sha256, [StringComparison]::OrdinalIgnoreCase)) { throw "Проверка контрольной суммы после замены не прошла: $($file.RelativePath)" }
        }
        return [pscustomobject]@{ Succeeded = $true; RollbackComplete = $true; Error = $null }
    } catch {
        $originalError = $_.Exception.Message
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        for ($index = $journal.Count - 1; $index -ge 0; $index--) {
            $item = $journal[$index]
            try {
                if ($item.Created) {
                    if (Test-Path -LiteralPath $item.Destination -PathType Leaf) { [IO.File]::Delete($item.Destination) }
                } elseif ($item.Backup -and (Test-Path -LiteralPath $item.Backup -PathType Leaf)) {
                    if (Test-Path -LiteralPath $item.Destination -PathType Leaf) {
                        $failed = Join-Path $failedRoot ($item.Destination.Substring(([IO.Path]::GetPathRoot($item.Destination)).Length).TrimStart('\','/'))
                        $failedParent = Split-Path -Parent $failed
                        if (-not (Test-Path -LiteralPath $failedParent -PathType Container)) { New-Item -ItemType Directory -Path $failedParent -Force | Out-Null }
                        [IO.File]::Replace($item.Backup, $item.Destination, $failed)
                    } else {
                        [IO.File]::Move($item.Backup, $item.Destination)
                    }
                }
            } catch { $rollbackErrors.Add(("{0}: {1}" -f $item.Destination, $_.Exception.Message)) }
        }
        if ($rollbackErrors.Count -gt 0) {
            return [pscustomobject]@{ Succeeded = $false; RollbackComplete = $false; Error = ($originalError + ' Резервное восстановление не завершено: ' + ($rollbackErrors -join '; ')) }
        }
        return [pscustomobject]@{ Succeeded = $false; RollbackComplete = $true; Error = ($originalError + ' Все заменённые файлы восстановлены.') }
    }
}

function Test-ZapretUpdaterAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Start-ZapretUpdaterElevated {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [Parameter(Mandatory = $true)][string]$ArchivePath, [Parameter(Mandatory = $true)][string]$TargetRoot, [switch]$NoPause, [switch]$AssumeYes)
    $escape = { param([string]$Value) return $Value.Replace("'", "''") }
    $scriptValue = & $escape $ScriptPath
    $archiveValue = & $escape $ArchivePath
    $targetValue = & $escape $TargetRoot
    $pauseArgument = if ($NoPause) { ' -NoPause' } else { '' }
    $assumeArgument = if ($AssumeYes) { ' -AssumeYes' } else { '' }
    $command = "& '$scriptValue' -ArchivePath '$archiveValue' -TargetRoot '$targetValue' -Elevated$pauseArgument$assumeArgument"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { throw 'Не найден Windows PowerShell 5.1.' }
    $process = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList (('-NoProfile -ExecutionPolicy Bypass -EncodedCommand {0}' -f $encoded)) -Wait -PassThru -ErrorAction Stop
    return [int]$process.ExitCode
}

function Show-ZapretOpenFileDialog {
    param([string]$InitialDirectory)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Выберите ZIP-архив новой версии zapret'
        $dialog.Filter = 'ZIP-архивы (*.zip)|*.zip|Все файлы (*.*)|*.*'
        $dialog.Multiselect = $false
        if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) { $dialog.InitialDirectory = $InitialDirectory }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
        return $null
    } catch {
        return (Read-Host 'Введите полный путь к ZIP-архиву (Enter — отмена)')
    }
}

function Show-ZapretFolderDialog {
    param([string]$InitialDirectory)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Выберите существующую папку zapret, которую нужно обновить. Папка установки останется на месте.'
        $dialog.ShowNewFolderButton = $false
        if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory -PathType Container)) { $dialog.SelectedPath = $InitialDirectory }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    } catch {
        return (Read-Host 'Введите полный путь к существующей папке zapret (Enter — отмена)')
    }
}

function Invoke-ZapretUpdate {
    [CmdletBinding()]
    param([string]$ArchivePath, [string]$TargetRoot, [switch]$Elevated, [switch]$NoPause, [switch]$AssumeYes)
    $platformIsWindows = $true
    if ($PSVersionTable.PSVersion.Major -ge 6) { $platformIsWindows = [bool]$IsWindows }
    if (-not $platformIsWindows) { throw 'Обновление zapret поддерживается только в Windows.' }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = Show-ZapretOpenFileDialog -InitialDirectory (Get-Location).Path }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { Write-Host 'Обновление отменено.' -ForegroundColor Yellow; return 0 }
    $ArchivePath = (Resolve-Path -LiteralPath $ArchivePath -ErrorAction Stop).Path
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        $TargetRoot = Show-ZapretFolderDialog -InitialDirectory $PSScriptRoot
    }
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) { Write-Host 'Обновление отменено.' -ForegroundColor Yellow; return 0 }
    $TargetRoot = (Resolve-Path -LiteralPath $TargetRoot -ErrorAction Stop).Path
    if (-not (Test-ZapretInstallRoot -Path $TargetRoot)) { throw 'Выбранная папка не похожа на существующую установку zapret: не хватает обязательных файлов.' }

    $checksum = Test-ZapretReleaseChecksum -Path $ArchivePath
    if (-not $checksum.Verified) {
        if ($AssumeYes) { throw 'Обновление отменено: контрольная сумма ZIP не подтверждена файлом SHA256SUMS.txt (автоматический режим не пропускает проверку).' }
        $answer = Read-Host 'Рядом с ZIP нет SHA256SUMS.txt: контрольная сумма не подтверждена. Продолжить всё равно? [д/Н]'
        if (-not $answer -or $answer.Trim() -notmatch '^(?i:y|yes|д|да)$') { throw 'Отменено: сначала скачайте SHA256SUMS.txt рядом с архивом.' }
        Write-Warning ("SHA-256 архива (не сверена): {0}" -f $checksum.Hash)
    } else {
        Write-Host 'Контрольная сумма ZIP совпадает с SHA256SUMS.txt.' -ForegroundColor Green
    }

    $currentVersion = [IO.File]::ReadAllText((Join-Path $TargetRoot '.service/version.txt')).Trim()
    [void](Get-ZapretVersionParts -Version $currentVersion)
    if (-not (Test-ZapretUpdaterAdmin)) {
        if ($Elevated) { throw 'Повышенные права администратора не получены.' }
        Write-Host 'Запрашиваю права администратора Windows для безопасной проверки и замены файлов...'
        $elevatedExitCode = Start-ZapretUpdaterElevated -ScriptPath $PSCommandPath -ArchivePath $ArchivePath -TargetRoot $TargetRoot -NoPause:$NoPause
        if (-not $NoPause) { $script:ZapretUpdateChildHandledPause = $true }
        return $elevatedExitCode
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $workRoot = Join-Path $TargetRoot ('.zapret-update-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    $script:ZapretUpdateWorkRoot = $workRoot
    $script:ZapretUpdateKeepWork = $false
    try { (Get-Item -LiteralPath $workRoot -Force).Attributes = (Get-Item -LiteralPath $workRoot -Force).Attributes -bor [IO.FileAttributes]::Hidden }
    catch { Write-Verbose ("Could not hide the temporary updater directory: {0}" -f $_.Exception.Message) }
    $stageRoot = Join-Path $workRoot 'new'
    $archiveInfo = Expand-ZapretReleaseArchive -Path $ArchivePath -DestinationRoot $stageRoot
    $comparison = Compare-ZapretVersions -Left $archiveInfo.Version -Right $currentVersion
    if ($comparison -lt 0) { throw "ZIP содержит более старую версию $($archiveInfo.Version); установленная версия $currentVersion. Понижение версии этим updater не поддерживается." }
    Write-Host ''
    Write-Host ("Каталог останется прежним: {0}" -f $TargetRoot) -ForegroundColor Cyan
    Write-Host ("Версия: {0} -> {1}; подготовлено файлов в ZIP: {2}" -f $currentVersion, $archiveInfo.Version, $archiveInfo.Files) -ForegroundColor Cyan
    Write-Host 'config.json, логи, пользовательские списки, пользовательские стратегии и выбранные ACTIVE_*.bin сохраняются.' -ForegroundColor Gray
    Write-Host 'Служба/процесс временно остановятся; если WinDivert64.sys не освободится, замена не начнётся.' -ForegroundColor Gray
    if (-not $AssumeYes) {
        $confirm = Read-Host 'Продолжить безопасное обновление в этом же каталоге? [д/Н]'
        if (-not $confirm -or $confirm.Trim() -notmatch '^(?i:y|yes|д|да)$') {
            Write-Host 'Обновление отменено.' -ForegroundColor Yellow
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
            $script:ZapretUpdateWorkRoot = $null
            return 0
        }
    }

    $files = @(Get-ZapretUpdateFilePlan -SourceRoot $stageRoot -TargetRoot $TargetRoot)
    $runtimeState = @{
        Services = (New-Object 'System.Collections.Generic.List[object]')
        ManualProcesses = (New-Object 'System.Collections.Generic.List[object]')
        DriverServices = (New-Object 'System.Collections.Generic.List[object]')
    }
    $runtimeTouched = $true
    $rollbackIncomplete = $false
    $keepWork = $false
    $updateSucceeded = $false
    $runtimeRestoreFailed = $false
    try {
        Stop-ZapretRuntimeForUpdate -TargetRoot $TargetRoot -RuntimeState $runtimeState
        Write-Host 'Проверяю, что все заменяемые файлы доступны...' -ForegroundColor Yellow
        Test-ZapretUpdatePreflight -Files $files
        Write-Host 'Все проверки пройдены; начинаю транзакционную замену файлов...' -ForegroundColor Yellow
        $transaction = Invoke-ZapretFileTransaction -Files $files -WorkRoot $workRoot
        if (-not $transaction.Succeeded) {
            if (-not $transaction.RollbackComplete) {
                $keepWork = $true
                $rollbackIncomplete = $true
                $script:ZapretUpdateKeepWork = $true
            }
            throw ("Обновление не завершено. {0}" -f $transaction.Error)
        }
        $updateSucceeded = $true
        Write-Host ("Файлы обновлены до версии {0}." -f $archiveInfo.Version) -ForegroundColor Green
    } catch {
        if ($rollbackIncomplete) {
            Write-Warning ("Транзакционный откат не завершён. Службы не запускаю, чтобы не использовать смешанные версии. Резервные файлы сохранены в: {0}" -f $workRoot)
        } elseif ($runtimeTouched) {
            Write-Warning 'Обновление остановлено; пытаюсь вернуть прежнее состояние обхода.'
            $restoreErrors = @(Restore-ZapretRuntimeAfterUpdate -TargetRoot $TargetRoot -RuntimeState $runtimeState)
            foreach ($restoreError in $restoreErrors) { Write-Warning ("Не удалось полностью восстановить прежний запуск: {0}" -f $restoreError) }
        }
        throw
    }

    if ($updateSucceeded -and $runtimeTouched) {
        $restoreErrors = @(Restore-ZapretRuntimeAfterUpdate -TargetRoot $TargetRoot -RuntimeState $runtimeState)
        if ($restoreErrors.Count -eq 0) {
            Write-Host 'Прежний режим запуска восстановлен.' -ForegroundColor Green
        } else {
            Write-Warning 'Файлы обновлены, но прежний обход не удалось полностью запустить:'
            foreach ($restoreError in $restoreErrors) { Write-Warning ("  {0}" -f $restoreError) }
            $runtimeRestoreFailed = $true
            $keepWork = $true
            $script:ZapretUpdateKeepWork = $true
            Write-Warning ("Временная папка с резервными файлами сохранена: {0}" -f $workRoot)
        }
    }
    if (-not $keepWork -and (Test-Path -LiteralPath $workRoot)) {
        try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning ("Не удалось удалить временную папку обновления: {0}" -f $workRoot) }
    }
    if (-not $keepWork) { $script:ZapretUpdateWorkRoot = $null }
    Write-Host ''
    if ($runtimeRestoreFailed) {
        Write-Host 'Файлы обновлены, но прежний обход не удалось запустить полностью. Проверьте предупреждения выше; временная папка сохранена для восстановления.' -ForegroundColor Yellow
        return 2
    }
    Write-Host ("Готово. Каталог установки не переносился: {0}" -f $TargetRoot) -ForegroundColor Green
    return 0
}

if ($NoRun) { return }

$exitCode = 0
try {
    $exitCode = Invoke-ZapretUpdate -ArchivePath $ArchivePath -TargetRoot $TargetRoot -Elevated:$Elevated -NoPause:$NoPause -AssumeYes:$AssumeYes
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host ("Не удалось обновить zapret: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($script:ZapretUpdateWorkRoot -and -not $script:ZapretUpdateKeepWork -and (Test-Path -LiteralPath $script:ZapretUpdateWorkRoot)) {
        Remove-Item -LiteralPath $script:ZapretUpdateWorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (-not $NoPause -and -not $AssumeYes -and -not $script:ZapretUpdateChildHandledPause) {
    try { [void](Read-Host 'Нажмите Enter, чтобы закрыть окно') }
    catch { Write-Verbose 'No interactive host is available for the final pause.' }
}
exit $exitCode
