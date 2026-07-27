#Requires -Version 5.1
<#
.SYNOPSIS
  Session sync for workday overtime (power on/off via Event Log).
#>

$script:WorkdaySessionsRoot = $PSScriptRoot
$script:WorkdayLookbackDays = 0
$script:WorkdaySuspectHours = 36
$script:WorkdayMinSessionHours = 2
# Ignore Event Log noise from before continuous tracking (April leftovers).
$script:WorkdayEarliestDate = [datetime]'2026-06-01'

function Get-WorkdayDataDir {
    $dir = Join-Path $script:WorkdaySessionsRoot 'data'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-WorkdayConfigPath {
    return (Join-Path (Get-WorkdayDataDir) 'config.json')
}

function Get-WorkdayDefaultConfig {
    return [pscustomobject]@{
        entryHour      = 9
        lunchStartHour = 13
        lunchEndHour   = 14
        leaveHour      = 18
        trayOffsetPx   = 215
        marginBottom   = -35
    }
}

function Read-WorkdayConfig {
    $path = Get-WorkdayConfigPath
    $defaults = Get-WorkdayDefaultConfig

    if (-not (Test-Path -LiteralPath $path)) {
        return $defaults
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $defaults
    }

    $cfg = Get-WorkdayDefaultConfig
    foreach ($name in @('entryHour', 'lunchStartHour', 'lunchEndHour', 'leaveHour', 'trayOffsetPx', 'marginBottom')) {
        if ($null -ne $raw.PSObject.Properties[$name]) {
            $cfg.$name = [int]$raw.$name
        }
    }
    return $cfg
}

function Save-WorkdayConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $path = Get-WorkdayConfigPath
    $obj = [ordered]@{
        entryHour      = [int]$Config.entryHour
        lunchStartHour = [int]$Config.lunchStartHour
        lunchEndHour   = [int]$Config.lunchEndHour
        leaveHour      = [int]$Config.leaveHour
        trayOffsetPx   = [int]$Config.trayOffsetPx
        marginBottom   = [int]$Config.marginBottom
    }
    $json = ($obj | ConvertTo-Json)
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($path, $json + [Environment]::NewLine, $utf8Bom)
}

function Test-WorkdayConfigValid {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,
        [ref]$ErrorMessage
    )

    foreach ($h in @($Config.entryHour, $Config.lunchStartHour, $Config.lunchEndHour, $Config.leaveHour)) {
        if ($h -lt 0 -or $h -gt 23) {
            $ErrorMessage.Value = 'Horas devem estar entre 0 e 23.'
            return $false
        }
    }

    if ($Config.lunchStartHour -ge $Config.lunchEndHour) {
        $ErrorMessage.Value = 'Inicio do almoco deve ser antes do fim do almoco.'
        return $false
    }

    if ($Config.entryHour -ge $Config.leaveHour) {
        $ErrorMessage.Value = 'Entrada deve ser antes da saida.'
        return $false
    }

    if ($Config.lunchStartHour -lt $Config.entryHour -or $Config.lunchEndHour -gt $Config.leaveHour) {
        $ErrorMessage.Value = 'Almoco deve ficar entre entrada e saida.'
        return $false
    }

    return $true
}

function Format-WorkdayDuration([TimeSpan]$span) {
    if ($span -lt [TimeSpan]::Zero) { $span = [TimeSpan]::Zero }
    $hours = [int][Math]::Floor($span.TotalHours)
    return '{0}h{1:D2}m' -f $hours, $span.Minutes
}

function Get-WorkdayIntervalIntersection {
    param(
        [datetime]$RangeStart,
        [datetime]$RangeEnd,
        [datetime]$WindowStart,
        [datetime]$WindowEnd
    )

    $start = if ($RangeStart -gt $WindowStart) { $RangeStart } else { $WindowStart }
    $end = if ($RangeEnd -lt $WindowEnd) { $RangeEnd } else { $WindowEnd }
    if ($end -le $start) {
        return [TimeSpan]::Zero
    }
    return ($end - $start)
}

