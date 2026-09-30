#Requires -RunAsAdministrator
# W11AUTO - pääohjaus työpöydällä. Käynnistyy ajastetusta tehtävästä jokaisella kirjautumisella,
# kunnes päivitykset on tehty ja raportti annettu.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Common', 'UI', 'Updates', 'Report') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") -Force -DisableNameChecking }

$mutex = New-Object Threading.Mutex($false, 'Global\W11AUTO')
if (-not $mutex.WaitOne(0)) { exit }

$cfg = Get-W11Config
$state = Get-W11State
$machine = Get-W11MachineInfo
Write-W11Log "Start.ps1: vaihe=$($state.Phase) kierros=$($state.Round)"

Add-Type -Namespace W11 -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'

function Restart-W11 {
    param([string]$Why)
    Write-W11Log "Uudelleenkäynnistys: $Why"
    Set-W11UIHeader -Title 'Käynnistetään uudelleen…' -Subtitle $Why -Action 'Jatkuu automaattisesti kirjautumisen jälkeen' -Busy $true
    Start-Sleep -Seconds 3
    & shutdown.exe /r /t 2 /f /c "W11AUTO: $Why" | Out-Null
    Start-Sleep -Seconds 120
    exit
}

# Odottaa kunnes laturi ja verkko ovat kunnossa. Palauttaa $false jos asentaja keskeyttää.
function Wait-W11Prerequisites {
    $since = Get-Date; $lastBeep = [datetime]::MinValue; $alerted = $false; $gateShown = $false
    while ($true) {
        $p = Test-W11Power
        $n = Test-W11Network
        Set-W11UIStep 'power' $p.Text $(if ($p.Ok) { 'OK' } else { 'FAIL' })
        Set-W11UIStep 'net' $n.Text $(if ($n.Ok) { 'OK' } else { 'FAIL' })
        if ($p.Ok -and $n.Ok) {
            if ($gateShown) { Set-W11UIButtons @() }
            return $true
        }
        if (Test-W11UIAbort) { return $false }

        if (-not $gateShown) {
            $gateShown = $true
            Set-W11UIButtons @(@{ Id = 'wifi'; Text = 'Valitse Wi-Fi-verkko' }, @{ Id = 'settings'; Text = 'Verkkoasetukset' })
        }
        $missing = @(); if (-not $p.Ok) { $missing += 'LATURI' }; if (-not $n.Ok) { $missing += 'NETTIYHTEYS' }
        Set-W11UIHeader -Title ("Kytke {0}" -f ($missing -join ' ja ')) -Color 'FAIL' -Subtitle 'Päivitykset alkavat automaattisesti heti kun molemmat ovat kunnossa.' -Action 'Odotetaan…' -Busy $false

        if (((Get-Date) - $lastBeep).TotalSeconds -ge 20) { Invoke-W11Beep; $lastBeep = Get-Date }
        if (-not $alerted -and ((Get-Date) - $since).TotalMinutes -ge $cfg.WaitAlertMinutes -and $n.Ok) {
            $alerted = Send-W11Discord -Content ("{0} Kone **{1} {2}** (SN {3}) odottaa: {4}" -f [char]::ConvertFromUtf32(0x1F50C), $machine.Manufacturer, $machine.Model, $machine.Serial, ($missing -join ' + '))
        }
        switch (Get-W11UIClick) {
            'wifi' { Start-Process 'ms-availablenetworks:' }
            'settings' { Start-Process 'ms-settings:network-wifi' }
        }
        Start-Sleep -Seconds 2
    }
}

# Emolevyn avain eri versiolle (esim. Pro) -> versionvaihto kerran ennen päivityksiä
function Invoke-W11EditionFix {
    if ($state.EditionChecked) { return }
    $lic = Get-W11LicenseInfo
    if ($lic.Key -and $lic.KeyEdition -and $lic.KeyEdition -ne $lic.Edition -and -not $state.EditionTried) {
        $state.EditionTried = $true; Save-W11State
        Add-W11Event 'Versio' 'INFO' "Emolevyn avain: $($lic.KeyEdition) – vaihdetaan versio ($($lic.Edition) -> $($lic.KeyEdition))"
        Set-W11UIHeader -Title "Vaihdetaan Windows-versio: $($lic.KeyEdition)" -Subtitle 'Emolevyn lisenssi on eri versiolle' -Action 'Kone käynnistyy uudelleen…' -Busy $true
        Start-Process -FilePath "$env:SystemRoot\System32\changepk.exe" -ArgumentList "/ProductKey $($lic.Key)" -Wait:$false
        Start-Sleep -Seconds 240   # changepk käynnistää koneen yleensä itse
        Restart-W11 'Versionvaihto'
    }
    $lic = Get-W11LicenseInfo
    if ($lic.Key -and $lic.KeyEdition -and $lic.KeyEdition -ne $lic.Edition) {
        Add-W11Event 'Versio' 'FAIL' "Versionvaihto epäonnistui: avain on $($lic.KeyEdition), asennettu $($lic.Edition). Asenna uudelleen versiolla $($lic.KeyEdition) (WinPE-valikko V)."
    } elseif ($state.EditionTried) {
        Add-W11Event 'Versio' 'OK' "Versio vaihdettu: $($lic.Edition)"
    }
    $state.EditionChecked = $true; Save-W11State
}

