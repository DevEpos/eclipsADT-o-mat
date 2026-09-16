<#
.SYNOPSIS
    Console menu / prompt helpers shared by the ADT Bundler wizard.

.DESCRIPTION
    Provides dependency-free helpers (requires lib\Ui.ps1 to be dot-sourced
    first for Test-InteractiveConsole):
    - Read-MenuChoice: single-choice menu (arrow-key navigation, or a
      numbered fallback when the console can't do rich rendering).
    - Read-MultiSelect: multi-select menu with checkbox toggling and optional
      grouping, with the same numbered fallback.
    - Read-PathPrompt: prompt for a filesystem path with a default value.
    - Read-YesNo: yes/no confirmation (single keypress when interactive).
#>

function Get-MenuOptionLabel {
    param($Option, [string]$LabelProperty)
    if ($LabelProperty) { return [string]$Option.$LabelProperty }
    return $Option.ToString()
}

function Get-MenuPageSize {
    # Lines available for menu rows below the pinned banner, title and hint lines.
    param([int]$ReservedLines = 0)
    try { return [Math]::Max(1, [Console]::WindowHeight - 3 - $ReservedLines) } catch { return 10 }
}

function Read-MenuChoice {
    <#
    .SYNOPSIS
        Displays a list of options and returns the selected item. Uses
        arrow-key navigation when the console supports it, otherwise a
        numbered prompt.

    .PARAMETER Title
        Heading printed above the menu.

    .PARAMETER Options
        Array of objects to choose from.

    .PARAMETER LabelProperty
        Name of the property on each option object to display. If omitted,
        ToString() is used.

    .PARAMETER DefaultIndex
        0-based index pre-selected initially / when the user just presses Enter.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Options,

        [string]$LabelProperty,

        [int]$DefaultIndex = 0
    )

    if (Test-InteractiveConsole) { return Read-MenuChoiceInteractive @PSBoundParameters }
    return Read-MenuChoiceClassic @PSBoundParameters
}

function Read-MenuChoiceInteractive {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Options,

        [string]$LabelProperty,

        [int]$DefaultIndex = 0
    )

    $esc = [char]27
    $current = [Math]::Min([Math]::Max(0, $DefaultIndex), $Options.Count - 1)
    $bannerHeight = Get-PinnedBannerHeight

    [Console]::CursorVisible = $false
    Clear-Host
    Write-PinnedBanner
    try {
        while ($true) {
            $pageSize = Get-MenuPageSize -ReservedLines $bannerHeight
            $pageCount = [int][Math]::Ceiling($Options.Count / $pageSize)
            $page = [int][Math]::Floor($current / $pageSize)
            $start = $page * $pageSize
            $end = [Math]::Min($start + $pageSize, $Options.Count) - 1

            [Console]::SetCursorPosition(0, $bannerHeight)
            Write-Host ("$esc[2K" + (Limit-UiLine $Title)) -ForegroundColor Cyan
            $hint = "  Up/Down move · Enter select · 1-9 jump"
            if ($pageCount -gt 1) { $hint += " · PgUp/PgDn page $($page + 1)/$pageCount" }
            Write-Host ("$esc[2K" + (Limit-UiLine $hint)) -ForegroundColor DarkGray

            for ($i = $start; $i -le $end; $i++) {
                $label = Get-MenuOptionLabel -Option $Options[$i] -LabelProperty $LabelProperty
                if ($i -eq $current) {
                    Write-Host ("$esc[2K" + (Limit-UiLine ("  > {0}" -f $label))) -ForegroundColor Cyan
                } else {
                    Write-Host ("$esc[2K" + (Limit-UiLine ("    {0}" -f $label)))
                }
            }
            [Console]::Write("$esc[0J")

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $current = ($current - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $current = ($current + 1) % $Options.Count }
                'PageUp'    { $current = [Math]::Max(0, $current - $pageSize) }
                'PageDown'  { $current = [Math]::Min($Options.Count - 1, $current + $pageSize) }
                'Home'      { $current = 0 }
                'End'       { $current = $Options.Count - 1 }
                'Enter'     { return $Options[$current] }
                default {
                    if ($key.KeyChar -ge '1' -and $key.KeyChar -le '9') {
                        $num = [int][string]$key.KeyChar
                        if ($num -le $Options.Count) { $current = $num - 1 }
                    }
                }
            }
        }
    } finally {
        Clear-Host
        Write-PinnedBanner
        [Console]::CursorVisible = $true
    }
}

