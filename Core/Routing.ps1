#Requires -Version 5.1
# Routing helpers: prefix parsing (IPv4 + IPv6), interfaces and metrics, route lookup, route changes
# (as previewable operations with rollback), route table checks, snapshot comparison and restore planning.
# Reading works without administrator rights; every change requires them.

#region Prefix math (IPv4 and IPv6)

function Get-PSToolsMaskedAddressBytes {
    <#
    .SYNOPSIS
    Returns a copy of the address bytes with all bits after PrefixLength set to zero.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$PrefixLength
    )
    $result = [byte[]]$Bytes.Clone()
    for ($i = 0; $i -lt $result.Length; $i++) {
        $bits = $PrefixLength - 8 * $i
        if ($bits -ge 8) { continue }
        if ($bits -le 0) { $result[$i] = 0; continue }
        $result[$i] = $result[$i] -band ((255 -shl (8 - $bits)) -band 255)
    }
    return ,$result
}

function ConvertTo-PSToolsIPAddress {
    <#
    .SYNOPSIS
    Parses an IPv4 or IPv6 address strictly (IPv4 must be dotted quad). Returns [ipaddress] or $null.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $value = ([string]$Text).Trim().Trim('[', ']')
    if (-not $value) { return $null }
    # [ipaddress]::TryParse accepts '10' as 0.0.0.10 - only allow complete dotted quads for IPv4.
    if ($value -notmatch ':' -and $value -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $null }
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($value, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-PSToolsAddressFamilyName {
    # Returns 'IPv4' or 'IPv6' for an [ipaddress].
    param([Parameter(Mandatory)][System.Net.IPAddress]$Address)
    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return 'IPv6' }
    return 'IPv4'
}

function ConvertTo-PSToolsRoutePrefix {
    <#
    .SYNOPSIS
    Parses a route destination into a normalized prefix (network address/length), IPv4 or IPv6.

    .DESCRIPTION
    Accepts '10.20.0.0/16', '10.20.0.0 255.255.0.0', a single address (host route, /32 or /128),
    '2001:db8::/32' and 'default' (0.0.0.0/0 or ::/0). Host bits are cleared (10.20.1.5/16 becomes
    10.20.0.0/16; HostBitsCleared tells the caller). Throws a readable message on invalid input.

    .EXAMPLE
    ConvertTo-PSToolsRoutePrefix -Text '192.168.10.7 255.255.255.0'
    Returns Prefix 192.168.10.0/24.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('IPv4', 'IPv6')][string]$AddressFamily
    )

    $value = $Text.Trim()
    if (-not $value) { throw 'Enter a destination, e.g. 10.20.0.0/16, 10.20.0.0 255.255.0.0, a single address or "default".' }

    if ($value -eq 'default') {
        if (-not $AddressFamily) { throw "'default' needs an address family." }
        $value = if ($AddressFamily -eq 'IPv6') { '::/0' } else { '0.0.0.0/0' }
    }

    $addressText = $value
    $length      = $null
    if ($value -match '^(\S+)\s*/\s*(\d{1,3})$') {
        $addressText = $Matches[1]
        $length      = [int]$Matches[2]
    }
    elseif ($value -match '^(\S+)\s+(?:mask\s+)?(\d{1,3}(?:\.\d{1,3}){3})$') {
        $addressText = $Matches[1]
        $mask = ConvertTo-PSToolsIPAddress $Matches[2]
        if (-not $mask) { throw "Invalid subnet mask '$($Matches[2])'." }
        $bits = ($mask.GetAddressBytes() | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
        if ($bits -notmatch '^1*0*$') { throw "Invalid subnet mask '$($Matches[2])': the ones must be contiguous (e.g. 255.255.255.0)." }
        $length = $bits.IndexOf('0')
        if ($length -lt 0) { $length = 32 }
    }

    if ($addressText -match '%') { throw "Remove the zone index ('%...') from '$addressText'; the interface is selected separately." }
    $address = ConvertTo-PSToolsIPAddress $addressText
    if (-not $address) { throw "'$addressText' is not a valid IPv4 or IPv6 address." }

    $family = Get-PSToolsAddressFamilyName $address
    if ($AddressFamily -and $family -ne $AddressFamily) {
        throw "'$addressText' is an $family address, but the $AddressFamily route table is selected."
    }
    $maxLength = if ($family -eq 'IPv6') { 128 } else { 32 }
    if ($null -eq $length) { $length = $maxLength }
    if ($length -lt 0 -or $length -gt $maxLength) { throw "The prefix length must be between 0 and $maxLength." }

    $bytes   = $address.GetAddressBytes()
    $masked  = Get-PSToolsMaskedAddressBytes -Bytes $bytes -PrefixLength $length
    $network = New-Object System.Net.IPAddress (, $masked)

    [pscustomobject]@{
        PSTypeName      = 'PSTools.RoutePrefix'
        Prefix          = '{0}/{1}' -f $network, $length
        Network         = $network.ToString()
        PrefixLength    = $length
        AddressFamily   = $family
        HostBitsCleared = ([BitConverter]::ToString($bytes) -ne [BitConverter]::ToString($masked))
    }
}

