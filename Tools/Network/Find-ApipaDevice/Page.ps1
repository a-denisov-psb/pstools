#Requires -Version 5.1
# GUI page of the tool "Find APIPA Device". Runs inside its own dynamic module (see CLAUDE.md):
# $script: variables are private to this page.

$ResultColumns = @('IPAddress', 'MacAddress', 'Vendor', 'InterfaceAlias', 'DetectedBy', 'ResponseTimeMs')

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
    $ui.cmbSubnet.Text = '169.254.0.0/16'
    foreach ($value in '100', '200', '300', '500', '1000', '2000') { [void]$ui.cmbTimeout.Items.Add($value) }
    $ui.cmbTimeout.Text    = '300'
    $ui.chkArp.IsChecked    = $true
    $ui.chkVendor.IsChecked = $true

    if (-not $Context.IsAdmin) {
        $ui.btnAssignApipa.IsEnabled = $false
        $ui.btnAssignApipa.ToolTip   = 'Requires administrator rights (status bar: "Restart as administrator")'
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($ui.btnAssignApipa, $true)
    }

    # Events
    $ui.btnRefresh.Add_Click({ Invoke-PSToolsUiAction { Update-AdapterList } })
    $ui.chkShowAll.Add_Click({ Invoke-PSToolsUiAction { Update-AdapterList } })
    $ui.cmbAdapter.Add_SelectionChanged({ Invoke-PSToolsUiAction { Update-AdapterDependentUi } })
    $ui.btnStart.Add_Click({ Invoke-PSToolsUiAction { Start-Scan } })
    $ui.btnCancel.Add_Click({ Invoke-PSToolsUiAction { Stop-Scan } })
    $ui.btnCopyCommand.Add_Click({ Invoke-PSToolsUiAction { [System.Windows.Clipboard]::SetText($script:Ui.txtNoticeCommand.Text) } })
    $ui.btnAssignApipa.Add_Click({ Invoke-PSToolsUiAction { Add-ApipaAddressToAdapter } })

    $ui.dgResults.Add_SelectionChanged({
        $hasSelection = $null -ne $script:Ui.dgResults.SelectedItem
        $script:Ui.btnOpenWeb.IsEnabled = $hasSelection
        $script:Ui.btnPing.IsEnabled    = $hasSelection
    })
    $ui.btnCopy.Add_Click({ Invoke-PSToolsUiAction { Copy-PSToolsGridSelection -Grid $script:Ui.dgResults -Property $ResultColumns } })
    $ui.btnExport.Add_Click({
        Invoke-PSToolsUiAction {
            $fileName = 'ApipaDevices_{0:yyyyMMdd_HHmmss}.csv' -f (Get-Date)
            Export-PSToolsGridCsv -Grid $script:Ui.dgResults -Property $ResultColumns -DefaultFileName $fileName
        }
    })
    $ui.btnOpenWeb.Add_Click({
        Invoke-PSToolsUiAction {
            $device = $script:Ui.dgResults.SelectedItem
            if ($device) { Start-Process -FilePath ('http://{0}/' -f $device.IPAddress) }
        }
    })
    $ui.btnPing.Add_Click({
        Invoke-PSToolsUiAction {
            $device = $script:Ui.dgResults.SelectedItem
            if ($device) {
                Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/k ping -t {0}' -f $device.IPAddress)
            }
        }
    })
    $ui.btnClear.Add_Click({
        Invoke-PSToolsUiAction {
            $script:Results.Clear()
            $script:Ui.pbProgress.Value = 0
            $script:Ui.txtStatus.Text = 'Ready.'
        }
    })

    Update-AdapterList
    return $view.Root
}

#region Adapter selection and notice bar