function Read-MenuChoiceClassic {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Options,

        [string]$LabelProperty,

        [int]$DefaultIndex = 0
    )

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $label = Get-MenuOptionLabel -Option $Options[$i] -LabelProperty $LabelProperty
        $marker = if ($i -eq $DefaultIndex) { '*' } else { ' ' }
        Write-Host ("  [{0,2}]{1} {2}" -f ($i + 1), $marker, $label)
    }

    while ($true) {
        $prompt = "Enter a number (1-$($Options.Count))"
        if ($DefaultIndex -ge 0) { $prompt += " [default: $($DefaultIndex + 1)]" }
        $answer = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ($DefaultIndex -ge 0) { return $Options[$DefaultIndex] }
            continue
        }
        $num = 0
        if ([int]::TryParse($answer.Trim(), [ref]$num) -and $num -ge 1 -and $num -le $Options.Count) {
            return $Options[$num - 1]
        }
        Write-Host "Invalid choice. Please enter a number between 1 and $($Options.Count)." -ForegroundColor Yellow
    }
}

function Read-MultiSelect {
    <#
    .SYNOPSIS
        Displays a list of options with toggleable checkboxes and returns the
        array of selected items once the user confirms. Uses arrow-key
        navigation when the console supports it, otherwise a numbered prompt.

    .PARAMETER Title
        Heading printed above the menu.

    .PARAMETER Options
        Array of objects to choose from.

    .PARAMETER LabelProperty
        Name of the property on each option object to display.

    .PARAMETER DescriptionProperty
        Optional property name to display as a secondary description line.

    .PARAMETER GroupProperty
        Optional property name used to group options under muted category
        headers (interactive mode only).

    .PARAMETER PreSelectedIndices
        0-based indices that start out checked (e.g. required items).

    .PARAMETER LockedIndices
        0-based indices that cannot be toggled off (e.g. required items).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Options,

        [string]$LabelProperty,

        [string]$DescriptionProperty,

        [string]$GroupProperty,

        [int[]]$PreSelectedIndices = @(),

        [int[]]$LockedIndices = @()
    )

    if (Test-InteractiveConsole) { return Read-MultiSelectInteractive @PSBoundParameters }
    return Read-MultiSelectClassic @PSBoundParameters
}

