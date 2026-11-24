#Requires -Version 5.1
# GUI page of the tool "Route Table". Runs inside its own dynamic module (see CLAUDE.md):
# $script: variables are private to this page.

$RouteColumns      = @('AddressFamily', 'DestinationPrefix', 'NextHopDisplay', 'InterfaceName', 'RouteMetric', 'InterfaceMetric',
                       'EffectiveMetric', 'Origin', 'Store', 'Kind', 'Lifetime')
$DiffColumns       = @('Change', 'AddressFamily', 'DestinationPrefix', 'NextHop', 'InterfaceAlias', 'Before', 'After')
$LookupHistoryName = 'RouteLookupHistory'
$SnapshotDataName  = 'RouteSnapshots'
$LookupHistoryMax  = 15
$SnapshotMax       = 20
$BackupFormat      = 'PSTools.RouteBackup'
$AdminHint         = 'Requires administrator rights – use "Restart as administrator" in the status bar.'

function Initialize-ToolPage {
    <#
    .SYNOPSIS
    Builds the page and wires up all events. Returns the root element.
    #>
    param([Parameter(Mandatory)]$Context)

    $script:Context        = $Context
    $view = ConvertFrom-PSToolsXaml -Path (Join-Path $Context.ToolRoot 'Page.xaml')
    $script:Ui             = $view.Controls
    $script:Family         = 'IPv4'
    $script:AllRoutes      = @()
    $script:Interfaces     = @()
    $script:Routes         = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $script:Snapshots      = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $script:LookupHistory  = New-Object 'System.Collections.Generic.List[string]'
    $script:EditRoute      = $null    # route loaded into the editor ($null = new route)
    $script:Loading        = $false   # true while code fills controls (suppresses change events)
    $script:LookupJob      = $null
    $script:LookupResult   = $null
    $script:LookupTarget   = $null
    $script:LastComparison = $null
    $script:SaveWarned     = @{}
    $ui = $script:Ui

    # Defaults
    $script:Loading = $true
    $ui.dgRoutes.ItemsSource    = $script:Routes
    $ui.dgSnapshots.ItemsSource = $script:Snapshots
    foreach ($value in '0', '1', '5', '10', '25', '50', '100', '256') { [void]$ui.cmbMetric.Items.Add($value) }
    foreach ($value in '5', '10', '15', '25', '35', '50', '100', '500') { [void]$ui.cmbIfMetric.Items.Add($value) }
    foreach ($value in 'PowerShell', 'Netsh') { [void]$ui.cmbSyntax.Items.Add($value) }
    $ui.cmbSyntax.SelectedIndex = 0
    $ui.rbIPv4.IsChecked = $true
    $ui.rbPersistent.IsChecked = $true
    $script:Loading = $false

    if (-not $Context.IsAdmin) {
        foreach ($name in 'btnAdd', 'btnApply', 'btnDelete', 'btnSetMetric', 'btnAutoMetric') {
            $ui[$name].ToolTip = $AdminHint
            [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($ui[$name], $true)
        }
    }

    # View
    $ui.rbIPv4.Add_Checked({ Invoke-PSToolsUiAction { Set-AddressFamily 'IPv4' } })
    $ui.rbIPv6.Add_Checked({ Invoke-PSToolsUiAction { Set-AddressFamily 'IPv6' } })
    $ui.chkSystem.Add_Checked({ Invoke-PSToolsUiAction { Update-RouteFilter } })
    $ui.chkSystem.Add_Unchecked({ Invoke-PSToolsUiAction { Update-RouteFilter } })
    $ui.txtFilter.Add_TextChanged({ Invoke-PSToolsUiAction { Update-RouteFilter } })
    $ui.btnRefresh.Add_Click({ Invoke-PSToolsUiAction { Update-RouteView; Add-LogLine 'Route table refreshed.' } })

    # Routes tab
    $ui.dgRoutes.Add_SelectionChanged({ Invoke-PSToolsUiAction { Select-EditorRoute } })
    $ui.btnLookup.Add_Click({ Invoke-PSToolsUiAction { Start-Lookup } })
    $ui.cmbLookup.Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Return) {
            $e.Handled = $true
            if (-not ($script:LookupJob -and -not $script:LookupJob.IsFinished)) { Invoke-PSToolsUiAction { Start-Lookup } }
        }
    })
    $ui.btnCopy.Add_Click({ Invoke-PSToolsUiAction { Copy-PSToolsGridSelection -Grid $script:Ui.dgRoutes -Property $RouteColumns } })
    $ui.btnCopyCommand.Add_Click({ Invoke-PSToolsUiAction { Copy-RouteCommand } })
    $ui.btnExport.Add_Click({
        Invoke-PSToolsUiAction {
            $fileName = 'Routes_{0}_{1:yyyyMMdd_HHmmss}.csv' -f $script:Family, (Get-Date)
            Export-PSToolsGridCsv -Grid $script:Ui.dgRoutes -Property $RouteColumns -DefaultFileName $fileName
        }
    })
    $ui.btnDelete.Add_Click({ Invoke-PSToolsUiAction { Remove-SelectedRoute } })
    $ui.btnBackup.Add_Click({ Invoke-PSToolsUiAction { Save-RouteBackup } })
    $ui.btnRestore.Add_Click({ Invoke-PSToolsUiAction { Restore-RouteBackup } })

    # Editor
    $previewHandler = [System.Windows.Controls.TextChangedEventHandler]{ Invoke-PSToolsUiAction { Update-CommandPreview } }
    $ui.txtPrefix.Add_TextChanged($previewHandler)
    $ui.txtNextHop.Add_TextChanged($previewHandler)
    $ui.cmbMetric.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, $previewHandler)
    $ui.cmbInterface.Add_SelectionChanged({ Invoke-PSToolsUiAction { Update-CommandPreview } })
    $ui.rbPersistent.Add_Checked({ Invoke-PSToolsUiAction { Update-CommandPreview } })
    $ui.rbTemporary.Add_Checked({ Invoke-PSToolsUiAction { Update-CommandPreview } })
    $ui.cmbSyntax.Add_SelectionChanged({ Invoke-PSToolsUiAction { Update-CommandPreview } })
    $ui.txtNextHop.Add_LostFocus({ Invoke-PSToolsUiAction { Select-InterfaceForGateway } })
    $ui.btnRefreshInterfaces.Add_Click({ Invoke-PSToolsUiAction { Update-InterfaceList; Update-CommandPreview } })
    $ui.btnNew.Add_Click({ Invoke-PSToolsUiAction { Clear-Editor; $script:Ui.dgRoutes.UnselectAll(); $script:Ui.txtPrefix.Focus() | Out-Null } })
    $ui.btnAdd.Add_Click({ Invoke-PSToolsUiAction { Add-EditorRoute } })
    $ui.btnApply.Add_Click({ Invoke-PSToolsUiAction { Set-EditorRoute } })
    $ui.btnCopyEditorCommand.Add_Click({ Invoke-PSToolsUiAction { Set-ClipboardText $script:Ui.txtCommand.Text } })

    # Interface metrics tab
    $ui.dgInterfaces.Add_SelectionChanged({ Invoke-PSToolsUiAction { Update-InterfaceEditor } })
    $ui.cmbIfMetric.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
        [System.Windows.Controls.TextChangedEventHandler]{ Invoke-PSToolsUiAction { Update-InterfaceCommand } })
    $ui.btnSetMetric.Add_Click({ Invoke-PSToolsUiAction { Set-InterfaceMetric } })
    $ui.btnAutoMetric.Add_Click({ Invoke-PSToolsUiAction { Set-InterfaceMetric -Automatic } })
    $ui.btnCopyIfCommand.Add_Click({ Invoke-PSToolsUiAction { Set-ClipboardText $script:Ui.txtIfCommand.Text } })

    # Snapshots tab
    $ui.btnTakeSnapshot.Add_Click({ Invoke-PSToolsUiAction { New-RouteSnapshot } })
    $ui.dgSnapshots.Add_SelectionChanged({ Invoke-PSToolsUiAction { Update-Buttons } })
    $ui.btnCompareCurrent.Add_Click({ Invoke-PSToolsUiAction { Compare-SnapshotWithCurrent } })
    $ui.btnCompareTwo.Add_Click({ Invoke-PSToolsUiAction { Compare-TwoSnapshots } })
    $ui.btnDeleteSnapshot.Add_Click({ Invoke-PSToolsUiAction { Remove-RouteSnapshot } })
    $ui.chkDiffSystem.Add_Checked({ Invoke-PSToolsUiAction { Show-Comparison } })
    $ui.chkDiffSystem.Add_Unchecked({ Invoke-PSToolsUiAction { Show-Comparison } })
    $ui.btnCopyDiff.Add_Click({ Invoke-PSToolsUiAction { Copy-PSToolsGridSelection -Grid $script:Ui.dgDiff -Property $DiffColumns } })

    Import-LookupHistory
    Import-RouteSnapshots
    Update-RouteView
    Clear-Editor
    return $view.Root
}

