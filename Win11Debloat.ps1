<#
.SYNOPSIS
    Disable Windows 11 ads, promotions and "suggestions". Optional GUI for
    selecting which sections to apply and which preinstalled bloat to remove.

.DESCRIPTION
    Toggles OFF (per checkbox in the GUI):
      - Lock screen tips, fun facts, weather widget that opens MSN/Edge
      - Start menu Recommendations / suggested apps / silently-installed promos
      - System tips, welcome experience, "ways to get the most out of Windows"
      - Settings app suggested content
      - Advertising ID and tailored experiences
      - File Explorer sync provider ads
      - Taskbar search highlights & widgets news feed
      - Microsoft Consumer Experiences (machine policy)
      - Edge new tab promos, first-run nag, Rewards prompts

    Optional uninstall lists:
      - Tier 1: third-party promos (Spotify, Disney+, TikTok, Candy Crush, ...)
                + obvious MS bloat (BingNews, Tips, Office Hub, Solitaire, ...)
      - Tier 2: real apps some people use (Mail/Calendar, Phone Link, Maps,
                Media Player, Movies & TV, Xbox apps, ...)

    System-critical apps (Store, Terminal, Calculator, Photos, Paint,
    Snipping Tool, Notepad, Defender UI, runtimes) are never touched.

.PARAMETER NoGui
    Run non-interactively with all 9 ad-disabling sections enabled.
    Combine with -RemoveBloat / -Aggressive / -DryRun.

.PARAMETER RemoveBloat
    With -NoGui: also uninstall the Tier 1 list.

.PARAMETER Aggressive
    With -NoGui -RemoveBloat: also uninstall Tier 2.

.PARAMETER DryRun
    Show what would happen without making changes.

.EXAMPLE
    # GUI (default)
    .\Win11Debloat.ps1

.EXAMPLE
    # CLI: kill ads only
    .\Win11Debloat.ps1 -NoGui

.EXAMPLE
    # CLI: kill ads + uninstall obvious bloat
    .\Win11Debloat.ps1 -NoGui -RemoveBloat
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$NoGui,
    [switch]$RemoveBloat,
    [switch]$Aggressive,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:LogTextBox = $null
$script:DryRun     = [bool]$DryRun

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    if ($script:LogTextBox) {
        $script:LogTextBox.AppendText("$Message`r`n")
        $script:LogTextBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-Reg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','ExpandString','Binary','MultiString','QWord')]
        [string]$Type = 'DWord'
    )
    if ($script:DryRun) {
        Write-Log ("  [DRY] {0}\{1} = {2}" -f $Path, $Name, $Value) 'DarkCyan'
        return
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Log ("  [OK]  {0}\{1} = {2}" -f $Path, $Name, $Value) 'DarkGray'
}