function Test-PSToolsAddressInPrefix {
    <#
    .SYNOPSIS
    Returns $true if an address lies inside Network/PrefixLength (IPv4 or IPv6; zone indexes are ignored).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Network,
        [Parameter(Mandatory)][int]$PrefixLength
    )
    $a = ConvertTo-PSToolsIPAddress ($Address -replace '%.*$', '')
    $n = ConvertTo-PSToolsIPAddress ($Network -replace '%.*$', '')
    if (-not $a -or -not $n -or $a.AddressFamily -ne $n.AddressFamily) { return $false }
    $left  = Get-PSToolsMaskedAddressBytes -Bytes $a.GetAddressBytes() -PrefixLength $PrefixLength
    $right = Get-PSToolsMaskedAddressBytes -Bytes $n.GetAddressBytes() -PrefixLength $PrefixLength
    return ([BitConverter]::ToString($left) -eq [BitConverter]::ToString($right))
}

function Get-PSToolsOnLinkNextHop {
    # The next hop value Windows uses for on-link routes.
    param([Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$AddressFamily)
    if ($AddressFamily -eq 'IPv6') { return '::' }
    return '0.0.0.0'
}

function Test-PSToolsNextHopOnLink {
    <#
    .SYNOPSIS
    Returns $true if a gateway is directly reachable from an interface: it lies in one of the interface's
    subnets, or it is an IPv6 link-local address.

    .PARAMETER Interface
    A PSTools.IPInterface object (Get-PSToolsIPInterface), which carries the address list.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$NextHop,
        [Parameter(Mandatory)]$Interface
    )
    if (Test-PSToolsAddressInPrefix -Address $NextHop -Network 'fe80::' -PrefixLength 10) { return $true }
    foreach ($entry in @($Interface.AddressList)) {
        if (Test-PSToolsAddressInPrefix -Address $NextHop -Network $entry.Address -PrefixLength $entry.PrefixLength) { return $true }
    }
    return $false
}

#endregion

#region Interfaces and metrics

function Get-PSToolsIPInterface {
    <#
    .SYNOPSIS
    Lists the IP interfaces of one address family with metric, state, addresses and default gateways.

    .DESCRIPTION
    Sorted: connected interfaces first, then by interface metric and name. InterfaceMetric is the value
    Windows adds to every route metric of the interface (effective metric = route metric + interface metric).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('IPv4', 'IPv6')][string]$AddressFamily = 'IPv4'
    )

    # NetAdapter script properties import a helper module and would flood the verbose stream.
    $VerbosePreference = 'SilentlyContinue'

    $interfaces = @(Get-NetIPInterface -AddressFamily $AddressFamily -ErrorAction SilentlyContinue -Verbose:$false)
    $addresses  = @(Get-NetIPAddress -AddressFamily $AddressFamily -ErrorAction SilentlyContinue -Verbose:$false)
    $adapters   = @{}
    foreach ($adapter in @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue -Verbose:$false)) { $adapters[[int]$adapter.ifIndex] = $adapter }
    $defaultPrefix = if ($AddressFamily -eq 'IPv6') { '::/0' } else { '0.0.0.0/0' }
    $defaults = @(Get-NetRoute -AddressFamily $AddressFamily -DestinationPrefix $defaultPrefix -ErrorAction SilentlyContinue -Verbose:$false)

    $result = foreach ($interface in $interfaces) {
        $index = [int]$interface.ifIndex
        $addressList = @($addresses | Where-Object { $_.InterfaceIndex -eq $index } | Sort-Object -Property SkipAsSource, PrefixOrigin |
            ForEach-Object { [pscustomobject]@{ Address = [string]$_.IPAddress; PrefixLength = [int]$_.PrefixLength } })
        $gateways = @($defaults | Where-Object { $_.InterfaceIndex -eq $index } | ForEach-Object { [string]$_.NextHop } |
            Where-Object { $_ -ne (Get-PSToolsOnLinkNextHop $AddressFamily) })
        $adapter = $adapters[$index]
        $state   = [string]$interface.ConnectionState
        $addressText = (($addressList | ForEach-Object { '{0}/{1}' -f ($_.Address -replace '%.*$', ''), $_.PrefixLength }) -join ', ')

        [pscustomobject]@{
            PSTypeName      = 'PSTools.IPInterface'
            InterfaceAlias  = [string]$interface.InterfaceAlias
            InterfaceIndex  = $index
            AddressFamily   = $AddressFamily
            ConnectionState = $state
            IsConnected     = ($state -eq 'Connected')
            AutomaticMetric = ([string]$interface.AutomaticMetric -eq 'Enabled')
            MetricMode      = $(if ([string]$interface.AutomaticMetric -eq 'Enabled') { 'Automatic' } else { 'Manual' })
            InterfaceMetric = [int]$interface.InterfaceMetric
            Dhcp            = [string]$interface.Dhcp
            AddressList     = $addressList
            Addresses       = $addressText
            DefaultGateway  = ($gateways -join ', ')
            Description     = $(if ($adapter) { [string]$adapter.InterfaceDescription } else { '' })
            DisplayName     = '{0}  –  {1}  [{2}, metric {3}]' -f $interface.InterfaceAlias,
                                  $(if ($addressText) { $addressText } else { "no $AddressFamily address" }), $state, $interface.InterfaceMetric
        }
    }

    $result | Sort-Object -Property @{ Expression = { $_.IsConnected }; Descending = $true }, InterfaceMetric, InterfaceAlias
}