function Complete-W11Cleanup {
    # Poistetaan automaattikirjautuminen, tehtävä, virta-asetukset ja asennustiedostot (sis. webhookin)
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $wl -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty $wl -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'W11AUTO' -Confirm:$false -ErrorAction SilentlyContinue
    & powercfg.exe -restoredefaultschemes | Out-Null
    Remove-Item "$env:SystemRoot\Panther\unattend.xml", "$env:SystemRoot\Panther\Unattend\unattend.xml" -Force -ErrorAction SilentlyContinue
    Start-Process cmd.exe -ArgumentList "/c timeout /t 8 /nobreak >nul & rmdir /s /q `"$(Get-W11Root)`"" -WindowStyle Hidden
}

function Start-W11SysprepFinalize {
    # Sysprep ajetaan SYSTEM-tilillä seuraavalla käynnistyksellä, kun User ei ole kirjautuneena
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path (Get-W11Root) 'Finalize.ps1')`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName 'W11AUTO-Finalize' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Unregister-ScheduledTask -TaskName 'W11AUTO' -Confirm:$false -ErrorAction SilentlyContinue
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $wl -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty $wl -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
    $state.Phase = 'sysprep'; Save-W11State
    Restart-W11 'Sysprep valmistellaan – kone sammuu itsestään'
}

# ------------------------------------------------------------------------------------------
Start-W11UI | Out-Null
Set-W11Volume $cfg.SoundVolumePercent
[void][W11.Power]::SetThreadExecutionState(0x80000003)   # ES_CONTINUOUS | SYSTEM | DISPLAY
foreach ($a in 'standby-timeout-ac', 'monitor-timeout-ac', 'hibernate-timeout-ac') { & powercfg.exe /change $a 0 | Out-Null }
if (-not $state.RunStarted) { $state.RunStarted = (Get-Date).ToString('o'); Save-W11State }

$sub = "$($machine.Manufacturer) $($machine.Model)  |  SN $($machine.Serial)"
Set-W11UIHeader -Title 'W11AUTO käynnistyy…' -Subtitle $sub -Busy $true

try {
    if ($state.Phase -eq 'updates') {
        if (-not (Wait-W11Prerequisites)) { throw [OperationCanceledException]::new('Asentaja keskeytti') }
        Set-W11UIHeader -Title 'Päivitetään Windowsia' -Color $null -Subtitle $sub

        Invoke-W11EditionFix
        if (-not $state.ActivationTried) {
            Set-W11UIHeader -Action 'Aktivoidaan Windows…'
            $act = Invoke-W11Activation
            Add-W11Event 'Aktivointi' $act.Status $act.Text
            $state.ActivationTried = $true; Save-W11State
        }

        while ($true) {
            if (Test-W11UIAbort) { throw [OperationCanceledException]::new('Asentaja keskeytti') }
            if ($state.Round -ge $cfg.MaxUpdateRounds) {
                Add-W11Event 'Päivitykset' 'WARN' "Kierrosraja ($($cfg.MaxUpdateRounds)) täyttyi – kaikki päivitykset eivät välttämättä asentuneet"
                break
            }
            Set-W11UIHeader -Title ("Päivitetään Windowsia – kierros {0}" -f ($state.Round + 1))
            Set-W11UIStep 'wu' ("Asennettu tähän mennessä: {0} päivitystä" -f @($state.Installed).Count) 'RUN'

            try { $r = Invoke-W11UpdateRound -State $state }
            catch {
                # Verkko katkesi tms. -> takaisin vahtiin, sitten uusi yritys
                Write-W11Log "Kierros keskeytyi: $($_.Exception.Message)" 'WARN'
                $state.RoundErrors = [int]$state.RoundErrors + 1; Save-W11State
                if ($state.RoundErrors -ge 5) { Add-W11Event 'Päivitykset' 'FAIL' "Windows Update virhe: $($_.Exception.Message)"; break }
                if (-not (Wait-W11Prerequisites)) { throw [OperationCanceledException]::new('Asentaja keskeytti') }
                continue
            }
            if ($r.Status -eq 'Done') { break }
            $state.Round = [int]$state.Round + 1; Save-W11State
            if ($r.Status -eq 'Reboot') {
                # Tarkista laturi vielä ennen uudelleenkäynnistystä (firmware-päivitykset!)
                if (-not (Wait-W11Prerequisites)) { throw [OperationCanceledException]::new('Asentaja keskeytti') }
                Restart-W11 ("Päivitykset vaativat uudelleenkäynnistyksen (kierros {0})" -f $state.Round)
            }
        }

        if (-not ($state.Events | Where-Object { $_.Area -eq 'Päivitykset' })) {
            $st = if ($state.FailedTitles.Count) { 'WARN' } else { 'OK' }
            $txt = "{0} päivitystä asennettu {1} kierroksella, ei jäljellä olevia" -f @($state.Installed).Count, $state.Round
            if ($state.FailedTitles.Count) { $txt += "; $($state.FailedTitles.Count) epäonnistui toistuvasti" }
            Add-W11Event 'Päivitykset' $st $txt
        }
        Set-W11UIStep 'wu' ("Windows Update valmis: {0} päivitystä" -f @($state.Installed).Count) 'OK'
        Set-W11UIStep 'wu-list' '' 'INFO'

        $extras = Update-W11Extras -IncludeStore (-not $state.Sysprep)
        foreach ($k in $extras.Keys) { Add-W11Event $k $extras[$k].Status $extras[$k].Text }
        $state.Phase = 'report'; Save-W11State
    }
}
catch [OperationCanceledException] {
    Add-W11Event 'Keskeytys' 'FAIL' 'Asentaja keskeytti W11AUTO:n (Ctrl+Shift+Q)'
    $state.Phase = 'report'; Save-W11State
}
catch {
    Write-W11Log "Odottamaton virhe: $($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)" 'ERROR'
    $state.Crashes = [int]$state.Crashes + 1; Save-W11State
    if ($state.Crashes -lt 3) { Restart-W11 'Odottamaton virhe – yritetään uudelleen' }
    Add-W11Event 'Skripti' 'FAIL' "Odottamaton virhe 3 kertaa: $($_.Exception.Message)"
    $state.Phase = 'report'; Save-W11State
}

