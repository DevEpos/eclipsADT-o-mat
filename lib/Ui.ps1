<#
.SYNOPSIS
    Shared console UI helpers for eclipsADT-o-Mat: interactivity detection,
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
    Write-Log "Test-InteractiveConsole: $script:UiInteractive" -Level DEBUG
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

$script:UiPinnedBanner = $null

function Write-Banner {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [string]$Subtitle
    )

    # Remembered so Write-PinnedBanner can redraw it above later menus.
    $script:UiPinnedBanner = [PSCustomObject]@{ Title = $Title; Subtitle = $Subtitle }
    Write-PinnedBanner
}

function Write-PinnedBanner {
    <#
    .SYNOPSIS
        (Re)draws the banner previously set via Write-Banner. Used to keep
        the intro screen pinned above menus after a Clear-Host. No-op if
        Write-Banner hasn't been called.
    #>
    if (-not $script:UiPinnedBanner) { return }
    $Title = $script:UiPinnedBanner.Title
    $Subtitle = $script:UiPinnedBanner.Subtitle

    $inner = [Math]::Max($Title.Length, ($Subtitle ?? '').Length) + 6
    Write-Host ""
    Write-Host ("╔{0}╗" -f ('═' * $inner)) -ForegroundColor $script:UiTheme.Accent
    Write-Host ("║{0}║" -f $Title.PadLeft(($inner + $Title.Length) / 2).PadRight($inner)) -ForegroundColor $script:UiTheme.Accent
    if ($Subtitle) {
        $subtitleLine = $Subtitle.PadLeft(($inner + $Subtitle.Length) / 2).PadRight($inner)
        Write-Host "║" -ForegroundColor $script:UiTheme.Accent -NoNewline
        Write-Host $subtitleLine -ForegroundColor $script:UiTheme.Muted -NoNewline
        Write-Host "║" -ForegroundColor $script:UiTheme.Accent
    }
    Write-Host ("╚{0}╝" -f ('═' * $inner)) -ForegroundColor $script:UiTheme.Accent
}

function Get-PinnedBannerHeight {
    # Line count Write-PinnedBanner prints, so callers can offset cursor math.
    if (-not $script:UiPinnedBanner) { return 0 }
    $height = 4 # blank line + top border + title + bottom border
    if ($script:UiPinnedBanner.Subtitle) { $height++ }
    return $height
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

function Show-DesktopNotification {
    <#
    .SYNOPSIS
        Shows a Windows taskbar balloon notification (best-effort, never throws).

    .PARAMETER Title
        Notification title text.

    .PARAMETER Message
        Notification body text.

    .PARAMETER Icon
        Balloon tip icon: 'Info', 'Warning' or 'Error'. Defaults to 'Info'.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Icon = 'Info'
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
        $notifyIcon.Visible = $true
        $notifyIcon.ShowBalloonTip(8000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::$Icon)

        # Keep the tray icon alive long enough for the balloon to actually render
        # before the process (and its icon) disappears.
        Start-Sleep -Milliseconds 3000
        $notifyIcon.Dispose()
    } catch {
        Write-Log "Could not show desktop notification: $_" -Level WARN
    }
}

