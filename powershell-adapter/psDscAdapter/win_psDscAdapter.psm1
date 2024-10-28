# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

$script:CurrentCacheSchemaVersion = 1

$moduleRoot = (Get-Item -Path $PSScriptRoot).Parent
# All generic helpers
$moduleRoot.EnumerateFiles("Helpers/*.ps1").Where({ $_.Name -notmatch "_Core\.ps1|_Desktop\.ps1"}).ForEach({. $_.FullName})
# Desktop specific helpers
if ($IsWindows) {
    $moduleRoot.EnumerateFiles("Helpers/*.ps1").Where({ $_.Name -match "_Desktop\.ps1"}).ForEach({. $_.FullName})
}

function Write-DscTrace {
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')]
        [string]$Operation = 'Debug',

        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Message
    )

    $trace = @{$Operation = $Message } | ConvertTo-Json -Compress
    $host.ui.WriteErrorLine($trace)
}

# if the version of PowerShell is greater than 5, import the PSDesiredStateConfiguration module
# this is necessary because the module is not included in the PowerShell 7.0+ releases;
# In Windows PowerShell, we should always use version 1.1 that ships in Windows.
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $m = Get-Module PSDesiredStateConfiguration -ListAvailable | Sort-Object -Descending | Select-Object -First 1
    $PSDesiredStateConfiguration = Import-Module $m -Force -PassThru
}
else {
    $env:PSModulePath += ";$env:windir\System32\WindowsPowerShell\v1.0\Modules"
    $PSDesiredStateConfiguration = Import-Module -Name 'PSDesiredStateConfiguration' -RequiredVersion '1.1' -Force -PassThru -ErrorAction stop -ErrorVariable $importModuleError
    if (-not [string]::IsNullOrEmpty($importModuleError)) {
        'Could not import PSDesiredStateConfiguration 1.1 in Windows PowerShell. ' + $importModuleError | Write-DscTrace -Operation Error
    }
}

# Convert the INPUT to a dscResourceObject object so configuration and resource are standardized as much as possible
function Get-DscResourceObject {
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $jsonInput
    )
    # normalize the INPUT object to an array of dscResourceObject objects
    $inputObj = $jsonInput | ConvertFrom-Json
    $desiredState = [System.Collections.Generic.List[Object]]::new()

    # catch potential for improperly formatted configuration input
    if ($inputObj.resources -and -not $inputObj.metadata.'Microsoft.DSC'.context -eq 'configuration') {
        'The input has a top level property named "resources" but is not a configuration. If the input should be a configuration, include the property: "metadata": {"Microsoft.DSC": {"context": "Configuration"}}' | Write-DscTrace -Operation Warn
    }

    # match adapter to version of powershell
    if ($PSVersionTable.PSVersion.Major -le 5) {
        $adapterName = 'Microsoft.Windows/WindowsPowerShell'
    }
    else {
        $adapterName = 'Microsoft.DSC/PowerShell'
    }

    if ($null -ne $inputObj.metadata -and $null -ne $inputObj.metadata.'Microsoft.DSC' -and $inputObj.metadata.'Microsoft.DSC'.context -eq 'configuration') {
        # change the type from pscustomobject to dscResourceObject
        $inputObj.resources | ForEach-Object -Process {
            $desiredState += [dscResourceObject]@{
                name       = $_.name
                type       = $_.type
                properties = $_.properties
            }
        }
    }
    else {
        # mimic a config object with a single resource
        $type = $inputObj.adapted_dsc_type
        $inputObj.psobject.properties.Remove('adapted_dsc_type')
        $desiredState += [dscResourceObject]@{
            name       = $adapterName
            type       = $type
            properties = $inputObj
        }
    }
    return $desiredState
}