# ---------------- Raportti ja lopetus ----------------
if ($state.Phase -eq 'report') {
    Clear-W11UISteps
    Set-W11UIHeader -Title 'Viimeistellään…' -Action 'Tarkistetaan aktivointi, ajurit, akku ja levy' -Busy $true
    $act = Invoke-W11Activation
    Add-W11Event 'Aktivointi' $act.Status $act.Text
    Invoke-W11HealthChecks -Machine $machine
    $rep = New-W11Report -Machine $machine
    $sent = Send-W11Discord -Embed $rep.Embed -AttachmentPath $rep.Path
    Write-W11Log "Raportti: $($rep.Path) (Discord: $sent)"

    foreach ($e in (Get-W11State).Events) {
        $ui = if ($e.Status -eq 'INFO') { 'INFO' } else { $e.Status }
        Set-W11UIStep $e.Area "$($e.Area): $($e.Text)" $ui
    }
    $color = @{ OK = 'OK'; WARN = 'WARN'; FAIL = 'FAIL' }[$rep.Overall]
    $discordNote = if ([string]::IsNullOrWhiteSpace($cfg.DiscordWebhook)) { 'Discord ei käytössä' } elseif ($sent) { 'Raportti lähetetty Discordiin' } else { 'Discord-lähetys EPÄONNISTUI' }
    Set-W11UIHeader -Title $rep.Headline -Color $color -Subtitle "$sub  |  $discordNote" -Busy $false `
        -Action $(if ($state.Sysprep) { 'Sysprep valittu: asiakas luo oman tilinsä ensimmäisellä käynnistyksellä.' } else { 'Kone jää käyttövalmiiksi tilille User.' })
    Invoke-W11Beep

    $buttons = @(
        @{ Id = 'sysprep'; Text = 'Sysprep ja sammuta' },
        @{ Id = 'done'; Text = 'Valmis (ei sysprepiä)' },
        @{ Id = 'open'; Text = 'Avaa raportti' }
    )
    # Automaattinen jatko vain jos ei virheitä; virheiden kanssa odotetaan asentajaa
    $default = if ($state.Sysprep) { 'sysprep' } else { 'done' }
    $timeout = if ($rep.Overall -eq 'FAIL') { 0 } else { [int]$cfg.FinalCountdownSec }
    do {
        $choice = Wait-W11UIButton -Buttons $buttons -TimeoutSec $timeout -DefaultId $default
        if ($choice -eq 'open') { Start-Process $rep.Path; $timeout = 0 }
    } while ($choice -eq 'open')

    $state.ReportPath = $rep.Path
    if ($choice -eq 'sysprep') { $state.Sysprep = $true; Save-W11State; Start-W11SysprepFinalize }
    $state.Phase = 'done'; Save-W11State
    Set-W11UIHeader -Title 'Valmis' -Color 'OK' -Action "Raportti: $($rep.Path)" -Busy $false
    Complete-W11Cleanup
    Start-Sleep -Seconds 2
    Stop-W11UI
}
elseif ($state.Phase -eq 'done') {
    Complete-W11Cleanup
}
