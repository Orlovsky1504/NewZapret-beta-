#requires -Version 5.1
<#
.SYNOPSIS
    Builds a clean, versioned release directory and UTF-8 ZIP from this Git checkout.
.DESCRIPTION
    Copies only tracked runtime/resources and approved top-level release files.
    User state, logs, tests, GitHub metadata, and old archives are never included.
    The required mobile app list is included explicitly because older working trees
    may have it present but not yet tracked. Existing output is never overwritten.
.EXAMPLE
    pwsh -NoProfile -File tools/Build-Release.ps1 -Version 2.1.7 -OutputDirectory ./dist
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$Version,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

function Test-ChecksumManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$BaseDirectory
    )
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Checksum manifest is missing: $ManifestPath" }
    $verified = 0
    foreach ($line in [IO.File]::ReadAllLines($ManifestPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line, '^(?<hash>[a-fA-F0-9]{64})  (?<name>[^*]+)$')
        if (-not $match.Success) { throw 'Checksum manifest contains a malformed line.' }
        $name = $match.Groups['name'].Value
        if ([IO.Path]::IsPathRooted($name) -or [IO.Path]::GetFileName($name) -cne $name -or $name -match '[/\\]') {
            throw "Unsafe path in checksum manifest: $name"
        }
        $target = Join-Path $BaseDirectory $name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Checksum target is missing: $name" }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not [string]::Equals($actual, $match.Groups['hash'].Value, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Checksum mismatch: $name"
        }
        $verified++
    }
    if ($verified -eq 0) { throw 'Checksum manifest contains no entries.' }
    return $true
}

function Test-ZipEntryHasUtf8NameFlag {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EntryName
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
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
            # Bit 11 is the UTF-8 filename flag in the central-directory header.
            return (([int]$bytes[$offset + 9] -band 0x08) -ne 0)
        }
        $offset = $nextHeaderOffset - 1
    }
    return $false
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$versionFile = Join-Path $repoRoot '.service/version.txt'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw 'Missing .service/version.txt; cannot determine the release version.'
}
$sourceVersion = [IO.File]::ReadAllText($versionFile).Trim()
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $sourceVersion }
if ($Version -notmatch '^\d+\.\d+\.\d+[A-Za-z]?(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid release version '$Version'. Expected X.Y.Z or X.Y.Z-prerelease."
}
if ($Version -ne $sourceVersion) {
    throw "Release version '$Version' does not match .service/version.txt ('$sourceVersion')."
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'build'
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$releaseName = "zapret-discord-youtube-$Version"
$destination = Join-Path $outputRoot $releaseName
$archivePath = Join-Path $outputRoot ($releaseName + '.zip')
$manifestPath = Join-Path $outputRoot 'SHA256SUMS.txt'
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $manifestPath)) {
    throw "Release output already exists ($destination, $archivePath, or $manifestPath). Choose another output directory or remove only those generated outputs first."
}

$packageDirectories = @('bin', 'lists', 'utils', 'src', '.service')
$modulePartFiles = @(
    'src/parts/Zapret.Runtime.ps1', 'src/parts/Zapret.Strategies.ps1',
    'src/parts/Zapret.IpsetHosts.ps1', 'src/parts/Zapret.Diagnostics.ps1',
    'src/parts/Zapret.AutoSelect.ps1', 'src/parts/Zapret.Dns.ps1',
    'src/parts/Zapret.Network.ps1', 'src/parts/Zapret.Automation.ps1',
    'src/parts/Zapret.Support.ps1', 'src/parts/Zapret.Maintenance.ps1',
    'src/parts/Zapret.Rollback.ps1', 'src/parts/Zapret.UserStrategies.ps1',
    'src/parts/Zapret.Watchdog.ps1',
    'src/parts/Zapret.Doctor.ps1'
)
$packageRootFiles = @(
    'strategies.json', 'zapret.ps1', 'zapret.bat', 'service.bat',
    'Zapret-Control.ps1', 'Zapret-Control.bat', 'Zapret-Control.ico', 'Zapret-Control.exe',
    'Zapret-Tray.exe',
    'Update-Zapret.ps1', 'Update-Zapret.bat',
    'README.md', 'LICENSE.txt', 'CHANGELOG.md', 'ИНСТРУКЦИЯ.txt', 'lists/ipset-telegram.txt'
) + $modulePartFiles
$requiredFiles = @(
    'strategies.json', 'zapret.ps1', 'zapret.bat', 'service.bat',
    'Zapret-Control.ps1', 'Zapret-Control.bat', 'Zapret-Control.ico', 'Zapret-Control.exe',
    'Update-Zapret.ps1', 'Update-Zapret.bat',
    'src/Zapret.psm1', '.service/version.txt', 'bin/winws.exe', 'bin/WinDivert.dll', 'bin/WinDivert64.sys',
    'lists/list-mobile-apps.txt', 'lists/ipset-telegram.txt', 'ИНСТРУКЦИЯ.txt'
) + $modulePartFiles
$excludedFiles = @(
    'lists/ipset-exclude-user.txt', 'lists/list-general-user.txt',
    'lists/list-exclude-user.txt', 'utils/game_filter.enabled', 'utils/test results'
)

