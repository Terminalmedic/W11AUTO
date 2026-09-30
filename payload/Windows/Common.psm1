# W11AUTO - yhteiset funktiot Windows-vaiheelle (loki, tila, asetukset, Discord, ääni, verkko, virta)

$script:Root    = Join-Path $env:SystemDrive 'W11AUTO'
$script:LogDir  = Join-Path $env:SystemRoot 'Logs\W11AUTO'
$script:State   = $null
$script:Config  = $null

function Get-W11Root { $script:Root }
function Get-W11LogDir { $script:LogDir }

function Write-W11Log {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path (Join-Path $script:LogDir 'W11AUTO.log') -Value $line -Encoding UTF8
}

# --- JSON <-> hashtable (PS 5.1:n ConvertFrom-Json palauttaa PSCustomObjectin) ---
function ConvertTo-W11Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}; foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-W11Hashtable $InputObject[$k] }; return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-W11Hashtable $p.Value }; return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @(foreach ($i in $InputObject) { ConvertTo-W11Hashtable $i })
    }
    return $InputObject
}

function Read-W11Json {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{} }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    ConvertTo-W11Hashtable ($raw | ConvertFrom-Json)
}

function Write-W11Json {
    param([string]$Path, $Data)
    $tmp = "$Path.tmp"
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}

function Get-W11Config {
    if (-not $script:Config) {
        $defaults = @{
            DiscordWebhook     = ''
            TimeZone           = 'FLE Standard Time'
            MaxUpdateRounds    = 12
            WaitAlertMinutes   = 5
            SoundVolumePercent = 25
            FinalCountdownSec  = 120
        }
        $cfg = Read-W11Json (Join-Path $script:Root 'config.json')
        foreach ($k in $defaults.Keys) { if (-not $cfg.ContainsKey($k)) { $cfg[$k] = $defaults[$k] } }
        $script:Config = $cfg
    }
    $script:Config
}

function Get-W11State {
    if (-not $script:State) {
        $s = Read-W11Json (Join-Path $script:Root 'state.json')
        foreach ($k in 'Events', 'Installed', 'FailedTitles') { if (-not $s.ContainsKey($k) -or $null -eq $s[$k]) { $s[$k] = @() } }
        if (-not $s.ContainsKey('FailCounts') -or $null -eq $s['FailCounts']) { $s['FailCounts'] = @{} }
        if (-not $s.ContainsKey('Round')) { $s['Round'] = 0 }
        if (-not $s.ContainsKey('Phase')) { $s['Phase'] = 'updates' }
        $script:State = $s
    }
    $script:State
}

function Save-W11State { Write-W11Json (Join-Path $script:Root 'state.json') (Get-W11State) }