function Get-PSToolsInterfaceMetricCommand {
    <#
    .SYNOPSIS
    Returns the PowerShell command that sets the interface metric (or switches it back to automatic).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Metric')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$InterfaceAlias,
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$AddressFamily,
        [Parameter(Mandatory, ParameterSetName = 'Metric')][ValidateRange(1, 9999)][int]$Metric,
        [Parameter(Mandatory, ParameterSetName = 'Automatic')][switch]$Automatic
    )
    $target = "Set-NetIPInterface -InterfaceAlias '{0}' -AddressFamily {1}" -f ($InterfaceAlias -replace "'", "''"), $AddressFamily
    if ($Automatic) { return "$target -AutomaticMetric Enabled" }
    return "$target -InterfaceMetric $Metric"
}

function Set-PSToolsInterfaceMetric {
    <#
    .SYNOPSIS
    Sets a fixed interface metric, or switches the interface back to the automatic metric. Requires administrator rights.

    .DESCRIPTION
    A lower interface metric makes all routes of the interface preferred (e.g. LAN over WLAN or VPN).
    The automatic metric depends on the link speed.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Metric')]
    param(
        [Parameter(Mandatory)][int]$InterfaceIndex,
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$AddressFamily,
        [Parameter(Mandatory, ParameterSetName = 'Metric')][ValidateRange(1, 9999)][int]$Metric,
        [Parameter(Mandatory, ParameterSetName = 'Automatic')][switch]$Automatic
    )

    if (-not (Test-PSToolsIsAdmin)) { throw 'Changing the interface metric requires administrator rights.' }
    $action = if ($Automatic) { 'Use the automatic interface metric' } else { "Set the interface metric to $Metric" }
    if ($PSCmdlet.ShouldProcess("interface $InterfaceIndex ($AddressFamily)", $action)) {
        if ($Automatic) {
            Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily $AddressFamily -AutomaticMetric Enabled -ErrorAction Stop -Verbose:$false
        }
        else {
            Set-NetIPInterface -InterfaceIndex $InterfaceIndex -AddressFamily $AddressFamily -InterfaceMetric $Metric -ErrorAction Stop -Verbose:$false
        }
    }
}

#endregion

#region Route lookup

function Find-PSToolsRoute {
    <#
    .SYNOPSIS
    Shows which route, interface, gateway and source address Windows uses to reach a destination.

    .DESCRIPTION
    Host names are resolved first. When a name has IPv4 and IPv6 addresses, PreferredAddressFamily decides
    (default IPv4). Uses Find-NetRoute, i.e. the same decision Windows makes for new connections.

    .EXAMPLE
    Find-PSToolsRoute -Destination 8.8.8.8
    #>
    [CmdletBinding()]
    [OutputType('PSTools.RouteLookup')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Destination,
        [ValidateSet('IPv4', 'IPv6')][string]$PreferredAddressFamily = 'IPv4'
    )

    $name    = $Destination.Trim()
    $address = ConvertTo-PSToolsIPAddress $name
    if (-not $address) {
        Write-Progress -Activity 'Route lookup' -Status "Resolving $name…"
        try {
            $all = @([System.Net.Dns]::GetHostAddresses($name))
        }
        catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            throw "The host name '$name' could not be resolved: $($inner.Message)"
        }
        if (-not $all.Count) { throw "The host name '$name' could not be resolved." }
        Write-Verbose ("'{0}' resolves to {1}" -f $name, (($all | ForEach-Object { $_.ToString() }) -join ', '))
        $address = $all | Where-Object { (Get-PSToolsAddressFamilyName $_) -eq $PreferredAddressFamily } | Select-Object -First 1
        if (-not $address) { $address = $all[0] }
    }

    Write-Progress -Activity 'Route lookup' -Status "Looking up the route to $address…"
    try {
        $found = @(Find-NetRoute -RemoteIPAddress $address.ToString() -ErrorAction Stop -Verbose:$false)
    }
    catch {
        throw "Windows has no route to $address. $($_.Exception.Message)"
    }
    $route  = $found | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1
    $source = $found | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetIPAddress' } | Select-Object -First 1
    if (-not $route) { throw "Windows has no route to $address." }

    $family = Get-PSToolsAddressFamilyName $address
    $onLink = ([string]$route.NextHop -eq (Get-PSToolsOnLinkNextHop $family))
    [pscustomobject]@{
        PSTypeName        = 'PSTools.RouteLookup'
        Destination       = $name
        RemoteAddress     = $address.ToString()
        AddressFamily     = $family
        DestinationPrefix = [string]$route.DestinationPrefix
        NextHop           = [string]$route.NextHop
        NextHopDisplay    = $(if ($onLink) { 'On-link' } else { [string]$route.NextHop })
        InterfaceAlias    = [string]$route.InterfaceAlias
        InterfaceIndex    = [int]$route.InterfaceIndex
        SourceAddress     = $(if ($source) { [string]$source.IPAddress } else { '' })
        RouteMetric       = [int]$route.RouteMetric
        InterfaceMetric   = [int]$route.InterfaceMetric
        EffectiveMetric   = [int]$route.RouteMetric + [int]$route.InterfaceMetric
    }
}

#endregion

#region Route changes (operations)

