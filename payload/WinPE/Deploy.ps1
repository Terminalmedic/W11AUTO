# W11AUTO - WinPE-asennin. Käynnistyy startnet.cmd:stä.
# Asentaja valitsee levyn -> levy tyhjennetään -> Windows kirjoitetaan -> ajurit -> vastausmalli -> uudelleenkäynnistys.

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Root = Split-Path $Here -Parent                 # ...\W11AUTO
$MediaDrive = Split-Path $Root -Qualifier         # esim. E:
Import-Module (Join-Path $Here 'DriverPacks.psm1') -Force -DisableNameChecking
$Host.UI.RawUI.WindowTitle = 'W11AUTO'
Start-Transcript -Path 'X:\W11AUTO-deploy.log' -Force | Out-Null

$cfg = Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
$images = @(Get-Content (Join-Path $Root 'Image\images.json') -Raw | ConvertFrom-Json)
$Events = New-Object System.Collections.ArrayList
function Add-Event([string]$Area, [string]$Status, [string]$Text) { [void]$Events.Add(@{ Area = $Area; Status = $Status; Text = $Text }) }

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }

# ------------------------------------------------------------------ laitteisto
try {
    Add-Type -Namespace W11 -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);
[DllImport("kernel32.dll")] public static extern uint GetSystemFirmwareTable(uint provider, uint id, byte[] buffer, uint size);
'@
    $script:NativeOk = $true
} catch { $script:NativeOk = $false }

function Get-FirmwareKey {
    if (-not $script:NativeOk) { return $null }
    $size = [W11.Native]::GetSystemFirmwareTable(0x41435049, 0x4D44534D, $null, 0)   # 'ACPI', 'MSDM'
    if ($size -lt 85) { return $null }
    $buf = New-Object byte[] $size
    [void][W11.Native]::GetSystemFirmwareTable(0x41435049, 0x4D44534D, $buf, $size)
    $key = [Text.Encoding]::ASCII.GetString($buf, 56, 29)
    if ($key -match '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { $key } else { $null }
}

$cs = Get-CimInstance Win32_ComputerSystem
$csp = Get-CimInstance Win32_ComputerSystemProduct
$Hw = @{
    Manufacturer = "$($cs.Manufacturer)".Trim()
    Model        = "$($cs.Model)".Trim()
    Friendly     = if ($cs.Manufacturer -match 'Lenovo' -and $csp.Version) { "$($csp.Version) ($($cs.Model))" } else { "$($cs.Model)".Trim() }
    Sku          = "$($cs.SystemSKUNumber)".Trim()
    BaseBoard    = "$((Get-CimInstance Win32_BaseBoard).Product)".Trim()
    Serial       = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
}
$Uefi = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').PEFirmwareType -eq 2
$CpuOk = if ($script:NativeOk) { [W11.Native]::IsProcessorFeaturePresent(38) } else { $true }   # PF_SSE4_2 (24H2+ vaatii)
$FwKey = Get-FirmwareKey
$RamGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB)

$MediaIsCd = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$MediaDrive'").DriveType -eq 5
$MediaDisk = if ($MediaIsCd) { -1 } else { try { (Get-Partition -DriveLetter $MediaDrive.TrimEnd(':')).DiskNumber } catch { -1 } }
$Writable = -not $MediaIsCd

# ------------------------------------------------------------------ ajurit WinPE:hen (levyohjain / verkkokortti) ja verkko
$peDrivers = Join-Path $Root 'Drivers\WinPE'
if (Test-Path $peDrivers) {
    Get-ChildItem $peDrivers -Filter *.inf -Recurse | ForEach-Object { & drvload.exe $_.FullName | Out-Null }
    & wpeutil.exe InitializeNetwork | Out-Null
}
try { & tzutil.exe /s 'FLE Standard Time' 2>$null } catch { }

