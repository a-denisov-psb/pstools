#Requires -Version 5.1
# Local user data (history, last settings) stored as JSON below <PSTools>\UserData.
# The folder is created on demand and excluded from git (.gitignore). If it is not writable
# (e.g. PSTools runs from a read-only share), saving fails with a readable error and the caller
# keeps the data in memory only.

function Get-PSToolsUserDataPath {
    <#
    .SYNOPSIS
    Returns the full path of a user data file (<PSTools>\UserData\<Name>.json).

    .PARAMETER Name
    File name without extension, e.g. 'PortCheckHistory'. Letters, digits, '-', '_' and '.' only.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Name
    )
    return (Join-Path (Join-Path $PSToolsRoot 'UserData') ($Name + '.json'))
}

function Get-PSToolsUserData {
    <#
    .SYNOPSIS
    Reads a user data file and returns its objects (an array is enumerated). Returns nothing if the
    file does not exist; a damaged file causes a warning and returns nothing.

    .EXAMPLE
    $history = @(Get-PSToolsUserData -Name 'PortCheckHistory')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Name
    )

    $path = Get-PSToolsUserDataPath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return }

    try {
        $text = [System.IO.File]::ReadAllText($path)
        if (-not $text.Trim()) { return }
        $data = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        Write-Warning (("User data file '{0}' could not be read and is ignored: {1}") -f $path, $_.Exception.Message)
        return
    }
    # Windows PowerShell emits a JSON array as one object; foreach enumerates it.
    foreach ($item in $data) { $item }
}

function Save-PSToolsUserData {
    <#
    .SYNOPSIS
    Writes objects as JSON to a user data file. The file is replaced atomically, so a crash while
    saving never leaves a half-written file. Throws if the folder is not writable.

    .EXAMPLE
    Save-PSToolsUserData -Name 'PortCheckHistory' -InputObject $entries
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$InputObject,
        [ValidateRange(1, 20)][int]$Depth = 5
    )

    $path   = Get-PSToolsUserDataPath -Name $Name
    $folder = Split-Path -Parent $path
    $json   = ConvertTo-Json -InputObject @($InputObject | Where-Object { $null -ne $_ }) -Depth $Depth
    $temp   = $path + '.tmp'

    try {
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -ErrorAction Stop) }
        [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $path) {
            # [NullString]::Value: PowerShell would pass $null as '' (invalid path).
            [System.IO.File]::Replace($temp, $path, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temp, $path)
        }
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw "Could not save '$path': $($inner.Message)"
    }
}