function New-PSToolsRouteOperation {
    # Internal: one change on one policy store. Get-PSToolsRouteCommand turns it into text,
    # Invoke-PSToolsRouteOperation executes it.
    param(
        [ValidateSet('Add', 'Remove', 'SetMetric')][string]$Action,
        [ValidateSet('ActiveStore', 'PersistentStore')][string]$Store,
        $Route,
        [int]$RouteMetric,
        [int]$PreviousRouteMetric
    )
    [pscustomobject]@{
        PSTypeName          = 'PSTools.RouteOperation'
        Action              = $Action
        Store               = $Store
        AddressFamily       = $Route.AddressFamily
        DestinationPrefix   = $Route.DestinationPrefix
        NextHop             = $Route.NextHop
        IsOnLink            = ($Route.NextHop -eq (Get-PSToolsOnLinkNextHop $Route.AddressFamily))
        InterfaceIndex      = [int]$Route.InterfaceIndex
        InterfaceAlias      = [string]$Route.InterfaceAlias
        RouteMetric         = $RouteMetric
        PreviousRouteMetric = $PreviousRouteMetric
    }
}

function New-PSToolsRouteSpec {
    <#
    .SYNOPSIS
    Validates the input for a new or changed route and returns a route specification for Get-PSToolsRouteChangePlan.

    .PARAMETER NextHop
    Gateway address; empty for an on-link route (destination directly reachable on the interface).

    .PARAMETER Interface
    PSTools.IPInterface object (Get-PSToolsIPInterface) of the same address family.

    .PARAMETER Persistent
    $true: the route survives a restart. $false: until restart (active store only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$AddressFamily,
        [Parameter(Mandatory)][AllowEmptyString()][string]$DestinationPrefix,
        [AllowEmptyString()][string]$NextHop = '',
        [Parameter(Mandatory)][AllowNull()]$Interface,
        [Parameter(Mandatory)][ValidateRange(0, 9999)][int]$RouteMetric,
        [bool]$Persistent = $true
    )

    $prefix = ConvertTo-PSToolsRoutePrefix -Text $DestinationPrefix -AddressFamily $AddressFamily
    if (-not $Interface) { throw 'Select the interface the route uses.' }
    if ($Interface.AddressFamily -ne $AddressFamily) { throw "The interface list does not match the $AddressFamily route table; refresh it." }

    $hop = $NextHop.Trim()
    if ($hop -eq '' -or $hop -match '^(on-?link)$') {
        $hop = Get-PSToolsOnLinkNextHop $AddressFamily
    }
    else {
        if ($hop -match '%') { throw "Remove the zone index ('%...') from the gateway; the interface is selected separately." }
        $hopAddress = ConvertTo-PSToolsIPAddress $hop
        if (-not $hopAddress) { throw "The gateway '$hop' is not a valid IP address. Leave it empty for an on-link route." }
        if ((Get-PSToolsAddressFamilyName $hopAddress) -ne $AddressFamily) { throw "The gateway '$hop' is not an $AddressFamily address." }
        if ($hopAddress.IsIPv6Multicast -or (Test-PSToolsAddressInPrefix -Address $hop -Network '224.0.0.0' -PrefixLength 4)) {
            throw "The gateway '$hop' is a multicast address."
        }
        $hop = $hopAddress.ToString()
    }

    [pscustomobject]@{
        PSTypeName        = 'PSTools.RouteSpec'
        AddressFamily     = $AddressFamily
        DestinationPrefix = $prefix.Prefix
        HostBitsCleared   = $prefix.HostBitsCleared
        NextHop           = $hop
        IsOnLink          = ($hop -eq (Get-PSToolsOnLinkNextHop $AddressFamily))
        InterfaceIndex    = [int]$Interface.InterfaceIndex
        InterfaceAlias    = [string]$Interface.InterfaceAlias
        InterfaceState    = [string]$Interface.ConnectionState
        GatewayOnLink     = $(if ($hop -eq (Get-PSToolsOnLinkNextHop $AddressFamily)) { $true } else { Test-PSToolsNextHopOnLink -NextHop $hop -Interface $Interface })
        RouteMetric       = $RouteMetric
        Persistent        = $Persistent
    }
}

