#Requires -Version 5.1
# Network helpers: IPv4 math, adapter listing, ARP / neighbor cache, APIPA helpers.

# Import the built-in network modules up front and quietly; autoloading them later inside a function
# that runs with -Verbose would write hundreds of "exporting function ..." messages.
Import-Module -Name NetTCPIP, NetAdapter -ErrorAction SilentlyContinue -Verbose:$false

#region IPv4 math

function ConvertTo-PSToolsIPv4Number {
    <#
    .SYNOPSIS
    Converts a dotted IPv4 address to a 64-bit integer (avoids UInt32 overflow pitfalls in PowerShell).
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory, ValueFromPipeline)][string]$IPAddress)

    process {
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed) -or
            $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "'$IPAddress' is not a valid IPv4 address."
        }
        $b = $parsed.GetAddressBytes()
        return ([long]$b[0] -shl 24) + ([long]$b[1] -shl 16) + ([long]$b[2] -shl 8) + [long]$b[3]
    }
}

function ConvertFrom-PSToolsIPv4Number {
    <#
    .SYNOPSIS
    Converts a 64-bit integer (0..4294967295) back to a dotted IPv4 address.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, ValueFromPipeline)][long]$Number)

    process {
        '{0}.{1}.{2}.{3}' -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255),
                             (($Number -shr 8) -band 255), ($Number -band 255)
    }
}

function Get-PSToolsIPv4Range {
    <#
    .SYNOPSIS
    Parses a CIDR string (e.g. 169.254.0.0/16) or a single address and returns its host range.

    .DESCRIPTION
    Returns Network, Broadcast, First and Last host (as 64-bit integers), Prefix and Count.
    For prefixes up to /30 the network and broadcast address are excluded from First..Last.

    .EXAMPLE
    Get-PSToolsIPv4Range -Cidr 169.254.12.0/24
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cidr)

    $text = $Cidr.Trim()
    if ($text -notmatch '^(?<ip>\d{1,3}(?:\.\d{1,3}){3})(?:/(?<prefix>\d{1,2}))?$') {
        throw "'$Cidr' is not a valid IPv4 subnet. Expected format: 169.254.0.0/16"
    }
    $prefix = 32
    if ($Matches['prefix']) { $prefix = [int]$Matches['prefix'] }
    if ($prefix -gt 32) { throw "Prefix length /$prefix is invalid (0-32)." }

    $address   = ConvertTo-PSToolsIPv4Number -IPAddress $Matches['ip']
    $mask      = ([long]0xFFFFFFFF -shl (32 - $prefix)) -band [long]0xFFFFFFFF
    $network   = $address -band $mask
    $broadcast = $network + ([long]0xFFFFFFFF -bxor $mask)

    $first = $network
    $last  = $broadcast
    if ($prefix -le 30) { $first++; $last-- }

    [pscustomobject]@{
        PSTypeName = 'PSTools.IPv4Range'
        Cidr       = '{0}/{1}' -f (ConvertFrom-PSToolsIPv4Number $network), $prefix
        Prefix     = $prefix
        Network    = $network
        Broadcast  = $broadcast
        First      = $first
        Last       = $last
        Count      = $last - $first + 1
    }
}

function Test-PSToolsApipaAddress {
    <#
    .SYNOPSIS
    Returns $true for addresses in 169.254.0.0/16.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$IPAddress)
    return ($IPAddress -like '169.254.*')
}

#endregion

#region MAC helpers

function ConvertTo-PSToolsMacAddress {
    <#
    .SYNOPSIS
    Normalizes a MAC address to the format AA-BB-CC-DD-EE-FF. Returns $null for invalid input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$MacAddress)

    if (-not $MacAddress) { return $null }
    $hex = ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -ne 12) { return $null }
    return ($hex -replace '(..)(?!$)', '$1-')
}

function Test-PSToolsUnicastMac {
    <#
    .SYNOPSIS
    Returns $true for a valid unicast MAC (not empty, not broadcast, not multicast).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$MacAddress)

    $mac = ConvertTo-PSToolsMacAddress $MacAddress
    if (-not $mac) { return $false }
    if ($mac -eq '00-00-00-00-00-00' -or $mac -eq 'FF-FF-FF-FF-FF-FF') { return $false }
    # Multicast: least significant bit of the first octet is set (01-00-5E-.., 33-33-.., ...)
    $firstOctet = [Convert]::ToInt32($mac.Substring(0, 2), 16)
    return (($firstOctet -band 1) -eq 0)
}

