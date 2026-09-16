#Requires -Version 7.0
<#
.SYNOPSIS
    ADT Bundler - downloads a chosen Eclipse release, installs SAP's ABAP
    Development Tools (ADT), and lets you pick additional DevEpos / third
    party ADT plugins, all headlessly via the Eclipse p2 director.

.DESCRIPTION
    Interactive by default: prompts for an install directory, an Eclipse
    release train, and which additional plugins to install, then downloads,
    extracts and provisions everything automatically.

    Can also be run unattended by supplying -EclipseVersion, -InstallPath,
    -Features and -NonInteractive, e.g. for scripted setups.

.PARAMETER InstallPath
    Directory where the Eclipse installation will be created (a subfolder
    'eclipse' will be created inside it). Defaults to '.\eclipse-adt' next to
    this script.

.PARAMETER EclipseVersion
    Eclipse release train id, e.g. '2025-06'. Must match an entry in
    catalog.json. If omitted in interactive mode, you'll be prompted; the
    most recent version is preselected.

.PARAMETER Features
    Array of plugin ids from catalog.json to install in addition to ADT,
    e.g. -Features devepos-search-tools,devepos-tags. Use -ListFeatures to see
    all available ids. Ignored in interactive mode (the menu is used instead).

.PARAMETER NonInteractive
    Suppresses all prompts. Requires -EclipseVersion. -InstallPath and
    -Features fall back to defaults (default install path, no extra plugins)
    if not supplied.

.PARAMETER CacheDirectory
    Directory used to cache the downloaded Eclipse zip so re-runs don't
    re-download it. Defaults to '%LOCALAPPDATA%\AdtBundler\cache'.

.PARAMETER ListFeatures
    Prints the catalog's available Eclipse versions and plugins, then exits
    without installing anything.

.EXAMPLE
    .\Setup-AdtEclipse.ps1
    Runs the full interactive wizard.

.EXAMPLE
    .\Setup-AdtEclipse.ps1 -NonInteractive -EclipseVersion 2025-06 `
        -InstallPath C:\dev\eclipse-adt -Features devepos-search-tools,devepos-tags
    Unattended install for scripting/CI use.
#>
[CmdletBinding()]
param(
    [string]$InstallPath,

    [string]$EclipseVersion,

    [string[]]$Features,

    [switch]$NonInteractive,

    [string]$CacheDirectory = (Join-Path $env:LOCALAPPDATA 'AdtBundler\cache'),

    [switch]$ListFeatures
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $scriptRoot 'lib\Logging.ps1')
. (Join-Path $scriptRoot 'lib\Ui.ps1')
. (Join-Path $scriptRoot 'lib\Download.ps1')
. (Join-Path $scriptRoot 'lib\P2Director.ps1')
. (Join-Path $scriptRoot 'lib\Menu.ps1')

$catalogPath = Join-Path $scriptRoot 'catalog.json'
if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "catalog.json not found at '$catalogPath'."
}
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

if ($ListFeatures) {
    Write-Host "Available Eclipse versions:" -ForegroundColor Cyan
    $catalog.eclipseVersions | ForEach-Object { Write-Host ("  {0,-9} {1}" -f $_.id, $_.label) }
    Write-Host ""
    Write-Host "Available plugins:" -ForegroundColor Cyan
    Write-Host ("  {0,-26} {1,-12} {2,-7} {3}" -f 'ID', 'CATEGORY', 'CHANNEL', 'NAME') -ForegroundColor DarkGray
    $catalog.plugins | ForEach-Object {
        Write-Host ("  {0,-26} {1,-12} {2,-7} {3}" -f $_.id, $_.category, $_.channel, $_.name)
    }
    return
}

Initialize-BundlerLog -LogDirectory (Join-Path $scriptRoot 'logs') | Out-Null

if (-not $NonInteractive -and (Test-InteractiveConsole)) {
    Write-Banner -Title 'ADT Bundler' -Subtitle 'Eclipse + ABAP Development Tools'
}
Write-Log "ADT Bundler starting." -Level INFO

if ($NonInteractive -and -not $EclipseVersion) {
    throw "-NonInteractive requires -EclipseVersion to be specified (use -ListFeatures to see available versions)."
}

# --- Step 1: Eclipse version -------------------------------------------------
if (-not $EclipseVersion) {
    if ($NonInteractive) { throw "-EclipseVersion is required in non-interactive mode." }
    Write-StepHeader -Step 1 -Total 5 -Title 'Eclipse release'
    $chosen = Read-MenuChoice -Title "Select an Eclipse release train to install:" `
        -Options $catalog.eclipseVersions -LabelProperty 'label' -DefaultIndex ($catalog.eclipseVersions.Count - 1)
    $EclipseVersion = $chosen.id
} else {
    $match = $catalog.eclipseVersions | Where-Object { $_.id -eq $EclipseVersion }
    if (-not $match) {
        throw "Unknown Eclipse version '$EclipseVersion'. Run with -ListFeatures to see valid values."
    }
}
Write-Log "Selected Eclipse version: $EclipseVersion" -Level INFO

# --- Step 2: install path ----------------------------------------------------
if (-not $InstallPath) {
    $defaultPath = Join-Path (Get-Location) 'eclipse-adt'
    if ($NonInteractive) {
        $InstallPath = $defaultPath
    } else {
        Write-StepHeader -Step 2 -Total 5 -Title 'Install location'
        $InstallPath = Read-PathPrompt -Message "Where should Eclipse be installed?" -DefaultPath $defaultPath
    }
}
Write-Log "Install path: $InstallPath" -Level INFO