function Get-PSToolsRouteChangePlan {
    <#
    .SYNOPSIS
    Returns the operations that add a route or turn an existing route into the given specification.

    .DESCRIPTION
    New route: add it to the active store and, if persistent, to the persistent store. For a disconnected
    interface a persistent route only goes to the persistent store (Windows activates it on connect).

    Existing route (Route object from Get-RouteTable): if destination, gateway and interface stay the same,
    only the metric is set and the route is added to / removed from stores as needed. Otherwise the new
    route is added first and the old one removed afterwards, so connectivity is never lost in between.
    #>
    [CmdletBinding()]
    param(
        $ExistingRoute,
        [Parameter(Mandatory)]$Spec
    )

    $newStores = if (-not $Spec.Persistent) { @('ActiveStore') }
                 elseif ($Spec.InterfaceState -eq 'Disconnected') { @('PersistentStore') }
                 else { @('ActiveStore', 'PersistentStore') }

    if (-not $ExistingRoute) {
        foreach ($store in $newStores) { New-PSToolsRouteOperation -Action Add -Store $store -Route $Spec -RouteMetric $Spec.RouteMetric }
        return
    }

    $oldStores = @()
    if ($ExistingRoute.IsActive)     { $oldStores += 'ActiveStore' }
    if ($ExistingRoute.IsPersistent) { $oldStores += 'PersistentStore' }

    $sameRoute = $ExistingRoute.DestinationPrefix -eq $Spec.DestinationPrefix -and
                 $ExistingRoute.NextHop -eq $Spec.NextHop -and
                 [int]$ExistingRoute.InterfaceIndex -eq $Spec.InterfaceIndex
    if ($sameRoute) {
        foreach ($store in $newStores) {
            if ($oldStores -contains $store) {
                if ([int]$ExistingRoute.RouteMetric -ne $Spec.RouteMetric) {
                    New-PSToolsRouteOperation -Action SetMetric -Store $store -Route $Spec -RouteMetric $Spec.RouteMetric -PreviousRouteMetric $ExistingRoute.RouteMetric
                }
            }
            else {
                New-PSToolsRouteOperation -Action Add -Store $store -Route $Spec -RouteMetric $Spec.RouteMetric
            }
        }
        foreach ($store in $oldStores) {
            # A persistent route on a disconnected interface keeps its (empty) active state.
            if ($newStores -notcontains $store -and -not ($store -eq 'ActiveStore' -and $Spec.Persistent)) {
                New-PSToolsRouteOperation -Action Remove -Store $store -Route $ExistingRoute -RouteMetric $ExistingRoute.RouteMetric
            }
        }
        return
    }

    foreach ($store in $newStores) { New-PSToolsRouteOperation -Action Add -Store $store -Route $Spec -RouteMetric $Spec.RouteMetric }
    foreach ($store in $oldStores) { New-PSToolsRouteOperation -Action Remove -Store $store -Route $ExistingRoute -RouteMetric $ExistingRoute.RouteMetric }
}

function Get-PSToolsRouteRemovePlan {
    <#
    .SYNOPSIS
    Returns the operations that delete routes (from every store they are in).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Route)
    foreach ($item in $Route) {
        if ($item.IsActive)     { New-PSToolsRouteOperation -Action Remove -Store ActiveStore -Route $item -RouteMetric $item.RouteMetric }
        if ($item.IsPersistent) { New-PSToolsRouteOperation -Action Remove -Store PersistentStore -Route $item -RouteMetric $item.RouteMetric }
    }
}

function Get-PSToolsRouteCopyPlan {
    <#
    .SYNOPSIS
    Returns the operations that would create the given routes as they are (for 'copy as command').
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Route)
    foreach ($item in $Route) {
        if ($item.IsActive -or $item.IsPersistent) { New-PSToolsRouteOperation -Action Add -Store ActiveStore -Route $item -RouteMetric $item.RouteMetric }
        if ($item.IsPersistent) { New-PSToolsRouteOperation -Action Add -Store PersistentStore -Route $item -RouteMetric $item.RouteMetric }
    }
}

function Get-PSToolsRouteCommand {
    <#
    .SYNOPSIS
    Turns route operations into command lines (PowerShell NetTCPIP cmdlets or netsh).

    .DESCRIPTION
    PowerShell: one line per operation and store; this is exactly what Invoke-PSToolsRouteOperation runs
    (it addresses the interface by index, the text by name). netsh: 'store=persistent' covers both stores,
    so an add/remove on both stores becomes one line.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operation,
        [ValidateSet('PowerShell', 'Netsh')][string]$Syntax = 'PowerShell'
    )

    $lines = New-Object System.Collections.Generic.List[string]
    if ($Syntax -eq 'PowerShell') {
        foreach ($op in $Operation) {
            $interface = if ($op.InterfaceAlias) { "-InterfaceAlias '{0}'" -f ($op.InterfaceAlias -replace "'", "''") } else { "-InterfaceIndex $($op.InterfaceIndex)" }
            $target = "-DestinationPrefix '{0}' {1}" -f $op.DestinationPrefix, $interface
            switch ($op.Action) {
                'Add' {
                    $hop = if ($op.IsOnLink) { '' } else { " -NextHop '{0}'" -f $op.NextHop }
                    $lines.Add(('New-NetRoute {0}{1} -RouteMetric {2} -PolicyStore {3}' -f $target, $hop, $op.RouteMetric, $op.Store))
                }
                'Remove' {
                    $lines.Add(("Remove-NetRoute {0} -NextHop '{1}' -PolicyStore {2} -Confirm:`$false" -f $target, $op.NextHop, $op.Store))
                }
                'SetMetric' {
                    $lines.Add(("Set-NetRoute {0} -NextHop '{1}' -PolicyStore {2} -RouteMetric {3}" -f $target, $op.NextHop, $op.Store, $op.RouteMetric))
                }
            }
        }
        return ,([string[]]$lines)
    }

    # netsh: merge Add/Remove of the same route on both stores into one 'store=persistent' line.
    $handled = New-Object 'System.Collections.Generic.HashSet[int]'
    for ($i = 0; $i -lt $Operation.Count; $i++) {
        if ($handled.Contains($i)) { continue }
        $op = $Operation[$i]
        $key = '{0}|{1}|{2}|{3}' -f $op.Action, $op.DestinationPrefix, $op.NextHop, $op.InterfaceIndex
        $store = if ($op.Store -eq 'PersistentStore') { 'persistent' } else { 'active' }
        if ($op.Action -ne 'SetMetric') {
            for ($j = $i + 1; $j -lt $Operation.Count; $j++) {
                $other = $Operation[$j]
                $otherKey = '{0}|{1}|{2}|{3}' -f $other.Action, $other.DestinationPrefix, $other.NextHop, $other.InterfaceIndex
                if ($otherKey -eq $key -and $other.Store -ne $op.Store) { [void]$handled.Add($j); $store = 'persistent' }
            }
        }
        $family    = $op.AddressFamily.ToLowerInvariant()
        $interface = if ($op.InterfaceAlias) { 'interface="{0}"' -f $op.InterfaceAlias } else { "interface=$($op.InterfaceIndex)" }
        $hop       = if ($op.IsOnLink) { '' } else { " nexthop=$($op.NextHop)" }
        switch ($op.Action) {
            'Add'       { $lines.Add(('netsh interface {0} add route prefix={1} {2}{3} metric={4} store={5}' -f $family, $op.DestinationPrefix, $interface, $hop, $op.RouteMetric, $store)) }
            'Remove'    {
                if ($op.Store -eq 'PersistentStore' -and $store -ne 'persistent') {
                    $lines.Add('# netsh cannot remove only the saved copy of a route (it would remove the active route too); use the PowerShell syntax.')
                }
                $lines.Add(('netsh interface {0} delete route prefix={1} {2}{3} store={4}' -f $family, $op.DestinationPrefix, $interface, $hop, $store))
            }
            'SetMetric' { $lines.Add(('netsh interface {0} set route prefix={1} {2}{3} metric={4} store={5}' -f $family, $op.DestinationPrefix, $interface, $hop, $op.RouteMetric, $store)) }
        }
    }
    return ,([string[]]$lines)
}

