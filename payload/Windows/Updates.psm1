# W11AUTO - Windows Update suoraan WUA COM -rajapinnan kautta (ei PSWindowsUpdate-moduulia).

$script:UpgradesCategory = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'   # versiopäivitykset (feature updates)

function Invoke-W11Retry {
    param([scriptblock]$Action, [string]$What, [int]$Tries = 3)
    for ($i = 1; $i -le $Tries; $i++) {
        try { return & $Action }
        catch {
            $hr = '0x{0:X8}' -f $_.Exception.HResult
            Write-W11Log "$What epäonnistui ($i/$Tries): $hr $($_.Exception.Message)" 'WARN'
            if ($i -eq $Tries) { throw }
            # 0x8024001E / 0x80240016 = toinen asennus käynnissä (Windowsin oma automaattipäivitys)
            Set-W11UIHeader -Action "$What – odotetaan hetki ja yritetään uudelleen ($i/$Tries)…"
            Start-Sleep -Seconds (30 * $i)
        }
    }
}

function Test-W11RebootPending {
    try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { return $true } } catch { }
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}

function Format-W11Size { param([double]$Bytes) if ($Bytes -ge 1GB) { '{0:N1} Gt' -f ($Bytes / 1GB) } else { '{0:N0} Mt' -f ($Bytes / 1MB) } }

# Yksi kierros: haku -> lataus -> asennus. Palauttaa Status: Done | Reboot | Continue
function Invoke-W11UpdateRound {
    param([hashtable]$State)

    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'W11AUTO'

    Set-W11UIHeader -Action 'Etsitään päivityksiä…' -Busy $true
    $search = Invoke-W11Retry -What 'Päivitysten haku' -Action {
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Search("IsInstalled=0 and IsHidden=0")
    }

    $todo = New-Object -ComObject Microsoft.Update.UpdateColl
    $titles = @(); $size = 0
    foreach ($u in $search.Updates) {
        $id = $u.Identity.UpdateID
        $isUpgrade = $false
        foreach ($c in $u.Categories) { if ($c.CategoryID -eq $script:UpgradesCategory) { $isUpgrade = $true } }
        if ($isUpgrade) { Write-W11Log "Ohitetaan versiopäivitys: $($u.Title)"; continue }
        if ($u.BrowseOnly) { Write-W11Log "Ohitetaan valinnainen: $($u.Title)"; continue }
        if ([int]$State.FailCounts[$id] -ge 2) { Write-W11Log "Ohitetaan (epäonnistunut 2x): $($u.Title)"; continue }
        if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
        [void]$todo.Add($u); $titles += $u.Title; $size += [double]$u.MaxDownloadSize
    }

    if ($todo.Count -eq 0) {
        if (Test-W11RebootPending) { return @{ Status = 'Reboot'; Count = 0 } }
        return @{ Status = 'Done'; Count = 0 }
    }
    Write-W11Log ("Kierros {0}: {1} päivitystä: {2}" -f ($State.Round + 1), $todo.Count, ($titles -join ' | '))

    # Lataus (kaikki kerralla, korkea prioriteetti)
    $pending = @($titles | Select-Object -First 4) -join "`n      "
    if ($titles.Count -gt 4) { $pending += "`n      … ja $($titles.Count - 4) muuta" }
    Set-W11UIStep 'wu-list' "Tällä kierroksella:`n      $pending" 'INFO'
    Set-W11UIHeader -Action ("Ladataan {0} päivitystä ({1})…" -f $todo.Count, (Format-W11Size $size))
    [void](Invoke-W11Retry -What 'Lataus' -Action {
        $dl = $session.CreateUpdateDownloader()
        $dl.Priority = 3
        $dl.Updates = $todo
        $dl.Download()
    })

    $install = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $todo) {
        if ($u.IsDownloaded) { [void]$install.Add($u) }
        else { $State.FailCounts[$u.Identity.UpdateID] = [int]$State.FailCounts[$u.Identity.UpdateID] + 1; Write-W11Log "Lataus epäonnistui: $($u.Title)" 'WARN' }
    }
    if ($install.Count -eq 0) { Save-W11State; return @{ Status = 'Continue'; Count = 0 } }

    # Asennus
    Set-W11UIHeader -Action ("Asennetaan {0} päivitystä… (ei saa sammuttaa)" -f $install.Count)
    $result = Invoke-W11Retry -What 'Asennus' -Action {
        $inst = $session.CreateUpdateInstaller()
        $inst.ForceQuiet = $true
        $inst.AllowSourcePrompts = $false
        $inst.Updates = $install
        $inst.Install()
    }

    $reboot = [bool]$result.RebootRequired
    for ($i = 0; $i -lt $install.Count; $i++) {
        $u = $install.Item($i); $r = $result.GetUpdateResult($i)
        if ($r.ResultCode -in 2, 3) {
            $State.Installed = @($State.Installed) + $u.Title
        } else {
            $id = $u.Identity.UpdateID
            $State.FailCounts[$id] = [int]$State.FailCounts[$id] + 1
            $code = '0x{0:X8}' -f $r.HResult
            if ($State.FailCounts[$id] -ge 2) { $State.FailedTitles = @($State.FailedTitles) + "$($u.Title) ($code)" }
            Write-W11Log "Asennus epäonnistui: $($u.Title) $code" 'WARN'
        }
        if ($r.RebootRequired) { $reboot = $true }
    }
    Save-W11State
    if ($reboot -or (Test-W11RebootPending)) { return @{ Status = 'Reboot'; Count = $install.Count } }
    @{ Status = 'Continue'; Count = $install.Count }
}

function Update-W11Extras {
    param([bool]$IncludeStore)
    $out = @{}
    try {
        Set-W11UIHeader -Action 'Päivitetään Defenderin virusmääritykset…'
        Update-MpSignature -UpdateSource MicrosoftUpdateServer -ErrorAction Stop
        $out.Defender = @{ Status = 'OK'; Text = "Virusmääritykset $((Get-MpComputerStatus).AntivirusSignatureVersion)" }
    } catch { $out.Defender = @{ Status = 'WARN'; Text = "Määritysten päivitys epäonnistui: $($_.Exception.Message)" } }

    if ($IncludeStore) {
        try {
            # Käynnistää Storen sovelluspäivitykset taustalla (ei odoteta – ne jatkuvat itsestään)
            Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
                Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
            $out.Store = @{ Status = 'OK'; Text = 'Store-sovellusten päivitys käynnistetty taustalle' }
        } catch { $out.Store = @{ Status = 'WARN'; Text = "Store-päivitystä ei voitu käynnistää: $($_.Exception.Message)" } }
    }
    $out
}

Export-ModuleMember -Function Invoke-W11UpdateRound, Test-W11RebootPending, Update-W11Extras, Format-W11Size