function Update-AdapterList {
    # Fills the adapter list; keeps the previous selection if the adapter still exists.
    $ui = $script:Ui
    $previousIndex = $null
    if ($ui.cmbAdapter.SelectedItem) { $previousIndex = $ui.cmbAdapter.SelectedItem.InterfaceIndex }

    $showAll  = [bool]$ui.chkShowAll.IsChecked
    $adapters = @(Get-PSToolsNetworkAdapter -IncludeVirtual:$showAll -IncludeDisconnected:$showAll)
    $script:ApipaAdapters = @($adapters | Where-Object { $_.ApipaAddress -and $_.Status -eq 'Up' })

    $ui.cmbAdapter.ItemsSource = $adapters
    $selected = $adapters | Where-Object { $_.InterfaceIndex -eq $previousIndex } | Select-Object -First 1
    if (-not $selected) { $selected = $adapters | Where-Object { $_.ApipaAddress } | Select-Object -First 1 }
    if (-not $selected) { $selected = $adapters | Select-Object -First 1 }
    $ui.cmbAdapter.SelectedItem = $selected

    Add-LogLine ('Adapter list refreshed: {0} adapter(s), {1} with APIPA address.' -f $adapters.Count, $script:ApipaAdapters.Count)
    Update-AdapterDependentUi
}

function Update-AdapterDependentUi {
    # Updates subnet suggestions and the notice bar for the selected adapter.
    $ui = $script:Ui
    $adapter = $ui.cmbAdapter.SelectedItem

    # Subnet suggestions: whole APIPA range plus the adapter's own /24
    $currentSubnet = $ui.cmbSubnet.Text
    $ui.cmbSubnet.Items.Clear()
    [void]$ui.cmbSubnet.Items.Add('169.254.0.0/16')
    if ($adapter -and $adapter.ApipaAddress) {
        $octets = $adapter.ApipaAddress.Split('.')
        [void]$ui.cmbSubnet.Items.Add(('169.254.{0}.0/24' -f $octets[2]))
    }
    $ui.cmbSubnet.Text = $currentSubnet

    # Notice bar
    if (-not $adapter) {
        Show-Notice -Text ('No network adapter found. Connect the cable or plug in the USB network adapter, then click ' +
                           [char]0x27F3 + '. Enable "Show virtual … adapters" to see all adapters.') -AdapterAlias $null
    }
    elseif (-not $adapter.ApipaAddress) {
        $text = Get-PSToolsApipaHint -InterfaceAlias $adapter.InterfaceAlias -NoCommand
        $others = @($script:ApipaAdapters | Where-Object { $_.InterfaceIndex -ne $adapter.InterfaceIndex })
        if ($others.Count) {
            $text += "`r`nAdapters with an APIPA address: " + (($others | ForEach-Object { "$($_.InterfaceAlias) ($($_.ApipaAddress))" }) -join ', ')
        }
        Show-Notice -Text $text -AdapterAlias $adapter.InterfaceAlias
    }
    else {
        $ui.bdrNotice.Visibility = 'Collapsed'
    }
}

function Show-Notice {
    param([string]$Text, [string]$AdapterAlias)

    $ui = $script:Ui
    $ui.txtNotice.Text = $Text
    $alias = if ($AdapterAlias) { $AdapterAlias } else { '<Name>' }
    $ui.txtNoticeCommand.Text = Get-PSToolsApipaCommand -InterfaceAlias $alias
    if ($script:Context.IsAdmin) { $ui.btnAssignApipa.IsEnabled = [bool]$AdapterAlias }
    $ui.bdrNotice.Visibility = 'Visible'
}