function Test-Net {
    try {
        $req = [Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
        $req.Timeout = 4000; $req.Method = 'HEAD'
        $resp = $req.GetResponse(); $date = $resp.Headers['Date']; $resp.Close()
        # Tyhjä CMOS-paristo -> väärä kello -> TLS ei toimi. Korjataan vain isot heitot.
        if ($date) {
            $net = [DateTime]::Parse($date).ToUniversalTime()
            if ([Math]::Abs(($net - [DateTime]::UtcNow).TotalHours) -gt 12) { Set-Date $net.ToLocalTime() | Out-Null }
        }
        return $true
    } catch { return $false }
}
$Net = $false
for ($i = 0; $i -lt 5 -and -not $Net; $i++) { $Net = Test-Net; if (-not $Net) { Start-Sleep -Seconds 2 } }

# ------------------------------------------------------------------ valikko
$Sysprep = [bool]$cfg.SysprepDefault
$ImgPos = [Math]::Max(0, [array]::IndexOf(@($images | ForEach-Object { $_.EditionId }), [string]$cfg.DefaultEditionId))

function Get-Candidates {
    # Asennusmedia ja USB-levyt piilotetaan, ettei tikkua voi vahingossa tyhjentää
    @(Get-Disk | Where-Object { $_.Number -ne $MediaDisk -and $_.Size -gt 0 -and $_.BusType -ne 'USB' } | Sort-Object Number)
}

function Get-DiskSummary($d) {
    $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)
    if ($parts.Count -eq 0) { return 'tyhjä' }
    $bits = foreach ($p in $parts) {
        if ($p.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' -or $p.MbrType -eq 39) { 'palautus' ; continue }
        if ($p.GptType -in '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}', '{e3c9e316-0b5c-4db8-817d-f92df00215ae}') { continue }
        $v = $p | Get-Volume -ErrorAction SilentlyContinue
        $lbl = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { $v.FileSystem }
        if ($p.Size -gt 1GB) { '{0} {1} Gt' -f $lbl, [int]($p.Size / 1GB) }
    }
    ($bits | Where-Object { $_ }) -join ', '
}

function Show-Menu($disks) {
    Clear-Host
    $edition = $images[$ImgPos]
    Say '  W11AUTO – Windows 11 -asennus' 'White'
    Say '  -------------------------------------------------------------' 'DarkGray'
    Say ("  Kone:      {0} {1}   SN {2}" -f $Hw.Manufacturer, $Hw.Friendly, $Hw.Serial)
    Say ("  Laiteohjelmisto: {0}   RAM {1} Gt   Verkko: {2}" -f $(if ($Uefi) { 'UEFI' } else { 'BIOS (vanha)' }), $RamGB, $(if ($Net) { 'OK' } else { 'ei yhteyttä' })) $(if ($Net) { 'Gray' } else { 'Yellow' })
    if ($FwKey) { Say '  Emolevyn lisenssiavain: löytyi' 'Green' } else { Say '  Emolevyn lisenssiavain: EI LÖYDY (aktivointi vaatii digitaalisen lisenssin)' 'Yellow' }
    if (-not $CpuOk) { Say '  SUORITIN EI TUE SSE4.2/POPCNT – Windows 11 24H2+ EI KÄYNNISTY tällä koneella!' 'Red' }
    Say ''
    Say ("  Versio: {0}      Sysprep lopuksi: {1}" -f $edition.Name, $(if ($Sysprep) { 'KYLLÄ (asiakas luo tilin)' } else { 'ei (tili User)' })) 'White'
    Say ''
    if ($disks.Count -eq 0) {
        Say '  LEVYJÄ EI LÖYTYNYT.' 'Red'
        Say '  Todennäköisesti Intel VMD/RST: lisää ajuri kansioon Drivers\WinPE tai kytke VMD pois BIOSista.' 'Yellow'
    } else {
        Say '  Levyt:' 'White'
        foreach ($d in $disks) {
            Say ("   [{0}]  {1,-34} {2,6} Gt  {3,-5} {4}" -f $d.Number, $d.FriendlyName, [int]($d.Size / 1GB), $d.BusType, (Get-DiskSummary $d)) 'Cyan'
        }
    }
    Say ''
    Say '  numero = asenna levylle   S = sysprep päälle/pois   V = vaihda versio' 'DarkGray'
    Say '  R = päivitä   C = komentokehote   Q = sammuta' 'DarkGray'
}

# ------------------------------------------------------------------ asennus
function Get-FreeLetters([int]$Count) {
    $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
    @('W', 'S', 'T', 'U', 'V', 'R', 'Q', 'P', 'O', 'N' | Where-Object { $used -notcontains $_ } | Select-Object -First $Count)
}

function Invoke-Native([string]$Exe, [string[]]$ArgList, [string]$What) {
    & $Exe @ArgList
    if ($LASTEXITCODE -ne 0) { throw "$What epäonnistui (koodi $LASTEXITCODE)" }
}

function Set-OfflineRegistry([string]$Win) {
    & reg.exe load HKLM\W11SYS "$Win\Windows\System32\config\SYSTEM" | Out-Null
    & reg.exe load HKLM\W11SW "$Win\Windows\System32\config\SOFTWARE" | Out-Null
    try {
        $set = @(
            @('HKLM\W11SYS\ControlSet001\Control\BitLocker', 'PreventDeviceEncryption', 1)          # ei laitesalausta
            @('HKLM\W11SYS\Setup\MoSetup', 'AllowUpgradesWithUnsupportedTPMOrCPU', 1)              # versiopäivitykset ilman TPM/CPU-tarkistusta
            @('HKLM\W11SYS\Setup\LabConfig', 'BypassTPMCheck', 1)
            @('HKLM\W11SYS\Setup\LabConfig', 'BypassSecureBootCheck', 1)
            @('HKLM\W11SYS\Setup\LabConfig', 'BypassRAMCheck', 1)
            @('HKLM\W11SYS\Setup\LabConfig', 'BypassCPUCheck', 1)
            @('HKLM\W11SW\Microsoft\Windows\CurrentVersion\Policies\System', 'EnableFirstLogonAnimation', 0)  # nopeampi 1. kirjautuminen
            @('HKLM\W11SW\Microsoft\Windows NT\CurrentVersion\Winlogon', 'EnableFirstLogonAnimation', 0)
            @('HKLM\W11SW\Microsoft\Windows\CurrentVersion\OOBE', 'BypassNRO', 1)
            @('HKLM\W11SW\Microsoft\WindowsUpdate\UX\Settings', 'AllowAutoWindowsUpdateDownloadOverMeteredNetwork', 1)
        )
        foreach ($s in $set) { & reg.exe add $s[0] /v $s[1] /t REG_DWORD /d $s[2] /f | Out-Null }
    } finally {
        [gc]::Collect(); Start-Sleep -Milliseconds 500
        & reg.exe unload HKLM\W11SW | Out-Null
        & reg.exe unload HKLM\W11SYS | Out-Null
    }
}

function Add-OfflineDrivers([string]$Win, [string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $n = @(Get-ChildItem $Path -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count
    if ($n -eq 0) { return 0 }
    & dism.exe /Image:"$Win\" /Add-Driver /Driver:"$Path" /Recurse /English | Out-Null
    if ($LASTEXITCODE -ne 0) { Say "   DISM /Add-Driver palautti $LASTEXITCODE (osa ajureista voi puuttua)" 'Yellow' }
    $n
}

function Invoke-DriverPack([string]$Win) {
    if ($cfg.DriverPacks -eq $false) { return }
    $cacheDir = Join-Path $Root 'Drivers\_Cache'
    $indexFile = Join-Path $cacheDir 'index.json'
    $key = '{0}|{1}|{2}|{3}' -f $Hw.Manufacturer, $Hw.Model, $Hw.Sku, $Hw.BaseBoard
    $index = @{}
    if (Test-Path $indexFile) { (Get-Content $indexFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $index[$_.Name] = $_.Value } }

    $pack = $null
    if ($Net) {
        try { $pack = Find-W11DriverPack -Hw $Hw -WorkDir 'X:\W11Cat' } catch { Say "   Ajuriluettelon haku epäonnistui: $($_.Exception.Message)" 'Yellow' }
    }
    if (-not $pack -and $index.ContainsKey($key)) { $c = $index[$key]; $pack = @{ Manufacturer = $c.Manufacturer; Name = $c.Name; FileName = $c.FileName; Format = $c.Format; Url = $c.Url } }
    if (-not $pack) {
        if ($Hw.Manufacturer -match 'Dell|HP|Hewlett|Lenovo') {
            $why = if ($Net) { 'mallille ei löytynyt pakettia' } else { 'ei verkkoa WinPE:ssä eikä pakettia välimuistissa' }
            Add-Event 'Ajuripaketti' 'WARN' "Ei valmistajan ajuripakettia ($why) – ajurit tulevat Windows Updatesta"
        }
        return
    }

    $store = if ($Writable) { $cacheDir } else { Join-Path $Win 'W11AUTO-tmp' }
    New-Item -ItemType Directory -Path $store -Force | Out-Null
    $local = Join-Path $store $pack.FileName
    if (Test-Path $local) { Say "   $($pack.Name) löytyi välimuistista" 'Green' }
    elseif ($Net) {
        Say "   Ladataan $($pack.Name)"
        try { Save-W11File -Url $pack.Url -Path $local -Label 'Ajuripaketti' }
        catch { Add-Event 'Ajuripaketti' 'WARN' "$($pack.Name): lataus epäonnistui – ajurit tulevat Windows Updatesta"; return }
        if ($Writable) {
            $index[$key] = $pack
            $index | ConvertTo-Json -Depth 4 | Set-Content $indexFile -Encoding UTF8
        }
    } else { return }

    if ($pack.Format -eq 'cab') {
        $x = Join-Path $Win 'W11AUTO-tmp\x'
        New-Item -ItemType Directory -Path $x -Force | Out-Null
        & expand.exe "$local" -F:* "$x" | Out-Null
        $n = Add-OfflineDrivers $Win $x
        Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
        if ($n -gt 0) { Add-Event 'Ajuripaketti' 'OK' "$($pack.Name) asennettu ($n ajuria)" }
        else { Add-Event 'Ajuripaketti' 'WARN' "$($pack.Name): purku ei tuottanut ajureita" }
    } else {
        # HP/Lenovo: 32-bittinen purkaja ei toimi WinPE:ssä -> puretaan specialize-vaiheessa (Specialize.ps1)
        $dp = Join-Path $Win 'W11AUTO\DriverPack'
        New-Item -ItemType Directory -Path $dp -Force | Out-Null
        Copy-Item $local $dp -Force
        @{ Manufacturer = $pack.Manufacturer; Name = $pack.Name; File = $pack.FileName } | ConvertTo-Json | Set-Content (Join-Path $dp 'pack.json') -Encoding UTF8
        Say "   $($pack.Name) asennetaan ensimmäisellä käynnistyksellä"
    }
    if (-not $Writable) { Remove-Item (Join-Path $Win 'W11AUTO-tmp') -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-W11($Disk) {
    $started = Get-Date
    $img = $images[$ImgPos]
    $winL, $sysL = Get-FreeLetters 2
    $Sys = "${sysL}:"; $Win = "${winL}:"

    Step "Osioidaan levy $($Disk.Number) ($($Disk.FriendlyName)) – $(if ($Uefi) { 'GPT/UEFI' } else { 'MBR/BIOS' })"
    $dp = @("select disk $($Disk.Number)", 'online disk noerr', 'attributes disk clear readonly noerr', 'clean')
    if ($Uefi) {
        $dp += 'convert gpt', 'create partition efi size=260', 'format quick fs=fat32 label="System"', "assign letter=$sysL",
               'create partition msr size=16', 'create partition primary', 'format quick fs=ntfs label="Windows"', "assign letter=$winL"
    } else {
        $dp += 'convert mbr', 'create partition primary size=200', 'format quick fs=ntfs label="System"', 'active', "assign letter=$sysL",
               'create partition primary', 'format quick fs=ntfs label="Windows"', "assign letter=$winL"
    }
    $dp += 'exit'
    $dp | Set-Content -Path 'X:\w11-diskpart.txt' -Encoding ASCII
    & diskpart.exe /s X:\w11-diskpart.txt | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$Win\")) { throw "Osiointi epäonnistui (diskpart $LASTEXITCODE)" }

    Step "Kirjoitetaan $($img.Name) levylle"
    $imgFile = Join-Path $Root "Image\$($img.File)"
    $applyArgs = @('/Apply-Image', "/ImageFile:$imgFile", "/Index:$($img.Index)", "/ApplyDir:$Win\")
    if ($imgFile -like '*.swm') { $applyArgs += "/SWMFile:$(Join-Path $Root 'Image\install*.swm')" }
    Invoke-Native dism.exe $applyArgs 'Levykuvan kirjoitus'
    Add-Event 'Asennus' 'OK' ("{0} ({1}) kirjoitettu levylle {2} {3} Gt" -f $img.Name, $img.Version, $Disk.FriendlyName, [int]($Disk.Size / 1GB))

    Step 'Ajurit'
    $n = Add-OfflineDrivers $Win (Join-Path $Root 'Drivers\_Kaikki')
    $safe = { param($s) ($s -replace '[\\/:*?"<>|]', '_').Trim() }
    $n += Add-OfflineDrivers $Win (Join-Path $Root ("Drivers\{0}\{1}" -f (& $safe $Hw.Manufacturer), (& $safe $Hw.Model)))
    if ($n -gt 0) { Add-Event 'USB-ajurit' 'OK' "$n ajuria USB:n Drivers-kansiosta" }
    Invoke-DriverPack $Win

    Step 'Asetukset (laitesalaus pois, vaatimusten ohitus, nopea ensikirjautuminen)'
    Set-OfflineRegistry $Win

    Step 'Kopioidaan W11AUTO ja vastausmalli'
    $dst = Join-Path $Win 'W11AUTO'
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item (Join-Path $Root 'Windows\*') $dst -Recurse -Force
    Copy-Item (Join-Path $Root 'config.json') $dst -Force
    New-Item -ItemType Directory -Path "$Win\Windows\Panther" -Force | Out-Null
    Copy-Item (Join-Path $dst 'unattend.xml') "$Win\Windows\Panther\unattend.xml" -Force

    if (-not $CpuOk) { Add-Event 'Suoritin' 'FAIL' 'Suoritin ei tue SSE4.2/POPCNT – Windows 11 24H2+ ei välttämättä käynnisty' }
    if ($FwKey) { Add-Event 'Emolevyn avain' 'OK' 'Emolevyssä on Windows-lisenssiavain' }
    else { Add-Event 'Emolevyn avain' 'WARN' 'Emolevyssä ei ole lisenssiavainta – aktivointi onnistuu vain digitaalisella lisenssillä' }

    $state = @{
        Phase = 'updates'; Round = 0; Sysprep = $Sysprep
        DeployStarted = $started.ToString('o'); DeployEnded = (Get-Date).ToString('o')
        Events = @($Events); Installed = @(); FailedTitles = @(); FailCounts = @{}
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dst 'state.json') -Encoding UTF8

    Step 'Käynnistystiedostot'
    $bcdArgs = @("$Win\Windows", '/s', $Sys, '/f', $(if ($Uefi) { 'UEFI' } else { 'BIOS' }))
    if ($Uefi -and $cfg.BootEx) { $bcdArgs += '/offline', '/bootex' }   # Windows UEFI CA 2023 -allekirjoitettu käynnistyksenhallinta
    Invoke-Native bcdboot.exe $bcdArgs 'bcdboot'
    & reagentc.exe /setreimage /path "$Win\Windows\System32\Recovery" /target "$Win\Windows" 2>$null | Out-Null

    $mins = [int]((Get-Date) - $started).TotalMinutes
    Say ''
    Say "  Asennus valmis $mins minuutissa." 'Green'
}

function Save-Logs([string]$Win) {
    try { Stop-Transcript | Out-Null } catch { }
    if ($Win -and (Test-Path "$Win\Windows")) {
        New-Item -ItemType Directory -Path "$Win\Windows\Logs\W11AUTO" -Force | Out-Null
        Copy-Item 'X:\W11AUTO-deploy.log' "$Win\Windows\Logs\W11AUTO\deploy.log" -Force -ErrorAction SilentlyContinue
    }
    if ($Writable) {
        $ld = Join-Path $Root 'Logs'
        New-Item -ItemType Directory -Path $ld -Force -ErrorAction SilentlyContinue | Out-Null
        $name = '{0}-{1}.log' -f ($Hw.Serial -replace '[^\w-]', ''), (Get-Date -Format 'yyyyMMdd-HHmm')
        Copy-Item 'X:\W11AUTO-deploy.log' (Join-Path $ld $name) -Force -ErrorAction SilentlyContinue
    }
}

function Wait-MediaRemoval {
    if ($MediaIsCd) {
        Say '  Käynnistetään uudelleen 10 s kuluttua (poista asennuslevy).' 'White'
        Start-Sleep -Seconds 10; return
    }
    Say ''
    Say '  >>> IRROTA USB-TIKKU <<<   Kone käynnistyy uudelleen heti kun tikku on irrotettu.' 'Yellow'
    Say '  (R = käynnistä uudelleen heti)' 'DarkGray'
    $beep = Get-Date
    while (Test-Path "$MediaDrive\") {
        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'R') { break }
        if (((Get-Date) - $beep).TotalSeconds -ge 15) { [Console]::Beep(660, 120); $beep = Get-Date }
        Start-Sleep -Milliseconds 500
    }
}

# ------------------------------------------------------------------ pääsilmukka
while ($true) {
    $disks = Get-Candidates
    Show-Menu $disks
    $in = (Read-Host "`n  Valinta").Trim().ToUpper()
    switch -Regex ($in) {
        '^S$' { $Sysprep = -not $Sysprep; continue }
        '^V$' { $ImgPos = ($ImgPos + 1) % $images.Count; continue }
        '^R$' { $Net = Test-Net; continue }
        '^C$' { Start-Process cmd.exe -Wait; continue }
        '^Q$' { & wpeutil.exe shutdown; exit }
        '^\d+$' {
            $d = $disks | Where-Object { $_.Number -eq [int]$in }
            if (-not $d) { Say '  Ei tällaista levyä.' 'Red'; Start-Sleep 2; continue }
            if ($d.Size -lt 30GB) { Say '  Levy on liian pieni (alle 30 Gt).' 'Red'; Start-Sleep 3; continue }
            Say ''
            Say ("  KAIKKI TIEDOT POISTETAAN LEVYLTÄ {0}: {1} {2} Gt ({3})" -f $d.Number, $d.FriendlyName, [int]($d.Size / 1GB), (Get-DiskSummary $d)) 'Red'
            if (-not $CpuOk) { Say '  VAROITUS: suoritin ei tue Windows 11 24H2:ta – asennus ei todennäköisesti käynnisty.' 'Red' }
            $confirm = (Read-Host '  Vahvista kirjoittamalla levyn numero uudelleen (tyhjä = peruuta)').Trim()
            if ($confirm -ne "$($d.Number)") { continue }
            $winDrive = $null
            try {
                Install-W11 $d
                $winDrive = (Get-Partition -DiskNumber $d.Number | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows") } | Select-Object -First 1).DriveLetter
                Save-Logs $(if ($winDrive) { "${winDrive}:" })
                Wait-MediaRemoval
                & wpeutil.exe reboot
                exit
            } catch {
                Say ''
                Say "  VIRHE: $($_.Exception.Message)" 'Red'
                Say "  Loki: X:\W11AUTO-deploy.log$(if ($Writable) { " ja USB:n Logs-kansio" })" 'Yellow'
                Save-Logs $null
                Start-Transcript -Path 'X:\W11AUTO-deploy.log' -Append | Out-Null
                Read-Host '  Paina Enter palataksesi valikkoon' | Out-Null
            }
        }
        default { }
    }
}
