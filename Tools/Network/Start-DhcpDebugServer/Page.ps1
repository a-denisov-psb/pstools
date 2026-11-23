#Requires -Version 5.1
# GUI page of the tool "DHCP Server". Runs inside its own dynamic module (see CLAUDE.md):
# $script: variables are private to this page.

$ResultColumns    = @('Time', 'State', 'IPAddress', 'MacAddress', 'HostName', 'Vendor', 'VendorClass', 'LeaseExpires', 'Message')
$FirewallRuleName = 'PSTools DHCP Server'

function Initialize-ToolPage {
    <#
    .SYNOPSIS
    Builds the page and wires up all events. Returns the root element.
    #>
    param([Parameter(Mandatory)]$Context)

    $script:Context = $Context
    $view = ConvertFrom-PSToolsXaml -Path (Join-Path $Context.ToolRoot 'Page.xaml')
    $script:Ui      = $view.Controls
    $script:Results = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $script:Job     = $null
    $ui = $script:Ui

    # Defaults
    $ui.dgResults.ItemsSource = $script:Results
    foreach ($value in '255.255.255.0', '255.255.0.0', '255.255.255.128', '255.0.0.0') { [void]$ui.cmbMask.Items.Add($value) }
    foreach ($value in '60', '300', '3600', '86400') { [void]$ui.cmbLease.Items.Add($value) }
    $ui.cmbLease.Text            = '3600'
    $ui.chkServerCheck.IsChecked = $true
    $ui.chkVendor.IsChecked      = $true

    if (-not $Context.IsAdmin) {
        foreach ($button in $ui.btnSetAddress, $ui.btnAddFirewallRule) {
            $button.IsEnabled = $false
            $button.ToolTip   = 'Requires administrator rights (status bar: "Restart as administrator")'
            [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($button, $true)
        }
    }

    # Events
    $ui.btnRefresh.Add_Click({ Invoke-PSToolsUiAction { Update-AdapterList; Update-FirewallNotice } })
    $ui.chkShowAll.Add_Click({ Invoke-PSToolsUiAction { Update-AdapterList } })
    $ui.cmbAdapter.Add_SelectionChanged({ Invoke-PSToolsUiAction { Update-ServerAddressList } })
    $ui.cmbServerAddress.Add_SelectionChanged({ Invoke-PSToolsUiAction { Update-AddressDefaults; Update-AddressNotice } })
    $ui.btnStart.Add_Click({ Invoke-PSToolsUiAction { Start-Server } })
    $ui.btnCancel.Add_Click({ Invoke-PSToolsUiAction { Stop-Server } })
    $ui.btnCopyAddressCommand.Add_Click({ Invoke-PSToolsUiAction { [System.Windows.Clipboard]::SetText($script:Ui.txtAddressCommand.Text) } })
    $ui.btnCopyFirewallCommand.Add_Click({ Invoke-PSToolsUiAction { [System.Windows.Clipboard]::SetText($script:Ui.txtFirewallCommand.Text) } })
    $ui.btnSetAddress.Add_Click({ Invoke-PSToolsUiAction { Set-StaticAddressOnAdapter } })
    $ui.btnAddFirewallRule.Add_Click({ Invoke-PSToolsUiAction { Add-DhcpFirewallRule } })

    $ui.dgResults.Add_SelectionChanged({
        $item = $script:Ui.dgResults.SelectedItem
        $hasAddress = ($null -ne $item) -and [bool]$item.IPAddress
        $script:Ui.btnOpenWeb.IsEnabled = $hasAddress
        $script:Ui.btnPing.IsEnabled    = $hasAddress
    })
    $ui.btnCopy.Add_Click({ Invoke-PSToolsUiAction { Copy-PSToolsGridSelection -Grid $script:Ui.dgResults -Property $ResultColumns } })
    $ui.btnExport.Add_Click({
        Invoke-PSToolsUiAction {
            $fileName = 'DhcpLeases_{0:yyyyMMdd_HHmmss}.csv' -f (Get-Date)
            Export-PSToolsGridCsv -Grid $script:Ui.dgResults -Property $ResultColumns -DefaultFileName $fileName
        }
    })
    $ui.btnOpenWeb.Add_Click({
        Invoke-PSToolsUiAction {
            $item = $script:Ui.dgResults.SelectedItem
            if ($item -and $item.IPAddress) { Start-Process -FilePath ('http://{0}/' -f $item.IPAddress) }
        }
    })
    $ui.btnPing.Add_Click({
        Invoke-PSToolsUiAction {
            $item = $script:Ui.dgResults.SelectedItem
            if ($item -and $item.IPAddress) {
                Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/k ping -t {0}' -f $item.IPAddress)
            }
        }
    })
    $ui.btnClear.Add_Click({ Invoke-PSToolsUiAction { $script:Results.Clear() } })

    Update-AdapterList
    Update-FirewallNotice
    return $view.Root
}

#region Adapter and server address

function Update-AdapterList {
    # Fills the adapter list; keeps the previous selection if the adapter still exists.
    $ui = $script:Ui
    $previousIndex = $null
    if ($ui.cmbAdapter.SelectedItem) { $previousIndex = $ui.cmbAdapter.SelectedItem.InterfaceIndex }

    # Virtual adapters are included: physical NICs bound to a Hyper-V external switch carry their address on 'vEthernet (...)'.
    $showAll  = [bool]$ui.chkShowAll.IsChecked
    $adapters = @(Get-PSToolsNetworkAdapter -IncludeVirtual -IncludeDisconnected:$showAll)
    $origins  = @{}
    foreach ($ip in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue -Verbose:$false) {
        $origins[[string]$ip.InterfaceIndex] += @([string]$ip.PrefixOrigin)
    }

    $ui.cmbAdapter.ItemsSource = $adapters
    $selected = $adapters | Where-Object { $_.InterfaceIndex -eq $previousIndex } | Select-Object -First 1
    if (-not $selected) {
        # Suggest the most likely adapter: static address > APIPA > none > DHCP; host-only switches last.
        $selected = $adapters | Sort-Object -Property @{ Expression = {
            $list  = @($origins[[string]$_.InterfaceIndex])
            $score = if ($list -contains 'Manual') { 0 } elseif ($list -contains 'WellKnown') { 1 } elseif (-not $list.Count) { 2 } else { 3 }
            if ($_.IsVirtual) { $score += 0.5 }
            if ($_.InterfaceAlias -match 'Default Switch|WSL|VMnet|Host-Only') { $score += 4 }
            $score } } | Select-Object -First 1
    }
    $ui.cmbAdapter.SelectedItem = $selected

    Add-LogLine ('Adapter list refreshed: {0} adapter(s).' -f $adapters.Count)
    Update-ServerAddressList
}

function Update-ServerAddressList {
    # Lists the IPv4 addresses of the selected adapter; keeps the previous selection if it still exists.
    $ui = $script:Ui
    $adapter = $ui.cmbAdapter.SelectedItem
    $previousAddress = $null
    if ($ui.cmbServerAddress.SelectedItem) { $previousAddress = $ui.cmbServerAddress.SelectedItem.IPAddress }

    $items = @()
    if ($adapter) {
        $items = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue -Verbose:$false |
            ForEach-Object {
                $origin = [string]$_.PrefixOrigin
                $originText = switch ($origin) { 'Manual' { 'static' } 'Dhcp' { 'from DHCP' } 'WellKnown' { 'APIPA' } default { $origin } }
                [pscustomobject]@{
                    IPAddress    = [string]$_.IPAddress
                    PrefixLength = [int]$_.PrefixLength
                    PrefixOrigin = $origin
                    DisplayName  = '{0}/{1}  ({2})' -f $_.IPAddress, $_.PrefixLength, $originText
                }
            } | Sort-Object -Property @{ Expression = { switch ($_.PrefixOrigin) { 'Manual' { 0 } 'Dhcp' { 2 } default { 1 } } } })
    }

    $ui.cmbServerAddress.ItemsSource = $items
    $selected = $items | Where-Object { $_.IPAddress -eq $previousAddress } | Select-Object -First 1
    if (-not $selected) { $selected = $items | Select-Object -First 1 }
    $ui.cmbServerAddress.SelectedItem = $selected
    if (-not $selected) { Update-AddressNotice }   # SelectionChanged does not fire when the list stays empty
}

