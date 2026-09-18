<#
.SYNOPSIS
    Java runtime detection and provisioning for eclipsADT-o-Mat.

.DESCRIPTION
    The EPP base packages (java, rcp) bundle a JustJ JRE, but the minimal
    'platform' package ships without any JVM - eclipsec.exe then aborts with
    "A Java Runtime Environment (JRE) ... must be available" before the p2
    director can even run. Test-EclipseJavaRuntime detects whether an install
    can find a usable JVM; Install-EclipseJre downloads the latest JustJ
    JRE 21 (the same runtime the EPP packages embed) and extracts it to
    '<eclipseRoot>\jre', the first location eclipsec.exe searches.
#>

$script:JustJJreBaseUrl = 'https://download.eclipse.org/justj/jres/21/downloads/latest'

function Get-PathJavaMajorVersion {
    <#
    .SYNOPSIS
        Returns the major version of java.exe on PATH, or $null if java is
        not on PATH / the version cannot be determined.
    #>
    $javaCmd = Get-Command java.exe -ErrorAction SilentlyContinue
    if (-not $javaCmd) { return $null }
    try {
        # 'java -version' prints e.g. 'openjdk version "21.0.4" ...' to stderr.
        $versionOutput = (& $javaCmd.Source -version 2>&1) -join "`n"
        if ($versionOutput -match 'version\s+"(\d+)(?:\.(\d+))?') {
            $major = [int]$Matches[1]
            if ($major -eq 1 -and $Matches[2]) { $major = [int]$Matches[2] }  # legacy '1.8' style
            return $major
        }
    } catch {
        Write-Log "Get-PathJavaMajorVersion: failed to run java -version: $($_.Exception.Message)" -Level DEBUG
    }
    return $null
}

function Test-EclipseJavaRuntime {
    <#
    .SYNOPSIS
        Returns $true when eclipsec.exe at the given Eclipse root will find a
        suitable JVM: a local 'jre' folder, a -vm entry in eclipse.ini (EPP
        packages point it at their embedded JustJ JRE), or a modern enough
        java.exe on PATH.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EclipseRoot,

        [int]$MinimumMajorVersion = 21
    )

    if (Test-Path -LiteralPath (Join-Path $EclipseRoot 'jre\bin\java.exe')) {
        Write-Log "Test-EclipseJavaRuntime: found local jre folder." -Level DEBUG
        return $true
    }

    $iniPath = Join-Path $EclipseRoot 'eclipse.ini'
    if ((Test-Path -LiteralPath $iniPath) -and ((Get-Content -LiteralPath $iniPath -Raw) -match '(?m)^-vm\s*$')) {
        Write-Log "Test-EclipseJavaRuntime: eclipse.ini contains a -vm entry." -Level DEBUG
        return $true
    }

    $pathJavaMajor = Get-PathJavaMajorVersion
    if ($pathJavaMajor -ge $MinimumMajorVersion) {
        Write-Log "Test-EclipseJavaRuntime: java $pathJavaMajor found on PATH." -Level DEBUG
        return $true
    }
    if ($pathJavaMajor) {
        Write-Log "Java $pathJavaMajor found on PATH, but Eclipse requires Java $MinimumMajorVersion or newer." -Level WARN
    }
    return $false
}

function Install-EclipseJre {
    <#
    .SYNOPSIS
        Downloads the latest JustJ JRE 21 (win32-x86_64 tar.gz) and extracts
        it to '<eclipseRoot>\jre' so eclipsec.exe can launch without a
        system-wide Java installation.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EclipseRoot,

        [Parameter(Mandatory)]
        [string]$CacheDirectory
    )

    Write-Log "No usable Java runtime found - provisioning a JustJ JRE 21 into '$EclipseRoot\jre'." -Level INFO

    $tarCmd = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tarCmd) {
        throw "Cannot extract the JRE archive: 'tar.exe' was not found (requires Windows 10 1803+). Install a Java 21+ JDK/JRE manually and re-run."
    }

    # The 'latest' manifest lists all published archives as relative paths
    # (e.g. '../20260826_1017/org.eclipse.justj...-win32-x86_64.tar.gz');
    # pick the stripped full JRE for win32-x86_64.
    $manifestUrl = "$script:JustJJreBaseUrl/justj.manifest"
    Write-Log "Install-EclipseJre: reading JRE manifest from $manifestUrl" -Level DEBUG
    $manifest = Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 60
    $match = [regex]::Match([string]$manifest, '(?m)^\S*?(org\.eclipse\.justj\.openjdk\.hotspot\.jre\.full\.stripped-[0-9][0-9A-Za-z.\-]*-win32-x86_64\.tar\.gz)\s*$')
    if (-not $match.Success) {
        throw "Could not find a win32-x86_64 JRE in the JustJ manifest at '$manifestUrl'. Install a Java 21+ JDK/JRE manually and re-run."
    }
    $fileName = $match.Groups[1].Value
    $downloadUrl = [Uri]::new([Uri]::new("$script:JustJJreBaseUrl/"), $match.Value.Trim()).AbsoluteUri
    Write-Log "Install-EclipseJre: resolved JRE download URL: $downloadUrl" -Level DEBUG

    $archivePath = Join-Path $CacheDirectory $fileName
    if (-not ((Test-Path -LiteralPath $archivePath) -and (Test-GzipFile -Path $archivePath))) {
        if (Test-Path -LiteralPath $archivePath) {
            Write-Log "Cached JRE archive '$archivePath' is invalid - re-downloading." -Level WARN
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $CacheDirectory)) {
            New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
        }
        $tempPath = "$archivePath.part"
        Save-FileWithProgress -Url $downloadUrl -Destination $tempPath -DisplayName $fileName
        if (-not (Test-GzipFile -Path $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            throw "Downloaded JRE archive is not a valid gzip file (got an error page instead?)."
        }
        Move-Item -LiteralPath $tempPath -Destination $archivePath -Force
        Write-Log "Downloaded '$fileName' successfully." -Level SUCCESS
    } else {
        Write-Log "Using cached JRE download: $archivePath" -Level INFO
    }

    # Extract to a temp folder first: the archive may or may not wrap its content in a top-level folder.
    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ("eclipsadt-jre-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
    try {
        & $tarCmd.Source -xf $archivePath -C $stagingDir
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe failed to extract '$archivePath' (exit code $LASTEXITCODE)."
        }

        $jreContentRoot = $stagingDir
        if (-not (Test-Path -LiteralPath (Join-Path $jreContentRoot 'bin\java.exe'))) {
            $topLevelDir = @(Get-ChildItem -LiteralPath $stagingDir -Directory) | Select-Object -First 1
            if ($topLevelDir -and (Test-Path -LiteralPath (Join-Path $topLevelDir.FullName 'bin\java.exe'))) {
                $jreContentRoot = $topLevelDir.FullName
            } else {
                throw "Extracted JRE archive does not contain 'bin\java.exe'."
            }
        }

        $jreDir = Join-Path $EclipseRoot 'jre'
        if (Test-Path -LiteralPath $jreDir) {
            Remove-Item -LiteralPath $jreDir -Recurse -Force
        }
        Move-Item -LiteralPath $jreContentRoot -Destination $jreDir
        Write-Log "JRE installed at '$jreDir'." -Level SUCCESS
    } finally {
        if (Test-Path -LiteralPath $stagingDir) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-GzipFile {
    param([Parameter(Mandatory)] [string]$Path)

    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $header = New-Object byte[] 2
            if ($stream.Read($header, 0, 2) -lt 2) { return $false }
            return ($header[0] -eq 0x1F -and $header[1] -eq 0x8B)
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    }
}
