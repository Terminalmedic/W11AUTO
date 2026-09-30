# W11AUTO - tilaikkuna. Ikkuna pyörii omassa säikeessään (runspace), joten se pysyy
# responsiivisena vaikka pääskripti odottaa Windows Updatea. Tieto kulkee $Sync-taulun kautta.

$script:Sync = $null
$script:UIPs = $null
$script:Lines = [ordered]@{}

$script:UIScript = {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $bg = [Drawing.Color]::FromArgb(22, 24, 30)
    $form = New-Object Windows.Forms.Form
    $form.Text = 'W11AUTO'
    $form.WindowState = 'Maximized'
    $form.BackColor = $bg
    $form.ForeColor = [Drawing.Color]::White
    $form.KeyPreview = $true
    $form.ShowInTaskbar = $true

    $title = New-Object Windows.Forms.Label
    $title.Dock = 'Top'; $title.Height = 80; $title.Padding = '30,20,0,0'
    $title.Font = New-Object Drawing.Font('Segoe UI', 26, [Drawing.FontStyle]::Bold)

    $sub = New-Object Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = 40; $sub.Padding = '34,0,0,0'
    $sub.Font = New-Object Drawing.Font('Segoe UI', 13)
    $sub.ForeColor = [Drawing.Color]::FromArgb(170, 175, 190)

    $list = New-Object Windows.Forms.RichTextBox
    $list.Dock = 'Fill'; $list.ReadOnly = $true; $list.BorderStyle = 'None'
    $list.BackColor = $bg; $list.ForeColor = [Drawing.Color]::White
    $list.Font = New-Object Drawing.Font('Segoe UI', 15)
    $list.TabStop = $false

    $action = New-Object Windows.Forms.Label
    $action.Dock = 'Bottom'; $action.Height = 44; $action.Padding = '34,8,0,0'
    $action.Font = New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)

    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Dock = 'Bottom'; $progress.Height = 8; $progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30

    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock = 'Bottom'; $buttons.Height = 76; $buttons.Padding = '30,12,0,0'

    $footer = New-Object Windows.Forms.Label
    $footer.Dock = 'Bottom'; $footer.Height = 30; $footer.Padding = '34,4,0,0'
    $footer.Font = New-Object Drawing.Font('Segoe UI', 10)
    $footer.ForeColor = [Drawing.Color]::FromArgb(130, 135, 150)

    # Telakointijärjestys: viimeksi lisätty telakoituu reunimmaiseksi.
    $form.Controls.AddRange(@($list, $action, $progress, $buttons, $footer, $sub, $title))

    $colors = @{
        OK   = [Drawing.Color]::FromArgb(80, 200, 120); WARN = [Drawing.Color]::FromArgb(240, 190, 60)
        FAIL = [Drawing.Color]::FromArgb(240, 90, 90);  RUN  = [Drawing.Color]::FromArgb(90, 160, 255)
        WAIT = [Drawing.Color]::FromArgb(150, 150, 160); INFO = [Drawing.Color]::FromArgb(200, 200, 210)
    }
    $icons = @{ OK = [char]0x2714; WARN = [char]0x26A0; FAIL = [char]0x2716; RUN = [char]0x25B6; WAIT = [char]0x2026; INFO = [char]0x2022 }
    $seen = @{ Version = -1; Buttons = -1 }  # hashtable: tapahtumakäsittelijä ei voi sijoittaa ulkoisiin muuttujiin

    $form.Add_KeyDown({
        param($s, $e)
        if ($e.Control -and $e.Shift -and $e.KeyCode -eq 'Q') {
            $r = [Windows.Forms.MessageBox]::Show('Keskeytetäänkö W11AUTO? Raportti lähetetään keskeneräisenä.', 'W11AUTO', 'YesNo', 'Warning')
            if ($r -eq 'Yes') { $sync.Abort = $true }
        }
    })
    $form.Add_FormClosing({ param($s, $e) if (-not $sync.AllowClose) { $e.Cancel = $true } })

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        if ($sync.AllowClose -and $sync.CloseNow) { $timer.Stop(); $form.Close(); return }
        $elapsed = (Get-Date) - $sync.Started
        $cd = ''; if ($sync.CountdownTo) { $left = [int](($sync.CountdownTo - (Get-Date)).TotalSeconds); if ($left -ge 0) { $cd = "   |   Jatketaan automaattisesti $left s kuluttua" } }
        $footer.Text = ('Kulunut {0:hh\:mm\:ss}   |   Ctrl+Shift+Q = keskeytä{1}' -f $elapsed, $cd)
        if ($sync.Version -ne $seen.Version) {
            $seen.Version = $sync.Version
            $title.Text = $sync.Title; $sub.Text = $sync.Subtitle; $action.Text = $sync.Action
            $title.ForeColor = if ($sync.TitleColor -and $colors.ContainsKey($sync.TitleColor)) { $colors[$sync.TitleColor] } else { [Drawing.Color]::White }
            $progress.Visible = [bool]$sync.Busy
            $list.Clear()
            foreach ($l in $sync.Lines) {
                $list.SelectionColor = $colors[$l.State]
                $list.AppendText("  $($icons[$l.State])  ")
                $list.SelectionColor = [Drawing.Color]::White
                $list.AppendText("$($l.Text)`n")
            }
        }
        if ($sync.ButtonsVersion -ne $seen.Buttons) {
            $seen.Buttons = $sync.ButtonsVersion
            $buttons.Controls.Clear()
            foreach ($b in $sync.Buttons) {
                $btn = New-Object Windows.Forms.Button
                $btn.Text = $b.Text; $btn.Tag = $b.Id; $btn.AutoSize = $true; $btn.Height = 48
                $btn.Padding = '14,4,14,4'; $btn.Margin = '0,0,16,0'; $btn.FlatStyle = 'Flat'
                $btn.Font = New-Object Drawing.Font('Segoe UI', 13)
                $btn.BackColor = [Drawing.Color]::FromArgb(45, 50, 62)
                $btn.Add_Click({ param($s, $e) $sync.Clicked = $s.Tag })
                $buttons.Controls.Add($btn)
            }
        }
    })
    $timer.Start()
    $form.Add_Shown({ $form.Activate() })
    [Windows.Forms.Application]::Run($form)
}

