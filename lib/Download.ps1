<#
.SYNOPSIS
    Download/cache/extract helpers for the ADT Bundler.

.DESCRIPTION
    Get-CachedFile downloads a file to a local cache directory (skipping the
    download if a non-empty file is already cached), retrying on transient
    failures and falling back to a secondary URL if provided. Downloads show
    a live progress bar (size, percent, speed) in interactive consoles.
    Expand-EclipseZip extracts a downloaded Eclipse package zip into the
    chosen install directory with per-entry progress.
#>

function Test-ZipFile {
    param([Parameter(Mandatory)] [string]$Path)

    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $header = New-Object byte[] 2
            if ($stream.Read($header, 0, 2) -lt 2) { return $false }
            # A valid zip local-file-header/empty-archive signature starts with 'PK'.
            return ($header[0] -eq 0x50 -and $header[1] -eq 0x4B)
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    }
}

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

function Save-FileWithProgress {
    <#
    .SYNOPSIS
        Streams a URL to disk, reporting size/percent/speed via Write-Progress
        in interactive consoles. Follows redirects; throws on HTTP errors.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    $showProgress = Test-InteractiveConsole
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $response = $null
    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        $totalBytes = $response.Content.Headers.ContentLength

        $inStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outStream = [System.IO.File]::Create($Destination)
        try {
            $buffer = [byte[]]::new(1MB)
            $totalRead = 0L
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $lastUpdateMs = 0.0
            while (($read = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outStream.Write($buffer, 0, $read)
                $totalRead += $read
                if ($showProgress -and ($stopwatch.Elapsed.TotalMilliseconds - $lastUpdateMs) -ge 200) {
                    $lastUpdateMs = $stopwatch.Elapsed.TotalMilliseconds
                    $speed = $totalRead / 1MB / [Math]::Max($stopwatch.Elapsed.TotalSeconds, 0.001)
                    if ($totalBytes) {
                        $status = "{0:N1} / {1:N1} MB ({2:N1} MB/s)" -f ($totalRead / 1MB), ($totalBytes / 1MB), $speed
                        Write-Progress -Activity "Downloading $DisplayName" -Status $status -PercentComplete ([int](($totalRead * 100) / $totalBytes))
                    } else {
                        Write-Progress -Activity "Downloading $DisplayName" -Status ("{0:N1} MB ({1:N1} MB/s)" -f ($totalRead / 1MB), $speed)
                    }
                }
            }
        } finally {
            $outStream.Dispose()
            $inStream.Dispose()
            if ($showProgress) { Write-Progress -Activity "Downloading $DisplayName" -Completed }
        }
    } finally {
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
}

function Get-CachedFile {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [string]$FallbackUrl,

        [Parameter(Mandatory)]
        [string]$CacheDirectory,

        [Parameter(Mandatory)]
        [string]$FileName,

        [int]$MaxRetries = 3
    )

    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
    }

    $destination = Join-Path $CacheDirectory $FileName

    if (Test-Path -LiteralPath $destination) {
        if ((Get-Item -LiteralPath $destination).Length -gt 0 -and (Test-ZipFile -Path $destination)) {
            Write-Log "Using cached download: $destination" -Level INFO
            return $destination
        }
        Write-Log "Cached file '$destination' is not a valid zip - discarding and re-downloading." -Level WARN
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
    }

    $urlsToTry = @($Url)
    if ($FallbackUrl) { $urlsToTry += $FallbackUrl }

    $tempDestination = "$destination.part"

    foreach ($candidateUrl in $urlsToTry) {
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                Write-Log "Downloading '$FileName' (attempt $attempt/$MaxRetries) from: $candidateUrl" -Level INFO
                Save-FileWithProgress -Url $candidateUrl -Destination $tempDestination -DisplayName $FileName
                if ((Get-Item -LiteralPath $tempDestination).Length -eq 0) {
                    throw "Downloaded file is empty."
                }
                if (-not (Test-ZipFile -Path $tempDestination)) {
                    throw "Downloaded file is not a valid zip archive (got a non-zip response, e.g. a mirror-selection or error page)."
                }
                Move-Item -LiteralPath $tempDestination -Destination $destination -Force
                Write-Log "Downloaded '$FileName' successfully." -Level SUCCESS
                return $destination
            } catch {
                Write-Log "Download attempt $attempt failed: $($_.Exception.Message)" -Level WARN
                if (Test-Path -LiteralPath $tempDestination) { Remove-Item -LiteralPath $tempDestination -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Seconds ([Math]::Min(5 * $attempt, 15))
            }
        }
        Write-Log "All attempts against '$candidateUrl' failed, trying next URL if available." -Level WARN
    }

    throw "Failed to download '$FileName' after trying all URLs: $($urlsToTry -join ', ')"
}

function Expand-EclipseZip {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,

        [Parameter(Mandatory)]
        [string]$InstallPath
    )

    $eclipseRoot = Resolve-EclipseInstallRoot -InstallPath $InstallPath

    if (-not (Test-Path -LiteralPath $eclipseRoot)) {
        New-Item -ItemType Directory -Force -Path $eclipseRoot | Out-Null
    }

    $eclipseExe = Join-Path $eclipseRoot 'eclipse.exe'
    if (Test-Path -LiteralPath $eclipseExe) {
        Write-Log "Eclipse already extracted at '$eclipseRoot', skipping extraction." -Level INFO
        return $eclipseRoot
    }

    Write-Log "Extracting '$ZipPath' to '$eclipseRoot' ..." -Level INFO

    $destRoot = (Resolve-Path -LiteralPath $eclipseRoot).Path.TrimEnd('\', '/')
    $showProgress = Test-InteractiveConsole
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = $zip.Entries
        $total = $entries.Count
        $done = 0
        foreach ($entry in $entries) {
            $done++
            $relativePath = $entry.FullName -replace '^eclipse[\\/]', ''
            $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destRoot $relativePath))
            $isDirectory = [string]::IsNullOrEmpty($entry.Name) -or $entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\\')
            # Guard against zip-slip: every entry must stay inside the destination.
            if (-not $targetPath.StartsWith($destRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
                $targetPath -ne $destRoot) {
                throw "Zip entry '$($entry.FullName)' would extract outside the destination directory."
            }
            if ($isDirectory) {
                [void][System.IO.Directory]::CreateDirectory($targetPath)
            } else {
                [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($targetPath))
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
            }
            if ($showProgress -and ($done % 100 -eq 0 -or $done -eq $total)) {
                Write-Progress -Activity 'Extracting Eclipse' -Status "$done / $total files" -PercentComplete ([int](($done * 100) / $total))
            }
        }
    } finally {
        $zip.Dispose()
        if ($showProgress) { Write-Progress -Activity 'Extracting Eclipse' -Completed }
    }

    if (-not (Test-Path -LiteralPath $eclipseExe)) {
        throw "Extraction finished but eclipse.exe was not found at expected path '$eclipseExe'."
    }

    Write-Log "Eclipse extracted successfully." -Level SUCCESS
    return $eclipseRoot
}
