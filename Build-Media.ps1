#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Rakentaa W11AUTO-asennusmedian (USB-tikku tai ISO testaukseen).

.DESCRIPTION
  1. Hakee (valinnaisesti) uusimman kumulatiivisen päivityksen + .NET-päivityksen Microsoft Update Catalogista
  2. Vie valitun version (oletus Home) Windows 11 -ISO:sta omaksi levykuvakseen ja lisää päivitykset siihen
  3. Rakentaa WinPE:n (ADK) PowerShell-tuella ja W11AUTO-käynnistyksellä
  4. Kirjoittaa USB-tikun: FAT32-käynnistysosio (WinPE) + NTFS-dataosio (levykuva, skriptit, ajurit, lokit)

  Vaatii: Windows 10/11, Windows ADK + WinPE-lisäosa (10.1.26100.2454 tai uudempi), järjestelmänvalvoja.

.EXAMPLE
  .\Build-Media.ps1 -IsoPath D:\Win11_25H2_Finnish_x64.iso -DownloadUpdates -UsbDiskNumber 3
.EXAMPLE
  .\Build-Media.ps1 -IsoPath D:\Win11.iso -Target Iso            # Hyper-V-testaukseen
.EXAMPLE
  .\Build-Media.ps1 -PayloadOnly                                 # päivitä vain skriptit/asetukset olemassa olevalle tikulle
