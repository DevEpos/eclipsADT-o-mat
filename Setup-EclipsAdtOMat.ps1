#Requires -Version 7.0
<#
.SYNOPSIS
    eclipsADT-o-Mat - downloads a chosen Eclipse release, installs SAP's ABAP
    Development Tools (ADT), and lets you pick additional DevEpos / third
    party ADT plugins, all headlessly via the Eclipse p2 director.

.DESCRIPTION
    Interactive by default: prompts for an install directory, an Eclipse
    release train, and which additional plugins to install, then downloads,
    extracts and provisions everything automatically.

    Can also be run unattended by supplying -EclipseVersion, -InstallPath,
    -Features and -NonInteractive, e.g. for scripted setups.

.PARAMETER InstallPath
    Directory where the Eclipse installation will be created. If the directory
    already exists and is not empty, a subfolder 'eclipse' will be created
    inside it. Defaults to '~\Documents\eclipse'.

.PARAMETER BasePackage
    Base Eclipse package id to install from catalog.json's basePackages, e.g.
    'java', 'rcp' or 'platform'. Defaults to the catalog's default package
    ('java'). Use -ListFeatures to see all available ids. Note that the
    'platform' package (minimal core runtime) is only available for a subset
    of Eclipse versions - see -ListFeatures.

.PARAMETER EclipseVersion
    Eclipse release train id, e.g. '2025-06'. Must match an entry in
    catalog.json and be supported by the selected -BasePackage. If omitted in
    interactive mode, you'll be prompted; the most recent supported version is
    preselected.

.PARAMETER Features
    Array of plugin ids from catalog.json to install in addition to ADT,
    e.g. -Features devepos-search-tools,devepos-tags. Use -ListFeatures to see
    all available ids. Ignored in interactive mode (the menu is used instead).

.PARAMETER DevEposChannel
    DevEpos update channel to use for all selected DevEpos plugins: 'dev' or
    'latest'. Defaults to 'latest'. In interactive mode, the selected channel
    is chosen after plugin selection.

.PARAMETER NonInteractive
    Suppresses all prompts. Requires -EclipseVersion. -InstallPath and
    -Features fall back to defaults (default install path, no extra plugins)
    if not supplied.

.PARAMETER CacheDirectory
    Directory used to cache the downloaded Eclipse zip so re-runs don't
    re-download it. Defaults to '%LOCALAPPDATA%\eclipsADT-o-Mat\cache'.

.PARAMETER ListFeatures
    Prints the catalog's available Eclipse versions and plugins, then exits
    without installing anything.

.PARAMETER SkipUpdateCheck
    Skips the startup check whether the local sources (catalog.json, scripts)
    differ from the GitHub repository. The check is also skipped in
    -NonInteractive mode.

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

    [string]$BasePackage,

    [string]$EclipseVersion,

    [string[]]$Features,

    [ValidateSet('dev', 'latest')]
    [string]$DevEposChannel = 'latest',

    [switch]$NonInteractive,

    [string]$CacheDirectory = (Join-Path $env:LOCALAPPDATA 'eclipsADT-o-Mat\cache'),

    [switch]$ListFeatures,

    [switch]$SkipUpdateCheck
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $scriptRoot 'lib\Logging.ps1')
. (Join-Path $scriptRoot 'lib\Ui.ps1')
. (Join-Path $scriptRoot 'lib\Download.ps1')
. (Join-Path $scriptRoot 'lib\P2Director.ps1')
. (Join-Path $scriptRoot 'lib\EclipseInstall.ps1')
. (Join-Path $scriptRoot 'lib\Menu.ps1')
. (Join-Path $scriptRoot 'lib\Catalog.ps1')
. (Join-Path $scriptRoot 'lib\Wizard.ps1')
. (Join-Path $scriptRoot 'lib\Update.ps1')

$catalogPath = Join-Path $scriptRoot 'catalog.json'
if (-not (Test-Path -LiteralPath $catalogPath)) {
    throw "catalog.json not found at '$catalogPath'."
}
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
Write-Log "Loaded catalog: $($catalog.basePackages.Count) base package(s), $($catalog.eclipseVersions.Count) Eclipse version(s), $($catalog.plugins.Count) plugin(s)" -Level DEBUG

if ($ListFeatures) {
    Write-Host "Available base packages:" -ForegroundColor Cyan
    $catalog.basePackages | ForEach-Object {
        $versionCount = if ($_.downloads) { ($_.downloads.PSObject.Properties | Measure-Object).Count } else { $catalog.eclipseVersions.Count }
        Write-Host ("  {0,-10} {1} ({2} supported version(s))" -f $_.id, $_.name, $versionCount)
    }
    Write-Host ""
    Write-Host "Available Eclipse versions:" -ForegroundColor Cyan
    $catalog.eclipseVersions | ForEach-Object { Write-Host ("  {0,-9} {1}" -f $_.id, $_.label) }
    Write-Host ""
    Write-Host "Available plugins:" -ForegroundColor Cyan
    Write-Host ("  {0,-26} {1,-12} {2}" -f 'ID', 'PUBLISHER', 'NAME') -ForegroundColor DarkGray
    $catalog.plugins | ForEach-Object {
        Write-Host ("  {0,-26} {1,-12} {2}" -f $_.id, $_.publisher, $_.name)
    }
    return
}

