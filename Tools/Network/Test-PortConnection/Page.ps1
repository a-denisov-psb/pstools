#Requires -Version 5.1
# GUI page of the tool "Port Check". Runs inside its own dynamic module (see CLAUDE.md):
# $script: variables are private to this page.

$ResultColumns = @('Timestamp', 'ComputerName', 'Protocol', 'Port', 'Service', 'State', 'ResponseTimeMs',
                   'RemoteAddress', 'SourceAddress', 'InterfaceAlias', 'Detail')
$HistoryName   = 'PortCheckHistory'
$HistoryMax    = 20

function Initialize-ToolPage {
    <#
    .SYNOPSIS
    Builds the page and wires up all events. Returns the root element.
    #>
    param([Parameter(Mandatory)]$Context)

    $script:Context = $Context
    $view = ConvertFrom-PSToolsXaml -Path (Join-Path $Context.ToolRoot 'Page.xaml')
    $script:Ui           = $view.Controls
    $script:Results      = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $script:History      = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $script:Job          = $null
    $script:CurrentCheck = $null
    $script:SaveWarned   = $false
    $script:Busy         = $false
    $ui = $script:Ui

    # Defaults
    $ui.dgResults.ItemsSource = $script:Results
    $ui.dgHistory.ItemsSource = $script:History
    $ui.txtPorts.Text   = '443'
    $ui.rbTcp.IsChecked = $true
    foreach ($value in '1000', '2000', '3000', '5000', '10000') { [void]$ui.cmbTimeout.Items.Add($value) }
    $ui.cmbTimeout.Text = '3000'
    $ui.cmbPreset.ItemsSource = @(
        New-Preset 'RDP'                          '3389'                               'TCP'
        New-Preset 'SSH'                          '22'                                 'TCP'
        New-Preset 'Web (HTTP, HTTPS)'            '80,443'                             'TCP'
        New-Preset 'SMB file share'               '445'                                'TCP'
        New-Preset 'WinRM / PowerShell remoting'  '5985-5986'                          'TCP'
        New-Preset 'DNS'                          '53'                                 'TCP+UDP'
        New-Preset 'NTP'                          '123'                                'UDP'
        New-Preset 'SNMP'                         '161'                                'UDP'
        New-Preset 'Active Directory (TCP)'       '88,135,389,445,464,636,3268-3269'   'TCP'
        New-Preset 'Active Directory (UDP)'       '88,123,389'                         'UDP'
        New-Preset 'SQL Server'                   '1433'                               'TCP'
        New-Preset 'Mail (SMTP, IMAP, POP3)'      '25,110,143,465,587,993,995'         'TCP'
        New-Preset 'Printer (LPD, IPP, RAW)'      '515,631,9100'                       'TCP'
    )

    # Events
    $ui.btnStart.Add_Click({ Invoke-PSToolsUiAction { Start-Check } })
    $ui.btnCancel.Add_Click({ Invoke-PSToolsUiAction { Stop-Check } })
    $ui.cmbPreset.Add_SelectionChanged({ Invoke-PSToolsUiAction { Use-Preset } })

    $ui.btnCopy.Add_Click({ Invoke-PSToolsUiAction { Copy-PSToolsGridSelection -Grid $script:Ui.dgResults -Property $ResultColumns } })
    $ui.btnExport.Add_Click({
        Invoke-PSToolsUiAction {
            $fileName = 'PortCheck_{0:yyyyMMdd_HHmmss}.csv' -f (Get-Date)
            Export-PSToolsGridCsv -Grid $script:Ui.dgResults -Property $ResultColumns -DefaultFileName $fileName
        }
    })
    $ui.btnClear.Add_Click({
        Invoke-PSToolsUiAction {
            $script:Results.Clear()
            $script:Ui.pbProgress.Value = 0
            $script:Ui.txtStatus.Text = 'Ready.'
        }
    })

    $ui.dgHistory.Add_SelectionChanged({ Update-HistoryButtons })
    $ui.dgHistory.Add_MouseDoubleClick({
        param($sender, $e)
        Invoke-PSToolsUiAction {
            # Only react to double-clicks on a row (not on the header or the scroll bar).
            $element = $e.OriginalSource
            while ($element -and -not ($element -is [System.Windows.Controls.DataGridRow])) {
                if (-not ($element -is [System.Windows.Media.Visual])) { $element = $null; break }
                $element = [System.Windows.Media.VisualTreeHelper]::GetParent($element)
            }
            if ($element) { Invoke-HistoryEntry -Entry $element.Item }
        }
    })
    $ui.btnRerun.Add_Click({ Invoke-PSToolsUiAction { Invoke-HistoryEntry -Entry $script:Ui.dgHistory.SelectedItem } })
    $ui.btnRemoveHistory.Add_Click({ Invoke-PSToolsUiAction { Remove-HistoryEntry } })
    $ui.btnClearHistory.Add_Click({ Invoke-PSToolsUiAction { Clear-History } })

    Import-History
    return $view.Root
}