function Read-MultiSelectInteractive {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Options,

        [string]$LabelProperty,

        [string]$DescriptionProperty,

        [string]$GroupProperty,

        [int[]]$PreSelectedIndices = @(),

        [int[]]$LockedIndices = @()
    )

    $esc = [char]27
    $selected = New-Object bool[] $Options.Count
    foreach ($i in $PreSelectedIndices) { $selected[$i] = $true }
    foreach ($i in $LockedIndices) { $selected[$i] = $true }

    # One display block per option: optional group header, the option line and
    # its optional description line. Blocks are never split across pages.
    $blocks = @()
    $lastGroup = $null
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $lines = [System.Collections.Generic.List[object]]::new()
        if ($GroupProperty) {
            $group = [string]$Options[$i].$GroupProperty
            if ($group -ne $lastGroup) {
                $lines.Add(@{ Kind = 'Header'; Text = $group })
                $lastGroup = $group
            }
        }
        $lines.Add(@{ Kind = 'Option'; Index = $i })
        if ($DescriptionProperty -and $Options[$i].$DescriptionProperty) {
            $lines.Add(@{ Kind = 'Description'; Index = $i })
        }
        $blocks += , $lines
    }

    $current = 0
    $bannerHeight = Get-PinnedBannerHeight

    [Console]::CursorVisible = $false
    Clear-Host
    Write-PinnedBanner
    try {
        while ($true) {
            # Re-page on every draw so window resizes are picked up.
            $pageSize = Get-MenuPageSize -ReservedLines $bannerHeight
            $pages = [System.Collections.Generic.List[object]]::new()
            $pageOfOption = New-Object int[] $Options.Count
            $page = [System.Collections.Generic.List[object]]::new()
            $pageLines = 0
            for ($i = 0; $i -lt $blocks.Count; $i++) {
                if ($page.Count -gt 0 -and ($pageLines + $blocks[$i].Count) -gt $pageSize) {
                    $pages.Add($page)
                    $page = [System.Collections.Generic.List[object]]::new()
                    $pageLines = 0
                }
                $page.Add($blocks[$i])
                $pageOfOption[$i] = $pages.Count
                $pageLines += $blocks[$i].Count
            }
            if ($page.Count -gt 0) { $pages.Add($page) }
            $pageIndex = $pageOfOption[$current]

            [Console]::SetCursorPosition(0, $bannerHeight)
            Write-Host ("$esc[2K" + (Limit-UiLine $Title)) -ForegroundColor Cyan
            $hint = "  Up/Down move · Space toggle · a all · n none · Enter confirm"
            if ($pages.Count -gt 1) { $hint += " · PgUp/PgDn page $($pageIndex + 1)/$($pages.Count)" }
            Write-Host ("$esc[2K" + (Limit-UiLine $hint)) -ForegroundColor DarkGray

            foreach ($block in $pages[$pageIndex]) {
                foreach ($line in $block) {
                    switch ($line.Kind) {
                        'Header' {
                            Write-Host ("$esc[2K" + (Limit-UiLine ("  {0}" -f $line.Text))) -ForegroundColor DarkGray
                        }
                        'Option' {
                            $i = $line.Index
                            $label = Get-MenuOptionLabel -Option $Options[$i] -LabelProperty $LabelProperty
                            $check = if ($selected[$i]) { 'x' } else { ' ' }
                            $lockTag = if ($LockedIndices -contains $i) { ' (required)' } else { '' }
                            $pointer = if ($i -eq $current) { '>' } else { ' ' }
                            $text = "$esc[2K" + (Limit-UiLine ("  {0} [{1}] {2}{3}" -f $pointer, $check, $label, $lockTag))
                            if ($i -eq $current) {
                                Write-Host $text -ForegroundColor Cyan
                            } else {
                                Write-Host $text
                            }
                        }
                        'Description' {
                            Write-Host ("$esc[2K" + (Limit-UiLine ("        {0}" -f $Options[$line.Index].$DescriptionProperty))) -ForegroundColor DarkGray
                        }
                    }
                }
            }
            [Console]::Write("$esc[0J")

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $current = ($current - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $current = ($current + 1) % $Options.Count }
                'PageUp'    { $current = [Array]::IndexOf($pageOfOption, [int][Math]::Max(0, $pageIndex - 1)) }
                'PageDown'  { $current = [Array]::IndexOf($pageOfOption, [int][Math]::Min($pages.Count - 1, $pageIndex + 1)) }
                'Home'      { $current = 0 }
                'End'       { $current = $Options.Count - 1 }
                'Spacebar'  {
                    if ($LockedIndices -notcontains $current) { $selected[$current] = -not $selected[$current] }
                }
                'Enter' {
                    $result = @()
                    for ($i = 0; $i -lt $Options.Count; $i++) { if ($selected[$i]) { $result += $Options[$i] } }
                    return $result
                }
                default {
                    switch ($key.KeyChar) {
                        'a' { for ($i = 0; $i -lt $Options.Count; $i++) { $selected[$i] = $true } }
                        'n' {
                            for ($i = 0; $i -lt $Options.Count; $i++) {
                                if ($LockedIndices -notcontains $i) { $selected[$i] = $false }
                            }
                        }
                        default {
                            if ($key.KeyChar -ge '1' -and $key.KeyChar -le '9') {
                                $num = [int][string]$key.KeyChar
                                if ($num -le $Options.Count -and $LockedIndices -notcontains ($num - 1)) {
                                    $selected[$num - 1] = -not $selected[$num - 1]
                                }
                            }
                        }
                    }
                }
            }
        }
    } finally {
        Clear-Host
        Write-PinnedBanner
        [Console]::CursorVisible = $true
    }
}