function Get-WorkdayPowerEvents {
    param(
        [int]$LookbackDays = $script:WorkdayLookbackDays
    )

    # 0 = use everything still retained in the System log (Windows overwrites old events)
    $since = $null
    if ($LookbackDays -gt 0) {
        $since = (Get-Date).AddDays(-$LookbackDays)
    }

    $bag = New-Object System.Collections.ArrayList

    function Read-WorkdayEventBatch {
        param(
            [hashtable]$Filter,
            [string]$Kind,
            [System.Collections.ArrayList]$Target
        )
        try {
            $found = @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)
            foreach ($ev in $found) {
                [void]$Target.Add([pscustomobject]@{
                        Time = $ev.TimeCreated
                        Kind = $Kind
                        Id   = $ev.Id
                    })
            }
        }
        catch {
            if ($_.Exception.Message -notmatch 'No events were found|Nenhum evento|nenhum evento') {
                throw
            }
        }
    }

    function New-WorkdayEventFilter {
        param([hashtable]$Base)
        if ($null -ne $since) {
            $Base['StartTime'] = $since
        }
        return $Base
    }

    # Classic boot/shutdown (when present)
    Read-WorkdayEventBatch -Filter (New-WorkdayEventFilter @{ LogName = 'System'; Id = 12, 6005 }) -Kind 'start' -Target $bag
    Read-WorkdayEventBatch -Filter (New-WorkdayEventFilter @{ LogName = 'System'; Id = 13, 6006 }) -Kind 'stop' -Target $bag

    # Modern hybrid sleep: morning resume = start work session
    Read-WorkdayEventBatch -Filter (New-WorkdayEventFilter @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Power-Troubleshooter'
            Id           = 1
        }) -Kind 'start' -Target $bag

    # Evening "Desligar" / enter sleep = end work session
    Read-WorkdayEventBatch -Filter (New-WorkdayEventFilter @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Kernel-Power'
            Id           = 42
        }) -Kind 'stop' -Target $bag

    Read-WorkdayEventBatch -Filter (New-WorkdayEventFilter @{ LogName = 'System'; Id = 1074 }) -Kind 'stop' -Target $bag

    # Cold boot fallback only when no resume/boot starts were found
    $hasStart = $false
    foreach ($item in $bag) {
        if ($item.Kind -eq 'start') { $hasStart = $true; break }
    }
    if (-not $hasStart) {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        if ($null -eq $since -or $boot -ge $since) {
            [void]$bag.Add([pscustomobject]@{
                    Time = $boot
                    Kind = 'start'
                    Id   = 0
                })
        }
    }

    $events = @($bag | Sort-Object Time)

    # Deduplicate near-duplicate same-kind events (e.g. 1074 + Kernel-Power 42)
    $deduped = New-Object System.Collections.ArrayList
    foreach ($ev in $events) {
        if ($deduped.Count -eq 0) {
            [void]$deduped.Add($ev)
            continue
        }
        $prev = $deduped[$deduped.Count - 1]
        if ($prev.Kind -eq $ev.Kind -and ($ev.Time - $prev.Time).TotalSeconds -lt 120) {
            continue
        }
        [void]$deduped.Add($ev)
    }

    return @($deduped.ToArray())
}

function New-WorkdaySessions {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Events,
        [datetime]$Now = (Get-Date)
    )

    $starts = @($Events | Where-Object { $_.Kind -eq 'start' } | Sort-Object Time)
    $stops = @($Events | Where-Object { $_.Kind -eq 'stop' } | Sort-Object Time)

    $sessions = New-Object System.Collections.ArrayList
    $stopIndex = 0

    for ($i = 0; $i -lt $starts.Count; $i++) {
        $start = $starts[$i].Time
        $nextStart = if ($i + 1 -lt $starts.Count) { $starts[$i + 1].Time } else { $null }

        while ($stopIndex -lt $stops.Count -and $stops[$stopIndex].Time -le $start) {
            $stopIndex++
        }

        $end = $null
        $closedBy = $null

        if ($stopIndex -lt $stops.Count) {
            $candidate = $stops[$stopIndex].Time
            if ($null -eq $nextStart -or $candidate -lt $nextStart) {
                $end = $candidate
                $closedBy = 'event'
                $stopIndex++
            }
        }

        if ($null -eq $end) {
            if ($null -ne $nextStart) {
                $end = $nextStart.AddSeconds(-1)
                $closedBy = 'next-start'
            }
            else {
                $end = $null
                $closedBy = 'open'
            }
        }

        $effectiveEnd = if ($null -eq $end) { $Now } else { $end }
        $duration = $effectiveEnd - $start
        $suspect = $duration.TotalHours -gt $script:WorkdaySuspectHours

        [void]$sessions.Add([pscustomobject]@{
                Start    = $start
                End      = $end
                ClosedBy = $closedBy
                Suspect  = [bool]$suspect
                Source   = 'event-log'
            })
    }

    return @($sessions.ToArray())
}