#region Form

function New-Preset {
    param([string]$Name, [string]$Ports, [string]$Protocol)
    [pscustomobject]@{
        Display  = '{0} – {1} {2}' -f $Name, ($Protocol -replace '\+', ' + '), $Ports
        Ports    = $Ports
        Protocol = $Protocol
    }
}

function Use-Preset {
    $preset = $script:Ui.cmbPreset.SelectedItem
    if (-not $preset) { return }
    $script:Ui.txtPorts.Text = $preset.Ports
    Set-ProtocolSelection -Protocol $preset.Protocol
    # Reset, so the same preset can be chosen again after editing the ports.
    $script:Ui.cmbPreset.SelectedIndex = -1
    $script:Ui.cmbHost.Focus() | Out-Null
}

function Get-ProtocolSelection {
    # Returns 'TCP', 'UDP' or 'TCP+UDP'.
    $ui = $script:Ui
    if ($ui.rbUdp.IsChecked)  { return 'UDP' }
    if ($ui.rbBoth.IsChecked) { return 'TCP+UDP' }
    return 'TCP'
}

function Set-ProtocolSelection {
    param([string]$Protocol)
    $ui = $script:Ui
    switch ($Protocol) {
        'UDP'     { $ui.rbUdp.IsChecked  = $true }
        'TCP+UDP' { $ui.rbBoth.IsChecked = $true }
        default   { $ui.rbTcp.IsChecked  = $true }
    }
}

function Format-PortList {
    # Compresses a sorted port list into ranges: 80,443,8000-8010.
    param([int[]]$Ports)
    $parts = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Ports.Count) {
        $start = $Ports[$i]
        while ($i + 1 -lt $Ports.Count -and $Ports[$i + 1] -eq $Ports[$i] + 1) { $i++ }
        if ($Ports[$i] -eq $start) { $parts.Add([string]$start) } else { $parts.Add(('{0}-{1}' -f $start, $Ports[$i])) }
        $i++
    }
    return ($parts -join ',')
}

#endregion

#region Check

