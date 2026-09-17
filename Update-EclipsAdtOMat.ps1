#Requires -Version 7.0
<#
.SYNOPSIS
    Checks GitHub for changed eclipsADT-o-Mat sources (catalog.json, scripts)
    and updates the local files after confirmation.

.DESCRIPTION
    Compares every file tracked in the GitHub repository against its local
    counterpart using git blob hashes - no git installation or .git folder is
    required, so installations downloaded as a zip are supported as well.
    If differences are found, the branch zipball is downloaded and the local
    sources are overwritten. Extra local files (logs, caches) are preserved.

.PARAMETER Force
    Applies the update without asking for confirmation.

.EXAMPLE
    .\Update-EclipsAdtOMat.ps1
    Checks for changes and asks before updating.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $scriptRoot 'lib\Logging.ps1')
. (Join-Path $scriptRoot 'lib\Ui.ps1')
. (Join-Path $scriptRoot 'lib\Menu.ps1')
. (Join-Path $scriptRoot 'lib\Download.ps1')
. (Join-Path $scriptRoot 'lib\Update.ps1')

Initialize-BundlerLog -LogDirectory (Join-Path $scriptRoot 'logs') | Out-Null

if (Test-InteractiveConsole) {
    Write-Banner -Title 'eclipsADT-o-Mat' -Subtitle 'Source updater'
}

Write-Log "Checking GitHub for source updates..." -Level INFO
$changedFiles = Test-SourceUpdateAvailable -ScriptRoot $scriptRoot

if ($null -eq $changedFiles) {
    Write-Log "Could not check GitHub for updates (offline or rate-limited). Try again later." -Level WARN
    exit 1
}

if ($changedFiles.Count -eq 0) {
    Write-Log "Local sources are up to date." -Level SUCCESS
    exit 0
}

Write-Log "$($changedFiles.Count) file(s) differ from GitHub:" -Level DEBUG
Write-UpdateNotice -ChangedFiles $changedFiles

if (-not $Force) {
    if (-not (Read-YesNo "Update local sources now? (local changes to these files will be overwritten)")) {
        Write-Log "Update skipped by user." -Level INFO
        exit 0
    }
}

if (-not (Invoke-SourceUpdate -ScriptRoot $scriptRoot)) {
    exit 1
}
