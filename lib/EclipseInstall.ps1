<#
.SYNOPSIS
    Detection/compatibility helpers for locating and validating an existing
    Eclipse installation on disk.

.DESCRIPTION
    Find-ExistingEclipse locates an already-extracted Eclipse install under a
    given path. Resolve-EclipseVersionIdFromInstall / Test-ExistingEclipseBasePackage
    / Test-ExistingEclipseCompatible check whether that install matches the
    requested catalog release train / base package.
#>

function Resolve-EclipseInstallRoot {
    param([Parameter(Mandatory)] [string]$InstallPath)

    if (Test-Path -LiteralPath $InstallPath -PathType Container) {
        $hasExistingContent = [bool](Get-ChildItem -LiteralPath $InstallPath -Force -ErrorAction Stop | Select-Object -First 1)
        if ($hasExistingContent) {
            return (Join-Path $InstallPath 'eclipse')
        }
    }

    return $InstallPath
}

function Find-ExistingEclipse {
    <#
    .SYNOPSIS
        Returns the root of an existing Eclipse installation reachable from
        $InstallPath (either directly or in the 'eclipse' subfolder that
        Resolve-EclipseInstallRoot would have created), or $null if none.
    #>
    param([Parameter(Mandatory)] [string]$InstallPath)

    foreach ($candidate in @($InstallPath, (Join-Path $InstallPath 'eclipse'))) {
        Write-Log "Find-ExistingEclipse: checking '$candidate'" -Level DEBUG
        if (Test-Path -LiteralPath (Join-Path $candidate 'eclipse.exe')) {
            $resolved = (Resolve-Path -LiteralPath $candidate).Path
            Write-Log "Find-ExistingEclipse: found existing installation at '$resolved'" -Level DEBUG
            return $resolved
        }
    }
    Write-Log "Find-ExistingEclipse: no existing installation found under '$InstallPath'" -Level DEBUG
    return $null
}

function Get-InstalledEclipsePlatformVersion {
    <#
    .SYNOPSIS
        Reads the major.minor Eclipse platform version (e.g. '4.36') from an
        existing installation, or $null if it can't be determined.
    #>
    param([Parameter(Mandatory)] [string]$EclipseRoot)

    # The platform feature folder/jar carries the major.minor version reliably
    # across both EPP (java/rcp) and minimal 'platform' packages.
    $featuresDir = Join-Path $EclipseRoot 'features'
    if (Test-Path -LiteralPath $featuresDir) {
        $feature = Get-ChildItem -LiteralPath $featuresDir -Filter 'org.eclipse.platform_*' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($feature -and $feature.Name -match 'org\.eclipse\.platform_(\d+\.\d+)') {
            return $Matches[1]
        }
    }

    # Fall back to the .eclipseproduct marker file at the install root.
    $productFile = Join-Path $EclipseRoot '.eclipseproduct'
    if (Test-Path -LiteralPath $productFile) {
        $versionLine = Get-Content -LiteralPath $productFile | Where-Object { $_ -match '^version=(\d+\.\d+)' } | Select-Object -First 1
        if ($versionLine -match '^version=(\d+\.\d+)') {
            return $Matches[1]
        }
    }

    return $null
}

function Resolve-EclipseVersionIdFromInstall {
    <#
    .SYNOPSIS
        Maps an existing Eclipse installation to its catalog release-train id
        (e.g. '2025-06') by matching the installed platform version against the
        catalog's eclipseVersions labels, or $null if it can't be resolved.
    #>
    param(
        [Parameter(Mandatory)] [string]$EclipseRoot,

        [Parameter(Mandatory)] $EclipseVersions
    )

    $platformVersion = Get-InstalledEclipsePlatformVersion -EclipseRoot $EclipseRoot
    Write-Log "Resolve-EclipseVersionIdFromInstall: detected platform version '$platformVersion' at '$EclipseRoot'" -Level DEBUG
    if (-not $platformVersion) { return $null }

    foreach ($version in $EclipseVersions) {
        if ($version.label -match "\($([regex]::Escape($platformVersion))\)") {
            Write-Log "Resolve-EclipseVersionIdFromInstall: matched catalog version '$($version.id)'" -Level DEBUG
            return $version.id
        }
    }
    Write-Log "Resolve-EclipseVersionIdFromInstall: no catalog version matched platform version '$platformVersion'" -Level DEBUG
    return $null
}

function Test-ExistingEclipseBasePackage {
    <#
    .SYNOPSIS
        Returns $true if an existing Eclipse installation's base package (its
        p2 profile, e.g. 'epp.package.java') matches the chosen base package
        entry from the catalog.
    #>
    param(
        [Parameter(Mandatory)] [string]$EclipseRoot,

        [Parameter(Mandatory)] $BasePackageEntry
    )

    if (-not $BasePackageEntry.p2Profile) { return $true }

    $installedProfile = Get-EclipseP2Profile -EclipseInstallPath $EclipseRoot
    Write-Log "Test-ExistingEclipseBasePackage: detected profile '$installedProfile' at '$EclipseRoot', expected '$($BasePackageEntry.p2Profile)'" -Level DEBUG
    return $installedProfile -eq $BasePackageEntry.p2Profile
}

function Test-ExistingEclipseCompatible {
    <#
    .SYNOPSIS
        Returns $true if an existing Eclipse installation matches both the
        requested release train and the requested base package.
    #>
    param(
        [Parameter(Mandatory)] [string]$EclipseRoot,

        [Parameter(Mandatory)] $Catalog,

        [Parameter(Mandatory)] [string]$EclipseVersion,

        [Parameter(Mandatory)] $BasePackageEntry
    )

    $installedVersion = Resolve-EclipseVersionIdFromInstall -EclipseRoot $EclipseRoot -EclipseVersions $Catalog.eclipseVersions
    if ($installedVersion -ne $EclipseVersion) { return $false }

    return (Test-ExistingEclipseBasePackage -EclipseRoot $EclipseRoot -BasePackageEntry $BasePackageEntry)
}
