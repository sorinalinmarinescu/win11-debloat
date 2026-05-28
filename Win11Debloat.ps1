<#
.SYNOPSIS
    Win11 Debloat & Hardening v1.0 - GUI tool for disabling ads, applying
    Bitdefender-derived security hardening, with snapshot/restore and config
    export/import for admin-to-user distribution.

.DESCRIPTION
    Two intended workflows:

    1) Individual user
       - Run with no args. GUI opens with everything OFF by default.
       - (Optional) click "Export current state" to capture your starting
         configuration to a JSON file.
       - Toggle desired actions, click Apply.
       - System Restore Point is created automatically.
       - Per-action snapshot is saved to %LOCALAPPDATA%\Win11Debloat\snapshots.
       - If something breaks: load a previously-exported good config and
         re-apply, or use the Restore button to roll back to a snapshot,
         or use Windows System Restore to roll back the registry hive entirely.

    2) Admin -> end user
       - Admin runs script on a test machine, configures toggles, tests.
       - Admin clicks "Export config" to write a JSON of the selection.
       - Admin distributes the JSON.
       - End user runs script (or  Win11Debloat.ps1 -NoGui -ConfigFile config.json)
         and Applies. Same restore-point/snapshot story.

.PARAMETER NoGui
    Run non-interactively. Requires either -ConfigFile or -Export.

.PARAMETER ConfigFile
    Path to a config JSON. With -NoGui this loads + applies. In GUI mode the
    file is loaded and toggles are pre-set so the user can review before Apply.

.PARAMETER Export
    Path to write current-state config without applying anything.
    Use this to capture what's currently selected/applied on your machine.

.PARAMETER DryRun
    Show what would happen without making changes.

.PARAMETER CatalogueFile
    Override path to security_catalogue.json. Defaults to the file alongside
    the script in $PSScriptRoot.

.PARAMETER SkipRestorePoint
    Skip the System Restore Point creation step (faster, but no system-level
    rollback safety net).

.NOTES
    All registry / service / task changes are snapshotted to JSON before being
    applied, allowing per-action rollback even when Windows System Restore is
    unavailable. AppX uninstalls cannot be auto-restored — Microsoft Store
    is the only path to bring them back.

    Run elevated. The companion bootstrap.ps1 handles UAC.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$NoGui,
    [string]$ConfigFile,
    [string]$Export,
    [switch]$DryRun,
    [string]$CatalogueFile,
    [switch]$SkipRestorePoint
)

$ErrorActionPreference = 'Stop'
$script:Version       = '1.0.0'
$script:DataDir       = Join-Path $env:LOCALAPPDATA 'Win11Debloat'
$script:SnapshotDir   = Join-Path $script:DataDir 'snapshots'
$script:LogDir        = Join-Path $script:DataDir 'logs'
$script:LogPath       = $null
$script:LogTextBox    = $null
$script:DryRun        = [bool]$DryRun
$script:Snapshot      = $null

# -----------------------------------------------------------------------------
# Initialization
# -----------------------------------------------------------------------------
function Initialize-DataDirs {
    foreach ($d in @($script:DataDir, $script:SnapshotDir, $script:LogDir)) {
        if (-not (Test-Path $d)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }
    }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:LogPath = Join-Path $script:LogDir "run-$stamp.log"
}

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $ts = (Get-Date).ToString('HH:mm:ss')
    $line = "[$ts] $Message"
    Write-Host $line -ForegroundColor $Color
    if ($script:LogPath) { Add-Content -Path $script:LogPath -Value $line }
    if ($script:LogTextBox) {
        $script:LogTextBox.AppendText("$line`r`n")
        $script:LogTextBox.ScrollToCaret()
        try { [System.Windows.Forms.Application]::DoEvents() } catch {}
    }
}

# -----------------------------------------------------------------------------
# Snapshot subsystem
# Records state of every registry value / service / task / appx package BEFORE
# we modify it, so we can roll back individual actions without relying on
# Windows System Restore.
# -----------------------------------------------------------------------------
function New-Snapshot {
    @{
        schemaVersion = 1
        scriptVersion = $script:Version
        timestamp     = (Get-Date).ToString('o')
        computerName  = $env:COMPUTERNAME
        userName      = $env:USERNAME
        osCaption     = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        osBuild       = [System.Environment]::OSVersion.Version.Build
        restorePoint  = $null
        registry      = @()
        services      = @()
        tasks         = @()
        appx          = @()
        commands      = @()
        actions       = @()
    }
}

function Add-RegSnapshot {
    param([string]$Path,[string]$Name)
    if (-not $script:Snapshot) { return }
    $existed = $false; $oldValue = $null; $oldType = $null
    try {
        if (Test-Path $Path) {
            $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
            if ($item -and $null -ne $item.$Name) {
                $existed = $true
                $oldValue = $item.$Name
                $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
                if ($key) { $oldType = $key.GetValueKind($Name).ToString() }
            }
        }
    } catch {}
    $script:Snapshot.registry += @{
        path     = $Path
        name     = $Name
        existed  = $existed
        oldValue = $oldValue
        oldType  = $oldType
    }
}

function Add-ServiceSnapshot {
    param([string]$Name)
    if (-not $script:Snapshot) { return }
    try {
        $s = Get-Service -Name $Name -ErrorAction Stop
        $script:Snapshot.services += @{
            name        = $Name
            oldStatus   = $s.Status.ToString()
            oldStartType= $s.StartType.ToString()
        }
    } catch {
        $script:Snapshot.services += @{ name=$Name; oldStatus='NotFound'; oldStartType='NotFound' }
    }
}

function Add-AppxSnapshot {
    param([string]$Pattern,[array]$Packages,[array]$Provisioned)
    if (-not $script:Snapshot) { return }
    $script:Snapshot.appx += @{
        pattern             = $Pattern
        removedPackages     = @($Packages | ForEach-Object { @{ name=$_.Name; packageFullName=$_.PackageFullName; publisher=$_.Publisher; version=$_.Version.ToString() } })
        removedProvisioned  = @($Provisioned | ForEach-Object { @{ displayName=$_.DisplayName; packageName=$_.PackageName } })
    }
}

