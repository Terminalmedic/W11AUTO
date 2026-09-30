$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot
$Media = Split-Path $Root -Qualifier
$Cfg = Get-Content "$Root\config.json" -Raw | ConvertFrom-Json
$Img = "$Root\Image\install.wim", "$Root\Image\install.swm" | Where-Object { Test-Path $_ } | Select-Object -First 1
Start-Transcript X:\deploy.log | Out-Null

$pe = Get-ChildItem "$Root\Drivers\WinPE" -Filter *.inf -Recurse -ErrorAction SilentlyContinue
if ($pe) { $pe | ForEach-Object { drvload.exe $_.FullName | Out-Null }; wpeutil.exe InitializeNetwork | Out-Null }

$cs = Get-CimInstance Win32_ComputerSystem
$Hw = @{
    Make = "$($cs.Manufacturer)".Trim(); Model = "$($cs.Model)".Trim(); Sku = "$($cs.SystemSKUNumber)".Trim()
    Board = "$((Get-CimInstance Win32_BaseBoard).Product)".Trim(); Serial = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
}
$Uefi = (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control).PEFirmwareType -eq 2
$CpuOk = $true; $Key = $null
try {
    Add-Type -Namespace W11 -Name N -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint f); [DllImport("kernel32.dll")] public static extern uint GetSystemFirmwareTable(uint p, uint i, byte[] b, uint s);'
    $CpuOk = [W11.N]::IsProcessorFeaturePresent(38)
    $n = [W11.N]::GetSystemFirmwareTable(0x41435049, 0x4D44534D, $null, 0)
    if ($n -ge 85) { $b = [byte[]]::new($n); [void][W11.N]::GetSystemFirmwareTable(0x41435049, 0x4D44534D, $b, $n); $Key = [Text.Encoding]::ASCII.GetString($b, 56, 29) }
} catch { }
$MediaDisk = try { (Get-Partition -DriveLetter $Media[0]).DiskNumber } catch { -1 }
$Cache = "$Root\Drivers\_Cache\" + ("$($Hw.Make)_$($Hw.Model)_$($Hw.Sku)_$($Hw.Board)" -replace '[^\w.-]', '_')
$Events = @()
function Ev($Area, $Status, $Text) { $script:Events += @{ Area = $Area; Status = $Status; Text = $Text } }

