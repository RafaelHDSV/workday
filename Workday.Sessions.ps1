#Requires -Version 5.1
<#
.SYNOPSIS
  Session sync for workday overtime (power on/off via Event Log).
#>

$script:WorkdaySessionsRoot = $PSScriptRoot
$script:WorkdayLookbackDays = 0
$script:WorkdaySuspectHours = 36
$script:WorkdayMinSessionHours = 2
# Same-day sessions separated by a shorter gap are treated as one workday (PC restart).
$script:WorkdayMergeGapMinutes = 30
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
        entryHour        = 9
        lunchStartHour   = 13
        lunchEndHour     = 14
        leaveHour        = 18
        trayOffsetPx     = 215
        marginBottom     = -35
        omitExtrasDates  = @()
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
    if ($null -ne $raw.PSObject.Properties['omitExtrasDates'] -and $null -ne $raw.omitExtrasDates) {
        $cfg.omitExtrasDates = @($raw.omitExtrasDates | ForEach-Object { [string]$_ })
    }
    return $cfg
}

function Save-WorkdayConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $path = Get-WorkdayConfigPath
    $omit = @()
    if ($null -ne $Config.PSObject.Properties['omitExtrasDates'] -and $null -ne $Config.omitExtrasDates) {
        $omit = @($Config.omitExtrasDates | ForEach-Object { [string]$_ })
    }
    $obj = [ordered]@{
        entryHour       = [int]$Config.entryHour
        lunchStartHour  = [int]$Config.lunchStartHour
        lunchEndHour    = [int]$Config.lunchEndHour
        leaveHour       = [int]$Config.leaveHour
        trayOffsetPx    = [int]$Config.trayOffsetPx
        marginBottom    = [int]$Config.marginBottom
        omitExtrasDates = $omit
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

function Format-WorkdaySignedDuration([TimeSpan]$span) {
    $sign = if ($span -lt [TimeSpan]::Zero) { '-' } else { '' }
    $abs = if ($span -lt [TimeSpan]::Zero) { -$span } else { $span }
    return $sign + (Format-WorkdayDuration $abs)
}

function Get-WorkdayDayShort {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Row,
        [int]$LeaveHour = 18,
        [bool]$OmitExtras = $false
    )

    if ($OmitExtras -or $Row.Open -or $null -eq $Row.MaxEnd -or $Row.IsWeekend) {
        return [TimeSpan]::Zero
    }

    $leaveAt = $Row.Date.AddHours($LeaveHour)
    if ($Row.MaxEnd -lt $leaveAt) {
        return $leaveAt - $Row.MaxEnd
    }

    return [TimeSpan]::Zero
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

function Merge-WorkdaySameDaySessions {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Sessions,
        [int]$MaxGapMinutes = $script:WorkdayMergeGapMinutes
    )

    if ($Sessions.Count -eq 0) {
        return @()
    }

    $sorted = @($Sessions | Sort-Object Start)
    $merged = New-Object System.Collections.ArrayList
    $current = $sorted[0]

    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $next = $sorted[$i]
        $sameDay = ($current.Start.Date -eq $next.Start.Date)
        $gap = if ($null -eq $current.End) {
            [TimeSpan]::MaxValue
        }
        else {
            $next.Start - $current.End
        }
        $canMerge = $sameDay -and ($null -ne $current.End) -and ($gap.TotalMinutes -le $MaxGapMinutes)

        if ($canMerge) {
            $current = [pscustomobject]@{
                Start    = $current.Start
                End      = $next.End
                ClosedBy = $next.ClosedBy
                Suspect  = [bool]($current.Suspect -or $next.Suspect)
                Source   = 'merged'
            }
        }
        else {
            [void]$merged.Add($current)
            $current = $next
        }
    }

    [void]$merged.Add($current)
    return @($merged.ToArray())
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
        [string[]]$OmitExtrasDates = @(),
        [string]$Path,
        [datetime]$Now = (Get-Date)
    )

    $weekdayEarly = [TimeSpan]::Zero
    $weekdayLate = [TimeSpan]::Zero
    $weekdayShort = [TimeSpan]::Zero
    $weekendEarly = [TimeSpan]::Zero
    $weekendLate = [TimeSpan]::Zero
    $suspectCount = 0
    $atypicalSessions = New-Object System.Collections.ArrayList
    $omitSet = @{}
    foreach ($d in @($OmitExtrasDates)) {
        if (-not [string]::IsNullOrWhiteSpace($d)) {
            $omitSet[$d.Trim()] = $true
        }
    }
    $omittedApplied = New-Object System.Collections.ArrayList

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
            $omitExtras = $omitSet.ContainsKey($key)
            $early = if ($omitExtras) { [TimeSpan]::Zero } else { $slice.Early }
            $late = if ($omitExtras) { [TimeSpan]::Zero } else { $slice.Late }
            if ($omitExtras -and ($omittedApplied -notcontains $key)) {
                [void]$omittedApplied.Add($key)
            }

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
            $row.Early += $early
            $row.Late += $late
            if ($slice.SliceStart -lt $row.MinStart) { $row.MinStart = $slice.SliceStart }
            if ($slice.Open) {
                $row.Open = $true
                $row.MaxEnd = $null
            }
            elseif (-not $row.Open -and $slice.SliceEnd -gt $row.MaxEnd) {
                $row.MaxEnd = $slice.SliceEnd
            }

            if ($slice.IsWeekend) {
                $weekendEarly += $early
                $weekendLate += $late
            }
            else {
                $weekdayEarly += $early
                $weekdayLate += $late
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
    foreach ($row in $weekdayRows) {
        $key = $row.Date.ToString('yyyy-MM-dd')
        $omitExtras = $omitSet.ContainsKey($key)
        $weekdayShort += (Get-WorkdayDayShort -Row $row -LeaveHour $LeaveHour -OmitExtras $omitExtras)
    }

    [void]$sb.AppendLine(('| Antes das {0:D2}:00 | {1} |' -f $EntryHour, (Format-WorkdayDuration $weekdayEarly)))
    [void]$sb.AppendLine(('| Depois das {0:D2}:00 | {1} |' -f $LeaveHour, (Format-WorkdayDuration $weekdayLate)))
    [void]$sb.AppendLine(('| Sa' + [char]0x00ED + 'da antecipada | {0} |' -f (Format-WorkdayDuration $weekdayShort)))
    [void]$sb.AppendLine(('| **Total l' + [char]0x00ED + 'quido** | **{0}** |' -f (Format-WorkdaySignedDuration ($weekdayEarly + $weekdayLate - $weekdayShort))))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Resumo — fim de semana')
    [void]$sb.AppendLine('| | Tempo |')
    [void]$sb.AppendLine('|--|--|')
    [void]$sb.AppendLine(('| Antes das {0:D2}:00 | {1} |' -f $EntryHour, (Format-WorkdayDuration $weekendEarly)))
    [void]$sb.AppendLine(('| Depois das {0:D2}:00 | {1} |' -f $LeaveHour, (Format-WorkdayDuration $weekendLate)))
    [void]$sb.AppendLine(('| **Total** | **{0}** |' -f (Format-WorkdayDuration ($weekendEarly + $weekendLate))))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('## Por dia (dias ' + [char]0x00FA + 'teis)'))
    [void]$sb.AppendLine('| Data | Ligou | Desligou | Early | Late | Short | Total |')
    [void]$sb.AppendLine('|------|-------|----------|-------|------|-------|-------|')

    foreach ($row in $weekdayRows) {
        $key = $row.Date.ToString('yyyy-MM-dd')
        $omitExtras = $omitSet.ContainsKey($key)
        $endText = if ($row.Open -or $null -eq $row.MaxEnd) { '_em andamento_' } else { $row.MaxEnd.ToString('HH:mm') }
        $short = Get-WorkdayDayShort -Row $row -LeaveHour $LeaveHour -OmitExtras $omitExtras
        $net = $row.Early + $row.Late - $short
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
                $row.Date.ToString('yyyy-MM-dd'),
            $row.MinStart.ToString('HH:mm'),
            $endText,
            (Format-WorkdayDuration $row.Early),
            (Format-WorkdayDuration $row.Late),
            (Format-WorkdayDuration $short),
            (Format-WorkdaySignedDuration $net)))
    }

    if ($weekdayRows.Count -eq 0) {
        [void]$sb.AppendLine('| _(sem dados)_ | | | | | | |')
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
        [void]$sb.AppendLine('Sessões curtas (< 2h) sem continuação no mesmo dia — costumam ser wake/sleep acidental, não o expediente.')
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

    if ($omittedApplied.Count -gt 0) {
        $list = ($omittedApplied | Sort-Object) -join ', '
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('> Extras zerados (omitExtrasDates): {0}' -f $list))
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
        $reportSessions = Merge-WorkdaySameDaySessions -Sessions $sessions
        $cfg = Read-WorkdayConfig
        $omitDates = @()
        if ($null -ne $cfg.PSObject.Properties['omitExtrasDates'] -and $null -ne $cfg.omitExtrasDates) {
            $omitDates = @($cfg.omitExtrasDates)
        }
        Write-WorkdayExtrasMarkdown -Sessions $reportSessions -EntryHour $EntryHour -LeaveHour $LeaveHour -OmitExtrasDates $omitDates -Path $mdPath -Now $now

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
