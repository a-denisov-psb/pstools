#Requires -Version 5.1
# Logic of the tool "Route Table". Dot-source this file to use the function from the console:
#   . .\Tools\Network\Get-RouteTable\Get-RouteTable.ps1
#   Get-RouteTable -AddressFamily IPv4 | Format-Table
# Changing routes: see Core\Routing.ps1 (New-PSToolsRouteSpec, Get-PSToolsRouteChangePlan,
# Invoke-PSToolsRouteOperation), loaded with this file.

. (Join-Path $PSScriptRoot '..\..\..\Core\Core.ps1')

function Get-RouteTable {
    <#
    .SYNOPSIS
    Lists the IPv4 and/or IPv6 routes of this PC, active and persistent, with effective metric and origin.

    .DESCRIPTION
    Combines the active route table with the persistent routes (saved routes, restored at startup). A
    persistent route whose interface is disconnected or no longer exists is listed as inactive.

    Per route:
      EffectiveMetric  route metric + interface metric; among routes with the same prefix length Windows
                       uses the one with the lowest effective metric (longest prefix wins first)
      Origin           System (created by Windows for local addresses), DHCP (default gateway with a
                       lease lifetime), Router advertisement (IPv6), Static (configured manually, by the
                       adapter settings or by software such as VPN clients)
      Store            Persistent (survives a restart), Temporary (static, until restart), Persistent (inactive),
                       Automatic (created by Windows from addresses, DHCP or router advertisements)
      Kind             Default, Network, Host, Multicast, Broadcast, Loopback, Link-local
      IsSystem         multicast, broadcast, loopback and the host routes of the PC's own addresses

    .PARAMETER AddressFamily
    IPv4, IPv6 or both (default).

    .PARAMETER IncludeSystem
    Also return system routes (multicast, broadcast, loopback, own addresses, IPv6 link-local).

    .OUTPUTS
    PSTools.Route: AddressFamily, DestinationPrefix, PrefixLength, NextHop, NextHopDisplay, IsOnLink,
    InterfaceAlias (empty if the interface no longer exists), InterfaceName (for display), InterfaceIndex, InterfaceState, RouteMetric, InterfaceMetric, EffectiveMetric, Protocol,
    Origin, Kind, IsSystem, IsActive, IsPersistent, Store, Lifetime, RouteKey, SortKey.

    .EXAMPLE
    Get-RouteTable -AddressFamily IPv4 | Format-Table DestinationPrefix, NextHopDisplay, InterfaceAlias, EffectiveMetric, Origin, Store

    .EXAMPLE
    Get-RouteTable | Where-Object Store -like 'Persistent*'
    Lists all persistent routes of both address families.

    .EXAMPLE
    Find-PSToolsRoute -Destination www.example.com
    Shows which route Windows uses for a destination (from Core\Routing.ps1).
    #>
    [CmdletBinding()]
    [OutputType('PSTools.Route')]
    param(
        [ValidateSet('IPv4', 'IPv6')][string[]]$AddressFamily = @('IPv4', 'IPv6'),
        [switch]$IncludeSystem
    )

    #region Nested helpers

    function Get-RouteKind {
        param([string]$Family, [string]$Prefix, [int]$Length)
        $network = ($Prefix -split '/')[0]
        if ($Length -eq 0) { return 'Default' }
        if ($Family -eq 'IPv4') {
            if (Test-PSToolsAddressInPrefix -Address $network -Network '224.0.0.0' -PrefixLength 4) { return 'Multicast' }
            if ($Prefix -eq '255.255.255.255/32') { return 'Broadcast' }
            if (Test-PSToolsAddressInPrefix -Address $network -Network '127.0.0.0' -PrefixLength 8) { return 'Loopback' }
            if ($Length -eq 32) { return 'Host' }
            if (Test-PSToolsAddressInPrefix -Address $network -Network '169.254.0.0' -PrefixLength 16) { return 'Link-local' }
        }
        else {
            if (Test-PSToolsAddressInPrefix -Address $network -Network 'ff00::' -PrefixLength 8) { return 'Multicast' }
            if ($Prefix -eq '::1/128') { return 'Loopback' }
            if ($Length -eq 128) { return 'Host' }
            if (Test-PSToolsAddressInPrefix -Address $network -Network 'fe80::' -PrefixLength 10) { return 'Link-local' }
        }
        return 'Network'
    }

    function Format-Lifetime {
        param($Lifetime)
        if ($null -eq $Lifetime) { return '' }
        $span = [TimeSpan]$Lifetime
        if ($span.TotalDays -gt 36500) { return 'Infinite' }
        if ($span.TotalDays -ge 1) { return '{0}d {1}h' -f [int][Math]::Floor($span.TotalDays), $span.Hours }
        return '{0}h {1:D2}m' -f $span.Hours, $span.Minutes
    }

    function New-RouteObject {
        param($Source, [string]$Family, [bool]$IsActive, [bool]$IsPersistent, $Interface)

        $prefix  = [string]$Source.DestinationPrefix
        $length  = [int]($prefix -split '/')[1]
        $nextHop = [string]$Source.NextHop
        $onLink  = ($nextHop -eq (Get-PSToolsOnLinkNextHop $Family))
        $kind    = Get-RouteKind -Family $Family -Prefix $prefix -Length $length
        $protocol = [string]$Source.Protocol
        $isSystem = $kind -in 'Multicast', 'Broadcast', 'Loopback' -or
                    ($protocol -eq 'Local' -and ($kind -eq 'Host' -or ($Family -eq 'IPv6' -and $kind -eq 'Link-local')))

        $lifetime = $null
        if ($IsActive) { $lifetime = $Source.ValidLifetime }
        $finite = $lifetime -and ([TimeSpan]$lifetime).TotalDays -le 36500
        $origin = switch ($protocol) {
            'Local'               { 'System' }
            'RouterAdvertisement' { 'Router advertisement' }
            'Dhcp'                { 'DHCP' }
            'NetMgmt'             { if ($finite -and -not $IsPersistent) { 'DHCP' } else { 'Static' } }
            default               { $protocol }
        }

        $interfaceMetric = if ($Interface) { [int]$Interface.InterfaceMetric } else { [int]$Source.InterfaceMetric }
        $store = if ($IsPersistent -and $IsActive) { 'Persistent' }
                 elseif ($IsPersistent) { 'Persistent (inactive)' }
                 elseif ($origin -eq 'Static') { 'Temporary' }
                 else { 'Automatic' }     # recreated by Windows (own addresses, DHCP, router advertisements)
        $networkBytes = (ConvertTo-PSToolsIPAddress ($prefix -split '/')[0]).GetAddressBytes()
        $alias = if ($Interface) { [string]$Interface.InterfaceAlias } else { [string]$Source.InterfaceAlias }

        [pscustomobject]@{
            PSTypeName        = 'PSTools.Route'
            AddressFamily     = $Family
            DestinationPrefix = $prefix
            PrefixLength      = $length
            NextHop           = $nextHop
            NextHopDisplay    = $(if ($onLink) { 'On-link' } else { $nextHop })
            IsOnLink          = $onLink
            InterfaceAlias    = $alias
            InterfaceName     = $(if ($alias) { $alias } else { "(index $($Source.InterfaceIndex))" })
            InterfaceIndex    = [int]$Source.InterfaceIndex
            InterfaceState    = $(if ($Interface) { [string]$Interface.ConnectionState } else { 'Missing' })
            RouteMetric       = [int]$Source.RouteMetric
            InterfaceMetric   = $interfaceMetric
            EffectiveMetric   = [int]$Source.RouteMetric + $interfaceMetric
            Protocol          = $protocol
            Origin            = $origin
            Kind              = $kind
            IsSystem          = $isSystem
            IsActive          = $IsActive
            IsPersistent      = $IsPersistent
            Store             = $store
            Lifetime          = Format-Lifetime $lifetime
            RouteKey          = '{0}|{1}|{2}|{3}' -f $Family, $prefix, $nextHop, [int]$Source.InterfaceIndex
            # Sortable destination: address bytes as hex, then the prefix length.
            SortKey           = '{0}/{1:D3}' -f ([BitConverter]::ToString($networkBytes)), $length
        }
    }

    #endregion

    $result = foreach ($family in $AddressFamily) {
        Write-Verbose "Reading the $family route table."
        $active     = @(Get-NetRoute -AddressFamily $family -PolicyStore ActiveStore -ErrorAction SilentlyContinue -Verbose:$false)
        $persistent = @(Get-NetRoute -AddressFamily $family -PolicyStore PersistentStore -ErrorAction SilentlyContinue -Verbose:$false)
        $interfaces = @{}
        foreach ($interface in @(Get-NetIPInterface -AddressFamily $family -ErrorAction SilentlyContinue -Verbose:$false)) {
            $interfaces[[int]$interface.ifIndex] = $interface
        }

        $persistentKeys = @{}
        foreach ($route in $persistent) { $persistentKeys[('{0}|{1}|{2}' -f $route.DestinationPrefix, $route.NextHop, $route.InterfaceIndex)] = $route }
        $activeKeys = @{}

        foreach ($route in $active) {
            $key = '{0}|{1}|{2}' -f $route.DestinationPrefix, $route.NextHop, $route.InterfaceIndex
            $activeKeys[$key] = $true
            New-RouteObject -Source $route -Family $family -IsActive $true -IsPersistent $persistentKeys.ContainsKey($key) -Interface $interfaces[[int]$route.InterfaceIndex]
        }
        foreach ($key in $persistentKeys.Keys) {
            if ($activeKeys.ContainsKey($key)) { continue }
            $route = $persistentKeys[$key]
            New-RouteObject -Source $route -Family $family -IsActive $false -IsPersistent $true -Interface $interfaces[[int]$route.InterfaceIndex]
        }
        Write-Verbose ('{0}: {1} active, {2} persistent routes.' -f $family, $active.Count, $persistent.Count)
    }

    $result | Where-Object { $IncludeSystem -or -not $_.IsSystem } |
        Sort-Object -Property AddressFamily, SortKey, EffectiveMetric
}
