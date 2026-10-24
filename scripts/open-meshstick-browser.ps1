# Ouvre l'interface Meshtastic dans Google Chrome.
# Le navigateur par defaut de Windows n'est pas modifie.
# Chrome (ou Edge en secours) est necessaire pour les ports COM (Web Serial) et le Bluetooth du navigateur.

function Resolve-MeshstickChrome {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Google\Chrome\Application\chrome.exe"),
        (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe")
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    foreach ($key in @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
        )) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $item) {
            continue
        }
        $exe = $item.'(default)'
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            return $exe
        }
    }

    return $null
}

function Resolve-MeshstickEdge {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Microsoft\Edge\Application\msedge.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft\Edge\Application\msedge.exe")
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    return $null
}

function Open-MeshstickBrowser {
    param(
        [string]$Url = "https://127.0.0.1:9443/"
    )

    $chrome = Resolve-MeshstickChrome
    if ($chrome) {
        Start-Process -FilePath $chrome -ArgumentList @("--new-window", $Url)
        Write-Host "Chrome ouvert : $Url"
        return
    }

    $edge = Resolve-MeshstickEdge
    if ($edge) {
        Start-Process -FilePath $edge -ArgumentList @("--new-window", $Url)
        Write-Host "Chrome est absent. Edge ouvert a la place : $Url"
        return
    }

    throw "Google Chrome est introuvable. Installez Chrome pour choisir HTTPS, un port COM (serie) ou le Bluetooth dans l'interface."
}