function Invoke-PSToolsRouteOperation {
    <#
    .SYNOPSIS
    Executes route operations in order. Requires administrator rights.

    .DESCRIPTION
    If an operation fails, the operations already done are undone in reverse order and the error is
    thrown (with a note whether the rollback worked).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operation)

    if (-not $Operation.Count) { return }
    if (-not (Test-PSToolsIsAdmin)) { throw 'Changing routes requires administrator rights.' }

    $done = New-Object System.Collections.Generic.List[object]
    foreach ($op in $Operation) {
        $description = '{0} {1} via {2} on interface {3} ({4})' -f $op.Action, $op.DestinationPrefix, $op.NextHop, $op.InterfaceIndex, $op.Store
        if (-not $PSCmdlet.ShouldProcess($op.DestinationPrefix, $description)) { continue }
        try {
            Invoke-PSToolsRouteOperationStep -Operation $op
            $done.Add($op)
            Write-Verbose "Done: $description"
        }
        catch {
            $message = "$description failed: $($_.Exception.Message)"
            $rollbackErrors = @()
            for ($i = $done.Count - 1; $i -ge 0; $i--) {
                $undo = $done[$i].PSObject.Copy()
                switch ($undo.Action) {
                    'Add'       { $undo.Action = 'Remove' }
                    'Remove'    { $undo.Action = 'Add' }
                    'SetMetric' { $undo.RouteMetric = $done[$i].PreviousRouteMetric }
                }
                try { Invoke-PSToolsRouteOperationStep -Operation $undo }
                catch { $rollbackErrors += $_.Exception.Message }
            }
            if ($done.Count -and $rollbackErrors.Count) {
                $message += " Rolling back the previous steps failed too: $($rollbackErrors -join ' ') Check the route table."
            }
            elseif ($done.Count) {
                $message += ' The previous steps were rolled back.'
            }
            throw $message
        }
    }
}

function Invoke-PSToolsRouteOperationStep {
    # Internal: runs one route operation with the NetTCPIP cmdlets.
    param([Parameter(Mandatory)]$Operation)
    $op = $Operation
    $common = @{
        DestinationPrefix = $op.DestinationPrefix
        InterfaceIndex    = $op.InterfaceIndex
        PolicyStore       = $op.Store
        ErrorAction       = 'Stop'
        Verbose           = $false
    }
    switch ($op.Action) {
        'Add' {
            if (-not $op.IsOnLink) { $common.NextHop = $op.NextHop }
            New-NetRoute @common -RouteMetric $op.RouteMetric | Out-Null
        }
        'Remove'    { Remove-NetRoute @common -NextHop $op.NextHop -Confirm:$false }
        'SetMetric' { Set-NetRoute @common -NextHop $op.NextHop -RouteMetric $op.RouteMetric }
    }
}

#endregion

#region Checks, snapshots, restore

