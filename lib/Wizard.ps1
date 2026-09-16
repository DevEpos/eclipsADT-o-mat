<#
.SYNOPSIS
    Interactive/non-interactive wizard steps for eclipsADT-o-Mat: selecting a
    base package, Eclipse version, install location and plugins, showing the
    confirmation summary, and driving the actual download/install pipeline.

.DESCRIPTION
    Each function here corresponds to one step of the wizard implemented in
    Setup-EclipsAdtOMat.ps1's -Step comments. They are kept separate from the
    main script so that step orchestration stays readable as a short pipeline.
#>

function Resolve-BasePackageSelection {
    <#
    .SYNOPSIS
        Step 1: resolves (prompting if needed) the catalog basePackages entry
        to install/modify.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [string]$BasePackage,
        [switch]$NonInteractive
    )

    if (-not $BasePackage) {
        $defaultBasePackage = $Catalog.basePackages | Where-Object { $_.default } | Select-Object -First 1
        if (-not $defaultBasePackage) { $defaultBasePackage = $Catalog.basePackages[0] }
        if ($NonInteractive) {
            $BasePackage = $defaultBasePackage.id
        } else {
            Write-StepHeader -Step 1 -Total 6 -Title 'Base package'
            $defaultIndex = [Math]::Max(0, [Array]::IndexOf(@($Catalog.basePackages.id), $defaultBasePackage.id))
            $chosen = Read-MenuChoice -Title "Select the base Eclipse package to install/modify:" `
                -Options $Catalog.basePackages -LabelProperty 'name' -DefaultIndex $defaultIndex
            $BasePackage = $chosen.id
        }
    }

    $basePackageEntry = $Catalog.basePackages | Where-Object { $_.id -eq $BasePackage }
    if (-not $basePackageEntry) {
        throw "Unknown base package '$BasePackage'. Run with -ListFeatures to see valid values."
    }
    Write-Log "Selected base package: $($basePackageEntry.id)" -Level INFO
    return $basePackageEntry
}

function Resolve-EclipseVersionSelection {
    <#
    .SYNOPSIS
        Step 2: resolves (prompting if needed) the Eclipse release train id,
        validated against the versions the chosen base package supports.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] $BasePackageEntry,
        [string]$EclipseVersion,
        [switch]$NonInteractive
    )

    $supportedVersions = Get-SupportedEclipseVersions -Catalog $Catalog -BasePackageEntry $BasePackageEntry
    if ($supportedVersions.Count -eq 0) {
        throw "Base package '$($BasePackageEntry.id)' does not support any known Eclipse version."
    }
    Write-Log "Supported Eclipse versions for '$($BasePackageEntry.id)': $(($supportedVersions.id) -join ', ')" -Level DEBUG

    if (-not $EclipseVersion) {
        if ($NonInteractive) { throw "-EclipseVersion is required in non-interactive mode." }
        Write-StepHeader -Step 2 -Total 6 -Title 'Eclipse release'
        $chosen = Read-MenuChoice -Title "Select an Eclipse release train to install:" `
            -Options $supportedVersions -LabelProperty 'label' -DefaultIndex ($supportedVersions.Count - 1)
        $EclipseVersion = $chosen.id
    } else {
        $match = $supportedVersions | Where-Object { $_.id -eq $EclipseVersion }
        if (-not $match) {
            throw "Eclipse version '$EclipseVersion' is not supported by base package '$($BasePackageEntry.id)'. Run with -ListFeatures to see valid values."
        }
    }
    Write-Log "Selected Eclipse version: $EclipseVersion" -Level INFO
    Write-Log "Eclipse version resolved via $(if ($NonInteractive) { 'parameter' } else { 'menu' }): '$EclipseVersion'" -Level DEBUG
    return $EclipseVersion
}

