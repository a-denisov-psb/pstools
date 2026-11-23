#Requires -Version 5.1
# Logic of the tool "Find APIPA Device". Dot-source this file to use the function from the console:
#   . .\Tools\Network\Find-ApipaDevice\Find-ApipaDevice.ps1
#   Find-ApipaDevice -StopOnFirst

. (Join-Path $PSScriptRoot '..\..\..\Core\Core.ps1')

function Find-ApipaDevice {
    <#
    .SYNOPSIS
    Finds devices with an APIPA / link-local address (169.254.0.0/16) on a local network segment.

    .DESCRIPTION
    Devices without a DHCP server assign themselves a random address from 169.254.0.0/16. To find such a
    device, the PC needs an address in the same range on the adapter the device is connected to.

    The function
      1. selects the adapter (parameter, or automatically: connected physical adapter with a 169.254.x.x
         address; if there are several, you are asked to choose),
      2. sends asynchronous pings to the subnet, one block of BatchSize addresses at a time,
      3. evaluates the ARP cache of the adapter after every block. Windows resolves every target via ARP
         before pinging, so devices that block ICMP are found too,
      4. resolves the MAC address ('arp -a', fallback Get-NetNeighbor) and optionally the vendor (offline).

    Addresses that belong to this PC (e.g. VPN/TAP adapters with APIPA addresses) are skipped.
    A full /16 scan with 300 ms timeout takes about 2 minutes.

    If no adapter has an APIPA address, a warning with the netsh command to add one is shown:
        netsh interface ipv4 add address "<Name>" 169.254.1.1 255.255.0.0

    .PARAMETER InterfaceAlias
    Name of the network adapter (as in Get-NetAdapter). Default: connected physical adapter with a
    169.254.x.x address; when several qualify you are prompted to choose (console only).

    .PARAMETER Subnet
    Range to scan in CIDR notation, /16 to /32. Default: 169.254.0.0/16.

    .PARAMETER TimeoutMs
    Ping timeout per address in milliseconds (50-10000). Default: 300.

    .PARAMETER StopOnFirst
    Stop after the first block (BatchSize addresses) that contains at least one device.

    .PARAMETER SkipVendorLookup
    Do not resolve the vendor from the offline OUI table.

    .PARAMETER SkipArpDetection
    Only report devices that answer ping; ignore devices that only show up in the ARP cache.

    .PARAMETER BatchSize
    Number of parallel pings per block (16-1024). Default: 256.

    .OUTPUTS
    PSTools.ApipaDevice: IPAddress, MacAddress, Vendor, InterfaceAlias, InterfaceIndex, DetectedBy
    (ICMP or ARP), ResponseTimeMs.

    .EXAMPLE
    Find-ApipaDevice
    Scans 169.254.0.0/16 on the automatically selected adapter.

    .EXAMPLE
    Find-ApipaDevice -InterfaceAlias 'Ethernet 2' -StopOnFirst
    Scans via 'Ethernet 2' and stops as soon as a device was found.

    .EXAMPLE
    Find-ApipaDevice -Subnet 169.254.222.0/24 -TimeoutMs 500 | Format-Table
    Scans only one /24 with a longer timeout.

    .EXAMPLE
    arp -a | findstr 00-c0-eb-1c-73-81
    Not part of this function: APIPA addresses can change after a reboot; search the ARP cache for the
    known MAC address after a scan.

    .NOTES
    Alternatives: nmap -sn -n --min-rate 2000 169.254.0.0/16 (ARP scan) or Wireshark with the filter
    'arp || bootp || lldp' while the device reboots. Broadcast pings (x.x.255.255) are unreliable.
    #>
    [CmdletBinding()]
    [OutputType('PSTools.ApipaDevice')]
    param(
        [Parameter(Position = 0)]
        [string]$InterfaceAlias,

        [ValidateScript({
            $range = Get-PSToolsIPv4Range -Cidr $_
            if ($range.Prefix -lt 16) { throw 'Subnets larger than /16 are not supported.' }
            $true
        })]
        [string]$Subnet = '169.254.0.0/16',

        [ValidateRange(50, 10000)]
        [int]$TimeoutMs = 300,

        [switch]$StopOnFirst,

        [switch]$SkipVendorLookup,

        [switch]$SkipArpDetection,

        [ValidateRange(16, 1024)]
        [int]$BatchSize = 256
    )

    #region nested helpers
    function Select-AdapterInteractively {
        param([object[]]$Candidates)

        $canPrompt = [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost'
        if (-not $canPrompt) {
            $names = ($Candidates | ForEach-Object { "'$($_.InterfaceAlias)'" }) -join ', '
            throw "Several adapters have an APIPA address ($names). Specify one with -InterfaceAlias."
        }
        Write-Host 'Several adapters have an APIPA address:'
        for ($i = 0; $i -lt $Candidates.Count; $i++) {
            Write-Host ('  [{0}] {1}' -f ($i + 1), $Candidates[$i].DisplayName)
        }
        while ($true) {
            $answer = Read-Host "Select adapter (1-$($Candidates.Count), empty = cancel)"
            if (-not $answer) { throw 'Cancelled by user.' }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Candidates.Count) {
                return $Candidates[$number - 1]
            }
        }
    }

    function New-DeviceResult {
        param([string]$IPAddress, [string]$MacAddress, [string]$DetectedBy, $ResponseTimeMs)

        $vendor = $null
        if ($MacAddress -and -not $SkipVendorLookup) { $vendor = Resolve-PSToolsMacVendor -MacAddress $MacAddress }
        $result = [pscustomobject]@{
            PSTypeName     = 'PSTools.ApipaDevice'
            IPAddress      = $IPAddress
            MacAddress     = $MacAddress
            Vendor         = $vendor
            InterfaceAlias = $adapter.InterfaceAlias
            InterfaceIndex = $adapter.InterfaceIndex
            DetectedBy     = $DetectedBy
            ResponseTimeMs = $ResponseTimeMs
        }
        $defaultView = New-Object System.Management.Automation.PSPropertySet('DefaultDisplayPropertySet',
            [string[]]@('IPAddress', 'MacAddress', 'Vendor', 'InterfaceAlias', 'DetectedBy', 'ResponseTimeMs'))
        $result | Add-Member -MemberType MemberSet -Name PSStandardMembers `
            -Value ([System.Management.Automation.PSMemberInfo[]]@($defaultView)) -Force
        return $result
    }
    #endregion

    $range = Get-PSToolsIPv4Range -Cidr $Subnet
    $isApipaRange = Test-PSToolsApipaAddress (ConvertFrom-PSToolsIPv4Number $range.Network)

    # 1. Select adapter
    if ($InterfaceAlias) {
        $adapter = Get-PSToolsNetworkAdapter -IncludeVirtual -IncludeDisconnected |
            Where-Object { $_.InterfaceAlias -eq $InterfaceAlias } | Select-Object -First 1
        if (-not $adapter) { throw "Network adapter '$InterfaceAlias' was not found." }
        if ($adapter.Status -ne 'Up') {
            Write-Warning "Adapter '$InterfaceAlias' is not connected (status: $($adapter.Status))."
        }
        if ($isApipaRange -and -not $adapter.ApipaAddress) {
            Write-Warning (Get-PSToolsApipaHint -InterfaceAlias $InterfaceAlias)
        }
    }
    else {
        $candidates = @(Get-PSToolsNetworkAdapter -ApipaOnly)
        if ($candidates.Count -eq 0) {
            Write-Warning (Get-PSToolsApipaHint)
            return
        }
        if ($candidates.Count -eq 1) { $adapter = $candidates[0] }
        else { $adapter = Select-AdapterInteractively -Candidates $candidates }
    }
    Write-Verbose ("Adapter: {0} (index {1}), IPv4: {2}" -f $adapter.InterfaceAlias, $adapter.InterfaceIndex, ($adapter.IPv4Address -join ', '))

    # Warn if the routing table sends the traffic out through another adapter (e.g. several adapters with APIPA addresses).
    try {
        $route = Find-NetRoute -RemoteIPAddress (ConvertFrom-PSToolsIPv4Number $range.First) -ErrorAction Stop -Verbose:$false | Select-Object -First 1
        if ($route -and $route.InterfaceIndex -ne $adapter.InterfaceIndex) {
            $routeAlias = (Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue -Verbose:$false).Name
            Write-Warning (("Traffic to {0} is routed via '{1}', not via '{2}'. Pings leave through '{1}'; only the ARP cache of '{2}' is evaluated. " +
                            "Disable the other adapter or lower the interface metric of '{2}' if no device is found.") -f $range.Cidr, $routeAlias, $adapter.InterfaceAlias)
        }
    }
    catch {
        Write-Warning "No route to $($range.Cidr) found. Pings will fail; only the ARP cache is evaluated."
    }

    # Own addresses of this PC must not be reported as devices.
    $ownAddresses = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($ip in (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue -Verbose:$false).IPAddress) { [void]$ownAddresses.Add($ip) }

    # 2./3. Sweep block by block
    $reported     = New-Object 'System.Collections.Generic.HashSet[string]'
    $batchCount   = [int][Math]::Ceiling($range.Count / $BatchSize)
    $activity     = "Scanning $($range.Cidr) via '$($adapter.InterfaceAlias)'"
    $stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()
    $stoppedEarly = $false
    $deviceCount  = 0

    for ($batch = 0; $batch -lt $batchCount; $batch++) {
        $blockStart = $range.First + [long]$batch * $BatchSize
        $blockEnd   = [Math]::Min($blockStart + $BatchSize - 1, $range.Last)

        $percent = [int](100 * $batch / $batchCount)
        $status  = '{0} - {1}  |  block {2}/{3}  |  {4} device(s) found' -f (ConvertFrom-PSToolsIPv4Number $blockStart),
                   (ConvertFrom-PSToolsIPv4Number $blockEnd), ($batch + 1), $batchCount, $deviceCount
        Write-Progress -Activity $activity -Status $status -PercentComplete $percent

        $addresses = New-Object System.Collections.Generic.List[string]
        $pings     = New-Object System.Collections.Generic.List[System.Net.NetworkInformation.Ping]
        $tasks     = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
        for ($n = $blockStart; $n -le $blockEnd; $n++) {
            $ip = '{0}.{1}.{2}.{3}' -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255)
            if ($ownAddresses.Contains($ip)) { continue }
            $ping = New-Object System.Net.NetworkInformation.Ping
            try {
                $tasks.Add($ping.SendPingAsync($ip, $TimeoutMs))
                $addresses.Add($ip)
                $pings.Add($ping)
            }
            catch {
                $ping.Dispose()
                Write-Verbose "Ping to $ip could not be sent: $($_.Exception.Message)"
            }
        }

        if ($tasks.Count) {
            try { [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray()) } catch { }  # failed pings are expected
        }

        $hits = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $tasks.Count; $i++) {
            $task = $tasks[$i]
            if ($task.Status -eq 'RanToCompletion' -and $task.Result.Status -eq 'Success') {
                $hits.Add([pscustomobject]@{ IPAddress = $addresses[$i]; RoundTrip = $task.Result.RoundtripTime })
            }
            $pings[$i].Dispose()
        }

        $arpTable = $null
        if ($hits.Count -or -not $SkipArpDetection) {
            $arpTable = @(Get-PSToolsArpTable -InterfaceIndex $adapter.InterfaceIndex)
        }

        foreach ($hit in $hits) {
            if (-not $reported.Add($hit.IPAddress)) { continue }
            $mac = Get-PSToolsNeighborMac -IPAddress $hit.IPAddress -InterfaceIndex $adapter.InterfaceIndex -ArpTable $arpTable
            $deviceCount++
            New-DeviceResult -IPAddress $hit.IPAddress -MacAddress $mac -DetectedBy 'ICMP' -ResponseTimeMs $hit.RoundTrip
        }

        if (-not $SkipArpDetection) {
            foreach ($entry in $arpTable) {
                $number = ConvertTo-PSToolsIPv4Number $entry.IPAddress
                if ($number -lt $blockStart -or $number -gt $blockEnd) { continue }
                if ($ownAddresses.Contains($entry.IPAddress)) { continue }
                if (-not $reported.Add($entry.IPAddress)) { continue }
                $deviceCount++
                New-DeviceResult -IPAddress $entry.IPAddress -MacAddress $entry.MacAddress -DetectedBy 'ARP' -ResponseTimeMs $null
            }
        }

        if ($StopOnFirst -and $deviceCount -gt 0) {
            $stoppedEarly = ($batch -lt $batchCount - 1)
            break
        }
    }

    # Final pass: Get-NetNeighbor may know entries that 'arp -a' did not show during the sweep.
    if (-not $SkipArpDetection -and -not ($StopOnFirst -and $deviceCount -gt 0)) {
        foreach ($entry in Get-PSToolsNeighbor -InterfaceIndex $adapter.InterfaceIndex) {
            $number = ConvertTo-PSToolsIPv4Number $entry.IPAddress
            if ($number -lt $range.First -or $number -gt $range.Last) { continue }
            if ($ownAddresses.Contains($entry.IPAddress)) { continue }
            if (-not $reported.Add($entry.IPAddress)) { continue }
            $deviceCount++
            New-DeviceResult -IPAddress $entry.IPAddress -MacAddress $entry.MacAddress -DetectedBy 'ARP' -ResponseTimeMs $null
        }
    }

    Write-Progress -Activity $activity -Completed
    $stopwatch.Stop()

    $summary = '{0} device(s) found in {1:mm\:ss}.' -f $deviceCount, $stopwatch.Elapsed
    if ($stoppedEarly) { $summary += ' Scan stopped after the first hit (StopOnFirst).' }
    Write-Verbose $summary

    if ($deviceCount -eq 0) {
        Write-Warning (("No device found in {0} via '{1}'. Check the cable/link, wait until the device has booted " +
                        "(APIPA assignment can take a minute), or try a longer timeout.") -f $range.Cidr, $adapter.InterfaceAlias)
    }
}
