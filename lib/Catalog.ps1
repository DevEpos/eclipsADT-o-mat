<#
.SYNOPSIS
    Catalog lookup helpers: URL templating, supported-version filtering and
    download URL resolution for a chosen base package.
#>

function Expand-Template {
    param([string]$Template, [string]$Version)
    return $Template.Replace('{version}', $Version)
}

function Get-SupportedEclipseVersions {
    <#
    .SYNOPSIS
        Returns the catalog.eclipseVersions entries supported by a given base
        package (all of them for template-based packages, only the ones with
        a 'downloads' entry for packages that use per-version URLs).
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] $BasePackageEntry
    )

    if ($BasePackageEntry.downloads) {
        $supportedIds = @($BasePackageEntry.downloads.PSObject.Properties.Name)
        $supported = @($Catalog.eclipseVersions | Where-Object { $_.id -in $supportedIds })
        Write-Log "Get-SupportedEclipseVersions: '$($BasePackageEntry.id)' supports $($supported.Count) of $($Catalog.eclipseVersions.Count) version(s)" -Level DEBUG
        return $supported
    }
    return @($Catalog.eclipseVersions)
}

function Resolve-BasePackageDownload {
    <#
    .SYNOPSIS
        Resolves the primary/fallback download URLs and cache file name for a
        base package + Eclipse version, whether the package is templated
        (java, rcp, ...) or uses explicit per-version URLs (platform).
    #>
    param(
        [Parameter(Mandatory)] $BasePackageEntry,
        [Parameter(Mandatory)] [string]$Version
    )

    if ($BasePackageEntry.downloads) {
        $entry = $BasePackageEntry.downloads.$Version
        if (-not $entry) {
            throw "Base package '$($BasePackageEntry.id)' does not support Eclipse version '$Version'. Run with -ListFeatures to see supported versions."
        }
        $url = $entry.url
        $fallbackUrl = $entry.fallbackUrl
    } else {
        $url = Expand-Template -Template $BasePackageEntry.urlTemplate -Version $Version
        $fallbackUrl = if ($BasePackageEntry.fallbackUrlTemplate) { Expand-Template -Template $BasePackageEntry.fallbackUrlTemplate -Version $Version } else { $null }
    }

    if ($fallbackUrl) {
        # Derive the cache file name from the (query-string free) fallback URL's leaf segment.
        $zipFileName = Split-Path -Leaf ([uri]$fallbackUrl).AbsolutePath
    } else {
        # No fallback URL - extract the real file name from the primary URL's 'file' query parameter instead.
        $fileParam = [regex]::Match(([uri]$url).Query, '[?&]file=([^&]+)').Groups[1].Value
        $zipFileName = Split-Path -Leaf ([uri]::UnescapeDataString($fileParam))
    }

    Write-Log "Resolve-BasePackageDownload: url='$url' fallbackUrl='$fallbackUrl' zipFileName='$zipFileName'" -Level DEBUG
    return [PSCustomObject]@{ Url = $url; FallbackUrl = $fallbackUrl; ZipFileName = $zipFileName }
}