function Resolve-InstallLocation {
    <#
    .SYNOPSIS
        Step 3: resolves the install path, detecting and (with confirmation
        in interactive mode) reusing a compatible existing Eclipse install.
    .OUTPUTS
        A [PSCustomObject] with InstallPath/ReuseExistingEclipseRoot, or $null
        if the user cancelled the installation.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] $BasePackageEntry,
        [Parameter(Mandatory)] [string]$EclipseVersion,
        [string]$InstallPath,
        [switch]$NonInteractive
    )

    $defaultPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'eclipse'
    $reuseExistingEclipseRoot = $null

    if ($NonInteractive) {
        if (-not $InstallPath) { $InstallPath = $defaultPath }
        $existingRoot = Find-ExistingEclipse -InstallPath $InstallPath
        if ($existingRoot) {
            if (-not (Test-ExistingEclipseCompatible -EclipseRoot $existingRoot -Catalog $Catalog -EclipseVersion $EclipseVersion -BasePackageEntry $BasePackageEntry)) {
                Write-Log "Existing Eclipse at '$existingRoot' does not match the requested version '$EclipseVersion' / base package '$($BasePackageEntry.id)'. Installation cancelled." -Level ERROR
                exit 1
            }
            Write-Log "Reusing existing Eclipse ($EclipseVersion) at '$existingRoot'." -Level INFO
            $reuseExistingEclipseRoot = $existingRoot
        }
    } else {
        Write-StepHeader -Step 3 -Total 6 -Title 'Install location'
        while ($true) {
            if (-not $InstallPath) {
                $InstallPath = Read-PathPrompt -Message "Where should Eclipse be installed?" -DefaultPath $defaultPath
            }

            $existingRoot = Find-ExistingEclipse -InstallPath $InstallPath
            if (-not $existingRoot) { break }

            Write-Host ""
            Write-Host "  An existing Eclipse installation was found at: $existingRoot" -ForegroundColor Yellow
            if (-not (Read-YesNo -Message "  Add ADT and the chosen plugins to this existing installation?" -DefaultYes $true)) {
                Write-Host "  Please choose a different folder." -ForegroundColor DarkGray
                $InstallPath = $null
                continue
            }

            $installedVersion = Resolve-EclipseVersionIdFromInstall -EclipseRoot $existingRoot -EclipseVersions $Catalog.eclipseVersions
            if ($installedVersion -ne $EclipseVersion) {
                $foundLabel = if ($installedVersion) { $installedVersion } else { 'unknown' }
                Write-Host "  The existing installation is Eclipse '$foundLabel', which does not match the selected '$EclipseVersion'." -ForegroundColor Red
                if (-not (Read-YesNo -Message "  Choose a different folder? (answering no cancels the installation)" -DefaultYes $true)) {
                    Write-Log "Existing Eclipse at '$existingRoot' is version '$foundLabel' but '$EclipseVersion' was requested. Installation cancelled by user." -Level WARN
                    return $null
                }
                $InstallPath = $null
                continue
            }

            if (-not (Test-ExistingEclipseBasePackage -EclipseRoot $existingRoot -BasePackageEntry $BasePackageEntry)) {
                Write-Host "  The existing installation does not match the selected base package '$($BasePackageEntry.name)'." -ForegroundColor Red
                if (-not (Read-YesNo -Message "  Choose a different folder? (answering no cancels the installation)" -DefaultYes $true)) {
                    Write-Log "Existing Eclipse at '$existingRoot' does not match the requested base package '$($BasePackageEntry.id)'. Installation cancelled by user." -Level WARN
                    return $null
                }
                $InstallPath = $null
                continue
            }

            Write-Host "  Version and base package match ($EclipseVersion, $($BasePackageEntry.name)) - ADT and plugins will be added to this installation." -ForegroundColor Green
            $reuseExistingEclipseRoot = $existingRoot
            break
        }
    }
    Write-Log "Install path: $InstallPath" -Level INFO
    Write-Log "Reuse existing Eclipse root: $reuseExistingEclipseRoot" -Level DEBUG

    return [PSCustomObject]@{ InstallPath = $InstallPath; ReuseExistingEclipseRoot = $reuseExistingEclipseRoot }
}

