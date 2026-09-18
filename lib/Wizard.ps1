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

function Resolve-InstallMode {
    <#
    .SYNOPSIS
        Step 1: resolves whether to create a new Eclipse installation or
        modify an existing one. Defaults to 'New' when -Mode was not given
        in non-interactive mode.
    #>
    param(
        [string]$Mode,
        [switch]$NonInteractive
    )

    if (-not $Mode) {
        if ($NonInteractive) {
            $Mode = 'New'
        } else {
            Write-StepHeader -Step 1 -Title 'Installation mode'
            $options = @(
                [PSCustomObject]@{ id = 'New'; label = 'Create a new Eclipse installation' }
                [PSCustomObject]@{ id = 'Modify'; label = 'Add ADT and plugins to an existing Eclipse installation' }
            )
            $chosen = Read-MenuChoice -Title 'What would you like to do?' -Options $options -LabelProperty 'label' -DefaultIndex 0
            $Mode = $chosen.id
        }
    }
    Write-Log "Installation mode: $Mode" -Level INFO
    return $Mode
}

function Resolve-BasePackageSelection {
    <#
    .SYNOPSIS
        Step 2 (new mode): resolves (prompting if needed) the catalog
        basePackages entry to install.
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
            Write-StepHeader -Step 2 -Total 7 -Title 'Base package'
            $defaultIndex = [Math]::Max(0, [Array]::IndexOf(@($Catalog.basePackages.id), $defaultBasePackage.id))
            $chosen = Read-MenuChoice -Title "Select the base Eclipse package to install:" `
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
        Step 3 (new mode): resolves (prompting if needed) the Eclipse release
        train id, validated against the versions the chosen base package
        supports.
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
        Write-StepHeader -Step 3 -Total 7 -Title 'Eclipse release'
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
        Step 4 (new mode): resolves the install path for a new Eclipse
        installation. Folders already containing an Eclipse installation are
        rejected - modifying one requires -Mode Modify.
    .OUTPUTS
        The install path as [string], or $null if the user cancelled.
    #>
    param(
        [string]$InstallPath,
        [switch]$NonInteractive
    )

    $defaultPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'eclipse'

    if ($NonInteractive) {
        if (-not $InstallPath) { $InstallPath = $defaultPath }
        $existingRoot = Find-ExistingEclipse -InstallPath $InstallPath
        if ($existingRoot) {
            Write-Log "An existing Eclipse installation was found at '$existingRoot'. Use -Mode Modify to add ADT and plugins to it, or choose a folder without an Eclipse installation. Installation cancelled." -Level ERROR
            exit 1
        }
    } else {
        Write-StepHeader -Step 4 -Total 7 -Title 'Install location'
        while ($true) {
            if (-not $InstallPath) {
                $InstallPath = Read-PathPrompt -Message "Where should Eclipse be installed?" -DefaultPath $defaultPath
            }

            $existingRoot = Find-ExistingEclipse -InstallPath $InstallPath
            if (-not $existingRoot) { break }

            Write-Host ""
            Write-Host "  This folder already contains an Eclipse installation: $existingRoot" -ForegroundColor Red
            Write-Host "  To add ADT and plugins to it, restart and choose 'Add ADT and plugins to an existing Eclipse installation'." -ForegroundColor DarkGray
            if (-not (Read-YesNo -Message "  Choose a different folder? (answering no cancels the installation)" -DefaultYes $true)) {
                Write-Log "Target folder '$InstallPath' already contains an Eclipse installation at '$existingRoot'. Installation cancelled by user." -Level WARN
                return $null
            }
            $InstallPath = $null
        }
    }
    Write-Log "Install path: $InstallPath" -Level INFO

    return $InstallPath
}

function Resolve-ExistingInstallSelection {
    <#
    .SYNOPSIS
        Step 2 (modify mode): resolves the folder of the existing Eclipse
        installation to modify, auto-detecting its Eclipse version and base
        package. Explicit -EclipseVersion/-BasePackage values are validated
        against what was detected.
    .OUTPUTS
        A [PSCustomObject] with InstallPath/EclipseRoot/BasePackageEntry/
        EclipseVersion, or $null if the user cancelled.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [string]$BasePackage,
        [string]$EclipseVersion,
        [string]$InstallPath,
        [switch]$NonInteractive
    )

    $defaultPath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'eclipse'

    if (-not $NonInteractive) {
        Write-StepHeader -Step 2 -Total 5 -Title 'Existing installation'
    }

    while ($true) {
        if (-not $InstallPath) {
            if ($NonInteractive) {
                $InstallPath = $defaultPath
            } else {
                $InstallPath = Read-PathPrompt -Message "Where is the existing Eclipse installation?" -DefaultPath $defaultPath
            }
        }

        $failure = $null
        $installedVersion = $null
        $basePackageEntry = $null

        $existingRoot = Find-ExistingEclipse -InstallPath $InstallPath
        if (-not $existingRoot) {
            $failure = "No Eclipse installation (eclipse.exe) was found at '$InstallPath'."
        }

        if (-not $failure) {
            $installedVersion = Resolve-EclipseVersionIdFromInstall -EclipseRoot $existingRoot -EclipseVersions $Catalog.eclipseVersions
            if (-not $installedVersion) {
                $failure = "Could not map the installation at '$existingRoot' to a supported Eclipse version."
            } elseif ($EclipseVersion -and $installedVersion -ne $EclipseVersion) {
                $failure = "The installation at '$existingRoot' is Eclipse '$installedVersion', which does not match the requested '$EclipseVersion'."
            }
        }

        if (-not $failure) {
            $basePackageEntry = Resolve-BasePackageFromInstall -EclipseRoot $existingRoot -Catalog $Catalog
            if (-not $basePackageEntry) {
                $failure = "Could not map the installation at '$existingRoot' to a known base package."
            } elseif ($BasePackage -and $basePackageEntry.id -ne $BasePackage) {
                $failure = "The installation at '$existingRoot' uses base package '$($basePackageEntry.id)', which does not match the requested '$BasePackage'."
            }
        }

        if ($failure) {
            if ($NonInteractive) {
                Write-Log "$failure Installation cancelled." -Level ERROR
                exit 1
            }
            Write-Host ""
            Write-Host "  $failure" -ForegroundColor Red
            if (-not (Read-YesNo -Message "  Choose a different folder? (answering no cancels the installation)" -DefaultYes $true)) {
                Write-Log "$failure Installation cancelled by user." -Level WARN
                return $null
            }
            $InstallPath = $null
            continue
        }

        if (-not $NonInteractive) {
            Write-Host ""
            Write-Host "  Detected Eclipse '$installedVersion' with base package '$($basePackageEntry.name)' at: $existingRoot" -ForegroundColor Green
        }
        Write-Log "Modifying existing Eclipse at '$existingRoot' (version '$installedVersion', base package '$($basePackageEntry.id)')." -Level INFO

        return [PSCustomObject]@{
            InstallPath      = $InstallPath
            EclipseRoot      = $existingRoot
            BasePackageEntry = $basePackageEntry
            EclipseVersion   = $installedVersion
        }
    }
}

function Resolve-PluginSelection {
    <#
    .SYNOPSIS
        Plugins step: resolves the additional plugins to install, either from
        -Features (non-interactive) or via the multi-select menu. Plugins
        restricted to specific base packages (via `requiresBasePackage`) are
        only offered/accepted when the matching base package was selected.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] $BasePackageEntry,
        [string[]]$Features,
        [switch]$NonInteractive,
        [int]$Step = 5,
        [int]$Total = 7
    )

    $availablePlugins = @($Catalog.plugins | Where-Object {
        -not $_.requiresBasePackage -or $_.requiresBasePackage -contains $BasePackageEntry.id
    })

    $selectedPlugins = @()
    if ($NonInteractive) {
        if ($Features) {
            foreach ($featureId in $Features) {
                $plugin = $Catalog.plugins | Where-Object { $_.id -eq $featureId }
                if (-not $plugin) { throw "Unknown feature id '$featureId'. Run with -ListFeatures to see valid values." }
                if ($plugin.requiresBasePackage -and $plugin.requiresBasePackage -notcontains $BasePackageEntry.id) {
                    throw "Plugin '$featureId' requires base package '$($plugin.requiresBasePackage -join ', ')', but '$($BasePackageEntry.id)' was selected."
                }
                $selectedPlugins += $plugin
            }
        }
    } else {
        Write-StepHeader -Step $Step -Total $Total -Title 'Additional plugins'
        $selectedPlugins = Read-MultiSelect -Title "Select additional plugins to install (ADT itself is always installed):" `
            -Options $availablePlugins -LabelProperty 'name' -DescriptionProperty 'description' -GroupProperty 'publisher'
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
        Confirmation step: prints the confirmation summary and prompts the
        user to proceed. Returns $true if the user confirmed.
    #>
    param(
        [Parameter(Mandatory)] $Catalog,
        [Parameter(Mandatory)] $BasePackageEntry,
        [Parameter(Mandatory)] [string]$EclipseVersion,
        [string]$InstallPath,
        [string]$ReuseExistingEclipseRoot,
        [object[]]$SelectedPlugins,
        $ActiveDevEposChannel,
        [int]$Step = 6,
        [int]$Total = 7
    )

    Write-StepHeader -Step $Step -Total $Total -Title 'Confirmation'
    $plannedEclipseRoot = if ($ReuseExistingEclipseRoot) { $ReuseExistingEclipseRoot } else { Resolve-EclipseInstallRoot -InstallPath $InstallPath }
    Write-Host "  Mode            : $(if ($ReuseExistingEclipseRoot) { 'modify existing installation' } else { 'new installation' })"
    Write-Host "  Eclipse version : $EclipseVersion"
    Write-Host "  Install path    : $plannedEclipseRoot"
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
        Install step (a): reuses the existing Eclipse root, or downloads
        (with cache) and extracts the chosen base package's zip.
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
        Install step (b): installs ADT (required) plus any selected DevEpos and
        third-party plugins, via the p2 director. Returns an array of
        [PSCustomObject]@{ Name; Success } results for the summary step.

    .DESCRIPTION
        Builds one repository/IU set per logical item (ADT, DevEpos channel,
        each third-party plugin) and first tries a single combined p2 director
        call for everything. Only if that fails does it fall back to running
        each item's own director call sequentially (Install-ItemsSequentially),
        so the summary can still pinpoint which specific item broke.
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

    # Third-party plugins commonly depend on bundles (e.g. org.eclipse.lsp4e,
    # com.ibm.icu) that ship with the full EPP packages (java/rcp) but are
    # absent from the minimal 'platform' base package. Always pairing the
    # plugin's own repo with the matching Eclipse release train repo lets p2
    # resolve those transitive dependencies regardless of the base package.
    $releaseTrainRepo = Expand-Template -Template 'https://download.eclipse.org/releases/{version}' -Version $EclipseVersion

    $items = @([PSCustomObject]@{
        ResultNames = @($Catalog.adt.name)
        Repos       = $adtRepos
        IUs         = $Catalog.adt.installableUnits
    })

    $selectedDevEpos = @($SelectedPlugins | Where-Object { $_.publisher -eq 'DevEpos' })
    if ($selectedDevEpos.Count -gt 0) {
        $items += [PSCustomObject]@{
            ResultNames = @($selectedDevEpos | ForEach-Object { $_.name })
            Repos       = @($ActiveDevEposChannel.repoUrl, $releaseTrainRepo)
            IUs         = @($selectedDevEpos | ForEach-Object { $_.installableUnits })
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
        # repoUrl is optional: some features (e.g. Eclipse Marketplace Client) ship as
        # part of the release train repo itself and need no dedicated update site.
        $pluginRepos = @($plugin.repoUrl, $releaseTrainRepo) | Where-Object { $_ }
        $items += [PSCustomObject]@{ ResultNames = @($plugin.name); Repos = $pluginRepos; IUs = $pluginIUs }
    }

    foreach ($item in $items) {
        Write-Log "Item '$($item.ResultNames -join ', ')' repositories: $($item.Repos -join ', ')" -Level DEBUG
        Write-Log "Item '$($item.ResultNames -join ', ')' installable units: $($item.IUs -join ', ')" -Level DEBUG
    }

    $combinedRepos = @($items.Repos | Select-Object -Unique)
    $combinedIUs = @($items.IUs | Select-Object -Unique)

    # Fail fast (no retries) on the combined attempt: a failure here falls back
    # to per-item calls anyway, so retrying the whole bundle first would just
    # delay reaching the granular diagnostics.
    $combinedResult = Invoke-P2Director -EclipseExePath $EclipseExePath -Repositories $combinedRepos `
        -InstallIUs $combinedIUs -DestinationPath $EclipseRoot `
        -Description 'ADT + selected plugins' -RetryCount 0

    if ($combinedResult.Success) {
        return @($items | ForEach-Object {
            $item = $_
            $item.ResultNames | ForEach-Object { [PSCustomObject]@{ Name = $_; Success = $true } }
        })
    }

    Write-Log "Combined installation failed - falling back to per-item installs to identify the culprit." -Level WARN
    return (Install-ItemsSequentially -Items $items -EclipseExePath $EclipseExePath -EclipseRoot $EclipseRoot)
}

function Install-ItemsSequentially {
    <#
    .SYNOPSIS
        Fallback for Install-AdtAndPlugins: installs each item (ADT, DevEpos
        channel, third-party plugin) via its own p2 director call, so the
        summary can pinpoint which specific item failed.

    .DESCRIPTION
        The first item is assumed to be ADT; if it fails, the remaining items
        are skipped since they all depend on it.
    #>
    param(
        [Parameter(Mandatory)] [object[]]$Items,
        [Parameter(Mandatory)] [string]$EclipseExePath,
        [Parameter(Mandatory)] [string]$EclipseRoot
    )

    $results = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $itemResult = Invoke-P2Director -EclipseExePath $EclipseExePath -Repositories $item.Repos `
            -InstallIUs $item.IUs -DestinationPath $EclipseRoot -Description ($item.ResultNames -join ', ')
        foreach ($name in $item.ResultNames) {
            $results += [PSCustomObject]@{ Name = $name; Success = $itemResult.Success }
        }
        if ($i -eq 0 -and -not $itemResult.Success) {
            Write-Log "ADT installation failed - skipping additional plugins since they depend on ADT." -Level ERROR
            break
        }
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