function Update-AddressDefaults {
    # Suggests pool and subnet mask for the selected server address (.100 - .199 of its /24).
    $ui = $script:Ui
    $address = $ui.cmbServerAddress.SelectedItem
    if (-not $address) { return }

    $prefix  = $address.PrefixLength
    $server  = ConvertTo-PSToolsIPv4Number $address.IPAddress
    $mask    = ([long]4294967295 -shl (32 - $prefix)) -band [long]4294967295
    $network = $server -band $mask
    if ($prefix -le 24) {
        $base  = $server -band [long]4294967040
        $first = $base + 100
        $last  = $base + 199
    }
    else {
        $first = $network + 1
        $last  = $network + ([long]4294967295 -bxor $mask) - 1
    }
    $ui.txtPoolStart.Text = ConvertFrom-PSToolsIPv4Number $first
    $ui.txtPoolEnd.Text   = ConvertFrom-PSToolsIPv4Number $last
    $ui.cmbMask.Text      = ConvertFrom-PSToolsIPv4Number $mask
}

function Update-AddressNotice {
    # Shows the notice bar when the adapter has no static address.
    $ui = $script:Ui
    $adapter = $ui.cmbAdapter.SelectedItem
    $address = $ui.cmbServerAddress.SelectedItem
    $alias   = if ($adapter) { $adapter.InterfaceAlias } else { '<Name>' }
    $revert  = Get-PSToolsStaticAddressCommand -InterfaceAlias $alias -Dhcp

    $text = $null
    if (-not $adapter) {
        $text = 'No network adapter found. Connect the cable or plug in the USB network adapter, then click ' + [char]0x27F3 + '.'
    }
    elseif (-not $address) {
        $text = "Adapter '$alias' has no IPv4 address. Give it a static address in the network of the device (as administrator)."
    }
    elseif ($address.PrefixOrigin -eq 'Dhcp') {
        $text = ("Adapter '{0}' got its address {1} from a DHCP server, so there is already a DHCP server on this network and " +
                 "the DHCP Server will not start here. Use a separate network (e.g. a direct cable to the device) with a static address.") -f
                $alias, $address.IPAddress
    }
    elseif ($address.PrefixOrigin -eq 'WellKnown') {
        $text = ("Adapter '{0}' only has the APIPA address {1}. That works, but Windows may change it at any time; " +
                 "a static address is recommended.") -f $alias, $address.IPAddress
    }

    if (-not $text) {
        $ui.bdrAddress.Visibility = 'Collapsed'
        return
    }
    if ($adapter) { $text += "`r`nSwitch the adapter back to DHCP later with: $revert" }
    $ui.txtAddressNotice.Text  = $text
    $ui.txtAddressCommand.Text = Get-PSToolsStaticAddressCommand -InterfaceAlias $alias
    if ($script:Context.IsAdmin) { $ui.btnSetAddress.IsEnabled = [bool]$adapter -and -not (Test-ServerRunning) }
    $ui.bdrAddress.Visibility = 'Visible'
}