function Test-WorkdayAtypicalSession {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Session,
        [datetime]$Now = (Get-Date)
    )

    if ($Session.Suspect) {
        return $true
    }

    # Still running today — keep in the main report
    if ($null -eq $Session.End) {
        return $false
    }

    $durationHours = ($Session.End - $Session.Start).TotalHours
    if ($durationHours -lt $script:WorkdayMinSessionHours) {
        return $true
    }

    return $false
}

function Get-WorkdayOvertime {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Session,
        [int]$EntryHour = 9,
        [int]$LeaveHour = 18,
        [datetime]$Now = (Get-Date)
    )

    $rangeStart = $Session.Start
    $rangeEnd = if ($null -eq $Session.End) { $Now } else { $Session.End }
    if ($rangeEnd -le $rangeStart) {
        return @()
    }

    $daySlices = @()
    $day = $rangeStart.Date
    $lastDay = $rangeEnd.Date

    while ($day -le $lastDay) {
        $dayStart = $day
        $dayEnd = $day.AddDays(1)
        $sliceStart = if ($rangeStart -gt $dayStart) { $rangeStart } else { $dayStart }
        $sliceEnd = if ($rangeEnd -lt $dayEnd) { $rangeEnd } else { $dayEnd }

        if ($sliceEnd -gt $sliceStart) {
            $earlyWindowEnd = $day.AddHours($EntryHour)
            $lateWindowStart = $day.AddHours($LeaveHour)

            $early = Get-WorkdayIntervalIntersection -RangeStart $sliceStart -RangeEnd $sliceEnd -WindowStart $dayStart -WindowEnd $earlyWindowEnd
            $late = Get-WorkdayIntervalIntersection -RangeStart $sliceStart -RangeEnd $sliceEnd -WindowStart $lateWindowStart -WindowEnd $dayEnd

            $isWeekend = ($day.DayOfWeek -eq [DayOfWeek]::Saturday) -or ($day.DayOfWeek -eq [DayOfWeek]::Sunday)

            $daySlices += [pscustomobject]@{
                Date       = $day
                SliceStart = $sliceStart
                SliceEnd   = $sliceEnd
                Early      = $early
                Late       = $late
                IsWeekend  = [bool]$isWeekend
                Open       = (($null -eq $Session.End) -and ($day -eq $Now.Date))
            }
        }

        $day = $day.AddDays(1)
    }

    return $daySlices
}

