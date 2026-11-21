#requires -Version 5.1
<#
.SYNOPSIS
    Dev-Tools для удобства разработчика OpenZapret.
.DESCRIPTION
    Одна точка входа для частых задач: быстрый bump версии, build+hash, проверка
    wiring/gates, нормализация EOL/BOM, просмотр логов релиза.
    Не требует админ-прав. Работает на Linux/PowerShell 7 и Windows 5.1.
.EXAMPLE
    pwsh -File tools/Dev-Tools.ps1 bump 3.0.18
    pwsh -File tools/Dev-Tools.ps1 build
    pwsh -File tools/Dev-Tools.ps1 gates
    pwsh -File tools/Dev-Tools.ps1 bump 3.0.18 --push
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Action,
    [Parameter(Position=1)][string]$Version,
    [switch]$Push
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location $repoRoot

function Write-Step { param([string]$Text) Write-Host "`n== $Text ==" -ForegroundColor Cyan }
function Write-Ok2 { param([string]$Text) Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Fail2 { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red }

if (-not $Action) {
    Write-Host @"
Dev-Tools — инструменты разработчика:

  bump <X.Y.Z> [--push]  Бамп version.txt/.service/version.txt/.rc/README/CHANGELOG + build + manifest
  build                  Только Build-Release + SHA (без бампа)
  gates                  9 гейтов: parse/static/wiring/tests/harness/bug-hunt1-3/PSScriptAnalyzer + bug-hunt4 + gui
  normalize              Нормализовать EOL (CRLF для ps1/bat/txt/md, LF для json) + BOM
  release-status         Статус последних 3 GitHub Actions runs + manifest vs release SHA
  help                   Эта справка

Примеры:
  pwsh -File tools/Dev-Tools.ps1 bump 3.0.18
  pwsh -File tools/Dev-Tools.ps1 bump 3.0.18 --push
  pwsh -File tools/Dev-Tools.ps1 gates
"@
    return
}

if ($Action -in @('help','--help','-h')) { Write-Host @"
Dev-Tools: bump/build/gates/normalize/release-status
"@; return }

# --- bump ---
if ($Action -eq 'bump') {
    if (-not $Version -or $Version -notmatch '^\d+\.\d+\.\d+') { throw "Укажите версию X.Y.Z: bump 3.0.18" }
    $oldVer = ([IO.File]::ReadAllText((Join-Path $repoRoot '.service/version.txt'))).Trim()
    Write-Step "Bump $oldVer -> $Version"
    # version files
    [IO.File]::WriteAllText((Join-Path $repoRoot 'version.txt'), "$Version`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $repoRoot '.service/version.txt'), "$Version`n", (New-Object Text.UTF8Encoding($false)))
    # .rc
    $rc = Join-Path $repoRoot 'tools/zapret-control.rc'
    $rcText = [IO.File]::ReadAllText($rc)
    $oldRc = $oldVer -replace '\.',','
    $newRc = $Version -replace '\.',','
    $rcText = $rcText.Replace("$oldRc,0", "$newRc,0").Replace($oldVer, $Version)
    [IO.File]::WriteAllText($rc, $rcText, (New-Object Text.UTF8Encoding($false)))
    # README badge/link
    $readme = Join-Path $repoRoot 'README.md'
    $rt = [IO.File]::ReadAllText($readme)
    $rt = $rt.Replace("версия-$oldVer", "версия-$Version").Replace("/download/$oldVer/", "/download/$Version/").Replace("zapret-discord-youtube-$oldVer.zip", "zapret-discord-youtube-$Version.zip")
    [IO.File]::WriteAllText($readme, $rt, (New-Object Text.UTF8Encoding($false)))
    # CHANGELOG
    $cl = Join-Path $repoRoot 'CHANGELOG.md'
    $oldCl = [IO.File]::ReadAllText($cl, [Text.Encoding]::GetEncoding(65001))
    $newEntry = "## $Version — $(Get-Date -Format 'yyyy-MM-dd') — Dev-Tools`n`n- bump $oldVer -> $Version`n`n"
    [IO.File]::WriteAllText($cl, $newEntry + $oldCl, (New-Object Text.UTF8Encoding($true)))
    Write-Ok2 "version files + rc + README + CHANGELOG"
    # normalize + build + manifest (reuse build logic)
    $Action = 'build'
    # fall through to build
}

if ($Action -eq 'build') {
    $targetVer = if ($Version) { $Version } else { ([IO.File]::ReadAllText((Join-Path $repoRoot '.service/version.txt'))).Trim() }
    Write-Step "Build-Release $targetVer"
    $out = Join-Path ([IO.Path]::GetTempPath()) 'zapret-build'
    if (Test-Path $out) { Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue }
    & (Join-Path $repoRoot 'tools/Build-Release.ps1') -Version $targetVer -OutputDirectory $out
    $sums = [IO.File]::ReadAllText((Join-Path $out 'SHA256SUMS.txt'))
    $sha = ($sums -split '\s+')[0]
    Write-Host $sums -NoNewline
    Write-Ok2 "ZIP $out/zapret-discord-youtube-$targetVer.zip SHA $sha"
    # update-manifest.json
    $manifestPath = Join-Path $repoRoot 'update-manifest.json'
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $manifest.version = $targetVer
    $manifest.zipUrl = "https://github.com/Orlovsky1504/OpenZapret/releases/download/$targetVer/zapret-discord-youtube-$targetVer.zip"
    $manifest.sha256 = $sha.ToLowerInvariant()
    $manifest.published = Get-Date -Format 'yyyy-MM-dd'
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Ok2 "update-manifest.json -> $targetVer $sha"
    if ($Push) {
        Write-Step "Push bump $targetVer"
        & git -C $repoRoot add version.txt .service/version.txt tools/zapret-control.rc README.md CHANGELOG.md update-manifest.json .gitattributes tools/Build-Release.ps1 2>&1 | Out-Null
        & git -C $repoRoot commit -m "chore: bump $targetVer dev-tools" 2>&1 | Out-Null
        Write-Host "Commit created. Run: git push && dispatch release.yml tag=$targetVer"
    }
    return
}

if ($Action -eq 'gates') {
    Write-Step "Gates (9) + bug-hunt4 + gui"
    & (Join-Path $repoRoot '../qa/run-gates.ps1') 2>&1 | Select-Object -Last 20
    Write-Host ""
    python3 (Join-Path $PSScriptRoot '../qa/bug-hunt4.py') 2>&1 | Select-Object -Last 5
    if (Test-Path (Join-Path $repoRoot '../qa/gui-functional-check.ps1')) {
        & (Join-Path $repoRoot '../qa/gui-functional-check.ps1') 2>&1 | Select-Object -Last 10
    }
    return
}

if ($Action -eq 'normalize') {
    Write-Step "Normalize EOL + BOM"
    $crlfExts = @('.ps1','.psm1','.bat','.txt','.md')
    $lfExts = @('.json')
    $fixed = 0
    foreach ($file in (Get-ChildItem -LiteralPath $repoRoot -File -Recurse -Force | Where-Object { $_.Extension -in $crlfExts -or $_.Extension -in $lfExts -or $_.Name -eq 'version.txt' })) {
        if ($file.FullName -like '*.git*') { continue }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -eq 0) { continue }
        $ext = $file.Extension.ToLowerInvariant()
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text = if ($hasBom) { [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) } else { [Text.Encoding]::UTF8.GetString($bytes) }
        $newText = $null
        if ($ext -in $crlfExts -or $file.Name -eq 'version.txt') { $newText = $text -replace "(?<!\r)\n", "`r`n" }
        elseif ($ext -in $lfExts) { $newText = $text -replace "\r\n", "`n" }
        if ($null -ne $newText -and $newText -ne $text) {
            $out = if ($hasBom -or $ext -in @('.ps1','.psm1')) { (New-Object Text.UTF8Encoding($true)).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($newText) } else { [Text.Encoding]::UTF8.GetBytes($newText) }
            [IO.File]::WriteAllBytes($file.FullName, $out)
            $fixed++
        }
    }
    Write-Ok2 "normalized $fixed files"
    return
}

if ($Action -eq 'release-status') {
    Write-Step "Release status"
    $token = $env:GITHUB_TOKEN
    if (-not $token) { Write-Host "Set GITHUB_TOKEN env to query GitHub API" -ForegroundColor Yellow; return }
    $headers = @{ Authorization = "token $token" }
    try {
        $runs = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Orlovsky1504/OpenZapret/actions/runs?per_page=5" -TimeoutSec 10
        $runs.workflow_runs | Select-Object -First 5 | Format-Table name,status,conclusion,updated_at -AutoSize | Out-String | Write-Host
        $manifest = Get-Content (Join-Path $repoRoot 'update-manifest.json') -Raw | ConvertFrom-Json
        Write-Host "Local manifest: $($manifest.version) $($manifest.sha256.Substring(0,12))" -ForegroundColor Cyan
        $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/Orlovsky1504/OpenZapret/releases/tags/$($manifest.version)" -TimeoutSec 10 -ErrorAction SilentlyContinue
        if ($release) { Write-Host "Release $($release.tag_name) assets $($release.assets.Count)" -ForegroundColor Green }
    } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    return
}

throw "Unknown action '$Action'. Use: help"