#region Helpers

function Add-LogLine {
    param([string]$Text)
    $box = $script:Ui.txtLog
    $box.AppendText(('[{0:HH:mm:ss}] {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine))
    $box.ScrollToEnd()
}

function Set-ClipboardText {
    param([string]$Text)
    if (-not $Text) { return }
    [System.Windows.Clipboard]::SetText($Text)
    $script:Ui.txtStatus.Text = 'Copied to the clipboard.'
}

function Confirm-Action {
    # Shows a Yes/No question; returns $true for Yes.
    param([string]$Message, [ValidateSet('Question', 'Warning')][string]$Kind = 'Question')
    return ((Show-PSToolsMessage -Message $Message -Kind $Kind -Buttons YesNo) -eq 'Yes')
}

function Save-UserDataSafe {
    # Saves user data; a read-only folder only causes one warning per data file.
    param([string]$Name, [object[]]$Data)
    try {
        Save-PSToolsUserData -Name $Name -InputObject $Data
    }
    catch {
        if (-not $script:SaveWarned[$Name]) {
            $script:SaveWarned[$Name] = $true
            Add-LogLine "[Warning] Kept for this session only. $($_.Exception.Message)"
            $script:Ui.expLog.IsExpanded = $true
        }
    }
}

function Read-UserDataSafe {
    param([string]$Name)
    $warnings = $null
    $entries  = @(Get-PSToolsUserData -Name $Name -WarningVariable warnings -WarningAction SilentlyContinue)
    foreach ($warning in @($warnings)) {
        Add-LogLine "[Warning] $warning"
        $script:Ui.expLog.IsExpanded = $true
    }
    return ,$entries
}

function Format-RouteText {
    # One-line description of a route for messages and the log.
    param($Route)
    $gateway   = if ($Route.NextHopDisplay) { $Route.NextHopDisplay } elseif ($Route.IsOnLink) { 'On-link' } else { $Route.NextHop }
    $interface = if ($Route.InterfaceName) { $Route.InterfaceName } else { $Route.InterfaceAlias }
    return ("{0} via {1} on '{2}'" -f $Route.DestinationPrefix, $gateway, $interface)
}

function Get-CommandSyntax {
    $syntax = [string]$script:Ui.cmbSyntax.SelectedItem
    if (-not $syntax) { $syntax = 'PowerShell' }
    return $syntax
}

#endregion

#region Route table

function Set-AddressFamily {
    param([string]$Family)
    if ($script:Loading -or $script:Family -eq $Family) { return }
    $script:Family = $Family
    $script:Ui.txtLookupResult.Visibility = 'Collapsed'
    Update-RouteView
    Clear-Editor
}

function Update-RouteView {
    # Reads routes and interfaces of the selected address family and refreshes all lists.
    $ui = $script:Ui
    $selectedKeys = @($ui.dgRoutes.SelectedItems | ForEach-Object { $_.RouteKey })

    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    try {
        $script:AllRoutes = @(Get-RouteTable -AddressFamily $script:Family -IncludeSystem)
        Update-InterfaceList
    }
    finally {
        [System.Windows.Input.Mouse]::OverrideCursor = $null
    }

    Update-RouteFilter -SelectKeys $selectedKeys
    Update-Issues

    if ($script:EditRoute) {
        $key = $script:EditRoute.RouteKey
        $fresh = $script:AllRoutes | Where-Object { $_.RouteKey -eq $key } | Select-Object -First 1
        if ($fresh) { $script:EditRoute = $fresh; Update-CommandPreview } else { Clear-Editor }
    }
    Update-Buttons
}

function Update-RouteFilter {
    # Fills the grid from $script:AllRoutes according to the system and text filter.
    param([string[]]$SelectKeys)

    $ui = $script:Ui
    if ($null -eq $SelectKeys) { $SelectKeys = @($ui.dgRoutes.SelectedItems | ForEach-Object { $_.RouteKey }) }
    $words      = @($ui.txtFilter.Text -split '\s+' | Where-Object { $_ })
    $showSystem = [bool]$ui.chkSystem.IsChecked

    $script:Loading = $true
    try {
        $script:Routes.Clear()
        foreach ($route in $script:AllRoutes) {
            if ($route.IsSystem -and -not $showSystem) { continue }
            if ($words.Count) {
                $text = ($route.DestinationPrefix, $route.NextHopDisplay, $route.InterfaceName, $route.Origin, $route.Store, $route.Kind) -join ' '
                $match = $true
                foreach ($word in $words) { if ($text -notlike "*$word*") { $match = $false; break } }
                if (-not $match) { continue }
            }
            $script:Routes.Add($route)
        }
        foreach ($route in $script:Routes) {
            if ($SelectKeys -contains $route.RouteKey) { [void]$ui.dgRoutes.SelectedItems.Add($route) }
        }
    }
    finally {
        $script:Loading = $false
    }

    $system = @($script:AllRoutes | Where-Object { $_.IsSystem }).Count
    $ui.txtStatus.Text = '{0} of {1} {2} routes shown{3}. Read at {4:HH:mm:ss}.' -f $script:Routes.Count, $script:AllRoutes.Count, $script:Family,
        $(if (-not $showSystem -and $system) { " ($system system routes hidden)" } else { '' }), (Get-Date)
    Update-Buttons
}

function Update-Issues {
    $ui = $script:Ui
    $issues = @(Get-PSToolsRouteIssue -Route $script:AllRoutes -Interface $script:Interfaces -AddressFamily $script:Family)
    $ui.icIssues.ItemsSource = $issues
    $ui.bdrIssues.Visibility = $(if ($issues.Count) { 'Visible' } else { 'Collapsed' })
}

function Update-InterfaceList {
    # Reads the interfaces of the selected family; keeps the selection in the editor and the grid.
    $ui = $script:Ui
    $editorIndex = if ($ui.cmbInterface.SelectedItem) { $ui.cmbInterface.SelectedItem.InterfaceIndex } else { $null }
    $gridIndex   = if ($ui.dgInterfaces.SelectedItem) { $ui.dgInterfaces.SelectedItem.InterfaceIndex } else { $null }

    $script:Interfaces = @(Get-PSToolsIPInterface -AddressFamily $script:Family)
    $wasLoading = $script:Loading
    $script:Loading = $true
    try {
        # Separate arrays: a shared source would share the sort order of the grid with the combo box.
        $ui.cmbInterface.ItemsSource = @($script:Interfaces)
        $ui.dgInterfaces.ItemsSource = @($script:Interfaces)
        if ($null -ne $editorIndex) {
            $ui.cmbInterface.SelectedItem = $ui.cmbInterface.ItemsSource | Where-Object { $_.InterfaceIndex -eq $editorIndex } | Select-Object -First 1
        }
        if ($null -ne $gridIndex) {
            $ui.dgInterfaces.SelectedItem = $ui.dgInterfaces.ItemsSource | Where-Object { $_.InterfaceIndex -eq $gridIndex } | Select-Object -First 1
        }
    }
    finally {
        $script:Loading = $wasLoading
    }
    Update-InterfaceEditor
}

function Select-RouteByKey {
    # Selects a route in the grid (shows system routes / clears the filter if needed) and scrolls to it.
    param([string]$Key)
    $ui = $script:Ui
    $route = $script:AllRoutes | Where-Object { $_.RouteKey -eq $Key } | Select-Object -First 1
    if (-not $route) { return $false }
    if ($route.IsSystem -and -not $ui.chkSystem.IsChecked) { $ui.chkSystem.IsChecked = $true }
    if (-not ($script:Routes | Where-Object { $_.RouteKey -eq $Key })) { $ui.txtFilter.Text = '' }
    $item = $script:Routes | Where-Object { $_.RouteKey -eq $Key } | Select-Object -First 1
    if (-not $item) { return $false }
    $ui.tabMain.SelectedIndex = 0
    $ui.dgRoutes.SelectedItem = $item
    $ui.dgRoutes.ScrollIntoView($item)
    return $true
}

function Update-Buttons {
    $ui      = $script:Ui
    $admin   = [bool]$script:Context.IsAdmin
    $routes  = @($ui.dgRoutes.SelectedItems)
    $snaps   = @($ui.dgSnapshots.SelectedItems)

    $ui.btnAdd.IsEnabled            = $admin
    $ui.btnApply.IsEnabled          = $admin -and [bool]$script:EditRoute
    $ui.btnDelete.IsEnabled         = $admin -and $routes.Count -gt 0
    $ui.btnSetMetric.IsEnabled      = $admin -and [bool]$ui.dgInterfaces.SelectedItem
    $ui.btnAutoMetric.IsEnabled     = $admin -and [bool]$ui.dgInterfaces.SelectedItem
    $ui.btnCompareCurrent.IsEnabled = $snaps.Count -eq 1
    $ui.btnCompareTwo.IsEnabled     = $snaps.Count -eq 2
    $ui.btnDeleteSnapshot.IsEnabled = $snaps.Count -gt 0

    $hint = @()
    if (-not $admin) { $hint += 'Read-only: changing routes requires administrator rights.' }
    if ($script:EditRoute -and $script:EditRoute.Origin -ne 'Static') {
        $hint += "Created by Windows ($($script:EditRoute.Origin)): Windows may restore or remove it again."
    }
    $ui.txtEditorHint.Text = $hint -join '  '
}

#endregion

#region Route lookup

function Start-Lookup {
    $ui = $script:Ui
    if ($script:LookupJob -and -not $script:LookupJob.IsFinished) {
        $ui.txtLookupResult.Text = 'Cancelling…'
        Stop-PSToolsJob -Job $script:LookupJob
        return
    }

    $target = $ui.cmbLookup.Text.Trim()
    if (-not $target) { throw 'Enter an IP address or host name, e.g. 8.8.8.8 or server01.' }
    if ($target -match '\s') { throw 'Enter one IP address or host name without spaces.' }

    $script:LookupTarget = $target
    $script:LookupResult = $null
    $ui.btnLookup.Content = 'Cancel'
    $ui.txtLookupResult.Visibility = 'Visible'
    $ui.txtLookupResult.Text = "Looking up the route to $target…"

    $script:LookupJob = Start-PSToolsJob -ScriptFile $script:Context.Tool.LogicFile -Command 'Find-PSToolsRoute' `
        -Parameters @{ Destination = $target; PreferredAddressFamily = $script:Family } `
        -OnOutput { param($item) $script:LookupResult = $item } `
        -OnProgress {
            param($record)
            if ([string]$record.RecordType -ne 'Completed') { $script:Ui.txtLookupResult.Text = $record.StatusDescription }
        } `
        -OnMessage {
            param($kind, $text)
            Add-LogLine ('[{0}] {1}' -f $kind, $text)
            if ($kind -in 'Warning', 'Error') { $script:Ui.expLog.IsExpanded = $true }
        } `
        -OnCompleted { param($result) Complete-Lookup -Result $result }
}

function Complete-Lookup {
    param($Result)
    $ui = $script:Ui
    $ui.btnLookup.Content = 'Look up'
    $found = $script:LookupResult

    if ($Result.State -eq 'Stopped') {
        $ui.txtLookupResult.Text = 'Lookup cancelled.'
        return
    }
    if (-not $found) {
        $message = if ($Result.Error) { $Result.Error } else { 'No result.' }
        $ui.txtLookupResult.Text = "Lookup failed: $message"
        Add-LogLine "Lookup of '$($script:LookupTarget)' failed: $message"
        return
    }

    $name = if ($found.Destination -ne $found.RemoteAddress) { '{0} ({1})' -f $found.Destination, $found.RemoteAddress } else { $found.RemoteAddress }
    $text = "{0} → route {1} via {2} on '{3}', source address {4}, effective metric {5} ({6} + interface {7})." -f
        $name, $found.DestinationPrefix, $found.NextHopDisplay, $found.InterfaceAlias,
        $(if ($found.SourceAddress) { $found.SourceAddress } else { 'unknown' }), $found.EffectiveMetric, $found.RouteMetric, $found.InterfaceMetric
    $ui.txtLookupResult.Text = $text
    Add-LogLine "Lookup: $text"
    Add-LookupHistory -Target $script:LookupTarget

    # Show the route in the table (switch the address family if needed).
    if ($found.AddressFamily -ne $script:Family) {
        if ($found.AddressFamily -eq 'IPv6') { $ui.rbIPv6.IsChecked = $true } else { $ui.rbIPv4.IsChecked = $true }
        $ui.txtLookupResult.Text = $text
        $ui.txtLookupResult.Visibility = 'Visible'
    }
    $key = '{0}|{1}|{2}|{3}' -f $found.AddressFamily, $found.DestinationPrefix, $found.NextHop, $found.InterfaceIndex
    if (-not (Select-RouteByKey -Key $key)) {
        Update-RouteView
        [void](Select-RouteByKey -Key $key)
    }
}

function Import-LookupHistory {
    foreach ($entry in (Read-UserDataSafe -Name $LookupHistoryName) | Select-Object -First $LookupHistoryMax) {
        if ($entry -is [string] -and $entry.Trim()) { $script:LookupHistory.Add($entry.Trim()) }
    }
    Update-LookupSuggestions
}

function Add-LookupHistory {
    param([string]$Target)
    $existing = @($script:LookupHistory | Where-Object { $_ -eq $Target })
    foreach ($entry in $existing) { [void]$script:LookupHistory.Remove($entry) }
    $script:LookupHistory.Insert(0, $Target)
    while ($script:LookupHistory.Count -gt $LookupHistoryMax) { $script:LookupHistory.RemoveAt($script:LookupHistory.Count - 1) }
    Save-UserDataSafe -Name $LookupHistoryName -Data @($script:LookupHistory)
    Update-LookupSuggestions
}

function Update-LookupSuggestions {
    $box  = $script:Ui.cmbLookup
    $text = $box.Text
    $box.Items.Clear()
    foreach ($entry in $script:LookupHistory) { [void]$box.Items.Add($entry) }
    $box.Text = $text
}

#endregion

#region Editor

function Select-EditorRoute {
    # Selection changed in the route grid: a single selected route is loaded into the editor.
    if ($script:Loading) { return }
    $selected = @($script:Ui.dgRoutes.SelectedItems)
    if ($selected.Count -eq 1) { Show-EditorRoute -Route $selected[0] }
    Update-Buttons
}

function Show-EditorRoute {
    param([Parameter(Mandatory)]$Route)
    $ui = $script:Ui
    $script:Loading = $true
    try {
        $script:EditRoute = $Route
        $ui.expEditor.Header = 'Edit route {0}' -f (Format-RouteText $Route)
        $ui.txtPrefix.Text   = $Route.DestinationPrefix
        $ui.txtNextHop.Text  = $(if ($Route.IsOnLink) { '' } else { $Route.NextHop })
        $ui.cmbMetric.Text   = [string]$Route.RouteMetric
        $ui.rbPersistent.IsChecked = [bool]$Route.IsPersistent
        $ui.rbTemporary.IsChecked  = -not $Route.IsPersistent
        $ui.cmbInterface.SelectedItem = $ui.cmbInterface.ItemsSource | Where-Object { $_.InterfaceIndex -eq $Route.InterfaceIndex } | Select-Object -First 1
    }
    finally {
        $script:Loading = $false
    }
    Update-CommandPreview
    Update-Buttons
}

function Clear-Editor {
    $ui = $script:Ui
    $script:Loading = $true
    try {
        $script:EditRoute = $null
        $ui.expEditor.Header = "New $($script:Family) route"
        $ui.txtPrefix.Text  = ''
        $ui.txtNextHop.Text = ''
        $ui.cmbMetric.Text  = '256'
        $ui.rbPersistent.IsChecked = $true
        if (-not $ui.cmbInterface.SelectedItem) {
            # Default: the connected interface with a default gateway, else the first connected one.
            $items = @($ui.cmbInterface.ItemsSource)
            $default = $items | Where-Object { $_.IsConnected -and $_.DefaultGateway } | Select-Object -First 1
            if (-not $default) { $default = $items | Where-Object { $_.IsConnected } | Select-Object -First 1 }
            $ui.cmbInterface.SelectedItem = $default
        }
    }
    finally {
        $script:Loading = $false
    }
    Update-CommandPreview
    Update-Buttons
}

function Get-EditorSpec {
    # Validates the form and returns a route specification (throws a readable message).
    $ui = $script:Ui
    $metric = 0
    if (-not [int]::TryParse($ui.cmbMetric.Text.Trim(), [ref]$metric) -or $metric -lt 0 -or $metric -gt 9999) {
        throw 'The metric must be a number between 0 and 9999.'
    }
    return New-PSToolsRouteSpec -AddressFamily $script:Family -DestinationPrefix $ui.txtPrefix.Text -NextHop $ui.txtNextHop.Text `
        -Interface $ui.cmbInterface.SelectedItem -RouteMetric $metric -Persistent ([bool]$ui.rbPersistent.IsChecked)
}

function Update-CommandPreview {
    # Shows the commands 'Apply changes' (route loaded) or 'Add route' (new route) would run.
    if ($script:Loading) { return }
    $ui = $script:Ui
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        $spec = Get-EditorSpec
        $plan = @(Get-PSToolsRouteChangePlan -ExistingRoute $script:EditRoute -Spec $spec)
        if ($spec.HostBitsCleared) { $lines.Add("# Destination normalized to $($spec.DestinationPrefix).") }
        if (-not $spec.GatewayOnLink) {
            $lines.Add("# Warning: the gateway is not in a subnet of '$($spec.InterfaceAlias)', so Windows cannot reach it directly.")
        }
        if ($spec.Persistent -and $spec.InterfaceState -eq 'Disconnected') {
            $lines.Add('# The interface is disconnected: the route is saved and becomes active when the interface connects.')
        }
        if ($plan.Count) {
            foreach ($line in (Get-PSToolsRouteCommand -Operation $plan -Syntax (Get-CommandSyntax))) { $lines.Add($line) }
        }
        else {
            $lines.Add('# No changes.')
        }
    }
    catch {
        $lines.Clear()
        $lines.Add("# $($_.Exception.Message)")
    }
    $ui.txtCommand.Text = $lines -join [Environment]::NewLine
}

function Select-InterfaceForGateway {
    # When the selected interface cannot reach the gateway, select the interface whose subnet contains it.
    $ui = $script:Ui
    $gateway = ConvertTo-PSToolsIPAddress $ui.txtNextHop.Text
    if (-not $gateway -or (Get-PSToolsAddressFamilyName $gateway) -ne $script:Family) { return }
    $current = $ui.cmbInterface.SelectedItem
    if ($current -and (Test-PSToolsNextHopOnLink -NextHop $gateway.ToString() -Interface $current)) { return }
    $match = @($ui.cmbInterface.ItemsSource) | Where-Object { Test-PSToolsNextHopOnLink -NextHop $gateway.ToString() -Interface $_ } |
        Select-Object -First 1
    if ($match) {
        $ui.cmbInterface.SelectedItem = $match
        Add-LogLine "Interface '$($match.InterfaceAlias)' selected: its subnet contains the gateway $gateway."
    }
}

function Invoke-RoutePlan {
    # Runs route operations, logs the commands, refreshes the table. Errors are logged and rethrown.
    param([object[]]$Plan, [string]$Description)
    foreach ($line in (Get-PSToolsRouteCommand -Operation $Plan)) { Add-LogLine "> $line" }
    try {
        Invoke-PSToolsRouteOperation -Operation $Plan -Confirm:$false
        Add-LogLine $Description
        $script:Ui.txtStatus.Text = $Description
    }
    catch {
        Add-LogLine "[Error] $($_.Exception.Message)"
        $script:Ui.expLog.IsExpanded = $true
        Update-RouteView
        throw
    }
    Update-RouteView
}

function Add-EditorRoute {
    if (-not $script:Context.IsAdmin) { throw 'Adding a route requires administrator rights.' }
    $spec = Get-EditorSpec
    $key  = '{0}|{1}|{2}|{3}' -f $spec.AddressFamily, $spec.DestinationPrefix, $spec.NextHop, $spec.InterfaceIndex
    if ($script:AllRoutes | Where-Object { $_.RouteKey -eq $key }) {
        throw 'This route exists already. Select it in the table to change it.'
    }
    if (-not $spec.GatewayOnLink) {
        $question = "The gateway $($spec.NextHop) is not in a subnet of '$($spec.InterfaceAlias)'. Windows cannot reach it directly, so the route will probably not work.`r`n`r`nAdd it anyway?"
        if (-not (Confirm-Action -Message $question -Kind Warning)) { return }
    }

    $plan = @(Get-PSToolsRouteChangePlan -Spec $spec)
    $store = if ($spec.Persistent) { 'persistent' } else { 'temporary' }
    Invoke-RoutePlan -Plan $plan -Description ('Added {0} route {1}.' -f $store, (Format-RouteText ([pscustomobject]@{
        DestinationPrefix = $spec.DestinationPrefix; IsOnLink = $spec.IsOnLink; NextHop = $spec.NextHop; InterfaceAlias = $spec.InterfaceAlias })))
    if (Select-RouteByKey -Key $key) { Select-EditorRoute }
}

function Set-EditorRoute {
    if (-not $script:Context.IsAdmin) { throw 'Changing a route requires administrator rights.' }
    $route = $script:EditRoute
    if (-not $route) { throw 'Select the route to change in the table first.' }
    $spec = Get-EditorSpec
    $plan = @(Get-PSToolsRouteChangePlan -ExistingRoute $route -Spec $spec)
    if (-not $plan.Count) {
        $script:Ui.txtStatus.Text = 'No changes to apply.'
        return
    }

    $message = "Change the route {0}?`r`n`r`n{1}" -f (Format-RouteText $route), ((Get-PSToolsRouteCommand -Operation $plan) -join "`r`n")
    if (-not $spec.GatewayOnLink) { $message += "`r`n`r`nWarning: the gateway $($spec.NextHop) is not in a subnet of '$($spec.InterfaceAlias)'." }
    if ($route.Origin -ne 'Static') { $message += "`r`n`r`nThis route was created by Windows ($($route.Origin)); Windows may restore or remove it again." }
    if ($route.PrefixLength -eq 0) { $message += "`r`n`r`nChanging a default route can interrupt network connections, including remote sessions." }
    if (-not (Confirm-Action -Message $message -Kind Warning)) { return }

    $key = '{0}|{1}|{2}|{3}' -f $spec.AddressFamily, $spec.DestinationPrefix, $spec.NextHop, $spec.InterfaceIndex
    Invoke-RoutePlan -Plan $plan -Description "Changed route $(Format-RouteText $route)."
    if (Select-RouteByKey -Key $key) { Select-EditorRoute }
}

function Remove-SelectedRoute {
    if (-not $script:Context.IsAdmin) { throw 'Deleting routes requires administrator rights.' }
    $routes = @($script:Ui.dgRoutes.SelectedItems)
    if (-not $routes.Count) { return }

    $list = ($routes | Select-Object -First 20 | ForEach-Object { '  {0}  ({1})' -f (Format-RouteText $_), $_.Store }) -join "`r`n"
    if ($routes.Count -gt 20) { $list += "`r`n  … and $($routes.Count - 20) more" }
    $message = "Delete {0} route(s)?`r`n`r`n{1}" -f $routes.Count, $list
    $automatic = @($routes | Where-Object { $_.Origin -ne 'Static' }).Count
    if ($automatic) { $message += "`r`n`r`n$automatic of them were created by Windows (system, DHCP or router advertisement) and may come back." }
    if ($routes | Where-Object { $_.PrefixLength -eq 0 }) { $message += "`r`n`r`nDeleting a default route can interrupt network connections, including remote sessions." }
    if (-not (Confirm-Action -Message $message -Kind Warning)) { return }

    $editKey = if ($script:EditRoute) { $script:EditRoute.RouteKey } else { $null }
    Invoke-RoutePlan -Plan @(Get-PSToolsRouteRemovePlan -Route $routes) -Description ('Deleted {0} route(s).' -f $routes.Count)
    if ($editKey -and -not ($script:AllRoutes | Where-Object { $_.RouteKey -eq $editKey })) { Clear-Editor }
}

function Copy-RouteCommand {
    $routes = @($script:Ui.dgRoutes.SelectedItems)
    if (-not $routes.Count) { $routes = @($script:Routes) }
    if (-not $routes.Count) { return }
    $lines = Get-PSToolsRouteCommand -Operation @(Get-PSToolsRouteCopyPlan -Route $routes) -Syntax (Get-CommandSyntax)
    Set-ClipboardText ($lines -join [Environment]::NewLine)
    $script:Ui.txtStatus.Text = 'Commands for {0} route(s) copied to the clipboard ({1} syntax).' -f $routes.Count, (Get-CommandSyntax)
}

#endregion

#region Backup / restore

function Save-RouteBackup {
    $routes = @(Get-RouteTable -AddressFamily IPv4, IPv6 | Where-Object { $_.IsPersistent })
    if (-not $routes.Count) {
        Show-PSToolsMessage -Message 'There are no persistent routes to back up (IPv4 and IPv6). Routes from DHCP, router advertisements and temporary routes are not saved.' | Out-Null
        return
    }

    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter   = 'Route backup (*.json)|*.json|All files (*.*)|*.*'
    $dialog.FileName = 'Routes_{0}_{1:yyyyMMdd_HHmm}.json' -f $env:COMPUTERNAME, (Get-Date)
    if (-not $dialog.ShowDialog()) { return }

    $data = [ordered]@{
        Format       = $BackupFormat
        Version      = 1
        ComputerName = $env:COMPUTERNAME
        Created      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Routes       = @($routes | ForEach-Object {
            [ordered]@{
                AddressFamily     = $_.AddressFamily
                DestinationPrefix = $_.DestinationPrefix
                NextHop           = $_.NextHop
                InterfaceAlias    = $_.InterfaceAlias
                RouteMetric       = $_.RouteMetric
            }
        })
    }
    $json = ConvertTo-Json -InputObject $data -Depth 5
    [System.IO.File]::WriteAllText($dialog.FileName, $json, (New-Object System.Text.UTF8Encoding($false)))
    $text = 'Backup of {0} persistent route(s) saved: {1}' -f $routes.Count, $dialog.FileName
    Add-LogLine $text
    $script:Ui.txtStatus.Text = $text
}

function Restore-RouteBackup {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Route backup (*.json)|*.json|All files (*.*)|*.*'
    if (-not $dialog.ShowDialog()) { return }

    try {
        $data = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($dialog.FileName)) -ErrorAction Stop
    }
    catch {
        throw "The file could not be read as a route backup: $($_.Exception.Message)"
    }
    if ($data.Format -ne $BackupFormat -or $null -eq $data.Routes) { throw 'The file is not a PSTools route backup.' }

    $plan  = @(Get-PSToolsRouteRestorePlan -Route @($data.Routes))
    $add   = @($plan | Where-Object { $_.Action -eq 'Add' })
    $other = @($plan | Where-Object { $_.Action -ne 'Add' })

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('Backup of {0}, {1}: {2} route(s).' -f $data.ComputerName, $data.Created, $plan.Count))
    $lines.Add('')
    foreach ($item in $add | Select-Object -First 20) {
        $line = "  + {0} via {1} on '{2}' (metric {3})" -f $item.DestinationPrefix, $item.NextHopDisplay, $item.InterfaceAlias, $item.RouteMetric
        if ($item.Reason) { $line += "  – $($item.Reason)" }
        $lines.Add($line)
    }
    if ($add.Count -gt 20) { $lines.Add("  … and $($add.Count - 20) more to add") }
    foreach ($item in $other | Select-Object -First 15) {
        $lines.Add(("  {0} {1} via {2}: {3}" -f $(if ($item.Action -eq 'Exists') { '=' } else { '!' }), $item.DestinationPrefix, $item.NextHopDisplay, $item.Reason))
    }
    if ($other.Count -gt 15) { $lines.Add("  … and $($other.Count - 15) more skipped") }
    $summary = $lines -join "`r`n"

    if (-not $add.Count) {
        Show-PSToolsMessage -Message "$summary`r`n`r`nThere is nothing to add." | Out-Null
        return
    }

    # One plan per route: a failing route must not roll back the others.
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($item in $add) {
        $spec = [pscustomobject]@{
            AddressFamily     = $item.AddressFamily
            DestinationPrefix = $item.DestinationPrefix
            NextHop           = $item.NextHop
            IsOnLink          = $item.NextHopDisplay -eq 'On-link'
            InterfaceIndex    = $item.InterfaceIndex
            InterfaceAlias    = $item.InterfaceAlias
            InterfaceState    = $item.InterfaceState
            RouteMetric       = $item.RouteMetric
            Persistent        = $true
        }
        $plans.Add(@(Get-PSToolsRouteChangePlan -Spec $spec))
    }

    if (-not $script:Context.IsAdmin) {
        $question = "$summary`r`n`r`nAdding routes requires administrator rights. Copy the commands to the clipboard instead?"
        if (Confirm-Action -Message $question) {
            $commands = foreach ($routePlan in $plans) { Get-PSToolsRouteCommand -Operation $routePlan -Syntax (Get-CommandSyntax) }
            Set-ClipboardText ($commands -join [Environment]::NewLine)
        }
        return
    }

    if (-not (Confirm-Action -Message "$summary`r`n`r`nAdd $($add.Count) route(s) as persistent routes?")) { return }

    $ok = 0
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($routePlan in $plans) {
        foreach ($line in (Get-PSToolsRouteCommand -Operation $routePlan)) { Add-LogLine "> $line" }
        try {
            Invoke-PSToolsRouteOperation -Operation $routePlan -Confirm:$false
            $ok++
        }
        catch {
            $failed.Add($_.Exception.Message)
            Add-LogLine "[Error] $($_.Exception.Message)"
        }
    }
    Update-RouteView
    $text = 'Restore: {0} route(s) added, {1} failed.' -f $ok, $failed.Count
    Add-LogLine $text
    $script:Ui.txtStatus.Text = $text
    if ($failed.Count) {
        $script:Ui.expLog.IsExpanded = $true
        Show-PSToolsMessage -Kind Warning -Message ("$text`r`n`r`n" + (($failed | Select-Object -First 10) -join "`r`n")) | Out-Null
    }
}