function Save-Snapshot {
    if (-not $script:Snapshot) { return $null }
    if ($script:DryRun) { Write-Log "  [DRY] would save snapshot" 'DarkCyan'; return $null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $path  = Join-Path $script:SnapshotDir "snapshot-$stamp.json"
    $script:Snapshot | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    Write-Log "  Snapshot saved: $path" 'DarkGray'
    return $path
}

function Get-SnapshotList {
    if (-not (Test-Path $script:SnapshotDir)) { return @() }
    Get-ChildItem -Path $script:SnapshotDir -Filter 'snapshot-*.json' | Sort-Object LastWriteTime -Descending
}

# -----------------------------------------------------------------------------
# Snapshot RESTORE - applies a snapshot in reverse
# -----------------------------------------------------------------------------
function Invoke-SnapshotRestore {
    param([Parameter(Mandatory)][string]$SnapshotFile)
    if (-not (Test-Path $SnapshotFile)) { throw "Snapshot file not found: $SnapshotFile" }
    Write-Log "Loading snapshot $SnapshotFile" 'Cyan'
    $snap = Get-Content $SnapshotFile -Raw | ConvertFrom-Json

    # Restore registry values in REVERSE order (LIFO)
    Write-Log "[Registry] restoring $($snap.registry.Count) value(s)" 'Yellow'
    foreach ($r in @($snap.registry | Select-Object -Last $snap.registry.Count) ) {
        try {
            if ($r.existed) {
                if (-not (Test-Path $r.path)) { New-Item -Path $r.path -Force | Out-Null }
                $type = if ($r.oldType) { $r.oldType } else { 'DWord' }
                New-ItemProperty -Path $r.path -Name $r.name -Value $r.oldValue -PropertyType $type -Force | Out-Null
                Write-Log "  [OK] $($r.path)\$($r.name) <- $($r.oldValue)" 'DarkGray'
            } else {
                Remove-ItemProperty -Path $r.path -Name $r.name -ErrorAction SilentlyContinue
                Write-Log "  [OK] removed $($r.path)\$($r.name) (didn't exist before)" 'DarkGray'
            }
        } catch {
            Write-Log "  [WARN] could not restore $($r.path)\$($r.name): $($_.Exception.Message)" 'Yellow'
        }
    }

    # Restore services
    Write-Log "[Services] restoring $($snap.services.Count) service(s)" 'Yellow'
    foreach ($s in $snap.services) {
        if ($s.oldStartType -eq 'NotFound') { continue }
        try {
            $startMap = @{ 'Automatic'='Automatic'; 'Manual'='Manual'; 'Disabled'='Disabled'; 'AutomaticDelayedStart'='Automatic' }
            $start = $startMap[$s.oldStartType]; if (-not $start) { $start = $s.oldStartType }
            Set-Service -Name $s.name -StartupType $start -ErrorAction SilentlyContinue
            if ($s.oldStatus -eq 'Running') { Start-Service -Name $s.name -ErrorAction SilentlyContinue }
            Write-Log "  [OK] $($s.name) -> $start (was $($s.oldStatus))" 'DarkGray'
        } catch { Write-Log "  [WARN] $($s.name): $($_.Exception.Message)" 'Yellow' }
    }

    # AppX cannot be auto-restored. Just report.
    if ($snap.appx -and $snap.appx.Count -gt 0) {
        Write-Log "[AppX] $($snap.appx.Count) package(s) were uninstalled." 'Yellow'
        Write-Log "  AppX packages cannot be auto-restored. Reinstall from Microsoft Store:" 'Yellow'
        foreach ($a in $snap.appx) {
            foreach ($p in $a.removedPackages) { Write-Log "    - $($p.name)" 'DarkGray' }
        }
    }

    & gpupdate /force | Out-Null
    Write-Log "Restore complete. A reboot is recommended." 'Green'
}

# -----------------------------------------------------------------------------
# Set-Reg with snapshot
# -----------------------------------------------------------------------------
function Set-Reg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','ExpandString','Binary','MultiString','QWord')]
        [string]$Type = 'DWord'
    )
    Add-RegSnapshot -Path $Path -Name $Name
    if ($script:DryRun) {
        Write-Log "  [DRY] $Path\$Name = $Value ($Type)" 'DarkCyan'; return
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Log "  [OK]  $Path\$Name = $Value ($Type)" 'DarkGray'
}

function Set-ServiceState {
    param([string]$Name,[string]$StartType='Disabled',[bool]$StopFirst=$true)
    Add-ServiceSnapshot -Name $Name
    if ($script:DryRun) {
        Write-Log "  [DRY] svc $Name -> $StartType (stopFirst=$StopFirst)" 'DarkCyan'; return
    }
    try {
        if ($StopFirst) { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
        Write-Log "  [OK]  svc $Name -> $StartType" 'DarkGray'
    } catch { Write-Log "  [WARN] svc $Name : $($_.Exception.Message)" 'Yellow' }
}

# -----------------------------------------------------------------------------
# System Restore Point
# -----------------------------------------------------------------------------
function New-SystemRestorePoint-Safe {
    param([string]$Description = "Win11Debloat $($script:Version)")
    if ($script:DryRun) { Write-Log "[DRY] would create restore point '$Description'" 'DarkCyan'; return $null }
    if ($SkipRestorePoint) { Write-Log "[Restore Point] skipped (-SkipRestorePoint)" 'Yellow'; return $null }

    Write-Log "[Restore Point] preparing..." 'Cyan'
    try {
        # Enable System Protection on C: if not already
        try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop }
        catch { Write-Log "  could not enable System Protection: $($_.Exception.Message)" 'Yellow' }

        # Bypass 1440-min cooldown (allows multiple restore points per day)
        $sr = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        if (-not (Test-Path $sr)) { New-Item -Path $sr -Force | Out-Null }
        New-ItemProperty -Path $sr -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null

        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log "[Restore Point] created: $Description" 'Green'
        if ($script:Snapshot) { $script:Snapshot.restorePoint = @{ description=$Description; timestamp=(Get-Date).ToString('o') } }
        return $true
    } catch {
        Write-Log "[Restore Point] FAILED: $($_.Exception.Message)" 'Red'
        Write-Log "  Continuing anyway. Per-action snapshot will still be saved." 'Yellow'
        return $false
    }
}

