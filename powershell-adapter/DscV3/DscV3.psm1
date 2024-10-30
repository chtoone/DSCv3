$moduleRoot = Get-Item -Path $PSScriptRoot
$moduleRoot.EnumerateFiles("Private/*.ps1").ForEach({ . $_.FullName })
$moduleRoot.EnumerateFiles("Public/*.ps1").ForEach({ . $_.FullName })

# output format for resource list
class resourceOutput {
    [string] $type
    [string] $kind
    [string] $version
    [string[]] $capabilities
    [string] $path
    [string] $directory
    [string] $implementedAs
    [string] $author
    [string[]] $properties
    [string] $requireAdapter
    [string] $description
}