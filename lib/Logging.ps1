<#
.SYNOPSIS
    Minimal logging helpers shared by eclipsADT-o-Mat scripts.

.DESCRIPTION
    Provides Write-Log for console + optional log-file output and
    Initialize-BundlerLog to configure the active log file for a run.
    Only built-in PowerShell cmdlets are used - no external modules required.
#>

$script:BundlerLogFilePath = $null

function Initialize-BundlerLog {
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:BundlerLogFilePath = Join-Path $LogDirectory "adt-bundler-$timestamp.log"
    "eclipsADT-o-Mat log started $(Get-Date -Format 'u')" | Out-File -FilePath $script:BundlerLogFilePath -Encoding utf8
    return $script:BundlerLogFilePath
}

function Write-Log {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }

    if ($script:BundlerLogFilePath) {
        $line | Out-File -FilePath $script:BundlerLogFilePath -Append -Encoding utf8
    }
}