function Resolve-PluginSelection {
    <#
    .SYNOPSIS
        Step 4: resolves the additional plugins to install, either from
        -Features (non-interactive) or via the multi-select menu.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [string[]]$Features,
        [switch]$NonInteractive
    )

    $selectedPlugins = @()
    if ($NonInteractive) {
        if ($Features) {
            foreach ($featureId in $Features) {
                $plugin = $Catalog.plugins | Where-Object { $_.id -eq $featureId }
                if (-not $plugin) { throw "Unknown feature id '$featureId'. Run with -ListFeatures to see valid values." }
                $selectedPlugins += $plugin
            }
        }
    } else {
        Write-StepHeader -Step 4 -Total 6 -Title 'Additional plugins'
        $selectedPlugins = Read-MultiSelect -Title "Select additional plugins to install (ADT itself is always installed):" `
            -Options $Catalog.plugins -LabelProperty 'name' -DescriptionProperty 'description' -GroupProperty 'publisher'
    }
    Write-Log "Selected plugins: $(($selectedPlugins.id) -join ', ')" -Level DEBUG
    return $selectedPlugins
}

function Resolve-DevEposChannel {
    <#
    .SYNOPSIS
        Resolves the DevEpos update channel to use, if any DevEpos plugin was
        selected. Returns $null when no DevEpos plugin is selected.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [object[]]$SelectedPlugins,
        [string]$DevEposChannel,
        [switch]$NonInteractive
    )

    $selectedDevEpos = @($SelectedPlugins | Where-Object { $_.publisher -eq 'DevEpos' })
    if ($selectedDevEpos.Count -eq 0) { return $null }

    if (-not $Catalog.devepos -or -not $Catalog.devepos.channels) {
        throw 'catalog.json does not define DevEpos channels.'
    }

    $channelId = $DevEposChannel
    if (-not $NonInteractive) {
        $channelOptions = @($Catalog.devepos.channels)
        $defaultChannelIndex = [Math]::Max(0, [Array]::IndexOf(@($channelOptions.id), 'latest'))
        $selectedChannel = Read-MenuChoice -Title 'Select the DevEpos channel for all selected DevEpos plugins:' `
            -Options $channelOptions -LabelProperty 'label' -DefaultIndex $defaultChannelIndex
        if ($selectedChannel -and $selectedChannel.id) { $channelId = [string]$selectedChannel.id }
    }

    $activeDevEposChannel = $Catalog.devepos.channels | Where-Object { $_.id -eq $channelId }
    if (-not $activeDevEposChannel) {
        throw "Unknown DevEpos channel '$channelId'. Valid values: $($Catalog.devepos.channels.id -join ', ')."
    }
    Write-Log "DevEpos channel: $($activeDevEposChannel.id)" -Level INFO
    return $activeDevEposChannel
}

function Show-InstallationSummary {
    <#
    .SYNOPSIS
        Step 5: prints the confirmation summary and prompts the user to
        proceed. Returns $true if the user confirmed.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] $BasePackageEntry,
        [Parameter(Mandatory)] [string]$EclipseVersion,
        [string]$InstallPath,
        [string]$ReuseExistingEclipseRoot,
        [object[]]$SelectedPlugins,
        $ActiveDevEposChannel
    )

    Write-StepHeader -Step 5 -Total 6 -Title 'Confirmation'
    $plannedEclipseRoot = if ($ReuseExistingEclipseRoot) { $ReuseExistingEclipseRoot } else { Resolve-EclipseInstallRoot -InstallPath $InstallPath }
    Write-Host "  Eclipse version : $EclipseVersion"
    Write-Host "  Install path    : $plannedEclipseRoot"
    if ($ReuseExistingEclipseRoot) {
        Write-Host "  Mode            : add to existing installation"
    }
    Write-Host "  Base package    : $($BasePackageEntry.name)"
    Write-Host "  ADT             : $($Catalog.adt.name) (always installed)"
    if ($ActiveDevEposChannel) {
        Write-Host "  DevEpos channel : $($ActiveDevEposChannel.label)"
    }
    if ($SelectedPlugins.Count -gt 0) {
        Write-Host "  Extra plugins   :"
        $SelectedPlugins | ForEach-Object { Write-Host "    - $($_.name)" }
    } else {
        Write-Host "  Extra plugins   : (none selected)"
    }
    Write-Host ""
    return (Read-YesNo -Message "Proceed with download and installation?" -DefaultYes $true)
}