Initialize-BundlerLog -LogDirectory (Join-Path $scriptRoot 'logs') | Out-Null
Write-Log "Parameters: InstallPath='$InstallPath' BasePackage='$BasePackage' EclipseVersion='$EclipseVersion' Features=$($Features -join ',') DevEposChannel='$DevEposChannel' NonInteractive=$NonInteractive CacheDirectory='$CacheDirectory'" -Level DEBUG

if (-not $NonInteractive -and (Test-InteractiveConsole)) {
    Write-Banner -Title 'eclipsADT-o-Mat' -Subtitle 'Installer for Eclipse + ABAP Development Tools + Additional Plugins'
}
Write-Log "eclipsADT-o-Mat starting." -Level INFO

# --- Update check --------------------------------------------------------------
if (-not $SkipUpdateCheck -and -not $NonInteractive) {
    $changedFiles = Test-SourceUpdateAvailable -ScriptRoot $scriptRoot
    if ($changedFiles -and $changedFiles.Count -gt 0) {
        Write-Log "An update is available: $($changedFiles.Count) file(s) differ from GitHub ($($changedFiles -join ', '))" -Level DEBUG
        Write-UpdateNotice -ChangedFiles $changedFiles
        if (Read-YesNo "Update local sources now? (local changes to these files will be overwritten)") {
            if (Invoke-SourceUpdate -ScriptRoot $scriptRoot) {
                Write-Log "Restarting wizard with updated sources..." -Level INFO
                Write-Host ""
                $restartParams = @{} + $PSBoundParameters
                $restartParams['SkipUpdateCheck'] = $true
                & $PSCommandPath @restartParams
                exit $LASTEXITCODE
            }
            Write-Log "Continuing with the existing local sources." -Level WARN
        }
    }
}

if ($NonInteractive -and -not $EclipseVersion) {
    throw "-NonInteractive requires -EclipseVersion to be specified (use -ListFeatures to see available versions)."
}

# --- Step 1: base package -----------------------------------------------------
$basePackageEntry = Resolve-BasePackageSelection -Catalog $catalog -BasePackage $BasePackage -NonInteractive:$NonInteractive

# --- Step 2: Eclipse version --------------------------------------------------
$EclipseVersion = Resolve-EclipseVersionSelection -Catalog $catalog -BasePackageEntry $basePackageEntry -EclipseVersion $EclipseVersion -NonInteractive:$NonInteractive

# --- Step 3: install path ----------------------------------------------------
$installLocation = Resolve-InstallLocation -Catalog $catalog -BasePackageEntry $basePackageEntry -EclipseVersion $EclipseVersion -InstallPath $InstallPath -NonInteractive:$NonInteractive
if (-not $installLocation) { exit 0 }
$InstallPath = $installLocation.InstallPath
$reuseExistingEclipseRoot = $installLocation.ReuseExistingEclipseRoot

# --- Step 4: plugin selection -------------------------------------------------
$selectedPlugins = Resolve-PluginSelection -Catalog $catalog -Features $Features -NonInteractive:$NonInteractive
$activeDevEposChannel = Resolve-DevEposChannel -Catalog $catalog -SelectedPlugins $selectedPlugins -DevEposChannel $DevEposChannel -NonInteractive:$NonInteractive

# --- Step 5: confirmation -----------------------------------------------------
if (-not $NonInteractive) {
    $confirmed = Show-InstallationSummary -Catalog $catalog -BasePackageEntry $basePackageEntry -EclipseVersion $EclipseVersion `
        -InstallPath $InstallPath -ReuseExistingEclipseRoot $reuseExistingEclipseRoot `
        -SelectedPlugins $selectedPlugins -ActiveDevEposChannel $activeDevEposChannel
    if (-not $confirmed) {
        Write-Log "Aborted by user." -Level WARN
        exit 0
    }
}

# --- Step 6: download, extract & install --------------------------------------
if (-not $NonInteractive) {
    Write-StepHeader -Step 6 -Total 6 -Title 'Download & install'
}

$installation = Resolve-EclipseInstallation -BasePackageEntry $basePackageEntry -EclipseVersion $EclipseVersion `
    -InstallPath $InstallPath -ReuseExistingEclipseRoot $reuseExistingEclipseRoot -CacheDirectory $CacheDirectory

$results = Install-AdtAndPlugins -Catalog $catalog -EclipseExePath $installation.EclipseExePath -EclipseRoot $installation.EclipseRoot `
    -EclipseVersion $EclipseVersion -SelectedPlugins $selectedPlugins -ActiveDevEposChannel $activeDevEposChannel

Show-ResultsSummary -Results $results -EclipseRoot $installation.EclipseRoot