function Test-Net {
    try {
        $t = [datetime](Invoke-WebRequest http://www.msftconnecttest.com/connecttest.txt -UseBasicParsing -TimeoutSec 4).Headers.Date
        if ([Math]::Abs(((Get-Date) - $t).TotalHours) -gt 12) { Set-Date $t | Out-Null }
        $true
    } catch { $false }
}
function Get-Xml($Url) {
    $f = "X:\$(Split-Path $Url -Leaf)"
    (New-Object Net.WebClient).DownloadFile($Url, $f)
    if ($f -like '*.cab') { expand.exe $f -F:* X:\ | Out-Null; $f = $f -replace 'cab$', 'xml' }
    [xml](Get-Content $f -Raw)
}
function Find-Pack {
    switch -Regex ($Hw.Make) {
        'Dell' {
            $x = (Get-Xml https://downloads.dell.com/catalog/DriverPackCatalog.cab).DriverPackManifest
            $p = $x.DriverPackage | Where-Object { $_.type -eq 'win' -and $_.SupportedSystems.Brand.Model.systemID -contains $Hw.Sku -and $_.SupportedOperatingSystems.OperatingSystem.osCode -contains 'Windows11' } |
                Sort-Object { [datetime]$_.dateTime } | Select-Object -Last 1
            if ($p) { "https://$($x.baseLocation)/$($p.path)" }
        }
        'HP|Hewlett' {
            $x = (Get-Xml https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab).NewDataSet.HPClientDriverPackCatalog
            $p = $x.ProductOSDriverPackList.ProductOSDriverPack | Where-Object { ($_.SystemId -split ',\s*') -contains $Hw.Board -and $_.OSName -match 'Windows 11 64' } | Sort-Object OSName | Select-Object -Last 1
            if ($p) { ($x.SoftPaqList.SoftPaq | Where-Object Id -eq $p.SoftPaqId).Url -replace '^http:', 'https:' }
        }
        'Lenovo' {
            $m = (Get-Xml https://download.lenovo.com/cdrt/td/catalogv2.xml).ModelList.Model | Where-Object { $_.Types.Type -contains $Hw.Model.Substring(0, 4) } | Select-Object -First 1
            ($m.SCCM | Where-Object os -eq win11 | Sort-Object version | Select-Object -Last 1).'#text'
        }
    }
}
function Start-Pack($Win) {
    $dir = if ($MediaDisk -ge 0) { $Cache } else { "$Win\W11AUTO-pack" }
    $f = Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object Extension -in '.cab', '.exe' | Select-Object -First 1
    if ($f) { return @{ Path = $f.FullName } }
    if (-not $Net -or $Hw.Make -notmatch 'Dell|HP|Hewlett|Lenovo') { return }
    $url = try { Find-Pack } catch { Write-Host "Ajuriluettelo: $_" -ForegroundColor Yellow }
    if (-not $url) { return Ev Ajuripaketti WARN 'Mallille ei löytynyt ajuripakettia – Windows Update hoitaa ajurit' }
    New-Item -ItemType Directory $dir -Force | Out-Null
    $path = Join-Path $dir (Split-Path $url -Leaf)
    @{ Path = $path; Task = (New-Object Net.WebClient).DownloadFileTaskAsync($url, "$path.part") }
}
function Add-Drivers($Win, $Dir) {
    if (Get-ChildItem $Dir -Filter *.inf -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) { dism.exe "/Image:$Win\" /Add-Driver "/Driver:$Dir" /Recurse | Out-Null; $true }
}

function Install($Disk) {
    $t0 = Get-Date
    $W, $B = @('W', 'S', 'T', 'U', 'V', 'R' | Where-Object { -not (Test-Path "${_}:\") })[0, 1]
    $Win = $script:Win = "${W}:"
    $dp = "select disk $($Disk.Number)", 'attributes disk clear readonly noerr', 'online disk noerr', 'clean'
    $dp += $(if ($Uefi) { 'convert gpt', 'create partition efi size=260', 'format quick fs=fat32', "assign letter=$B", 'create partition msr size=16' }
             else { 'convert mbr', 'create partition primary size=200', 'format quick fs=ntfs', 'active', "assign letter=$B" })
    $dp += 'create partition primary', 'format quick fs=ntfs label=Windows', "assign letter=$W"
    $dp | Set-Content X:\dp.txt -Encoding Ascii
    diskpart.exe /s X:\dp.txt | Out-Null
    if (-not (Test-Path "$Win\")) { throw 'Osiointi epäonnistui' }

    $pack = Start-Pack $Win
    $a = '/Apply-Image', "/ImageFile:$Img", '/Index:1', "/ApplyDir:$Win\"
    if ($Img -like '*.swm') { $a += "/SWMFile:$Root\Image\install*.swm" }
    dism.exe @a
    if ($LASTEXITCODE) { throw "DISM $LASTEXITCODE" }
    Ev Asennus OK "Windows kirjoitettu levylle $($Disk.FriendlyName) $([int]($Disk.Size / 1GB)) Gt"

    New-Item -ItemType Directory "$Win\W11AUTO\DriverPack", "$Win\Windows\Panther" -Force | Out-Null
    if ((Add-Drivers $Win "$Root\Drivers\_Kaikki") -or (Add-Drivers $Win "$Root\Drivers\$($Hw.Make)\$($Hw.Model)")) { Ev USB-ajurit OK 'Drivers-kansion ajurit lisätty' }
    if ($pack.Path) {
        try {
            if ($pack.Task) { Write-Host 'Odotetaan ajuripaketin latausta…'; $pack.Task.Wait(); Move-Item "$($pack.Path).part" $pack.Path -Force }
            if ($pack.Path -like '*.exe') { Copy-Item $pack.Path "$Win\W11AUTO\DriverPack\" }
            else {
                expand.exe $pack.Path -F:* "$Win\W11AUTO-x" | Out-Null
                if (Add-Drivers $Win "$Win\W11AUTO-x") { Ev Ajuripaketti OK (Split-Path $pack.Path -Leaf) }
                Remove-Item "$Win\W11AUTO-x" -Recurse -Force
            }
        } catch { Ev Ajuripaketti WARN "$(Split-Path $pack.Path -Leaf): $_" }
        Remove-Item "$Win\W11AUTO-pack" -Recurse -Force -ErrorAction SilentlyContinue
    }

    reg.exe load HKLM\W11SYS "$Win\Windows\System32\config\SYSTEM" | Out-Null
    reg.exe load HKLM\W11SW "$Win\Windows\System32\config\SOFTWARE" | Out-Null
    @(
        'W11SYS\ControlSet001\Control\BitLocker|PreventDeviceEncryption|1'
        'W11SYS\Setup\MoSetup|AllowUpgradesWithUnsupportedTPMOrCPU|1'
        'W11SW\Microsoft\Windows\CurrentVersion\Policies\System|EnableFirstLogonAnimation|0'
        'W11SW\Microsoft\Windows\CurrentVersion\OOBE|BypassNRO|1'
        'W11SW\Microsoft\WindowsUpdate\UX\Settings|AllowAutoWindowsUpdateDownloadOverMeteredNetwork|1'
    ) | ForEach-Object { $k, $v, $d = $_ -split '\|'; reg.exe add "HKLM\$k" /v $v /t REG_DWORD /d $d /f | Out-Null }
    [gc]::Collect()
    reg.exe unload HKLM\W11SW | Out-Null
    reg.exe unload HKLM\W11SYS | Out-Null

    Copy-Item "$Root\Windows\*", "$Root\config.json" "$Win\W11AUTO" -Recurse -Force
    Copy-Item "$Root\Windows\unattend.xml" "$Win\Windows\Panther\"
    if (-not $CpuOk) { Ev Suoritin FAIL 'Ei SSE4.2/POPCNT-tukea – Windows 11 24H2+ ei välttämättä käynnisty' }
    if ($Key) { Ev 'Emolevyn avain' OK 'Löytyi' } else { Ev 'Emolevyn avain' WARN 'Ei avainta – aktivointi vaatii digitaalisen lisenssin' }
    @{ Phase = 'updates'; Round = 0; Errors = 0; Crashes = 0; EditionTried = $false; Sysprep = $Sysprep; Started = $t0.ToString('o')
       Events = $Events; Installed = @(); Failed = @(); FailIds = @() } | ConvertTo-Json -Depth 5 | Set-Content "$Win\W11AUTO\state.json" -Encoding UTF8

    $bcd = "$Win\Windows", '/s', "${B}:", '/f', $(if ($Uefi) { 'UEFI' } else { 'BIOS' })
    if ($Uefi -and $Cfg.BootEx) { $bcd += '/offline', '/bootex' }
    bcdboot.exe @bcd
    if ($LASTEXITCODE) { throw "bcdboot $LASTEXITCODE" }
    reagentc.exe /setreimage /path "$Win\Windows\System32\Recovery" /target "$Win\Windows" | Out-Null
    Write-Host "`n  Valmis $([int]((Get-Date) - $t0).TotalMinutes) minuutissa." -ForegroundColor Green
}
function Save-Log($Win) {
    Stop-Transcript | Out-Null
    if ($Win) { New-Item -ItemType Directory "$Win\Windows\Logs\W11AUTO" -Force | Out-Null; Copy-Item X:\deploy.log "$Win\Windows\Logs\W11AUTO\" }
    if ($MediaDisk -ge 0) { New-Item -ItemType Directory "$Root\Logs" -Force | Out-Null; Copy-Item X:\deploy.log "$Root\Logs\$($Hw.Serial -replace '\W')-$(Get-Date -f yyyyMMdd-HHmm).log" }
}

$Sysprep = [bool]$Cfg.SysprepDefault
while ($true) {
    $Net = Test-Net
    $disks = @(Get-Disk | Where-Object { $_.Number -ne $MediaDisk -and $_.BusType -ne 'USB' -and $_.Size } | Sort-Object Number)
    Clear-Host
    Write-Host "`n  W11AUTO   $($Hw.Make) $($Hw.Model)   SN $($Hw.Serial)" -ForegroundColor White
    Write-Host "  $(if ($Uefi) { 'UEFI' } else { 'BIOS' })   verkko: $(if ($Net) { 'OK' } else { 'ei' })   emolevyn avain: $(if ($Key) { 'löytyi' } else { 'EI' })   sysprep: $(if ($Sysprep) { 'KYLLÄ' } else { 'ei' })"
    if (-not $CpuOk) { Write-Host '  SUORITIN EI TUE WINDOWS 11 24H2:TA (SSE4.2/POPCNT)' -ForegroundColor Red }
    if (-not $disks) { Write-Host "`n  Levyjä ei löytynyt: Intel VMD/RST-ajuri kansioon Drivers\WinPE tai VMD pois BIOSista." -ForegroundColor Red }
    foreach ($d in $disks) {
        $vols = (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue).FileSystemLabel -join ', '
        Write-Host ("  [{0}] {1}  {2} Gt  {3}  {4}" -f $d.Number, $d.FriendlyName, [int]($d.Size / 1GB), $d.BusType, $vols) -ForegroundColor Cyan
    }
    $in = (Read-Host "`n  Levyn numero | S = sysprep | Enter = päivitä | C = cmd | Q = sammuta").Trim().ToUpper()
    if ($in -eq 'S') { $Sysprep = -not $Sysprep; continue }
    if ($in -eq 'C') { Start-Process cmd.exe -Wait; continue }
    if ($in -eq 'Q') { wpeutil.exe shutdown }
    $d = $disks | Where-Object { "$($_.Number)" -eq $in }
    if (-not $d) { continue }
    Write-Host "`n  KAIKKI TIEDOT POISTETAAN: $($d.FriendlyName) $([int]($d.Size / 1GB)) Gt" -ForegroundColor Red
    if ((Read-Host '  Vahvista kirjoittamalla levyn numero uudelleen') -ne $in) { continue }
    $Win = $null
    try {
        Install $d
        Save-Log $Win
        if ($MediaDisk -lt 0) { Start-Sleep 10 }
        else {
            Write-Host "`n  >>> IRROTA USB-LEVY <<<  Kone käynnistyy uudelleen heti irrotuksen jälkeen (R = heti)." -ForegroundColor Yellow
            while ((Test-Path "$Media\") -and -not ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'R')) { Start-Sleep -Milliseconds 500 }
        }
        wpeutil.exe reboot
    } catch {
        Write-Host "`n  VIRHE: $_" -ForegroundColor Red
        Save-Log $null
        Start-Transcript X:\deploy.log -Append | Out-Null
        Read-Host '  Enter = takaisin valikkoon'
    }
}
