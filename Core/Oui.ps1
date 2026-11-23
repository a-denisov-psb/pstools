#Requires -Version 5.1
# Offline MAC vendor lookup based on Data\oui.txt (IEEE MA-L, MA-M and MA-S registries).
# File format: one entry per line, "<HEX PREFIX><TAB><Vendor>", prefix with 6, 7 or 9 hex digits.
# Regenerate with Data\Update-OuiTable.ps1.

$PSToolsOuiTable = $null

function Import-PSToolsOuiTable {
    <#
    .SYNOPSIS
    Loads Data\oui.txt into memory (once per session). Called automatically by Resolve-PSToolsMacVendor.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if ($script:PSToolsOuiTable -and -not $Force) { return }

    $table = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $path  = Join-Path $PSToolsRoot 'Data\oui.txt'
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [System.IO.File]::ReadLines($path)) {
            if ($line.Length -lt 8 -or $line[0] -eq '#') { continue }
            $tab = $line.IndexOf("`t")
            if ($tab -lt 6) { continue }
            $table[$line.Substring(0, $tab)] = $line.Substring($tab + 1)
        }
    }
    else {
        Write-Warning "OUI table not found: $path. Vendor lookup is disabled."
    }
    $script:PSToolsOuiTable = $table
}

function Resolve-PSToolsMacVendor {
    <#
    .SYNOPSIS
    Returns the vendor name for a MAC address from the offline OUI table (no network access).

    .DESCRIPTION
    Tries the 36-bit (MA-S), 28-bit (MA-M) and 24-bit (MA-L) prefixes in that order.
    Locally administered (randomized) addresses are reported as such.

    .EXAMPLE
    Resolve-PSToolsMacVendor 00-c0-eb-1c-73-81
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$MacAddress)

    begin { Import-PSToolsOuiTable }
    process {
        $hex = ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        if ($hex.Length -ne 12) { return $null }

        foreach ($length in 9, 7, 6) {
            $vendor = $null
            if ($script:PSToolsOuiTable.TryGetValue($hex.Substring(0, $length), [ref]$vendor)) { return $vendor }
        }
        if (([Convert]::ToInt32($hex.Substring(0, 2), 16) -band 2) -ne 0) {
            return '(locally administered address)'
        }
        return $null
    }
}