function Read-MultiSelectClassic {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Options,

        [string]$LabelProperty,

        [string]$DescriptionProperty,

        [string]$GroupProperty,

        [int[]]$PreSelectedIndices = @(),

        [int[]]$LockedIndices = @()
    )

    $selected = New-Object bool[] $Options.Count
    foreach ($i in $PreSelectedIndices) { $selected[$i] = $true }
    foreach ($i in $LockedIndices) { $selected[$i] = $true }

    while ($true) {
        Write-Host ""
        Write-Host $Title -ForegroundColor Cyan
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $label = Get-MenuOptionLabel -Option $Options[$i] -LabelProperty $LabelProperty
            $check = if ($selected[$i]) { 'x' } else { ' ' }
            $lockTag = if ($LockedIndices -contains $i) { ' (required)' } else { '' }
            Write-Host ("  [{0}] {1,2}. {2}{3}" -f $check, ($i + 1), $label, $lockTag)
            if ($DescriptionProperty -and $Options[$i].$DescriptionProperty) {
                Write-Host ("         {0}" -f $Options[$i].$DescriptionProperty) -ForegroundColor DarkGray
            }
        }
        Write-Host ""
        Write-Host "Toggle a number, 'a' = select all, 'n' = select none, Enter = confirm selection." -ForegroundColor DarkGray
        $answer = Read-Host "Selection"

        if ([string]::IsNullOrWhiteSpace($answer)) {
            $result = @()
            for ($i = 0; $i -lt $Options.Count; $i++) { if ($selected[$i]) { $result += $Options[$i] } }
            return $result
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            'a' { for ($i = 0; $i -lt $Options.Count; $i++) { $selected[$i] = $true }; continue }
            'n' {
                for ($i = 0; $i -lt $Options.Count; $i++) {
                    if ($LockedIndices -contains $i) { continue }
                    $selected[$i] = $false
                }
                continue
            }
            default {
                $num = 0
                if ([int]::TryParse($answer.Trim(), [ref]$num) -and $num -ge 1 -and $num -le $Options.Count) {
                    $idx = $num - 1
                    if ($LockedIndices -contains $idx) {
                        Write-Host "This item is required and cannot be deselected." -ForegroundColor Yellow
                    } else {
                        $selected[$idx] = -not $selected[$idx]
                    }
                } else {
                    Write-Host "Invalid input. Enter a number, 'a', 'n', or press Enter to confirm." -ForegroundColor Yellow
                }
            }
        }
    }
}

function Read-PathPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$DefaultPath
    )

    while ($true) {
        Write-Host ""
        Write-Host -NoNewline "$Message "
        Write-Host -NoNewline "[Enter = default, B = browse: $DefaultPath]" -ForegroundColor DarkGray
        Write-Host -NoNewline ": "
        $answer = [Console]::ReadLine()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultPath }
        if ($answer.Trim().Equals('b', [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
            $dialog.Description = $Message
            $dialog.SelectedPath = $DefaultPath
            $dialog.ShowNewFolderButton = $true
            try {
                if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    return $dialog.SelectedPath
                }
            } finally {
                $dialog.Dispose()
            }
            continue
        }
        return $answer.Trim().Trim('"')
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }

    if (Test-InteractiveConsole) {
        Write-Host -NoNewline "$Message "
        Write-Host -NoNewline "$suffix " -ForegroundColor DarkGray
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') {
                Write-Host ($DefaultYes ? 'y' : 'n')
                return $DefaultYes
            }
            switch ([char]::ToLowerInvariant($key.KeyChar)) {
                'y' { Write-Host 'y'; return $true }
                'n' { Write-Host 'n'; return $false }
            }
        }
    }

    while ($true) {
        $answer = Read-Host "$Message $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
        switch ($answer.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
            default { Write-Host "Please answer 'y' or 'n'." -ForegroundColor Yellow }
        }
    }
}