#>
[CmdletBinding()]
param(
    [string]$IsoPath,
    [ValidateSet('Usb', 'Iso')][string]$Target = 'Usb',
    [int]$UsbDiskNumber = -1,
    [string]$OutputIso = (Join-Path $PSScriptRoot 'out\W11AUTO.iso'),
    [string]$EditionId = 'Core',                 # Core = Home, Professional = Pro
    [string]$DiscordWebhook,
    [switch]$DownloadUpdates,                    # hae uusimmat päivitykset Catalogista kansioon Updates\
    [switch]$SkipUpdates,                        # älä lisää päivityksiä levykuvaan
    [switch]$SkipResetBase,                      # nopeampi rakennus, isompi levykuva
    [switch]$BootEx,                             # Windows UEFI CA 2023 -allekirjoitetut käynnistystiedostot
    [switch]$ReuseImage,                         # käytä edellistä out\install.wim -tiedostoa (ei uudelleenhuoltoa)
    [switch]$PayloadOnly,                        # päivitä vain W11AUTO-skriptit ja config.json tikulle
    [string]$WorkDir = 'C:\W11AUTO-build'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$BootExGiven = $PSBoundParameters.ContainsKey('BootEx')
$Repo = $PSScriptRoot
$OutDir = Join-Path $Repo 'out'
$UpdatesDir = Join-Path $Repo 'Updates'

function Step([string]$t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Run([string]$Exe, [string[]]$ArgList, [string]$What) {
    & $Exe @ArgList
    if ($LASTEXITCODE -ne 0) { throw "$What epäonnistui (koodi $LASTEXITCODE)" }
}

# ------------------------------------------------------------------ ADK
$kits = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
$adk = if ($kits) { Join-Path $kits 'Assessment and Deployment Kit' }
$peRoot = "$adk\Windows Preinstallation Environment"
$dandi = "$adk\Deployment Tools\DandISetEnv.bat"
$Dism = "$adk\Deployment Tools\amd64\DISM\dism.exe"
if (-not $PayloadOnly) {
    if (-not $adk -or -not (Test-Path "$peRoot\amd64")) { throw 'Windows ADK ja WinPE-lisäosa puuttuvat: https://learn.microsoft.com/windows-hardware/get-started/adk-install' }
    if (-not (Test-Path $Dism)) { $Dism = "$env:SystemRoot\System32\dism.exe" }
}
function Invoke-Dandi([string]$Command) {
    & cmd.exe /c "call `"$dandi`" >nul && $Command"
    if ($LASTEXITCODE -ne 0) { throw "Komento epäonnistui: $Command" }
}

# ------------------------------------------------------------------ config.json
function New-Config {
    $src = if (Test-Path (Join-Path $Repo 'config.json')) { Join-Path $Repo 'config.json' } else { Join-Path $Repo 'config.example.json' }
    $cfg = Get-Content $src -Raw | ConvertFrom-Json
    if ($DiscordWebhook) { $cfg | Add-Member -NotePropertyName DiscordWebhook -NotePropertyValue $DiscordWebhook -Force }
    if ($BootExGiven) { $cfg | Add-Member -NotePropertyName BootEx -NotePropertyValue ([bool]$BootEx) -Force }
    if (-not $PayloadOnly) { $cfg | Add-Member -NotePropertyName DefaultEditionId -NotePropertyValue $EditionId -Force }
    $cfg
}

# ------------------------------------------------------------------ payload (W11AUTO-kansio)
function Copy-Payload([string]$Dest, $Config) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    foreach ($d in 'WinPE', 'Windows') {
        $t = Join-Path $Dest $d
        if (Test-Path $t) { Remove-Item $t -Recurse -Force }
        Copy-Item (Join-Path $Repo "payload\$d") $t -Recurse -Force
    }
    $Config | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Dest 'config.json') -Encoding UTF8
    Set-Content (Join-Path $Dest 'W11AUTO.tag') -Value "W11AUTO $(Get-Date -Format s)" -Encoding ASCII
    # Ajurit (välimuisti _Cache säilyy tikulla, sitä ei kopioida repoon eikä poisteta)
    $drv = Join-Path $Dest 'Drivers'
    New-Item -ItemType Directory -Path $drv -Force | Out-Null
    Get-ChildItem (Join-Path $Repo 'Drivers') -Directory | ForEach-Object {
        & robocopy.exe $_.FullName (Join-Path $drv $_.Name) /E /NFL /NDL /NJH /NJS /NP | Out-Null
    }
}

# ================================================================== vain skriptit
if ($PayloadOnly) {
    $vol = Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\W11AUTO\W11AUTO.tag") } | Select-Object -First 1
    if (-not $vol) { throw 'W11AUTO-tikkua ei löytynyt (etsitään \W11AUTO\W11AUTO.tag)' }
    Step "Päivitetään skriptit ja asetukset: $($vol.DriveLetter):\W11AUTO"
    Copy-Payload "$($vol.DriveLetter):\W11AUTO" (New-Config)
    Write-Host 'Valmis.' -ForegroundColor Green
    return
}

if (-not $IsoPath -or -not (Test-Path $IsoPath)) { throw 'Anna Windows 11 -ISO: -IsoPath <polku>' }

# ------------------------------------------------------------------ USB-kohteen valinta heti alussa (ei yllätyksiä tunnin päästä)
if ($Target -eq 'Usb') {
    $usb = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })
    if ($UsbDiskNumber -lt 0) {
        if ($usb.Count -eq 0) { throw 'USB-levyjä ei löytynyt' }
        $usb | ForEach-Object { Write-Host ("  [{0}] {1}  {2} Gt" -f $_.Number, $_.FriendlyName, [int]($_.Size / 1GB)) }
        $UsbDiskNumber = [int](Read-Host 'USB-levyn numero')
    }
    $UsbDisk = $usb | Where-Object { $_.Number -eq $UsbDiskNumber }
    if (-not $UsbDisk) { throw "Levy $UsbDiskNumber ei ole USB-levy" }
    if ($UsbDisk.Size -lt 14GB) { throw 'USB-tikun pitää olla vähintään 16 Gt (suositus 64 Gt ajuripakettien välimuistille)' }
    Write-Host ("KAIKKI TIEDOT POISTETAAN: [{0}] {1} {2} Gt" -f $UsbDisk.Number, $UsbDisk.FriendlyName, [int]($UsbDisk.Size / 1GB)) -ForegroundColor Red
    if ((Read-Host 'Vahvista kirjoittamalla levyn numero uudelleen') -ne "$UsbDiskNumber") { throw 'Peruutettu' }
}

New-Item -ItemType Directory -Path $WorkDir, $OutDir -Force | Out-Null
$Cfg = New-Config
$FinalWim = Join-Path $OutDir 'install.wim'
$ImagesJson = Join-Path $OutDir 'images.json'

# ================================================================== 1. levykuva
if ($ReuseImage -and (Test-Path $FinalWim) -and (Test-Path $ImagesJson)) {
    Step 'Käytetään edellistä levykuvaa (out\install.wim)'
} else {
    Step 'Avataan ISO'
    $iso = Mount-DiskImage -ImagePath (Resolve-Path $IsoPath) -PassThru
    try {
        $isoDrive = ($iso | Get-Volume).DriveLetter + ':'
        $src = @("$isoDrive\sources\install.wim", "$isoDrive\sources\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $src) { throw 'ISO:sta ei löytynyt install.wim/esd' }
        $srcIdx = $null
        foreach ($i in Get-WindowsImage -ImagePath $src) {
            $info = Get-WindowsImage -ImagePath $src -Index $i.ImageIndex
            Write-Host ("  [{0}] {1} ({2})" -f $i.ImageIndex, $i.ImageName, $info.EditionId)
            if (-not $srcIdx -and $info.EditionId -eq $EditionId) { $srcIdx = $i.ImageIndex; $srcInfo = $info }
        }
        if (-not $srcIdx) { throw "Versiota $EditionId ei löytynyt ISO:sta" }
        $build = [int]$srcInfo.Version.Split('.')[2]
        if ($srcInfo.Languages -notcontains 'fi-FI') { Write-Warning "Levykuvan kieli on $($srcInfo.Languages -join ',') – vastausmalli olettaa fi-FI" }

        if ($DownloadUpdates) {
            Step "Haetaan uusimmat päivitykset (koontiversio $build)"
            Import-Module (Join-Path $Repo 'build\UpdateCatalog.psm1') -Force
            Save-W11LatestUpdates -Build $build -Destination $UpdatesDir | Out-Null
        }

        Step "Viedään $($srcInfo.ImageName) omaksi levykuvaksi"
        $stage = Join-Path $WorkDir 'stage.wim'
        Remove-Item $stage -Force -ErrorAction SilentlyContinue
        Run $Dism @('/Export-Image', "/SourceImageFile:$src", "/SourceIndex:$srcIdx", "/DestinationImageFile:$stage", '/Compression:max', '/CheckIntegrity') 'Export-Image'
    } finally { Dismount-DiskImage -ImagePath (Resolve-Path $IsoPath) | Out-Null }

    $msus = @(Get-ChildItem $UpdatesDir -Filter *.msu -ErrorAction SilentlyContinue)
    if (-not $SkipUpdates -and $msus.Count -gt 0) {
        Step "Lisätään $($msus.Count) päivityspakettia levykuvaan (kestää 15–40 min)"
        $mount = Join-Path $WorkDir 'mount'; $scratch = Join-Path $WorkDir 'scratch'
        New-Item -ItemType Directory -Path $mount, $scratch -Force | Out-Null
        Run $Dism @('/Mount-Image', "/ImageFile:$stage", '/Index:1', "/MountDir:$mount") 'Mount-Image'
        try {
            # Kansio: DISM löytää checkpoint-päivitykset samasta kansiosta ja asentaa oikeassa järjestyksessä
            Run $Dism @("/Image:$mount", '/Add-Package', "/PackagePath:$UpdatesDir", "/ScratchDir:$scratch") 'Add-Package'
            if (-not $SkipResetBase) {
                Step 'Siivotaan komponenttivarasto (pienempi ja nopeampi levykuva)'
                Run $Dism @("/Image:$mount", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase', "/ScratchDir:$scratch") 'Cleanup-Image'
            }
            Run $Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit') 'Unmount-Image'
        } catch {
            & $Dism /Unmount-Image /MountDir:$mount /Discard | Out-Null
            throw
        }
    } elseif (-not $SkipUpdates) {
        Write-Warning 'Kansiossa Updates\ ei ole .msu-paketteja – levykuva jää ISO:n tasolle (käytä -DownloadUpdates)'
    }

    Step 'Pakataan lopullinen levykuva'
    Remove-Item $FinalWim -Force -ErrorAction SilentlyContinue
    Run $Dism @('/Export-Image', "/SourceImageFile:$stage", '/SourceIndex:1', "/DestinationImageFile:$FinalWim", '/Compression:max') 'Export-Image'
    Remove-Item $stage -Force
    $fin = Get-WindowsImage -ImagePath $FinalWim -Index 1
    $label = @{ Core = 'Windows 11 Home'; Professional = 'Windows 11 Pro'; CoreSingleLanguage = 'Windows 11 Home Single Language' }[$EditionId]
    if (-not $label) { $label = $fin.ImageName }
    ConvertTo-Json -InputObject @(@{ Index = 1; EditionId = $fin.EditionId; Name = $label; Version = $fin.Version; File = 'install.wim' }) |
        Set-Content $ImagesJson -Encoding UTF8
    Write-Host "  Levykuva: $label $($fin.Version), $([int]((Get-Item $FinalWim).Length / 1MB)) Mt" -ForegroundColor Green
}

# ================================================================== 2. WinPE
Step 'Rakennetaan WinPE'
$pe = Join-Path $WorkDir 'winpe'
if (Test-Path $pe) { Remove-Item $pe -Recurse -Force }
Invoke-Dandi "copype amd64 `"$pe`" >nul"
$peMount = Join-Path $WorkDir 'pemount'
New-Item -ItemType Directory -Path $peMount -Force | Out-Null
Run $Dism @('/Mount-Image', "/ImageFile:$pe\media\sources\boot.wim", '/Index:1', "/MountDir:$peMount") 'WinPE Mount'
try {
    $ocs = "$peRoot\amd64\WinPE_OCs"
    foreach ($oc in 'WinPE-WMI', 'WinPE-NetFX', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets', 'WinPE-EnhancedStorage') {
        Write-Host "  + $oc"
        Run $Dism @("/Image:$peMount", '/Add-Package', "/PackagePath:$ocs\$oc.cab") $oc
        $lp = "$ocs\en-us\${oc}_en-us.cab"
        if (Test-Path $lp) { Run $Dism @("/Image:$peMount", '/Add-Package', "/PackagePath:$lp") "$oc (en-us)" }
    }
    $peDrv = Join-Path $Repo 'Drivers\WinPE'
    if (@(Get-ChildItem $peDrv -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count) {
        Run $Dism @("/Image:$peMount", '/Add-Driver', "/Driver:$peDrv", '/Recurse') 'WinPE-ajurit'
    }
    Copy-Item (Join-Path $Repo 'payload\WinPE\startnet.cmd') "$peMount\Windows\System32\startnet.cmd" -Force
    Run $Dism @("/Image:$peMount", '/Set-InputLocale:040b:0000040b') 'Set-InputLocale'
    Run $Dism @("/Image:$peMount", '/Set-ScratchSpace:512') 'Set-ScratchSpace'
    Run $Dism @('/Unmount-Image', "/MountDir:$peMount", '/Commit') 'WinPE Unmount'
} catch {
    & $Dism /Unmount-Image /MountDir:$peMount /Discard | Out-Null
    throw
}
$bootexArg = if ($Cfg.BootEx) { ' /bootex' } else { '' }

# ================================================================== 3. media
if ($Target -eq 'Iso') {
    Step 'Luodaan ISO'
    # ISO:ssa tiedostot < 4 Gt -> levykuva pilkotaan (Deploy.ps1 tukee .swm-tiedostoja)
    $payload = Join-Path $pe 'media\W11AUTO'
    Copy-Payload $payload $Cfg
    $imgDir = Join-Path $payload 'Image'
    New-Item -ItemType Directory -Path $imgDir -Force | Out-Null
    Run $Dism @('/Split-Image', "/ImageFile:$FinalWim", "/SWMFile:$imgDir\install.swm", '/FileSize:3800') 'Split-Image'
    $imgs = Get-Content $ImagesJson -Raw | ConvertFrom-Json
    foreach ($i in $imgs) { $i.File = 'install.swm' }
    ConvertTo-Json -InputObject @($imgs) | Set-Content (Join-Path $imgDir 'images.json') -Encoding UTF8
    New-Item -ItemType Directory -Path (Split-Path $OutputIso) -Force | Out-Null
    Invoke-Dandi "MakeWinPEMedia /ISO /F `"$pe`" `"$OutputIso`"$bootexArg"
    Write-Host "Valmis: $OutputIso" -ForegroundColor Green
    return
}

Step "Osioidaan USB-levy $UsbDiskNumber (FAT32 käynnistys + NTFS data)"
$letters = @('P', 'O', 'N', 'M', 'L', 'K', 'J' | Where-Object { -not (Test-Path "${_}:\") })
$bootL, $dataL = $letters[0], $letters[1]
$dp = @(
    "select disk $UsbDiskNumber", 'clean', 'convert mbr',
    'create partition primary size=2048', 'active', 'format fs=fat32 quick label="W11BOOT"', "assign letter=$bootL",
    'create partition primary', 'format fs=ntfs quick label="W11AUTO"', "assign letter=$dataL", 'exit'
)
$dpFile = Join-Path $WorkDir 'usb-diskpart.txt'
$dp | Set-Content $dpFile -Encoding ASCII
Run diskpart.exe @('/s', $dpFile) 'USB-osiointi'
Start-Sleep -Seconds 3

Step 'Kirjoitetaan WinPE käynnistysosioon'
Invoke-Dandi "MakeWinPEMedia /UFD /F `"$pe`" ${bootL}:$bootexArg"

Step 'Kopioidaan levykuva ja W11AUTO dataosioon'
$payload = "${dataL}:\W11AUTO"
Copy-Payload $payload $Cfg
$imgDir = Join-Path $payload 'Image'
New-Item -ItemType Directory -Path $imgDir -Force | Out-Null
& robocopy.exe $OutDir $imgDir install.wim images.json /J /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Levykuvan kopiointi epäonnistui (robocopy $LASTEXITCODE)" }

Write-Host ''
Write-Host "Valmis! Tikku: ${bootL}: (käynnistys) + ${dataL}:\W11AUTO (data)" -ForegroundColor Green
Write-Host 'Seuraavalla kerralla pelkkä skriptien päivitys: .\Build-Media.ps1 -PayloadOnly' -ForegroundColor DarkGray