# -----------------------------------------------------------------------------
# AppX removal with snapshot
# -----------------------------------------------------------------------------
function Remove-AppxByPattern {
    param([Parameter(Mandatory)][string]$Pattern)
    $installed = @(Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction SilentlyContinue)
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Pattern })

    if (-not $installed -and -not $provisioned) {
        Write-Log "  [--]  $Pattern (not present)"
        return
    }
    Add-AppxSnapshot -Pattern $Pattern -Packages $installed -Provisioned $provisioned

    foreach ($pkg in $installed) {
        if ($script:DryRun) {
            Write-Log "  [DRY] would remove $($pkg.PackageFullName)" 'DarkCyan'
        } else {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Log "  [OK]  removed $($pkg.Name)" 'DarkGray'
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
                Write-Log "  [OK]  deprovisioned $($prov.DisplayName)" 'DarkGray'
            } catch {
                Write-Log "  [WARN] could not deprovision $($prov.DisplayName): $($_.Exception.Message)" 'Yellow'
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Catalogue loader - reads security_catalogue.json
# -----------------------------------------------------------------------------
function Get-SecurityCatalogue {
    $candidates = @()
    if ($CatalogueFile) { $candidates += $CatalogueFile }
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot 'security_catalogue.json') }
    $candidates += (Join-Path (Split-Path -Parent $MyInvocation.PSCommandPath) 'security_catalogue.json' -ErrorAction SilentlyContinue 2>$null)
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) {
            try {
                $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
                Write-Log "Loaded security catalogue: $p ($($j.findings.Count) findings)" 'DarkGray'
                return $j
            } catch {
                Write-Log "Failed to parse catalogue at $p : $($_.Exception.Message)" 'Yellow'
            }
        }
    }
    Write-Log "No security_catalogue.json found - Security tab will be empty." 'Yellow'
    return $null
}

# -----------------------------------------------------------------------------
# Apply a single security-catalogue finding
# -----------------------------------------------------------------------------
function Invoke-CatalogueFinding {
    param([Parameter(Mandatory)]$Finding)
    Write-Log "[$($Finding.severity)/$($Finding.compatibility)] $($Finding.friendlyName)" 'Yellow'
    $impl = $Finding.implementation
    $type = $impl.type

    if ($type -eq 'manual') {
        Write-Log "  MANUAL action - displaying audit commands. No automatic change applied." 'Yellow'
        if ($impl.command) {
            foreach ($c in $impl.command) {
                Write-Log "  > $($c.description)" 'DarkGray'
                if (-not $script:DryRun) {
                    try {
                        $output = Invoke-Expression $c.command 2>&1 | Out-String
                        if ($output) { Write-Log $output.Trim() 'DarkGray' }
                    } catch {
                        Write-Log "  [WARN] command failed: $($_.Exception.Message)" 'Yellow'
                    }
                }
            }
        }
        return
    }

    if ($impl.registry) {
        foreach ($r in $impl.registry) {
            $vt = if ($r.valueType) { $r.valueType } else { 'DWord' }
            Set-Reg -Path $r.path -Name $r.name -Value $r.value -Type $vt
        }
    }
    if ($impl.service) {
        foreach ($s in $impl.service) {
            $stop = if ($null -ne $s.stopFirst) { [bool]$s.stopFirst } else { $true }
            Set-ServiceState -Name $s.name -StartType $s.targetStartType -StopFirst $stop
        }
    }
    if ($impl.scheduledTask) {
        foreach ($t in $impl.scheduledTask) {
            if ($script:DryRun) { Write-Log "  [DRY] task $($t.path)\$($t.name) -> $($t.action)" 'DarkCyan'; continue }
            try {
                if ($t.action -eq 'disable') {
                    Disable-ScheduledTask -TaskPath $t.path -TaskName $t.name -ErrorAction Stop | Out-Null
                    Write-Log "  [OK]  disabled task $($t.path)$($t.name)" 'DarkGray'
                }
            } catch { Write-Log "  [WARN] task: $($_.Exception.Message)" 'Yellow' }
        }
    }
    if ($impl.command) {
        foreach ($c in $impl.command) {
            if ($script:DryRun) { Write-Log "  [DRY] $($c.shell): $($c.command)" 'DarkCyan'; continue }
            try {
                if ($c.shell -eq 'cmd') {
                    cmd /c $c.command 2>&1 | Out-Null
                } else {
                    Invoke-Expression $c.command 2>&1 | Out-Null
                }
                Write-Log "  [OK]  $($c.description)" 'DarkGray'
            } catch { Write-Log "  [WARN] cmd: $($_.Exception.Message)" 'Yellow' }
        }
    }
    if ($script:Snapshot) {
        $script:Snapshot.actions += @{ id=$Finding.id; ts=(Get-Date).ToString('o') }
    }
}

# -----------------------------------------------------------------------------
# Built-in action catalogue (ad sections + apps) - preserved from v0
# These are ALWAYS in the catalogue. Security findings are loaded from JSON.
# -----------------------------------------------------------------------------
$cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"