# --- Step 3: plugin selection -------------------------------------------------
$selectedPlugins = @()
if ($NonInteractive) {
    if ($Features) {
        foreach ($featureId in $Features) {
            $plugin = $catalog.plugins | Where-Object { $_.id -eq $featureId }
            if (-not $plugin) { throw "Unknown feature id '$featureId'. Run with -ListFeatures to see valid values." }
            $selectedPlugins += $plugin
        }
    }
} else {
    Write-StepHeader -Step 3 -Total 5 -Title 'Additional plugins'
    $selectedPlugins = Read-MultiSelect -Title "Select additional plugins to install (ADT itself is always installed):" `
        -Options $catalog.plugins -LabelProperty 'name' -DescriptionProperty 'description' -GroupProperty 'category'
}

# --- Step 4: confirmation -----------------------------------------------------
if (-not $NonInteractive) {
    Write-StepHeader -Step 4 -Total 5 -Title 'Confirmation'
    $plannedEclipseRoot = if (Test-Path -LiteralPath $InstallPath -PathType Container) {
        Join-Path $InstallPath 'eclipse'
    } else {
        $InstallPath
    }
    Write-Host "  Eclipse version : $EclipseVersion"
    Write-Host "  Install path    : $plannedEclipseRoot"
    Write-Host "  Base package    : $($catalog.eclipseDownload.packageName)"
    Write-Host "  ADT             : $($catalog.adt.name) (always installed)"
    if ($selectedPlugins.Count -gt 0) {
        Write-Host "  Extra plugins   :"
        $selectedPlugins | ForEach-Object { Write-Host "    - $($_.name)" }
    } else {
        Write-Host "  Extra plugins   : (none selected)"
    }
    Write-Host ""
    if (-not (Read-YesNo -Message "Proceed with download and installation?" -DefaultYes $true)) {
        Write-Log "Aborted by user." -Level WARN
        return
    }
}

# --- Step 5: download & extract Eclipse --------------------------------------
if (-not $NonInteractive) {
    Write-StepHeader -Step 5 -Total 5 -Title 'Download & install'
}

function Expand-Template {
    param([string]$Template, [string]$Version)
    return $Template.Replace('{version}', $Version)
}

$downloadUrl = Expand-Template -Template $catalog.eclipseDownload.urlTemplate -Version $EclipseVersion
$fallbackUrl = Expand-Template -Template $catalog.eclipseDownload.fallbackUrlTemplate -Version $EclipseVersion
$zipFileName = "eclipse-java-$EclipseVersion-R-win32-x86_64.zip"

$zipPath = Get-CachedFile -Url $downloadUrl -FallbackUrl $fallbackUrl -CacheDirectory $CacheDirectory -FileName $zipFileName
$eclipseRoot = Expand-EclipseZip -ZipPath $zipPath -InstallPath $InstallPath
$eclipseExe = Join-Path $eclipseRoot 'eclipsec.exe'

# --- Step 6: install ADT (+ required extra repos/IUs) -------------------------
$adtRepos = @((Expand-Template -Template $catalog.adt.repoUrlTemplate -Version $EclipseVersion))
if ($catalog.adt.additionalRepoUrlTemplates) {
    foreach ($tmpl in $catalog.adt.additionalRepoUrlTemplates) {
        $adtRepos += (Expand-Template -Template $tmpl -Version $EclipseVersion)
    }
}

$results = @()
$adtResult = Invoke-P2Director -EclipseExePath $eclipseExe -Repositories $adtRepos `
    -InstallIUs $catalog.adt.installableUnits -DestinationPath $eclipseRoot `
    -Description $catalog.adt.name
$results += [PSCustomObject]@{ Name = $catalog.adt.name; Success = $adtResult.Success }

if (-not $adtResult.Success) {
    Write-Log "ADT installation failed - skipping additional plugins since they depend on ADT." -Level ERROR
} else {
    # --- Step 7: install selected plugins ------------------------------------
    foreach ($plugin in $selectedPlugins) {
        $pluginResult = Invoke-P2Director -EclipseExePath $eclipseExe -Repositories @($plugin.repoUrl) `
            -InstallIUs $plugin.installableUnits -DestinationPath $eclipseRoot `
            -Description $plugin.name
        $results += [PSCustomObject]@{ Name = $plugin.name; Success = $pluginResult.Success }
    }
}

# --- Step 8: summary -----------------------------------------------------------
Write-Host ""
Write-Host ("── Installation Summary " + ('─' * 24)) -ForegroundColor Cyan
$anyFailed = $false
foreach ($r in $results) {
    if ($r.Success) {
        Write-Host "  [OK]   $($r.Name)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $($r.Name)" -ForegroundColor Red
        $anyFailed = $true
    }
}
Write-Host ""

if ($anyFailed) {
    Write-Log "Completed with failures. See log for details." -Level ERROR
    exit 1
}

Write-Log "All done. Launch Eclipse from: $eclipseRoot\eclipse.exe" -Level SUCCESS
Write-Host "Eclipse with ADT is ready at: $eclipseRoot\eclipse.exe" -ForegroundColor Green
exit 0
