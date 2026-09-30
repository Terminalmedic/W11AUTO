param([ValidateSet('Run', 'Specialize', 'Finalize')][string]$Mode = 'Run')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$Root = "$env:SystemDrive\W11AUTO"
$LogDir = "$env:SystemRoot\Logs\W11AUTO"
$Winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
New-Item -ItemType Directory $LogDir -Force | Out-Null
$Cfg = Get-Content "$Root\config.json" -Raw | ConvertFrom-Json
$S = Get-Content "$Root\state.json" -Raw | ConvertFrom-Json

function Log($m) { Add-Content "$LogDir\W11AUTO.log" "$(Get-Date -f s) $m" -Encoding UTF8 }
function Save { $S | ConvertTo-Json -Depth 5 | Set-Content "$Root\state.json" -Encoding UTF8 }
function Ev($Area, $Status, $Text) {
    $e = $S.Events | Where-Object Area -eq $Area
    if ($e) { $e.Status = $Status; $e.Text = $Text } else { $S.Events = @($S.Events) + [pscustomobject]@{ Area = $Area; Status = $Status; Text = $Text } }
    Save; Log "$Area [$Status] $Text"
}
function Show($Title, $Color, $Lines) {
    Clear-Host
    Write-Host "`n  $Title" -ForegroundColor $Color
    Write-Host "  $Machine`n" -ForegroundColor DarkGray
    $Lines | ForEach-Object { Write-Host "  $_" }
}
function Read-Key($Sec) {
    $end = (Get-Date).AddSeconds($Sec)
    while ($Sec -lt 0 -or (Get-Date) -lt $end) {
        if ([Console]::KeyAvailable) { return [Console]::ReadKey($true).Key.ToString() }
        Start-Sleep -Milliseconds 200
    }
}
function Discord($Body) {
    if (-not $Cfg.DiscordWebhook) { return $false }
    try { Invoke-RestMethod $Cfg.DiscordWebhook -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5))) | Out-Null; $true }
    catch { Log "Discord: $_"; $false }
}
function Restart($Why) { Log "Restart: $Why"; Show 'Käynnistetään uudelleen…' Cyan $Why; shutdown.exe /r /t 5 /f | Out-Null; exit }
function Disable-AutoLogon {
    Set-ItemProperty $Winlogon AutoAdminLogon '0'
    Remove-ItemProperty $Winlogon DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
    powercfg.exe -restoredefaultschemes
    Remove-Item "$env:SystemRoot\Panther\unattend.xml" -Force -ErrorAction SilentlyContinue
}
function Register-Task($Name, $ModeArg, $Trigger, $Principal) {
    $a = New-ScheduledTaskAction powershell.exe "-NoProfile -ExecutionPolicy Bypass -WindowStyle Maximized -File `"$Root\W11AUTO.ps1`" $ModeArg"
    $t = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
    Register-ScheduledTask $Name -Action $a -Trigger $Trigger -Principal $Principal -Settings $t -Force | Out-Null
}

if ($Mode -eq 'Specialize') {
    $exe = Get-ChildItem "$Root\DriverPack" -Filter *.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) {
        $x = "$Root\DriverPack\x"
        $argList = if ((Get-CimInstance Win32_ComputerSystem).Manufacturer -match 'Lenovo') { "/VERYSILENT /DIR=`"$x`" /EXTRACT=YES" } else { "/s /e /f `"$x`"" }
        Start-Process $exe.FullName $argList -Wait
        $n = @(Get-ChildItem $x -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count
        if ($n) { pnputil.exe /add-driver "$x\*.inf" /subdirs /install | Out-Null; Ev Ajuripaketti OK "$($exe.Name): $n ajuria" }
        else { Ev Ajuripaketti WARN "$($exe.Name) ei purkautunut – Windows Update hoitaa ajurit" }
        Remove-Item "$Root\DriverPack" -Recurse -Force
    }
    Register-Task W11AUTO '' (New-ScheduledTaskTrigger -AtLogOn) (New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest)
    return
}

$sn = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
$cs = Get-CimInstance Win32_ComputerSystem
$Machine = "$($cs.Manufacturer) $($cs.Model) | SN $sn"