#endregion

#region Adapters

function Test-PSToolsVirtualAdapter {
    <#
    .SYNOPSIS
    Returns $true for virtual, tunnel, VPN, VM and Bluetooth adapters (not useful for LAN diagnostics).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Adapter)

    if ($Adapter.Virtual) { return $true }
    if ($null -ne $Adapter.HardwareInterface -and -not $Adapter.HardwareInterface) { return $true }
    $pattern = 'virtual|hyper-v|vethernet|vmware|virtualbox|tap-|tap adapter|tap-windows|wintun|wireguard|' +
               'openvpn|vpn|tailscale|zerotier|fortinet|anyconnect|juniper|pangp|bluetooth|loopback|' +
               'miniport|npcap|teredo|isatap|kernel debug'
    return ($Adapter.InterfaceDescription -match $pattern -or $Adapter.Name -match $pattern)
}

function Get-PSToolsNetworkAdapter {
    <#
    .SYNOPSIS
    Lists network adapters with their IPv4 and APIPA addresses.

    .DESCRIPTION
    By default only physical adapters that are connected (Status Up) are returned. Virtual, VPN, VM and
    Bluetooth adapters as well as disconnected adapters can be included with the switches.
    Results are sorted: adapters with an APIPA address first, then connected ones, then by name.

    .PARAMETER IncludeVirtual
    Also return virtual / tunnel / VM / Bluetooth adapters.

    .PARAMETER IncludeDisconnected
    Also return adapters that are not Up.

    .PARAMETER ApipaOnly
    Only return adapters that currently have a 169.254.x.x address.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeVirtual,
        [switch]$IncludeDisconnected,
        [switch]$ApipaOnly
    )

    # The NetAdapter script properties (Status, LinkSpeed, ...) import a helper module and would flood the
    # verbose stream with "importing function ..." messages.
    $VerbosePreference = 'SilentlyContinue'

    $ipAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue -Verbose:$false)
    $adapters    = @(Get-NetAdapter -ErrorAction SilentlyContinue -Verbose:$false)

    $result = foreach ($adapter in $adapters) {
        $isVirtual = Test-PSToolsVirtualAdapter -Adapter $adapter
        if ($isVirtual -and -not $IncludeVirtual) { continue }
        if ($adapter.Status -ne 'Up' -and -not $IncludeDisconnected) { continue }

        $ipv4  = @($ipAddresses | Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex } |
                   Sort-Object -Property SkipAsSource | ForEach-Object { $_.IPAddress })
        $apipa = $ipv4 | Where-Object { Test-PSToolsApipaAddress $_ } | Select-Object -First 1
        if ($ApipaOnly -and -not $apipa) { continue }

        $addressText = if ($ipv4.Count) { $ipv4 -join ', ' } else { 'no IPv4' }
        [pscustomobject]@{
            PSTypeName     = 'PSTools.NetworkAdapter'
            InterfaceAlias = $adapter.Name
            InterfaceIndex = [int]$adapter.ifIndex
            Description    = $adapter.InterfaceDescription
            Status         = [string]$adapter.Status
            MacAddress     = ConvertTo-PSToolsMacAddress $adapter.MacAddress
            LinkSpeed      = $adapter.LinkSpeed
            IPv4Address    = $ipv4
            ApipaAddress   = $apipa
            IsVirtual      = $isVirtual
            DisplayName    = '{0}  –  {1}  [{2}]  {3}' -f $adapter.Name, $addressText, $adapter.Status, $adapter.InterfaceDescription
        }
    }

    $result | Sort-Object -Property @{ Expression = { [bool]$_.ApipaAddress }; Descending = $true },
                                    @{ Expression = { $_.Status -eq 'Up' }; Descending = $true },
                                    InterfaceAlias
}

#endregion

#region ARP / neighbor cache

