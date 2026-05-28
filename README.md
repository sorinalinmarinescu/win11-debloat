# Win11 Debloat & Hardening

A PowerShell tool with a Windows Forms GUI that disables Windows 11 ads and
telemetry, removes pre-installed bloat, and applies Bitdefender-derived
security hardening — with snapshot/restore, System Restore Point creation,
and config export/import for admin → end-user distribution.

## Quick start (one-liner)

Open **any PowerShell window** and paste:

```powershell
irm https://raw.githubusercontent.com/sorinalinmarinescu/win11-debloat/main/bootstrap.ps1 | iex
```

The bootstrap downloads `Win11Debloat.ps1` + `security_catalogue.json` to
`%TEMP%\Win11Debloat\`, then re-launches elevated (UAC prompt). The GUI opens
with everything **unchecked** by default — you choose what to apply.

## Workflows

### Individual user

1. Open the GUI. Browse the tabs (Ads, Telemetry, Bloat Apps, plus a Security
   tab per category).
2. *(Optional)* click **Export config** to capture your starting state.
3. Tick the actions you want.
4. *(Optional)* tick **Dry run** to preview without changes.
5. Click **Apply**. A System Restore Point + a per-action snapshot are
   created automatically.
6. If something breaks: **Rollback snapshot** to revert, or **Import config**
   to load a previously-known-good selection and re-apply.

### Admin → end-user distribution

1. Admin runs the script on a test machine, configures the toggles, tests.
2. Admin clicks **Export config** to write a JSON file.
3. Admin distributes the JSON.
4. End user runs `Win11Debloat.ps1 -ConfigFile <path-to-config.json>` (with
   `-NoGui` for unattended apply, or without it to review in GUI first).

## What's included

| Category | Count | Source |
|---|---|---|
| Ads & Promotions | 9 | Built-in (lock screen tips, Start menu, Edge promos, etc.) |
| Telemetry | 7 | Built-in (DiagTrack disable, AllowTelemetry=0, CEIP tasks, WER, activity history, etc.) |
| Bloat apps | 47 | Built-in (Tier 1 promo apps + Tier 2 real apps) |
| Real Win Security | 7 | From Bitdefender catalogue (Follina, Tarrask, Exploit Protection, etc.) |
| Network/SMB | 8 | SMB signing, anonymous SAM, IP source routing, etc. |
| Credentials | 3 | Domain creds, LAPS, BitLocker on removable |
| WinRM | 3 | Service disable, Digest auth, RunAs |
| Optional services | 3 | Smart Card, Telephony, Microphone |
| Browser cert/zones | 10 | Cert errors, EPM, RSS, Intranet UNCs |
| IE/IE-Mode per-zone | 39 | Java, ActiveX, scripting, clipboard, drag-drop, XAML, .NET |

Total: **136 individually-toggleable actions.** All registry/service/task
changes are snapshotted before being applied.

Each security finding shows:
- **Severity** (Critical / High / Medium / Low — our rubric, not Bitdefender's)
- **Compatibility** (Safe / Caution / Breaking)
- **Compatibility note** describing exactly what may break
- Cross-references to Microsoft Learn, CIS Benchmark, DISA STIG

Hover any item in the GUI for the full description and references.

## CLI mode

```powershell
# Just open the GUI (default)
.\Win11Debloat.ps1

# Apply a config file unattended
.\Win11Debloat.ps1 -NoGui -ConfigFile good-baseline.json

# Apply a config file but preview only
.\Win11Debloat.ps1 -NoGui -ConfigFile good-baseline.json -DryRun

# Review a config file in GUI before applying
.\Win11Debloat.ps1 -ConfigFile good-baseline.json
```

## Snapshot & rollback

Every Apply creates two artifacts in `%LOCALAPPDATA%\Win11Debloat\`:
- A System Restore Point (machine-wide, recovers via Windows System Restore)
- A JSON snapshot in `snapshots\snapshot-<timestamp>.json` recording the old
  registry value / service state / AppX install state for every change

The GUI's **Rollback snapshot** button reads any snapshot back and reverses
the changes. AppX uninstalls cannot be auto-restored (Microsoft Store is the
only path); the snapshot lists them so you know what to reinstall.

## Files in this repo

| File | Purpose |
|---|---|
| `Win11Debloat.ps1` | The main script (loads catalogue, builds GUI, applies actions) |
| `security_catalogue.json` | 73 Bitdefender-derived Windows security findings |
| `bootstrap.ps1` | One-liner downloader + UAC re-launcher |
| `LICENSE` | AGPL-3.0 |

## What the script does NOT touch

- Spotlight wallpapers (rotating lock screen pictures still work)
- Widgets button (only the news/promo content)
- Cortana / Search functionality
- System-critical AppX (Store, Terminal, Calculator, Photos, Paint, Snipping
  Tool, Camera, Sticky Notes, Defender UI, .NET / VCLibs / UI XAML runtimes)
- `Audiosrv` (the Windows Audio service — the "Microphone" finding uses the
  privacy consent broker instead)
- `XboxIdentityProvider` (kept even on aggressive Tier 2 — some games need it)

## Severity & compatibility breakdown of security catalogue

| Severity | Count | | Compatibility | Count |
|---|---|---|---|---|
| Critical | 2 | | Safe | 31 |
| High | 17 | | Caution | 39 |
| Medium | 13 | | Breaking | 3 |
| Low | 41 | | | |

Critical = real-world exploited (Follina CVE-2022-30190, Tarrask APT
persistence). Breaking = will reliably disrupt a common feature
(Smart Card → YubiKey/CAC; Microphone deny → all voice apps; BitLocker
deny-write removable → USB sticks become read-only).

## Requirements

- Windows 11 Pro / Enterprise (Home will mostly work but some Group Policy
  hardening only fully applies on Pro+)
- PowerShell 5.1+ (built in to Windows 11)
- Administrator rights (bootstrap handles UAC)

## License

AGPL-3.0 — see [LICENSE](LICENSE).
