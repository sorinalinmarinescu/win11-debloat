# Win11 Debloat

A small PowerShell tool that turns off Windows 11 Pro's ads, promos and "suggestions"
without breaking functionality. Optional GUI lets you pick which sections to apply
and which preinstalled bloat apps to uninstall.

## Quick start (one-liner)

Open **any PowerShell window** and paste this. It downloads the script to `%TEMP%`
and re-launches it elevated, then the GUI appears (UAC prompt is normal).

```powershell
$u='https://raw.githubusercontent.com/sorinalinmarinescu/win11-debloat/main/Win11Debloat.ps1'; $f="$env:TEMP\Win11Debloat.ps1"; iwr $u -OutFile $f -UseBasicParsing; Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File',"`"$f`""
```

In the GUI:
1. Leave all 9 ad-disabling sections checked (default).
2. Optionally tick apps under **Tier 1** (safe bloat) and/or **Tier 2** (real apps).
3. Tick **Dry run** to preview, or click **Apply** to do it for real.
4. Sign out / reboot afterwards.

## Manual install

```powershell
# 1. Open Terminal (Admin)
# 2. Download
iwr https://raw.githubusercontent.com/sorinalinmarinescu/win11-debloat/main/Win11Debloat.ps1 -OutFile "$HOME\Desktop\Win11Debloat.ps1"
# 3. Run
Set-ExecutionPolicy -Scope Process Bypass -Force
& "$HOME\Desktop\Win11Debloat.ps1"
```

## Command-line mode

```powershell
.\Win11Debloat.ps1 -NoGui                              # ads only, defaults
.\Win11Debloat.ps1 -NoGui -RemoveBloat                 # ads + Tier 1 cleanup
.\Win11Debloat.ps1 -NoGui -RemoveBloat -Aggressive     # ads + Tier 1 + Tier 2
.\Win11Debloat.ps1 -NoGui -RemoveBloat -DryRun         # preview, no changes
```

## What it disables

| # | Section | What it does |
|---|---|---|
| 1 | Lock screen tips | Kills "fun facts" overlay and the MSN/weather redirect that opens Edge |
| 2 | Start menu ads | Removes "Recommended", suggested apps, silently-installed promo apps |
| 3 | System tips | "Get the most out of Windows", post-update welcome, suggestion notifications |
| 4 | Settings app | Suggested-content cards inside Settings |
| 5 | Advertising ID | Disables ad ID, tailored experiences, language tracking, writing-data telemetry |
| 6 | File Explorer | OneDrive / sync provider promo notifications |
| 7 | Search & widgets | Bing/news highlights in search box; widgets news feed (panel still works) |
| 8 | Consumer Experiences | Group Policy that prevents Spotify/Disney/TikTok auto-installs |
| 9 | Edge | New tab MSN feed, first-run nag, Rewards prompts, shopping assistant |

## Bloat lists

### Tier 1 - third-party promos & obvious MS bloat

Adobe Photoshop Express, Bubble Witch 3, Candy Crush, Disney+, Dolby Access,
Duolingo, Eclipse Manager, Facebook, Flipboard, Hidden City, king.com games,
LinkedIn, March of Empires, Netflix, Pandora, PicsArt, Spotify, TikTok,
Twitter/X, Wunderlist, Microsoft Advertising SDK, MSN News, Bing Search,
Get Help, Tips, Office Hub launcher, Solitaire, Mixed Reality Portal, Mobile
Plans, People (legacy), Print 3D, consumer Skype, Wallet, Feedback Hub, Clipchamp.

### Tier 2 - real apps (only if you don't use them)

Mail + Calendar, Phone Link, Maps, Media Player / Groove, Movies & TV, Sound
Recorder, Alarms & Clock, Xbox app, Xbox overlays.

> `Microsoft.XboxIdentityProvider` is intentionally **kept** even on Tier 2 -
> some Win32 / Game Pass titles need it for sign-in.

## What it does NOT touch

- Spotlight wallpapers (rotating lock-screen pictures still work)
- Widgets button itself (only the news/promo content)
- Telemetry / diagnostics levels
- Cortana / Search functionality
- System-critical AppX: Microsoft Store, App Installer (winget), Terminal,
  Photos, Paint, Calculator, Notepad, Snipping Tool, Camera, Sticky Notes,
  Defender UI, .NET / VCLibs / UI XAML runtimes

## Reversibility

**Registry side.** Every change is a single registry value. Either re-enable
specific items in **Settings**, or delete the keys this script created:

```
HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent
HKLM:\SOFTWARE\Policies\Microsoft\Edge
HKLM:\SOFTWARE\Policies\Microsoft\Dsh
HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager
HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo
HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy
```

Then run `gpupdate /force`.

**Bloat side.** Any uninstalled AppX can be reinstalled individually from the
Microsoft Store. To restore the full default Windows set:

```powershell
Get-AppxPackage -AllUsers | Foreach { Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml" }
```

## Requirements

- Windows 11 Pro / Enterprise (Home will mostly work, but the Group Policy
  bits in section 8 only fully apply on Pro+)
- PowerShell 5.1+ (built in to Windows 11)
- Administrator rights

## Disclaimer

Use at your own risk. The script is intentionally conservative and reversible,
but every system is different. Run with `Dry run` first if you're unsure.

## License

AGPL-3.0 - see [LICENSE](LICENSE).