if ($Mode -eq 'Finalize') {
    Start-Sleep 20
    try {
        Unregister-ScheduledTask W11AUTO-Finalize -Confirm:$false
        $u = Get-LocalUser User -ErrorAction SilentlyContinue
        if ($u) { Get-CimInstance Win32_UserProfile | Where-Object SID -eq $u.SID.Value | Remove-CimInstance; Remove-LocalUser User }
        Disable-AutoLogon
        Remove-Item $Root -Recurse -Force
        $p = Start-Process "$env:SystemRoot\System32\Sysprep\sysprep.exe" '/oobe /shutdown /quiet' -Wait -PassThru
        Start-Sleep 90
        throw "sysprep $($p.ExitCode)"
    } catch {
        $err = "$_ $(Get-Content "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log" -Tail 3 -ErrorAction SilentlyContinue)"
        Log "Sysprep epäonnistui: $err"
        New-LocalUser User -NoPassword | Out-Null
        Add-LocalGroupMember -SID S-1-5-32-544 -Member User
        Set-ItemProperty $Winlogon AutoAdminLogon '1'; Set-ItemProperty $Winlogon DefaultUserName User; Set-ItemProperty $Winlogon DefaultPassword ''
        Discord @{ content = "❌ **Sysprep epäonnistui** – $Machine`n$err" } | Out-Null
        shutdown.exe /r /t 5
    }
    return
}

$w = New-Object -ComObject WScript.Shell
1..50 | ForEach-Object { $w.SendKeys([char]174) }
1..12 | ForEach-Object { $w.SendKeys([char]175) }
'standby-timeout-ac', 'monitor-timeout-ac', 'hibernate-timeout-ac' | ForEach-Object { powercfg.exe /change $_ 0 }

