#Requires -Version 5.1
<#
.SYNOPSIS
    Attache le Meshstick, relance meshtasticd et ouvre l'interface dans Google Chrome.
#>
[CmdletBinding()]
param(
    [string]$Distribution = "Ubuntu"
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-MeshstickError {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Message, "Meshstick USB") | Out-Null
}

function Test-MeshstickUsePrereqs {
    param([string]$DistributionName)

    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw "Windows 64 bits et PowerShell 64 bits sont requis pour utiliser meshtasticd."
    }
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    if ($build -lt 19041) {
        throw "Windows 10 version 2004 (build 19041) ou Windows 11 est requis. Build detecte : $build."
    }
    Write-Host "Prerequis OK : Windows build $build"

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe est introuvable. Lancez d'abord scripts\install-windows.ps1."
    }
    $wslList = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ""
    if ($wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($DistributionName))\s+") {
        throw "La distribution $DistributionName est absente. Lancez d'abord scripts\install-windows.ps1."
    }
    if ($wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($DistributionName))\s+\S+\s+2\b") {
        throw "$DistributionName doit etre en WSL 2. Commande : wsl --set-version $DistributionName 2"
    }
    Write-Host "Prerequis OK : $DistributionName en WSL 2"

    if (-not (Get-Command usbipd -ErrorAction SilentlyContinue) -and (Test-Path "C:\Program Files\usbipd-win\usbipd.exe")) {
        $env:Path = "C:\Program Files\usbipd-win;" + $env:Path
    }
    if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
        throw "usbipd est introuvable. Lancez d'abord scripts\install-windows.ps1."
    }
    $usbipdRaw = (& usbipd --version 2>&1 | Out-String)
    if ($usbipdRaw -notmatch "(\d+)\.(\d+)\.(\d+)") {
        throw "Version usbipd illisible. usbipd-win 4.0.0 ou plus recent est requis."
    }
    $usbipdVersion = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    if ($usbipdVersion -lt [version]::new(4, 0, 0)) {
        throw "usbipd-win $usbipdVersion est trop ancien. Version 4.0.0 ou plus recente requise."
    }
    Write-Host "Prerequis OK : usbipd-win $usbipdVersion"

    $listed = (& usbipd list 2>&1 | Out-String)
    if ($listed -notmatch "1a86:5512") {
        throw "Cle Meshstick absente (USB 1a86:5512). Vissez l'antenne SMA, branchez la cle sur un port USB, puis relancez."
    }
    Write-Host "Prerequis OK : cle 1a86:5512 vue par Windows"

    . (Join-Path $PSScriptRoot "open-meshstick-browser.ps1")
    if (-not (Resolve-MeshstickChrome) -and -not (Resolve-MeshstickEdge)) {
        throw "Chrome ou Edge est requis pour ouvrir l'interface Meshtastic. Relancez scripts\install-windows.ps1."
    }
    Write-Host "Prerequis OK : navigateur"
}

if (-not (Test-IsAdmin)) {
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arg | Out-Null
    exit 0
}

$autostart = Join-Path $PSScriptRoot "autostart-meshstick.ps1"
try {
    Test-MeshstickUsePrereqs -DistributionName $Distribution
    & $autostart -Distribution $Distribution
    if ($LASTEXITCODE -ne 0) {
        throw "La preparation du Meshstick a echoue. Journal : $env:ProgramData\Meshstick\autostart.log"
    }

    $kernelRaw = (& wsl.exe -d $Distribution -u root -- uname -r 2>&1 | Out-String) -replace "`0", ""
    if ($kernelRaw -notmatch "(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?") {
        throw "Impossible de lire le noyau WSL. Meshtastic exige un noyau superieur a 5.10.60.1."
    }
    $revision = 0
    if ($Matches[4]) { $revision = [int]$Matches[4] }
    $kernel = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $revision)
    if ($kernel -le [version]::new(5, 10, 60, 1)) {
        throw "Noyau WSL $kernel. Meshtastic exige un noyau superieur a 5.10.60.1. Commande : wsl --update"
    }
    Write-Host "Prerequis OK : noyau WSL $kernel"

    $ready = $false
    $deadline = (Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Seconds 1
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $client.Connect("127.0.0.1", 9443)
            $ready = $client.Connected
        } catch {
            $ready = $false
        } finally {
            $client.Dispose()
        }
    } while (-not $ready -and (Get-Date) -lt $deadline)

    if (-not $ready) {
        throw "meshtasticd n'ecoute pas sur le port 9443. Verifiez : wsl -d $Distribution -u root -- journalctl -u meshtasticd -n 40 --no-pager"
    }
    Write-Host "Prerequis OK : interface web https://127.0.0.1:9443"

    . (Join-Path $PSScriptRoot "open-meshstick-browser.ps1")
    Open-MeshstickBrowser -Url "https://127.0.0.1:9443/"
} catch {
    Show-MeshstickError $_.Exception.Message
    exit 1
}