function Start-W11UI {
    $script:Sync = [hashtable]::Synchronized(@{
        Title = 'W11AUTO'; Subtitle = ''; TitleColor = $null; Action = ''; Busy = $true
        Lines = @(); Version = 0; Buttons = @(); ButtonsVersion = 0; Clicked = $null
        Abort = $false; AllowClose = $false; CloseNow = $false; Started = (Get-Date); CountdownTo = $null
    })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $script:Sync)
    $script:UIPs = [powershell]::Create(); $script:UIPs.Runspace = $rs
    [void]$script:UIPs.AddScript($script:UIScript)
    [void]$script:UIPs.BeginInvoke()
    $script:Sync
}

function Set-W11UIHeader {
    param([string]$Title, [string]$Subtitle, [string]$Color, [string]$Action, $Busy)
    if (-not $script:Sync) { return }
    if ($PSBoundParameters.ContainsKey('Title')) { $script:Sync.Title = $Title; $script:Sync.TitleColor = $Color }
    if ($PSBoundParameters.ContainsKey('Subtitle')) { $script:Sync.Subtitle = $Subtitle }
    if ($PSBoundParameters.ContainsKey('Action')) { $script:Sync.Action = $Action }
    if ($PSBoundParameters.ContainsKey('Busy')) { $script:Sync.Busy = [bool]$Busy }
    $script:Sync.Version++
}

function Set-W11UIStep {
    param([string]$Key, [string]$Text, [ValidateSet('OK', 'WARN', 'FAIL', 'RUN', 'WAIT', 'INFO')][string]$State)
    $script:Lines[$Key] = [pscustomobject]@{ Text = $Text; State = $State }
    if (-not $script:Sync) { return }
    $script:Sync.Lines = @($script:Lines.Values)
    $script:Sync.Version++
}

function Clear-W11UISteps { $script:Lines.Clear(); if ($script:Sync) { $script:Sync.Lines = @(); $script:Sync.Version++ } }

function Set-W11UIButtons {
    param([array]$Buttons = @())
    if (-not $script:Sync) { return }
    $script:Sync.Clicked = $null
    $script:Sync.Buttons = @($Buttons | ForEach-Object { [pscustomobject]$_ })
    $script:Sync.ButtonsVersion++
}

function Get-W11UIClick { if (-not $script:Sync) { return $null }; $c = $script:Sync.Clicked; $script:Sync.Clicked = $null; $c }
function Test-W11UIAbort { [bool]($script:Sync -and $script:Sync.Abort) }

# Odottaa napin painallusta; TimeoutSec > 0 -> palauttaa DefaultId aikakatkaisussa.
function Wait-W11UIButton {
    param([array]$Buttons, [int]$TimeoutSec = 0, [string]$DefaultId)
    Set-W11UIButtons $Buttons
    if ($TimeoutSec -gt 0) { $script:Sync.CountdownTo = (Get-Date).AddSeconds($TimeoutSec) }
    try {
        while ($true) {
            $c = Get-W11UIClick
            if ($c) { return $c }
            if ($TimeoutSec -gt 0 -and (Get-Date) -ge $script:Sync.CountdownTo) { return $DefaultId }
            Start-Sleep -Milliseconds 250
        }
    } finally { $script:Sync.CountdownTo = $null; Set-W11UIButtons @() }
}

function Stop-W11UI {
    if (-not $script:Sync) { return }
    $script:Sync.AllowClose = $true; $script:Sync.CloseNow = $true
    Start-Sleep -Milliseconds 800
}

Export-ModuleMember -Function *-W11UI*