function Test-Power {
    $b = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue)
    -not $b -or $b.PowerOnline -contains $true
}
function Test-Net {
    try {
        $r = Invoke-WebRequest http://www.msftconnecttest.com/connecttest.txt -UseBasicParsing -TimeoutSec 5
        if ($r.Content -notmatch 'Microsoft Connect Test') { return $false }
        $t = [datetime]$r.Headers.Date
        if ([Math]::Abs(((Get-Date) - $t).TotalMinutes) -gt 5) { Set-Date $t | Out-Null }
        try { Invoke-WebRequest https://sls.update.microsoft.com -UseBasicParsing -TimeoutSec 8 | Out-Null } catch { if (-not $_.Exception.Response) { throw } }
        $true
    } catch { $false }
}
function Wait-Ready {
    $since = Get-Date; $alerted = $false
    while ($true) {
        $p = Test-Power; $n = Test-Net
        if ($p -and $n) { return }
        $miss = @(); if (-not $p) { $miss += 'LATURI' }; if (-not $n) { $miss += 'NETTIYHTEYS' }
        Show "KYTKE $($miss -join ' JA ')" Red 'Jatkuu automaattisesti, kun molemmat ovat kunnossa.', '', 'W = valitse Wi-Fi   Q = keskeytä'
        [Media.SystemSounds]::Asterisk.Play()
        if (-not $alerted -and $n -and ((Get-Date) - $since).TotalMinutes -ge 5) { $alerted = Discord @{ content = "🔌 $Machine odottaa: $($miss -join ' + ')" } }
        switch (Read-Key 20) { 'W' { Start-Process ms-availablenetworks: } 'Q' { throw 'Keskeytetty' } }
    }
}
function Update-Round {
    $ses = New-Object -ComObject Microsoft.Update.Session
    $todo = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $ses.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0').Updates) {
        $id = $u.Identity.UpdateID
        if ($u.BrowseOnly -or @($u.Categories | Where-Object CategoryID -eq '3689bdc8-b205-4af4-8d4a-a63924c5e9d5').Count -or @($S.FailIds -eq $id).Count -ge 2) { continue }
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$todo.Add($u)
    }
    if (-not $todo.Count) { return $(if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { 'Reboot' } else { 'Done' }) }
    $titles = foreach ($u in $todo) { $u.Title }
    Show "Päivitetään – kierros $($S.Round + 1)" Cyan (@("Asennettu tähän mennessä: $(@($S.Installed).Count)", '', "Ladataan ja asennetaan $($todo.Count):") + $titles + '', 'Älä sammuta konetta.')
    $d = $ses.CreateUpdateDownloader(); $d.Priority = 3; $d.Updates = $todo; [void]$d.Download()
    $ok = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $todo) { if ($u.IsDownloaded) { [void]$ok.Add($u) } else { $S.FailIds += $u.Identity.UpdateID } }
    if (-not $ok.Count) { Save; return 'Again' }
    $i = $ses.CreateUpdateInstaller(); $i.ForceQuiet = $true; $i.Updates = $ok
    $r = $i.Install()
    for ($k = 0; $k -lt $ok.Count; $k++) {
        $u = $ok.Item($k)
        if ($r.GetUpdateResult($k).ResultCode -in 2, 3) { $S.Installed += $u.Title; continue }
        $S.FailIds += $u.Identity.UpdateID
        if (@($S.FailIds -eq $u.Identity.UpdateID).Count -eq 2) { $S.Failed += $u.Title }
    }
    Save
    if ($r.RebootRequired) { 'Reboot' } else { 'Again' }
}
function Get-License {
    $svc = Get-CimInstance SoftwareLicensingService
    [pscustomobject]@{
        Svc = $svc; Key = $svc.OA3xOriginalProductKey
        KeyEd = if ($svc.OA3xOriginalProductKeyDescription -match '\]\s*(\w+)') { $Matches[1] }
        Ed = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    }
}
function Test-Activation {
    $l = Get-License
    if ($l.KeyEd -and $l.KeyEd -ne $l.Ed) { return Ev Aktivointi FAIL "Emolevyn avain on $($l.KeyEd), asennettu $($l.Ed) – versionvaihto epäonnistui" }
    if ($l.Key) { try { Invoke-CimMethod $l.Svc InstallProductKey @{ ProductKey = $l.Key } | Out-Null } catch { Log $_ } }
    $q = { Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1 }
    $p = & $q
    if ($p.LicenseStatus -ne 1) { try { Invoke-CimMethod $p Activate | Out-Null } catch { Log $_ }; $p = & $q }
    if ($p.LicenseStatus -eq 1) { Ev Aktivointi OK 'Aktivoitu' }
    elseif ($l.Key) { Ev Aktivointi FAIL 'EI AKTIVOITU, vaikka emolevyn avain löytyi – yritä myöhemmin (Asetukset > Aktivointi)' }
    else { Ev Aktivointi FAIL 'EI AKTIVOITU – ei emolevyn avainta eikä digitaalista lisenssiä, tarvitaan tuoteavain' }
}
function Test-Health {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Ev Windows INFO "$($cv.EditionID) $($cv.DisplayVersion) ($($cv.CurrentBuild).$($cv.UBR)) | $((Get-CimInstance Win32_Processor).Name.Trim()) | $([Math]::Round($cs.TotalPhysicalMemory / 1GB)) Gt"
    $tpm = (Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion -like '2.0*'
    $sb = try { Confirm-SecureBootUEFI } catch { $false }
    if ($tpm -and $sb) { Ev Laitteisto OK 'TPM 2.0 ja Secure Boot' } else { Ev Laitteisto WARN "Ei virallisesti tuettu (TPM 2.0: $tpm, Secure Boot: $sb) – versiopäivitykset eivät välttämättä tule" }
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 22 })
    if ($bad) { Ev Ajurit WARN "$($bad.Count) laitetta ilman ajuria: $(($bad.Name | Select-Object -First 5) -join '; ')" } else { Ev Ajurit OK 'Kaikilla laitteilla ajuri' }
    $des = (Get-CimInstance -Namespace root/wmi BatteryStaticData -ErrorAction SilentlyContinue | Measure-Object DesignedCapacity -Sum).Sum
    if ($des) {
        $pct = [int](100 * (Get-CimInstance -Namespace root/wmi BatteryFullChargedCapacity | Measure-Object FullChargedCapacity -Sum).Sum / $des)
        Ev Akku $(if ($pct -lt 60) { 'FAIL' } elseif ($pct -lt 80) { 'WARN' } else { 'OK' }) "Kunto $pct %"
    }
    $pd = Get-PhysicalDisk | Where-Object DeviceId -eq "$((Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber)"
    $wear = ($pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue).Wear
    Ev Levy $(if ($pd.HealthStatus -ne 'Healthy') { 'FAIL' } elseif ($wear -ge 80) { 'WARN' } else { 'OK' }) "$($pd.FriendlyName) $([int]($pd.Size / 1GB)) Gt, $($pd.HealthStatus), kuluma $wear %"
}

