#Requires -Version 5.1
<#
.SYNOPSIS
    Installe le Meshstick sous Windows 10 (version 2004 ou plus recente) et Windows 11.
    Meme script : WSL 2 Ubuntu, usbipd, meshtasticd, raccourci bureau.

.DESCRIPTION
    A la fin, un raccourci "Meshstick USB" est pose sur le bureau. Il installe
    meshtasticd s'il manque, regle la radio, demarre le noeud et ouvre Chrome.
#>
[CmdletBinding()]
param(
    [string]$Distribution = "Ubuntu",
    [string]$OwnerName = "Meshstick",
    [switch]$ShortcutOnly
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-MeshstickIcon {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing
    $size = 256
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $shape = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = 16; $y = 16; $w = 224; $h = 224; $r = 48; $d = $r * 2
    $shape.AddArc($x, $y, $d, $d, 180, 90)
    $shape.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
    $shape.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
    $shape.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
    $shape.CloseFigure()
    $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 14, 74, 52))
    $g.FillPath($bg, $shape)

    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 125, 255, 179), 10)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, 128, 176, 128, 78)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $pen.Color), 116, 62, 24, 24)
    $arc = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 232, 255, 243), 8)
    $arc.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arc.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawArc($arc, 96, 88, 64, 64, 200, 140)
    $g.DrawArc($arc, 78, 70, 100, 100, 200, 140)
    $g.DrawArc($arc, 60, 52, 136, 136, 200, 140)
    $plug = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 232, 255, 243))
    $g.FillRectangle($plug, 104, 176, 48, 28)
    $g.FillRectangle($plug, 112, 204, 10, 16)
    $g.FillRectangle($plug, 134, 204, 10, 16)

    $pngStream = New-Object System.IO.MemoryStream
    $bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $pngStream.ToArray()
    $g.Dispose()
    $bmp.Dispose()
    $pngStream.Dispose()

    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter $fs
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]1)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$png.Length)
    $bw.Write([uint32]22)
    $bw.Write($png)
    $bw.Flush()
    $bw.Dispose()
    $fs.Dispose()
}

function New-MeshstickShortcut {
    $icon = Join-Path $PSScriptRoot "meshstick.ico"
    Save-MeshstickIcon -Path $icon
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not (Test-Path $desktop)) {
        throw "Dossier Bureau introuvable."
    }
    $lnkPath = Join-Path $desktop "Meshstick USB.lnk"
    $launch = Join-Path $PSScriptRoot "launch-meshstick.ps1"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnkPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launch`""
    $shortcut.WorkingDirectory = (Split-Path $PSScriptRoot -Parent)
    $shortcut.WindowStyle = 7
    $shortcut.Description = "Prepare le Meshstick et ouvre l'interface dans Chrome"
    $shortcut.IconLocation = "$icon,0"
    $shortcut.Save()

    $bytes = [System.IO.File]::ReadAllBytes($lnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [System.IO.File]::WriteAllBytes($lnkPath, $bytes)
    Write-Host "Raccourci bureau : $lnkPath"
}

if ($ShortcutOnly) {
    New-MeshstickShortcut
    exit 0
}

if (-not (Test-IsAdmin)) {
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Distribution `"$Distribution`" -OwnerName `"$OwnerName`""
    $elevated = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList $arg
    exit $elevated.ExitCode
}

function Start-MeshstickUbuntu {
    Start-Process -FilePath "wsl.exe" -ArgumentList @("-d", $Distribution, "-u", "root", "--", "sleep", "infinity") -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 1
        $script:wslList = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ""
    } while ((Get-Date) -lt $deadline -and $script:wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+Running\b")
    return [bool]($script:wslList -match "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+Running\b")
}

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -lt 19041) {
    throw "Windows 10 version 2004 (build 19041) ou Windows 11 est requis. Build detecte : $build."
}
Write-Host "Installation Meshstick USB pour Windows (build $build)"

$wslJustInstalled = $false
$wslList = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ""
if ($wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+") {
    Write-Host "Installation de la distribution $Distribution..."
    & wsl.exe --install -d $Distribution --no-launch
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --install -d $Distribution a echoue. Redemarrez Windows, puis relancez ce script."
    }
    $wslJustInstalled = $true
}
& wsl.exe --set-default-version 2 | Out-Null