#endregion

#region Interface metrics

function Update-InterfaceEditor {
    if ($script:Loading) { return }
    $ui = $script:Ui
    $interface = $ui.dgInterfaces.SelectedItem
    if ($interface) {
        $ui.grpInterfaceMetric.Header = "Interface metric – $($interface.InterfaceAlias) ($($script:Family))"
        $ui.cmbIfMetric.Text = [string]$interface.InterfaceMetric
    }
    else {
        $ui.grpInterfaceMetric.Header = 'Interface metric'
    }
    Update-InterfaceCommand
    Update-Buttons
}

function Get-InterfaceMetricInput {
    $metric = 0
    if (-not [int]::TryParse($script:Ui.cmbIfMetric.Text.Trim(), [ref]$metric) -or $metric -lt 1 -or $metric -gt 9999) {
        throw 'The interface metric must be a number between 1 and 9999.'
    }
    return $metric
}

function Update-InterfaceCommand {
    $ui = $script:Ui
    $interface = $ui.dgInterfaces.SelectedItem
    if (-not $interface) { $ui.txtIfCommand.Text = '# Select an interface.'; return }
    $automatic = Get-PSToolsInterfaceMetricCommand -InterfaceAlias $interface.InterfaceAlias -AddressFamily $script:Family -Automatic
    try {
        $fixed = Get-PSToolsInterfaceMetricCommand -InterfaceAlias $interface.InterfaceAlias -AddressFamily $script:Family -Metric (Get-InterfaceMetricInput)
    }
    catch {
        $fixed = "# $($_.Exception.Message)"
    }
    $ui.txtIfCommand.Text = $fixed + [Environment]::NewLine + $automatic
}

