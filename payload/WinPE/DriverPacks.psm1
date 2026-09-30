# W11AUTO - valmistajien ajuripakettiluettelot (Dell, HP, Lenovo). Idea ja luettelolähteet kuten OSDCloudissa
# (OSD-moduuli, David Segura, MIT). Toteutus on oma ja pieni, jotta se toimii WinPE:ssä ilman moduulia.
#
# Palauttaa @{ Manufacturer; Name; Url; FileName; Format } tai $null.

$script:Catalogs = @{
    Dell   = 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'
    HP     = 'https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab'
    Lenovo = 'https://download.lenovo.com/cdrt/td/catalogv2.xml'
}

function Save-W11File {
    param([string]$Url, [string]$Path, [string]$Label)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 30000; $req.ReadWriteTimeout = 60000; $req.UserAgent = 'W11AUTO'
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create("$Path.part")
    try {
        $buf = New-Object byte[] (4MB); $done = 0L; $lastPct = -1; $sw = [Diagnostics.Stopwatch]::StartNew()
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $done += $n
            if ($Label -and $total -gt 0) {
                $pct = [int](100 * $done / $total)
                if ($pct -ne $lastPct -and $pct % 5 -eq 0) {
                    $lastPct = $pct
                    $mbps = if ($sw.Elapsed.TotalSeconds -gt 0) { [int](($done / 1MB) / $sw.Elapsed.TotalSeconds) } else { 0 }
                    Write-Host ("`r  {0}: {1,3} %  ({2:N0}/{3:N0} Mt, {4} Mt/s)   " -f $Label, $pct, ($done / 1MB), ($total / 1MB), $mbps) -NoNewline
                }
            }
        }
        if ($Label) { Write-Host '' }
    } finally { $out.Close(); $in.Close(); $resp.Close() }
    Move-Item "$Path.part" $Path -Force
}

function Get-W11CatalogXml {
    param([string]$Vendor, [string]$WorkDir)
    $url = $script:Catalogs[$Vendor]
    $file = Join-Path $WorkDir ([IO.Path]::GetFileName($url))
    Save-W11File -Url $url -Path $file
    if ($file -like '*.cab') {
        & expand.exe "$file" -F:* "$WorkDir" | Out-Null
        $xml = Join-Path $WorkDir ([IO.Path]::GetFileNameWithoutExtension($file) + '.xml')
    } else { $xml = $file }
    [xml](Get-Content -Path $xml -Raw)
}

function Find-W11DriverPack {
    param([hashtable]$Hw, [string]$WorkDir)
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

    switch -Regex ($Hw.Manufacturer) {
        'Dell' {
            if (-not $Hw.Sku) { return $null }
            $cat = Get-W11CatalogXml -Vendor Dell -WorkDir $WorkDir
            $base = $cat.DriverPackManifest.baseLocation
            $cands = foreach ($p in $cat.DriverPackManifest.DriverPackage) {
                if ($p.type -ne 'win') { continue }
                $ids = @($p.SupportedSystems.Brand | ForEach-Object { $_.Model } | ForEach-Object { $_.systemID })
                if ($ids -notcontains $Hw.Sku) { continue }
                $os = @($p.SupportedOperatingSystems.OperatingSystem | Where-Object { $_.osArch -eq 'x64' })
                $rank = if ($os.osCode -contains 'Windows11') { 2 } elseif ($os.osCode -contains 'Windows10') { 1 } else { 0 }
                if ($rank -eq 0) { continue }
                [pscustomobject]@{ Rank = $rank; Date = [datetime]$p.dateTime; Path = $p.path; Name = $p.SelectSingleNode("*[local-name()='Name']").InnerText.Trim() }  # .Name olisi XmlNode.Name
            }
            $best = $cands | Sort-Object Rank, Date -Descending | Select-Object -First 1
            if (-not $best) { return $null }
            $proto = if ($base -match '^https?://') { '' } else { 'https://' }
            return @{ Manufacturer = 'Dell'; Name = "Dell $($best.Name)"; Url = "$proto$base/$($best.Path)"; FileName = [IO.Path]::GetFileName($best.Path); Format = 'cab' }
        }
        'HP|Hewlett' {
            if (-not $Hw.BaseBoard) { return $null }
            $cat = Get-W11CatalogXml -Vendor HP -WorkDir $WorkDir
            $root = $cat.NewDataSet.HPClientDriverPackCatalog
            $cands = foreach ($p in $root.ProductOSDriverPackList.ProductOSDriverPack) {
                $ids = ($p.SystemId -split ',') | ForEach-Object { $_.Trim() }
                if ($ids -notcontains $Hw.BaseBoard) { continue }
                if ($p.OSName -notmatch '64-bit') { continue }
                $rank = if ($p.OSName -match 'Windows 11') { 2 } elseif ($p.OSName -match 'Windows 10') { 1 } else { 0 }
                if ($rank -eq 0) { continue }
                $ver = if ($p.OSName -match '(\d\d)H(\d)') { [int]"$($Matches[1])$($Matches[2])" } else { 0 }
                [pscustomobject]@{ Rank = $rank; Ver = $ver; Id = $p.SoftPaqId; Name = $p.SystemName }
            }
            $best = $cands | Sort-Object Rank, Ver -Descending | Select-Object -First 1
            if (-not $best) { return $null }
            $sp = $root.SoftPaqList.SoftPaq | Where-Object { $_.Id -eq $best.Id } | Select-Object -First 1
            if (-not $sp) { return $null }
            $url = $sp.Url -replace '^http://', 'https://'
            return @{ Manufacturer = 'HP'; Name = "$($best.Name) ($($sp.Id))"; Url = $url; FileName = [IO.Path]::GetFileName($url); Format = 'exe' }
        }
        'Lenovo' {
            $mt = if ($Hw.Model.Length -ge 4) { $Hw.Model.Substring(0, 4).ToUpper() } else { return $null }
            $cat = Get-W11CatalogXml -Vendor Lenovo -WorkDir $WorkDir
            $model = $cat.ModelList.Model | Where-Object { @($_.Types.Type) -contains $mt } | Select-Object -First 1
            if (-not $model) { return $null }
            $cands = foreach ($s in @($model.SCCM)) {
                $rank = switch ($s.os) { 'win11' { 2 } 'win10' { 1 } default { 0 } }
                if ($rank -eq 0) { continue }
                $ver = if ($s.version -match '(\d\d)H(\d)') { [int]"$($Matches[1])$($Matches[2])" } else { 0 }
                [pscustomobject]@{ Rank = $rank; Ver = $ver; Url = $s.'#text' }
            }
            $best = $cands | Sort-Object Rank, Ver -Descending | Select-Object -First 1
            if (-not $best) { return $null }
            return @{ Manufacturer = 'Lenovo'; Name = "Lenovo $($model.GetAttribute('name'))"; Url = $best.Url; FileName = [IO.Path]::GetFileName($best.Url); Format = 'exe' }
        }
    }
    $null
}

Export-ModuleMember -Function Find-W11DriverPack, Save-W11File
