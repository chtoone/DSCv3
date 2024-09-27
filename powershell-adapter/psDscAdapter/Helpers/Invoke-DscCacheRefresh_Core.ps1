<# public function Invoke-DscCacheRefresh
.SYNOPSIS
    This function caches the results of the Get-DscResource call to optimize performance.

.DESCRIPTION
    This function is designed to improve the performance of DSC operations by caching the results of the Get-DscResource call. 
    By storing the results, subsequent calls to Get-DscResource can retrieve the cached data instead of making a new call each time. 
    This can significantly speed up operations that need to repeatedly access DSC resources.

.EXAMPLE
    Invoke-DscCacheRefresh -Module "PSDesiredStateConfiguration"
#>
function Invoke-DscCacheRefresh {
    [CmdletBinding(HelpUri = '')]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Object[]]
        $Module
    )

    $refreshCache = $false

    $cacheFilePath = if ($IsWindows) {
        # PS 6+ on Windows
        Join-Path $env:LocalAppData "dsc\PSAdapterCache.json"
    } else {
        # PS 6+ on Linux/Mac
        Join-Path $env:HOME ".dsc" "PSAdapterCache.json"
    }

    if (Test-Path $cacheFilePath) {
        "Reading from Get-DscResource cache file $cacheFilePath" | Write-DscTrace

        $cache = Get-Content -Raw $cacheFilePath | ConvertFrom-Json

        if ($cache.CacheSchemaVersion -ne $script:CurrentCacheSchemaVersion) {
            $refreshCache = $true
            "Incompatible version of cache in file '"+$cache.CacheSchemaVersion+"' (expected '"+$script:CurrentCacheSchemaVersion+"')" | Write-DscTrace
        } else {
            $dscResourceCacheEntries = $cache.ResourceCache

            if ($dscResourceCacheEntries.Count -eq 0) {
                # if there is nothing in the cache file - refresh cache
                $refreshCache = $true

                "Filtered DscResourceCache cache is empty" | Write-DscTrace
            }
            else
            {
                "Checking cache for stale entries" | Write-DscTrace

                foreach ($cacheEntry in $dscResourceCacheEntries) {

                    $cacheEntry.LastWriteTimes.PSObject.Properties | ForEach-Object {
                    
                        if (Test-Path $_.Name) {
                            $file_LastWriteTime = (Get-Item $_.Name).LastWriteTime
                            # Truncate DateTime to seconds
                            $file_LastWriteTime = $file_LastWriteTime.AddTicks( - ($file_LastWriteTime.Ticks % [TimeSpan]::TicksPerSecond));

                            $cache_LastWriteTime = [DateTime]$_.Value
                            # Truncate DateTime to seconds
                            $cache_LastWriteTime = $cache_LastWriteTime.AddTicks( - ($cache_LastWriteTime.Ticks % [TimeSpan]::TicksPerSecond));

                            if (-not ($file_LastWriteTime.Equals($cache_LastWriteTime)))
                            {
                                "Detected stale cache entry '$($_.Name)'" | Write-DscTrace
                                $refreshCache = $true
                                break
                            }
                        } else {
                            "Detected non-existent cache entry '$($_.Name)'" | Write-DscTrace
                            $refreshCache = $true
                            break
                        }
                    }

                    if ($refreshCache) {break}
                }

                if (-not $refreshCache) {
                    "Checking cache for stale PSModulePath" | Write-DscTrace

                    $m = $env:PSModulePath -split [IO.Path]::PathSeparator | %{Get-ChildItem -Directory -Path $_ -Depth 1 -ea SilentlyContinue}

                    $hs_cache = [System.Collections.Generic.HashSet[string]]($cache.PSModulePaths)
                    $hs_live = [System.Collections.Generic.HashSet[string]]($m.FullName)
                    $hs_cache.SymmetricExceptWith($hs_live)
                    $diff = $hs_cache

                    "PSModulePath diff '$diff'" | Write-DscTrace

                    if ($diff.Count -gt 0) {
                        $refreshCache = $true
                    }
                }
            }
        }
    }
    else {
        "Cache file not found '$cacheFilePath'" | Write-DscTrace
        $refreshCache = $true
    }
    
    if ($refreshCache) {
        'Constructing Get-DscResource cache' | Write-DscTrace

        # create a list object to store cache of Get-DscResource
        [dscResourceCacheEntry[]]$dscResourceCacheEntries = [System.Collections.Generic.List[Object]]::new()

        $DscResources = [System.Collections.Generic.List[DscResourceInfo]]::new()
        $dscResourceModulePsd1s = Get-DSCResourceModules
        if($null -ne $dscResourceModulePsd1s) {
            $modules = Get-Module -ListAvailable -Name ($dscResourceModulePsd1s)
            $processedModuleNames = @{}
            foreach ($mod in $modules)
            {
                if (-not ($processedModuleNames.ContainsKey($mod.Name))) {
                    $processedModuleNames.Add($mod.Name, $true)

                    # from several modules with the same name select the one with the highest version
                    $selectedMod = $modules | Where-Object Name -EQ $mod.Name 
                    if ($selectedMod.Count -gt 1) {
                        "Found $($selectedMod.Count) modules with name '$($mod.Name)'" | Write-DscTrace -Operation Trace
                        $selectedMod = $selectedMod | Sort-Object -Property Version -Descending | Select-Object -First 1
                    }

                    [System.Collections.Generic.List[DscResourceInfo]]$r = LoadPowerShellClassResourcesFromModule -moduleInfo $selectedMod
                    if ($r) {
                        $DscResources.AddRange($r)
                    }
                }
            }
        }

        foreach ($dscResource in $DscResources) {
            $moduleName = $dscResource.ModuleName

            # fill in resource files (and their last-write-times) that will be used for up-do-date checks
            $lastWriteTimes = @{}
            Get-ChildItem -Recurse -File -Path $dscResource.ParentPath -Include "*.ps1","*.psd1","*psm1","*.mof" -ea Ignore | % {
                $lastWriteTimes.Add($_.FullName, $_.LastWriteTime)
            }

            $dscResourceCacheEntries += [dscResourceCacheEntry]@{
                Type            = "$moduleName/$($dscResource.Name)"
                DscResourceInfo = $dscResource
                LastWriteTimes = $lastWriteTimes
            }
        }

        [dscResourceCache]$cache = [dscResourceCache]::new()
        $cache.ResourceCache = $dscResourceCacheEntries
        $m = $env:PSModulePath -split [IO.Path]::PathSeparator | %{Get-ChildItem -Directory -Path $_ -Depth 1 -ea SilentlyContinue}
        $cache.PSModulePaths = $m.FullName
        $cache.CacheSchemaVersion = $script:CurrentCacheSchemaVersion

        # save cache for future use
        # TODO: replace this with a high-performance serializer
        "Saving Get-DscResource cache to '$cacheFilePath'" | Write-DscTrace
        $jsonCache = $cache | ConvertTo-Json -Depth 90
        New-Item -Force -Path $cacheFilePath -Value $jsonCache -Type File | Out-Null
    }

    return $dscResourceCacheEntries
}