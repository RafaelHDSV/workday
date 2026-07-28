#Requires -Version 5.1
<#
.SYNOPSIS
  Overlay de expediente (entrada, almoco, saida, extras) + log de horas extras.
.DESCRIPTION
  Janela sem borda no canto inferior direito. Horarios e posicao em data/config.json.
  Clique direito: Ver extras, Configurar, Sair. Arraste para mover. Duplo clique oculta ate o dia seguinte.
#>

$ErrorActionPreference = 'Stop'

$sessionModule = Join-Path $PSScriptRoot 'Workday.Sessions.ps1'
. $sessionModule

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32Topmost {
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    public static void ApplyAlwaysOnTop(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) { return; }

        int exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, exStyle | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}
"@

$script:WindowHandle = [IntPtr]::Zero
$script:HiddenUntil = $null
$script:Dragging = $false

$script:OmitExtrasDates = @()

function Apply-WorkdayRuntimeConfig {
    param([object]$Config)

    $script:EntryHour = [int]$Config.entryHour
    $script:LunchStartHour = [int]$Config.lunchStartHour
    $script:LunchEndHour = [int]$Config.lunchEndHour
    $script:LeaveHour = [int]$Config.leaveHour
    $script:TrayOffsetPx = [int]$Config.trayOffsetPx
    $script:MarginBottom = [int]$Config.marginBottom
    if ($null -ne $Config.PSObject.Properties['omitExtrasDates'] -and $null -ne $Config.omitExtrasDates) {
        $script:OmitExtrasDates = @($Config.omitExtrasDates | ForEach-Object { [string]$_ })
    }
    else {
        $script:OmitExtrasDates = @()
    }
}

function Get-WorkdayRuntimeConfig {
    return [pscustomobject]@{
        entryHour       = $script:EntryHour
        lunchStartHour  = $script:LunchStartHour
        lunchEndHour    = $script:LunchEndHour
        leaveHour       = $script:LeaveHour
        trayOffsetPx    = $script:TrayOffsetPx
        marginBottom    = $script:MarginBottom
        omitExtrasDates = @($script:OmitExtrasDates)
    }
}

Apply-WorkdayRuntimeConfig (Read-WorkdayConfig)
if (-not (Test-Path -LiteralPath (Get-WorkdayConfigPath))) {
    Save-WorkdayConfig (Get-WorkdayRuntimeConfig)
}

function Test-IsWeekday {
    $day = (Get-Date).DayOfWeek
    return $day -ne [DayOfWeek]::Saturday -and $day -ne [DayOfWeek]::Sunday
}

function Format-Countdown([TimeSpan]$remaining) {
    $hours = [int][Math]::Floor($remaining.TotalHours)
    return '{0:D2}:{1:D2}:{2:D2}' -f $hours, $remaining.Minutes, $remaining.Seconds
}

function Format-SignedCountdown([string]$sign, [TimeSpan]$span) {
    return '{0}{1}' -f $sign, (Format-Countdown $span)
}

function Get-LeaveDisplay {
    $now = Get-Date

    if ($script:HiddenUntil -and $now -lt $script:HiddenUntil) {
        return $null
    }

    if ($script:HiddenUntil -and $now -ge $script:HiddenUntil) {
        $script:HiddenUntil = $null
    }

    if (-not (Test-IsWeekday)) {
        return $null
    }

    $entryTarget = $now.Date.AddHours($script:EntryHour)
    $lunchStart = $now.Date.AddHours($script:LunchStartHour)
    $lunchEnd = $now.Date.AddHours($script:LunchEndHour)
    $leaveTarget = $now.Date.AddHours($script:LeaveHour)

    if ($now -lt $entryTarget) {
        return @{
            Text  = Format-SignedCountdown '-' ($entryTarget - $now)
            Phase = 'before-entry'
        }
    }

    if ($now -ge $leaveTarget) {
        return @{
            Text  = Format-SignedCountdown '+' ($now - $leaveTarget)
            Phase = 'overtime'
        }
    }

    if ($now -ge $lunchStart -and $now -lt $lunchEnd) {
        return @{
            Text  = ('Almo' + [char]0x00E7 + 'o')
            Phase = 'lunch'
        }
    }

    if ($now -lt $lunchStart) {
        return @{
            Text  = Format-Countdown ($lunchStart - $now)
            Phase = 'countdown'
        }
    }

    return @{
        Text  = Format-Countdown ($leaveTarget - $now)
        Phase = 'countdown'
    }
}

function Set-OverlayAlwaysOnTop {
    if ($script:WindowHandle -eq [IntPtr]::Zero) { return }
    [Win32Topmost]::ApplyAlwaysOnTop($script:WindowHandle) | Out-Null
}

function Update-OverlayPosition {
    if ($script:Dragging) { return }

    $workArea = [System.Windows.SystemParameters]::WorkArea
    $window.UpdateLayout()

    $width = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { 80 }
    $height = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { 24 }

    $window.Left = $workArea.Right - $width - $script:TrayOffsetPx
    $window.Top = $workArea.Bottom - $height - $script:MarginBottom
    Set-OverlayAlwaysOnTop
}