function Add-ApipaAddressToAdapter {
    # Adds 169.254.1.1/16 to the selected adapter (admin only).
    $adapter = $script:Ui.cmbAdapter.SelectedItem
    if (-not $adapter) { return }

    $command = Get-PSToolsApipaCommand -InterfaceAlias $adapter.InterfaceAlias
    $answer = Show-PSToolsMessage -Kind Question -Buttons YesNo `
        -Message "Add the address 169.254.1.1/16 to '$($adapter.InterfaceAlias)'?`r`n`r`n$command`r`n`r`nExisting addresses and DHCP settings are kept."
    if ($answer -ne 'Yes') { return }

    $output = Add-PSToolsApipaAddress -InterfaceAlias $adapter.InterfaceAlias -Confirm:$false
    Add-LogLine "Added 169.254.1.1 to '$($adapter.InterfaceAlias)'. $output"
    Add-LogLine "If the address does not show up yet, click $([char]0x27F3) in a few seconds."
    Update-AdapterList
}

#endregion

#region Scan

function Start-Scan {
    $ui = $script:Ui
    if ($script:Job -and -not $script:Job.IsFinished) { return }

    $adapter = $ui.cmbAdapter.SelectedItem
    if (-not $adapter) { throw 'Select a network adapter first.' }

    $subnet = $ui.cmbSubnet.Text.Trim()
    $range  = Get-PSToolsIPv4Range -Cidr $subnet          # throws a readable message on invalid input
    if ($range.Prefix -lt 16) { throw 'Subnets larger than /16 are not supported.' }

    $timeout = 0
    if (-not [int]::TryParse($ui.cmbTimeout.Text.Trim(), [ref]$timeout) -or $timeout -lt 50 -or $timeout -gt 10000) {
        throw 'The timeout must be a number between 50 and 10000 ms.'
    }

    $parameters = @{
        InterfaceAlias   = $adapter.InterfaceAlias
        Subnet           = $range.Cidr
        TimeoutMs        = $timeout
        StopOnFirst      = [bool]$ui.chkStopOnFirst.IsChecked
        SkipArpDetection = -not $ui.chkArp.IsChecked
        SkipVendorLookup = -not $ui.chkVendor.IsChecked
    }

    $script:Results.Clear()
    $ui.pbProgress.Value = 0
    $ui.txtStatus.Text   = 'Starting…'
    Set-BusyState -Busy $true
    Add-LogLine ("Scan started: {0} via '{1}', timeout {2} ms." -f $range.Cidr, $adapter.InterfaceAlias, $timeout)

    $script:Job = Start-PSToolsJob -ScriptFile $script:Context.Tool.LogicFile -Command $script:Context.Tool.Command `
        -Parameters $parameters `
        -OnOutput {
            param($item)
            $script:Results.Add($item)
            Add-LogLine ('Found {0}  {1}  {2}  ({3})' -f $item.IPAddress, $item.MacAddress, $item.Vendor, $item.DetectedBy)
        } `
        -OnProgress {
            param($record)
            if ([string]$record.RecordType -eq 'Completed') { return }
            if ($record.PercentComplete -ge 0) { $script:Ui.pbProgress.Value = $record.PercentComplete }
            $script:Ui.txtStatus.Text = $record.StatusDescription
        } `
        -OnMessage {
            param($kind, $text)
            Add-LogLine ('[{0}] {1}' -f $kind, $text)
            if ($kind -in 'Warning', 'Error') { $script:Ui.expLog.IsExpanded = $true }
        } `
        -OnCompleted {
            param($result)
            Complete-Scan -Result $result
        }
}

function Stop-Scan {
    if ($script:Job -and -not $script:Job.IsFinished) {
        $script:Ui.txtStatus.Text = 'Cancelling…'
        $script:Ui.btnCancel.IsEnabled = $false
        Stop-PSToolsJob -Job $script:Job
    }
}

function Complete-Scan {
    param($Result)

    $ui = $script:Ui
    Set-BusyState -Busy $false
    $count = $script:Results.Count
    $duration = '{0:mm\:ss}' -f $Result.Duration

    switch ($Result.State) {
        'Completed' {
            $ui.pbProgress.Value = 100
            $ui.txtStatus.Text = "Finished: $count device(s) found in $duration."
        }
        'Stopped' {
            $ui.txtStatus.Text = "Cancelled after $duration – $count device(s) found so far."
        }
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
    foreach ($name in 'cmbAdapter', 'btnRefresh', 'chkShowAll', 'cmbSubnet', 'cmbTimeout',
                      'chkStopOnFirst', 'chkArp', 'chkVendor', 'btnStart', 'btnClear') {
        $ui[$name].IsEnabled = -not $Busy
    }
    $ui.btnCancel.IsEnabled = $Busy
    $ui.btnAssignApipa.IsEnabled = (-not $Busy) -and $script:Context.IsAdmin -and [bool]$ui.cmbAdapter.SelectedItem
}

function Add-LogLine {
    param([string]$Text)
    $box = $script:Ui.txtLog
    $box.AppendText(('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine))
    $box.ScrollToEnd()
}

#endregion