function Get-PSToolsRouteIssue {
    <#
    .SYNOPSIS
    Checks a route table (one address family) for common problems and returns notices.

    .DESCRIPTION
    Checks: no IPv4 default route, several default routes (which one wins, or an unpredictable tie),
    gateways outside the interface's subnets, persistent routes on disconnected or missing interfaces.

    .PARAMETER Route
    Routes of one address family from Get-RouteTable (including inactive persistent routes).

    .PARAMETER Interface
    Interfaces of the same family from Get-PSToolsIPInterface.

    .OUTPUTS
    PSTools.RouteIssue: Severity (Warning, Info), Message, Command (fix, may be empty), RouteKey.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Route,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Interface,
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$AddressFamily
    )

    function New-Issue {
        param([string]$Severity, [string]$Message, [string]$Command = '', [string]$RouteKey = '')
        [pscustomobject]@{
            PSTypeName        = 'PSTools.RouteIssue'
            Severity          = $Severity
            Symbol            = $(if ($Severity -eq 'Warning') { [string][char]0x26A0 } else { [string][char]0x2139 })
            Message           = $Message
            Command           = $Command
            CommandVisibility = $(if ($Command) { 'Visible' } else { 'Collapsed' })
            RouteKey          = $RouteKey
        }
    }

    $byIndex = @{}
    foreach ($item in $Interface) { $byIndex[[int]$item.InterfaceIndex] = $item }

    # Default routes on connected interfaces
    $defaults = @($Route | Where-Object { $_.IsActive -and $_.PrefixLength -eq 0 -and $_.InterfaceState -eq 'Connected' } |
        Sort-Object -Property EffectiveMetric, InterfaceAlias)
    if (-not $defaults.Count -and $AddressFamily -eq 'IPv4') {
        New-Issue Warning 'There is no IPv4 default route (0.0.0.0/0): only directly connected networks and networks with their own route are reachable. Check the default gateway of the adapter, or add a route to 0.0.0.0/0.'
    }
    elseif ($defaults.Count -gt 1) {
        $best = $defaults[0]
        $tie  = @($defaults | Where-Object { $_.EffectiveMetric -eq $best.EffectiveMetric -and $_.InterfaceIndex -ne $best.InterfaceIndex })
        if ($tie.Count) {
            New-Issue Warning (("{0} default routes have the same lowest effective metric ({1}): {2}. Windows may use any of them, so connections can take different paths. Give the preferred interface a lower metric (Interfaces tab).") -f
                ($tie.Count + 1), $best.EffectiveMetric, ((@($best) + $tie | ForEach-Object { "'{0}' via {1}" -f $_.InterfaceAlias, $_.NextHopDisplay }) -join ', '))
        }
        else {
            $others = ($defaults | Select-Object -Skip 1 | ForEach-Object { "'{0}' ({1})" -f $_.InterfaceAlias, $_.EffectiveMetric }) -join ', '
            New-Issue Info (("{0} default routes: traffic to other networks uses '{1}' via {2} (effective metric {3}). Fallback: {4}.") -f
                $defaults.Count, $best.InterfaceAlias, $best.NextHopDisplay, $best.EffectiveMetric, $others)
        }
    }

    foreach ($item in $Route) {
        if ($item.IsSystem) { continue }
        $interface = $byIndex[[int]$item.InterfaceIndex]

        if ($item.IsPersistent -and -not $item.IsActive) {
            if (-not $interface) {
                $command = (Get-PSToolsRouteCommand -Operation @(New-PSToolsRouteOperation -Action Remove -Store PersistentStore -Route $item -RouteMetric $item.RouteMetric)) -join [Environment]::NewLine
                New-Issue Warning (("The persistent route {0} via {1} belongs to an interface that no longer exists (index {2}). It is never used; delete it.") -f
                    $item.DestinationPrefix, $item.NextHopDisplay, $item.InterfaceIndex) $command $item.RouteKey
            }
            else {
                New-Issue Info (("The persistent route {0} via {1} on '{2}' is inactive because the interface is {3}. Windows activates it when the interface connects.") -f
                    $item.DestinationPrefix, $item.NextHopDisplay, $item.InterfaceAlias, $item.InterfaceState.ToLowerInvariant()) '' $item.RouteKey
            }
            continue
        }

        if ($item.IsActive -and -not $item.IsOnLink -and $interface -and $item.Protocol -ne 'RouterAdvertisement') {
            if (-not (Test-PSToolsNextHopOnLink -NextHop $item.NextHop -Interface $interface)) {
                $subnets = if ($interface.Addresses) { $interface.Addresses } else { "no $AddressFamily address" }
                New-Issue Warning (("The gateway {0} of route {1} is not in a subnet of '{2}' ({3}). Windows cannot reach it directly, so the route does not work.") -f
                    $item.NextHop, $item.DestinationPrefix, $item.InterfaceAlias, $subnets) '' $item.RouteKey
            }
        }
    }
}

function ConvertTo-PSToolsRouteSnapshotEntry {
    <#
    .SYNOPSIS
    Reduces a route to the fields stored in snapshots and backups.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)]$Route)
    process {
        [pscustomobject]@{
            AddressFamily     = [string]$Route.AddressFamily
            DestinationPrefix = [string]$Route.DestinationPrefix
            NextHop           = [string]$Route.NextHop
            InterfaceAlias    = [string]$Route.InterfaceAlias
            RouteMetric       = [int]$Route.RouteMetric
            Store             = [string]$Route.Store
            Origin            = [string]$Route.Origin
            IsSystem          = [bool]$Route.IsSystem
        }
    }
}