# Get the actual state using DSC Get method from any type of DSC resource
function Invoke-DscOperation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Set', 'Test', 'Export')]
        [string]$Operation,
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        [dscResourceObject]$DesiredState,
        [Parameter(Mandatory)]
        [dscResourceCacheEntry[]]$dscResourceCache
    )

    $osVersion = [System.Environment]::OSVersion.VersionString
    'OS version: ' + $osVersion | Write-DscTrace

    $psVersion = $PSVersionTable.PSVersion.ToString()
    'PowerShell version: ' + $psVersion | Write-DscTrace

    $moduleVersion = Get-Module PSDesiredStateConfiguration | ForEach-Object Version
    'PSDesiredStateConfiguration module version: ' + $moduleVersion | Write-DscTrace

    # get details from cache about the DSC resource, if it exists
    $cachedDscResourceInfo = $dscResourceCache | Where-Object Type -EQ $DesiredState.type | ForEach-Object DscResourceInfo

    # if the resource is found in the cache, get the actual state
    if ($cachedDscResourceInfo) {

        # formated OUTPUT of each resource
        $addToActualState = [dscResourceObject]@{}

        # set top level properties of the OUTPUT object from INPUT object
        $DesiredState.psobject.properties | ForEach-Object -Process {
            if ($_.TypeNameOfValue -EQ 'System.String') { $addToActualState.$($_.Name) = $DesiredState.($_.Name) }
        }

        'DSC resource implementation: ' + [dscResourceType]$cachedDscResourceInfo.ImplementationDetail | Write-DscTrace

        # workaround: script based resources do not validate Get parameter consistency, so we need to remove any parameters the author chose not to include in Get-TargetResource
        switch ([dscResourceType]$cachedDscResourceInfo.ImplementationDetail) {
            'ScriptBased' {

                # For Linux/MacOS, only class based resources are supported and are called directly.
                if ($IsLinux) {
                    'Script based resources are only supported on Windows.' | Write-DscTrace -Operation Error
                    exit 1
                }

                # imports the .psm1 file for the DSC resource as a PowerShell module and stores the list of parameters
                Import-Module -Scope Local -Name $cachedDscResourceInfo.path -Force -ErrorAction stop
                $validParams = (Get-Command -Module $cachedDscResourceInfo.ResourceType -Name 'Get-TargetResource').Parameters.Keys

                if ($Operation -eq 'Get') {
                    # prune any properties that are not valid parameters of Get-TargetResource
                    $DesiredState.properties.psobject.properties | ForEach-Object -Process {
                        if ($validParams -notcontains $_.Name) {
                            $DesiredState.properties.psobject.properties.Remove($_.Name)
                        }
                    }
                }

                # morph the INPUT object into a hashtable named "property" for the cmdlet Invoke-DscResource
                $DesiredState.properties.psobject.properties | ForEach-Object -Begin { $property = @{} } -Process { $property[$_.Name] = $_.Value }

                # using the cmdlet the appropriate dsc module, and handle errors
                try {
                    $invokeResult = Invoke-DscResource -Method $Operation -ModuleName $cachedDscResourceInfo.ModuleName -Name $cachedDscResourceInfo.Name -Property $property

                    if ($invokeResult.GetType().Name -eq 'Hashtable') {
                        $invokeResult.keys | ForEach-Object -Begin { $ResultProperties = @{} } -Process { $ResultProperties[$_] = $invokeResult.$_ }
                    }
                    else {
                        # the object returned by WMI is a CIM instance with a lot of additional data. only return DSC properties
                        $invokeResult.psobject.Properties.name | Where-Object { 'CimClass', 'CimInstanceProperties', 'CimSystemProperties' -notcontains $_ } | ForEach-Object -Begin { $ResultProperties = @{} } -Process { $ResultProperties[$_] = $invokeResult.$_ }
                    }
                    
                    # set the properties of the OUTPUT object from the result of Get-TargetResource
                    $addToActualState.properties = $ResultProperties
                }
                catch {
                    'Exception: ' + $_.Exception.Message | Write-DscTrace -Operation Error
                    exit 1
                }
            }
            'ClassBased' {
                try {
                    # load powershell class from external module
                    $resource = GetTypeInstanceFromModule -modulename $cachedDscResourceInfo.ModuleName -classname $cachedDscResourceInfo.Name
                    $dscResourceInstance = $resource::New()

                    if ($DesiredState.properties) {
                        # set each property of $dscResourceInstance to the value of the property in the $desiredState INPUT object
                        $DesiredState.properties.psobject.properties | ForEach-Object -Process {
                            $dscResourceInstance.$($_.Name) = $_.Value
                        }
                    }

                    switch ($Operation) {
                        'Get' {
                            $Result = $dscResourceInstance.Get()
                            $addToActualState.properties = $Result
                        }
                        'Set' {
                            $dscResourceInstance.Set()
                        }
                        'Test' {
                            $Result = $dscResourceInstance.Test()
                            $addToActualState.properties = [psobject]@{'InDesiredState'=$Result} 
                        }
                        'Export' {
                            $t = $dscResourceInstance.GetType()
                            $method = $t.GetMethod('Export')
                            $resultArray = $method.Invoke($null,$null)
                            $addToActualState = $resultArray
                        }
                    }
                }
                catch {
                    
                    'Exception: ' + $_.Exception.Message | Write-DscTrace -Operation Error
                    exit 1
                }
            }
            'Binary' {
                if ($PSVersionTable.PSVersion.Major -gt 5) {
                    'To use a binary resource such as File, Log, or SignatureValidation, use the Microsoft.Windows/WindowsPowerShell adapter.' | Write-DscTrace
                    exit 1
                }

                if (-not (($cachedDscResourceInfo.ImplementedAs -eq 'Binary') -and ('File', 'Log', 'SignatureValidation' -contains $cachedDscResourceInfo.Name))) {
                    'Only File, Log, and SignatureValidation are supported as Binary resources.' | Write-DscTrace
                    exit 1
                }

                # morph the INPUT object into a hashtable named "property" for the cmdlet Invoke-DscResource
                $DesiredState.properties.psobject.properties | ForEach-Object -Begin { $property = @{} } -Process { $property[$_.Name] = $_.Value }
                # using the cmdlet from PSDesiredStateConfiguration module in Windows
                try {
                    $invokeResult = Invoke-DscResource -Method $Operation -ModuleName $cachedDscResourceInfo.ModuleName -Name $cachedDscResourceInfo.Name -Property $property
                    if ($invokeResult.GetType().Name -eq 'Hashtable') {
                        $invokeResult.keys | ForEach-Object -Begin { $ResultProperties = @{} } -Process { $ResultProperties[$_] = $invokeResult.$_ }
                    }
                    else {
                        # the object returned by WMI is a CIM instance with a lot of additional data. only return DSC properties
                        $invokeResult.psobject.Properties.name | Where-Object { 'CimClass', 'CimInstanceProperties', 'CimSystemProperties' -notcontains $_ } | ForEach-Object -Begin { $ResultProperties = @{} } -Process { $ResultProperties[$_] = $invokeResult.$_ }
                    }
                    
                    # set the properties of the OUTPUT object from the result of Get-TargetResource
                    $addToActualState.properties = $ResultProperties
                }
                catch {
                    'Exception: ' + $_.Exception.Message | Write-DscTrace -Operation Error
                    exit 1
                }
            }
            Default {
                'Can not find implementation of type: ' + $cachedDscResourceInfo.ImplementationDetail | Write-DscTrace
                exit 1
            }
        }

        return $addToActualState
    }
    else {
        $dsJSON = $DesiredState | ConvertTo-Json -Depth 10
        'Can not find type "' + $DesiredState.type + '" for resource "' + $dsJSON + '". Please ensure that Get-DscResource returns this resource type.' | Write-DscTrace -Operation Error
        exit 1
    }
}

