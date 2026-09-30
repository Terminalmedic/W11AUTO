# W11AUTO - sysprep-viimeistely. Ajetaan SYSTEM-tilillä käynnistyksessä (kukaan ei ole kirjautuneena):
# poistaa asennustilin User, siivoaa jäljet ja ajaa sysprep /oobe /shutdown -> asiakas luo oman tilinsä.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking
[void](Get-W11Config)   # luetaan muistiin ennen kuin config.json poistetaan (webhook virheilmoitusta varten)
$machine = Get-W11MachineInfo
$user = 'User'
Write-W11Log 'Finalize.ps1: sysprep-viimeistely alkaa'
Start-Sleep -Seconds 20   # annetaan palveluiden käynnistyä

function Restore-W11User {
    # Sysprep epäonnistui -> palautetaan tili, ettei kone jää ilman käyttäjää
    try {
        if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
            New-LocalUser -Name $user -NoPassword -AccountNeverExpires | Out-Null
            Set-LocalUser -Name $user -PasswordNeverExpires $true
            Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $user
        }
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty $wl -Name AutoAdminLogon -Value '1'
        Set-ItemProperty $wl -Name DefaultUserName -Value $user
        Set-ItemProperty $wl -Name DefaultPassword -Value ''
    } catch { Write-W11Log "Tilin palautus epäonnistui: $($_.Exception.Message)" 'ERROR' }
}

try {
    Unregister-ScheduledTask -TaskName 'W11AUTO-Finalize' -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'W11AUTO' -Confirm:$false -ErrorAction SilentlyContinue

    # Tilin ja profiilin poisto
    $sid = (Get-LocalUser -Name $user -ErrorAction SilentlyContinue).SID.Value
    if ($sid) {
        Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid } | Remove-CimInstance
        Remove-LocalUser -Name $user
        Write-W11Log "Tili $user ja profiili poistettu"
    }
    # Automaattikirjautuminen pois varmuudella
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $wl -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty $wl -Name DefaultPassword, DefaultUserName, AutoLogonCount -ErrorAction SilentlyContinue

    # TÄRKEÄ: vanha vastausmalli pois, muuten OOBE loisi taas tilin User ja ohittaisi asiakkaan näkymät
    Remove-Item "$env:SystemRoot\Panther\unattend.xml", "$env:SystemRoot\Panther\Unattend\unattend.xml",
        "$env:SystemRoot\System32\Sysprep\unattend.xml" -Force -ErrorAction SilentlyContinue
    & powercfg.exe -restoredefaultschemes | Out-Null

    # Asennustiedostot (sis. webhook) pois asiakkaan koneelta. Asetukset ovat jo muistissa.
    Remove-Item (Get-W11Root) -Recurse -Force -ErrorAction SilentlyContinue

    Write-W11Log 'Ajetaan sysprep /oobe /shutdown'
    $p = Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\sysprep.exe" -ArgumentList '/oobe', '/shutdown', '/quiet' -PassThru -Wait
    Start-Sleep -Seconds 90   # onnistuessa kone sammuu tämän aikana
    throw "sysprep palasi koodilla $($p.ExitCode) eikä kone sammunut"
}
catch {
    $err = $_.Exception.Message
    $log = "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log"
    if (Test-Path $log) { $err += ' | ' + ((Get-Content $log -Tail 5) -join ' / ') }
    Write-W11Log "Sysprep epäonnistui: $err" 'ERROR'
    Restore-W11User
    Send-W11Discord -Content ("{0} **Sysprep EPÄONNISTUI** – {1} {2} (SN {3}): {4}. Tili User palautettu." -f [char]::ConvertFromUtf32(0x274C), $machine.Manufacturer, $machine.Model, $machine.Serial, $err) | Out-Null
    Set-Content -Path "$env:PUBLIC\Desktop\SYSPREP EPÄONNISTUI.txt" -Value "Sysprep epäonnistui:`r`n$err`r`n`r`nLoki: $(Get-W11LogDir)" -Encoding UTF8
    Remove-Item (Get-W11Root) -Recurse -Force -ErrorAction SilentlyContinue
    & shutdown.exe /r /t 5 | Out-Null
}
