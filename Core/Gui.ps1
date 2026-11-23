#Requires -Version 5.1
# GUI helpers (WPF): XAML loading, background jobs, dialogs, DataGrid actions.
# Only dot-sourced by the main window and tool pages, never by logic files.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

#region XAML

function ConvertFrom-PSToolsXaml {
    <#
    .SYNOPSIS
    Loads XAML (file or string) and returns the root element plus all named controls.

    .DESCRIPTION
    Removes designer-only attributes (x:Class, mc:Ignorable, d:*) so XAML from Visual Studio can be used.
    Returns an object with Root (the element) and Controls (hashtable: x:Name -> element).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Text')][string]$Xaml
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $Xaml = [System.IO.File]::ReadAllText($Path)
    }
    $Xaml = $Xaml -replace '\sx:Class="[^"]*"', '' -replace '\smc:Ignorable="[^"]*"', '' -replace '\sd:\w+="[^"]*"', ''

    [xml]$document = $Xaml
    $reader = New-Object System.Xml.XmlNodeReader $document
    try {
        $root = [Windows.Markup.XamlReader]::Load($reader)
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw "XAML could not be loaded: $($inner.Message)"
    }

    $controls = @{}
    $xamlNs   = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $nodes    = $document.SelectNodes("//*[@*[local-name()='Name']]")
    foreach ($node in $nodes) {
        $name = $node.GetAttribute('Name', $xamlNs)
        if (-not $name) { $name = $node.GetAttribute('Name') }
        if ($name) {
            $element = $root.FindName($name)
            if ($element) { $controls[$name] = $element }
        }
    }

    [pscustomobject]@{ Root = $root; Controls = $controls }
}

#endregion

#region Dialogs and safe UI actions

function Show-PSToolsMessage {
    <#
    .SYNOPSIS
    Shows a WPF message box. Returns the clicked button.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Title = 'PSTools',
        [ValidateSet('Info', 'Warning', 'Error', 'Question')][string]$Kind = 'Info',
        [System.Windows.MessageBoxButton]$Buttons = 'OK'
    )
    $icon = switch ($Kind) {
        'Info'     { [System.Windows.MessageBoxImage]::Information }
        'Warning'  { [System.Windows.MessageBoxImage]::Warning }
        'Error'    { [System.Windows.MessageBoxImage]::Error }
        'Question' { [System.Windows.MessageBoxImage]::Question }
    }
    return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $icon)
}

function Invoke-PSToolsUiAction {
    <#
    .SYNOPSIS
    Runs a script block from an event handler and shows any error in a message box instead of crashing.

    .EXAMPLE
    $button.Add_Click({ Invoke-PSToolsUiAction { Start-Scan } })
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][scriptblock]$Action)

    try {
        & $Action
    }
    catch {
        Show-PSToolsMessage -Message $_.Exception.Message -Kind Error | Out-Null
    }
}

#endregion

#region Background jobs

