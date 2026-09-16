<#
.SYNOPSIS
    Shared console UI helpers for the ADT Bundler: interactivity detection,
    theme, banner, step headers and a polling-based spinner.

.DESCRIPTION
    All rich rendering (ANSI cursor movement, spinners, progress bars) is
    gated on Test-InteractiveConsole so that redirected or non-VT sessions
    degrade to plain sequential output.
#>

$script:UiTheme = @{
    Accent = 'Cyan'
    Muted  = 'DarkGray'
    Ok     = 'Green'
    Warn   = 'Yellow'
    Err    = 'Red'
}

$script:UiInteractive = $null

function Test-InteractiveConsole {
    <#
    .SYNOPSIS
        Returns $true when the session can do rich rendering (no redirected
        std streams, virtual terminal supported). Result is cached.
    #>
    if ($null -ne $script:UiInteractive) { return $script:UiInteractive }
    try {
        $script:UiInteractive = (-not [Console]::IsInputRedirected) -and
            (-not [Console]::IsOutputRedirected) -and
            [bool]$Host.UI.SupportsVirtualTerminal
    } catch {
        $script:UiInteractive = $false
    }
    return $script:UiInteractive
}

function Get-UiWidth {
    try { return [Math]::Max(40, [Console]::WindowWidth) } catch { return 80 }
}

function Limit-UiLine {
    # Truncates to console width so in-place re-rendered lines never wrap.
    param([string]$Text)
    $max = (Get-UiWidth) - 1
    if ($Text.Length -le $max) { return $Text }
    return $Text.Substring(0, $max - 1) + '…'
}

function Write-Banner {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [string]$Subtitle
    )

    $inner = [Math]::Max($Title.Length, ($Subtitle ?? '').Length) + 6
    Write-Host ""
    Write-Host ("╔{0}╗" -f ('═' * $inner)) -ForegroundColor $script:UiTheme.Accent
    Write-Host ("║{0}║" -f $Title.PadLeft(($inner + $Title.Length) / 2).PadRight($inner)) -ForegroundColor $script:UiTheme.Accent
    if ($Subtitle) {
        Write-Host ("║{0}║" -f $Subtitle.PadLeft(($inner + $Subtitle.Length) / 2).PadRight($inner)) -ForegroundColor $script:UiTheme.Muted
    }
    Write-Host ("╚{0}╝" -f ('═' * $inner)) -ForegroundColor $script:UiTheme.Accent
}

function Write-StepHeader {
    param(
        [Parameter(Mandatory)]
        [int]$Step,

        [Parameter(Mandatory)]
        [int]$Total,

        [Parameter(Mandatory)]
        [string]$Title
    )

    $label = " Step $Step/$Total · $Title "
    $ruleWidth = [Math]::Max(4, [Math]::Min((Get-UiWidth), 72) - $label.Length - 2)
    Write-Host ""
    Write-Host ("──{0}{1}" -f $label, ('─' * $ruleWidth)) -ForegroundColor $script:UiTheme.Accent
}

function Start-ConsoleSpinner {
    <#
    .SYNOPSIS
        Creates spinner state for a long-running operation. Caller must poll
        Update-ConsoleSpinner and finish with Stop-ConsoleSpinner.
        No-ops (returns inert state) in non-interactive sessions.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Activity
    )

    $spinner = [PSCustomObject]@{
        Activity    = $Activity
        Frames      = @('|', '/', '-', '\')
        Index       = 0
        StartTime   = Get-Date
        Interactive = (Test-InteractiveConsole)
        LastLength  = 0
    }
    if ($spinner.Interactive) { [Console]::CursorVisible = $false }
    return $spinner
}

function Update-ConsoleSpinner {
    param(
        [Parameter(Mandatory)]
        $Spinner,

        [string]$Status
    )

    if (-not $Spinner.Interactive) { return }

    $frame = $Spinner.Frames[$Spinner.Index % $Spinner.Frames.Count]
    $Spinner.Index++
    $elapsed = (Get-Date) - $Spinner.StartTime
    $text = " {0} {1} [{2:mm\:ss}]" -f $frame, $Spinner.Activity, $elapsed
    if ($Status) { $text += "  $($Status.Trim())" }

    $maxWidth = (Get-UiWidth) - 1
    if ($text.Length -gt $maxWidth) { $text = $text.Substring(0, $maxWidth) }
    $padding = ' ' * [Math]::Max(0, $Spinner.LastLength - $text.Length)
    [Console]::Write("`r$text$padding")
    $Spinner.LastLength = $text.Length
}

function Stop-ConsoleSpinner {
    param(
        [Parameter(Mandatory)]
        $Spinner
    )

    if (-not $Spinner.Interactive) { return }
    [Console]::Write("`r" + (' ' * $Spinner.LastLength) + "`r")
    [Console]::CursorVisible = $true
}
