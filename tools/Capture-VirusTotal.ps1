# Capture-VirusTotal.ps1 - открывает VirusTotal в STA браузере на windows-latest и делает PNG пруфы
# Использование: powershell -STA -File tools/Capture-VirusTotal.ps1 -OutDir assets/screenshots
param([string]$OutDir = "assets/screenshots")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, System.Windows.Forms

$repoRoot = Split-Path $PSScriptRoot -Parent
$outFull = Join-Path $repoRoot $OutDir
New-Item -ItemType Directory -Path $outFull -Force | Out-Null

# SHA256 наших файлов (считаются прямо на раннере)
$files = @('bin/winws.exe','bin/WinDivert.dll','bin/WinDivert64.sys','Zapret-Control.exe','Zapret-Tray.exe')
$hashMap = @{}
foreach ($rel in $files) {
  $p = Join-Path $repoRoot $rel
  if (Test-Path $p) {
    $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
    $hashMap[$rel] = $h
    Write-Host "$rel -> $h"
  }
}

# Делаем HTML-отчёт (пруф: хэши + ссылки на VT)
$report = Join-Path $outFull 'virustotal-links.html'
@"
<!DOCTYPE html><meta charset=utf-8><title>OpenZapret VirusTotal - ручная проверка</title>
<style>body{font:14px Segoe UI;background:#0F141E;color:#E8EEF8;padding:24px} a{color:#4F7DF3} code{background:#1C2335;padding:2px 6px;border-radius:6px} .card{background:#1C2335;border-radius:12px;padding:16px;margin:12px 0}</style>
<h1>OpenZapret - VirusTotal (2.9.13)</h1>
<p>Винда на <b>windows-latest</b> не имеет браузера с GUI для скрина virustotal.com. Вместо фейка - <b>реальные хэши</b> и прямые ссылки (открой и проверь):</p>
"@ | Set-Content $report -Encoding UTF8

foreach ($rel in $hashMap.Keys) {
  $h = $hashMap[$rel]
  $url = "https://www.virustotal.com/gui/file/$h"
  Add-Content $report "<div class=card><b>$rel</b><br><code>$h</code><br><a href=`"$url`">$url</a></div>" -Encoding UTF8
}
# ZIP релиза
try {
  $manifest = Get-Content (Join-Path $repoRoot 'update-manifest.json') -Raw | ConvertFrom-Json
  $zipSha = $manifest.sha256
  $zipUrl = $manifest.zipUrl
  Add-Content $report "<div class=card><b>ZIP $($manifest.version)</b><br><code>$zipSha</code><br><a href=`"https://www.virustotal.com/gui/file/$zipSha`">VT ZIP</a> - <a href=`"$zipUrl`">download</a></div>" -Encoding UTF8
} catch {}
Add-Content $report "<p style='color:#91A0B8'>Generated на windows-latest $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC - hashes computed on runner.</p>" -Encoding UTF8
Write-Host "report $report"

# Плюс рендерим WPF пруф как раньше (что прога та самая)
try {
  Add-Type -AssemblyName PresentationFramework
  $ps1Path = Join-Path $repoRoot 'Zapret-Control.ps1'
  $text = [IO.File]::ReadAllText($ps1Path)
  $m = [regex]::Match($text, '\$xamlText\s*=\s*@''(?<x>.*?)''@', 'Singleline')
  if ($m.Success) {
    $xaml = $m.Groups['x'].Value
    [xml]$doc = $xaml
    $reader = New-Object System.Xml.XmlNodeReader $doc
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()
    $window.Width=1180; $window.Height=780
    try { $window.Show() } catch {}
    $window.UpdateLayout()
    $pf=[System.Windows.Media.PixelFormats]::Pbgra32
    $bmp=New-Object System.Windows.Media.Imaging.RenderTargetBitmap 1180,780,96,96,$pf
    $bmp.Render($window)
    $enc=New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs=[IO.File]::Create((Join-Path $outFull 'ci-overview.png'))
    try { $enc.Save($fs) } finally { $fs.Close() }
    try { $window.Close() } catch {}
    Write-Host "saved ci-overview.png"
  }
} catch { Write-Host "WPF render skip: $_" }

Write-Host "Done"
