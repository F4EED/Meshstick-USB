#Requires -Version 5.1
<#
.SYNOPSIS
    Demarre Ubuntu, attache le Meshstick et relance meshtasticd. Sans fenetre.

.DESCRIPTION
    Appele a l'ouverture de session et par le raccourci. Si le stick est absent,
    le script se termine sans erreur pour ne pas bloquer la session.
#>
[CmdletBinding()]
param(
    [string]$Distribution = "Ubuntu",
    [string]$VidPid = "1a86:5512",
    [switch]$SkipService
)

$ErrorActionPreference = "Continue"
$env:WSL_UTF8 = "1"
$logDir = Join-Path $env:ProgramData "Meshstick"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "autostart.log"

function Write-MeshstickLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Update-MeshstickPortProxy {
    $ipRaw = (& wsl.exe -d $Distribution -u root -- hostname -I | Out-String) -replace "`0", ""
    $ip = ($ipRaw.Trim() -split "\s+") | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    if (-not $ip) {
        return
    }
    foreach ($port in 4403, 9443) {
        & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port | Out-Null
        & netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$port connectaddress=$ip connectport=$port | Out-Null
        Write-MeshstickLog "portproxy $port -> ${ip}:$port"
    }
}

function Invoke-MeshstickEnsure {
    $linux = Join-Path $PSScriptRoot "meshstick-ensure.sh"
    $drive = $linux.Substring(0, 1).ToLower()
    $wslPath = "/mnt/$drive" + ($linux.Substring(2) -replace '\\', '/')
    $quoted = $wslPath.Replace("'", "'\''")
    Write-MeshstickLog "meshtasticd, reglage radio, demarrage du noeud"
    $output = & wsl.exe -d $Distribution -u root -- bash -c "exec bash '$quoted'" 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($output)) {
        $text = "$line".Trim()
        if ($text) {
            Write-MeshstickLog $text
        }
    }
    if ($code -ne 0) {
        Write-MeshstickLog "Echec de la preparation du noeud (code $code)."
        return $false
    }
    return $true
}

function Complete-Meshstick {
    param([int]$Code)
    $global:LASTEXITCODE = $Code
    $callers = @(Get-PSCallStack | Where-Object { $_.ScriptName -and $_.ScriptName -ne $PSCommandPath })
    if ($callers.Count -eq 0) {
        exit $Code
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-MeshstickLog "Droits administrateur requis."
    Complete-Meshstick 1
    return
}

$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue) -and (Test-Path "C:\Program Files\usbipd-win\usbipd.exe")) {
    $env:Path = "C:\Program Files\usbipd-win;" + $env:Path
}
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Write-MeshstickLog "usbipd introuvable."
    Complete-Meshstick 10
    return
}

$usbipdService = Get-Service -Name "usbipd" -ErrorAction SilentlyContinue
if ($usbipdService -and $usbipdService.Status -ne "Running") {
    Write-MeshstickLog "Demarrage du service usbipd."
    Start-Service usbipd
    Start-Sleep -Seconds 2
}

Write-MeshstickLog "Demarrage de $Distribution"
Start-Process -FilePath "wsl.exe" -ArgumentList @("-d", $Distribution, "-u", "root", "--", "sleep", "infinity") -WindowStyle Hidden | Out-Null
$deadline = (Get-Date).AddSeconds(45)
$running = $false
do {
    Start-Sleep -Seconds 1
    $wslList = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ""
    $running = $wslList -match "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+Running\b"
} while (-not $running -and (Get-Date) -lt $deadline)
if (-not $running) {
    Write-MeshstickLog "$Distribution n'a pas demarre."
    Complete-Meshstick 10
    return
}

if (-not $SkipService) {
    $inside = (& wsl.exe -d $Distribution -u root -- lsusb 2>&1 | Out-String)
    $svc = (& wsl.exe -d $Distribution -u root -- systemctl is-active meshtasticd 2>&1 | Out-String).Trim()
    if ($inside -match "1a86:5512" -and $svc -eq "active") {
        Write-MeshstickLog "Service deja actif."
        if (-not (Invoke-MeshstickEnsure)) {
            Complete-Meshstick 1
            return
        }
        Update-MeshstickPortProxy
        Complete-Meshstick 0
        return
    }
}

$policy = (& usbipd policy list 2>&1 | Out-String)
if ($policy -notmatch [regex]::Escape($VidPid)) {
    & usbipd policy add --effect Allow --operation AutoBind --hardware-id $VidPid 2>&1 | ForEach-Object { Write-MeshstickLog $_ }
}

$listed = (& usbipd list 2>&1 | Out-String)
if ($listed -notmatch [regex]::Escape($VidPid)) {
    Write-MeshstickLog "Stick $VidPid absent. Branchez-le : l'attache reprendra toute seule."
    Complete-Meshstick 0
    return
}

& usbipd bind --hardware-id $VidPid 2>&1 | ForEach-Object { Write-MeshstickLog $_ }
# Pas de --auto-attach : cette option bloque le processus dans une boucle.
$attached = $false
foreach ($try in 1..3) {
    & usbipd attach --wsl $Distribution --hardware-id $VidPid 2>&1 | ForEach-Object { Write-MeshstickLog $_ }
    Start-Sleep -Seconds 2
    $usbipdList = (& usbipd list 2>&1 | Out-String)
    $attached = $usbipdList -match ("(?m)" + [regex]::Escape($VidPid) + ".*\bAttached\b")
    $seen = (& wsl.exe -d $Distribution -u root -- bash -c "command -v lsusb >/dev/null 2>&1 && lsusb || echo NO_LSUSB" 2>&1 | Out-String)
    Write-MeshstickLog $seen.Trim()
    if ($seen -match "1a86:5512") {
        $attached = $true
        break
    }
    # Ubuntu tout neuf n'a pas encore lsusb. usbipd suffit pour continuer l'installation.
    if ($attached -and $seen -match "NO_LSUSB") {
        break
    }
    $attached = $false
}
if (-not $attached) {
    Write-MeshstickLog "Le stick n'apparait pas dans Ubuntu."
    if ($SkipService) {
        Complete-Meshstick 20
        return
    }
    Complete-Meshstick 1
    return
}

if ($SkipService) {
    Write-MeshstickLog "Service non relance (installation en cours)."
    Complete-Meshstick 0
    return
}

if (-not (Invoke-MeshstickEnsure)) {
    Complete-Meshstick 1
    return
}

Update-MeshstickPortProxy

Write-MeshstickLog "Meshstick pret."
Complete-Meshstick 0
return
