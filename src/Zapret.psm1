#requires -Version 4.0
<#
    Zapret.psm1 - Shared engine for zapret-discord-youtube (2.x)

    Contains the configuration, strategy engine, service management,
    maintenance and diagnostics helpers used by zapret.ps1 and the
    test utility.

    Target: Windows PowerShell 5.1+ (also runs on PowerShell 7+).
    Windows-only operations are guarded and degrade to clear errors
    on other platforms.
#>

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------

$script:ModuleDir   = $PSScriptRoot
$script:Root        = Split-Path -Parent $script:ModuleDir
$script:BinDir      = Join-Path $script:Root 'bin'
$script:ListsDir    = Join-Path $script:Root 'lists'
$script:UtilsDir    = Join-Path $script:Root 'utils'
$script:ServiceDir  = Join-Path $script:Root '.service'
$script:ConfigPath  = Join-Path $script:Root 'config.json'
$script:LogDir      = Join-Path $script:Root 'logs'
$script:StrategiesFile = Join-Path $script:Root 'strategies.json'
$script:UserStrategiesFile = Join-Path $script:Root 'strategies-user.json'
$script:LocalVersion = $null
$script:UiLanguage = 'ru'

$script:IpsetSentinel  = '203.0.113.113/32'
$script:IpsetFile      = Join-Path $script:ListsDir 'ipset-all.txt'
$script:IpsetBackup    = Join-Path $script:ListsDir 'ipset-all.txt.backup'
$script:IpsetUrl       = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
$script:HostsUrl       = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts'
$script:VersionUrl     = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt'
$script:ReleasesUrl    = 'https://github.com/Flowseal/zapret-discord-youtube/releases/latest'

$script:OnWindows = $true
if ($PSVersionTable.PSVersion.Major -ge 6) {
    $script:OnWindows = [bool]$IsWindows
}

function Get-ZapretRoot     { return $script:Root }
function Get-ZapretBinDir   { return $script:BinDir }
function Get-ZapretListsDir { return $script:ListsDir }

function Test-OnboardingRequired {
    # Pure first-run predicate; configuration and services are not created here.
    [CmdletBinding()]
    param([bool]$ConfigExists, [bool]$ServiceInstalled)
    return (-not $ConfigExists -and -not $ServiceInstalled)
}

function Test-IsAdmin {
    if (-not $script:OnWindows) { return $false }
    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        throw "Administrator rights are required for this operation. Run zapret.bat (or 'zapret.ps1' from an elevated console)."
    }
}

function Get-TrailingDir {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
}

function Get-SignatureSeverity {
    <# Returns OK | WARN | FAIL for a Get-AuthenticodeSignature Status string. #>
    param([string]$Status)
    switch -Regex ([string]$Status) {
        '^Valid$'        { return 'OK' }
        '^HashMismatch$' { return 'FAIL' }   # file modified after signing = tampering
        default          { return 'WARN' }
    }
}

function Get-BinarySignatureReport {
    <#
        Authenticode-verifies the shipped binaries in bin\.
        Windows-only; on other platforms every entry is SKIPPED.
        Severity: OK = valid signature, WARN = unsigned/unverifiable (common for
        unsigned builds - not proof of tampering), FAIL = HashMismatch (tampered).
    #>
    $targets = @('winws.exe', 'WinDivert.dll', 'WinDivert64.sys', 'cygwin1.dll')
    $report = @()
    foreach ($name in $targets) {
        $path = Join-Path $script:BinDir $name
        if (-not (Test-Path $path)) { $report += [pscustomobject]@{ File = $name; Status = 'MISSING'; Severity = 'FAIL' }; continue }
        if (-not $script:OnWindows) { $report += [pscustomobject]@{ File = $name; Status = 'SKIPPED (not Windows)'; Severity = 'SKIP' }; continue }
        try {
            $sig    = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
            $status = [string]$sig.Status
            $report += [pscustomobject]@{ File = $name; Status = $status; Severity = (Get-SignatureSeverity -Status $status) }
        } catch {
            $report += [pscustomobject]@{ File = $name; Status = ('ERROR: ' + $_.Exception.Message); Severity = 'WARN' }
        }
    }
    return @($report)
}
function Get-WinwsPathName {
    <#
        Builds the service PathName string: "<winws.exe>" <args>.
        Rejects quotes in paths (they would break out of the quoting).
        Pure function - unit-testable on any platform.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WinwsPath,
        [Parameter(Mandatory = $true)][string]$ExpandedArgs
    )
    if ($WinwsPath -match '"') { throw "The zapret path contains a double-quote character - move the folder to a path without quotes." }
    return ('"{0}" {1}' -f $WinwsPath, $ExpandedArgs)
}

function Get-AutoSelectTaskArguments {
    <#
        Builds the schtasks /TR payload for the weekly re-check task.
        Rejects quotes in paths (injection into the task command line).
        Pure function - unit-testable on any platform.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )
    foreach ($p in @($PowerShellPath, $ScriptPath)) {
        if ($p -match '"') { throw "Path contains a double-quote character - move zapret to a path without quotes." }
    }
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" auto-select -Install -Scheduled' -f $PowerShellPath, $ScriptPath)
}

function Get-WatchdogTaskArguments {
    <#
        Builds the schtasks /TR payload for the watchdog ("Автозащита") task.
        Rejects quotes in paths (injection into the task command line).
        Pure function - unit-testable on any platform.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )
    foreach ($p in @($PowerShellPath, $ScriptPath)) {
        if ($p -match '"') { throw "Path contains a double-quote character - move zapret to a path without quotes." }
    }
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" watchdog -Scheduled' -f $PowerShellPath, $ScriptPath)
}

# Ordered implementation parts are dot-sourced into this module's script scope.
# Keep their order stable: a few top-level catalog/constant initializers depend on
# helper functions declared earlier in the sequence.
$modulePartsDirectory = Join-Path $script:ModuleDir 'parts'
$moduleParts = @(
    'Zapret.Runtime.ps1',
    'Zapret.Strategies.ps1',
    'Zapret.IpsetHosts.ps1',
    'Zapret.Diagnostics.ps1',
    'Zapret.AutoSelect.ps1',
    'Zapret.Dns.ps1',
    'Zapret.Network.ps1',
    'Zapret.Automation.ps1',
    'Zapret.Support.ps1',
    'Zapret.Maintenance.ps1',
    'Zapret.Rollback.ps1',
    'Zapret.UserStrategies.ps1',
    'Zapret.Watchdog.ps1',
    'Zapret.Doctor.ps1'
)
foreach ($modulePart in $moduleParts) {
    $modulePartPath = Join-Path $modulePartsDirectory $modulePart
    if (-not (Test-Path -LiteralPath $modulePartPath -PathType Leaf)) {
        throw "Required module part is missing: $modulePartPath"
    }
    . $modulePartPath
}

# The original monolithic module implicitly exported every function. Keep that
# contract explicit so dot-sourced implementation parts remain fully compatible.
Export-ModuleMember -Function *
