function Invoke-DscAdapter
{
    # Copyright (c) Microsoft Corporation.
    # Licensed under the MIT License.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, HelpMessage = 'Operation to perform. Choose from List, Get, Set, Test, Export, Validate.')]
        [ValidateSet('List', 'Get', 'Set', 'Test', 'Export', 'Validate', 'ClearCache')]
        [string]$Operation,
        [Parameter(Mandatory = $false, Position = 1, ValueFromPipeline = $true, HelpMessage = 'Configuration or resource input in JSON format.')]
        [string]$jsonInput = '@{}',
        [string]$adapterPath
    )

    $adapterParams = $PSBoundParameters

    if ([string]::IsNullOrWhiteSpace($adapterPath))
    {
        $adapterPath = (Join-Path -Path $PWD -ChildPath "powershell.resource.ps1")
        $adapterParams.Remove("adapterPath")
    }

    & $adapterPath @adapterParams
}
