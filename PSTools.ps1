#Requires -Version 5.1
<#
.SYNOPSIS
PSTools main window: discovers all tools below .\Tools and hosts their pages.

.DESCRIPTION
Portable WPF toolbox for Windows PowerShell 5.1. Tools are plugins: every folder
Tools\<Category>\<ToolName>\ with a tool.psd1 is shown automatically. See CLAUDE.md for the contract.

Start via Start-PSTools.cmd (ExecutionPolicy Bypass, STA), or manually:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\PSTools.ps1

.PARAMETER Tool
Optional tool id (e.g. 'Network/Find-ApipaDevice') to select at startup.
#>
[CmdletBinding()]
param(
    [string]$Tool
)

$ErrorActionPreference = 'Stop'
$AppRoot = $PSScriptRoot
$AppVersion = '0.3.0'

. (Join-Path $AppRoot 'Core\Core.ps1')
. (Join-Path $AppRoot 'Core\Gui.ps1')

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Error 'The GUI requires an STA thread. Start PSTools with Start-PSTools.cmd or powershell.exe -STA.'
    return
}

$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PSTools" Width="1150" Height="760" MinWidth="820" MinHeight="520"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
    <Window.Resources>
        <!-- Shared styles for all tool pages. Implicit styles apply automatically;
             keyed styles must be referenced with DynamicResource from pages. -->
        <Style TargetType="Button">
            <Setter Property="Padding" Value="12,4"/>
            <Setter Property="MinWidth" Value="80"/>
            <Setter Property="Margin" Value="0,0,6,0"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Margin" Value="0,4,16,4"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Margin" Value="0,4,16,4"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Padding" Value="0,0,8,0"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Padding" Value="3,2"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Padding" Value="5,3"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
        <Style TargetType="ProgressBar">
            <Setter Property="Height" Value="18"/>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="SelectionMode" Value="Extended"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#FFE5E5E5"/>
            <Setter Property="AlternatingRowBackground" Value="#FFF7F9FC"/>
            <Setter Property="RowHeight" Value="24"/>
        </Style>
        <Style x:Key="RefreshButtonStyle" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Content" Value="&#x27F3;"/>
            <Setter Property="FontSize" Value="15"/>
            <Setter Property="MinWidth" Value="0"/>
            <Setter Property="Width" Value="32"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Margin" Value="6,0,0,0"/>
            <Setter Property="ToolTip" Value="Refresh"/>
        </Style>
        <Style x:Key="NoticeBarStyle" TargetType="Border">
            <Setter Property="Background" Value="#FFFFF4CE"/>
            <Setter Property="BorderBrush" Value="#FFE0C060"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="3"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="Margin" Value="0,0,0,8"/>
        </Style>
        <Style x:Key="LogBoxStyle" TargetType="TextBox">
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
        </Style>
    </Window.Resources>
    <DockPanel>
        <StatusBar DockPanel.Dock="Bottom">
            <StatusBarItem>
                <TextBlock x:Name="txtAdmin"/>
            </StatusBarItem>
            <StatusBarItem>
                <Button x:Name="btnElevate" Content="Restart as administrator" Padding="8,1" Margin="0"/>
            </StatusBarItem>
            <Separator/>
            <StatusBarItem>
                <TextBlock x:Name="txtInfo"/>
            </StatusBarItem>
        </StatusBar>
        <Grid>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="240" MinWidth="160"/>
                <ColumnDefinition Width="6"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <DockPanel Grid.Column="0" Margin="8,8,0,8">
                <Button DockPanel.Dock="Bottom" x:Name="btnReload" Content="Reload tools" Margin="0,6,0,0"
                        ToolTip="Scan the Tools folder again and reload all tool pages"/>
                <TreeView x:Name="tvTools" Padding="2,4"/>
            </DockPanel>
            <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" Background="Transparent"/>
            <DockPanel Grid.Column="2" Margin="6,8,10,8">
                <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
                    <TextBlock x:Name="txtToolName" FontSize="20" FontWeight="SemiBold"/>
                    <TextBlock x:Name="txtToolDescription" TextWrapping="Wrap" Margin="0,2,0,0"
                               Foreground="{DynamicResource {x:Static SystemColors.GrayTextBrushKey}}"/>
                </StackPanel>
                <ContentControl x:Name="ccTool" Focusable="False"/>
            </DockPanel>
        </Grid>
    </DockPanel>
</Window>
'@