# GetTypeInstanceFromModule function to get the type instance from the module
function GetTypeInstanceFromModule {
    param(
        [Parameter(Mandatory = $true)]
        [string] $modulename,
        [Parameter(Mandatory = $true)]
        [string] $classname
    )
    $instance = & (Import-Module $modulename -PassThru) ([scriptblock]::Create("'$classname' -as 'type'"))
    return $instance
}

# cached resource
class dscResourceCacheEntry {
    [string] $Type
    [psobject] $DscResourceInfo
    [PSCustomObject] $LastWriteTimes
}

class dscResourceCache {
    [int] $CacheSchemaVersion
    [string[]] $PSModulePaths
    [dscResourceCacheEntry[]] $ResourceCache
}

# format expected for configuration and resource output
class dscResourceObject {
    [string] $name
    [string] $type
    [psobject] $properties
}

# dsc resource types
enum dscResourceType {
    ScriptBased
    ClassBased
    Binary
    Composite
}

# dsc resource type (settable clone)
class DscResourceInfo {
    [dscResourceType] $ImplementationDetail
    [string] $ResourceType
    [string] $Name
    [string] $FriendlyName
    [string] $Module
    [string] $ModuleName
    [string] $Version
    [string] $Path
    [string] $ParentPath
    [string] $ImplementedAs
    [string] $CompanyName
    [psobject[]] $Properties
}
