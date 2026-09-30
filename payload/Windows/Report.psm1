# W11AUTO - lisenssi/aktivointi, kuntotarkistukset ja loppuraportti (HTML + Discord)

$script:WinAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'

function Get-W11LicenseInfo {
    $svc = Get-CimInstance SoftwareLicensingService
    $desc = [string]$svc.OA3xOriginalProductKeyDescription
    $keyEdition = if ($desc -match '\]\s*([A-Za-z]+)') { $Matches[1] } else { $null }
    @{
        Key        = [string]$svc.OA3xOriginalProductKey
        KeyEdition = $keyEdition
        Edition    = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    }
}

function Get-W11WindowsProduct {
    Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='$script:WinAppId' AND PartialProductKey IS NOT NULL" |
        Where-Object { $_.Name -like 'Windows*' } | Select-Object -First 1
}

# Asentaa emolevyn avaimen (jos versio täsmää) ja yrittää aktivoida. Palauttaa @{Status; Text}
function Invoke-W11Activation {
    $lic = Get-W11LicenseInfo
    $keyNote = ''
    if ($lic.Key) {
        if ($lic.KeyEdition -and $lic.KeyEdition -ne $lic.Edition) {
            return @{ Status = 'FAIL'; Text = "Emolevyn avain on '$($lic.KeyEdition)', mutta asennettu versio on '$($lic.Edition)'. Asenna uudelleen oikealla versiolla." }
        }
        try {
            $svc = Get-CimInstance SoftwareLicensingService
            Invoke-CimMethod -InputObject $svc -MethodName InstallProductKey -Arguments @{ ProductKey = $lic.Key } | Out-Null
            Invoke-CimMethod -InputObject $svc -MethodName RefreshLicenseStatus | Out-Null
            $keyNote = ' (emolevyn avain)'
        } catch { Write-W11Log "Emolevyn avaimen asennus epäonnistui: $($_.Exception.Message)" 'WARN' }
    }
    $p = Get-W11WindowsProduct
    if ($p -and $p.LicenseStatus -ne 1) {
        try { Invoke-CimMethod -InputObject $p -MethodName Activate -ErrorAction Stop | Out-Null } catch {
            Write-W11Log "Aktivointi: $($_.Exception.Message)" 'WARN'
        }
        Start-Sleep -Seconds 2
        $p = Get-W11WindowsProduct
    }
    if ($p -and $p.LicenseStatus -eq 1) {
        $how = if ($lic.Key) { $keyNote } elseif ($p.ProductKeyChannel -eq 'Retail' -or $p.Description -match 'RETAIL') { ' (digitaalinen lisenssi)' } else { '' }
        return @{ Status = 'OK'; Text = "Aktivoitu$how" }
    }
    if (-not $lic.Key) {
        return @{ Status = 'FAIL'; Text = 'EI AKTIVOITU – koneessa ei ole emolevyn avainta eikä digitaalista lisenssiä. Tarvitaan tuoteavain.' }
    }
    @{ Status = 'FAIL'; Text = "EI AKTIVOITU, vaikka emolevyn avain löytyi (tila $($p.LicenseStatus)). Yritä myöhemmin uudelleen: Asetukset > Aktivointi." }
}

