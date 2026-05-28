<#
.SYNOPSIS
    Win11Debloat secure bootstrap.

.DESCRIPTION
    Elevates FIRST (UAC) and only the elevated process downloads the payload.
    The payload is written to %ProgramData%\Win11Debloat\<guid>\ which is
    locked down so only Administrators + SYSTEM can modify it. This closes
    the TOCTOU window in which a low-priv attacker could tamper with a
    user-writable %TEMP% file between download and elevated execution.

.NOTES
    Run via the README one-liner:
        irm https://raw.githubusercontent.com/sorinalinmarinescu/win11-debloat/main/bootstrap.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Stage 1 (runs in user context): elevate, do nothing else.
# -----------------------------------------------------------------------------
function Test-IsElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]'Administrator')
}

if (-not (Test-IsElevated)) {
    Write-Host "Win11Debloat bootstrap: requesting elevation (UAC prompt)..." -ForegroundColor Yellow
    Write-Host "Nothing will be downloaded until the elevated process starts." -ForegroundColor DarkGray

    # Re-fetch and re-execute this same bootstrap inside an elevated PowerShell.
    # The elevated copy will skip this branch (it IS elevated) and run the
    # protected-download stage below. Two HTTPS fetches of bootstrap.ps1
    # over TLS to GitHub is acceptable; the *payload* is only ever fetched
    # by the elevated process into a non-user-writable directory.
    $bootstrapUrl = 'https://raw.githubusercontent.com/sorinalinmarinescu/win11-debloat/main/bootstrap.ps1'
    $elevatedCmd  = "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iex (Invoke-RestMethod '$bootstrapUrl' -UseBasicParsing)"
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($elevatedCmd)
    $b64   = [Convert]::ToBase64String($bytes)

    try {
        Start-Process powershell -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-EncodedCommand', $b64
        ) -ErrorAction Stop
    } catch {
        Write-Host "User cancelled UAC or elevation failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    return
}

# -----------------------------------------------------------------------------
# Stage 2 (runs ELEVATED): download into ACL-locked %ProgramData% subdir.
# -----------------------------------------------------------------------------
Write-Host "[+] Running elevated. Preparing protected workspace..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base     = 'https://raw.githubusercontent.com/sorinalinmarinescu/win11-debloat/main'
$workRoot = Join-Path $env:ProgramData 'Win11Debloat'
$run      = Join-Path $workRoot ([guid]::NewGuid().ToString())

# Create the per-run subdir. ProgramData itself is already non-user-writable.
New-Item -Path $run -ItemType Directory -Force | Out-Null

# Lock the per-run dir with explicit ACLs: Admins+SYSTEM full, Users read-only,
# inheritance disabled. Closes the TOCTOU window even for processes that
# already hold a token in the caller's session.
$acl = Get-Acl -Path $run
$acl.SetAccessRuleProtection($true, $false)  # disable + drop inherited rules
foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
$ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
    (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'),  # BUILTIN\Administrators
    'FullControl','ContainerInherit,ObjectInherit','None','Allow')
$ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
    (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'),       # NT AUTHORITY\SYSTEM
    'FullControl','ContainerInherit,ObjectInherit','None','Allow')
$ruleUsers  = New-Object System.Security.AccessControl.FileSystemAccessRule(
    (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'),   # BUILTIN\Users
    'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')
$acl.AddAccessRule($ruleAdmins)
$acl.AddAccessRule($ruleSystem)
$acl.AddAccessRule($ruleUsers)
Set-Acl -Path $run -AclObject $acl

Write-Host "[+] Workspace: $run" -ForegroundColor DarkGray

# Download payload into the locked dir
foreach ($f in 'Win11Debloat.ps1','security_catalogue.json') {
    $url = "$base/$f"
    $out = Join-Path $run $f
    try {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -ErrorAction Stop
        $hash = (Get-FileHash -Path $out -Algorithm SHA256).Hash
        Write-Host ("  {0,-26}  SHA256={1}" -f $f, $hash) -ForegroundColor DarkGray
    } catch {
        Write-Host "FAILED to download $url : $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Execute the payload from the locked location.
$mainScript = Join-Path $run 'Win11Debloat.ps1'
Write-Host "[+] Launching $mainScript`n" -ForegroundColor Cyan
& $mainScript