function Save-WorkdayPositionFromWindow {
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $width = if ($window.ActualWidth -gt 0) { $window.ActualWidth } else { 80 }
    $height = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { 24 }

    $script:TrayOffsetPx = [int][Math]::Round($workArea.Right - $width - $window.Left)
    $script:MarginBottom = [int][Math]::Round($workArea.Bottom - $height - $window.Top)

    $cfg = Get-WorkdayRuntimeConfig
    Save-WorkdayConfig -Config $cfg
}

function Update-OverlayDisplay {
    $display = Get-LeaveDisplay

    if ($null -eq $display) {
        $window.Visibility = [System.Windows.Visibility]::Hidden
        return
    }

    $window.Visibility = [System.Windows.Visibility]::Visible
    $textBlock.Text = $display.Text

    $color = switch ($display.Phase) {
        'before-entry' { '#FF56CCF2' }
        'overtime' { '#FFEB5757' }
        'lunch' { '#FFF2C94C' }
        default { '#FFE8E8E8' }
    }
    $textBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)

    Update-OverlayPosition
    Set-OverlayAlwaysOnTop
}

function Show-WorkdaySettingsDialog {
    $dlg = New-Object System.Windows.Window
    $dlg.Title = 'Workday — Configurar'
    $dlg.Width = 360
    $dlg.SizeToContent = [System.Windows.SizeToContent]::Height
    $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $dlg.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dlg.Topmost = $true
    $dlg.ShowInTaskbar = $true

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = [System.Windows.Thickness]::new(16)

    for ($r = 0; $r -lt 8; $r++) {
        $row = New-Object System.Windows.Controls.RowDefinition
        $row.Height = [System.Windows.GridLength]::Auto
        [void]$grid.RowDefinitions.Add($row)
    }

    $col0 = New-Object System.Windows.Controls.ColumnDefinition
    $col0.Width = [System.Windows.GridLength]::new(180)
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = [System.Windows.GridLength]::new(120)
    [void]$grid.ColumnDefinitions.Add($col0)
    [void]$grid.ColumnDefinitions.Add($col1)

    $fields = @(
        @{ Label = 'Entrada (hora 0-23)'; Key = 'entryHour'; Value = $script:EntryHour }
        @{ Label = 'Almoco inicio (hora)'; Key = 'lunchStartHour'; Value = $script:LunchStartHour }
        @{ Label = 'Almoco fim (hora)'; Key = 'lunchEndHour'; Value = $script:LunchEndHour }
        @{ Label = 'Saida (hora 0-23)'; Key = 'leaveHour'; Value = $script:LeaveHour }
        @{ Label = 'Offset direita (px)'; Key = 'trayOffsetPx'; Value = $script:TrayOffsetPx }
        @{ Label = 'Margem inferior (px)'; Key = 'marginBottom'; Value = $script:MarginBottom }
    )

    $boxes = @{}
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $f = $fields[$i]
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $f.Label
        $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $label.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
        [System.Windows.Controls.Grid]::SetRow($label, $i)
        [System.Windows.Controls.Grid]::SetColumn($label, 0)
        [void]$grid.Children.Add($label)

        $box = New-Object System.Windows.Controls.TextBox
        $box.Text = [string]$f.Value
        $box.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        $box.Padding = [System.Windows.Thickness]::new(4, 2, 4, 2)
        [System.Windows.Controls.Grid]::SetRow($box, $i)
        [System.Windows.Controls.Grid]::SetColumn($box, 1)
        [void]$grid.Children.Add($box)
        $boxes[$f.Key] = $box
    }

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = 'Dica: arraste o overlay para mover; a posicao e salva automaticamente.'
    $hint.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $hint.Foreground = [System.Windows.Media.Brushes]::Gray
    $hint.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)
    [System.Windows.Controls.Grid]::SetRow($hint, 6)
    [System.Windows.Controls.Grid]::SetColumnSpan($hint, 2)
    [void]$grid.Children.Add($hint)

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    [System.Windows.Controls.Grid]::SetRow($buttons, 7)
    [System.Windows.Controls.Grid]::SetColumnSpan($buttons, 2)

    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'Cancelar'
    $cancelBtn.Width = 90
    $cancelBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $cancelBtn.IsCancel = $true

    $saveBtn = New-Object System.Windows.Controls.Button
    $saveBtn.Content = 'Salvar'
    $saveBtn.Width = 90
    $saveBtn.IsDefault = $true

    [void]$buttons.Children.Add($cancelBtn)
    [void]$buttons.Children.Add($saveBtn)
    [void]$grid.Children.Add($buttons)

    $dlg.Content = $grid
    $dlg.Tag = @{
        Boxes = $boxes
    }

    $cancelBtn.Add_Click({
            $dlg.DialogResult = $false
            $dlg.Close()
        }.GetNewClosure())

    $saveBtn.Add_Click({
            $localBoxes = $dlg.Tag.Boxes
            $parsed = @{}
            foreach ($key in @($localBoxes.Keys)) {
                $text = $localBoxes[$key].Text.Trim()
                $n = 0
                if (-not [int]::TryParse($text, [ref]$n)) {
                    [System.Windows.MessageBox]::Show(
                        ('Valor invalido: {0}' -f $key),
                        'Workday',
                        'OK',
                        'Warning') | Out-Null
                    return
                }
                $parsed[$key] = $n
            }

            $cfg = [pscustomobject]@{
                entryHour      = $parsed['entryHour']
                lunchStartHour = $parsed['lunchStartHour']
                lunchEndHour   = $parsed['lunchEndHour']
                leaveHour      = $parsed['leaveHour']
                trayOffsetPx   = $parsed['trayOffsetPx']
                marginBottom   = $parsed['marginBottom']
            }

            $err = ''
            if (-not (Test-WorkdayConfigValid -Config $cfg -ErrorMessage ([ref]$err))) {
                [System.Windows.MessageBox]::Show($err, 'Workday', 'OK', 'Warning') | Out-Null
                return
            }

            Save-WorkdayConfig -Config $cfg
            Apply-WorkdayRuntimeConfig $cfg
            Sync-WorkdaySessions -Quiet -EntryHour $script:EntryHour -LeaveHour $script:LeaveHour | Out-Null
            Update-OverlayPosition
            Update-OverlayDisplay

            $dlg.DialogResult = $true
            $dlg.Close()
        }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

$window = New-Object System.Windows.Window
$window.WindowStyle = [System.Windows.WindowStyle]::None
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.Focusable = $false
$window.ResizeMode = [System.Windows.ResizeMode]::NoResize
$window.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight

$border = New-Object System.Windows.Controls.Border
$border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF2D2D30')
$border.CornerRadius = [System.Windows.CornerRadius]::new(4)
$border.Padding = [System.Windows.Thickness]::new(6, 2, 6, 2)
$border.Cursor = [System.Windows.Input.Cursors]::Hand

$textBlock = New-Object System.Windows.Controls.TextBlock
$textBlock.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
$textBlock.FontSize = 12
$textBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFE8E8E8')
$textBlock.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
$textBlock.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
$textBlock.Text = '--:--:--'

$border.Child = $textBlock
$window.Content = $border

$contextMenu = New-Object System.Windows.Controls.ContextMenu

$extrasItem = New-Object System.Windows.Controls.MenuItem
$extrasItem.Header = 'Ver extras'
$extrasItem.Add_Click({
        $result = Sync-WorkdaySessions -EntryHour $script:EntryHour -LeaveHour $script:LeaveHour
        $report = $result.ReportPath
        if ($report -and (Test-Path -LiteralPath $report)) {
            Invoke-Item -LiteralPath $report
        }
    })
[void]$contextMenu.Items.Add($extrasItem)

$settingsItem = New-Object System.Windows.Controls.MenuItem
$settingsItem.Header = 'Configurar...'
$settingsItem.Add_Click({
        Show-WorkdaySettingsDialog
    })
[void]$contextMenu.Items.Add($settingsItem)

$exitItem = New-Object System.Windows.Controls.MenuItem
$exitItem.Header = 'Sair'
$exitItem.Add_Click({
        [System.Windows.Application]::Current.Shutdown()
    })
[void]$contextMenu.Items.Add($exitItem)
$border.ContextMenu = $contextMenu

$border.Add_MouseLeftButtonDown({
        param($sender, $e)

        if ($e.ClickCount -ge 2) {
            $script:HiddenUntil = (Get-Date).Date.AddDays(1)
            $window.Visibility = [System.Windows.Visibility]::Hidden
            $e.Handled = $true
            return
        }

        if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
            $script:Dragging = $true
            try {
                $window.DragMove()
                Save-WorkdayPositionFromWindow
            }
            catch {
                # DragMove can throw if button already released
            }
            finally {
                $script:Dragging = $false
                Update-OverlayPosition
            }
            $e.Handled = $true
        }
    })

$tickTimer = New-Object System.Windows.Threading.DispatcherTimer
$tickTimer.Interval = [TimeSpan]::FromSeconds(1)
$tickTimer.Add_Tick({ Update-OverlayDisplay })

$layoutTimer = New-Object System.Windows.Threading.DispatcherTimer
$layoutTimer.Interval = [TimeSpan]::FromSeconds(5)
$layoutTimer.Add_Tick({ Update-OverlayPosition })

$window.Add_Loaded({
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $script:WindowHandle = $helper.Handle
        Set-OverlayAlwaysOnTop
        Sync-WorkdaySessions -Quiet -EntryHour $script:EntryHour -LeaveHour $script:LeaveHour | Out-Null
        Update-OverlayDisplay
        $tickTimer.Start()
        $layoutTimer.Start()
    })

$window.Add_Deactivated({
        if ($window.Visibility -eq [System.Windows.Visibility]::Visible) {
            Set-OverlayAlwaysOnTop
        }
    })

$window.Add_IsVisibleChanged({
        param($sender, $e)

        if ($window.Visibility -eq [System.Windows.Visibility]::Visible) {
            Set-OverlayAlwaysOnTop
        }
    })

$app = New-Object System.Windows.Application
$app.Run($window)