#region Page loading

function New-PSToolsMessageElement {
    # Simple element that shows a (multi-line) message in the tool area.
    param([string]$Text, [switch]$IsError)
    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $Text
    $box.IsReadOnly = $true
    $box.TextWrapping = 'Wrap'
    $box.BorderThickness = 0
    $box.Background = [System.Windows.Media.Brushes]::Transparent
    if ($IsError) { $box.Foreground = [System.Windows.Media.Brushes]::Firebrick }
    return $box
}

function New-PSToolsPage {
    <#
    Loads a tool page in its own dynamic module: Core, Gui, the logic file and Page.ps1 are
    dot-sourced into the module, so the page has private $script: state and its event handlers
    keep access to all functions.
    #>
    param([Parameter(Mandatory)]$ToolInfo)

    if ($ToolInfo.LoadError) {
        return New-PSToolsMessageElement -IsError -Text "This tool could not be loaded:`r`n$($ToolInfo.LoadError)`r`n`r`nFolder: $($ToolInfo.ToolRoot)"
    }
    if (-not $ToolInfo.HasPage) {
        return New-PSToolsMessageElement -Text ("This tool has no GUI page (Page.ps1). Use it from the console:`r`n`r`n" +
            ". '$($ToolInfo.LogicFile)'`r`nGet-Help $($ToolInfo.Command) -Full")
    }

    $moduleBody = {
        param($CoreFile, $GuiFile, $LogicFile, $PageFile)
        . $CoreFile
        . $GuiFile
        . $LogicFile
        . $PageFile
        Export-ModuleMember
    }

    try {
        $moduleName = 'PSToolsPage_' + ($ToolInfo.Id -replace '[^A-Za-z0-9]', '_')
        $module = New-Module -Name $moduleName -ScriptBlock $moduleBody -ArgumentList @(
            (Join-Path $AppRoot 'Core\Core.ps1'),
            (Join-Path $AppRoot 'Core\Gui.ps1'),
            $ToolInfo.LogicFile,
            $ToolInfo.PageFile
        )

        $context = [pscustomobject]@{
            PSTypeName = 'PSTools.PageContext'
            AppRoot    = $AppRoot
            ToolRoot   = $ToolInfo.ToolRoot
            Tool       = $ToolInfo
            Window     = $script:Window
            IsAdmin    = $script:IsAdmin
        }
        $element = & $module { param($ctx) Initialize-ToolPage -Context $ctx } $context
        if ($element -is [array]) { $element = $element | Where-Object { $_ -is [System.Windows.UIElement] } | Select-Object -Last 1 }
        if (-not ($element -is [System.Windows.UIElement])) {
            throw 'Initialize-ToolPage did not return a WPF element.'
        }
        return $element
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.InvocationInfo -and $_.InvocationInfo.ScriptName) {
            $detail += "`r`n  at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
        }
        return New-PSToolsMessageElement -IsError -Text "The page of '$($ToolInfo.Name)' failed to load:`r`n$detail"
    }
}

#endregion

#region Main window logic

function Update-PSToolsToolTree {
    # (Re)scans the Tools folder and fills the tree view: categories -> tools.
    param([string]$SelectId)

    $script:PageCache = @{}
    $script:Ui.ccTool.Content = $null
    $tree = $script:Ui.tvTools
    $tree.Items.Clear()

    $tools = @(Get-PSToolsTool -Root $AppRoot)
    $firstToolItem = $null
    $selectItem    = $null

    $groups = $tools | Group-Object -Property Category |
        Sort-Object -Property @{ Expression = { $_.Group[0].CategoryOrder } }, Name
    foreach ($group in $groups) {
        $categoryItem = New-Object System.Windows.Controls.TreeViewItem
        $categoryItem.Header     = $group.Name
        $categoryItem.FontWeight = 'SemiBold'
        $categoryItem.IsExpanded = $true
        $categoryItem.Margin     = '0,2,0,2'

        foreach ($toolInfo in ($group.Group | Sort-Object -Property Order, Name)) {
            $toolItem = New-Object System.Windows.Controls.TreeViewItem
            $toolItem.Header     = $toolInfo.Name
            $toolItem.FontWeight = 'Normal'
            $toolItem.Tag        = $toolInfo
            $toolItem.ToolTip    = $(if ($toolInfo.LoadError) { $toolInfo.LoadError } elseif ($toolInfo.Description) { $toolInfo.Description } else { $null })
            if ($toolInfo.LoadError) { $toolItem.Foreground = [System.Windows.Media.Brushes]::Firebrick }
            [void]$categoryItem.Items.Add($toolItem)

            if (-not $firstToolItem) { $firstToolItem = $toolItem }
            if ($SelectId -and $toolInfo.Id -eq $SelectId) { $selectItem = $toolItem }
        }
        [void]$tree.Items.Add($categoryItem)
    }

    $script:Ui.txtInfo.Text = 'PSTools {0}  |  {1} tool(s)  |  PowerShell {2}' -f $AppVersion, $tools.Count, $PSVersionTable.PSVersion

    if (-not $selectItem) { $selectItem = $firstToolItem }
    if ($selectItem) {
        $selectItem.IsSelected = $true
    }
    else {
        $script:Ui.txtToolName.Text = 'No tools found'
        $script:Ui.txtToolDescription.Text = "Add tool folders below $(Join-Path $AppRoot 'Tools')"
    }
}