function Get-PSToolsArpTable {
    <#
    .SYNOPSIS
    Reads the ARP cache by parsing 'arp.exe -a' (language independent).

    .DESCRIPTION
    'arp -a' is used because Get-NetNeighbor can lag behind right after a ping sweep.
    Only valid unicast entries are returned.

    .PARAMETER InterfaceIndex
    Only return entries of this interface.
    #>
    [CmdletBinding()]
    param([int]$InterfaceIndex = -1)

    $lines = & "$env:SystemRoot\System32\arp.exe" -a 2>$null
    $currentIndex     = -1
    $currentInterface = $null

    foreach ($line in $lines) {
        # Header, e.g. "Interface: 169.254.1.2 --- 0x5" / "Schnittstelle: 169.254.1.2 --- 0x5"
        if ($line -match '(\d{1,3}(?:\.\d{1,3}){3})\s+---\s+0x([0-9A-Fa-f]+)') {
            $currentInterface = $Matches[1]
            $currentIndex     = [Convert]::ToInt32($Matches[2], 16)
            continue
        }
        if ($line -match '^\s+(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5})\s+(\S+)') {
            if ($InterfaceIndex -ge 0 -and $currentIndex -ne $InterfaceIndex) { continue }
            if (-not (Test-PSToolsUnicastMac $Matches[2])) { continue }
            [pscustomobject]@{
                PSTypeName       = 'PSTools.NeighborEntry'
                IPAddress        = $Matches[1]
                MacAddress       = ConvertTo-PSToolsMacAddress $Matches[2]
                InterfaceIndex   = $currentIndex
                InterfaceAddress = $currentInterface
                Type             = $Matches[3]
                Source           = 'arp'
            }
        }
    }
}

function Get-PSToolsNeighbor {
    <#
    .SYNOPSIS
    Returns the neighbor (ARP) cache of an interface, combining 'arp -a' and Get-NetNeighbor.

    .DESCRIPTION
    Both sources are merged and de-duplicated by IP address ('arp -a' wins). Incomplete and
    unreachable entries as well as broadcast/multicast addresses are excluded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$InterfaceIndex)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($entry in Get-PSToolsArpTable -InterfaceIndex $InterfaceIndex) {
        if ($seen.Add($entry.IPAddress)) { $entry }
    }

    $neighbors = Get-NetNeighbor -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue -Verbose:$false
    foreach ($n in $neighbors) {
        if ([string]$n.State -in 'Unreachable', 'Incomplete') { continue }
        if (-not (Test-PSToolsUnicastMac $n.LinkLayerAddress)) { continue }
        if (-not $seen.Add($n.IPAddress)) { continue }
        [pscustomobject]@{
            PSTypeName       = 'PSTools.NeighborEntry'
            IPAddress        = $n.IPAddress
            MacAddress       = ConvertTo-PSToolsMacAddress $n.LinkLayerAddress
            InterfaceIndex   = [int]$n.InterfaceIndex
            InterfaceAddress = $null
            Type             = [string]$n.State
            Source           = 'Get-NetNeighbor'
        }
    }
}

function Get-PSToolsNeighborMac {
    <#
    .SYNOPSIS
    Resolves the MAC address of a single IP from the neighbor cache ('arp -a' first, then Get-NetNeighbor).

    .PARAMETER ArpTable
    Optional pre-read result of Get-PSToolsArpTable to avoid calling arp.exe again.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [int]$InterfaceIndex = -1,
        [object[]]$ArpTable
    )

    if (-not $ArpTable) { $ArpTable = @(Get-PSToolsArpTable -InterfaceIndex $InterfaceIndex) }
    $hit = $ArpTable | Where-Object { $_.IPAddress -eq $IPAddress } | Select-Object -First 1
    if ($hit) { return $hit.MacAddress }

    $params = @{ IPAddress = $IPAddress; AddressFamily = 'IPv4'; ErrorAction = 'SilentlyContinue'; Verbose = $false }
    if ($InterfaceIndex -ge 0) { $params.InterfaceIndex = $InterfaceIndex }
    $n = Get-NetNeighbor @params | Where-Object { Test-PSToolsUnicastMac $_.LinkLayerAddress } | Select-Object -First 1
    if ($n) { return (ConvertTo-PSToolsMacAddress $n.LinkLayerAddress) }
    return $null
}

#endregion