function Set-StaticAddressOnAdapter {
    # Sets 192.168.100.1/24 on the selected adapter (admin only).
    $adapter = $script:Ui.cmbAdapter.SelectedItem
    if (-not $adapter) { return }

    $command = Get-PSToolsStaticAddressCommand -InterfaceAlias $adapter.InterfaceAlias
    $revert  = Get-PSToolsStaticAddressCommand -InterfaceAlias $adapter.InterfaceAlias -Dhcp
    $answer = Show-PSToolsMessage -Kind Question -Buttons YesNo -Message (
        "Set the static address 192.168.100.1/24 on '$($adapter.InterfaceAlias)'?`r`n`r`n$command`r`n`r`n" +
        "DHCP is switched off for this adapter. Switch it back later with:`r`n$revert")
    if ($answer -ne 'Yes') { return }

    $output = Set-PSToolsStaticAddress -InterfaceAlias $adapter.InterfaceAlias -Confirm:$false
    Add-LogLine "Set 192.168.100.1/24 on '$($adapter.InterfaceAlias)'. $output"
    Add-LogLine "If the address does not show up yet, click $([char]0x27F3) in a few seconds. Back to DHCP: $revert"
    Update-AdapterList
}

#endregion

#region Firewall

function Update-FirewallNotice {
    # Shows the notice bar when the Windows Firewall probably blocks inbound UDP port 67.
    $ui = $script:Ui
    try {
        $open = Test-PSToolsFirewallPortOpen -Protocol UDP -LocalPort 67
    }
    catch {
        Add-LogLine "Firewall check failed: $($_.Exception.Message)"
        $ui.bdrFirewall.Visibility = 'Collapsed'
        return
    }
    if ($open) {
        $ui.bdrFirewall.Visibility = 'Collapsed'
        return
    }
    $ui.txtFirewallNotice.Text = ("The Windows Firewall blocks incoming DHCP requests (UDP port 67), so clients cannot reach the server. " +
                                  "Add an inbound rule (as administrator). Remove it later with: Remove-NetFirewallRule -DisplayName '{0}'") -f $FirewallRuleName
    $ui.txtFirewallCommand.Text = Get-PSToolsFirewallRuleCommand -DisplayName $FirewallRuleName -Protocol UDP -LocalPort 67
    $ui.bdrFirewall.Visibility = 'Visible'
}

