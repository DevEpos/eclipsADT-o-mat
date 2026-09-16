<#
.SYNOPSIS
    Wrapper around the Eclipse p2 director application (eclipsec.exe) for
    headless installation of features into an extracted Eclipse instance.

.DESCRIPTION
    Invoke-P2Director drives 'eclipsec.exe -application org.eclipse.equinox.p2.director'
    to install one or more installable units (feature groups) from one or more
    p2 repositories into an existing Eclipse installation's profile.

    Notes learned from manual verification (see installer/README.md):
    - The p2 profile of an "Eclipse IDE for Java Developers" package is
      'epp.package.java' (not 'SDKProfile').
    - ADT's version-specific p2 repo (https://tools.hana.ondemand.com/<version>)
      must be paired with the matching Eclipse release train, or core platform
      bundle version mismatches cause resolution failures.
    - ADT's full feature set (com.sap.adt.core.feature.group) transitively
      requires a handful of EMF sub-features (workspace, databinding.edit,
      validation) that are not bundled in the base Java Developers package.
      These must be requested from https://download.eclipse.org/releases/<version>
      alongside the ADT repo in the same director call. catalog.json already
      lists these as part of the 'adt' entry's installableUnits/additionalRepoUrlTemplates.
#>

function Get-EclipseP2Profile {
    <#
    .SYNOPSIS
        Determines the p2 profile id of an extracted Eclipse installation by
        reading config.ini, falling back to the profileRegistry folder name.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EclipseInstallPath
    )

    $configIni = Join-Path $EclipseInstallPath 'configuration\config.ini'
    if (Test-Path -LiteralPath $configIni) {
        $line = Select-String -LiteralPath $configIni -Pattern '^eclipse\.p2\.profile\s*=\s*(.+)$' -ErrorAction SilentlyContinue
        if ($line) {
            return $line.Matches[0].Groups[1].Value.Trim()
        }
    }

    $profileRegistry = Join-Path $EclipseInstallPath 'p2\org.eclipse.equinox.p2.engine\profileRegistry'
    if (Test-Path -LiteralPath $profileRegistry) {
        $profileDir = Get-ChildItem -LiteralPath $profileRegistry -Filter '*.profile' -Directory | Select-Object -First 1
        if ($profileDir) {
            return $profileDir.BaseName
        }
    }

    # Reasonable default for Eclipse IDE for Java Developers packages.
    return 'epp.package.java'
}

function Invoke-P2Director {
    <#
    .SYNOPSIS
        Installs one or more installable units from one or more p2 repositories
        into an Eclipse installation, headlessly.

    .PARAMETER EclipseExePath
        Full path to eclipsec.exe inside the target Eclipse installation.

    .PARAMETER Repositories
        Array of p2 repository URLs to consult (metadata + artifacts).

    .PARAMETER InstallIUs
        Array of installable unit ids (typically '<feature-id>.feature.group')
        to install in a single director call. Passing all related IUs together
        (e.g. ADT + its extra EMF dependencies) in one call is important -
        resolving them one-by-one across separate calls can surface only the
        first unresolved dependency at a time.

    .PARAMETER DestinationPath
        Path to the Eclipse installation root (the folder containing eclipse.exe).

    .PARAMETER Profile
        The p2 profile id to install into. Defaults to 'epp.package.java'.

    .PARAMETER Description
        Human-friendly label used only for logging.

    .PARAMETER RetryCount
        Number of times to retry after a failed director process. Defaults to 2.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EclipseExePath,

        [Parameter(Mandatory)]
        [string[]]$Repositories,

        [Parameter(Mandatory)]
        [string[]]$InstallIUs,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$Profile,

        [string]$Description = ($InstallIUs -join ', '),

        [ValidateRange(0, 2)]
        [int]$RetryCount = 2
    )

    if (-not (Test-Path -LiteralPath $EclipseExePath)) {
        throw "eclipsec.exe not found at '$EclipseExePath'."
    }

    if (-not $Profile) {
        $Profile = Get-EclipseP2Profile -EclipseInstallPath (Split-Path -Parent $EclipseExePath)
    }

    $repoArg = ($Repositories | Select-Object -Unique) -join ','
    $iuArg = ($InstallIUs | Select-Object -Unique) -join ','

    Write-Log "Installing via p2 director: $Description" -Level INFO
    Write-Log "  Repositories: $repoArg" -Level INFO
    Write-Log "  Installable units: $iuArg" -Level INFO
    Write-Log "  Profile: $Profile" -Level INFO

    $directorArgs = @(
        '-nosplash'
        '-application', 'org.eclipse.equinox.p2.director'
        '-repository', $repoArg
        '-installIU', $iuArg
        '-destination', $DestinationPath
        '-profile', $Profile
        '-followReferences'
    )

    $output = @()
    $attempt = 0
    do {
        $attempt++

        # Redirect output to temp files so a spinner can tail progress while eclipsec runs.
        $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("adt-bundler-p2-" + [Guid]::NewGuid().ToString('N'))
        $stdoutFile = "$tempBase.out.log"
        $stderrFile = "$tempBase.err.log"

        $spinner = Start-ConsoleSpinner -Activity "Installing $Description (attempt $attempt/$($RetryCount + 1))"
        try {
            $proc = Start-Process -FilePath $EclipseExePath -ArgumentList $directorArgs -NoNewWindow -PassThru `
                -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            while (-not $proc.HasExited) {
                $lastLine = Get-Content -LiteralPath $stdoutFile -Tail 1 -ErrorAction SilentlyContinue
                Update-ConsoleSpinner -Spinner $spinner -Status ([string]$lastLine)
                Start-Sleep -Milliseconds 150
            }
            $proc.WaitForExit()
            $exitCode = $proc.ExitCode
        } finally {
            Stop-ConsoleSpinner -Spinner $spinner
        }

        foreach ($file in @($stdoutFile, $stderrFile)) {
            if (Test-Path -LiteralPath $file) {
                $output += @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }

        if ($exitCode -ne 0 -and $attempt -le $RetryCount) {
            Write-Log "Installation attempt $attempt failed for $Description (exit code $exitCode); retrying." -Level WARN
        }
    } while ($exitCode -ne 0 -and $attempt -le $RetryCount)

    if ($exitCode -eq 0) {
        Write-Log "Installed successfully: $Description" -Level SUCCESS
        return [PSCustomObject]@{ Success = $true; ExitCode = $exitCode; Output = $output }
    }

    # Surface the most useful lines (missing requirements / failure summary)
    # instead of the full (often very verbose) director output.
    $relevantLines = $output | Where-Object {
        $_ -match 'Missing requirement|Cannot satisfy dependency|Installation failed|Cannot complete the install|^\s*From:|^\s*To:'
    }

    Write-Log "Installation FAILED: $Description (exit code $exitCode)" -Level ERROR
    foreach ($line in $relevantLines) {
        Write-Log "  $line" -Level ERROR
    }

    return [PSCustomObject]@{ Success = $false; ExitCode = $exitCode; Output = $output }
}
