#Requires -Version 5.1
<#
.SYNOPSIS
Downloads the IEEE MAC address registries and regenerates Data\oui.txt for the offline vendor lookup.

.DESCRIPTION
This is the only script that accesses the internet for the vendor lookup, and only when you run it.
It downloads the MA-L (24-bit), MA-M (28-bit) and MA-S (36-bit) registries from standards-oui.ieee.org
and writes a compact tab-separated file: "<HEX PREFIX><TAB><Vendor>".

.PARAMETER OutputPath
Target file. Default: oui.txt next to this script.

.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Data\Update-OuiTable.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is not reliable in param() defaults of Windows PowerShell 5.1.
if (-not $OutputPath) { $OutputPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'oui.txt' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$sources = [ordered]@{
    'MA-L' = 'https://standards-oui.ieee.org/oui/oui.csv'
    'MA-M' = 'https://standards-oui.ieee.org/oui28/mam.csv'
    'MA-S' = 'https://standards-oui.ieee.org/oui36/oui36.csv'
}

$entries = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::Ordinal)
foreach ($registry in $sources.Keys) {
    $url = $sources[$registry]
    Write-Progress -Activity 'Updating OUI table' -Status "Downloading $registry ($url)"
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PSTools-OUI-Updater'
    $text = if ($response.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }

    $rows = $text | ConvertFrom-Csv
    $count = 0
    foreach ($row in $rows) {
        $prefix = ([string]$row.Assignment).Trim().ToUpperInvariant()
        $vendor = (([string]$row.'Organization Name') -replace '\s+', ' ').Trim()
        if ($prefix -notmatch '^[0-9A-F]{6}([0-9A-F]|[0-9A-F]{3})?$' -or -not $vendor) { continue }
        $entries[$prefix] = $vendor
        $count++
    }
    Write-Verbose "$registry : $count entries"
    if ($count -lt 100) { throw "Download of $registry returned only $count entries – aborting, the existing table is kept." }
}
Write-Progress -Activity 'Updating OUI table' -Completed

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# PSTools offline OUI table. Source: IEEE Registration Authority (MA-L, MA-M, MA-S).')
$lines.Add('# Generated {0:yyyy-MM-dd} by Data\Update-OuiTable.ps1. Format: <HEX PREFIX><TAB><Vendor>' -f (Get-Date))
foreach ($pair in $entries.GetEnumerator()) { $lines.Add($pair.Key + "`t" + $pair.Value) }

$tempPath = $OutputPath + '.tmp'
[System.IO.File]::WriteAllLines($tempPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force

[pscustomobject]@{
    Path    = (Resolve-Path -LiteralPath $OutputPath).Path
    Entries = $entries.Count
    SizeKB  = [int]((Get-Item -LiteralPath $OutputPath).Length / 1KB)
}