$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = "$machinePath;$userPath"
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Write-Host "Installation de usbipd-win..."
    & winget install --id dorssel.usbipd-win --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget install usbipd a echoue."
    }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    $usbipdExe = "C:\Program Files\usbipd-win\usbipd.exe"
    if (Test-Path $usbipdExe) {
        $env:Path = "C:\Program Files\usbipd-win;" + $env:Path
    } else {
        throw "usbipd est introuvable apres installation."
    }
}

Write-Host "Demarrage de $Distribution..."
if (-not (Start-MeshstickUbuntu)) {
    if ($wslJustInstalled) {
        throw "Ubuntu vient d'etre installe. Redemarrez Windows, puis relancez ce script."
    }
    throw "Impossible de demarrer $Distribution."
}

$systemdState = (& wsl.exe -d $Distribution -u root -- bash -c "if grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null; then echo PRESENT; else printf '\n[boot]\nsystemd=true\n' >> /etc/wsl.conf; echo ADDED; fi" | Out-String) -replace "`0", ""
if ($systemdState -match "ADDED") {
    Write-Host "Activation de systemd dans WSL, puis redemarrage d'Ubuntu..."
    & wsl.exe --shutdown
    Start-Sleep -Seconds 3
    if (-not (Start-MeshstickUbuntu)) {
        throw "Ubuntu n'a pas redemarre apres l'activation de systemd."
    }
}

Write-Host "Attache du stick s'il est branche..."
& (Join-Path $PSScriptRoot "autostart-meshstick.ps1") -Distribution $Distribution -SkipService
if ($LASTEXITCODE -ne 0) {
    throw "Impossible de preparer Ubuntu ou d'attacher le stick. Journal : $env:ProgramData\Meshstick\autostart.log"
}

$linuxScriptWin = Join-Path $PSScriptRoot "install-linux.sh"
$drive = $linuxScriptWin.Substring(0, 1).ToLower()
$wslPath = "/mnt/$drive" + ($linuxScriptWin.Substring(2) -replace '\\', '/')
$quotedScript = $wslPath.Replace("'", "'\''")
$quotedOwner = $OwnerName.Replace("'", "'\''")
Write-Host "Installation de meshtasticd dans $Distribution..."
& wsl.exe -d $Distribution -u root -- bash -c "export MESHSTICK_OWNER='$quotedOwner'; exec bash '$quotedScript'"
if ($LASTEXITCODE -ne 0) {
    throw "Le script Linux a echoue."
}

Write-Host "Pare-feu et demarrage automatique..."
foreach ($rule in @(
        @{ Name = "Meshstick Meshtastic API"; Port = 4403 },
        @{ Name = "Meshstick Meshtastic Web"; Port = 9443 }
    )) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rule.Port -Profile Any | Out-Null
    }
}

$taskName = "Meshstick USB"
$autoScript = Join-Path $PSScriptRoot "autostart-meshstick.ps1"
$taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$autoScript`""
$taskUser = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
$taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
$taskTrigger.Delay = "PT20S"
$taskRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 9999)
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Highest
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger @($taskTrigger, $taskRepeat) -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
Write-Host "Tache planifiee : $taskName (ouverture de session)"

& $autoScript -Distribution $Distribution
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Le noeud n'est pas encore en ligne. Branchez le stick : la tache planifiee reprendra."
}

New-MeshstickShortcut

. (Join-Path $PSScriptRoot "open-meshstick-browser.ps1")
if (-not (Resolve-MeshstickChrome)) {
    Write-Host "Installation de Google Chrome..."
    & winget install --id Google.Chrome --exact --accept-package-agreements --accept-source-agreements
    if (-not (Resolve-MeshstickChrome)) {
        Write-Warning "Google Chrome n'a pas ete installe. Le raccourci utilisera Edge s'il est present."
    }
}

$client = New-Object System.Net.Sockets.TcpClient
$webReady = $false
try {
    $client.Connect("127.0.0.1", 9443)
    $webReady = $client.Connected
} catch {
    $webReady = $false
} finally {
    $client.Dispose()
}

if ($webReady) {
    try {
        . (Join-Path $PSScriptRoot "open-meshstick-browser.ps1")
        Open-MeshstickBrowser -Url "https://127.0.0.1:9443/"
    } catch {
        Write-Warning $_.Exception.Message
    }
} else {
    Write-Warning "L'interface web ne repond pas encore. Elle s'ouvrira au prochain branchement via le raccourci Meshstick USB."
}

Write-Host "Installation terminee. Raccourci bureau : Meshstick USB"