function Save-WorkdaySessions {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Sessions,
        [string]$Path
    )

    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    $lines = foreach ($s in $Sessions) {
        $obj = [ordered]@{
            start    = $s.Start.ToString('o')
            end      = if ($null -eq $s.End) { $null } else { $s.End.ToString('o') }
            closedBy = $s.ClosedBy
            suspect  = [bool]$s.Suspect
            source   = $s.Source
        }
        ($obj | ConvertTo-Json -Compress)
    }

    $content = if ($lines) { ($lines -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    [System.IO.File]::WriteAllText($Path, $content, $utf8Bom)
}

function Write-WorkdayExtrasMarkdown {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Sessions,
        [int]$EntryHour = 9,
        [int]$LeaveHour = 18,
        [string]$Path,
        [datetime]$Now = (Get-Date)
    )

    $weekdayEarly = [TimeSpan]::Zero
    $weekdayLate = [TimeSpan]::Zero
    $weekendEarly = [TimeSpan]::Zero
    $weekendLate = [TimeSpan]::Zero
    $suspectCount = 0
    $atypicalSessions = New-Object System.Collections.ArrayList

    # Aggregate by date: @{ DateKey -> stats }
    $byDay = @{}

    foreach ($session in $Sessions) {
        if ($session.Suspect) {
            $suspectCount++
            continue
        }

        if (Test-WorkdayAtypicalSession -Session $session -Now $Now) {
            [void]$atypicalSessions.Add($session)
            continue
        }

        $slices = Get-WorkdayOvertime -Session $session -EntryHour $EntryHour -LeaveHour $LeaveHour -Now $Now
        foreach ($slice in $slices) {
            $key = $slice.Date.ToString('yyyy-MM-dd')
            if (-not $byDay.ContainsKey($key)) {
                $byDay[$key] = [pscustomobject]@{
                    Date      = $slice.Date
                    IsWeekend = $slice.IsWeekend
                    Early     = [TimeSpan]::Zero
                    Late      = [TimeSpan]::Zero
                    MinStart  = $slice.SliceStart
                    MaxEnd    = $slice.SliceEnd
                    Open      = [bool]$slice.Open
                }
            }

            $row = $byDay[$key]
            $row.Early += $slice.Early
            $row.Late += $slice.Late
            if ($slice.SliceStart -lt $row.MinStart) { $row.MinStart = $slice.SliceStart }
            if ($slice.Open) {
                $row.Open = $true
                $row.MaxEnd = $null
            }
            elseif (-not $row.Open -and $slice.SliceEnd -gt $row.MaxEnd) {
                $row.MaxEnd = $slice.SliceEnd
            }

            if ($slice.IsWeekend) {
                $weekendEarly += $slice.Early
                $weekendLate += $slice.Late
            }
            else {
                $weekdayEarly += $slice.Early
                $weekdayLate += $slice.Late
            }
        }
    }

    $weekdayRows = @($byDay.Values | Where-Object { -not $_.IsWeekend } | Sort-Object Date -Descending)
    $weekendRows = @($byDay.Values | Where-Object { $_.IsWeekend } | Sort-Object Date -Descending)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Extras — workday')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('Atualizado: {0}' -f $Now.ToString('yyyy-MM-dd HH:mm')))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('## Resumo — dias ' + [char]0x00FA + 'teis'))
    [void]$sb.AppendLine('| | Tempo |')
    [void]$sb.AppendLine('|--|--|')
    [void]$sb.AppendLine(('| Antes das {0:D2}:00 | {1} |' -f $EntryHour, (Format-WorkdayDuration $weekdayEarly)))
    [void]$sb.AppendLine(('| Depois das {0:D2}:00 | {1} |' -f $LeaveHour, (Format-WorkdayDuration $weekdayLate)))
    [void]$sb.AppendLine(('| **Total extras** | **{0}** |' -f (Format-WorkdayDuration ($weekdayEarly + $weekdayLate))))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Resumo — fim de semana')
    [void]$sb.AppendLine('| | Tempo |')
    [void]$sb.AppendLine('|--|--|')
    [void]$sb.AppendLine(('| Antes das {0:D2}:00 | {1} |' -f $EntryHour, (Format-WorkdayDuration $weekendEarly)))
    [void]$sb.AppendLine(('| Depois das {0:D2}:00 | {1} |' -f $LeaveHour, (Format-WorkdayDuration $weekendLate)))
    [void]$sb.AppendLine(('| **Total** | **{0}** |' -f (Format-WorkdayDuration ($weekendEarly + $weekendLate))))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('## Por dia (dias ' + [char]0x00FA + 'teis)'))
    [void]$sb.AppendLine('| Data | Ligou | Desligou | Early | Late | Total |')
    [void]$sb.AppendLine('|------|-------|----------|-------|------|-------|')

    foreach ($row in $weekdayRows) {
        $endText = if ($row.Open -or $null -eq $row.MaxEnd) { '_em andamento_' } else { $row.MaxEnd.ToString('HH:mm') }
        $total = $row.Early + $row.Late
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f `
                $row.Date.ToString('yyyy-MM-dd'),
            $row.MinStart.ToString('HH:mm'),
            $endText,
            (Format-WorkdayDuration $row.Early),
            (Format-WorkdayDuration $row.Late),
            (Format-WorkdayDuration $total)))
    }

    if ($weekdayRows.Count -eq 0) {
        [void]$sb.AppendLine('| _(sem dados)_ | | | | | |')
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Por dia (fim de semana)')
    [void]$sb.AppendLine('| Data | Ligou | Desligou | Early | Late | Total | Nota |')
    [void]$sb.AppendLine('|------|-------|----------|-------|------|-------|------|')

    foreach ($row in $weekendRows) {
        $endText = if ($row.Open -or $null -eq $row.MaxEnd) { '_em andamento_' } else { $row.MaxEnd.ToString('HH:mm') }
        $total = $row.Early + $row.Late
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | fim de semana |' -f `
                $row.Date.ToString('yyyy-MM-dd'),
            $row.MinStart.ToString('HH:mm'),
            $endText,
            (Format-WorkdayDuration $row.Early),
            (Format-WorkdayDuration $row.Late),
            (Format-WorkdayDuration $total)))
    }

    if ($weekendRows.Count -eq 0) {
        [void]$sb.AppendLine('| _(sem dados)_ | | | | | | |')
    }

    if ($atypicalSessions.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('## Dias at' + [char]0x00ED + 'picos (omitidos dos totais)'))
        [void]$sb.AppendLine('Sessões curtas (< 2h) — costumam ser wake/sleep acidental, não o expediente.')
        [void]$sb.AppendLine('| Data | Ligou | Desligou | Duração |')
        [void]$sb.AppendLine('|------|-------|----------|---------|')
        foreach ($session in ($atypicalSessions | Sort-Object Start -Descending)) {
            $endText = if ($null -eq $session.End) { '_em andamento_' } else { $session.End.ToString('HH:mm') }
            $dur = if ($null -eq $session.End) { ($Now - $session.Start) } else { ($session.End - $session.Start) }
            [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} |' -f `
                    $session.Start.ToString('yyyy-MM-dd'),
                $session.Start.ToString('HH:mm'),
                $endText,
                (Format-WorkdayDuration $dur)))
        }
    }

    if ($suspectCount -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('> Nota: {0} sess' + [char]0x00E3 + 'o(es) suspeita(s) (dura' + [char]0x00E7 + [char]0x00E3 + 'o > {1}h) omitidas dos totais.' -f $suspectCount, $script:WorkdaySuspectHours))
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $utf8Bom)
}