function Set-InterfaceMetric {
    param([switch]$Automatic)
    if (-not $script:Context.IsAdmin) { throw 'Changing the interface metric requires administrator rights.' }
    $interface = $script:Ui.dgInterfaces.SelectedItem
    if (-not $interface) { throw 'Select an interface first.' }

    if ($Automatic) {
        Add-LogLine ('> ' + (Get-PSToolsInterfaceMetricCommand -InterfaceAlias $interface.InterfaceAlias -AddressFamily $script:Family -Automatic))
        Set-PSToolsInterfaceMetric -InterfaceIndex $interface.InterfaceIndex -AddressFamily $script:Family -Automatic -Confirm:$false
        $text = "Interface '$($interface.InterfaceAlias)' ($($script:Family)) uses the automatic metric."
    }
    else {
        $metric = Get-InterfaceMetricInput
        Add-LogLine ('> ' + (Get-PSToolsInterfaceMetricCommand -InterfaceAlias $interface.InterfaceAlias -AddressFamily $script:Family -Metric $metric))
        Set-PSToolsInterfaceMetric -InterfaceIndex $interface.InterfaceIndex -AddressFamily $script:Family -Metric $metric -Confirm:$false
        $text = "Interface metric of '$($interface.InterfaceAlias)' ($($script:Family)) set to $metric."
    }
    Update-RouteView
    Add-LogLine $text
    $script:Ui.txtStatus.Text = $text
}

