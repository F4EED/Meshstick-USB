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

if (-not (Test-IsAdmin)) {
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arg | Out-Null
    exit 0
}

$autostart = Join-Path $PSScriptRoot "autostart-meshstick.ps1"
try {
    & $autostart -Distribution $Distribution
    if ($LASTEXITCODE -ne 0) {
        throw "La preparation du Meshstick a echoue. Journal : $env:ProgramData\Meshstick\autostart.log"
    }

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

    . (Join-Path $PSScriptRoot "open-meshstick-browser.ps1")
    Open-MeshstickBrowser -Url "https://127.0.0.1:9443/"
} catch {
    Show-MeshstickError $_.Exception.Message
    exit 1
}
