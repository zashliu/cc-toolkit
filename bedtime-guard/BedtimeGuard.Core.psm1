function Get-WindowState {
    param(
        [DateTime]$Beijing,
        [int]$StartMinutes,
        [int]$EndMinutes,
        [int]$WarningLeadSeconds,
        [string]$NightId
    )

    $minutes = $Beijing.Hour * 60 + $Beijing.Minute
    if ($StartMinutes -le $EndMinutes) {
        $inWindow = ($minutes -ge $StartMinutes -and $minutes -lt $EndMinutes)
        $windowStartForNight = $Beijing.Date.AddMinutes($StartMinutes)
    } else {
        $inWindow = ($minutes -ge $StartMinutes -or $minutes -lt $EndMinutes)
        if ($minutes -lt $EndMinutes) { $windowStartForNight = $Beijing.Date.AddMinutes($StartMinutes).AddDays(-1) }
        else                         { $windowStartForNight = $Beijing.Date.AddMinutes($StartMinutes) }
    }

    $secondsUntilWindowStart = [int][Math]::Ceiling(($windowStartForNight - $Beijing).TotalSeconds)
    $inWarning = (-not $inWindow -and $secondsUntilWindowStart -gt 0 -and $secondsUntilWindowStart -le $WarningLeadSeconds)
    [pscustomobject]@{
        InWindow = $inWindow
        InWarning = $inWarning
        WindowStartForNight = $windowStartForNight
        SecondsUntilWindowStart = $secondsUntilWindowStart
        NightId = $(if ($inWindow -or $inWarning) { $NightId } else { '' })
    }
}

Export-ModuleMember -Function Get-WindowState