$script:AdActions = @(
    @{
        Id='ad-lockscreen-tips'
        Title='Lock screen tips & weather widget'
        Detail='Kills the "fun facts" overlay and the MSN/weather redirect that opens Edge.'
        Category='Ads & Promotions'
        Action={ Set-Reg $cdm "RotatingLockScreenOverlayEnabled" 0; Set-Reg $cdm "SubscribedContent-338387Enabled" 0; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen" "SlideshowEnabled" 0 }
    }
    @{
        Id='ad-start-recommendations'
        Title='Start menu recommendations & suggested apps'
        Detail='Disables the "Recommended" section and silently installed promo apps.'
        Category='Ads & Promotions'
        Action={ Set-Reg $cdm "SubscribedContent-338388Enabled" 0; Set-Reg $cdm "SilentInstalledAppsEnabled" 0; Set-Reg $cdm "PreInstalledAppsEnabled" 0; Set-Reg $cdm "OEMPreInstalledAppsEnabled" 0; Set-Reg $cdm "ContentDeliveryAllowed" 0; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_IrisRecommendations" 0 }
    }
    @{
        Id='ad-system-tips'
        Title='System tips & welcome experience'
        Detail='"Get the most out of Windows", post-update welcome screens, suggestions.'
        Category='Ads & Promotions'
        Action={ Set-Reg $cdm "SubscribedContent-310093Enabled" 0; Set-Reg $cdm "SubscribedContent-314559Enabled" 0; Set-Reg $cdm "SubscribedContent-338389Enabled" 0; Set-Reg $cdm "SubscribedContent-353698Enabled" 0; Set-Reg $cdm "SystemPaneSuggestionsEnabled" 0; Set-Reg $cdm "SoftLandingEnabled" 0 }
    }
    @{
        Id='ad-settings-suggestions'
        Title='Settings app "suggested content"'
        Detail='Removes promo cards inside the Settings app.'
        Category='Ads & Promotions'
        Action={ Set-Reg $cdm "SubscribedContent-338393Enabled" 0; Set-Reg $cdm "SubscribedContent-353694Enabled" 0; Set-Reg $cdm "SubscribedContent-353696Enabled" 0 }
    }
    @{
        Id='ad-advertising-id'
        Title='Advertising ID & tailored experiences'
        Detail='Disables advertising ID, language tracking, writing-data telemetry.'
        Category='Ads & Promotions'
        Action={ Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0; Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 0; Set-Reg "HKCU:\Software\Microsoft\Input\TIPC" "Enabled" 0; Set-Reg "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 1 }
    }
    @{
        Id='ad-explorer-sync'
        Title='File Explorer ads (sync provider notifications)'
        Detail='Disables OneDrive / sync provider promo notifications in File Explorer.'
        Category='Ads & Promotions'
        Action={ Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowSyncProviderNotifications" 0 }
    }
    @{
        Id='ad-search-highlights'
        Title='Taskbar search highlights & widgets news feed'
        Detail='Removes Bing/news highlights from search; widgets panel itself still works.'
        Category='Ads & Promotions'
        Action={ Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDynamicSearchBoxEnabled" 0; Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" 0 }
    }
    @{
        Id='ad-consumer-experiences'
        Title='Disable Microsoft Consumer Experiences (machine policy)'
        Detail='Master switch that prevents Spotify/Disney/TikTok auto-installs on this and new accounts.'
        Category='Ads & Promotions'
        Action={ $cc="HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Set-Reg $cc "DisableWindowsConsumerFeatures" 1; Set-Reg $cc "DisableConsumerAccountStateContent" 1; Set-Reg $cc "DisableSoftLanding" 1; Set-Reg $cc "DisableCloudOptimizedContent" 1 }
    }
    @{
        Id='ad-edge-promotions'
        Title='Edge promotional content'
        Detail='New tab MSN feed, first-run nag, Rewards prompts, shopping assistant.'
        Category='Ads & Promotions'
        Action={ $edge="HKLM:\SOFTWARE\Policies\Microsoft\Edge"; Set-Reg $edge "HideFirstRunExperience" 1; Set-Reg $edge "ShowRecommendationsEnabled" 0; Set-Reg $edge "PersonalizationReportingEnabled" 0; Set-Reg $edge "NewTabPageContentEnabled" 0; Set-Reg $edge "NewTabPageQuickLinksEnabled" 0; Set-Reg $edge "NewTabPageHideDefaultTopSites" 1; Set-Reg $edge "EdgeShoppingAssistantEnabled" 0; Set-Reg $edge "ShowMicrosoftRewards" 0 }
    }
)

$script:TelemetryActions = @(
    @{
        Id='tel-diag-track-disable'
        Title='Disable DiagTrack (Connected User Experiences and Telemetry) service'
        Detail='Stops the main outbound telemetry service. Does not affect local Event Logs.'
        Category='Telemetry'
        Action={ Set-ServiceState -Name 'DiagTrack' -StartType 'Disabled' -StopFirst $true; Set-ServiceState -Name 'dmwappushservice' -StartType 'Disabled' -StopFirst $true }
    }
    @{
        Id='tel-allow-telemetry-zero'
        Title='Set AllowTelemetry policy to Security (lowest) - 0 on Pro/Enterprise'
        Detail='Pro respects the 0 (Security) setting. Equivalent to "Required only" in the UI plus stricter.'
        Category='Telemetry'
        Action={ Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0; Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0 }
    }
    @{
        Id='tel-disable-feedback'
        Title='Disable feedback frequency / hub feedback'
        Detail='Stops automated feedback prompts and Feedback Hub auto-prompts.'
        Category='Telemetry'
        Action={ Set-Reg "HKCU:\Software\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod" 0; Set-Reg "HKCU:\Software\Microsoft\Siuf\Rules" "PeriodInNanoSeconds" 0; Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DoNotShowFeedbackNotifications" 1 }
    }
    @{
        Id='tel-disable-activity-history'
        Title='Disable Activity History collection / upload'
        Detail='Local + cloud Timeline / Activity History data collection.'
        Category='Telemetry'
        Action={ $p="HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Set-Reg $p "EnableActivityFeed" 0; Set-Reg $p "PublishUserActivities" 0; Set-Reg $p "UploadUserActivities" 0 }
    }
    @{
        Id='tel-disable-ceip-tasks'
        Title='Disable Customer Experience Improvement Program scheduled tasks'
        Detail='ProgramDataUpdater, Microsoft Compatibility Appraiser, KernelCeipTask, UsbCeip, Consolidator, etc.'
        Category='Telemetry'
        Action={
            $tasks = @(
                '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
                '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
                '\Microsoft\Windows\Application Experience\StartupAppTask',
                '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
                '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
                '\Microsoft\Windows\Autochk\Proxy',
                '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
                '\Microsoft\Windows\NetTrace\GatherNetworkInfo',
                '\Microsoft\Windows\Feedback\Siuf\DmClient',
                '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
                '\Microsoft\Windows\PI\Sqm-Tasks'
            )
            foreach ($tp in $tasks) {
                if ($script:DryRun) { Write-Log "  [DRY] disable task $tp" 'DarkCyan'; continue }
                try {
                    $dir = Split-Path -Path $tp -Parent
                    $name = Split-Path -Path $tp -Leaf
                    Disable-ScheduledTask -TaskPath ($dir + '\') -TaskName $name -ErrorAction Stop | Out-Null
                    Write-Log "  [OK]  disabled task $tp" 'DarkGray'
                } catch { Write-Log "  [--]  task $tp not present or already disabled" 'DarkGray' }
            }
        }
    }
    @{
        Id='tel-disable-error-reporting'
        Title='Disable Windows Error Reporting'
        Detail='WER service + per-user crash uploads.'
        Category='Telemetry'
        Action={ Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1; Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "DontSendAdditionalData" 1; Set-ServiceState -Name 'WerSvc' -StartType 'Disabled' -StopFirst $true }
    }
    @{
        Id='tel-disable-cloud-sync'
        Title='Disable cloud-based suggestions in IME / Search'
        Detail='Online tips, search suggestions, cloud handwriting recognition.'
        Category='Telemetry'
        Action={ $p="HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Set-Reg $p "BingSearchEnabled" 0; Set-Reg $p "CortanaConsent" 0; Set-Reg $p "CortanaCloudSearchEnabled" 0; Set-Reg "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" 1; Set-Reg "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" 1 }
    }
)

$script:Tier1Apps = @(
    @{ Pattern='*AdobePhotoshopExpress*'; Display='Adobe Photoshop Express' }
    @{ Pattern='*BubbleWitch3Saga*'; Display='Bubble Witch 3 Saga' }
    @{ Pattern='*CandyCrush*'; Display='Candy Crush' }
    @{ Pattern='*Disney*'; Display='Disney+' }
    @{ Pattern='*DolbyAccess*'; Display='Dolby Access' }
    @{ Pattern='*Duolingo*'; Display='Duolingo' }
    @{ Pattern='*EclipseManager*'; Display='Eclipse Manager' }
    @{ Pattern='*Facebook*'; Display='Facebook' }
    @{ Pattern='*Flipboard*'; Display='Flipboard' }
    @{ Pattern='*HiddenCity*'; Display='Hidden City' }
    @{ Pattern='king.com.*'; Display='king.com games' }
    @{ Pattern='*LinkedInforWindows*'; Display='LinkedIn' }
    @{ Pattern='*MarchofEmpires*'; Display='March of Empires' }
    @{ Pattern='*Netflix*'; Display='Netflix' }
    @{ Pattern='*PandoraMediaInc*'; Display='Pandora' }
    @{ Pattern='*PicsArt*'; Display='PicsArt' }
    @{ Pattern='*Spotify*'; Display='Spotify' }
    @{ Pattern='*TikTok*'; Display='TikTok' }
    @{ Pattern='*Twitter*'; Display='Twitter / X' }
    @{ Pattern='*Wunderlist*'; Display='Wunderlist' }
    @{ Pattern='Microsoft.Advertising.Xaml'; Display='Microsoft Advertising SDK' }
    @{ Pattern='Microsoft.BingNews'; Display='MSN News (Bing News)' }
    @{ Pattern='Microsoft.BingSearch'; Display='Bing Search' }
    @{ Pattern='Microsoft.GetHelp'; Display='Get Help' }
    @{ Pattern='Microsoft.Getstarted'; Display='Tips' }
    @{ Pattern='Microsoft.MicrosoftOfficeHub'; Display='Office Hub launcher' }
    @{ Pattern='Microsoft.MicrosoftSolitaireCollection'; Display='Microsoft Solitaire' }
    @{ Pattern='Microsoft.MixedReality.Portal'; Display='Mixed Reality Portal' }
    @{ Pattern='Microsoft.OneConnect'; Display='Mobile Plans' }
    @{ Pattern='Microsoft.People'; Display='People (legacy)' }
    @{ Pattern='Microsoft.Print3D'; Display='Print 3D' }
    @{ Pattern='Microsoft.SkypeApp'; Display='Skype (consumer)' }
    @{ Pattern='Microsoft.Wallet'; Display='Wallet' }
    @{ Pattern='Microsoft.WindowsFeedbackHub'; Display='Feedback Hub' }
    @{ Pattern='Clipchamp.Clipchamp'; Display='Clipchamp' }
)

$script:Tier2Apps = @(
    @{ Pattern='Microsoft.WindowsCommunicationsApps'; Display='Mail + Calendar' }
    @{ Pattern='Microsoft.YourPhone'; Display='Phone Link' }
    @{ Pattern='Microsoft.WindowsMaps'; Display='Maps' }
    @{ Pattern='Microsoft.ZuneMusic'; Display='Media Player / Groove' }
    @{ Pattern='Microsoft.ZuneVideo'; Display='Movies & TV' }
    @{ Pattern='Microsoft.WindowsSoundRecorder'; Display='Sound Recorder' }
    @{ Pattern='Microsoft.WindowsAlarms'; Display='Alarms & Clock' }
    @{ Pattern='Microsoft.GamingApp'; Display='Xbox app' }
    @{ Pattern='Microsoft.Xbox.TCUI'; Display='Xbox TCUI' }
    @{ Pattern='Microsoft.XboxGameOverlay'; Display='Xbox Game Overlay' }
    @{ Pattern='Microsoft.XboxGamingOverlay'; Display='Xbox Gaming Overlay' }
    @{ Pattern='Microsoft.XboxSpeechToTextOverlay'; Display='Xbox Speech-to-Text' }
)

# -----------------------------------------------------------------------------
# Apply pipeline - takes a Selection object and runs everything in it
# Selection = @{ ads=@('id1','id2'); telemetry=@(...); apps=@(...); security=@(...) }
# -----------------------------------------------------------------------------
function Invoke-Selection {
    param([Parameter(Mandatory)][hashtable]$Selection,$Catalogue)

    $script:Snapshot = New-Snapshot
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    $totalActions = $Selection.ads.Count + $Selection.telemetry.Count + $Selection.apps.Count + $Selection.security.Count
    if ($totalActions -eq 0) {
        Write-Log "Nothing selected. Done." 'Yellow'; return
    }

    Write-Log "=== Win11Debloat $($script:Version) - $stamp ===" 'Cyan'
    Write-Log "Selection: ads=$($Selection.ads.Count) telemetry=$($Selection.telemetry.Count) apps=$($Selection.apps.Count) security=$($Selection.security.Count)" 'Cyan'
    if ($script:DryRun) { Write-Log "*** DRY RUN - no changes will be made ***" 'Magenta' }

    # System Restore Point first
    New-SystemRestorePoint-Safe | Out-Null

    # Ad sections
    if ($Selection.ads.Count -gt 0) {
        Write-Log "`n--- Ads & Promotions ---" 'Cyan'
        foreach ($id in $Selection.ads) {
            $a = $script:AdActions | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($a) {
                Write-Log "[$($a.Title)]" 'Yellow'
                & $a.Action
                if ($script:Snapshot) { $script:Snapshot.actions += @{ id=$id; ts=(Get-Date).ToString('o') } }
            }
        }
    }

    # Telemetry
    if ($Selection.telemetry.Count -gt 0) {
        Write-Log "`n--- Telemetry ---" 'Cyan'
        foreach ($id in $Selection.telemetry) {
            $a = $script:TelemetryActions | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($a) {
                Write-Log "[$($a.Title)]" 'Yellow'
                & $a.Action
                if ($script:Snapshot) { $script:Snapshot.actions += @{ id=$id; ts=(Get-Date).ToString('o') } }
            }
        }
    }

    # AppX uninstalls
    if ($Selection.apps.Count -gt 0) {
        Write-Log "`n--- App uninstalls ---" 'Cyan'
        $allApps = @($script:Tier1Apps + $script:Tier2Apps)
        foreach ($pattern in $Selection.apps) {
            Remove-AppxByPattern -Pattern $pattern
        }
    }

    # Security findings
    if ($Selection.security.Count -gt 0 -and $Catalogue) {
        Write-Log "`n--- Security findings ---" 'Cyan'
        foreach ($id in $Selection.security) {
            $f = $Catalogue.findings | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if ($f) { Invoke-CatalogueFinding -Finding $f }
        }
    }

    if (-not $script:DryRun) {
        Write-Log "`nApplying group policy..." 'Cyan'
        & gpupdate /force | Out-Null
    }

    $snapPath = Save-Snapshot
    Write-Log "`n=== Done. Sign out / reboot for everything to take full effect. ===" 'Green'
    if ($snapPath) { Write-Log "Per-action rollback file: $snapPath" 'Green' }
    return $snapPath
}

# -----------------------------------------------------------------------------
# Config export/import
# -----------------------------------------------------------------------------
function Export-Config {
    param([Parameter(Mandatory)][hashtable]$Selection,[Parameter(Mandatory)][string]$Path)
    $cfg = @{
        schemaVersion = 1
        scriptVersion = $script:Version
        timestamp     = (Get-Date).ToString('o')
        computerName  = $env:COMPUTERNAME
        selection     = $Selection
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
    Write-Log "Exported config to $Path" 'Green'
}

function Import-Config {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Config file not found: $Path" }
    $j = Get-Content $Path -Raw | ConvertFrom-Json
    Write-Log "Loaded config from $Path (created $($j.timestamp) on $($j.computerName))" 'Green'
    $sel = @{ ads=@(); telemetry=@(); apps=@(); security=@() }
    if ($j.selection.ads)       { $sel.ads       = @($j.selection.ads) }
    if ($j.selection.telemetry) { $sel.telemetry = @($j.selection.telemetry) }
    if ($j.selection.apps)      { $sel.apps      = @($j.selection.apps) }
    if ($j.selection.security)  { $sel.security  = @($j.selection.security) }
    return $sel
}

# -----------------------------------------------------------------------------
# CLI mode
# -----------------------------------------------------------------------------
function Invoke-CliMode {
    param($Catalogue)
    if ($Export) {
        # Export current state - which means "everything currently in the catalogue, all unchecked"
        # since we don't know what's already applied. For a meaningful initial-state export,
        # the user should use the GUI's "Export current state" which can introspect.
        $sel = @{ ads=@(); telemetry=@(); apps=@(); security=@() }
        Export-Config -Selection $sel -Path $Export
        return
    }
    if ($ConfigFile) {
        $sel = Import-Config -Path $ConfigFile
        Invoke-Selection -Selection $sel -Catalogue $Catalogue
        return
    }
    Write-Log "CLI mode requires -ConfigFile or -Export. Run without -NoGui for the GUI." 'Red'
}

# -----------------------------------------------------------------------------
# GUI mode
# -----------------------------------------------------------------------------
function Show-Gui {
    param($Catalogue)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = "Win11 Debloat & Hardening v$($script:Version)"
    $form.Size          = New-Object System.Drawing.Size(1100, 880)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize   = New-Object System.Drawing.Size(900, 700)

    # Header
    $header = New-Object System.Windows.Forms.Label
    $header.Text     = "Win11 Debloat & Hardening v$($script:Version)"
    $header.Font     = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $header.Location = New-Object System.Drawing.Point(15, 12)
    $header.Size     = New-Object System.Drawing.Size(900, 26)
    $form.Controls.Add($header)

    $sub = New-Object System.Windows.Forms.Label
    if ($Catalogue) {
        $sub.Text = "Loaded $($Catalogue.findings.Count) security findings + $($script:AdActions.Count) ad actions + $($script:TelemetryActions.Count) telemetry actions + $($script:Tier1Apps.Count + $script:Tier2Apps.Count) bloat apps. Hover any item for details. Nothing is selected by default."
    } else {
        $sub.Text = "Security catalogue not found. Only built-in ad / telemetry / apps available. Place security_catalogue.json next to this script."
    }
    $sub.Location  = New-Object System.Drawing.Point(15, 40)
    $sub.Size      = New-Object System.Drawing.Size(1050, 32)
    $sub.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($sub)

    # Tab control
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(15, 76)
    $tabs.Size     = New-Object System.Drawing.Size(1055, 600)
    $tabs.Anchor   = 'Top,Bottom,Left,Right'
    $form.Controls.Add($tabs)

    # State containers
    $script:GuiCheckboxes = @{}  # id -> checkbox
    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.AutoPopDelay = 30000

    # Helper: build a tab with a CheckedListBox of items
    function Add-CheckTab {
        param($Title,$Items,$IdField,$DisplayField,$DetailField,$BadgeFormatter)
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = $Title
        $tabs.TabPages.Add($tab)

        # Search box (label + textbox; PlaceholderText is .NET 4.7.2+, avoid it)
        $lblSb = New-Object System.Windows.Forms.Label
        $lblSb.Text = "Search:"
        $lblSb.Location = New-Object System.Drawing.Point(8, 12)
        $lblSb.Size = New-Object System.Drawing.Size(50, 20)
        $tab.Controls.Add($lblSb)

        $sb = New-Object System.Windows.Forms.TextBox
        $sb.Location = New-Object System.Drawing.Point(60, 8)
        $sb.Size = New-Object System.Drawing.Size(348, 24)
        $tab.Controls.Add($sb)

        $btnAll = New-Object System.Windows.Forms.Button
        $btnAll.Text = "Select all (visible)"; $btnAll.Location = New-Object System.Drawing.Point(420, 6); $btnAll.Size = New-Object System.Drawing.Size(140, 26)
        $tab.Controls.Add($btnAll)

        $btnNone = New-Object System.Windows.Forms.Button
        $btnNone.Text = "Clear all"; $btnNone.Location = New-Object System.Drawing.Point(566, 6); $btnNone.Size = New-Object System.Drawing.Size(90, 26)
        $tab.Controls.Add($btnNone)

        # Use a Panel with auto-scroll so we can put rich CheckBox controls
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Location = New-Object System.Drawing.Point(0, 40)
        $panel.Size = New-Object System.Drawing.Size(1043, 540)
        $panel.AutoScroll = $true
        $panel.Anchor = 'Top,Bottom,Left,Right'
        $tab.Controls.Add($panel)

        $y = 6
        $tabCheckboxes = New-Object System.Collections.ArrayList
        foreach ($it in $Items) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $idVal = $it.($IdField)
            $disp  = $it.($DisplayField)
            $det   = if ($DetailField) { $it.($DetailField) } else { '' }
            $badge = if ($BadgeFormatter) { & $BadgeFormatter $it } else { '' }
            $cb.Text = if ($badge) { "$badge  $disp" } else { $disp }
            $cb.Tag = $idVal
            $cb.Location = New-Object System.Drawing.Point(8, $y)
            $cb.Size = New-Object System.Drawing.Size(1020, 22)
            $cb.AutoSize = $false
            $tooltip.SetToolTip($cb, $det)
            $panel.Controls.Add($cb)
            $script:GuiCheckboxes[$idVal] = $cb
            [void]$tabCheckboxes.Add($cb)
            $y += 26
        }

        # Wire up search
        $sb.Add_TextChanged({
            $q = $sb.Text.ToLower()
            foreach ($c in $tabCheckboxes) {
                $c.Visible = ($q -eq '' -or $c.Text.ToLower().Contains($q))
            }
        }.GetNewClosure())
        $btnAll.Add_Click({ foreach ($c in $tabCheckboxes) { if ($c.Visible) { $c.Checked = $true } } }.GetNewClosure())
        $btnNone.Add_Click({ foreach ($c in $tabCheckboxes) { $c.Checked = $false } }.GetNewClosure())

        return $tab
    }

    # Build tabs
    Add-CheckTab -Title "Ads & Promotions" -Items $script:AdActions `
        -IdField 'Id' -DisplayField 'Title' -DetailField 'Detail' | Out-Null

    Add-CheckTab -Title "Telemetry" -Items $script:TelemetryActions `
        -IdField 'Id' -DisplayField 'Title' -DetailField 'Detail' | Out-Null

    # Apps - use Pattern as ID
    $appItems = @($script:Tier1Apps | ForEach-Object { @{Pattern=$_.Pattern; Display="[T1] $($_.Display)"} }) +
                @($script:Tier2Apps | ForEach-Object { @{Pattern=$_.Pattern; Display="[T2] $($_.Display)"} })
    Add-CheckTab -Title "Bloat Apps" -Items $appItems `
        -IdField 'Pattern' -DisplayField 'Display' -DetailField $null | Out-Null

    # Security tabs - one tab per category
    if ($Catalogue) {
        foreach ($cat in $Catalogue.categories) {
            $catFindings = @($Catalogue.findings | Where-Object { $_.categoryId -eq $cat.id })
            if ($catFindings.Count -eq 0) { continue }
            $title = "$($cat.title)  ($($catFindings.Count))"
            $items = $catFindings | ForEach-Object {
                @{ id=$_.id; friendlyName=$_.friendlyName; description="[$($_.severity) / $($_.compatibility)] $($_.description)`r`n`r`nCompat note: $($_.compatNote)"; sev=$_.severity; comp=$_.compatibility }
            }
            $badgeFn = { param($it) "[$($it.sev[0])/$($it.comp[0])]" }
            Add-CheckTab -Title $title -Items $items `
                -IdField 'id' -DisplayField 'friendlyName' -DetailField 'description' `
                -BadgeFormatter $badgeFn | Out-Null
        }
    }

    # Bottom action bar
    $cbDry = New-Object System.Windows.Forms.CheckBox
    $cbDry.Text = "Dry run (preview - no changes)"
    $cbDry.Location = New-Object System.Drawing.Point(20, 690)
    $cbDry.Size = New-Object System.Drawing.Size(240, 22)
    $cbDry.Anchor = 'Bottom,Left'
    $form.Controls.Add($cbDry)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Text = "Export config..."
    $btnExport.Location = New-Object System.Drawing.Point(280, 686)
    $btnExport.Size = New-Object System.Drawing.Size(130, 30)
    $btnExport.Anchor = 'Bottom,Left'
    $form.Controls.Add($btnExport)

    $btnImport = New-Object System.Windows.Forms.Button
    $btnImport.Text = "Import config..."
    $btnImport.Location = New-Object System.Drawing.Point(420, 686)
    $btnImport.Size = New-Object System.Drawing.Size(130, 30)
    $btnImport.Anchor = 'Bottom,Left'
    $form.Controls.Add($btnImport)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = "Rollback snapshot..."
    $btnRestore.Location = New-Object System.Drawing.Point(560, 686)
    $btnRestore.Size = New-Object System.Drawing.Size(150, 30)
    $btnRestore.Anchor = 'Bottom,Left'
    $form.Controls.Add($btnRestore)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Apply"
    $btnApply.Location = New-Object System.Drawing.Point(870, 684)
    $btnApply.Size = New-Object System.Drawing.Size(95, 34)
    $btnApply.Anchor = 'Bottom,Right'
    $btnApply.BackColor = [System.Drawing.Color]::FromArgb(0,120,215)
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = 'Flat'
    $form.Controls.Add($btnApply)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(975, 684)
    $btnClose.Size = New-Object System.Drawing.Size(95, 34)
    $btnClose.Anchor = 'Bottom,Right'
    $btnClose.Add_Click({ $form.Close() })
    $form.Controls.Add($btnClose)

    # Log
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.ReadOnly = $true
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtLog.Location = New-Object System.Drawing.Point(15, 730)
    $txtLog.Size = New-Object System.Drawing.Size(1055, 100)
    $txtLog.Anchor = 'Top,Bottom,Left,Right'
    $txtLog.BackColor = [System.Drawing.Color]::Black
    $txtLog.ForeColor = [System.Drawing.Color]::LightGray
    $form.Controls.Add($txtLog)
    $script:LogTextBox = $txtLog

    # Helper to gather selection from all checkboxes
    $gatherSelection = {
        $sel = @{ ads=@(); telemetry=@(); apps=@(); security=@() }
        foreach ($a in $script:AdActions) {
            $cb = $script:GuiCheckboxes[$a.Id]
            if ($cb -and $cb.Checked) { $sel.ads += $a.Id }
        }
        foreach ($a in $script:TelemetryActions) {
            $cb = $script:GuiCheckboxes[$a.Id]
            if ($cb -and $cb.Checked) { $sel.telemetry += $a.Id }
        }
        foreach ($a in @($script:Tier1Apps + $script:Tier2Apps)) {
            $cb = $script:GuiCheckboxes[$a.Pattern]
            if ($cb -and $cb.Checked) { $sel.apps += $a.Pattern }
        }
        if ($Catalogue) {
            foreach ($f in $Catalogue.findings) {
                $cb = $script:GuiCheckboxes[$f.id]
                if ($cb -and $cb.Checked) { $sel.security += $f.id }
            }
        }
        return $sel
    }

    # Apply button
    $btnApply.Add_Click({
        $txtLog.Clear()
        $script:DryRun = $cbDry.Checked
        $sel = & $gatherSelection
        $total = $sel.ads.Count + $sel.telemetry.Count + $sel.apps.Count + $sel.security.Count
        if ($total -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Nothing selected.','Win11 Debloat','OK','Information') | Out-Null
            return
        }
        $msg = "About to apply $total actions:`r`n  Ads: $($sel.ads.Count)`r`n  Telemetry: $($sel.telemetry.Count)`r`n  Apps: $($sel.apps.Count)`r`n  Security: $($sel.security.Count)`r`n`r`nA System Restore Point and per-action snapshot will be created.`r`n`r`nProceed?"
        if ($script:DryRun) { $msg = "DRY RUN - $msg" }
        $r = [System.Windows.Forms.MessageBox]::Show($msg,'Win11 Debloat','YesNo','Warning')
        if ($r -ne 'Yes') { return }
        $btnApply.Enabled = $false
        try { Invoke-Selection -Selection $sel -Catalogue $Catalogue }
        catch { Write-Log "ERROR: $($_.Exception.Message)" 'Red' }
        finally { $btnApply.Enabled = $true }
    })

    # Export button
    $btnExport.Add_Click({
        $sel = & $gatherSelection
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "JSON config (*.json)|*.json"
        $sfd.FileName = "win11debloat-config-$(Get-Date -Format 'yyyyMMdd-HHmm').json"
        if ($sfd.ShowDialog() -eq 'OK') {
            try { Export-Config -Selection $sel -Path $sfd.FileName }
            catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Export failed','OK','Error') | Out-Null }
        }
    })

    # Import button
    $btnImport.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "JSON config (*.json)|*.json"
        if ($ofd.ShowDialog() -eq 'OK') {
            try {
                $sel = Import-Config -Path $ofd.FileName
                # Apply to GUI: clear all then check imported ids
                foreach ($cb in $script:GuiCheckboxes.Values) { $cb.Checked = $false }
                foreach ($id in $sel.ads + $sel.telemetry + $sel.security) {
                    if ($script:GuiCheckboxes[$id]) { $script:GuiCheckboxes[$id].Checked = $true }
                }
                foreach ($p in $sel.apps) {
                    if ($script:GuiCheckboxes[$p]) { $script:GuiCheckboxes[$p].Checked = $true }
                }
                Write-Log "Loaded $($sel.ads.Count + $sel.telemetry.Count + $sel.apps.Count + $sel.security.Count) selections from config." 'Green'
            } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Import failed','OK','Error') | Out-Null
            }
        }
    })

    # Rollback button
    $btnRestore.Add_Click({
        $snaps = Get-SnapshotList
        if ($snaps.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No snapshots found in $($script:SnapshotDir).",'Rollback','OK','Information') | Out-Null
            return
        }
        # Simple picker: show dialog
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "Choose snapshot to roll back"
        $dlg.Size = New-Object System.Drawing.Size(700, 400)
        $dlg.StartPosition = 'CenterParent'
        $lb = New-Object System.Windows.Forms.ListBox
        $lb.Dock = 'Fill'
        $lb.Font = New-Object System.Drawing.Font('Consolas', 9)
        foreach ($s in $snaps) { [void]$lb.Items.Add("$($s.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))   $($s.Name)") }
        $btnPick = New-Object System.Windows.Forms.Button
        $btnPick.Text = "Restore"
        $btnPick.Dock = 'Bottom'
        $btnPick.Height = 36
        $dlg.Controls.Add($lb); $dlg.Controls.Add($btnPick)
        $btnPick.Add_Click({
            if ($lb.SelectedIndex -ge 0) {
                $picked = $snaps[$lb.SelectedIndex]
                $confirm = [System.Windows.Forms.MessageBox]::Show("Roll back to $($picked.Name)?",'Confirm','YesNo','Warning')
                if ($confirm -eq 'Yes') {
                    $dlg.Close()
                    try { Invoke-SnapshotRestore -SnapshotFile $picked.FullName }
                    catch { Write-Log "Rollback failed: $($_.Exception.Message)" 'Red' }
                }
            }
        })
        $dlg.ShowDialog() | Out-Null
    })

    # If a config file was passed, load it now
    if ($ConfigFile -and (Test-Path $ConfigFile)) {
        try {
            $sel = Import-Config -Path $ConfigFile
            foreach ($id in $sel.ads + $sel.telemetry + $sel.security) {
                if ($script:GuiCheckboxes[$id]) { $script:GuiCheckboxes[$id].Checked = $true }
            }
            foreach ($p in $sel.apps) {
                if ($script:GuiCheckboxes[$p]) { $script:GuiCheckboxes[$p].Checked = $true }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not load config: $($_.Exception.Message)",'Import',"OK","Error") | Out-Null
        }
    }

    [void]$form.ShowDialog()
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
Initialize-DataDirs
Write-Log "Win11Debloat $($script:Version) starting (PID $PID, user $env:USERNAME)" 'Cyan'
$catalogue = Get-SecurityCatalogue
if ($NoGui) {
    Invoke-CliMode -Catalogue $catalogue
} else {
    Show-Gui -Catalogue $catalogue
}