function Remove-AppxByPattern {
    param([Parameter(Mandatory)][string]$Pattern)
    $installed = Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction SilentlyContinue
    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                   Where-Object { $_.DisplayName -like $Pattern }

    if (-not $installed -and -not $provisioned) {
        Write-Log "  [--]  $Pattern (not present)"
        return
    }
    foreach ($pkg in $installed) {
        if ($script:DryRun) {
            Write-Log "  [DRY] would remove $($pkg.PackageFullName)" 'DarkCyan'
        } else {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Log "  [OK]  removed $($pkg.Name)"
            } catch {
                Write-Log "  [WARN] could not remove $($pkg.Name): $($_.Exception.Message)" 'Yellow'
            }
        }
    }
    foreach ($prov in $provisioned) {
        if ($script:DryRun) {
            Write-Log "  [DRY] would deprovision $($prov.DisplayName)" 'DarkCyan'
        } else {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                Write-Log "  [OK]  deprovisioned $($prov.DisplayName)"
            } catch {
                Write-Log "  [WARN] could not deprovision $($prov.DisplayName): $($_.Exception.Message)" 'Yellow'
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Configuration: sections + app lists
# -----------------------------------------------------------------------------
$cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"

$script:Sections = @(
    @{
        Id     = 'lockscreen'
        Title  = 'Lock screen tips & weather widget'
        Detail = 'Kills the "fun facts" overlay and the MSN/weather redirect that opens Edge.'
        Action = {
            Set-Reg $cdm "RotatingLockScreenOverlayEnabled" 0
            Set-Reg $cdm "SubscribedContent-338387Enabled"  0
            Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen" "SlideshowEnabled" 0
        }
    }
    @{
        Id     = 'start'
        Title  = 'Start menu recommendations & suggested apps'
        Detail = 'Disables the "Recommended" section and silently installed promo apps.'
        Action = {
            Set-Reg $cdm "SubscribedContent-338388Enabled" 0
            Set-Reg $cdm "SilentInstalledAppsEnabled"      0
            Set-Reg $cdm "PreInstalledAppsEnabled"         0
            Set-Reg $cdm "OEMPreInstalledAppsEnabled"      0
            Set-Reg $cdm "ContentDeliveryAllowed"          0
            Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_IrisRecommendations" 0
        }
    }
    @{
        Id     = 'tips'
        Title  = 'System tips & welcome experience'
        Detail = '"Get the most out of Windows", tips, post-update welcome screens.'
        Action = {
            Set-Reg $cdm "SubscribedContent-310093Enabled" 0
            Set-Reg $cdm "SubscribedContent-314559Enabled" 0
            Set-Reg $cdm "SubscribedContent-338389Enabled" 0
            Set-Reg $cdm "SubscribedContent-353698Enabled" 0
            Set-Reg $cdm "SystemPaneSuggestionsEnabled"    0
            Set-Reg $cdm "SoftLandingEnabled"              0
        }
    }
    @{
        Id     = 'settingsapp'
        Title  = 'Settings app "suggested content"'
        Detail = 'Removes promo cards inside the Settings app.'
        Action = {
            Set-Reg $cdm "SubscribedContent-338393Enabled" 0
            Set-Reg $cdm "SubscribedContent-353694Enabled" 0
            Set-Reg $cdm "SubscribedContent-353696Enabled" 0
        }
    }
    @{
        Id     = 'adid'
        Title  = 'Advertising ID & tailored experiences'
        Detail = 'Disables advertising ID, language tracking, writing-data telemetry.'
        Action = {
            Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0
            Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 0
            Set-Reg "HKCU:\Software\Microsoft\Input\TIPC" "Enabled" 0
            Set-Reg "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 1
        }
    }
    @{
        Id     = 'explorer'
        Title  = 'File Explorer ads (sync provider notifications)'
        Detail = 'Disables OneDrive / sync provider promo notifications in File Explorer.'
        Action = {
            Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowSyncProviderNotifications" 0
        }
    }
    @{
        Id     = 'search'
        Title  = 'Taskbar search highlights & widgets news feed'
        Detail = 'Removes Bing/news highlights from search; widgets panel itself still works.'
        Action = {
            Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDynamicSearchBoxEnabled" 0
            Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0
        }
    }
    @{
        Id     = 'consumer'
        Title  = 'Consumer Experiences (master switch, machine policy)'
        Detail = 'Prevents Spotify/Disney/TikTok auto-installs on this and new accounts.'
        Action = {
            $cc = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
            Set-Reg $cc "DisableWindowsConsumerFeatures"     1
            Set-Reg $cc "DisableConsumerAccountStateContent" 1
            Set-Reg $cc "DisableSoftLanding"                 1
            Set-Reg $cc "DisableCloudOptimizedContent"       1
        }
    }
    @{
        Id     = 'edge'
        Title  = 'Edge promotional content'
        Detail = 'New tab MSN feed, first-run nag, Rewards prompts, shopping assistant.'
        Action = {
            $edge = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
            Set-Reg $edge "HideFirstRunExperience"          1
            Set-Reg $edge "ShowRecommendationsEnabled"      0
            Set-Reg $edge "PersonalizationReportingEnabled" 0
            Set-Reg $edge "NewTabPageContentEnabled"        0
            Set-Reg $edge "NewTabPageQuickLinksEnabled"     0
            Set-Reg $edge "NewTabPageHideDefaultTopSites"   1
            Set-Reg $edge "EdgeShoppingAssistantEnabled"    0
            Set-Reg $edge "ShowMicrosoftRewards"            0
        }
    }
)

$script:Tier1Apps = @(
    @{ Pattern='*AdobePhotoshopExpress*';                Display='Adobe Photoshop Express' }
    @{ Pattern='*BubbleWitch3Saga*';                     Display='Bubble Witch 3 Saga' }
    @{ Pattern='*CandyCrush*';                           Display='Candy Crush' }
    @{ Pattern='*Disney*';                               Display='Disney+' }
    @{ Pattern='*DolbyAccess*';                          Display='Dolby Access' }
    @{ Pattern='*Duolingo*';                             Display='Duolingo' }
    @{ Pattern='*EclipseManager*';                       Display='Eclipse Manager' }
    @{ Pattern='*Facebook*';                             Display='Facebook' }
    @{ Pattern='*Flipboard*';                            Display='Flipboard' }
    @{ Pattern='*HiddenCity*';                           Display='Hidden City' }
    @{ Pattern='king.com.*';                             Display='king.com games' }
    @{ Pattern='*LinkedInforWindows*';                   Display='LinkedIn' }
    @{ Pattern='*MarchofEmpires*';                       Display='March of Empires' }
    @{ Pattern='*Netflix*';                              Display='Netflix' }
    @{ Pattern='*PandoraMediaInc*';                      Display='Pandora' }
    @{ Pattern='*PicsArt*';                              Display='PicsArt' }
    @{ Pattern='*Spotify*';                              Display='Spotify' }
    @{ Pattern='*TikTok*';                               Display='TikTok' }
    @{ Pattern='*Twitter*';                              Display='Twitter / X' }
    @{ Pattern='*Wunderlist*';                           Display='Wunderlist' }
    @{ Pattern='Microsoft.Advertising.Xaml';             Display='Microsoft Advertising SDK' }
    @{ Pattern='Microsoft.BingNews';                     Display='MSN News (Bing News)' }
    @{ Pattern='Microsoft.BingSearch';                   Display='Bing Search' }
    @{ Pattern='Microsoft.GetHelp';                      Display='Get Help' }
    @{ Pattern='Microsoft.Getstarted';                   Display='Tips' }
    @{ Pattern='Microsoft.MicrosoftOfficeHub';           Display='Office Hub launcher' }
    @{ Pattern='Microsoft.MicrosoftSolitaireCollection'; Display='Microsoft Solitaire' }
    @{ Pattern='Microsoft.MixedReality.Portal';          Display='Mixed Reality Portal' }
    @{ Pattern='Microsoft.OneConnect';                   Display='Mobile Plans' }
    @{ Pattern='Microsoft.People';                       Display='People (legacy)' }
    @{ Pattern='Microsoft.Print3D';                      Display='Print 3D' }
    @{ Pattern='Microsoft.SkypeApp';                     Display='Skype (consumer)' }
    @{ Pattern='Microsoft.Wallet';                       Display='Wallet' }
    @{ Pattern='Microsoft.WindowsFeedbackHub';           Display='Feedback Hub' }
    @{ Pattern='Clipchamp.Clipchamp';                    Display='Clipchamp' }
)

$script:Tier2Apps = @(
    @{ Pattern='Microsoft.WindowsCommunicationsApps'; Display='Mail + Calendar' }
    @{ Pattern='Microsoft.YourPhone';                 Display='Phone Link' }
    @{ Pattern='Microsoft.WindowsMaps';               Display='Maps' }
    @{ Pattern='Microsoft.ZuneMusic';                 Display='Media Player / Groove Music' }
    @{ Pattern='Microsoft.ZuneVideo';                 Display='Movies & TV' }
    @{ Pattern='Microsoft.WindowsSoundRecorder';      Display='Sound Recorder' }
    @{ Pattern='Microsoft.WindowsAlarms';             Display='Alarms & Clock' }
    @{ Pattern='Microsoft.GamingApp';                 Display='Xbox app' }
    @{ Pattern='Microsoft.Xbox.TCUI';                 Display='Xbox TCUI' }
    @{ Pattern='Microsoft.XboxGameOverlay';           Display='Xbox Game Overlay' }
    @{ Pattern='Microsoft.XboxGamingOverlay';         Display='Xbox Gaming Overlay' }
    @{ Pattern='Microsoft.XboxSpeechToTextOverlay';   Display='Xbox Speech-to-Text Overlay' }
)

# -----------------------------------------------------------------------------
# Apply logic (used by both GUI and -NoGui modes)
# -----------------------------------------------------------------------------
function Invoke-Cleanup {
    param(
        [string[]]$EnabledSections,
        [string[]]$AppPatterns
    )
    foreach ($sec in $script:Sections) {
        if ($sec.Id -in $EnabledSections) {
            Write-Log "`n[$($sec.Title)]" 'Yellow'
            & $sec.Action
        }
    }
    if ($AppPatterns -and $AppPatterns.Count -gt 0) {
        Write-Log "`n[Removing apps]" 'Yellow'
        foreach ($p in $AppPatterns) { Remove-AppxByPattern -Pattern $p }
    }
    if (-not $script:DryRun) {
        Write-Log "`nApplying group policy..." 'Cyan'
        & gpupdate /force | Out-Null
        Write-Log "Restarting Explorer..." 'Cyan'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
    }
    Write-Log "`n=== Done. Sign out / reboot for everything to take full effect. ===" 'Green'
}

# -----------------------------------------------------------------------------
# CLI mode (-NoGui)
# -----------------------------------------------------------------------------
if ($NoGui) {
    $secIds = @($script:Sections | ForEach-Object { $_.Id })
    $apps = @()
    if ($RemoveBloat) {
        $apps += @($script:Tier1Apps | ForEach-Object { $_.Pattern })
        if ($Aggressive) {
            $apps += @($script:Tier2Apps | ForEach-Object { $_.Pattern })
        }
    }
    Invoke-Cleanup -EnabledSections $secIds -AppPatterns $apps
    return
}

# -----------------------------------------------------------------------------
# GUI mode (default)
# -----------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Win11 Debloat'
$form.Size          = New-Object System.Drawing.Size(780, 840)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(720, 760)

$header = New-Object System.Windows.Forms.Label
$header.Text     = "Disable Windows 11 ads, promos and 'suggestions'"
$header.Font     = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(15, 12)
$header.Size     = New-Object System.Drawing.Size(740, 24)
$form.Controls.Add($header)

$subheader = New-Object System.Windows.Forms.Label
$subheader.Text     = 'Hover any item for details. All registry changes are reversible.'
$subheader.Location = New-Object System.Drawing.Point(15, 36)
$subheader.Size     = New-Object System.Drawing.Size(740, 18)
$subheader.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($subheader)

# --- Section 1: ads & promotions ---
$gbSections = New-Object System.Windows.Forms.GroupBox
$gbSections.Text     = '1. Disable ads & promotions'
$gbSections.Location = New-Object System.Drawing.Point(15, 60)
$gbSections.Size     = New-Object System.Drawing.Size(735, 260)
$gbSections.Anchor   = 'Top,Left,Right'
$form.Controls.Add($gbSections)

$tooltip = New-Object System.Windows.Forms.ToolTip
$secCheckboxes = @{}
$y = 22
foreach ($sec in $script:Sections) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text     = $sec.Title
    $cb.Checked  = $true
    $cb.Location = New-Object System.Drawing.Point(15, $y)
    $cb.Size     = New-Object System.Drawing.Size(700, 22)
    $tooltip.SetToolTip($cb, $sec.Detail)
    $gbSections.Controls.Add($cb)
    $secCheckboxes[$sec.Id] = $cb
    $y += 26
}

# --- Section 2: bloat removal ---
$gbApps = New-Object System.Windows.Forms.GroupBox
$gbApps.Text     = '2. Uninstall promo / bloat apps  (optional)'
$gbApps.Location = New-Object System.Drawing.Point(15, 330)
$gbApps.Size     = New-Object System.Drawing.Size(735, 285)
$gbApps.Anchor   = 'Top,Left,Right'
$form.Controls.Add($gbApps)

# Tier 1
$lblT1 = New-Object System.Windows.Forms.Label
$lblT1.Text     = 'Tier 1 - promo apps & MS bloat (safe for almost everyone)'
$lblT1.Location = New-Object System.Drawing.Point(15, 22)
$lblT1.Size     = New-Object System.Drawing.Size(340, 16)
$lblT1.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$gbApps.Controls.Add($lblT1)

$clbT1 = New-Object System.Windows.Forms.CheckedListBox
$clbT1.Location     = New-Object System.Drawing.Point(15, 42)
$clbT1.Size         = New-Object System.Drawing.Size(345, 200)
$clbT1.CheckOnClick = $true
foreach ($a in $script:Tier1Apps) { [void]$clbT1.Items.Add($a.Display, $false) }
$gbApps.Controls.Add($clbT1)

$btnAllT1 = New-Object System.Windows.Forms.Button
$btnAllT1.Text     = 'Select all'
$btnAllT1.Location = New-Object System.Drawing.Point(15, 248)
$btnAllT1.Size     = New-Object System.Drawing.Size(85, 26)
$btnAllT1.Add_Click({
    for ($i = 0; $i -lt $clbT1.Items.Count; $i++) { $clbT1.SetItemChecked($i, $true) }
})
$gbApps.Controls.Add($btnAllT1)

$btnNoneT1 = New-Object System.Windows.Forms.Button
$btnNoneT1.Text     = 'Clear'
$btnNoneT1.Location = New-Object System.Drawing.Point(105, 248)
$btnNoneT1.Size     = New-Object System.Drawing.Size(85, 26)
$btnNoneT1.Add_Click({
    for ($i = 0; $i -lt $clbT1.Items.Count; $i++) { $clbT1.SetItemChecked($i, $false) }
})
$gbApps.Controls.Add($btnNoneT1)

# Tier 2
$lblT2 = New-Object System.Windows.Forms.Label
$lblT2.Text     = 'Tier 2 - aggressive (real apps some people use)'
$lblT2.Location = New-Object System.Drawing.Point(380, 22)
$lblT2.Size     = New-Object System.Drawing.Size(340, 16)
$lblT2.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$gbApps.Controls.Add($lblT2)

$clbT2 = New-Object System.Windows.Forms.CheckedListBox
$clbT2.Location     = New-Object System.Drawing.Point(380, 42)
$clbT2.Size         = New-Object System.Drawing.Size(340, 200)
$clbT2.CheckOnClick = $true
foreach ($a in $script:Tier2Apps) { [void]$clbT2.Items.Add($a.Display, $false) }
$gbApps.Controls.Add($clbT2)

$btnAllT2 = New-Object System.Windows.Forms.Button
$btnAllT2.Text     = 'Select all'
$btnAllT2.Location = New-Object System.Drawing.Point(380, 248)
$btnAllT2.Size     = New-Object System.Drawing.Size(85, 26)
$btnAllT2.Add_Click({
    for ($i = 0; $i -lt $clbT2.Items.Count; $i++) { $clbT2.SetItemChecked($i, $true) }
})
$gbApps.Controls.Add($btnAllT2)

$btnNoneT2 = New-Object System.Windows.Forms.Button
$btnNoneT2.Text     = 'Clear'
$btnNoneT2.Location = New-Object System.Drawing.Point(470, 248)
$btnNoneT2.Size     = New-Object System.Drawing.Size(85, 26)
$btnNoneT2.Add_Click({
    for ($i = 0; $i -lt $clbT2.Items.Count; $i++) { $clbT2.SetItemChecked($i, $false) }
})
$gbApps.Controls.Add($btnNoneT2)

# --- Action row ---
$cbDry = New-Object System.Windows.Forms.CheckBox
$cbDry.Text     = 'Dry run (preview only - no changes)'
$cbDry.Location = New-Object System.Drawing.Point(20, 630)
$cbDry.Size     = New-Object System.Drawing.Size(280, 22)
$cbDry.Anchor   = 'Bottom,Left'
$form.Controls.Add($cbDry)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text      = 'Apply'
$btnApply.Location  = New-Object System.Drawing.Point(550, 624)
$btnApply.Size      = New-Object System.Drawing.Size(95, 32)
$btnApply.Anchor    = 'Bottom,Right'
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnApply.ForeColor = [System.Drawing.Color]::White
$btnApply.FlatStyle = 'Flat'
$form.Controls.Add($btnApply)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text     = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(655, 624)
$btnClose.Size     = New-Object System.Drawing.Size(95, 32)
$btnClose.Anchor   = 'Bottom,Right'
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

# --- Log box ---
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline   = $true
$txtLog.ScrollBars  = 'Vertical'
$txtLog.ReadOnly    = $true
$txtLog.Font        = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Location    = New-Object System.Drawing.Point(15, 665)
$txtLog.Size        = New-Object System.Drawing.Size(735, 130)
$txtLog.Anchor      = 'Top,Bottom,Left,Right'
$txtLog.BackColor   = [System.Drawing.Color]::Black
$txtLog.ForeColor   = [System.Drawing.Color]::LightGray
$form.Controls.Add($txtLog)
$script:LogTextBox = $txtLog

$btnApply.Add_Click({
    $txtLog.Clear()
    $script:DryRun = $cbDry.Checked

    $enabled = @()
    foreach ($id in $secCheckboxes.Keys) {
        if ($secCheckboxes[$id].Checked) { $enabled += $id }
    }

    $apps = @()
    for ($i = 0; $i -lt $clbT1.Items.Count; $i++) {
        if ($clbT1.GetItemChecked($i)) { $apps += $script:Tier1Apps[$i].Pattern }
    }
    for ($i = 0; $i -lt $clbT2.Items.Count; $i++) {
        if ($clbT2.GetItemChecked($i)) { $apps += $script:Tier2Apps[$i].Pattern }
    }

    if ($enabled.Count -eq 0 -and $apps.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Nothing selected.', 'Win11 Debloat', 'OK', 'Information') | Out-Null
        return
    }

    $modeText = if ($script:DryRun) { ' (DRY RUN - no changes)' } else { '' }
    Write-Log "=== Starting cleanup$modeText ===" 'Cyan'

    $btnApply.Enabled = $false
    try {
        Invoke-Cleanup -EnabledSections $enabled -AppPatterns $apps
    } catch {
        Write-Log "ERROR: $($_.Exception.Message)" 'Red'
    } finally {
        $btnApply.Enabled = $true
    }
})

[void]$form.ShowDialog()
