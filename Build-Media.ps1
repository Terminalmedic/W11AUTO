#Requires -RunAsAdministrator
param(
    [string]$IsoPath,
    [ValidateSet('Usb', 'Iso')][string]$Target = 'Usb',
    [int]$UsbDiskNumber = -1,
    [string]$EditionId = 'Core',
    [ValidateSet('max', 'fast')][string]$Compression = 'max',
    [switch]$DownloadUpdates,
    [switch]$BootEx,
    [switch]$ReuseImage,
    [switch]$PayloadOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Out = "$PSScriptRoot\out"; $Upd = "$PSScriptRoot\Updates"; $Work = 'C:\W11AUTO-build'; $Wim = "$Out\install.wim"
$Adk = "$((Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10)Assessment and Deployment Kit"
$Dism = @("$Adk\Deployment Tools\amd64\DISM\dism.exe", 'dism.exe') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1

function Run { & $args[0] @($args | Select-Object -Skip 1); if ($LASTEXITCODE) { throw "$args ($LASTEXITCODE)" } }
function Adk($c) { cmd.exe /c "call `"$Adk\Deployment Tools\DandISetEnv.bat`" >nul && $c"; if ($LASTEXITCODE) { throw $c } }

$cfgFile = @("$PSScriptRoot\config.json", "$PSScriptRoot\config.example.json") | Where-Object { Test-Path $_ } | Select-Object -First 1
$Cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
if ($PSBoundParameters.ContainsKey('BootEx')) { $Cfg.BootEx = [bool]$BootEx }

function Copy-Payload($Dest) {
    robocopy.exe "$PSScriptRoot\payload" $Dest /E /NFL /NDL /NJH /NJS | Out-Null
    if (Test-Path "$PSScriptRoot\Drivers") { robocopy.exe "$PSScriptRoot\Drivers" "$Dest\Drivers" /E /NFL /NDL /NJH /NJS | Out-Null }
    $Cfg | ConvertTo-Json | Set-Content "$Dest\config.json" -Encoding UTF8
    Set-Content "$Dest\W11AUTO.tag" ''
}
function Get-Updates($Ver) {
    New-Item -ItemType Directory $Upd -Force | Out-Null
    Remove-Item "$Upd\*.msu"
    foreach ($q in "Cumulative Update for Windows 11 Version $Ver for x64-based Systems", "Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version $Ver for x64") {
        $html = (Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$([uri]::EscapeDataString($q))" -UseBasicParsing).Content
        $hit = [regex]::Matches($html, '<a[^>]+id=["''](?<id>[\w-]{36})_link["''][^>]*>\s*(?<t>[^<]+?)\s*</a>') |
            Where-Object { $_.Groups['t'].Value -like "*$q*" -and $_.Groups['t'].Value -notmatch 'Dynamic' } | Sort-Object { $_.Groups['t'].Value } | Select-Object -Last 1
        if (-not $hit) { Write-Warning "Catalog: ei löytynyt '$q' – lataa .msu käsin kansioon Updates"; continue }
        Write-Host $hit.Groups['t'].Value
        $id = $hit.Groups['id'].Value
        $body = 'updateIDs=' + [uri]::EscapeDataString("[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$id`",`"updateID`":`"$id`"}]")
        $dl = (Invoke-WebRequest https://www.catalog.update.microsoft.com/DownloadDialog.aspx -Method Post -Body $body -ContentType application/x-www-form-urlencoded -UseBasicParsing).Content
        [regex]::Matches($dl, "url\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | ForEach-Object { Start-BitsTransfer $_ "$Upd\$(Split-Path $_ -Leaf)" }
    }
}

if ($PayloadOnly) {
    $v = Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\W11AUTO\W11AUTO.tag") } | Select-Object -First 1
    if (-not $v) { throw 'W11AUTO-levyä ei löytynyt' }
    Copy-Payload "$($v.DriveLetter):\W11AUTO"
    return
}
if (-not (Test-Path "$Adk\Windows Preinstallation Environment")) { throw 'Asenna Windows ADK + WinPE-lisäosa' }

if ($Target -eq 'Usb') {
    Get-Disk | Where-Object BusType -eq USB | ForEach-Object { Write-Host "  [$($_.Number)] $($_.FriendlyName) $([int]($_.Size / 1GB)) Gt" }
    if ($UsbDiskNumber -lt 0) { $UsbDiskNumber = Read-Host 'USB-levyn numero' }
    $u = Get-Disk -Number $UsbDiskNumber
    if ($u.BusType -ne 'USB') { throw 'Ei USB-levy' }
    if ((Read-Host "KAIKKI TIEDOT POISTETAAN: $($u.FriendlyName). Kirjoita numero uudelleen") -ne "$UsbDiskNumber") { return }
}
New-Item -ItemType Directory $Out, "$Work\mount", "$Work\pemount" -Force | Out-Null