function Add-DhcpFirewallRule {
    $command = Get-PSToolsFirewallRuleCommand -DisplayName $FirewallRuleName -Protocol UDP -LocalPort 67
    $answer = Show-PSToolsMessage -Kind Question -Buttons YesNo -Message (
        "Add a Windows Firewall rule that allows incoming UDP port 67 (all profiles)?`r`n`r`n$command`r`n`r`n" +
        "Remove it later with:`r`nRemove-NetFirewallRule -DisplayName '$FirewallRuleName'")
    if ($answer -ne 'Yes') { return }

    Add-PSToolsFirewallRule -DisplayName $FirewallRuleName -Protocol UDP -LocalPort 67 -Confirm:$false
    Add-LogLine "Firewall rule '$FirewallRuleName' added (inbound UDP 67)."
    Update-FirewallNotice
}

#endregion

#region Server

function Test-ServerRunning {
    return ($script:Job -and -not $script:Job.IsFinished)
}

function Get-ValidatedAddress {
    # Returns the trimmed IPv4 address or throws a message that names the field.
    param([string]$Text, [string]$Label)
    $value = $Text.Trim()
    try { [void](ConvertTo-PSToolsIPv4Number $value) }
    catch { throw "${Label}: '$value' is not a valid IPv4 address." }
    return $value
}

