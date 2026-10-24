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
    [string]$DesktopPath = "",
    [string]$TaskUser = "",
    [switch]$ShortcutOnly
)

$ErrorActionPreference = "Stop"
$env:WSL_UTF8 = "1"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-MeshstickDialog {
    param([string]$Message, [string]$Title = "Meshstick USB")
    Write-Host $Message
    try {
        $dir = Join-Path $env:ProgramData "Meshstick"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-Content -Path (Join-Path $dir "install.log") -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
    } catch {
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, $Title) | Out-Null
    } catch {
        Read-Host "Appuyez sur Entree pour fermer"
    }
}

trap {
    Show-MeshstickDialog $_.Exception.Message
    exit 1
}

function Test-MeshstickNetwork {
    foreach ($hostName in @("github.com", "archive.ubuntu.com", "ppa.launchpadcontent.net")) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($hostName, 443, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(8000, $false)
            if ($ok -and $client.Connected) {
                $client.EndConnect($iar)
                $client.Close()
                return $true
            }
        } catch {
        } finally {
            if ($client) { $client.Close() }
        }
    }
    return $false
}

function Test-MeshstickInstallPrereqs {
    param([string]$DistributionName)

    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "Windows 64 bits est requis pour meshtasticd via WSL 2."
    }
    if (-not [Environment]::Is64BitProcess) {
        throw "Ce PowerShell est en 32 bits. Ouvrez Windows PowerShell (x64)."
    }
    Write-Host "Prerequis OK : Windows 64 bits, PowerShell 64 bits"

    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -lt 19041) {
        throw "Windows 10 version 2004 (build 19041) ou Windows 11 est requis. Build detecte : $build."
    }
    Write-Host "Prerequis OK : Windows build $build"

    $computer = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($computer.HypervisorPresent) {
        Write-Host "Prerequis OK : virtualisation (hyperviseur present, WSL 2)"
    } elseif ($cpu.VirtualizationFirmwareEnabled -eq $false -or $cpu.SecondLevelAddressTranslationExtensions -eq $false) {
        throw "La virtualisation est desactivee dans le firmware. WSL 2, requis par meshtasticd sous Windows, a besoin de VT-x ou AMD-V dans le BIOS ou l'UEFI."
    } else {
        Write-Host "Prerequis OK : virtualisation firmware"
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe est introuvable. Windows 10 version 2004 ou Windows 11 avec le composant Sous-systeme Windows pour Linux est requis."
    }
    Write-Host "Prerequis OK : wsl.exe"

    $wslList = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ""
    $distroInstalled = $wslList -match "(?m)^\s*\*?\s*$([regex]::Escape($DistributionName))\s+"
    $usbipdReady = [bool](Get-Command usbipd -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\usbipd-win\usbipd.exe")
    if (-not $distroInstalled) {
        $driveName = $env:SystemDrive.TrimEnd(":")
        $free = (Get-PSDrive -Name $driveName).Free
        if ($free -lt 4GB) {
            throw "Il faut au moins 4 Go libres sur $($env:SystemDrive) pour installer Ubuntu et meshtasticd."
        }
        Write-Host "Prerequis OK : $([math]::Round($free / 1GB, 1)) Go libres sur $($env:SystemDrive)"
    }
    if ((-not $distroInstalled -or -not $usbipdReady) -and -not (Test-MeshstickNetwork)) {
        throw "Acces reseau requis vers GitHub, archive.ubuntu.com ou le PPA Meshtastic pour installer WSL, usbipd et meshtasticd."
    }
    if (-not $distroInstalled -or -not $usbipdReady) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw "winget est requis pour installer usbipd-win (et Google Chrome s'il manque). Installez App Installer depuis le Microsoft Store."
        }
        Write-Host "Prerequis OK : winget et reseau"
    }
}

function Test-MeshstickWslPrereqs {
    param([string]$DistributionName)

    $wslList = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ""
    if ($wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($DistributionName))\s+\S+\s+2\b") {
        throw "$DistributionName doit etre en WSL 2. Commande : wsl --set-version $DistributionName 2"
    }
    Write-Host "Prerequis OK : $DistributionName en WSL 2"

    $raw = (& wsl.exe -d $DistributionName -u root -- uname -r 2>&1 | Out-String) -replace "`0", ""
    if ($raw -notmatch "(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?") {
        throw "Impossible de lire le noyau WSL (uname -r). Meshtastic exige un noyau superieur a 5.10.60.1."
    }
    $revision = 0
    if ($Matches[4]) { $revision = [int]$Matches[4] }
    $kernel = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $revision)
    $minimum = [version]::new(5, 10, 60, 1)
    if ($kernel -le $minimum) {
        throw "Noyau WSL $kernel. Meshtastic exige un noyau superieur a 5.10.60.1. Dans un PowerShell administrateur : wsl --update"
    }
    Write-Host "Prerequis OK : noyau WSL $kernel"

    $usbipdRaw = (& usbipd --version 2>&1 | Out-String)
    if ($usbipdRaw -notmatch "(\d+)\.(\d+)\.(\d+)") {
        throw "Version usbipd illisible. usbipd-win 4.0.0 ou plus recent est requis."
    }
    $usbipdVersion = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    if ($usbipdVersion -lt [version]::new(4, 0, 0)) {
        throw "usbipd-win $usbipdVersion est trop ancien. La documentation Meshtastic demande la version 4.0.0 ou plus recente."
    }
    Write-Host "Prerequis OK : usbipd-win $usbipdVersion"
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
    param([string]$Desktop)
    $icon = Join-Path $PSScriptRoot "meshstick.ico"
    Save-MeshstickIcon -Path $icon
    if (-not $Desktop) {
        $Desktop = [Environment]::GetFolderPath("Desktop")
    }
    if (-not (Test-Path -LiteralPath $Desktop)) {
        New-Item -ItemType Directory -Force -Path $Desktop | Out-Null
    }
    $desktop = $Desktop
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
    return $lnkPath
}

