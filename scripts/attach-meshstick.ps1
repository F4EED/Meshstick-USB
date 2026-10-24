#Requires -Version 5.1
<#
.SYNOPSIS
    Lie le Meshstick USB (1a86:5512) et l'attache a la distribution Ubuntu WSL 2.

.DESCRIPTION
    Le bind survit a un redemarrage. L'attache non : relancer ce script apres
    chaque reboot, debranchement ou sortie de veille. A executer dans un
    PowerShell eleve.

.PARAMETER Distribution
    Distribution WSL cible. Ubuntu par defaut, pas docker-desktop.

.PARAMETER VidPid
    Identifiant USB du CH341 en mode SPI. Meshstick Elecrow : 1a86:5512.
#>
[CmdletBinding()]
param(
    [string]$Distribution = "Ubuntu",
    [string]$VidPid = "1a86:5512"
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Error "PowerShell doit etre eleve (Executer en tant qu'administrateur) pour usbipd bind et attach."
}

if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Write-Error "usbipd est introuvable. Installez-le : winget install --id dorssel.usbipd-win"
}

$wslList = & wsl.exe -l -v 2>&1 | Out-String
$wslList = $wslList -replace "`0", ""
if ($wslList -notmatch [regex]::Escape($Distribution)) {
    Write-Error "La distribution WSL '$Distribution' est absente. Installez-la : wsl --install -d $Distribution"
}

$raw = & usbipd list 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Error "usbipd list a echoue : $raw"
}

$busId = $null
$state = $null
$vidPidPattern = [regex]::Escape($VidPid)
foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match "^\s*(\d+-\d+(?:\.\d+)*)\s+$vidPidPattern\s+(.*)$") {
        $busId = $Matches[1]
        $tail = $Matches[2].Trim()
        if ($tail -match "\s{2,}(\S.*)$") {
            $state = $Matches[1].Trim()
        } else {
            $state = "Unknown"
        }
        break
    }
}

if (-not $busId) {
    Write-Host $raw
    Write-Error "Aucun peripherique $VidPid. Vissez l'antenne, branchez le Meshstick, puis relancez ce script."
}

Write-Host "Meshstick trouve : BUSID $busId ($VidPid), etat : $state"

# usbipd 5.x refuse l'attache si la distribution est arretee.
# docker-desktop peut etre la distribution par defaut : on demarre Ubuntu explicitement.
if ($wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+Running\b") {
    Write-Host "Demarrage de $Distribution..."
    Start-Process -FilePath "wsl.exe" -ArgumentList @("-d", $Distribution, "-u", "root", "--", "sleep", "infinity") -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(40)
    do {
        Start-Sleep -Seconds 1
        $wslList = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ""
    } while ((Get-Date) -lt $deadline -and $wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+Running\b")
    if ($wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+Running\b") {
        Write-Error "Impossible de demarrer $Distribution. Lancez 'wsl -d $Distribution' puis relancez ce script."
    }
}

if ($state -notmatch "^(Shared|Attached)") {
    Write-Host "Bind de $busId..."
    & usbipd bind --busid $busId
    if ($LASTEXITCODE -ne 0) {
        Write-Error "usbipd bind a echoue pour $busId."
    }
}

Write-Host "Attache de $busId a WSL ($Distribution)..."
# usbipd 5 : --auto-attach ne revient jamais (boucle infinie). L'attache reste un appel court.
# Le retour apres reboot ou debranchement est fait par la tache planifiee.
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& usbipd attach --wsl $Distribution --busid $busId 2>&1 | ForEach-Object { Write-Host $_ }
$attachExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($attachExit -ne 0 -and $state -ne "Attached") {
    Write-Error "usbipd attach a echoue (code $attachExit). $Distribution doit etre en WSL 2 et en cours d'execution."
}

Write-Host "Controle lsusb dans $Distribution..."
& wsl.exe -d $Distribution -- lsusb
if ($LASTEXITCODE -ne 0) {
    Write-Warning "lsusb indisponible ou en echec. Apres installation des paquets : sudo apt install usbutils && lsusb"
}

Write-Host "Termine. Dans Ubuntu : sudo meshtasticd"