#endregion

#region Snapshots

function New-SnapshotEntry {
    param($Source)
    $routes = @($Source.Routes)
    [pscustomobject]@{
        Name         = [string]$Source.Name
        Time         = [string]$Source.Time
        ComputerName = [string]$Source.ComputerName
        IPv4Count    = @($routes | Where-Object { $_.AddressFamily -eq 'IPv4' -and -not $_.IsSystem }).Count
        IPv6Count    = @($routes | Where-Object { $_.AddressFamily -eq 'IPv6' -and -not $_.IsSystem }).Count
        Routes       = $routes
    }
}

function Import-RouteSnapshots {
    foreach ($entry in (Read-UserDataSafe -Name $SnapshotDataName) | Select-Object -First $SnapshotMax) {
        if ($entry.Name -and $null -ne $entry.Routes) { $script:Snapshots.Add((New-SnapshotEntry $entry)) }
    }
}

function Save-RouteSnapshots {
    $data = @($script:Snapshots | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Time = $_.Time; ComputerName = $_.ComputerName; Routes = @($_.Routes) }
    })
    Save-UserDataSafe -Name $SnapshotDataName -Data $data
}

function Get-CurrentSnapshotRoutes {
    return ,@(Get-RouteTable -AddressFamily IPv4, IPv6 -IncludeSystem | ConvertTo-PSToolsRouteSnapshotEntry)
}