function Install-MeshstickLayout {
    $installRoot = "C:\Apps\Meshstick"
    $sourceRoot = [System.IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
    $destRoot = [System.IO.Path]::GetFullPath($installRoot).TrimEnd('\')
    if ($sourceRoot.Equals($destRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $installRoot "scripts") | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot "*") -Destination (Join-Path $installRoot "scripts") -Recurse -Force
    foreach ($name in @("README.md", "LICENSE", ".gitattributes")) {
        $src = Join-Path $sourceRoot $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $installRoot $name) -Force
        }
    }
    $images = Join-Path $sourceRoot "images"
    if (Test-Path -LiteralPath $images) {
        $destImages = Join-Path $installRoot "images"
        New-Item -ItemType Directory -Force -Path $destImages | Out-Null
        Copy-Item -Path (Join-Path $images "*") -Destination $destImages -Recurse -Force
    }
    Write-Host "Fichiers installes dans $installRoot"
    return $true
}

if (-not $DesktopPath) {
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
}
if (-not $TaskUser) {
    $TaskUser = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
}

if ($ShortcutOnly) {
    if (Install-MeshstickLayout) {
        & "C:\Apps\Meshstick\scripts\install-windows.ps1" -ShortcutOnly -DesktopPath $DesktopPath -TaskUser $TaskUser
    } else {
        New-MeshstickShortcut -Desktop $DesktopPath
    }
    exit 0
}

if (-not (Test-IsAdmin)) {
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Distribution `"$Distribution`" -OwnerName `"$OwnerName`" -DesktopPath `"$DesktopPath`" -TaskUser `"$TaskUser`""
    $elevated = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList $arg
    if (-not $elevated) {
        Show-MeshstickDialog "Installation annulee : le controle de compte a ete refuse."
        exit 1
    }
    exit $elevated.ExitCode
}

if (Install-MeshstickLayout) {
    & "C:\Apps\Meshstick\scripts\install-windows.ps1" -Distribution $Distribution -OwnerName $OwnerName -DesktopPath $DesktopPath -TaskUser $TaskUser
    exit 0
}

Test-MeshstickInstallPrereqs -DistributionName $Distribution

function Start-MeshstickUbuntu {
    Start-Process -FilePath "wsl.exe" -ArgumentList @("-d", $Distribution, "-u", "root", "--", "sleep", "infinity") -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Seconds 1
        $script:wslList = (& wsl.exe -l -v 2>&1 | Out-String) -replace "`0", ""
    } while ((Get-Date) -lt $deadline -and $script:wslList -notmatch "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+Running\b")
    return [bool]($script:wslList -match "(?m)^\s*\*?\s*$([regex]::Escape($Distribution))\s+Running\b")
}

Write-Host "Installation Meshstick USB pour Windows"

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

try {
    $pnp = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match "VID_1A86&PID_5512" })
    foreach ($device in $pnp) {
        if ($device.FriendlyName -match "COM\d+") {
            Write-Warning "Le pilote serie WCH CH341 est charge sur la cle ($($device.FriendlyName)). L'installation va lier la cle a usbipd, chemin prevu pour Meshtastic."
        }
    }
} catch {
    Write-Host "Lecture des peripheriques USB ignoree."
}

Write-Host "Demarrage de $Distribution..."
if (-not (Start-MeshstickUbuntu)) {
    if ($wslJustInstalled) {
        throw "Ubuntu vient d'etre installe. Redemarrez Windows, puis relancez ce script."
    }
    throw "Impossible de demarrer $Distribution."
}

Test-MeshstickWslPrereqs -DistributionName $Distribution

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
$script:MeshstickAttachLater = $false
& (Join-Path $PSScriptRoot "autostart-meshstick.ps1") -Distribution $Distribution -SkipService
$attachCode = $LASTEXITCODE
if ($attachCode -eq 20) {
    $script:MeshstickAttachLater = $true
    Write-Host "La cle n'est pas encore visible dans Ubuntu. L'installation continue."
} elseif ($attachCode -ne 0) {
    $detail = ""
    $attachLog = Join-Path $env:ProgramData "Meshstick\autostart.log"
    if (Test-Path -LiteralPath $attachLog) {
        $detail = ((Get-Content -LiteralPath $attachLog -Tail 12) -join "`n")
    }
    throw "Ubuntu n'est pas pret.`n$detail"
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
$taskUser = $TaskUser
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

$shortcutPath = New-MeshstickShortcut -Desktop $DesktopPath

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

$done = "Installation terminee. Le raccourci Meshstick USB est ici : $shortcutPath"
if ($script:MeshstickAttachLater) {
    $done += "`n`nLa cle n'etait pas encore attachee a Ubuntu. Ouvrez le raccourci Meshstick USB. S'il manque encore, debranchez la cle, rebranchez-la, puis rouvrez le raccourci."
}
Show-MeshstickDialog $done
