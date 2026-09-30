# W11AUTO - ajetaan specialize-vaiheessa (SYSTEM, ennen ensimmäistä kirjautumista):
# 1) asentaa WinPE:ssä ladatun HP/Lenovo-ajuripaketin (32-bittiset purkajat eivät toimi WinPE:ssä)
# 2) rekisteröi W11AUTO-tehtävän, joka käynnistää Start.ps1:n jokaisella kirjautumisella

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -Force -DisableNameChecking
$root = Get-W11Root
Write-W11Log 'Specialize.ps1 alkaa'

# --- Ajuripaketti ---
$packDir = Join-Path $root 'DriverPack'
$manifest = Join-Path $packDir 'pack.json'
if (Test-Path $manifest) {
    $pack = Read-W11Json $manifest
    $exe = Join-Path $packDir $pack.File
    $dest = Join-Path $packDir 'x'
    try {
        switch -Regex ($pack.Manufacturer) {
            'HP'     { $argList = @('/s', '/e', '/f', "`"$dest`"") }
            'Lenovo' { $argList = @('/VERYSILENT', "/DIR=`"$dest`"", '/EXTRACT=YES') }
            default  { throw "Tuntematon purkutapa: $($pack.Manufacturer)" }
        }
        $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
        $infs = @(Get-ChildItem -Path $dest -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
        if ($infs.Count -eq 0) { throw "Purku ei tuottanut ajureita (koodi $($p.ExitCode))" }
        & pnputil.exe /add-driver "$dest\*.inf" /subdirs /install | Out-Null
        Add-W11Event 'Ajuripaketti' 'OK' "$($pack.Name) asennettu ($($infs.Count) ajuria)"
    } catch {
        Add-W11Event 'Ajuripaketti' 'WARN' "$($pack.Name): $($_.Exception.Message) – ajurit haetaan Windows Updatesta"
    }
    Remove-Item $packDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Kirjautumistehtävä: kaikki käyttäjät (Users-ryhmä SID:llä -> toimii kielestä riippumatta), korotettu ---
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'Start.ps1')`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 4
Register-ScheduledTask -TaskName 'W11AUTO' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-W11Log 'Tehtävä W11AUTO rekisteröity'