if (-not ($ReuseImage -and (Test-Path $Wim))) {
    Mount-DiskImage (Resolve-Path $IsoPath) | Out-Null
    try {
        $src = (Get-ChildItem "$((Get-DiskImage (Resolve-Path $IsoPath) | Get-Volume).DriveLetter):\sources\install.*").FullName | Select-Object -First 1
        $img = Get-WindowsImage -ImagePath $src | ForEach-Object { Get-WindowsImage -ImagePath $src -Index $_.ImageIndex } | Where-Object EditionId -eq $EditionId | Select-Object -First 1
        if (-not $img) { throw "ISO:sta ei löytynyt versiota $EditionId" }
        if ($DownloadUpdates) { Get-Updates @{ 26100 = '24H2'; 26200 = '25H2' }[([version]$img.Version).Build] }
        Remove-Item "$Work\stage.wim", $Wim -ErrorAction SilentlyContinue
        Run $Dism /Export-Image "/SourceImageFile:$src" "/SourceIndex:$($img.ImageIndex)" "/DestinationImageFile:$Work\stage.wim" /Compression:max
    } finally { Dismount-DiskImage (Resolve-Path $IsoPath) | Out-Null }
    if (Get-ChildItem $Upd -Filter *.msu -ErrorAction SilentlyContinue) {
        Run $Dism /Mount-Image "/ImageFile:$Work\stage.wim" /Index:1 "/MountDir:$Work\mount"
        try {
            Run $Dism "/Image:$Work\mount" /Add-Package "/PackagePath:$Upd"
            Run $Dism "/Image:$Work\mount" /Cleanup-Image /StartComponentCleanup /ResetBase
            Run $Dism /Unmount-Image "/MountDir:$Work\mount" /Commit
        } catch { & $Dism /Unmount-Image /MountDir:$Work\mount /Discard; throw }
    }
    Run $Dism /Export-Image "/SourceImageFile:$Work\stage.wim" /SourceIndex:1 "/DestinationImageFile:$Wim" "/Compression:$Compression"
    Remove-Item "$Work\stage.wim"
}

Remove-Item "$Work\winpe" -Recurse -Force -ErrorAction SilentlyContinue
Adk "copype amd64 $Work\winpe"
Run $Dism /Mount-Image "/ImageFile:$Work\winpe\media\sources\boot.wim" /Index:1 "/MountDir:$Work\pemount"
try {
    $oc = "$Adk\Windows Preinstallation Environment\amd64\WinPE_OCs"
    foreach ($p in 'WMI', 'NetFX', 'Scripting', 'PowerShell', 'StorageWMI', 'DismCmdlets') {
        Run $Dism "/Image:$Work\pemount" /Add-Package "/PackagePath:$oc\WinPE-$p.cab" "/PackagePath:$oc\en-us\WinPE-${p}_en-us.cab"
    }
    Copy-Item "$PSScriptRoot\payload\WinPE\startnet.cmd" "$Work\pemount\Windows\System32\"
    Run $Dism "/Image:$Work\pemount" /Set-InputLocale:040b:0000040b
    Run $Dism /Unmount-Image "/MountDir:$Work\pemount" /Commit
} catch { & $Dism /Unmount-Image /MountDir:$Work\pemount /Discard; throw }

$bootex = if ($Cfg.BootEx) { '/bootex' }
if ($Target -eq 'Iso') {
    Copy-Payload "$Work\winpe\media\W11AUTO"
    New-Item -ItemType Directory "$Work\winpe\media\W11AUTO\Image" -Force | Out-Null
    Run $Dism /Split-Image "/ImageFile:$Wim" "/SWMFile:$Work\winpe\media\W11AUTO\Image\install.swm" /FileSize:3800
}
Adk "MakeWinPEMedia /ISO /F $Work\winpe `"$Out\W11AUTO.iso`" $bootex"
if ($Target -eq 'Iso') { return "$Out\W11AUTO.iso" }

$P, $D = @('P', 'O', 'N', 'M', 'L', 'K' | Where-Object { -not (Test-Path "${_}:\") })[0, 1]
"select disk $UsbDiskNumber", 'clean', 'convert mbr', 'create partition primary size=2048', 'active', 'format fs=fat32 quick label=W11BOOT', "assign letter=$P",
    'create partition primary', 'format fs=ntfs quick label=W11AUTO', "assign letter=$D" | Set-Content "$Work\dp.txt" -Encoding Ascii
Run diskpart.exe /s "$Work\dp.txt"
$iso = Mount-DiskImage "$Out\W11AUTO.iso" -PassThru
robocopy.exe "$(($iso | Get-Volume).DriveLetter):\" "${P}:\" /E /NFL /NDL /NJH /NJS | Out-Null
Dismount-DiskImage "$Out\W11AUTO.iso" | Out-Null
Adk "bootsect /nt60 ${P}: /mbr"
Copy-Payload "${D}:\W11AUTO"
robocopy.exe $Out "${D}:\W11AUTO\Image" install.wim /J /NFL /NDL /NJH /NJS | Out-Null
"Valmis: ${P}: (käynnistys) + ${D}:\W11AUTO"