function New-RouteSnapshot {
    $ui   = $script:Ui
    $time = Get-Date
    $name = $ui.txtSnapshotName.Text.Trim()
    if (-not $name) { $name = 'Snapshot {0:yyyy-MM-dd HH:mm}' -f $time }

    $entry = New-SnapshotEntry ([pscustomobject]@{
        Name         = $name
        Time         = '{0:yyyy-MM-dd HH:mm:ss}' -f $time
        ComputerName = $env:COMPUTERNAME
        Routes       = Get-CurrentSnapshotRoutes
    })
    $script:Snapshots.Insert(0, $entry)
    while ($script:Snapshots.Count -gt $SnapshotMax) { $script:Snapshots.RemoveAt($script:Snapshots.Count - 1) }
    Save-RouteSnapshots

    $ui.txtSnapshotName.Text = ''
    $ui.dgSnapshots.SelectedItem = $entry
    $text = "Snapshot '$name' taken: $($entry.IPv4Count) IPv4 and $($entry.IPv6Count) IPv6 routes (without system routes)."
    Add-LogLine $text
    $ui.txtStatus.Text = $text
}

function Compare-SnapshotWithCurrent {
    $snapshot = $script:Ui.dgSnapshots.SelectedItem
    if (-not $snapshot) { return }
    $script:LastComparison = @{
        Reference     = @($snapshot.Routes)
        Difference    = Get-CurrentSnapshotRoutes
        ReferenceName = $snapshot.Name
        DifferenceName = 'now'
    }
    Show-Comparison
}