function Start-Server {
    $ui = $script:Ui
    if (Test-ServerRunning) { return }

    $adapter = $ui.cmbAdapter.SelectedItem
    if (-not $adapter) { throw 'Select a network adapter first.' }
    $address = $ui.cmbServerAddress.SelectedItem
    if (-not $address) { throw "Adapter '$($adapter.InterfaceAlias)' has no IPv4 address. Give it a static address first." }
    if ($address.PrefixOrigin -eq 'Dhcp') {
        throw (("The address {0} was assigned by a DHCP server, so there is already a DHCP server on this network. " +
                "Use a separate network with a static address (see the notice at the top).") -f $address.IPAddress)
    }

    $parameters = @{
        InterfaceAlias   = $adapter.InterfaceAlias
        ServerAddress    = $address.IPAddress
        PoolStart        = Get-ValidatedAddress -Text $ui.txtPoolStart.Text -Label 'Pool start'
        PoolEnd          = Get-ValidatedAddress -Text $ui.txtPoolEnd.Text -Label 'Pool end'
        SubnetMask       = Get-ValidatedAddress -Text $ui.cmbMask.Text -Label 'Subnet mask'
        SkipServerCheck  = -not $ui.chkServerCheck.IsChecked
        SkipVendorLookup = -not $ui.chkVendor.IsChecked
    }

    $lease = 0
    if (-not [int]::TryParse($ui.cmbLease.Text.Trim(), [ref]$lease) -or $lease -lt 60 -or $lease -gt 2592000) {
        throw 'The lease time must be a number between 60 and 2592000 seconds.'
    }
    $parameters.LeaseTimeSeconds = $lease

    if ($ui.txtRouter.Text.Trim()) { $parameters.Router = Get-ValidatedAddress -Text $ui.txtRouter.Text -Label 'Gateway' }
    $dns = @($ui.txtDns.Text -split '[,;\s]+' | Where-Object { $_ })
    if ($dns.Count) { $parameters.DnsServer = [string[]]@($dns | ForEach-Object { Get-ValidatedAddress -Text $_ -Label 'DNS servers' }) }
    if ($ui.txtDomain.Text.Trim()) { $parameters.DomainName = $ui.txtDomain.Text.Trim() }

    $script:Results.Clear()
    $ui.pbProgress.IsIndeterminate = $true
    $ui.txtStatus.Text = 'Starting…'
    Set-BusyState -Busy $true
    Add-LogLine ("Starting DHCP server on '{0}' ({1}), pool {2} - {3}, lease {4} s." -f
                 $adapter.InterfaceAlias, $address.IPAddress, $parameters.PoolStart, $parameters.PoolEnd, $lease)

    $script:Job = Start-PSToolsJob -ScriptFile $script:Context.Tool.LogicFile -Command $script:Context.Tool.Command `
        -Parameters $parameters `
        -OnOutput {
            param($item)
            # One row per client: replace the existing row of this MAC address.
            $replaced = $false
            for ($i = 0; $i -lt $script:Results.Count; $i++) {
                if ($script:Results[$i].MacAddress -eq $item.MacAddress) {
                    $script:Results[$i] = $item
                    $replaced = $true
                    break
                }
            }
            if (-not $replaced) { $script:Results.Add($item) }
            $line = '{0,-12} {1,-15} {2}' -f $item.State, $item.IPAddress, $item.MacAddress
            if ($item.HostName) { $line += "  '$($item.HostName)'" }
            if ($item.Vendor) { $line += "  $($item.Vendor)" }
            if ($item.Message) { $line += "  – $($item.Message)" }
            Add-LogLine $line
        } `
        -OnProgress {
            param($record)
            if ([string]$record.RecordType -eq 'Completed') { return }
            $script:Ui.txtStatus.Text = $record.StatusDescription
        } `
        -OnMessage {
            param($kind, $text)
            Add-LogLine ('[{0}] {1}' -f $kind, $text)
            if ($kind -in 'Warning', 'Error') { $script:Ui.expLog.IsExpanded = $true }
        } `
        -OnCompleted {
            param($result)
            Complete-Server -Result $result
        }
}

function Stop-Server {
    if (Test-ServerRunning) {
        $script:Ui.txtStatus.Text = 'Stopping…'
        $script:Ui.btnCancel.IsEnabled = $false
        Stop-PSToolsJob -Job $script:Job
    }
}

function Complete-Server {
    param($Result)

    $ui = $script:Ui
    $ui.pbProgress.IsIndeterminate = $false
    $ui.pbProgress.Value = 0
    Set-BusyState -Busy $false
    $duration = '{0:hh\:mm\:ss}' -f $Result.Duration

    switch ($Result.State) {
        'Stopped' { $ui.txtStatus.Text = "Server stopped after $duration – $($script:Results.Count) client(s) seen." }
        'Completed' { $ui.txtStatus.Text = "Server ended after $duration." }
        default {
            $ui.txtStatus.Text = "Failed: $($Result.Error)"
            $ui.expLog.IsExpanded = $true
        }
    }
    Add-LogLine $ui.txtStatus.Text
}

function Set-BusyState {
    param([bool]$Busy)

    $ui = $script:Ui
    foreach ($name in 'cmbAdapter', 'btnRefresh', 'chkShowAll', 'cmbServerAddress', 'chkServerCheck', 'chkVendor',
                      'txtPoolStart', 'txtPoolEnd', 'cmbMask', 'cmbLease', 'txtRouter', 'txtDns', 'txtDomain', 'btnStart') {
        $ui[$name].IsEnabled = -not $Busy
    }
    $ui.btnCancel.IsEnabled = $Busy
    $ui.btnSetAddress.IsEnabled = (-not $Busy) -and $script:Context.IsAdmin -and [bool]$ui.cmbAdapter.SelectedItem
}

function Add-LogLine {
    param([string]$Text)
    $box = $script:Ui.txtLog
    $box.AppendText(('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine))
    $box.ScrollToEnd()
}

#endregion
