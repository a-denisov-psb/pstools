#Requires -Version 5.1
# Common helpers: elevation check and tool discovery.

function Test-PSToolsIsAdmin {
    <#
    .SYNOPSIS
    Returns $true if the current process runs with administrator rights.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PSToolsTool {
    <#
    .SYNOPSIS
    Discovers all tools below the Tools folder.

    .DESCRIPTION
    Scans Tools\<Category>\<ToolName>\tool.psd1. Folders whose name starts with '_' are ignored.
    An optional Tools\<Category>\category.psd1 (@{ Name = '...'; Order = 10 }) sets the category
    display name and sort order. Invalid manifests are returned with LoadError set, so the GUI can
    show them instead of silently dropping them.

    .PARAMETER Root
    Toolbox root folder. Defaults to the folder that contains Core.
    #>
    [CmdletBinding()]
    param(
        [string]$Root = $PSToolsRoot
    )

    $toolsDir = Join-Path $Root 'Tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) { return }

    foreach ($categoryDir in Get-ChildItem -LiteralPath $toolsDir -Directory | Where-Object { $_.Name -notlike '_*' }) {
        $categoryName  = $categoryDir.Name
        $categoryOrder = 1000
        $categoryFile  = Join-Path $categoryDir.FullName 'category.psd1'
        if (Test-Path -LiteralPath $categoryFile) {
            try {
                $categoryData = Import-PowerShellDataFile -LiteralPath $categoryFile
                if ($categoryData.Name)  { $categoryName  = [string]$categoryData.Name }
                if ($categoryData.Order) { $categoryOrder = [int]$categoryData.Order }
            }
            catch {
                Write-Warning "Invalid category file '$categoryFile': $($_.Exception.Message)"
            }
        }

        foreach ($toolDir in Get-ChildItem -LiteralPath $categoryDir.FullName -Directory | Where-Object { $_.Name -notlike '_*' }) {
            $manifestPath = Join-Path $toolDir.FullName 'tool.psd1'
            if (-not (Test-Path -LiteralPath $manifestPath)) { continue }

            $manifest  = $null
            $loadError = $null
            try {
                $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
            }
            catch {
                $loadError = "Invalid tool.psd1: $($_.Exception.Message)"
            }
            if (-not $manifest) { $manifest = @{} }

            $logicFile = Join-Path $toolDir.FullName ($toolDir.Name + '.ps1')
            $pageFile  = Join-Path $toolDir.FullName 'Page.ps1'
            if (-not $loadError -and -not (Test-Path -LiteralPath $logicFile)) {
                $loadError = "Logic file '$($toolDir.Name).ps1' is missing."
            }

            [pscustomobject]@{
                PSTypeName    = 'PSTools.Tool'
                Id            = '{0}/{1}' -f $categoryDir.Name, $toolDir.Name
                Name          = $(if ($manifest.Name) { [string]$manifest.Name } else { $toolDir.Name })
                Description   = [string]$manifest.Description
                Command       = $(if ($manifest.Command) { [string]$manifest.Command } else { $toolDir.Name })
                Order         = $(if ($manifest.Order) { [int]$manifest.Order } else { 1000 })
                RequiresAdmin = [bool]$manifest.RequiresAdmin
                Version       = [string]$manifest.Version
                Category      = $categoryName
                CategoryOrder = $categoryOrder
                ToolRoot      = $toolDir.FullName
                LogicFile     = $logicFile
                PageFile      = $pageFile
                HasPage       = (Test-Path -LiteralPath $pageFile)
                LoadError     = $loadError
            }
        }
    }
}