function Compare-TwoSnapshots {
    $selected = @($script:Ui.dgSnapshots.SelectedItems | Sort-Object -Property Time)
    if ($selected.Count -ne 2) { throw 'Select exactly two snapshots (Ctrl+click).' }
    $script:LastComparison = @{
        Reference      = @($selected[0].Routes)
        Difference     = @($selected[1].Routes)
        ReferenceName  = $selected[0].Name
        DifferenceName = $selected[1].Name
    }
    Show-Comparison
}

function Show-Comparison {
    $ui = $script:Ui
    $comparison = $script:LastComparison
    if (-not $comparison) { return }
    $includeSystem = [bool]$ui.chkDiffSystem.IsChecked
    $diff = @(Compare-PSToolsRouteSnapshot -Reference $comparison.Reference -Difference $comparison.Difference -IncludeSystem:$includeSystem)
    $ui.dgDiff.ItemsSource = $diff

    $counts = foreach ($change in 'Added', 'Removed', 'Changed') { '{0} {1}' -f @($diff | Where-Object { $_.Change -eq $change }).Count, $change.ToLowerInvariant() }
    $scope  = if ($includeSystem) { '' } else { ' System routes are not compared.' }
    $ui.txtDiffSummary.Text = $(if ($diff.Count) {
        "'{0}' → '{1}': {2}.{3}" -f $comparison.ReferenceName, $comparison.DifferenceName, ($counts -join ', '), $scope
    } else {
        "'{0}' → '{1}': no differences.{2}" -f $comparison.ReferenceName, $comparison.DifferenceName, $scope
    })
}

function Remove-RouteSnapshot {
    $selected = @($script:Ui.dgSnapshots.SelectedItems)
    if (-not $selected.Count) { return }
    if (-not (Confirm-Action -Message ('Delete {0} snapshot(s)?' -f $selected.Count))) { return }
    foreach ($entry in $selected) { [void]$script:Snapshots.Remove($entry) }
    Save-RouteSnapshots
}

#endregion