function Sync-WorkdaySessions {
    param(
        [int]$EntryHour = 9,
        [int]$LeaveHour = 18,
        [int]$LookbackDays = $script:WorkdayLookbackDays,
        [switch]$Quiet
    )

    try {
        $dataDir = Get-WorkdayDataDir
        $jsonPath = Join-Path $dataDir 'sessions.jsonl'
        $mdPath = Join-Path $dataDir 'extras.md'
        $now = Get-Date

        $events = Get-WorkdayPowerEvents -LookbackDays $LookbackDays
        $sessions = @(New-WorkdaySessions -Events $events -Now $now | Where-Object {
                $_.Start.Date -ge $script:WorkdayEarliestDate.Date
            })

        Save-WorkdaySessions -Sessions $sessions -Path $jsonPath
        Write-WorkdayExtrasMarkdown -Sessions $sessions -EntryHour $EntryHour -LeaveHour $LeaveHour -Path $mdPath -Now $now

        return [pscustomobject]@{
            Ok           = $true
            SessionsPath = $jsonPath
            ReportPath   = $mdPath
            SessionCount = $sessions.Count
            Error        = $null
        }
    }
    catch {
        if (-not $Quiet) {
            $msg = 'Nao foi possivel atualizar o log de extras: {0}' -f $_.Exception.Message
            try {
                [System.Windows.MessageBox]::Show($msg, 'workday', 'OK', 'Warning') | Out-Null
            }
            catch {
                Write-Warning $msg
            }
        }

        $dataDir = Join-Path $script:WorkdaySessionsRoot 'data'
        $mdPath = Join-Path $dataDir 'extras.md'
        return [pscustomobject]@{
            Ok           = $false
            SessionsPath = $null
            ReportPath   = $(if (Test-Path -LiteralPath $mdPath) { $mdPath } else { $null })
            SessionCount = 0
            Error        = $_.Exception.Message
        }
    }
}
