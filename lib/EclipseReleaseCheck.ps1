#Requires -Version 7.0
<#
.SYNOPSIS
    Checks whether a new Eclipse simultaneous release train is available and,
    if so, updates catalog.json with the new eclipseVersions entry and the
    matching 'platform' base package download URLs.

.DESCRIPTION
    Eclipse ships a new simultaneous release every quarter (March, June,
    September, December), identified by a "YYYY-MM" id (catalog.json's
    eclipseVersions) and an internal minor version (4.NN). The 'java' and
    'rcp' base packages use templated URLs, so only a new eclipseVersions
    entry is required for them. The 'platform' base package instead needs an
    explicit download URL because its zip filename embeds a build-specific
    timestamp (e.g. R-4.41-202608281142), so this script scrapes Eclipse's
    drops4 build directory listing to discover it.

    Intended to be run from a scheduled GitHub Actions workflow. Emits
    'updated' and 'version' to $env:GITHUB_OUTPUT when running in CI.

.PARAMETER CatalogPath
    Path to catalog.json. Defaults to catalog.json next to the repo root.

.EXAMPLE
    .\lib\EclipseReleaseCheck.ps1
    Checks for a new release and rewrites catalog.json in place if found.
#>
[CmdletBinding()]
param(
    [string]$CatalogPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Logging.ps1')

$script:DropsBaseUrl = 'https://archive.eclipse.org/eclipse/downloads/drops4/'

function Get-NextEclipseVersion {
    <#
    .SYNOPSIS
        Computes the next quarterly release id (YYYY-MM) and the next
        platform minor version number (4.NN) from the current catalog.
    #>
    param([Parameter(Mandatory)] $Catalog)

    $versionIds = @($Catalog.eclipseVersions | ForEach-Object { $_.id } | Sort-Object)
    $latestId = $versionIds[-1]
    $latestYear = [int]($latestId -split '-')[0]
    $latestMonth = [int]($latestId -split '-')[1]

    $nextMonth = $latestMonth + 3
    $nextYear = $latestYear
    if ($nextMonth -gt 12) {
        $nextMonth -= 12
        $nextYear += 1
    }
    $nextVersionId = '{0:D4}-{1:D2}' -f $nextYear, $nextMonth

    $platformFileNames = @($Catalog.basePackages | Where-Object { $_.id -eq 'platform' } |
            ForEach-Object { $_.downloads.PSObject.Properties.Value.url })
    $minors = @($platformFileNames | ForEach-Object {
            if ($_ -match 'eclipse-platform-4\.(\d+)-') { [int]$Matches[1] }
        })
    $nextMinor = ($minors | Sort-Object)[-1] + 1

    return [PSCustomObject]@{ VersionId = $nextVersionId; PlatformMinor = $nextMinor }
}

function Find-PlatformBuild {
    <#
    .SYNOPSIS
        Looks up the drops4 build folder and win32 x86_64 zip filename for a
        given platform minor version (e.g. 42 -> R-4.42-<timestamp>/...zip).
        Returns $null if the build isn't published yet.

    .DESCRIPTION
        The build folder's own page renders its file list via client-side JS
        from a 'buildproperties.json' manifest, so that manifest is queried
        directly instead of scraping HTML for the exact win32 x86_64 zip
        filename (Eclipse has used both 'eclipse-platform-4.NN-win32-x86_64.zip'
        and, since 4.40, the doubled 'eclipse-platform-4.NN-win32-win32-x86_64.zip').
    #>
    param([Parameter(Mandatory)] [int]$Minor)

    $listing = Invoke-WebRequest -Uri $script:DropsBaseUrl -UseBasicParsing
    $folderMatch = [regex]::Match($listing.Content, "href='/eclipse/downloads/drops4/(R-4\.$Minor-\d+)'")
    if (-not $folderMatch.Success) {
        Write-Log "No drops4 build folder found yet for 4.$Minor." -Level DEBUG
        return $null
    }
    $folder = $folderMatch.Groups[1].Value

    $manifest = Invoke-WebRequest -Uri "$script:DropsBaseUrl$folder/buildproperties.json" -UseBasicParsing |
        Select-Object -ExpandProperty Content | ConvertFrom-Json
    $platformZip = $manifest.platformProducts | Where-Object { $_.name -match "^eclipse-platform-4\.$Minor-(?:win32-)?win32-x86_64\.zip$" } |
        Select-Object -First 1
    if (-not $platformZip) {
        throw "Found drops4 folder '$folder' for 4.$Minor but no matching win32 x86_64 platform zip in its buildproperties.json - Eclipse may have changed its naming scheme."
    }

    return [PSCustomObject]@{ Folder = $folder; FileName = $platformZip.name }
}

function Test-EppReleaseAvailable {
    <#
    .SYNOPSIS
        Confirms the java/rcp epp build for the given version id is
        published, using the same download.php mirror redirector as the
        'java'/'rcp' base packages' urlTemplate.

    .DESCRIPTION
        download.php always answers 200 even for a file that doesn't exist
        yet, returning an HTML mirror-selection/error page instead - so the
        response's Content-Type is checked rather than just its status code.
    #>
    param([Parameter(Mandatory)] [string]$VersionId)

    $url = "https://www.eclipse.org/downloads/download.php?file=/technology/epp/downloads/release/$VersionId/R/eclipse-java-$VersionId-R-win32-x86_64.zip&r=1"
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing
        return $response.StatusCode -eq 200 -and $response.Headers['Content-Type'] -like 'application/zip*'
    } catch {
        return $false
    }
}