#region APIPA helpers

function Get-PSToolsApipaCommand {
    <#
    .SYNOPSIS
    Returns the netsh command that adds a static APIPA address to an adapter.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$InterfaceAlias = '<Name>',
        [string]$IPAddress = '169.254.1.1'
    )
    return ('netsh interface ipv4 add address "{0}" {1} 255.255.0.0' -f $InterfaceAlias, $IPAddress)
}

function Get-PSToolsApipaHint {
    <#
    .SYNOPSIS
    Returns an explanatory text for adapters without an APIPA address, including the netsh command.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$InterfaceAlias,
        # Omit the netsh command (e.g. when the GUI shows it in a separate field).
        [switch]$NoCommand
    )

    $subject = if ($InterfaceAlias) { "Adapter '$InterfaceAlias' has no" } else { 'No connected physical adapter has an' }
    $text = "$subject APIPA address (169.254.x.x). Windows assigns one automatically when DHCP is " +
            "enabled and no DHCP server answers (this can take up to a minute after the link comes up)."
    if ($NoCommand) { return "$text To add one manually, run the command below as administrator." }
    $command = Get-PSToolsApipaCommand -InterfaceAlias $(if ($InterfaceAlias) { $InterfaceAlias } else { '<Name>' })
    return "$text To add one manually, run as administrator: $command"
}

function Add-PSToolsApipaAddress {
    <#
    .SYNOPSIS
    Adds a static APIPA address (255.255.0.0) to an adapter via netsh. Requires administrator rights.

    .DESCRIPTION
    Uses 'netsh interface ipv4 add address', which keeps existing addresses and DHCP settings untouched
    as far as possible. Returns the netsh output; throws if netsh reports an error.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$InterfaceAlias,
        [string]$IPAddress = '169.254.1.1'
    )

    if (-not (Test-PSToolsIsAdmin)) { throw 'Adding an IP address requires administrator rights.' }
    if ($PSCmdlet.ShouldProcess($InterfaceAlias, "Add IPv4 address $IPAddress/16")) {
        $output = & "$env:SystemRoot\System32\netsh.exe" interface ipv4 add address "$InterfaceAlias" $IPAddress 255.255.0.0 2>&1
        if ($LASTEXITCODE -ne 0) { throw "netsh failed (exit code $LASTEXITCODE): $($output -join ' ')" }
        return ($output -join [Environment]::NewLine).Trim()
    }
}

#endregion

#region Static address helpers

function Get-PSToolsStaticAddressCommand {
    <#
    .SYNOPSIS
    Returns the netsh command that sets a static IPv4 address on an adapter (replaces DHCP),
    or with -Dhcp the command that switches the adapter back to DHCP.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Static')]
    [OutputType([string])]
    param(
        [string]$InterfaceAlias = '<Name>',
        [Parameter(ParameterSetName = 'Static')][string]$IPAddress = '192.168.100.1',
        [Parameter(ParameterSetName = 'Static')][string]$SubnetMask = '255.255.255.0',
        [Parameter(Mandatory, ParameterSetName = 'Dhcp')][switch]$Dhcp
    )
    if ($Dhcp) { return ('netsh interface ipv4 set address name="{0}" dhcp' -f $InterfaceAlias) }
    return ('netsh interface ipv4 set address name="{0}" static {1} {2}' -f $InterfaceAlias, $IPAddress, $SubnetMask)
}

function Set-PSToolsStaticAddress {
    <#
    .SYNOPSIS
    Sets a static IPv4 address on an adapter via netsh (DHCP is disabled for this adapter). Requires administrator rights.

    .DESCRIPTION
    Revert with: netsh interface ipv4 set address name="<Name>" dhcp
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$InterfaceAlias,
        [string]$IPAddress = '192.168.100.1',
        [string]$SubnetMask = '255.255.255.0'
    )

    if (-not (Test-PSToolsIsAdmin)) { throw 'Setting a static IP address requires administrator rights.' }
    if ($PSCmdlet.ShouldProcess($InterfaceAlias, "Set static IPv4 address $IPAddress $SubnetMask")) {
        $output = & "$env:SystemRoot\System32\netsh.exe" interface ipv4 set address "$InterfaceAlias" static $IPAddress $SubnetMask 2>&1
        if ($LASTEXITCODE -ne 0) { throw "netsh failed (exit code $LASTEXITCODE): $($output -join ' ')" }
        return ($output -join [Environment]::NewLine).Trim()
    }
}