function Start-Check {
    $ui = $script:Ui
    if ($script:Job -and -not $script:Job.IsFinished) { return }

    $computerName = $ui.cmbHost.Text.Trim()
    if (-not $computerName) { throw 'Enter a host name or IP address.' }
    if ($computerName -match '\s') { throw 'The host name must not contain spaces. Check one host at a time.' }

    $ports = ConvertTo-PSToolsPortList -Text $ui.txtPorts.Text     # throws a readable message on invalid input

    $timeout = 0
    if (-not [int]::TryParse($ui.cmbTimeout.Text.Trim(), [ref]$timeout) -or $timeout -lt 100 -or $timeout -gt 60000) {
        throw 'The timeout must be a number between 100 and 60000 ms.'
    }

    $protocol = Get-ProtocolSelection
    $script:CurrentCheck = [pscustomobject]@{
        ComputerName = $computerName
        Ports        = Format-PortList -Ports $ports
        Protocol     = $protocol
        TimeoutMs    = $timeout
    }
    $ui.txtPorts.Text = $script:CurrentCheck.Ports

    $parameters = @{
        ComputerName = $computerName
        Port         = $ports
        Protocol     = [string[]]($protocol -split '\+')
        TimeoutMs    = $timeout
    }

    $script:Results.Clear()
    $ui.pbProgress.Value = 0
    $ui.pbProgress.IsIndeterminate = $true
    $ui.txtStatus.Text = 'Checking…'
    Set-BusyState -Busy $true
    Add-LogLine ('Check started: {0}, {1} {2}, timeout {3} ms.' -f $computerName, $protocol, $script:CurrentCheck.Ports, $timeout)

    $script:Job = Start-PSToolsJob -ScriptFile $script:Context.Tool.LogicFile -Command $script:Context.Tool.Command `
        -Parameters $parameters `
        -OnOutput {
            param($item)
            $script:Results.Add($item)
            Add-LogLine ('{0} {1}/{2}: {3} – {4}' -f $item.RemoteAddress, $item.Port, $item.Protocol, $item.State, $item.Detail)
        } `
        -OnProgress {
            param($record)
            if ([string]$record.RecordType -eq 'Completed') { return }
            $script:Ui.pbProgress.IsIndeterminate = $false
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
            Complete-Check -Result $result
        }
}

function Stop-Check {
    if ($script:Job -and -not $script:Job.IsFinished) {
        $script:Ui.txtStatus.Text = 'Cancelling…'
        $script:Ui.btnCancel.IsEnabled = $false
        Stop-PSToolsJob -Job $script:Job
    }
}

function Complete-Check {
    param($Result)

    $ui = $script:Ui
    Set-BusyState -Busy $false
    $ui.pbProgress.IsIndeterminate = $false
    $results = @($script:Results)

    # Summary: single result -> its state; several -> count per state.
    if ($results.Count -eq 1) {
        $summary = $results[0].State
        if ($null -ne $results[0].ResponseTimeMs) { $summary += ' ({0} ms)' -f $results[0].ResponseTimeMs }
    }
    elseif ($results.Count) {
        $order   = @('Open', 'Open|Filtered', 'Closed', 'Filtered', 'Unreachable', 'Blocked', 'Error')
        $summary = ($results | Group-Object -Property State |
            Sort-Object -Property @{ Expression = { $i = [array]::IndexOf($order, $_.Name); if ($i -lt 0) { 99 } else { $i } } } |
            ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join ', '
    }
    else {
        $summary = 'No result'
    }

    switch ($Result.State) {
        'Completed' {
            $ui.pbProgress.Value = 100
            if ($results.Count -eq 1) {
                $ui.txtStatus.Text = '{0} {1}/{2}: {3} – {4}' -f $results[0].ComputerName, $results[0].Port, $results[0].Protocol, $results[0].State, $results[0].Detail
            }
            else {
                $ui.txtStatus.Text = 'Finished: {0} ({1} checks in {2:mm\:ss}).' -f $summary, $results.Count, $Result.Duration
            }
        }
        'Stopped' {
            $summary += ' (cancelled)'
            $ui.txtStatus.Text = 'Cancelled: {0} of the ports checked.' -f $results.Count
        }
        default {
            $summary = "Failed: $($Result.Error)"
            $ui.txtStatus.Text = $summary
            $ui.expLog.IsExpanded = $true
        }
    }
    Add-LogLine $ui.txtStatus.Text

    if ($script:CurrentCheck) {
        Add-HistoryEntry -Check $script:CurrentCheck -Summary $summary
        $script:CurrentCheck = $null
    }
}

function Set-BusyState {
    param([bool]$Busy)

    $script:Busy = $Busy
    $ui = $script:Ui
    foreach ($name in 'cmbHost', 'txtPorts', 'cmbPreset', 'rbTcp', 'rbUdp', 'rbBoth', 'cmbTimeout',
                      'btnStart', 'btnClear', 'btnClearHistory') {
        $ui[$name].IsEnabled = -not $Busy
    }
    $ui.btnCancel.IsEnabled = $Busy
    Update-HistoryButtons
}

function Add-LogLine {
    param([string]$Text)
    $box = $script:Ui.txtLog
    $box.AppendText(('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine))
    $box.ScrollToEnd()
}

#endregion

#region History

function New-HistoryEntry {
    param($Source)
    [pscustomobject]@{
        Time         = [string]$Source.Time
        ComputerName = [string]$Source.ComputerName
        Ports        = [string]$Source.Ports
        Protocol     = [string]$Source.Protocol
        TimeoutMs    = [int]$Source.TimeoutMs
        Result       = [string]$Source.Result
    }
}

function Import-History {
    $warnings = $null
    $entries  = @(Get-PSToolsUserData -Name $HistoryName -WarningVariable warnings -WarningAction SilentlyContinue)
    foreach ($warning in @($warnings)) {
        Add-LogLine "[Warning] $warning"
        $script:Ui.expLog.IsExpanded = $true
    }
    foreach ($entry in $entries | Select-Object -First $HistoryMax) {
        if ($entry.ComputerName -and $entry.Ports) { $script:History.Add((New-HistoryEntry $entry)) }
    }
    Update-HostSuggestions
    Update-HistoryButtons
    if ($script:History.Count) {
        Add-LogLine ('History loaded: {0} entries ({1}).' -f $script:History.Count, (Get-PSToolsUserDataPath -Name $HistoryName))
    }
}

function Add-HistoryEntry {
    # Adds a check to the top of the history; the same host/ports/protocol replaces its older entry.
    param($Check, [string]$Summary)

    $existing = @($script:History | Where-Object {
        $_.ComputerName -eq $Check.ComputerName -and $_.Ports -eq $Check.Ports -and $_.Protocol -eq $Check.Protocol
    })
    foreach ($entry in $existing) { [void]$script:History.Remove($entry) }

    $script:History.Insert(0, (New-HistoryEntry ([pscustomobject]@{
        Time         = '{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)
        ComputerName = $Check.ComputerName
        Ports        = $Check.Ports
        Protocol     = $Check.Protocol
        TimeoutMs    = $Check.TimeoutMs
        Result       = $Summary
    })))
    while ($script:History.Count -gt $HistoryMax) { $script:History.RemoveAt($script:History.Count - 1) }

    Save-History
    Update-HostSuggestions
}

function Save-History {
    try {
        Save-PSToolsUserData -Name $HistoryName -InputObject @($script:History)
    }
    catch {
        # Read-only folder (e.g. network share): keep the history in memory, warn once.
        if (-not $script:SaveWarned) {
            $script:SaveWarned = $true
            Add-LogLine "[Warning] The history is kept for this session only. $($_.Exception.Message)"
            $script:Ui.expLog.IsExpanded = $true
        }
    }
}

function Invoke-HistoryEntry {
    # Loads a history entry into the form and runs the check.
    param($Entry)
    if (-not $Entry) { return }
    if ($script:Job -and -not $script:Job.IsFinished) { return }
    $ui = $script:Ui
    $ui.cmbHost.Text  = $Entry.ComputerName
    $ui.txtPorts.Text = $Entry.Ports
    Set-ProtocolSelection -Protocol $Entry.Protocol
    if ($Entry.TimeoutMs -ge 100) { $ui.cmbTimeout.Text = [string]$Entry.TimeoutMs }
    Start-Check
}

function Remove-HistoryEntry {
    $selected = @($script:Ui.dgHistory.SelectedItems)
    if (-not $selected.Count) { return }
    foreach ($entry in $selected) { [void]$script:History.Remove($entry) }
    Save-History
    Update-HostSuggestions
}

function Clear-History {
    if (-not $script:History.Count) { return }
    $answer = Show-PSToolsMessage -Kind Question -Buttons YesNo -Message ('Remove all {0} entries from the history?' -f $script:History.Count)
    if ($answer -ne 'Yes') { return }
    $script:History.Clear()
    Save-History
    Update-HostSuggestions
}

function Update-HostSuggestions {
    # The host field suggests the hosts from the history (most recent first); keeps the typed text.
    $box  = $script:Ui.cmbHost
    $text = $box.Text
    $box.Items.Clear()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $script:History) {
        if ($seen.Add($entry.ComputerName)) { [void]$box.Items.Add($entry.ComputerName) }
    }
    $box.Text = $text
}

function Update-HistoryButtons {
    $ui = $script:Ui
    $idle = -not $script:Busy
    $hasSelection = $ui.dgHistory.SelectedItems.Count -gt 0
    $ui.btnRerun.IsEnabled         = $idle -and $ui.dgHistory.SelectedItems.Count -eq 1
    $ui.btnRemoveHistory.IsEnabled = $idle -and $hasSelection
}

#endregion
