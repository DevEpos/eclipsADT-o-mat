<#
.SYNOPSIS
    Self-update helpers for the single-file (bundled) distribution of
    eclipsADT-o-Mat.

.DESCRIPTION
    The bundled release script carries its release tag in
    $script:DistributionVersion (injected by build/New-Bundle.ps1). These
    helpers compare that tag against the latest GitHub release, download the
    newer bundled script asset and replace the running script file in place.
#>

$script:ReleaseRepoOwner = 'DevEpos'
$script:ReleaseRepoName = 'eclipsADT-o-mat'
$script:ReleaseAssetName = 'eclipsADT-o-mat.ps1'

function ConvertTo-ReleaseVersion {
    <#
    .SYNOPSIS
        Parses a release tag like 'v1.2.3' into a semantic version, or $null
        if the tag is not a valid semver.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Tag
    )

    $parsed = $null
    if ([System.Management.Automation.SemanticVersion]::TryParse(($Tag -replace '^[vV]', ''), [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-LatestRelease {
    <#
    .SYNOPSIS
        Returns the latest GitHub release (tag + bundled script asset URL),
        or $null if it cannot be determined (offline, rate-limited, no
        release, missing asset, ...).
    #>
    param()

    $uri = "https://api.github.com/repos/$script:ReleaseRepoOwner/$script:ReleaseRepoName/releases/latest"
    try {
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec 10 -Headers @{
            'User-Agent' = 'eclipsADT-o-Mat'
            'Accept'     = 'application/vnd.github+json'
        }
    } catch {
        Write-Log "Update check: could not query GitHub releases API: $($_.Exception.Message)" -Level DEBUG
        return $null
    }

    $asset = @($response.assets) | Where-Object { $_.name -eq $script:ReleaseAssetName } | Select-Object -First 1
    if (-not $asset) {
        Write-Log "Update check: release '$($response.tag_name)' has no '$script:ReleaseAssetName' asset." -Level DEBUG
        return $null
    }

    return [PSCustomObject]@{
        Tag      = $response.tag_name
        AssetUrl = $asset.browser_download_url
    }
}

function Test-ReleaseUpdateAvailable {
    <#
    .SYNOPSIS
        Returns the latest release object when it is newer than
        $CurrentVersion, otherwise $null.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CurrentVersion
    )

    $release = Get-LatestRelease
    if (-not $release) { return $null }

    $current = ConvertTo-ReleaseVersion -Tag $CurrentVersion
    $latest = ConvertTo-ReleaseVersion -Tag $release.Tag
    if (-not $current -or -not $latest) {
        Write-Log "Update check: could not compare versions ('$CurrentVersion' vs '$($release.Tag)')." -Level DEBUG
        return $null
    }

    Write-Log "Update check: current $current, latest release $latest." -Level DEBUG
    if ($latest -gt $current) { return $release }
    return $null
}

function Write-ReleaseUpdateNotice {
    <#
    .SYNOPSIS
        Prints an eye-catching colored notice that a newer release is
        available.
    #>
    param(
        [Parameter(Mandatory)]
        $Release,

        [Parameter(Mandatory)]
        [string]$CurrentVersion
    )

    $accent = $script:UiTheme ? $script:UiTheme.Category : 'Magenta'
    $muted = $script:UiTheme ? $script:UiTheme.Muted : 'DarkGray'

    Write-Host ""
    Write-Host "  Update available! " -ForegroundColor $accent -NoNewline
    Write-Host "$($Release.Tag) (you are running $CurrentVersion)" -ForegroundColor $accent
    Write-Host "    https://github.com/$script:ReleaseRepoOwner/$script:ReleaseRepoName/releases/latest" -ForegroundColor $muted
    Write-Host ""
}

function Invoke-ReleaseSelfUpdate {
    <#
    .SYNOPSIS
        Downloads the bundled script asset of the given release and replaces
        the running script file with it. Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        $Release
    )

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "eclipsADT-o-Mat-$([System.IO.Path]::GetRandomFileName()).ps1"
    try {
        Write-Log "Downloading $($Release.Tag) from $($Release.AssetUrl)" -Level INFO
        Save-FileWithProgress -Url $Release.AssetUrl -Destination $tempFile -DisplayName "eclipsADT-o-Mat $($Release.Tag)"

        # Refuse to replace the running script with something that doesn't even parse.
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($tempFile, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            throw "Downloaded script has $($parseErrors.Count) parse error(s); keeping the current version."
        }

        Copy-Item -LiteralPath $tempFile -Destination $ScriptPath -Force
        Write-Log "Updated to $($Release.Tag)." -Level SUCCESS
        return $true
    } catch {
        Write-Log "Self-update failed: $($_.Exception.Message)" -Level ERROR
        return $false
    } finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}
