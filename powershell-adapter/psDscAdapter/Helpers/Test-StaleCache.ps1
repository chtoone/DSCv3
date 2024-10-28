function Test-StaleCache
{
    param
    (
        [string]$ResourcePath,
        [string]$CacheWriteTime
    )
    
    if (Test-Path $ResourcePath)
    {
        $file_LastWriteTime = (Get-Item $ResourcePath).LastWriteTimeUtc
        # Truncate DateTime to seconds
        $file_LastWriteTime = $file_LastWriteTime.AddTicks( - ($file_LastWriteTime.Ticks % [TimeSpan]::TicksPerSecond))

        $cache_LastWriteTime = [DateTime]$CacheWriteTime
        # Truncate DateTime to seconds
        $cache_LastWriteTime = $cache_LastWriteTime.AddTicks( - ($cache_LastWriteTime.Ticks % [TimeSpan]::TicksPerSecond))

        if (-not ($file_LastWriteTime.Equals($cache_LastWriteTime)))
        {
            "Detected stale cache entry '$ResourcePath'" | Write-DscTrace
            $refreshCache = $true
            break
        } 
    }
    else
    {
        "Detected non-existent cache entry '$ResourcePath'" | Write-DscTrace
        $refreshCache = $true
        break
    }
}