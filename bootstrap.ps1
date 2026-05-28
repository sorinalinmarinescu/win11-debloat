<#
.SYNOPSIS
    Win11Debloat bootstrap. Downloads the script + security catalogue from the
    repository, then re-launches elevated.

.NOTES
    Run with the one-liner from the README, or directly with:
        irm https://raw.githubusercontent.com/sorinalinmarinescu/win11-debloat/main/bootstrap.ps1 | iex
#>

$ErrorActionPreference = 'Stop'
$base = 'https://raw.githubusercontent.com/sorinalinmarinescu/win11-debloat/main'
$tempDir = Join-Path $env:TEMP 'Win11Debloat'

if (-not (Test-Path $tempDir)) {
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
}

Write-Host "Downloading Win11Debloat to $tempDir ..." -ForegroundColor Cyan
foreach ($f in 'Win11Debloat.ps1','security_catalogue.json') {
    $url = "$base/$f"
    $out = Join-Path $tempDir $f
    Write-Host "  $f" -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host "FAILED to download $url : $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Detect if we're already elevated
function Test-IsElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]'Administrator')
}

$mainScript = Join-Path $tempDir 'Win11Debloat.ps1'

if (Test-IsElevated) {
    Write-Host "Already elevated. Launching GUI..." -ForegroundColor Cyan
    & $mainScript
} else {
    Write-Host "Re-launching elevated (UAC prompt incoming)..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList @(
        '-NoExit','-ExecutionPolicy','Bypass','-File',"`"$mainScript`""
    )
}