function Invoke-W11HealthChecks {
    param([hashtable]$Machine)

    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Add-W11Event 'Windows' 'INFO' ("{0} {1} (koontiversio {2}.{3})" -f $cv.ProductName.Replace('Windows 10', 'Windows 11'), $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
    Add-W11Event 'Kone' 'INFO' ("{0} {1} | SN {2} | {3} | {4} Gt RAM | BIOS {5}" -f $Machine.Manufacturer, $Machine.Model, $Machine.Serial, $Machine.Cpu, $Machine.RamGB, $Machine.Bios)

    # Laitteisto vs. Windows 11 -vaatimukset (asennus ohittaa ne – tämä kertoo asiakkaalle)
    $notes = @()
    try {
        $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        if (-not $tpm -or -not ($tpm.SpecVersion -like '2.0*')) { $notes += 'ei TPM 2.0:aa' }
    } catch { $notes += 'ei TPM:ää' }
    try { if (-not (Confirm-SecureBootUEFI -ErrorAction Stop)) { $notes += 'Secure Boot pois päältä' } } catch { $notes += 'ei UEFI/Secure Bootia' }
    if ($Machine.RamGB -lt 4) { $notes += "vain $($Machine.RamGB) Gt RAM" }
    if ($notes) { Add-W11Event 'Laitteistovaatimukset' 'WARN' ("Ei virallisesti tuettu: {0}. Versiopäivitykset eivät välttämättä tule automaattisesti." -f ($notes -join ', ')) }
    else { Add-W11Event 'Laitteistovaatimukset' 'OK' 'TPM 2.0 ja Secure Boot OK' }

    # Laitteet ilman ajuria
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 })
    if ($bad.Count -eq 0) { Add-W11Event 'Ajurit' 'OK' 'Kaikilla laitteilla on toimiva ajuri' }
    else {
        $names = ($bad | Select-Object -First 6 | ForEach-Object { if ($_.Name) { $_.Name } else { $_.DeviceID } }) -join '; '
        Add-W11Event 'Ajurit' 'WARN' ("{0} laitetta ilman toimivaa ajuria: {1}" -f $bad.Count, $names)
    }

    # Akku
    try {
        $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Measure-Object DesignedCapacity -Sum).Sum
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Measure-Object FullChargedCapacity -Sum).Sum
        if ($design -gt 0) {
            $pct = [int](100 * $full / $design)
            $st = if ($pct -lt 60) { 'FAIL' } elseif ($pct -lt 80) { 'WARN' } else { 'OK' }
            Add-W11Event 'Akku' $st "Akun kunto $pct % alkuperäisestä ($full / $design mWh)"
        }
    } catch { }

    # Järjestelmälevy
    try {
        $part = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
        $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
        $rc = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $txt = "{0} {1} Gt, kunto: {2}" -f $pd.FriendlyName, [int]($pd.Size / 1GB), $pd.HealthStatus
        if ($rc -and $null -ne $rc.Wear) { $txt += ", kuluma $($rc.Wear) %" }
        if ($rc -and $rc.Temperature) { $txt += ", $($rc.Temperature) °C" }
        $st = if ($pd.HealthStatus -ne 'Healthy') { 'FAIL' } elseif ($rc -and $rc.Wear -ge 80) { 'WARN' } else { 'OK' }
        Add-W11Event 'Levy' $st $txt
    } catch { }

    # BitLocker / laitesalaus ei saa olla päällä
    try {
        $bl = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
        if ($bl -and $bl.ProtectionStatus -eq 1) { Add-W11Event 'Salaus' 'WARN' 'Laitesalaus on päällä – tarkista palautusavain!' }
        else { Add-W11Event 'Salaus' 'OK' 'BitLocker/laitesalaus pois päältä' }
    } catch { }
}

function Get-W11Overall {
    $ev = @((Get-W11State).Events)
    if ($ev | Where-Object { $_.Status -eq 'FAIL' }) { return 'FAIL' }
    if ($ev | Where-Object { $_.Status -eq 'WARN' }) { return 'WARN' }
    'OK'
}

