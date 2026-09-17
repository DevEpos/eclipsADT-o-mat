<#
.SYNOPSIS
    Self-update helpers for eclipsADT-o-Mat.

.DESCRIPTION
    Compares the local source files against the GitHub repository by hashing
    them the same way git does (blob SHA-1) and matching against the repo's
    tree API. This works without a .git folder or any stored state, so users
    who downloaded the repository as a zip are supported too.
    Invoke-SourceUpdate downloads the branch zipball and overwrites the local
    sources without deleting any extra local files (logs, caches, ...).
#>

$script:UpdateRepoOwner = 'DevEpos'
$script:UpdateRepoName = 'eclipsADT-o-mat'
$script:UpdateRepoBranch = 'main'

function Get-GitBlobSha {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    # git hashes blobs as sha1("blob <byte length>\0" + content)
    $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $data = [byte[]]::new($header.Length + $Bytes.Length)
    [Array]::Copy($header, 0, $data, 0, $header.Length)
    [Array]::Copy($Bytes, 0, $data, $header.Length, $Bytes.Length)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        return ([BitConverter]::ToString($sha1.ComputeHash($data)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha1.Dispose()
    }
}

function Test-LocalFileMatchesBlob {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$BlobSha
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ((Get-GitBlobSha -Bytes $bytes) -eq $BlobSha) { return $true }

    # Retry with CRLF normalized to LF: git checkouts with autocrlf store LF in the blob.
    $normalized = [System.Collections.Generic.List[byte]]::new($bytes.Length)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 13 -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
        $normalized.Add($bytes[$i])
    }
    return (Get-GitBlobSha -Bytes $normalized.ToArray()) -eq $BlobSha
}

function Get-RemoteFileTree {
    <#
    .SYNOPSIS
        Returns the blob entries (path, sha) of the repository's branch tree,
        or $null if GitHub cannot be reached (offline, rate-limited, ...).
    #>
    param()

    $uri = "https://api.github.com/repos/$script:UpdateRepoOwner/$script:UpdateRepoName/git/trees/$($script:UpdateRepoBranch)?recursive=1"
    try {
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec 10 -Headers @{
            'User-Agent' = 'eclipsADT-o-Mat'
            'Accept'     = 'application/vnd.github+json'
        }
        return @($response.tree | Where-Object { $_.type -eq 'blob' })
    } catch {
        Write-Log "Update check: could not query GitHub tree API: $($_.Exception.Message)" -Level DEBUG
        return $null
    }
}

function Test-SourceUpdateAvailable {
    <#
    .SYNOPSIS
        Compares local sources against the GitHub repository. Returns the list
        of repo-relative paths that differ or are missing locally (empty array
        = up to date), or $null if the remote check failed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )

    $tree = Get-RemoteFileTree
    if ($null -eq $tree) { return $null }

    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $tree) {
        # Never compare runtime artifacts.
        if ($entry.path -like 'logs/*') { continue }

        $localPath = Join-Path $ScriptRoot ($entry.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            $changed.Add($entry.path)
            continue
        }
        if (-not (Test-LocalFileMatchesBlob -Path $localPath -BlobSha $entry.sha)) {
            $changed.Add($entry.path)
        }
    }

    Write-Log "Update check: $($changed.Count) of $($tree.Count) tracked file(s) differ from GitHub." -Level DEBUG
    return $changed.ToArray()
}

function Write-UpdateNotice {
    <#
    .SYNOPSIS
        Prints an eye-catching colored notice that an update is available,
        including the list of changed files.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$ChangedFiles
    )

    $accent = $script:UiTheme ? $script:UiTheme.Category : 'Magenta'
    $muted = $script:UiTheme ? $script:UiTheme.Muted : 'DarkGray'

    Write-Host ""
    Write-Host "  Update available! " -ForegroundColor $accent -NoNewline
    Write-Host "$($ChangedFiles.Count) file(s) differ from GitHub:" -ForegroundColor $accent
    foreach ($file in $ChangedFiles) {
        Write-Host "    - $file" -ForegroundColor $muted
    }
    Write-Host ""
}

function Test-GitUpdateSupported {
    <#
    .SYNOPSIS
        Returns $true when the sources are a git clone (.git folder present)
        and a git executable is available, so 'git pull' can be used.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )

    if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot '.git'))) { return $false }
    return $null -ne (Get-Command git -ErrorAction SilentlyContinue)
}

function Invoke-GitSourceUpdate {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )

    Write-Log "Updating sources via 'git pull --ff-only'..." -Level INFO
    # --ff-only avoids surprise merges; local modifications cause a clean failure instead.
    $output = git -C $ScriptRoot pull --ff-only 2>&1
    $output | ForEach-Object { Write-Log "git: $_" -Level DEBUG }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "git pull failed (exit $LASTEXITCODE): $($output | Select-Object -Last 1)" -Level WARN
        return $false
    }
    Write-Log "Local sources updated via git pull ($script:UpdateRepoOwner/$script:UpdateRepoName@$script:UpdateRepoBranch)." -Level SUCCESS
    return $true
}

function Invoke-SourceUpdate {
    <#
    .SYNOPSIS
        Updates the local sources from GitHub. Uses 'git pull' when the
        sources are a git clone and git is installed; otherwise (or if the
        pull fails) downloads the branch zipball and overwrites the local
        sources. Extra local files (logs, caches) are left untouched.
        Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )

    if (Test-GitUpdateSupported -ScriptRoot $ScriptRoot) {
        if (Invoke-GitSourceUpdate -ScriptRoot $ScriptRoot) { return $true }
        Write-Log "Falling back to zip download." -Level WARN
    }

    $zipUrl = "https://github.com/$script:UpdateRepoOwner/$script:UpdateRepoName/archive/refs/heads/$($script:UpdateRepoBranch).zip"
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "eclipsADT-o-Mat-update-$([System.IO.Path]::GetRandomFileName())"
    try {
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
        $zipPath = Join-Path $tempDir 'sources.zip'

        Write-Log "Downloading latest sources from $zipUrl" -Level INFO
        Save-FileWithProgress -Url $zipUrl -Destination $zipPath -DisplayName 'eclipsADT-o-Mat sources'
        if (-not (Test-ZipFile -Path $zipPath)) {
            throw "Downloaded file is not a valid zip archive."
        }

        $extractDir = Join-Path $tempDir 'extracted'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        # The zipball wraps everything in a single '<repo>-<branch>' folder.
        $innerDir = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
        if (-not $innerDir) {
            throw "Unexpected zip layout: no root folder found in archive."
        }

        Copy-Item -Path (Join-Path $innerDir.FullName '*') -Destination $ScriptRoot -Recurse -Force
        Write-Log "Local sources updated from GitHub ($script:UpdateRepoOwner/$script:UpdateRepoName@$script:UpdateRepoBranch)." -Level SUCCESS
        return $true
    } catch {
        Write-Log "Source update failed: $($_.Exception.Message)" -Level ERROR
        return $false
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
