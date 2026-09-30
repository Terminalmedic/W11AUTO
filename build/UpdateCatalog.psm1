# W11AUTO - uusimpien kumulatiivisten päivitysten haku Microsoft Update Catalogista.
# Catalogilla ei ole virallista API:a: haku- ja latausdialogisivut jäsennetään. Jos Microsoft muuttaa sivua,
# lataa .msu-tiedostot käsin kansioon Updates\ (ks. README).

$script:Base = 'https://www.catalog.update.microsoft.com'
$script:Versions = @{ 26100 = '24H2'; 26200 = '25H2' }

function Search-W11Catalog {
    param([string]$Query)
    $html = (Invoke-WebRequest -Uri "$script:Base/Search.aspx?q=$([uri]::EscapeDataString($Query))" -UseBasicParsing).Content
    $links = [regex]::Matches($html, '<a[^>]+id=["''](?<id>[0-9a-fA-F-]{36})_link["''][^>]*>\s*(?<t>[^<]+?)\s*</a>')
    foreach ($m in $links) {
        $id = $m.Groups['id'].Value
        $d = [regex]::Match($html, "id=[""']$($id)_C4_R\d+[""'][^>]*>\s*(?<d>\d{1,2}/\d{1,2}/\d{4})\s*<")
        $date = if ($d.Success) { [datetime]::ParseExact($d.Groups['d'].Value, 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture) } else { [datetime]::MinValue }
        [pscustomobject]@{ Id = $id; Title = [Net.WebUtility]::HtmlDecode($m.Groups['t'].Value.Trim()); Date = $date }
    }
}

function Get-W11CatalogFileUrls {
    param([string]$Id)
    $json = '[{"size":0,"languages":"","uidInfo":"' + $Id + '","updateID":"' + $Id + '"}]'
    $r = Invoke-WebRequest -Uri "$script:Base/DownloadDialog.aspx" -Method Post -UseBasicParsing `
        -ContentType 'application/x-www-form-urlencoded' -Body ('updateIDs=' + [uri]::EscapeDataString($json))
    [regex]::Matches($r.Content, "\.url\s*=\s*'(?<u>https?://[^']+)'") | ForEach-Object { $_.Groups['u'].Value } | Select-Object -Unique
}

# Lataa uusimman Windowsin kumulatiivisen päivityksen (+ tarvittavat checkpoint-päivitykset) ja .NET-päivityksen.
function Save-W11LatestUpdates {
    param([Parameter(Mandatory)][int]$Build, [Parameter(Mandatory)][string]$Destination)
    $ver = $script:Versions[$Build]
    if (-not $ver) { throw "Tuntematon Windows-koontiversio $Build – lataa päivitykset käsin kansioon $Destination" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'

    $wanted = @(
        @{ Name = 'Windows'; Query = "Cumulative Update for Windows 11 Version $ver for x64-based Systems"
           Pattern = "^\d{4}-\d{2} Cumulative Update for Windows 11 Version $ver for x64-based Systems" }
        @{ Name = '.NET'; Query = "Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version $ver for x64"
           Pattern = "^\d{4}-\d{2} Cumulative Update for \.NET Framework 3\.5 and 4\.8\.1 for Windows 11, version $ver for x64" }
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem $Destination -Filter *.msu -ErrorAction SilentlyContinue | Remove-Item -Force

    $files = @()
    foreach ($w in $wanted) {
        $hit = Search-W11Catalog $w.Query |
            Where-Object { $_.Title -match $w.Pattern -and $_.Title -notmatch 'Preview|Dynamic|arm64' } |
            Sort-Object Date -Descending | Select-Object -First 1
        if (-not $hit) { Write-Warning "$($w.Name): päivitystä ei löytynyt Catalogista"; continue }
        Write-Host "  $($w.Name): $($hit.Title)"
        foreach ($url in (Get-W11CatalogFileUrls $hit.Id)) {
            $path = Join-Path $Destination ([IO.Path]::GetFileName(([uri]$url).AbsolutePath))
            Write-Host "    -> $([IO.Path]::GetFileName($path))"
            try { Start-BitsTransfer -Source $url -Destination $path -ErrorAction Stop }
            catch { Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing }
            $files += $path
        }
    }
    $files
}

Export-ModuleMember -Function Save-W11LatestUpdates, Search-W11Catalog, Get-W11CatalogFileUrls