function Add-EclipseReleaseToCatalog {
    <#
    .SYNOPSIS
        Appends the new eclipseVersions entry and platform download URLs to
        the in-memory catalog object.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] [string]$VersionId,
        [Parameter(Mandatory)] [int]$Minor,
        [Parameter(Mandatory)] $PlatformBuild
    )

    $Catalog.eclipseVersions += [PSCustomObject]@{ id = $VersionId; label = "$VersionId (4.$Minor)" }

    $platformPackage = $Catalog.basePackages | Where-Object { $_.id -eq 'platform' }
    $downloadEntry = [PSCustomObject]@{
        url         = "https://www.eclipse.org/downloads/download.php?file=/eclipse/downloads/drops4/$($PlatformBuild.Folder)/$($PlatformBuild.FileName)&r=1"
        fallbackUrl = "$script:DropsBaseUrl$($PlatformBuild.Folder)/$($PlatformBuild.FileName)"
    }
    $platformPackage.downloads | Add-Member -NotePropertyName $VersionId -NotePropertyValue $downloadEntry
}

function Write-GitHubOutput {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
}

# --- Main ---

$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$next = Get-NextEclipseVersion -Catalog $catalog
Write-Log "Latest known release: $($catalog.eclipseVersions[-1].id). Checking for $($next.VersionId) (4.$($next.PlatformMinor))..." -Level INFO

$platformBuild = Find-PlatformBuild -Minor $next.PlatformMinor
if (-not $platformBuild) {
    Write-Log "No new Eclipse release found." -Level INFO
    Write-GitHubOutput -Name 'updated' -Value 'false'
    exit 0
}

if (-not (Test-EppReleaseAvailable -VersionId $next.VersionId)) {
    Write-Log "Platform build $($platformBuild.Folder) exists but the epp (java/rcp) release for $($next.VersionId) is not published yet." -Level INFO
    Write-GitHubOutput -Name 'updated' -Value 'false'
    exit 0
}

Add-EclipseReleaseToCatalog -Catalog $catalog -VersionId $next.VersionId -Minor $next.PlatformMinor -PlatformBuild $platformBuild
$catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CatalogPath -Encoding utf8

Write-Log "Added Eclipse $($next.VersionId) (4.$($next.PlatformMinor)) to catalog.json." -Level SUCCESS
Write-GitHubOutput -Name 'updated' -Value 'true'
Write-GitHubOutput -Name 'version' -Value $next.VersionId