function Compare-PSToolsRouteSnapshot {
    <#
    .SYNOPSIS
    Compares two route lists (snapshot entries or routes) and returns the differences.

    .DESCRIPTION
    Routes are matched by address family, destination, gateway and interface name (interface indexes can
    change after a restart). A matched route counts as changed when its metric or store differs.

    .OUTPUTS
    PSTools.RouteDifference: Change (Added, Removed, Changed), AddressFamily, DestinationPrefix, NextHop,
    InterfaceAlias, Before, After.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Reference,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Difference,
        [switch]$IncludeSystem
    )

    function Get-Key { param($r) '{0}|{1}|{2}|{3}' -f $r.AddressFamily, $r.DestinationPrefix, $r.NextHop, $r.InterfaceAlias }
    function Get-Text { param($r) if (-not $r) { return '' } 'metric {0}, {1}' -f $r.RouteMetric, $r.Store }
    function New-Difference {
        param([string]$Change, $Route, $Before, $After)
        $onLink = $Route.NextHop -eq '0.0.0.0' -or $Route.NextHop -eq '::'
        [pscustomobject]@{
            PSTypeName        = 'PSTools.RouteDifference'
            Change            = $Change
            AddressFamily     = $Route.AddressFamily
            DestinationPrefix = $Route.DestinationPrefix
            NextHop           = $(if ($onLink) { 'On-link' } else { $Route.NextHop })
            InterfaceAlias    = $Route.InterfaceAlias
            Before            = Get-Text $Before
            After             = Get-Text $After
        }
    }

    $old = [ordered]@{}
    foreach ($r in $Reference)  { if ($IncludeSystem -or -not $r.IsSystem) { $old[(Get-Key $r)] = $r } }
    $new = [ordered]@{}
    foreach ($r in $Difference) { if ($IncludeSystem -or -not $r.IsSystem) { $new[(Get-Key $r)] = $r } }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($key in $new.Keys) {
        $after = $new[$key]
        if (-not $old.Contains($key)) { $result.Add((New-Difference Added $after $null $after)); continue }
        $before = $old[$key]
        if ([int]$before.RouteMetric -ne [int]$after.RouteMetric -or $before.Store -ne $after.Store) {
            $result.Add((New-Difference Changed $after $before $after))
        }
    }
    foreach ($key in $old.Keys) {
        if (-not $new.Contains($key)) { $result.Add((New-Difference Removed $old[$key] $old[$key] $null)) }
    }
    $order = @{ Added = 0; Removed = 1; Changed = 2 }
    $result | Sort-Object -Property AddressFamily, @{ Expression = { $order[$_.Change] } }, DestinationPrefix
}

function Get-PSToolsRouteRestorePlan {
    <#
    .SYNOPSIS
    Maps routes from a backup to the interfaces of this PC and tells which ones would be added.

    .DESCRIPTION
    The interface is matched by name first; if no interface has that name, the interface whose subnet
    contains the gateway is used. Routes that exist already (persistent, same destination, gateway and
    interface) are skipped.

    .OUTPUTS
    PSTools.RouteRestoreItem: Action (Add, Exists, Skip), Reason, the route fields and the target interface.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Route)

    $interfaces = @{}
    $persistent = @{}
    foreach ($family in 'IPv4', 'IPv6') {
        $interfaces[$family] = @(Get-PSToolsIPInterface -AddressFamily $family)
        foreach ($r in @(Get-NetRoute -AddressFamily $family -PolicyStore PersistentStore -ErrorAction SilentlyContinue -Verbose:$false)) {
            $persistent[('{0}|{1}|{2}' -f $r.DestinationPrefix, $r.NextHop, $r.InterfaceIndex)] = $true
        }
    }

    foreach ($item in $Route) {
        $action = 'Add'; $reason = ''; $target = $null
        $family = [string]$item.AddressFamily
        $prefix = $null
        try {
            if ($family -notin 'IPv4', 'IPv6') { throw "unknown address family '$family'" }
            $prefix = ConvertTo-PSToolsRoutePrefix -Text ([string]$item.DestinationPrefix) -AddressFamily $family
        }
        catch {
            $action = 'Skip'; $reason = "Invalid entry: $($_.Exception.Message)"
        }

        $nextHop = [string]$item.NextHop
        $onLink  = $prefix -and ($nextHop -eq '' -or $nextHop -eq (Get-PSToolsOnLinkNextHop $family))
        if ($action -eq 'Add') {
            if ($onLink) { $nextHop = Get-PSToolsOnLinkNextHop $family }
            $target = $interfaces[$family] | Where-Object { $_.InterfaceAlias -eq $item.InterfaceAlias } | Select-Object -First 1
            if (-not $target -and -not $onLink) {
                $target = $interfaces[$family] | Where-Object { Test-PSToolsNextHopOnLink -NextHop $nextHop -Interface $_ } | Select-Object -First 1
                if ($target) { $reason = "Interface '$($item.InterfaceAlias)' not found; using '$($target.InterfaceAlias)', which reaches the gateway." }
            }
            if (-not $target) {
                $action = 'Skip'
                $reason = "No interface named '$($item.InterfaceAlias)'" + $(if ($onLink) { '.' } else { ' and no interface reaches the gateway.' })
            }
            elseif ($persistent.ContainsKey(('{0}|{1}|{2}' -f $prefix.Prefix, $nextHop, $target.InterfaceIndex))) {
                $action = 'Exists'; $reason = 'The route exists already.'
            }
        }

        [pscustomobject]@{
            PSTypeName        = 'PSTools.RouteRestoreItem'
            Action            = $action
            Reason            = $reason
            AddressFamily     = $family
            DestinationPrefix = $(if ($prefix) { $prefix.Prefix } else { [string]$item.DestinationPrefix })
            NextHop           = $nextHop
            NextHopDisplay    = $(if ($onLink) { 'On-link' } else { $nextHop })
            RouteMetric       = [int]$item.RouteMetric
            SourceInterface   = [string]$item.InterfaceAlias
            InterfaceAlias    = $(if ($target) { $target.InterfaceAlias } else { '' })
            InterfaceIndex    = $(if ($target) { $target.InterfaceIndex } else { 0 })
            InterfaceState    = $(if ($target) { $target.ConnectionState } else { '' })
        }
    }
}

#endregion