function Start-PSToolsJob {
    <#
    .SYNOPSIS
    Runs a tool command in a background runspace and streams its output to the UI thread.

    .DESCRIPTION
    The script files are dot-sourced into a fresh runspace, then the command is invoked with the
    given parameters. A DispatcherTimer polls the runspace and calls the callbacks on the UI thread:
      OnOutput   param($item)            for every output object (streamed)
      OnProgress param($progressRecord)  for the latest Write-Progress record
      OnMessage  param($kind, $text)     for Write-Warning / Write-Verbose / Write-Information / errors
      OnCompleted param($result)         once; $result has State (Completed/Stopped/Failed), Error, Duration
    Returns a job object for Stop-PSToolsJob.

    .EXAMPLE
    $job = Start-PSToolsJob -ScriptFile $Context.Tool.LogicFile -Command 'Find-ApipaDevice' `
              -Parameters @{ TimeoutMs = 300 } -OnOutput { param($item) $results.Add($item) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ScriptFile,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{},
        [scriptblock]$OnOutput,
        [scriptblock]$OnProgress,
        [scriptblock]$OnMessage,
        [scriptblock]$OnCompleted,
        [int]$IntervalMs = 150
    )

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    $bootstrap = @'
param($__Files, $__Command, $__Parameters)
# Load the scripts with default preferences first (module imports would otherwise flood the verbose stream).
foreach ($__file in $__Files) { . $__file }
$ProgressPreference    = 'Continue'
$VerbosePreference     = 'Continue'
$InformationPreference = 'Continue'
& $__Command @__Parameters
'@
    [void]$ps.AddScript($bootstrap).AddArgument($ScriptFile).AddArgument($Command).AddArgument($Parameters)

    $inputData  = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $outputData = New-Object 'System.Management.Automation.PSDataCollection[psobject]'
    $inputData.Complete()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($IntervalMs)

    $job = [pscustomobject]@{
        PSTypeName    = 'PSTools.Job'
        PowerShell    = $ps
        Runspace      = $runspace
        Handle        = $null
        Output        = $outputData
        Timer         = $timer
        OutputIndex   = 0
        ProgressIndex = 0
        WarningIndex  = 0
        VerboseIndex  = 0
        InfoIndex     = 0
        ErrorIndex    = 0
        OnOutput      = $OnOutput
        OnProgress    = $OnProgress
        OnMessage     = $OnMessage
        OnCompleted   = $OnCompleted
        StopRequested = $false
        IsFinished    = $false
        Stopwatch     = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $timer.Tag = $job
    $timer.Add_Tick({
        param($sender, $e)
        Update-PSToolsJob -Job $sender.Tag
    })

    $job.Handle = $ps.BeginInvoke($inputData, $outputData)
    $timer.Start()
    return $job
}

function Stop-PSToolsJob {
    <#
    .SYNOPSIS
    Requests cancellation of a job started with Start-PSToolsJob. OnCompleted is called with State 'Stopped'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Job)

    if ($Job.IsFinished -or $Job.StopRequested) { return }
    $Job.StopRequested = $true
    [void]$Job.PowerShell.BeginStop($null, $null)
}

function Update-PSToolsJob {
    # Internal: called by the job's DispatcherTimer on the UI thread.
    param([Parameter(Mandatory)]$Job)

    if ($Job.IsFinished) { return }
    $isDone  = $Job.Handle.IsCompleted
    $streams = $Job.PowerShell.Streams

    try {
        while ($Job.OutputIndex -lt $Job.Output.Count) {
            $item = $Job.Output[$Job.OutputIndex]
            $Job.OutputIndex++
            if ($Job.OnOutput) { & $Job.OnOutput $item }
        }

        if ($Job.OnProgress -and $streams.Progress.Count -gt $Job.ProgressIndex) {
            $Job.ProgressIndex = $streams.Progress.Count
            & $Job.OnProgress $streams.Progress[$streams.Progress.Count - 1]
        }

        if ($Job.OnMessage) {
            while ($Job.WarningIndex -lt $streams.Warning.Count) {
                & $Job.OnMessage 'Warning' $streams.Warning[$Job.WarningIndex].Message
                $Job.WarningIndex++
            }
            while ($Job.VerboseIndex -lt $streams.Verbose.Count) {
                & $Job.OnMessage 'Verbose' $streams.Verbose[$Job.VerboseIndex].Message
                $Job.VerboseIndex++
            }
            while ($Job.InfoIndex -lt $streams.Information.Count) {
                & $Job.OnMessage 'Info' ([string]$streams.Information[$Job.InfoIndex].MessageData)
                $Job.InfoIndex++
            }
            while ($Job.ErrorIndex -lt $streams.Error.Count) {
                & $Job.OnMessage 'Error' $streams.Error[$Job.ErrorIndex].Exception.Message
                $Job.ErrorIndex++
            }
        }
    }
    catch {
        # A failing callback must not stop the polling loop.
        Write-Warning "Job callback failed: $($_.Exception.Message)"
    }

    if (-not $isDone) { return }

    $Job.IsFinished = $true
    $Job.Timer.Stop()
    $Job.Stopwatch.Stop()

    $errorMessage = $null
    try {
        [void]$Job.PowerShell.EndInvoke($Job.Handle)
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        if (-not ($inner -is [System.Management.Automation.PipelineStoppedException])) { $errorMessage = $inner.Message }
    }

    $state = [string]$Job.PowerShell.InvocationStateInfo.State
    if ($Job.StopRequested) { $state = 'Stopped' }
    elseif ($errorMessage) { $state = 'Failed' }
    elseif ($Job.PowerShell.InvocationStateInfo.Reason -and $state -eq 'Failed') {
        $errorMessage = $Job.PowerShell.InvocationStateInfo.Reason.Message
    }

    try { $Job.PowerShell.Dispose() } catch { }
    try { $Job.Runspace.Dispose() } catch { }

    if ($Job.OnCompleted) {
        try {
            & $Job.OnCompleted ([pscustomobject]@{
                State    = $state
                Error    = $errorMessage
                Duration = $Job.Stopwatch.Elapsed
            })
        }
        catch {
            Show-PSToolsMessage -Message "Completion handler failed: $($_.Exception.Message)" -Kind Error | Out-Null
        }
    }
}

#endregion

#region DataGrid helpers

function Copy-PSToolsGridSelection {
    <#
    .SYNOPSIS
    Copies the selected rows of a DataGrid (or all rows if none are selected) as tab-separated text.

    .PARAMETER Property
    Columns to copy, in this order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Controls.DataGrid]$Grid,
        [Parameter(Mandatory)][string[]]$Property
    )

    $rows = @($Grid.SelectedItems)
    if (-not $rows.Count) { $rows = @($Grid.Items) }
    if (-not $rows.Count) { return }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Property -join "`t")
    foreach ($row in $rows) {
        $lines.Add((($Property | ForEach-Object { [string]$row.$_ }) -join "`t"))
    }
    [System.Windows.Clipboard]::SetText($lines -join [Environment]::NewLine)
}

function Export-PSToolsGridCsv {
    <#
    .SYNOPSIS
    Asks for a file name and exports all rows of a DataGrid as CSV (culture-specific delimiter, UTF-8).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Windows.Controls.DataGrid]$Grid,
        [Parameter(Mandatory)][string[]]$Property,
        [string]$DefaultFileName = 'export.csv'
    )

    $rows = @($Grid.Items)
    if (-not $rows.Count) {
        Show-PSToolsMessage -Message 'There is nothing to export.' -Kind Info | Out-Null
        return
    }

    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter   = 'CSV file (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FileName = $DefaultFileName
    if (-not $dialog.ShowDialog()) { return }

    $rows | Select-Object -Property $Property |
        Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -UseCulture -Encoding UTF8
}

#endregion
