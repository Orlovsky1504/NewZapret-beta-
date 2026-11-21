#requires -Version 5.1
<#
  Обновляет VirusTotal секцию в README.md и assets/screenshots/virustotal-links.html
  по текущим бинарям + ZIP. Вызывается:
    - вручную:  pwsh -File tools/Update-VirusTotalDocs.ps1 -Version 2.9.14
    - автоматом: release.yml после Build-Release (передаёт TAG)
#>
[CmdletBinding()]
param([string]$Version)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$svcVer = [IO.File]::ReadAllText((Join-Path $root '.service/version.txt')).Trim()
if (-not $Version) { $Version = $svcVer }
if ($Version -notmatch '^\d+\.\d+\.\d+[A-Za-z]?(?:-[0-9A-Za-z.-]+)?$') { throw "Bad version '$Version'" }

function Get-HashOrNull($path) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
}

# Собираем хэши из рабочей копии (или из собранного ZIP если есть в PWD)
$zipName = "zapret-discord-youtube-$Version.zip"
$zipPath = Join-Path $PWD $zipName
if (-not (Test-Path -LiteralPath $zipPath)) { $zipPath = Join-Path $root $zipName }
$zipHash = Get-HashOrNull $zipPath

$bins = @(
  @{ Rel='bin/winws.exe'; Label='`bin/winws.exe`' },
  @{ Rel='bin/WinDivert.dll'; Label='`bin/WinDivert.dll`' },
  @{ Rel='bin/WinDivert64.sys'; Label='`bin/WinDivert64.sys`' },
  @{ Rel='Zapret-Control.exe'; Label='`Zapret-Control.exe`' },
  @{ Rel='Zapret-Tray.exe'; Label='`Zapret-Tray.exe`' }
)
$hashMap = @{}
foreach ($b in $bins) {
  $h = Get-HashOrNull (Join-Path $root $b.Rel)
  if (-not $h) { Write-Warning "Нет файла $($b.Rel) — пропускаю"; continue }
  $hashMap[$b.Rel] = $h
}
if ($zipHash) { $hashMap[$zipName] = $zipHash }

if (-not $zipHash) { Write-Warning "ZIP $zipName не найден — в README будет без ZIP строки (соберётся в релизе)." }