function Resolve-EclipseInstallation {
    <#
    .SYNOPSIS
        Step 6a: reuses the existing Eclipse root, or downloads (with cache)
        and extracts the chosen base package's zip.
    #>
    param(
        [Parameter(Mandatory)] $BasePackageEntry,
        [Parameter(Mandatory)] [string]$EclipseVersion,
        [string]$InstallPath,
        [string]$ReuseExistingEclipseRoot,
        [Parameter(Mandatory)] [string]$CacheDirectory
    )

    if ($ReuseExistingEclipseRoot) {
        Write-Log "Reusing existing Eclipse installation at '$ReuseExistingEclipseRoot' - skipping download and extraction." -Level INFO
        $eclipseRoot = $ReuseExistingEclipseRoot
    } else {
        $resolvedDownload = Resolve-BasePackageDownload -BasePackageEntry $BasePackageEntry -Version $EclipseVersion
        $zipPath = Get-CachedFile -Url $resolvedDownload.Url -FallbackUrl $resolvedDownload.FallbackUrl -CacheDirectory $CacheDirectory -FileName $resolvedDownload.ZipFileName
        $eclipseRoot = Expand-EclipseZip -ZipPath $zipPath -InstallPath $InstallPath
    }
    $eclipseExe = Join-Path $eclipseRoot 'eclipsec.exe'
    Write-Log "Eclipse root: '$eclipseRoot', eclipsec.exe: '$eclipseExe'" -Level DEBUG
    return [PSCustomObject]@{ EclipseRoot = $eclipseRoot; EclipseExePath = $eclipseExe }
}

