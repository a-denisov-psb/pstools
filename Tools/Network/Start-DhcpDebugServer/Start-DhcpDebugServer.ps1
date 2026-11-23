#Requires -Version 5.1
# Logic of the tool "DHCP Debug Server". Dot-source this file to use the function from the console:
#   . .\Tools\Network\Start-DhcpDebugServer\Start-DhcpDebugServer.ps1
#   Start-DhcpDebugServer -InterfaceAlias 'Ethernet' -Verbose        (stop with Ctrl+C)

. (Join-Path $PSScriptRoot '..\..\..\Core\Core.ps1')

function Start-DhcpDebugServer {
    <#
    .SYNOPSIS
    Runs a minimal DHCP server on one network adapter for debugging (e.g. a device connected directly to the PC).

    .DESCRIPTION
    Listens on UDP port 67 of one IPv4 address of the adapter and hands out addresses from a pool until it is
    stopped (Ctrl+C in the console, Stop in the GUI). Leases are kept in memory only.

    Supported: DISCOVER -> OFFER, REQUEST -> ACK / NAK, DECLINE, RELEASE, INFORM, relay agents (giaddr).
    Options sent: subnet mask, broadcast address, lease time (T1/T2), server identifier and optionally router,
    DNS servers and domain name. Replies to clients without an address are broadcast.

    Every lease change is returned as an object as soon as it happens (streaming); every packet is logged
    with Write-Verbose.

    Requirements:
      - The adapter needs a static IPv4 address in the subnet of the pool, e.g.
            netsh interface ipv4 set address "<Name>" static 192.168.100.1 255.255.255.0
      - The Windows Firewall must allow inbound UDP port 67 (needs administrator rights once):
            New-NetFirewallRule -DisplayName 'PSTools DHCP Debug Server' -Direction Inbound -Protocol UDP -LocalPort 67 -Action Allow
      - No other DHCP server on this PC may use port 67 on that address (Internet Connection Sharing,
        Hyper-V Default Switch).

    Safety: the server refuses to start on an address that was assigned by DHCP (there is a DHCP server on
    that network already). Before starting, a DHCP DISCOVER is sent from UDP port 68 of the server address;
    if another DHCP server answers, the function stops as well.

    .PARAMETER InterfaceAlias
    Name of the network adapter (as in Get-NetAdapter).

    .PARAMETER ServerAddress
    IPv4 address of the adapter the server listens on. Default: the first static (manual) address of the adapter,
    otherwise its APIPA address.

    .PARAMETER PoolStart
    First address handed out. Default: .100 in the /24 of the server address (whole subnet for prefixes above /24).

    .PARAMETER PoolEnd
    Last address handed out. Default: .199 in the /24 of the server address.

    .PARAMETER SubnetMask
    Subnet mask sent to the clients. Default: the prefix length of the server address.

    .PARAMETER Router
    Default gateway sent to the clients (option 3). Default: none.

    .PARAMETER DnsServer
    DNS servers sent to the clients (option 6). Default: none.

    .PARAMETER DomainName
    DNS domain name sent to the clients (option 15). Default: none.

    .PARAMETER LeaseTimeSeconds
    Lease time in seconds (60 - 2592000). Default: 3600.

    .PARAMETER SkipServerCheck
    Do not check for another DHCP server before starting.

    .PARAMETER SkipVendorLookup
    Do not resolve the vendor of the client MAC addresses from the offline OUI table.

    .OUTPUTS
    PSTools.DhcpLease: Time, State (Offered, Bound, Rejected, Released, Declined, Informed, Expired,
    Other server), IPAddress, MacAddress, HostName, Vendor, VendorClass, LeaseExpires, InterfaceAlias, Message.

    .EXAMPLE
    Start-DhcpDebugServer -InterfaceAlias 'Ethernet 2' -Verbose
    Serves .100-.199 of the adapter's subnet and logs every packet. Stop with Ctrl+C.

    .EXAMPLE
    Start-DhcpDebugServer 'Ethernet 2' -PoolStart 10.0.0.50 -PoolEnd 10.0.0.60 -Router 10.0.0.1 -DnsServer 10.0.0.1 -LeaseTimeSeconds 300

    .NOTES
    Never run this on a production network. Remove the firewall rule when it is no longer needed:
        Remove-NetFirewallRule -DisplayName 'PSTools DHCP Debug Server'
    #>
    [CmdletBinding()]
    [OutputType('PSTools.DhcpLease')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$InterfaceAlias,

        [ValidateScript({ [void](ConvertTo-PSToolsIPv4Number $_); $true })]
        [string]$ServerAddress,

        [ValidateScript({ [void](ConvertTo-PSToolsIPv4Number $_); $true })]
        [string]$PoolStart,

        [ValidateScript({ [void](ConvertTo-PSToolsIPv4Number $_); $true })]
        [string]$PoolEnd,

        [ValidateScript({ [void](ConvertTo-PSToolsIPv4Number $_); $true })]
        [string]$SubnetMask,

        [ValidateScript({ [void](ConvertTo-PSToolsIPv4Number $_); $true })]
        [string]$Router,

        [ValidateScript({ [void](ConvertTo-PSToolsIPv4Number $_); $true })]
        [string[]]$DnsServer,

        [ValidateLength(1, 255)]
        [string]$DomainName,

        [ValidateRange(60, 2592000)]
        [int]$LeaseTimeSeconds = 3600,

        [switch]$SkipServerCheck,

        [switch]$SkipVendorLookup
    )

    #region nested helpers: bytes and packets
    $messageNames = @{ 1 = 'DISCOVER'; 2 = 'OFFER'; 3 = 'REQUEST'; 4 = 'DECLINE'; 5 = 'ACK'; 6 = 'NAK'; 7 = 'RELEASE'; 8 = 'INFORM' }

    function ConvertTo-IPv4Bytes {
        param([string]$Address)
        return , ([System.Net.IPAddress]::Parse($Address).GetAddressBytes())
    }

    function ConvertTo-UInt32Bytes {
        param([long]$Value)
        return , ([byte[]]@((($Value -shr 24) -band 255), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255)))
    }

    function Read-IPv4 {
        param([byte[]]$Data, [int]$Offset)
        return ('{0}.{1}.{2}.{3}' -f $Data[$Offset], $Data[$Offset + 1], $Data[$Offset + 2], $Data[$Offset + 3])
    }

    function Get-InnerMessage {
        param($ErrorRecord)
        $inner = $ErrorRecord.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        return $inner.Message
    }

    function Add-DhcpOption {
        param([System.Collections.Generic.List[byte]]$Packet, [int]$Code, [byte[]]$Value)
        $Packet.Add([byte]$Code)
        $Packet.Add([byte]$Value.Length)
        $Packet.AddRange($Value)
    }

    function New-UdpSocket {
        $udp = New-Object System.Net.Sockets.Socket ([System.Net.Sockets.AddressFamily]::InterNetwork),
                                                    ([System.Net.Sockets.SocketType]::Dgram),
                                                    ([System.Net.Sockets.ProtocolType]::Udp)
        $udp.EnableBroadcast = $true
        # SIO_UDP_CONNRESET off: otherwise an ICMP "port unreachable" makes the next ReceiveFrom fail.
        try { [void]$udp.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch { }
        return $udp
    }

    function ConvertFrom-DhcpPacket {
        # Parses a BOOTP/DHCP packet. Returns $null for anything that is not a DHCP packet.
        param([byte[]]$Data, [int]$Length)

        if ($Length -lt 240) { return $null }
        if ($Data[236] -ne 99 -or $Data[237] -ne 130 -or $Data[238] -ne 83 -or $Data[239] -ne 99) { return $null }

        $options = @{}
        $i = 240
        while ($i -lt $Length) {
            $code = [int]$Data[$i]
            if ($code -eq 0) { $i++; continue }
            if ($code -eq 255 -or $i + 1 -ge $Length) { break }
            $optionLength = [int]$Data[$i + 1]
            if ($i + 2 + $optionLength -gt $Length) { break }
            $value = New-Object byte[] $optionLength
            [Array]::Copy($Data, $i + 2, $value, 0, $optionLength)
            $options[$code] = $value
            $i += 2 + $optionLength
        }

        $hardwareLength = [Math]::Min([int]$Data[2], 16)
        $clientHardware = New-Object byte[] 16
        [Array]::Copy($Data, 28, $clientHardware, 0, 16)
        $hardwareText = [BitConverter]::ToString($clientHardware, 0, $hardwareLength)
        $mac = $null
        if ($Data[1] -eq 1 -and $hardwareLength -eq 6) { $mac = $hardwareText }

        $messageType = 0
        if ($options.ContainsKey(53) -and $options[53].Length -ge 1) { $messageType = [int]$options[53][0] }
        $requested = $null
        if ($options.ContainsKey(50) -and $options[50].Length -eq 4) { $requested = Read-IPv4 -Data $options[50] -Offset 0 }
        $serverId = $null
        if ($options.ContainsKey(54) -and $options[54].Length -eq 4) { $serverId = Read-IPv4 -Data $options[54] -Offset 0 }
        $hostName = $null
        if ($options.ContainsKey(12)) { $hostName = [System.Text.Encoding]::ASCII.GetString($options[12]).Trim([char]0) }
        $vendorClass = $null
        if ($options.ContainsKey(60)) { $vendorClass = [System.Text.Encoding]::ASCII.GetString($options[60]).Trim([char]0) }

        $xidBytes = New-Object byte[] 4
        [Array]::Copy($Data, 4, $xidBytes, 0, 4)

        [pscustomobject]@{
            Op               = [int]$Data[0]
            HardwareType     = $Data[1]
            HardwareLength   = $Data[2]
            XidBytes         = $xidBytes
            Xid              = '0x{0:X2}{1:X2}{2:X2}{3:X2}' -f $xidBytes[0], $xidBytes[1], $xidBytes[2], $xidBytes[3]
            BroadcastFlag    = (($Data[10] -band 0x80) -ne 0)
            FlagBytes        = [byte[]]@($Data[10], $Data[11])
            CiAddr           = Read-IPv4 -Data $Data -Offset 12
            YiAddr           = Read-IPv4 -Data $Data -Offset 16
            GiAddr           = Read-IPv4 -Data $Data -Offset 24
            ClientHardware   = $clientHardware
            MacAddress       = $mac
            ClientKey        = $(if ($mac) { $mac } else { $hardwareText })
            MessageType      = $messageType
            MessageName      = $(if ($messageNames.ContainsKey($messageType)) { $messageNames[$messageType] } else { "type $messageType" })
            RequestedAddress = $requested
            ServerIdentifier = $serverId
            HostName         = $hostName
            VendorClass      = $vendorClass
        }
    }

    function New-DhcpReply {
        # Builds an OFFER / ACK / NAK for a request.
        param(
            $Request,
            [int]$MessageType,
            [string]$YourAddress = '0.0.0.0',
            [string]$ClientAddress = '0.0.0.0',
            [switch]$WithLease,
            [string]$Message
        )

        $header = New-Object byte[] 236
        $header[0] = 2                                   # BOOTREPLY
        $header[1] = $Request.HardwareType
        $header[2] = $Request.HardwareLength
        [Array]::Copy($Request.XidBytes, 0, $header, 4, 4)
        [Array]::Copy($Request.FlagBytes, 0, $header, 10, 2)
        [Array]::Copy((ConvertTo-IPv4Bytes $ClientAddress), 0, $header, 12, 4)
        [Array]::Copy((ConvertTo-IPv4Bytes $YourAddress), 0, $header, 16, 4)
        [Array]::Copy((ConvertTo-IPv4Bytes $Request.GiAddr), 0, $header, 24, 4)
        [Array]::Copy($Request.ClientHardware, 0, $header, 28, 16)

        $packet = New-Object 'System.Collections.Generic.List[byte]' 400
        $packet.AddRange($header)
        $packet.AddRange([byte[]](99, 130, 83, 99))      # magic cookie
        Add-DhcpOption $packet 53 ([byte[]]@($MessageType))
        Add-DhcpOption $packet 54 $serverBytes
        if ($MessageType -eq 6) {
            if ($Message) { Add-DhcpOption $packet 56 ([System.Text.Encoding]::ASCII.GetBytes($Message)) }
        }
        else {
            if ($WithLease) {
                Add-DhcpOption $packet 51 (ConvertTo-UInt32Bytes $LeaseTimeSeconds)
                Add-DhcpOption $packet 58 (ConvertTo-UInt32Bytes ([long]($LeaseTimeSeconds / 2)))
                Add-DhcpOption $packet 59 (ConvertTo-UInt32Bytes ([long]($LeaseTimeSeconds * 7 / 8)))
            }
            Add-DhcpOption $packet 1 $maskBytes
            Add-DhcpOption $packet 28 $broadcastBytes
            if ($routerBytes) { Add-DhcpOption $packet 3 $routerBytes }
            if ($dnsBytes) { Add-DhcpOption $packet 6 $dnsBytes }
            if ($domainBytes) { Add-DhcpOption $packet 15 $domainBytes }
        }
        $packet.Add(255)
        while ($packet.Count -lt 300) { $packet.Add(0) }   # minimum BOOTP size, some clients need it
        return , ($packet.ToArray())
    }

    function Send-DhcpReply {
        # Sends a reply to the relay agent, by unicast to the client's address, or by broadcast. Returns the target.
        param($Request, [byte[]]$Packet, [switch]$Broadcast)

        if ($Request.GiAddr -ne '0.0.0.0') {
            $target = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($Request.GiAddr)), 67
        }
        elseif ($Broadcast -or $Request.BroadcastFlag -or $Request.CiAddr -eq '0.0.0.0') {
            $target = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Broadcast), 68
        }
        else {
            $target = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($Request.CiAddr)), 68
        }
        [void]$socket.SendTo($Packet, $target)
        return $target.ToString()
    }

    function Find-OtherDhcpServer {
        # Sends a DISCOVER from <server address>:68 and returns every DHCP server that answers within 3 seconds.
        $probe = New-UdpSocket
        try {
            try {
                # The Windows DHCP client service holds 0.0.0.0:68; ReuseAddress lets us share the port for the check.
                $probe.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
                $probe.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($serverIP)), 68))
            }
            catch {
                Write-Warning ("Could not check for another DHCP server: UDP port 68 on {0} is not available ({1})." -f
                               $serverIP, (Get-InnerMessage $_))
                return
            }

            $xid = New-Object byte[] 4
            (New-Object System.Random).NextBytes($xid)
            $xidText = '0x{0:X2}{1:X2}{2:X2}{3:X2}' -f $xid[0], $xid[1], $xid[2], $xid[3]

            $header = New-Object byte[] 236
            $header[0] = 1; $header[1] = 1; $header[2] = 6   # BOOTREQUEST, Ethernet, MAC length 6
            [Array]::Copy($xid, 0, $header, 4, 4)
            $header[10] = 0x80                                # broadcast flag
            [Array]::Copy($probeMac, 0, $header, 28, 6)
            $packet = New-Object 'System.Collections.Generic.List[byte]' 300
            $packet.AddRange($header)
            $packet.AddRange([byte[]](99, 130, 83, 99))
            Add-DhcpOption $packet 53 ([byte[]]@(1))
            Add-DhcpOption $packet 55 ([byte[]]@(1, 3, 6, 54))
            $packet.Add(255)
            while ($packet.Count -lt 300) { $packet.Add(0) }

            Write-Verbose ("Checking for another DHCP server: DISCOVER from {0}:68 (xid {1})" -f $serverIP, $xidText)
            [void]$probe.SendTo($packet.ToArray(), (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Broadcast), 67))

            $found    = @{}
            $buffer   = New-Object byte[] 1500
            $deadline = (Get-Date).AddSeconds(3)
            while ((Get-Date) -lt $deadline) {
                if (-not $probe.Poll(200000, [System.Net.Sockets.SelectMode]::SelectRead)) { continue }
                $remote = [System.Net.EndPoint](New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0)
                try { $length = $probe.ReceiveFrom($buffer, [ref]$remote) } catch { continue }
                $reply = ConvertFrom-DhcpPacket -Data $buffer -Length $length
                if (-not $reply -or $reply.Op -ne 2 -or $reply.Xid -ne $xidText) { continue }
                $id = $reply.ServerIdentifier
                if (-not $id) { $id = $remote.Address.ToString() }
                if (-not $found.ContainsKey($id)) {
                    $found[$id] = [pscustomobject]@{ Server = $id; OfferedAddress = $reply.YiAddr }
                    Write-Verbose ("  {0} from {1}: offered {2}" -f $reply.MessageName, $id, $reply.YiAddr)
                }
            }
            $found.Values
        }
        finally {
            $probe.Close()
        }
    }
    #endregion

    #region nested helpers: leases
    function Get-Lease {
        param($Request)
        $lease = $leases[$Request.ClientKey]
        if (-not $lease) {
            $vendor = $null
            if ($Request.MacAddress -and -not $SkipVendorLookup) { $vendor = Resolve-PSToolsMacVendor -MacAddress $Request.MacAddress }
            $lease = [pscustomobject]@{
                Number      = [long]0
                IPAddress   = $null
                State       = 'New'
                Expires     = [datetime]::MinValue
                HostName    = $null
                VendorClass = $null
                Vendor      = $vendor
            }
            $leases[$Request.ClientKey] = $lease
        }
        if ($Request.HostName) { $lease.HostName = $Request.HostName }
        if ($Request.VendorClass) { $lease.VendorClass = $Request.VendorClass }
        return $lease
    }

    function Test-AddressFree {
        # -IgnoreExpired: addresses of other clients whose lease has expired count as free.
        param([long]$Number, [string]$ClientKey, [switch]$IgnoreExpired)

        if ($Number -eq $serverNumber) { return $false }
        if ($declined.Contains($Number)) { return $false }
        $now = Get-Date
        foreach ($entry in $leases.GetEnumerator()) {
            if ($entry.Key -eq $ClientKey) { continue }
            $lease = $entry.Value
            if ($lease.Number -ne $Number) { continue }
            if ($lease.State -in 'Offered', 'Bound' -and $lease.Expires -gt $now) { return $false }
            if (-not $IgnoreExpired) { return $false }
        }
        return $true
    }

    function Select-LeaseAddress {
        # Previous address of the client, then the requested address, then the first free one.
        param($Request)
        $key = $Request.ClientKey
        $existing = $leases[$key]
        if ($existing -and $existing.Number -ge $poolFirst -and $existing.Number -le $poolLast -and
            (Test-AddressFree -Number $existing.Number -ClientKey $key -IgnoreExpired)) {
            return $existing.Number
        }
        if ($Request.RequestedAddress) {
            $number = ConvertTo-PSToolsIPv4Number $Request.RequestedAddress
            if ($number -ge $poolFirst -and $number -le $poolLast -and (Test-AddressFree -Number $number -ClientKey $key)) {
                return $number
            }
        }
        foreach ($ignoreExpired in $false, $true) {
            for ($number = $poolFirst; $number -le $poolLast; $number++) {
                if (Test-AddressFree -Number $number -ClientKey $key -IgnoreExpired:$ignoreExpired) { return $number }
            }
        }
        return $null
    }

    function New-LeaseEvent {
        param([string]$ClientKey, [string]$State, [string]$Message)
        $lease = $leases[$ClientKey]
        $lease.State = $State
        $expires = $null
        if ($State -eq 'Bound') { $expires = $lease.Expires }
        $result = [pscustomobject]@{
            PSTypeName     = 'PSTools.DhcpLease'
            Time           = Get-Date
            State          = $State
            IPAddress      = $lease.IPAddress
            MacAddress     = $ClientKey
            HostName       = $lease.HostName
            Vendor         = $lease.Vendor
            VendorClass    = $lease.VendorClass
            LeaseExpires   = $expires
            InterfaceAlias = $adapter.InterfaceAlias
            Message        = $Message
        }
        $defaultView = New-Object System.Management.Automation.PSPropertySet('DefaultDisplayPropertySet',
            [string[]]@('Time', 'State', 'IPAddress', 'MacAddress', 'HostName', 'Vendor', 'Message'))
        $result | Add-Member -MemberType MemberSet -Name PSStandardMembers `
            -Value ([System.Management.Automation.PSMemberInfo[]]@($defaultView)) -Force
        return $result
    }

    function Update-ExpiredLease {
        $now = Get-Date
        foreach ($key in @($leases.Keys)) {
            $lease = $leases[$key]
            if ($lease.State -in 'Offered', 'Bound' -and $lease.Expires -le $now) {
                $message = if ($lease.State -eq 'Offered') { 'Offer was not accepted.' } else { 'Lease expired without renewal.' }
                New-LeaseEvent -ClientKey $key -State 'Expired' -Message $message
            }
        }
    }
    #endregion

    #region nested helpers: message handlers
    function Invoke-DhcpDiscover {
        param($Request)
        $lease  = Get-Lease $Request
        $number = Select-LeaseAddress $Request
        if ($null -eq $number) {
            Write-Warning ("No free address left in the pool for {0}. Enlarge the pool or wait until leases expire." -f $Request.ClientKey)
            return
        }
        $lease.Number    = $number
        $lease.IPAddress = ConvertFrom-PSToolsIPv4Number $number
        $lease.Expires   = (Get-Date).AddSeconds(60)     # an offer is reserved for one minute
        $reply  = New-DhcpReply -Request $Request -MessageType 2 -YourAddress $lease.IPAddress -WithLease
        $target = Send-DhcpReply -Request $Request -Packet $reply -Broadcast
        Write-Verbose ("  -> OFFER {0} to {1}" -f $lease.IPAddress, $target)
        New-LeaseEvent -ClientKey $Request.ClientKey -State 'Offered'
    }

    function Invoke-DhcpRequest {
        param($Request)
        $key = $Request.ClientKey

        # SELECTING state: the client names the server it chose. Another server means another DHCP server is active.
        if ($Request.ServerIdentifier -and $Request.ServerIdentifier -ne $serverIP) {
            if ($otherServers.Add($Request.ServerIdentifier)) {
                Write-Warning (("Client {0} requested an address from another DHCP server ({1}). Another DHCP server is active " +
                                "on this network; devices may get their address from either server.") -f $key, $Request.ServerIdentifier)
            }
            $lease = $leases[$key]
            if ($lease -and $lease.State -eq 'Offered') {
                New-LeaseEvent -ClientKey $key -State 'Other server' -Message ("Accepted the offer of {0}." -f $Request.ServerIdentifier)
            }
            return
        }

        $requested = $Request.RequestedAddress
        if (-not $requested -and $Request.CiAddr -ne '0.0.0.0') { $requested = $Request.CiAddr }
        if (-not $requested) {
            Write-Verbose '  ignored: REQUEST without requested address'
            return
        }

        $lease  = Get-Lease $Request
        $number = ConvertTo-PSToolsIPv4Number $requested
        $reason = $null
        if (($number -band $maskNumber) -ne $networkNumber) { $reason = "$requested is not in the subnet of this server." }
        elseif ($number -lt $poolFirst -or $number -gt $poolLast) { $reason = "$requested is outside the address pool." }
        elseif (-not (Test-AddressFree -Number $number -ClientKey $key -IgnoreExpired)) { $reason = "$requested is leased to another client." }

        if ($reason) {
            $reply  = New-DhcpReply -Request $Request -MessageType 6 -Message $reason
            $target = Send-DhcpReply -Request $Request -Packet $reply -Broadcast
            Write-Verbose ("  -> NAK to {0}: {1}" -f $target, $reason)
            New-LeaseEvent -ClientKey $key -State 'Rejected' -Message "NAK: $reason The client starts over with DISCOVER."
            return
        }

        $lease.Number    = $number
        $lease.IPAddress = $requested
        $lease.Expires   = (Get-Date).AddSeconds($LeaseTimeSeconds)
        $reply  = New-DhcpReply -Request $Request -MessageType 5 -YourAddress $requested -ClientAddress $Request.CiAddr -WithLease
        $target = Send-DhcpReply -Request $Request -Packet $reply
        Write-Verbose ("  -> ACK {0} to {1}, lease {2} s" -f $requested, $target, $LeaseTimeSeconds)
        New-LeaseEvent -ClientKey $key -State 'Bound'
    }

    function Invoke-DhcpDecline {
        param($Request)
        $lease = Get-Lease $Request
        $address = $Request.RequestedAddress
        if (-not $address) { $address = $lease.IPAddress }
        if ($address) { [void]$declined.Add((ConvertTo-PSToolsIPv4Number $address)) }
        $lease.Number = 0
        Write-Warning (("Client {0} declined {1}: the address is already used by another device (static address?). " +
                        "It is not offered again until the server is restarted.") -f $Request.ClientKey, $address)
        New-LeaseEvent -ClientKey $Request.ClientKey -State 'Declined' -Message "$address is already in use on the network."
    }

    function Invoke-DhcpRelease {
        param($Request)
        if ($Request.ServerIdentifier -and $Request.ServerIdentifier -ne $serverIP) { return }
        $lease = Get-Lease $Request
        $lease.Expires = Get-Date
        New-LeaseEvent -ClientKey $Request.ClientKey -State 'Released'
    }

    function Invoke-DhcpInform {
        param($Request)
        if ($Request.CiAddr -eq '0.0.0.0') { return }
        $lease = Get-Lease $Request
        if (-not $lease.IPAddress) { $lease.IPAddress = $Request.CiAddr }
        $reply  = New-DhcpReply -Request $Request -MessageType 5 -ClientAddress $Request.CiAddr
        $target = Send-DhcpReply -Request $Request -Packet $reply
        Write-Verbose ("  -> ACK (options only) to {0}" -f $target)
        New-LeaseEvent -ClientKey $Request.ClientKey -State 'Informed' -Message "Configured address: $($Request.CiAddr)"
    }
    #endregion

    # 1. Adapter and server address
    $adapter = Get-PSToolsNetworkAdapter -IncludeVirtual -IncludeDisconnected |
        Where-Object { $_.InterfaceAlias -eq $InterfaceAlias } | Select-Object -First 1
    if (-not $adapter) { throw "Network adapter '$InterfaceAlias' was not found." }
    if ($adapter.Status -ne 'Up') {
        Write-Warning "Adapter '$InterfaceAlias' is not connected (status: $($adapter.Status)). Clients can only be served once the link is up."
    }

    $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue -Verbose:$false)
    if (-not $addresses.Count) {
        throw ("Adapter '{0}' has no IPv4 address. Assign a static address first (as administrator):`r`n{1}" -f
               $InterfaceAlias, (Get-PSToolsStaticAddressCommand -InterfaceAlias $InterfaceAlias))
    }
    if ($ServerAddress) {
        $ipEntry = $addresses | Where-Object { $_.IPAddress -eq $ServerAddress } | Select-Object -First 1
        if (-not $ipEntry) {
            throw ("The address {0} is not assigned to adapter '{1}' (addresses: {2})." -f $ServerAddress, $InterfaceAlias, (($addresses.IPAddress) -join ', '))
        }
    }
    else {
        $ipEntry = $addresses | Sort-Object -Property @{ Expression = {
            switch ([string]$_.PrefixOrigin) { 'Manual' { 0 } 'Dhcp' { 2 } default { 1 } } } } | Select-Object -First 1
    }
    $serverIP = [string]$ipEntry.IPAddress
    switch ([string]$ipEntry.PrefixOrigin) {
        'Dhcp' {
            throw (("Adapter '{0}' got its address {1} from a DHCP server, so a DHCP server is already active on this network. " +
                    "Use a separate network (e.g. a direct cable to the device) and give the adapter a static address:`r`n{2}") -f
                   $InterfaceAlias, $serverIP, (Get-PSToolsStaticAddressCommand -InterfaceAlias $InterfaceAlias))
        }
        'WellKnown' {
            Write-Warning (("{0} is an APIPA address that Windows may change at any time. A static address is recommended:`r`n{1}") -f
                           $serverIP, (Get-PSToolsStaticAddressCommand -InterfaceAlias $InterfaceAlias))
        }
    }

    # 2. Subnet and pool
    $serverNumber = ConvertTo-PSToolsIPv4Number $serverIP
    if ($SubnetMask) {
        $maskNumber = ConvertTo-PSToolsIPv4Number $SubnetMask
        $inverted = [long]4294967295 -bxor $maskNumber
        if (($inverted -band ($inverted + 1)) -ne 0) { throw "'$SubnetMask' is not a valid subnet mask." }
    }
    else {
        $maskNumber = ([long]4294967295 -shl (32 - [int]$ipEntry.PrefixLength)) -band [long]4294967295
    }
    $prefix = 0
    for ($bit = 31; $bit -ge 0; $bit--) { if ($maskNumber -band ([long]1 -shl $bit)) { $prefix++ } }
    if ($prefix -lt 8 -or $prefix -gt 30) { throw "The subnet mask /$prefix is not supported (/8 to /30)." }

    $networkNumber   = $serverNumber -band $maskNumber
    $broadcastNumber = $networkNumber + ([long]4294967295 -bxor $maskNumber)
    $subnetText      = '{0}/{1}' -f (ConvertFrom-PSToolsIPv4Number $networkNumber), $prefix

    if ([bool]$PoolStart -ne [bool]$PoolEnd) { throw 'Specify both PoolStart and PoolEnd, or neither.' }
    if ($PoolStart) {
        $poolFirst = ConvertTo-PSToolsIPv4Number $PoolStart
        $poolLast  = ConvertTo-PSToolsIPv4Number $PoolEnd
    }
    elseif ($prefix -le 24) {
        $base = $serverNumber -band [long]4294967040
        $poolFirst = $base + 100
        $poolLast  = $base + 199
    }
    else {
        $poolFirst = $networkNumber + 1
        $poolLast  = $broadcastNumber - 1
    }
    $poolText = '{0} - {1}' -f (ConvertFrom-PSToolsIPv4Number $poolFirst), (ConvertFrom-PSToolsIPv4Number $poolLast)
    if ($poolFirst -gt $poolLast) { throw "The pool start must not be greater than the pool end ($poolText)." }
    if ($poolFirst -le $networkNumber -or $poolLast -ge $broadcastNumber) {
        throw "The pool $poolText must be inside the subnet $subnetText of the server address $serverIP (without network and broadcast address)."
    }
    if ($serverNumber -ge $poolFirst -and $serverNumber -le $poolLast) {
        Write-Verbose "The server address $serverIP is inside the pool and will not be handed out."
    }
    if ($Router -and ((ConvertTo-PSToolsIPv4Number $Router) -band $maskNumber) -ne $networkNumber) {
        Write-Warning "The gateway $Router is not in the subnet $subnetText. Clients will not be able to use it."
    }

    # 3. Option values
    $serverBytes    = ConvertTo-IPv4Bytes $serverIP
    $maskBytes      = ConvertTo-UInt32Bytes $maskNumber
    $broadcastBytes = ConvertTo-UInt32Bytes $broadcastNumber
    $routerBytes    = $null
    if ($Router) { $routerBytes = ConvertTo-IPv4Bytes $Router }
    $dnsBytes = $null
    if ($DnsServer) { $dnsBytes = [byte[]]@($DnsServer | ForEach-Object { ConvertTo-IPv4Bytes $_ } | ForEach-Object { $_ }) }
    $domainBytes = $null
    if ($DomainName) { $domainBytes = [System.Text.Encoding]::ASCII.GetBytes($DomainName) }

    $probeMac = [byte[]]@(0x02, 0x00, 0x00, 0x00, 0x00, 0x01)
    if ($adapter.MacAddress) { $probeMac = [byte[]]@($adapter.MacAddress.Split('-') | ForEach-Object { [Convert]::ToByte($_, 16) }) }

    $activity = "DHCP server on '$($adapter.InterfaceAlias)' ($serverIP)"
    Write-Verbose ("Adapter: {0} (index {1}), server address {2}, subnet {3}, pool {4}, lease {5} s" -f
                   $adapter.InterfaceAlias, $adapter.InterfaceIndex, $serverIP, $subnetText, $poolText, $LeaseTimeSeconds)

    # 4. Check for another DHCP server
    if (-not $SkipServerCheck) {
        Write-Progress -Activity $activity -Status 'Checking for another DHCP server (3 s)…' -PercentComplete -1
        $others = @(Find-OtherDhcpServer)
        if ($others.Count) {
            $list = ($others | ForEach-Object { '{0} (offered {1})' -f $_.Server, $_.OfferedAddress }) -join ', '
            Write-Progress -Activity $activity -Completed
            throw (("Another DHCP server answered on '{0}': {1}. A second DHCP server disturbs all devices on this network. " +
                    "Use a separate network (e.g. a direct cable to the device), or skip the check if you are sure.") -f $InterfaceAlias, $list)
        }
        Write-Verbose 'No other DHCP server answered.'
    }

    # 5. Serve
    $leases       = @{}
    $declined     = New-Object 'System.Collections.Generic.HashSet[long]'
    $otherServers = New-Object 'System.Collections.Generic.HashSet[string]'
    $stats        = @{ Requests = 0 }

    $socket = New-UdpSocket
    try {
        try {
            $socket.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($serverIP)), 67))
        }
        catch {
            throw (("UDP port 67 on {0} is already in use ({1}). Another DHCP server runs on this PC, e.g. Internet Connection " +
                    "Sharing, the Hyper-V Default Switch or a second instance of this tool. Choose another adapter or stop it.") -f
                   $serverIP, (Get-InnerMessage $_))
        }
        Write-Verbose "Listening on $($serverIP):67. Stop with Ctrl+C (console) or Stop (GUI)."

        $buffer = New-Object byte[] 1500
        $lastExpiryCheck = Get-Date
        $updateProgress = {
            $active = @($leases.Values | Where-Object { $_.State -eq 'Bound' }).Count
            Write-Progress -Activity $activity -PercentComplete -1 -Status ('Listening on {0}:67  |  pool {1}  |  {2} active lease(s)  |  {3} request(s)' -f
                $serverIP, $poolText, $active, $stats.Requests)
        }
        . $updateProgress

        while ($true) {
            if (((Get-Date) - $lastExpiryCheck).TotalSeconds -ge 1) {
                $lastExpiryCheck = Get-Date
                $expired = @(Update-ExpiredLease)
                if ($expired.Count) { $expired; . $updateProgress }
            }
            if (-not $socket.Poll(500000, [System.Net.Sockets.SelectMode]::SelectRead)) { continue }

            $remote = [System.Net.EndPoint](New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0)
            try {
                $length = $socket.ReceiveFrom($buffer, [ref]$remote)
            }
            catch {
                Write-Verbose ("Receive failed: {0}" -f (Get-InnerMessage $_))
                continue
            }

            $request = ConvertFrom-DhcpPacket -Data $buffer -Length $length
            if (-not $request -or $request.Op -ne 1) { continue }
            $stats.Requests++

            $details = ''
            if ($request.HostName) { $details += " host '$($request.HostName)'" }
            if ($request.RequestedAddress) { $details += " wants $($request.RequestedAddress)" }
            if ($request.CiAddr -ne '0.0.0.0') { $details += " ciaddr $($request.CiAddr)" }
            Write-Verbose ("{0} from {1}{2} via {3} (xid {4})" -f $request.MessageName, $request.ClientKey, $details, $remote, $request.Xid)

            try {
                if ($request.MessageType -eq 1) { Invoke-DhcpDiscover $request }
                elseif ($request.MessageType -eq 3) { Invoke-DhcpRequest $request }
                elseif ($request.MessageType -eq 4) { Invoke-DhcpDecline $request }
                elseif ($request.MessageType -eq 7) { Invoke-DhcpRelease $request }
                elseif ($request.MessageType -eq 8) { Invoke-DhcpInform $request }
                else { Write-Verbose '  ignored (not handled by this server)' }
            }
            catch [System.Management.Automation.PipelineStoppedException] {
                throw
            }
            catch {
                Write-Warning ("Could not handle {0} from {1}: {2}" -f $request.MessageName, $request.ClientKey, (Get-InnerMessage $_))
            }
            . $updateProgress
        }
    }
    finally {
        $socket.Close()
        Write-Progress -Activity $activity -Completed
    }
}