# Tapahtuma raporttia varten: Area = aihe, Status = OK | WARN | FAIL | INFO
function Add-W11Event {
    param([string]$Area, [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status, [string]$Text)
    $s = Get-W11State
    $new = @{ Area = $Area; Status = $Status; Text = $Text }
    $found = $false
    $s.Events = @(foreach ($e in $s.Events) { if ($e.Area -eq $Area) { $found = $true; $new } else { $e } })
    if (-not $found) { $s.Events = @($s.Events) + @($new) }
    Save-W11State
    Write-W11Log "$Area [$Status] $Text"
}

# --- Discord ---
function Send-W11Discord {
    param([string]$Content, [hashtable]$Embed, [string]$AttachmentPath)
    $url = (Get-W11Config).DiscordWebhook
    if ([string]::IsNullOrWhiteSpace($url)) { return $false }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.Net.Http
        $payload = @{ username = 'W11AUTO' }
        if ($Content) { $payload.content = $Content }
        if ($Embed) { $payload.embeds = @($Embed) }
        $json = $payload | ConvertTo-Json -Depth 10
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $form = New-Object System.Net.Http.MultipartFormDataContent
        $form.Add((New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')), 'payload_json')
        if ($AttachmentPath -and (Test-Path $AttachmentPath)) {
            $bytes = [IO.File]::ReadAllBytes($AttachmentPath)
            $file = New-Object System.Net.Http.ByteArrayContent(, $bytes)
            $file.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('text/html')
            $form.Add($file, 'files[0]', [IO.Path]::GetFileName($AttachmentPath))
        }
        $resp = $client.PostAsync($url, $form).GetAwaiter().GetResult()
        $ok = $resp.IsSuccessStatusCode
        if (-not $ok) { Write-W11Log "Discord: HTTP $([int]$resp.StatusCode)" 'WARN' }
        $client.Dispose()
        return $ok
    } catch {
        Write-W11Log "Discord epäonnistui: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# --- Ääni: järjestelmän äänenvoimakkuus ja hiljainen merkkiääni ---
$script:AudioTypeLoaded = $false
function Set-W11Volume {
    param([int]$Percent)
    try {
        if (-not $script:AudioTypeLoaded) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace W11Audio {
  [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j(); int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
  }
  [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice { int Activate(ref Guid id, int clsCtx, IntPtr activationParams, out IAudioEndpointVolume aev); }
  [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator { int f(); int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint); }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
  public static class Volume {
    public static void Set(float level) {
      var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
      IMMDevice dev; Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
      IAudioEndpointVolume epv; var iid = typeof(IAudioEndpointVolume).GUID;
      Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out epv));
      epv.SetMute(false, Guid.Empty);
      epv.SetMasterVolumeLevelScalar(level, Guid.Empty);
    }
  }
}
'@
            $script:AudioTypeLoaded = $true
        }
        [W11Audio.Volume]::Set([float]($Percent / 100))
    } catch { Write-W11Log "Äänenvoimakkuutta ei voitu asettaa: $($_.Exception.Message)" 'WARN' }
}

function Invoke-W11Beep {
    # Järjestelmän "Asterisk"-ääni noudattaa äänenvoimakkuutta (Set-W11Volume) -> ei kova.
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
}

# --- Virta ---
function Test-W11Power {
    $bat = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    if ($bat.Count -eq 0) { return @{ Ok = $true; HasBattery = $false; Text = 'Ei akkua (pöytäkone) – verkkovirta OK' } }
    Add-Type -AssemblyName System.Windows.Forms
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $pct = [int]($ps.BatteryLifePercent * 100)
    if ($ps.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online) {
        return @{ Ok = $true; HasBattery = $true; Text = "Laturi kytketty (akku $pct %)" }
    }
    @{ Ok = $false; HasBattery = $true; Text = "LATURI EI OLE KIINNI (akku $pct %)" }
}

# --- Kello: HTTP Date -otsake (toimii ilman TLS:ää, joten väärä kello ei estä korjausta) ---
function Sync-W11Clock {
    try {
        $req = [Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
        $req.Method = 'HEAD'; $req.Timeout = 5000
        $resp = $req.GetResponse(); $date = $resp.Headers['Date']; $resp.Close()
        if ($date) {
            $net = [DateTime]::Parse($date).ToUniversalTime()
            $drift = [Math]::Abs(($net - [DateTime]::UtcNow).TotalSeconds)
            if ($drift -gt 120) {
                Set-Date -Date $net.ToLocalTime() | Out-Null
                Write-W11Log "Kello korjattu ($([int]$drift) s heitto)"
                return "Kello korjattu ($([int]($drift/60)) min heitto)"
            }
        }
    } catch { }
    try { Start-Service w32time -ErrorAction SilentlyContinue; & w32tm.exe /resync /nowait | Out-Null } catch { }
    $null
}

# --- Verkko: kaappisivu + TLS Windows Updateen ---
function Test-W11Network {
    try {
        $req = [Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
        $req.Timeout = 5000; $req.AllowAutoRedirect = $false
        $resp = $req.GetResponse()
        $body = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd(); $resp.Close()
        if ($body -notmatch 'Microsoft Connect Test') { return @{ Ok = $false; Text = 'Verkko vaatii kirjautumisen (kaappisivu) – avaa selain' } }
    } catch { return @{ Ok = $false; Text = 'EI NETTIYHTEYTTÄ' } }

    $clock = Sync-W11Clock
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create('https://sls.update.microsoft.com/')
        $req.Timeout = 8000
        try { $r = $req.GetResponse(); $r.Close() }
        catch [Net.WebException] { if (-not $_.Exception.Response) { throw } }  # 4xx-vastauskin todistaa yhteyden
    } catch { return @{ Ok = $false; Text = 'Netti toimii, mutta Windows Update ei vastaa (palomuuri/kello?)' } }
    $t = 'Nettiyhteys OK'; if ($clock) { $t += " – $clock" }
    @{ Ok = $true; Text = $t }
}

# --- Tietokoneen tiedot ---
function Get-W11MachineInfo {
    $cs = Get-CimInstance Win32_ComputerSystem
    $csp = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $model = $cs.Model
    if ($cs.Manufacturer -match 'Lenovo' -and $csp.Version) { $model = "$($csp.Version) ($($cs.Model))" }
    @{
        Manufacturer = $cs.Manufacturer
        Model        = $model
        Serial       = $bios.SerialNumber
        Bios         = $bios.SMBIOSBIOSVersion
        Cpu          = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
        RamGB        = [Math]::Round($cs.TotalPhysicalMemory / 1GB)
    }
}

Export-ModuleMember -Function *-W11*
