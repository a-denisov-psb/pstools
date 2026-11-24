#Requires -Version 5.1
<#
    Loads all non-GUI core helpers into the caller's scope.
    Usage (dot-source!):  . (Join-Path $PSScriptRoot '..\..\..\Core\Core.ps1')
    Safe to dot-source multiple times.
#>

# Root folder of the toolbox (parent of Core). Used to locate Data/ and Tools/.
$PSToolsRoot = Split-Path -Parent $PSScriptRoot

foreach ($__coreFile in 'Common.ps1', 'Network.ps1', 'Routing.ps1', 'Oui.ps1', 'Storage.ps1') {
    . (Join-Path $PSScriptRoot $__coreFile)
}
Remove-Variable -Name __coreFile -ErrorAction SilentlyContinue
