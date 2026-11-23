#Requires -Version 5.1
# Logic of the tool "Port Check". Dot-source this file to use the function from the console:
#   . .\Tools\Network\Test-PortConnection\Test-PortConnection.ps1
#   Test-PortConnection -ComputerName server01 -Port 3389

. (Join-Path $PSScriptRoot '..\..\..\Core\Core.ps1')

function Test-PortConnection {
    <#
    .SYNOPSIS
    Checks whether TCP and/or UDP ports on a host are reachable.

    .DESCRIPTION
    TCP: opens a connection (three-way handshake) and closes it again. Results:
      Open         the service accepted the connection (ResponseTimeMs = connect time)
      Closed       the host answered with a reset: it is reachable, but nothing listens on the port
      Filtered     no answer within the timeout: a firewall drops the packets, or the host is offline
      Unreachable  the network or host is unreachable (e.g. no route)
      Blocked      Windows refused to send the packets (local firewall rule or security software)

    Windows retries a refused connection for about 2 seconds before it reports it. With a timeout below
    2500 ms a closed port may therefore be reported as 'Filtered'.

    UDP: has no handshake, so 'reachable' can only be proven when the service answers. For DNS (53),
    NTP (123), NetBIOS (137) and SNMP (161, community 'public') a valid request is sent, so these services
    answer; other ports get a one-byte datagram most services ignore. Results:
      Open           a response was received
      Closed         the host answered with ICMP 'port unreachable'
      Open|Filtered  no answer: the service may listen and ignore the probe, or a firewall drops it
      Unreachable    the network or host is unreachable
      Blocked        Windows refused to send the packets (local firewall rule or security software)

    Host names are resolved once; IPv4 is preferred when the name has IPv4 and IPv6 addresses.
    The source address is the local address Windows uses to reach the target (routing table).

    .PARAMETER ComputerName
    Host name, IPv4 or IPv6 address of the target.

    .PARAMETER Port
    One or more ports (1-65535).

    .PARAMETER Protocol
    TCP, UDP or both. Default: TCP.

    .PARAMETER TimeoutMs
    Time to wait for an answer per port and protocol in milliseconds (100-60000). Default: 3000.

    .OUTPUTS
    PSTools.PortCheckResult: Timestamp, ComputerName, RemoteAddress, Port, Protocol, Service, State,
    ResponseTimeMs, SourceAddress, InterfaceAlias, Detail.

    .EXAMPLE
    Test-PortConnection -ComputerName server01 -Port 3389
    Checks whether RDP is reachable on server01.

    .EXAMPLE
    Test-PortConnection dc01 -Port 53 -Protocol TCP, UDP | Format-Table
    Checks DNS over TCP and UDP.

    .EXAMPLE
    Test-PortConnection 192.168.1.10 -Port (ConvertTo-PSToolsPortList '80,443,8000-8010') -TimeoutMs 2500
    Checks a list of ports.
    #>
    [CmdletBinding()]
    [OutputType('PSTools.PortCheckResult')]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [Parameter(Mandatory, Position = 1)][ValidateRange(1, 65535)][int[]]$Port,
        [ValidateSet('TCP', 'UDP')][string[]]$Protocol = 'TCP',
        [ValidateRange(100, 60000)][int]$TimeoutMs = 3000
    )

    #region Nested helpers

    function Resolve-Target {
        param([string]$Name)
        $address = $null
        if ([System.Net.IPAddress]::TryParse($Name.Trim('[', ']'), [ref]$address)) { return $address }
        try {
            $all = @([System.Net.Dns]::GetHostAddresses($Name))
        }
        catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            throw "The host name '$Name' could not be resolved: $($inner.Message)"
        }
        if (-not $all.Count) { throw "The host name '$Name' could not be resolved." }
        Write-Verbose ("'{0}' resolves to {1}" -f $Name, (($all | ForEach-Object { $_.ToString() }) -join ', '))
        $ipv4 = $all | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if ($ipv4) { return $ipv4 }
        return $all[0]
    }

    function Get-SourceInfo {
        # A connected UDP socket picks the local address from the routing table without sending anything.
        param([System.Net.IPAddress]$Address)
        $info = [pscustomobject]@{ Address = $null; InterfaceAlias = $null }
        $socket = New-Object System.Net.Sockets.Socket($Address.AddressFamily, 'Dgram', 'Udp')
        try {
            $socket.Connect($Address, 9)
            $info.Address = $socket.LocalEndPoint.Address.ToString()
        }
        catch {
            Write-Verbose "No route to $Address."
            return $info
        }
        finally {
            $socket.Close()
        }
        try {
            $ip = Get-NetIPAddress -IPAddress ($info.Address -replace '%\d+$', '') -ErrorAction Stop -Verbose:$false |
                Select-Object -First 1
            if ($ip) { $info.InterfaceAlias = $ip.InterfaceAlias }
        }
        catch {
            Write-Verbose "Interface of $($info.Address) not found."
        }
        return $info
    }

    function Get-ServiceName {
        param([int]$Number, [string]$Kind)
        $tcp = @{
            20 = 'FTP data'; 21 = 'FTP'; 22 = 'SSH'; 23 = 'Telnet'; 25 = 'SMTP'; 53 = 'DNS'; 80 = 'HTTP'
            88 = 'Kerberos'; 102 = 'ISO-TSAP (S7)'; 110 = 'POP3'; 135 = 'RPC endpoint mapper'; 139 = 'NetBIOS session'
            143 = 'IMAP'; 389 = 'LDAP'; 443 = 'HTTPS'; 445 = 'SMB'; 464 = 'Kerberos password'; 465 = 'SMTPS'
            502 = 'Modbus TCP'; 515 = 'LPD'; 587 = 'SMTP submission'; 631 = 'IPP'; 636 = 'LDAPS'; 993 = 'IMAPS'
            995 = 'POP3S'; 1433 = 'SQL Server'; 1521 = 'Oracle'; 1883 = 'MQTT'; 2179 = 'Hyper-V VMConnect'
            3268 = 'Global Catalog'; 3269 = 'Global Catalog SSL'; 3306 = 'MySQL'; 3389 = 'RDP'; 5432 = 'PostgreSQL'
            5900 = 'VNC'; 5985 = 'WinRM HTTP'; 5986 = 'WinRM HTTPS'; 8080 = 'HTTP alternate'
            8443 = 'HTTPS alternate'; 8883 = 'MQTT TLS'; 9100 = 'Printer (RAW)'
        }
        $udp = @{
            53 = 'DNS'; 67 = 'DHCP server'; 68 = 'DHCP client'; 69 = 'TFTP'; 88 = 'Kerberos'; 123 = 'NTP'
            137 = 'NetBIOS name'; 138 = 'NetBIOS datagram'; 161 = 'SNMP'; 162 = 'SNMP trap'; 389 = 'CLDAP'
            500 = 'IKE'; 514 = 'Syslog'; 1812 = 'RADIUS'; 1813 = 'RADIUS accounting'; 1900 = 'SSDP'
            3389 = 'RDP (UDP)'; 4500 = 'IPsec NAT-T'; 5353 = 'mDNS'; 47808 = 'BACnet'
        }
        $table = if ($Kind -eq 'UDP') { $udp } else { $tcp }
        if ($table.ContainsKey($Number)) { return $table[$Number] }
        return ''
    }

    function Get-UdpProbe {
        # Returns a request the service on this port answers, or a generic one-byte datagram.
        param([int]$Number)
        switch ($Number) {
            53 {
                # DNS: standard query for the root NS records
                return @{ Name = 'DNS query'; Payload = [byte[]](0x50, 0x53, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                                               0x00, 0x00, 0x02, 0x00, 0x01) }
            }
            123 {
                # NTP: version 3 client request (48 bytes)
                $payload = New-Object byte[] 48
                $payload[0] = 0x1B
                return @{ Name = 'NTP request'; Payload = $payload }
            }
            137 {
                # NetBIOS: node status request for '*'
                $payload = New-Object System.Collections.Generic.List[byte]
                $payload.AddRange([byte[]](0x50, 0x54, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20))
                $payload.AddRange([System.Text.Encoding]::ASCII.GetBytes('CK' + ('A' * 30)))
                $payload.AddRange([byte[]](0x00, 0x00, 0x21, 0x00, 0x01))
                return @{ Name = 'NetBIOS status request'; Payload = $payload.ToArray() }
            }
            161 {
                # SNMP v2c GetRequest sysDescr.0, community 'public'
                return @{ Name = "SNMP request (community 'public')"; Payload = [byte[]](
                    0x30, 0x29, 0x02, 0x01, 0x01, 0x04, 0x06, 0x70, 0x75, 0x62, 0x6C, 0x69, 0x63,
                    0xA0, 0x1C, 0x02, 0x04, 0x50, 0x53, 0x54, 0x4C, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00,
                    0x30, 0x0E, 0x30, 0x0C, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00, 0x05, 0x00) }
            }
            default {
                return @{ Name = 'generic probe'; Payload = [byte[]](0x00) }
            }
        }
    }

    function Get-SocketError {
        # Unwraps PowerShell/.NET wrapper exceptions down to the SocketException (or the innermost one).
        param($Exception)
        $current = $Exception
        while ($current) {
            if ($current -is [System.Net.Sockets.SocketException]) { return $current }
            $current = $current.InnerException
        }
        return $Exception
    }

    function Test-Tcp {
        param([System.Net.IPAddress]$Address, [int]$Number)
        $client = New-Object System.Net.Sockets.TcpClient($Address.AddressFamily)
        $watch  = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $async = $client.BeginConnect($Address, $Number, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                $detail = "No answer within $TimeoutMs ms: a firewall drops the packets, or the host is offline."
                if ($TimeoutMs -lt 2500) {
                    $detail += ' Windows needs about 2 s to report a refused connection; use a timeout of at least 2500 ms to tell Closed from Filtered.'
                }
                return @{ State = 'Filtered'; Time = $null; Detail = $detail }
            }
            try {
                $client.EndConnect($async)
                return @{ State = 'Open'; Time = $watch.ElapsedMilliseconds; Detail = 'Connection established.' }
            }
            catch {
                $err = Get-SocketError $_.Exception
                if ($err -is [System.Net.Sockets.SocketException]) {
                    switch ([string]$err.SocketErrorCode) {
                        'ConnectionRefused' {
                            return @{ State = 'Closed'; Time = $watch.ElapsedMilliseconds
                                      Detail = 'Connection refused (TCP reset): the host is reachable, but nothing listens on this port.' }
                        }
                        'TimedOut' {
                            return @{ State = 'Filtered'; Time = $null; Detail = 'Connection attempt timed out: a firewall drops the packets, or the host is offline.' }
                        }
                        { $_ -in 'HostUnreachable', 'NetworkUnreachable', 'HostDown' } {
                            return @{ State = 'Unreachable'; Time = $null; Detail = "$($err.SocketErrorCode): $($err.Message)" }
                        }
                        'AccessDenied' {
                            return @{ State = 'Blocked'; Time = $null
                                      Detail = 'Windows blocked the connection attempt on this PC (access denied), e.g. a local firewall rule or security software.' }
                        }
                    }
                }
                return @{ State = 'Error'; Time = $null; Detail = $err.Message }
            }
        }
        finally {
            $client.Close()
        }
    }

    function Test-Udp {
        param([System.Net.IPAddress]$Address, [int]$Number)
        $probe  = Get-UdpProbe -Number $Number
        $client = New-Object System.Net.Sockets.UdpClient($Address.AddressFamily)
        $client.Client.ReceiveTimeout = $TimeoutMs
        $watch  = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            try {
                $client.Connect($Address, $Number)
                [void]$client.Send($probe.Payload, $probe.Payload.Length)
                $remote = New-Object System.Net.IPEndPoint($Address, 0)
                $data   = $client.Receive([ref]$remote)
                return @{ State = 'Open'; Time = $watch.ElapsedMilliseconds
                          Detail = ('Response of {0} bytes to the {1}.' -f $data.Length, $probe.Name) }
            }
            catch {
                $err = Get-SocketError $_.Exception
                if ($err -is [System.Net.Sockets.SocketException]) {
                    switch ([string]$err.SocketErrorCode) {
                        'ConnectionReset' {
                            return @{ State = 'Closed'; Time = $watch.ElapsedMilliseconds
                                      Detail = 'ICMP port unreachable: the host is reachable, but nothing listens on this port.' }
                        }
                        'TimedOut' {
                            if ($probe.Name -eq 'generic probe') {
                                $detail = "No answer within $TimeoutMs ms. UDP has no handshake: the service may listen and ignore the probe, or a firewall drops the packets."
                            }
                            else {
                                $detail = "No answer to the $($probe.Name) within $TimeoutMs ms: no such service, or a firewall drops the packets."
                            }
                            return @{ State = 'Open|Filtered'; Time = $null; Detail = $detail }
                        }
                        { $_ -in 'HostUnreachable', 'NetworkUnreachable', 'HostDown' } {
                            return @{ State = 'Unreachable'; Time = $null; Detail = "$($err.SocketErrorCode): $($err.Message)" }
                        }
                        'AccessDenied' {
                            return @{ State = 'Blocked'; Time = $null
                                      Detail = 'Windows blocked the connection attempt on this PC (access denied), e.g. a local firewall rule or security software.' }
                        }
                    }
                }
                return @{ State = 'Error'; Time = $null; Detail = $err.Message }
            }
        }
        finally {
            $client.Close()
        }
    }

    #endregion

    $address = Resolve-Target -Name $ComputerName
    $source  = Get-SourceInfo -Address $address
    Write-Verbose ("Target {0} ({1}), source {2} via '{3}', timeout {4} ms." -f $ComputerName, $address, $source.Address, $source.InterfaceAlias, $TimeoutMs)

    $ports     = @($Port | Sort-Object -Unique)
    $protocols = @('TCP', 'UDP' | Where-Object { $Protocol -contains $_ })
    $total     = $ports.Count * $protocols.Count
    $done      = 0

    foreach ($kind in $protocols) {
        foreach ($number in $ports) {
            if ($total -gt 1) {
                Write-Progress -Activity "Checking $ComputerName" -Status ('{0} port {1} ({2} of {3})' -f $kind, $number, ($done + 1), $total) `
                    -PercentComplete ([int](100 * $done / $total))
            }

            $result = if ($kind -eq 'TCP') { Test-Tcp -Address $address -Number $number } else { Test-Udp -Address $address -Number $number }
            $done++

            [pscustomobject]@{
                PSTypeName     = 'PSTools.PortCheckResult'
                Timestamp      = Get-Date
                ComputerName   = $ComputerName
                RemoteAddress  = $address.ToString()
                Port           = $number
                Protocol       = $kind
                Service        = Get-ServiceName -Number $number -Kind $kind
                State          = $result.State
                ResponseTimeMs = $result.Time
                SourceAddress  = $source.Address
                InterfaceAlias = $source.InterfaceAlias
                Detail         = $result.Detail
            }
        }
    }
    if ($total -gt 1) { Write-Progress -Activity "Checking $ComputerName" -Completed }
}