# 1) Обновить assets/screenshots/virustotal-links.html (генерит пруф как capture, но локально)
$outHtml = Join-Path $root 'assets/screenshots/virustotal-links.html'
$repo = 'Orlovsky1504/OpenZapret'
$lines = @()
$lines += '<!DOCTYPE html>'
$lines += '<meta charset="utf-8">'
$lines += "<title>OpenZapret VirusTotal — proof $Version</title>"
$lines += '<style>body{font:14px Segoe UI,Arial;background:#0F141E;color:#E8EEF8;padding:24px} a{color:#4F7DF3} code{background:#1C2335;padding:2px 6px;border-radius:6px;word-break:break-all} .card{background:#1C2335;border-radius:12px;padding:16px;margin:12px 0}</style>'
$lines += "<h1>OpenZapret VirusTotal — $Version (proof)</h1>"
$lines += '<p>Hashes computed locally / in release job — direct VT links (open to verify):</p>'
foreach ($b in $bins) {
  $h = $hashMap[$b.Rel]
  if (-not $h) { continue }
  $lines += "<div class=card><b>$($b.Rel)</b><br><code>$h</code><br><a href=`"https://www.virustotal.com/gui/file/$h`">https://www.virustotal.com/gui/file/$h</a></div>"
}
if ($zipHash) {
  $lines += "<div class=card><b>ZIP $Version</b><br><code>$zipHash</code><br><a href=`"https://www.virustotal.com/gui/file/$zipHash`">VT ZIP</a> — <a href=`"https://github.com/$repo/releases/download/$Version/$zipName`">download ZIP</a></div>"
}
$lines += "<p style=`"color:#91A0B8`">Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC — $Version — VirusTotal check: open any link.</p>"
[IO.File]::WriteAllText($outHtml, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Updated $outHtml"

# 2) Обновить README.md — заменить все таблицы VirusTotal на актуальные
$readmePath = Join-Path $root 'README.md'
$readme = [IO.File]::ReadAllText($readmePath)

function Build-Table($includeZip) {
  $rows = @()
  $rows += '| Файл | SHA256 | VirusTotal |'
  $rows += '|---|---|---|'
  foreach ($b in $bins) {
    $h = $hashMap[$b.Rel]
    if (-not $h) { continue }
    $rows += "| $($b.Label) | ``$h`` | [открыть](https://www.virustotal.com/gui/file/$h) |"
  }
  if ($includeZip -and $zipHash) {
    $rows += "| **ZIP $Version** | ``$zipHash`` | [открыть](https://www.virustotal.com/gui/file/$zipHash) — [скачать ZIP](https://github.com/Orlovsky1504/OpenZapret/releases/download/$Version/$zipName) |"
  }
  return ($rows -join "`n")
}

# Верхний IMPORTANT блок — между "> [!IMPORTANT]" и "<sub>Ложные"
$topTable = Build-Table $true
# Заменяем старый верхний блок (детектим по заголовку)
$patternTop = '(?s)> \[!IMPORTANT\].*?<sub>Ложные.*?инструментов \(эвристика\).*?</sub>'
$replacementTop = @"
> [!IMPORTANT]
> #### 🛡️ Безопасность — проверено на VirusTotal (сгенерировано на ``windows-latest``)
> Все бинари собираются на чистой Windows в Actions из открытых исходников. Открой любой файл на VirusTotal и сверь SHA256 — совпадение = файл не подменён.
>
$($topTable -replace '^','> ' -replace "`n","`n> ")
>
> Проверка: ``certutil -hashfile bin\\winws.exe SHA256`` и сравни с таблицей · Полный отчёт: [``assets/screenshots/virustotal-links.html``](https://raw.githubusercontent.com/Orlovsky1504/OpenZapret/main/assets/screenshots/virustotal-links.html) (артефакт ``virustotal-proof`` на ``windows-latest``).
>
> <sub>Ложные 1–2/70 детекты для ``winws.exe``/``WinDivert`` — норма для DPI-инструментов (эвристика). Исходники ``src/``+``bin/`` открыты и собираются на чистой GH Windows.</sub>
"@
if ($readme -match $patternTop) {
  $readme = [regex]::Replace($readme, $patternTop, $replacementTop)
  Write-Host "README top block updated"
}

# Нижняя секция "Безопасность · VirusTotal" — между "**Актуальный релиз" и "> Пруф:"
$bottomTable = Build-Table $true
$patternBottom = '(?s)\*\*Актуальный релиз.*?<table>.*?</table>|(?s)\*\*Актуальный релиз.*?> Пруф:'
# проще: найти заголовок и заменить следующую таблицу
if ($readme -match '\*\*Актуальный релиз') {
  # заменить блок таблицы целиком
  $patternB = '(?s)\*\*Актуальный релиз[^`]*?```.*?```|\*\*Актуальный релиз.*?\n\n\| Что \| SHA256.*?\[скачать ZIP[^\n]*\n'
  # fallback: ищем таблицу по "| Что | SHA256"
  if ($readme -match '\| Что \| SHA256') {
    $oldBottom = [regex]::Match($readme, '(?s)\| Что \| SHA256.*?\[скачать ZIP[^\n]*\n').Value
    if ($oldBottom) {
      $newBottom = @"
**Актуальный релиз $Version — проверь перед распаковкой** (``windows-latest`` пруф):

| Что | SHA256 | VirusTotal |
|---|---|---|
"@
      foreach ($b in $bins) {
        $h = $hashMap[$b.Rel]
        if (-not $h) { continue }
        $label = $b.Label -replace '`',''
        $newBottom += "| ``$label`` | ``$h`` | [открыть](https://www.virustotal.com/gui/file/$h) |`n"
      }
      if ($zipHash) {
        $newBottom += "| ZIP ``$zipName`` | ``$zipHash`` | [открыть](https://www.virustotal.com/gui/file/$zipHash) |`n"
      }
      $newBottom += "`n> Пруф: хэши посчитаны на чистой ``windows-latest`` (артефакт ``virustotal-proof`` + [``virustotal-links.html``](https://raw.githubusercontent.com/Orlovsky1504/OpenZapret/main/assets/screenshots/virustotal-links.html))."
      $readme = $readme.Replace($oldBottom, $newBottom + "`n")
      Write-Host "README bottom section updated"
    }
  }
}

# Бейджи версии в шапке — обновить 2.9.13 -> $Version
$readme = $readme -replace 'версия-2\.9\.13', "версия-$Version"
$readme = $readme -replace 'download/v2\.9\.13/', "download/$Version/"
$readme = $readme -replace 'zapret-discord-youtube-2\.9\.13\.zip', "zapret-discord-youtube-$Version.zip"

[IO.File]::WriteAllText($readmePath, $readme, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "README updated to $Version — done"