function Show-PSToolsTool {
    # Shows the page of the selected tool (pages are created once and cached).
    param($ToolInfo)

    if (-not $ToolInfo) {
        $script:Ui.txtToolName.Text = 'PSTools'
        $script:Ui.txtToolDescription.Text = 'Select a tool on the left.'
        $script:Ui.ccTool.Content = $null
        return
    }

    $description = $ToolInfo.Description
    if ($ToolInfo.RequiresAdmin -and -not $script:IsAdmin) {
        $description += '  (Requires administrator rights – use "Restart as administrator".)'
    }
    $script:Ui.txtToolName.Text = $ToolInfo.Name
    $script:Ui.txtToolDescription.Text = $description

    if (-not $script:PageCache.ContainsKey($ToolInfo.Id)) {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            $script:PageCache[$ToolInfo.Id] = New-PSToolsPage -ToolInfo $ToolInfo
        }
        finally {
            $script:Window.Cursor = $null
        }
    }
    $script:Ui.ccTool.Content = $script:PageCache[$ToolInfo.Id]
}

function Restart-PSToolsElevated {
    # Starts a new elevated instance (UAC prompt) and closes this one.
    $selected = $script:Ui.tvTools.SelectedItem
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    if ($selected -and $selected.Tag) { $arguments += @('-Tool', ('"{0}"' -f $selected.Tag.Id)) }
    try {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs | Out-Null
        $script:Window.Close()
    }
    catch {
        # UAC prompt cancelled or not allowed.
        Show-PSToolsMessage -Message "Could not restart as administrator: $($_.Exception.Message)" -Kind Warning | Out-Null
    }
}

#endregion

try {
    $view = ConvertFrom-PSToolsXaml -Xaml $MainXaml
    $script:Window    = $view.Root
    $script:Ui        = $view.Controls
    $script:IsAdmin   = Test-PSToolsIsAdmin
    $script:PageCache = @{}

    if ($script:IsAdmin) {
        $script:Window.Title = 'PSTools (Administrator)'
        $script:Ui.txtAdmin.Text = 'Running as administrator'
        $script:Ui.btnElevate.Visibility = 'Collapsed'
    }
    else {
        $script:Ui.txtAdmin.Text = 'Standard user'
    }

    $script:Ui.tvTools.Add_SelectedItemChanged({
        Invoke-PSToolsUiAction {
            $item = $script:Ui.tvTools.SelectedItem
            if ($item -and $item.Tag) { Show-PSToolsTool -ToolInfo $item.Tag }
        }
    })
    $script:Ui.btnReload.Add_Click({
        Invoke-PSToolsUiAction {
            $selected = $script:Ui.tvTools.SelectedItem
            $id = if ($selected -and $selected.Tag) { $selected.Tag.Id } else { $null }
            Update-PSToolsToolTree -SelectId $id
        }
    })
    $script:Ui.btnElevate.Add_Click({ Invoke-PSToolsUiAction { Restart-PSToolsElevated } })

    $script:Window.Add_Loaded({ Invoke-PSToolsUiAction { Update-PSToolsToolTree -SelectId $Tool } })

    [void]$script:Window.ShowDialog()
}
catch {
    $message = "PSTools could not be started:`r`n$($_.Exception.Message)"
    if ($_.InvocationInfo) { $message += "`r`n  at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" }
    try { Show-PSToolsMessage -Message $message -Kind Error | Out-Null } catch { Write-Error $message }
}
