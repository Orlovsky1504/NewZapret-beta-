# Capture-Screenshots.ps1 — render Zapret-Control.ps1 XAML to PNG on real Windows (STA)
# Запускать только на windows-latest в powershell (5.1): powershell -STA -File tools/Capture-Screenshots.ps1
param(
    [string]$OutDir = "assets/screenshots"
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$repoRoot = Split-Path $PSScriptRoot -Parent
$ps1Path = Join-Path $repoRoot 'Zapret-Control.ps1'
if (-not (Test-Path $ps1Path)) { throw "Zapret-Control.ps1 not found at $ps1Path" }

$text = [IO.File]::ReadAllText($ps1Path)
$m = [regex]::Match($text, '\$xamlText\s*=\s*@''(?<x>.*?)''@', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $m.Success) { throw 'xamlText block not found' }
$xaml = $m.Groups['x'].Value

# Ensure output dir exists
$outFull = Join-Path $repoRoot $OutDir
New-Item -ItemType Directory -Path $outFull -Force | Out-Null

function Save-PngFromXaml {
    param([string]$XamlString, [string]$OutPath, [int]$Width = 1180, [int]$Height = 780)
    [xml]$doc = $XamlString
    $reader = New-Object System.Xml.XmlNodeReader $doc
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()

    $window.WindowStartupLocation = 'CenterScreen'
    $window.Width = $Width
    $window.Height = $Height
    # hide chrome for capture: no need to Show
    $window.Visibility = [System.Windows.Visibility]::Hidden
    # Use a hidden host to measure
    $window.ShowInTaskbar = $false
    $window.Topmost = $false
    # We need to show offscreen to trigger layout, but we can do Measure/Arrange without Show if we force
    # Create a helper: put window in hidden state then call Show and immediately hide after render
    try { $window.Show() } catch { }
    $window.UpdateLayout()
    # Force layout
    $window.Measure([System.Windows.Size]::new($Width, $Height))
    $window.Arrange([System.Windows.Rect]::new(0,0,$Width,$Height))
    $window.UpdateLayout()
    Start-Sleep -Milliseconds 300

    $dpi = 96
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $Width, $Height, $dpi, $dpi, [System.Windows.Media.PixelFormats]::Pbgra32
    $bmp.Render($window)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($OutPath)
    try { $enc.Save($fs) } finally { $fs.Close() }
    try { $window.Close() } catch { }
    Write-Host "saved $OutPath"
}

# We capture the main window as is (default page is 'home' -> Overview)
# For fuller proof we also switch pages via FindName and re-render
# Helper to set page visibility like Set-ControlPage does

$xamlPath = Join-Path $outFull 'ci-overview.png'
Save-PngFromXaml -XamlString $xaml -OutPath $xamlPath -Width 1180 -Height 780

Write-Host "CI screenshots done"