#endregion

#region Windows Firewall

function Test-PSToolsFirewallPortOpen {
    <#
    .SYNOPSIS
    Returns $true if the Windows Firewall lets unsolicited inbound traffic reach a local port.

    .DESCRIPTION
    Uses the firewall COM API (HNetCfg.FwPolicy2), which is fast and works without administrator rights.
    The port counts as open if the firewall is disabled for all active profiles, or if an enabled inbound
    allow rule for an active profile matches the protocol and either names the port ('67', '60-70') or allows
    any port for the given program. Rules with neither port nor program are ignored (app container rules).
    Block rules and group policy details are not evaluated, so treat the result as a hint.

    .PARAMETER ApplicationPath
    Program that listens on the port. Rules restricted to this program count as matching. Default: this PowerShell.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateSet('TCP', 'UDP')][string]$Protocol,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$LocalPort,
        [string]$ApplicationPath = (Get-Process -Id $PID).Path
    )

    $policy = New-Object -ComObject HNetCfg.FwPolicy2
    $activeProfiles = [int]$policy.CurrentProfileTypes
    $enabledForActive = $false
    foreach ($profileType in 1, 2, 4) {
        if (($activeProfiles -band $profileType) -and $policy.FirewallEnabled($profileType)) { $enabledForActive = $true }
    }
    if (-not $enabledForActive) { return $true }

    $protocolNumber = if ($Protocol -eq 'TCP') { 6 } else { 17 }
    foreach ($rule in $policy.Rules) {
        # Direction 1 = inbound, Action 1 = allow, Protocol 256 = any
        if (-not $rule.Enabled -or $rule.Direction -ne 1 -or $rule.Action -ne 1) { continue }
        if ($rule.Protocol -ne $protocolNumber -and $rule.Protocol -ne 256) { continue }
        if (-not ($rule.Profiles -band $activeProfiles)) { continue }
        if ($rule.ApplicationName -and $rule.ApplicationName -ne $ApplicationPath) { continue }

        $ports = [string]$rule.LocalPorts
        if (-not $ports -or $ports -eq '*') {
            # Rules without program and port are app container rules (Store apps): the COM API does not show
            # their package binding, so only count "any port" rules that name our program.
            if ($rule.ApplicationName) { return $true }
            continue
        }
        foreach ($part in $ports.Split(',')) {
            $part = $part.Trim()
            if ($part -match '^(\d+)-(\d+)$') {
                if ($LocalPort -ge [int]$Matches[1] -and $LocalPort -le [int]$Matches[2]) { return $true }
            }
            elseif ($part -eq [string]$LocalPort) { return $true }
        }
    }
    return $false
}

function Get-PSToolsFirewallRuleCommand {
    <#
    .SYNOPSIS
    Returns the PowerShell command that adds an inbound allow rule for a local port.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][ValidateSet('TCP', 'UDP')][string]$Protocol,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$LocalPort
    )
    return ("New-NetFirewallRule -DisplayName '{0}' -Direction Inbound -Protocol {1} -LocalPort {2} -Action Allow" -f $DisplayName, $Protocol, $LocalPort)
}

function Add-PSToolsFirewallRule {
    <#
    .SYNOPSIS
    Adds an inbound allow rule for a local port (all profiles). Requires administrator rights.

    .DESCRIPTION
    Remove the rule later with: Remove-NetFirewallRule -DisplayName '<DisplayName>'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][ValidateSet('TCP', 'UDP')][string]$Protocol,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$LocalPort
    )

    if (-not (Test-PSToolsIsAdmin)) { throw 'Adding a firewall rule requires administrator rights.' }
    if ($PSCmdlet.ShouldProcess($DisplayName, "Allow inbound $Protocol port $LocalPort")) {
        New-NetFirewallRule -DisplayName $DisplayName -Direction Inbound -Protocol $Protocol -LocalPort $LocalPort `
            -Action Allow -Profile Any -Verbose:$false | Out-Null
    }
}

#endregion