$Host.UI.RawUI.WindowTitle = 'W11AUTO'
try {
    if ($S.Phase -eq 'updates') {
        Wait-Ready
        $l = Get-License
        if ($l.KeyEd -and $l.KeyEd -ne $l.Ed -and -not $S.EditionTried) {
            $S.EditionTried = $true; Save
            Show "Vaihdetaan versio: $($l.Ed) -> $($l.KeyEd)" Cyan 'Emolevyn lisenssi on eri versiolle.'
            Start-Process changepk.exe "/ProductKey $($l.Key)"
            Start-Sleep 240
            Restart 'Versionvaihto'
        }
        while ($S.Round -lt 12) {
            if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Q') { throw 'Keskeytetty' }
            try { $r = Update-Round }
            catch {
                Log "Kierros: $_"; $S.Errors++; Save
                if ($S.Errors -ge 5) { Ev Päivitykset FAIL "Windows Update: $_"; break }
                Start-Sleep 30; Wait-Ready; continue
            }
            if ($r -eq 'Done') { break }
            $S.Round++; Save
            if ($r -eq 'Reboot') { Wait-Ready; Restart "Päivityskierros $($S.Round)" }
        }
        if (-not ($S.Events | Where-Object Area -eq Päivitykset)) {
            $st = if ($S.Failed -or $S.Round -ge 12) { 'WARN' } else { 'OK' }
            Ev Päivitykset $st "$(@($S.Installed).Count) asennettu $($S.Round) kierroksella$(if ($S.Failed) { ", epäonnistui: $($S.Failed -join '; ')" })"
        }
        Show 'Viimeistellään…' Cyan 'Defender, Store, aktivointi, kuntotarkistus'
        try { Update-MpSignature -UpdateSource MicrosoftUpdateServer; Ev Defender OK 'Virusmääritykset päivitetty' } catch { Ev Defender WARN "$_" }
        if (-not $S.Sysprep) { Get-CimInstance -Namespace root/cimv2/mdm/dmmap MDM_EnterpriseModernAppManagement_AppManagement01 -ErrorAction SilentlyContinue | Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction SilentlyContinue | Out-Null }
        $S.Phase = 'report'; Save
    }
} catch {
    if ("$_" -eq 'Keskeytetty') { Ev Keskeytys FAIL 'Asentaja keskeytti' }
    else {
        Log "Virhe: $_ $($_.InvocationInfo.PositionMessage)"; $S.Crashes++; Save
        if ($S.Crashes -lt 3) { Restart 'Odottamaton virhe, yritetään uudelleen' }
        Ev Skripti FAIL "$_"
    }
    $S.Phase = 'report'; Save
}

Test-Activation
Test-Health
$icon = @{ OK = '✅'; WARN = '⚠️'; FAIL = '❌'; INFO = 'ℹ️' }
$overall = if ($S.Events.Status -contains 'FAIL') { 'FAIL' } elseif ($S.Events.Status -contains 'WARN') { 'WARN' } else { 'OK' }
$head = @{ OK = 'VALMIS – kaikki kunnossa'; WARN = 'VALMIS – tarkista huomiot'; FAIL = 'VALMIS – VIRHEITÄ' }[$overall]
$lines = foreach ($e in $S.Events) { "$($icon[$e.Status]) $($e.Area): $($e.Text)" }
$dur = '{0:%h} h {0:%m} min' -f ((Get-Date) - [datetime]$S.Started)
$report = "$LogDir\raportti-$($sn -replace '\W')-$(Get-Date -f yyyyMMdd-HHmm).txt"
($head, $Machine, "Kesto $dur", '') + $lines + ('', 'Asennetut päivitykset:') + $S.Installed | Set-Content $report -Encoding UTF8
$sent = Discord @{ embeds = @(@{
    title = "$($icon[$overall]) $head"; description = "**$Machine** · $dur`n`n$($lines -join "`n")"
    color = @{ OK = 0x1E9E5A; WARN = 0xE0A000; FAIL = 0xD13438 }[$overall] }) }

$sysprepDefault = [bool]$S.Sysprep
Show $head @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$overall] ($lines + '', "Discord: $(if ($sent) { 'lähetetty' } else { 'ei lähetetty' })   Raportti: $report", '',
    "S = sysprep ja sammuta   V = valmis (tili User)   R = avaa raportti$(if ($overall -ne 'FAIL') { "   (oletus $(if ($sysprepDefault) { 'S' } else { 'V' }) 2 min kuluttua)" })")
[Media.SystemSounds]::Asterisk.Play()
$sec = if ($overall -eq 'FAIL') { -1 } else { 120 }
do {
    $k = Read-Key $sec
    if ($k -eq 'R') { notepad.exe $report; $sec = -1 }
} until ($k -in 'S', 'V' -or $null -eq $k)
if ($null -eq $k) { $k = if ($sysprepDefault) { 'S' } else { 'V' } }

Unregister-ScheduledTask W11AUTO -Confirm:$false -ErrorAction SilentlyContinue
if ($k -eq 'S') {
    Register-Task W11AUTO-Finalize '-Mode Finalize' (New-ScheduledTaskTrigger -AtStartup) (New-ScheduledTaskPrincipal -UserId S-1-5-18 -RunLevel Highest)
    Set-ItemProperty $Winlogon AutoAdminLogon '0'
    Restart 'Sysprep – kone sammuu itsestään'
}
Disable-AutoLogon
Start-Process cmd.exe "/c timeout /t 5 >nul & rmdir /s /q `"$Root`"" -WindowStyle Hidden