function Install-AdtAndPlugins {
    <#
    .SYNOPSIS
        Step 6b: installs ADT (required), then any selected DevEpos and
        third-party plugins, via the p2 director. Returns an array of
        [PSCustomObject]@{ Name; Success } results for the summary step.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] [string]$EclipseExePath,
        [Parameter(Mandatory)] [string]$EclipseRoot,
        [Parameter(Mandatory)] [string]$EclipseVersion,
        [object[]]$SelectedPlugins,
        $ActiveDevEposChannel
    )

    $adtRepos = @((Expand-Template -Template $Catalog.adt.repoUrlTemplate -Version $EclipseVersion))
    if ($Catalog.adt.additionalRepoUrlTemplates) {
        foreach ($tmpl in $Catalog.adt.additionalRepoUrlTemplates) {
            $adtRepos += (Expand-Template -Template $tmpl -Version $EclipseVersion)
        }
    }
    Write-Log "ADT repositories: $($adtRepos -join ', ')" -Level DEBUG

    $results = @()
    Write-Log "ADT installable units: $($Catalog.adt.installableUnits -join ', ')" -Level DEBUG
    $adtResult = Invoke-P2Director -EclipseExePath $EclipseExePath -Repositories $adtRepos `
        -InstallIUs $Catalog.adt.installableUnits -DestinationPath $EclipseRoot `
        -Description $Catalog.adt.name
    $results += [PSCustomObject]@{ Name = $Catalog.adt.name; Success = $adtResult.Success }

    if (-not $adtResult.Success) {
        Write-Log "ADT installation failed - skipping additional plugins since they depend on ADT." -Level ERROR
        return $results
    }

    # Third-party plugins commonly depend on bundles (e.g. org.eclipse.lsp4e,
    # com.ibm.icu) that ship with the full EPP packages (java/rcp) but are
    # absent from the minimal 'platform' base package. Always pairing the
    # plugin's own repo with the matching Eclipse release train repo lets p2
    # resolve those transitive dependencies regardless of the base package.
    $releaseTrainRepo = Expand-Template -Template 'https://download.eclipse.org/releases/{version}' -Version $EclipseVersion

    $selectedDevEpos = @($SelectedPlugins | Where-Object { $_.publisher -eq 'DevEpos' })
    if ($selectedDevEpos.Count -gt 0) {
        $deveposIUs = @($selectedDevEpos | ForEach-Object { $_.installableUnits })
        Write-Log "DevEpos installable units: $($deveposIUs -join ', ')" -Level DEBUG
        $deveposResult = Invoke-P2Director -EclipseExePath $EclipseExePath -Repositories @($ActiveDevEposChannel.repoUrl, $releaseTrainRepo) `
            -InstallIUs $deveposIUs -DestinationPath $EclipseRoot `
            -Description "DevEpos ($($ActiveDevEposChannel.id) channel)"
        foreach ($plugin in $selectedDevEpos) {
            $results += [PSCustomObject]@{ Name = $plugin.name; Success = $deveposResult.Success }
        }
    }

    foreach ($plugin in @($SelectedPlugins | Where-Object { $_.publisher -ne 'DevEpos' })) {
        $pluginIUs = @($plugin.installableUnits)
        if ($plugin.requiresTerminal -and $Catalog.terminalFeature) {
            # Eclipse renamed its Terminal feature starting with the 2025-09 train (see
            # catalog.json's 'terminalFeature' entry); pick the id matching this version so
            # plugins like GitHub Copilot (whose terminal tool needs it) resolve correctly,
            # since it's absent from the minimal 'platform' base package.
            $terminalIU = if ($EclipseVersion -ge $Catalog.terminalFeature.firstVersionWithNewFeature) {
                $Catalog.terminalFeature.installableUnit
            } else {
                $Catalog.terminalFeature.legacyInstallableUnit
            }
            $pluginIUs += $terminalIU
        }
        Write-Log "Plugin '$($plugin.name)' installable units: $($pluginIUs -join ', ')" -Level DEBUG
        $pluginResult = Invoke-P2Director -EclipseExePath $EclipseExePath -Repositories @($plugin.repoUrl, $releaseTrainRepo) `
            -InstallIUs $pluginIUs -DestinationPath $EclipseRoot `
            -Description $plugin.name
        $results += [PSCustomObject]@{ Name = $plugin.name; Success = $pluginResult.Success }
    }

    return $results
}

function Show-ResultsSummary {
    <#
    .SYNOPSIS
        Prints the final per-item install results and exits the process:
        code 1 if any item failed, 0 otherwise.
    #>
    param(
        [object[]]$Results,
        [Parameter(Mandatory)] [string]$EclipseRoot
    )

    Write-Host ""
    Write-Host ("── Installation Summary " + ('─' * 24)) -ForegroundColor Cyan
    $anyFailed = $false
    foreach ($r in $Results) {
        if ($r.Success) {
            Write-Host "  [OK]   $($r.Name)" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] $($r.Name)" -ForegroundColor Red
            $anyFailed = $true
        }
    }
    Write-Host ""

    if ($anyFailed) {
        Write-Log "Completed with failures. See log for details." -Level ERROR
        Show-DesktopNotification -Title 'eclipsADT-o-Mat' -Message 'Installation completed with failures. See the log for details.' -Icon Error
        exit 1
    }

    Write-Log "All done. Launch Eclipse from: $EclipseRoot\eclipse.exe" -Level SUCCESS
    Write-Host "Eclipse with ADT is ready at: $EclipseRoot\eclipse.exe" -ForegroundColor Green
    Show-DesktopNotification -Title 'eclipsADT-o-Mat' -Message "Installation finished. Launch Eclipse from: $EclipseRoot\eclipse.exe"
    exit 0
}