# Use Git's tracked-file list to avoid accidentally bundling ignored user data or
# arbitrary files added to bin/lists/utils locally. Root docs/entry points are a
# small explicit allow-list; the mobile and IP lists are required runtime assets.
$trackedFiles = @(& git -C $repoRoot ls-files)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not list tracked files. Run this developer tool from a Git checkout with Git installed.'
}
$selected = New-Object 'System.Collections.Generic.List[string]'
foreach ($trackedPath in $trackedFiles) {
    $relativePath = ([string]$trackedPath).Replace('\', '/')
    $isPackageFile = $false
    foreach ($directory in $packageDirectories) {
        if ($relativePath.StartsWith(($directory + '/'), [StringComparison]::Ordinal)) {
            $isPackageFile = $true
            break
        }
    }
    if (-not $isPackageFile) { continue }
    if ($relativePath -in $excludedFiles) { continue }
    if ($relativePath -match '(?i)\.(zip|rar|7z|tar|gz)$') { continue }
    if (-not $selected.Contains($relativePath)) { [void]$selected.Add($relativePath) }
}
foreach ($relativePath in $packageRootFiles + @('lists/list-mobile-apps.txt')) {
    if (-not $selected.Contains($relativePath)) { [void]$selected.Add($relativePath) }
}

foreach ($requiredPath in $requiredFiles) {
    if (-not $selected.Contains($requiredPath)) {
        throw "Required release file is not in the package manifest: $requiredPath"
    }
}
foreach ($relativePath in $selected) {
    if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|/)\.\.?(/|$)') {
        throw "Unsafe path in release manifest: $relativePath"
    }
    $sourcePath = Join-Path $repoRoot ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required package file is missing: $relativePath"
    }
}

if (-not $PSCmdlet.ShouldProcess(($destination + ', ' + $archivePath + ', and ' + $manifestPath), 'Build clean release directory, ZIP, and SHA256 manifest')) {
    return
}
if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
}

$staging = Join-Path $outputRoot ('.{0}.stage-{1}' -f $releaseName, [Guid]::NewGuid().ToString('N'))
$temporaryZip = Join-Path $outputRoot ('.{0}.zip-stage-{1}.zip' -f $releaseName, [Guid]::NewGuid().ToString('N'))
$temporaryManifest = Join-Path $outputRoot ('.SHA256SUMS-stage-{0}.txt' -f [Guid]::NewGuid().ToString('N'))
$destinationCreated = $false
$archiveCreated = $false
$manifestCreated = $false
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($relativePath in $selected) {
        $sourcePath = Join-Path $repoRoot ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $destinationPath = Join-Path $staging ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $parent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipArchive = $null
    try {
        $zipArchive = [IO.Compression.ZipFile]::Open($temporaryZip, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($file in (Get-ChildItem -LiteralPath $staging -File -Recurse -Force)) {
            $relativeEntry = $file.FullName.Substring($staging.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/')
            $entryName = '{0}/{1}' -f $releaseName, $relativeEntry
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zipArchive, $file.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal
            )
        }
    } finally {
        if ($zipArchive) { $zipArchive.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $temporaryZip -PathType Leaf) -or (Get-Item -Force -LiteralPath $temporaryZip).Length -le 0) {
        throw 'Release ZIP was not created.'
    }
    $checkZip = [IO.Compression.ZipFile]::OpenRead($temporaryZip)
    try {
        $zipNames = @($checkZip.Entries | ForEach-Object { $_.FullName })
        $expectedZipNames = @($selected | ForEach-Object { '{0}/{1}' -f $releaseName, $_ })
        $missingZipEntries = @($expectedZipNames | Where-Object { $_ -notin $zipNames })
        $unexpectedZipEntries = @($zipNames | Where-Object { $_ -notin $expectedZipNames })
        if ($missingZipEntries.Count -gt 0 -or $unexpectedZipEntries.Count -gt 0) {
            throw 'Release ZIP manifest does not match the staged package.'
        }
        $instructionEntryName = $releaseName + '/ИНСТРУКЦИЯ.txt'
        if ($zipNames -notcontains $instructionEntryName) {
            throw 'Release ZIP does not contain the correctly encoded Russian instruction filename.'
        }
        if (-not (Test-ZipEntryHasUtf8NameFlag -Path $temporaryZip -EntryName $instructionEntryName)) {
            throw 'Release ZIP does not mark the Russian instruction filename with the UTF-8 flag.'
        }
    } finally {
        $checkZip.Dispose()
    }

    if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $manifestPath)) {
        throw 'Release output appeared during packaging; refusing to overwrite it.'
    }
    Move-Item -LiteralPath $staging -Destination $destination
    $destinationCreated = $true
    Move-Item -LiteralPath $temporaryZip -Destination $archivePath
    $archiveCreated = $true

    $zipHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $manifestLine = '{0}  {1}' -f $zipHash, [IO.Path]::GetFileName($archivePath)
    [IO.File]::WriteAllText($temporaryManifest, $manifestLine + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    if (-not (Test-ChecksumManifest -ManifestPath $temporaryManifest -BaseDirectory $outputRoot)) {
        throw 'SHA256 manifest verification failed.'
    }
    if (Test-Path -LiteralPath $manifestPath) { throw 'SHA256SUMS.txt appeared during packaging; refusing to overwrite it.' }
    Move-Item -LiteralPath $temporaryManifest -Destination $manifestPath
    $manifestCreated = $true
} catch {
    if ($manifestCreated -and (Test-Path -LiteralPath $manifestPath)) {
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    }
    if ($archiveCreated -and (Test-Path -LiteralPath $archivePath)) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    }
    if ($destinationCreated -and (Test-Path -LiteralPath $destination)) {
        Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $temporaryZip) {
        Remove-Item -LiteralPath $temporaryZip -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $temporaryManifest) {
        Remove-Item -LiteralPath $temporaryManifest -Force -ErrorAction SilentlyContinue
    }
    throw
}

Write-Output $archivePath