function New-W11Report {
    param([hashtable]$Machine)
    $s = Get-W11State
    $overall = Get-W11Overall
    $start = if ($s.DeployStarted) { [datetime]$s.DeployStarted } elseif ($s.RunStarted) { [datetime]$s.RunStarted } else { Get-Date }
    $dur = (Get-Date) - $start
    $durText = '{0} h {1} min' -f [int][Math]::Floor($dur.TotalHours), $dur.Minutes
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }

    $color = @{ OK = '#1e9e5a'; WARN = '#c98a00'; FAIL = '#d13438'; INFO = '#555' }
    $label = @{ OK = 'OK'; WARN = 'HUOM'; FAIL = 'VIRHE'; INFO = 'INFO' }
    $rows = foreach ($e in $s.Events) {
        "<tr><td style='color:$($color[$e.Status]);font-weight:600'>$($label[$e.Status])</td><td>$(& $enc $e.Area)</td><td>$(& $enc $e.Text)</td></tr>"
    }
    $inst = if ($s.Installed.Count) { ($s.Installed | ForEach-Object { "<li>$(& $enc $_)</li>" }) -join '' } else { '<li>–</li>' }
    $fail = if ($s.FailedTitles.Count) { ($s.FailedTitles | ForEach-Object { "<li>$(& $enc $_)</li>" }) -join '' } else { '<li>–</li>' }
    $head = @{ OK = 'Kaikki kunnossa'; WARN = 'Valmis – tarkista huomiot'; FAIL = 'Valmis – VIRHEITÄ' }[$overall]

    $html = @"
<!doctype html><html lang="fi"><head><meta charset="utf-8"><title>W11AUTO $(& $enc $Machine.Serial)</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{color:$($color[$overall])}
table{border-collapse:collapse;width:100%}td{border-bottom:1px solid #ddd;padding:6px 10px;vertical-align:top}
.meta{color:#666}</style></head><body>
<h1>$head</h1>
<p class="meta">$(& $enc "$($Machine.Manufacturer) $($Machine.Model)") &middot; SN $(& $enc $Machine.Serial) &middot; $(Get-Date -Format 'd.M.yyyy HH:mm') &middot; kesto $durText &middot; päivityskierroksia $($s.Round)</p>
<table>$($rows -join '')</table>
<h2>Asennetut päivitykset ($($s.Installed.Count))</h2><ul>$inst</ul>
<h2>Epäonnistuneet päivitykset ($($s.FailedTitles.Count))</h2><ul>$fail</ul>
</body></html>
"@
    $name = 'W11AUTO-{0}-{1}.html' -f ($Machine.Serial -replace '[^\w-]', ''), (Get-Date -Format 'yyyyMMdd-HHmm')
    $path = Join-Path (Get-W11LogDir) $name
    Set-Content -Path $path -Value $html -Encoding UTF8

    # Discord-upotus
    $emoji = @{ OK = [char]::ConvertFromUtf32(0x2705); WARN = [char]::ConvertFromUtf32(0x26A0); FAIL = [char]::ConvertFromUtf32(0x274C); INFO = [char]::ConvertFromUtf32(0x2139) }
    $lines = foreach ($e in $s.Events) { "$($emoji[$e.Status]) **$($e.Area):** $($e.Text)" }
    $desc = ($lines -join "`n")
    if ($s.FailedTitles.Count) { $desc += "`n`n**Epäonnistuneet päivitykset:**`n" + (($s.FailedTitles | Select-Object -First 8) -join "`n") }
    if ($desc.Length -gt 4000) { $desc = $desc.Substring(0, 3990) + ' …' }
    $embed = @{
        title       = "$($emoji[$overall]) $head – $($Machine.Manufacturer) $($Machine.Model)"
        description = $desc
        color       = @{ OK = 0x1E9E5A; WARN = 0xE0A000; FAIL = 0xD13438 }[$overall]
        fields      = @(
            @{ name = 'Sarjanumero'; value = "$($Machine.Serial)"; inline = $true }
            @{ name = 'Kesto'; value = $durText; inline = $true }
            @{ name = 'Päivityksiä'; value = "$($s.Installed.Count) asennettu, $($s.FailedTitles.Count) epäonnistui"; inline = $true }
        )
        footer      = @{ text = 'W11AUTO' }
        timestamp   = (Get-Date).ToUniversalTime().ToString('o')
    }
    @{ Path = $path; Overall = $overall; Embed = $embed; Headline = $head }
}

Export-ModuleMember -Function Get-W11LicenseInfo, Invoke-W11Activation, Invoke-W11HealthChecks, Get-W11Overall, New-W11Report
