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
function Invoke-DscCacheRefresh
{
    [CmdletBinding(HelpUri = '')]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Object[]]
        $Module
    )

    $refreshCache = $false

    $cacheFilePath = if ($IsWindows)
    {
        # PS 6+ on Windows
        Join-Path $env:LocalAppData "dsc\PSAdapterCache.json"
    }
    else
    {
        # either WinPS or PS 6+ on Linux/Mac
        if ($PSVersionTable.PSVersion.Major -le 5)
        {
            Join-Path $env:LocalAppData "dsc\WindowsPSAdapterCache.json"
        }
        else
        {
            Join-Path $env:HOME ".dsc" "PSAdapterCache.json"
        }
    }

    if (Test-Path $cacheFilePath)
    {
        "Reading from Get-DscResource cache file $cacheFilePath" | Write-DscTrace

        $cache = Get-Content -Raw $cacheFilePath | ConvertFrom-Json
        if ($cache.CacheSchemaVersion -ne $script:CurrentCacheSchemaVersion)
        {
            $refreshCache = $true
            "Incompartible version of cache in file '" + $cache.CacheSchemaVersion + "' (expected '" + $script:CurrentCacheSchemaVersion + "')" | Write-DscTrace
        }
        else
        {
            $dscResourceCacheEntries = $cache.ResourceCache

            if ($dscResourceCacheEntries.Count -eq 0)
            {
                # if there is nothing in the cache file - refresh cache
                $refreshCache = $true
                "Filtered DscResourceCache cache is empty" | Write-DscTrace
            }
            elseif ($Module.Count -gt 0)
            {
                $entriesToCheck = @()
                $uniqueModules = $Module | Select-Object -Unique
                # Verify the resource is in the cache
                foreach ($m in $uniqueModules)
                {
                    $entries = $dscResourceCacheEntries | Where-Object { $_.Type -like "$m*" }
                    if ($entries.Count -eq 0)
                    {
                        $refreshCache = $true
                        $resourcesToRefresh = $m
                        "Module $m is not cached" | Write-DscTrace -Operation Warn
                    }
                    else
                    {
                        $entriesToCheck += $entries
                    }
                }
                foreach ($entry in $entriesToCheck)
                {
                    $entry.LastWriteTimes.PSObject.Properties | ForEach-Object {
                        if (Test-StaleCache -ResourcePath $_.Name -CacheWriteTime $_.Value)
                        {
                            $refreshCache = $true
                            $resourcesToRefresh += $entry.Type
                            #break
                        }
                    }
                }
            }
            else
            {
                "Checking cache for stale entries" | Write-DscTrace

                foreach ($cacheEntry in $dscResourceCacheEntries)
                {
                    #"Checking cache entry '$($cacheEntry.Type) $($cacheEntry.LastWriteTimes)'" | Write-DscTrace -Operation Trace

                    $cacheEntry.LastWriteTimes.PSObject.Properties | ForEach-Object {
                        if (Test-StaleCache -ResourcePath $_.Name -CacheWriteTime $_.Value)
                        {
                            $refreshCache = $true
                            break
                        }
                    }
                }

                if (-not $refreshCache)
                {
                    "Checking cache for stale PSModulePath" | Write-DscTrace

                    $m = $env:PSModulePath -split [IO.Path]::PathSeparator | % { Get-ChildItem -Directory -Path $_ -Depth 1 -ea SilentlyContinue }

                    $hs_cache = [System.Collections.Generic.HashSet[string]]($cache.PSModulePaths)
                    $hs_live = [System.Collections.Generic.HashSet[string]]($m.FullName)
                    $hs_cache.SymmetricExceptWith($hs_live)
                    $diff = $hs_cache

                    "PSModulePath diff '$diff'" | Write-DscTrace

                    if ($diff.Count -gt 0)
                    {
                        $refreshCache = $true
                    }
                }
            }
        }
    }
    else
    {
        "Cache file not found '$cacheFilePath'" | Write-DscTrace
        $refreshCache = $true
    }
    
    if ($refreshCache)
    {
        'Constructing Get-DscResource cache' | Write-DscTrace

        # create a list object to store cache of Get-DscResource
        [dscResourceCacheEntry[]]$dscResourceCacheEntries = [System.Collections.Generic.List[Object]]::new()

        # improve by performance by having the option to only get details for named modules
        # workaround for File and SignatureValidation resources that ship in Windows
        if ($null -ne $Module -and 'PSDesiredStateConfiguration' -ne $Module)
        {
            if ($Module.gettype().name -eq 'string')
            {
                $Module = @($Module)
            }
            $dscResources = [System.Collections.Generic.List[Object]]::new()
            $modules = [System.Collections.Generic.List[Object]]::new()
            foreach ($m in $Module)
            {
                $dscResources += Get-DscResource -Module $m
                $modules += Get-Module -Name $m -ListAvailable
            }
        }
        elseif ('PSDesiredStateConfiguration' -eq $Module -and $PSVersionTable.PSVersion.Major -le 5 )
        {
            # the resources in Windows should only load in Windows PowerShell
            # workaround: the binary modules don't have a module name, so we have to special case File and SignatureValidation resources that ship in Windows
            $dscResources = Get-DscResource | Where-Object { $_.modulename -eq 'PSDesiredStateConfiguration' -or ( $_.modulename -eq $null -and $_.parentpath -like "$env:windir\System32\Configuration\*" ) }
        }
        else
        {
            # if no module is specified, get all resources
            $dscResources = Get-DscResource
            $modules = Get-Module -ListAvailable
        }

        $psdscVersion = Get-Module PSDesiredStateConfiguration | Sort-Object -descending | Select-Object -First 1 | ForEach-Object Version

        foreach ($dscResource in $dscResources)
        {
            # resources that shipped in Windows should only be used with Windows PowerShell
            if ($dscResource.ParentPath -like "$env:windir\System32\*" -and $PSVersionTable.PSVersion.Major -gt 5)
            {
                continue
            }

            # we can't run this check in PSDesiredStateConfiguration 1.1 because the property doesn't exist
            if ( $psdscVersion -ge '2.0.7' )
            {
                # only support known dscResourceType
                if ([dscResourceType].GetEnumNames() -notcontains $dscResource.ImplementationDetail)
                {
                    'WARNING: implementation detail not found: ' + $dscResource.ImplementationDetail | Write-DscTrace
                    continue
                }
            }

            # workaround: if the resource does not have a module name, get it from parent path
            # workaround: modulename is not settable, so clone the object without being read-only
            # workaround: we have to special case File and SignatureValidation resources that ship in Windows
            $binaryBuiltInModulePaths = @(
                "$env:windir\system32\Configuration\Schema\MSFT_FileDirectoryConfiguration"
                "$env:windir\system32\Configuration\BaseRegistration"
            )
            $dscResourceInfo = [DscResourceInfo]::new()
            $dscResource.PSObject.Properties | ForEach-Object -Process {
                if ($null -ne $_.Value)
                {
                    $dscResourceInfo.$($_.Name) = $_.Value
                }
                else
                {
                    $dscResourceInfo.$($_.Name) = ''
                }
            }

            if ($dscResource.ModuleName)
            {
                $moduleName = $dscResource.ModuleName
            }
            elseif ($binaryBuiltInModulePaths -contains $dscResource.ParentPath)
            {
                $moduleName = 'PSDesiredStateConfiguration'
                $dscResourceInfo.Module = 'PSDesiredStateConfiguration'
                $dscResourceInfo.ModuleName = 'PSDesiredStateConfiguration'
                $dscResourceInfo.CompanyName = 'Microsoft Corporation'
                $dscResourceInfo.Version = '1.0.0'
                if ($PSVersionTable.PSVersion.Major -le 5 -and $dscResourceInfo.ImplementedAs -eq 'Binary')
                {
                    $dscResourceInfo.ImplementationDetail = 'Binary'
                }
            }
            elseif ($binaryBuiltInModulePaths -notcontains $dscResource.ParentPath -and $null -ne $dscResource.ParentPath)
            {
                # workaround: populate module name from parent path that is three levels up
                $moduleName = Split-Path $dscResource.ParentPath | Split-Path | Split-Path -Leaf
                $dscResourceInfo.Module = $moduleName
                $dscResourceInfo.ModuleName = $moduleName
                # workaround: populate module version from psmoduleinfo if available
                if ($moduleInfo = $modules | Where-Object { $_.Name -eq $moduleName })
                {
                    $moduleInfo = $moduleInfo | Sort-Object -Property Version -Descending | Select-Object -First 1
                    $dscResourceInfo.Version = $moduleInfo.Version.ToString()
                }
            }

            # fill in resource files (and their last-write-times) that will be used for up-do-date checks
            $lastWriteTimes = @{}
            Get-ChildItem -Recurse -File -Path $dscResource.ParentPath -Include "*.ps1", "*.psd1", "*psm1", "*.mof" -ea Ignore | % {
                $lastWriteTimes.Add($_.FullName, $_.LastWriteTime)
            }

            $dscResourceCacheEntries += [dscResourceCacheEntry]@{
                Type            = "$moduleName/$($dscResource.Name)"
                DscResourceInfo = $dscResourceInfo
                LastWriteTimes  = $lastWriteTimes
            }
        }

        [dscResourceCache]$cache = [dscResourceCache]::new()
        $cache.ResourceCache = $dscResourceCacheEntries
        $m = $env:PSModulePath -split [IO.Path]::PathSeparator | % { Get-ChildItem -Directory -Path $_ -Depth 1 -ea SilentlyContinue }
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