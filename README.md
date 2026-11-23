# PSTools

A portable PowerShell toolbox with a WPF GUI for Windows diagnostics: network, system, and more.

Copy the folder, double-click `Start-PSTools.cmd`, done. There is nothing to install: no modules from the
PowerShell Gallery, no compiled DLLs, and no admin rights needed for most tools.

- **Portable**: runs from a USB stick or a network share. Settings and history go to `UserData/` next to the tools.
- **Built-in components only**: Windows PowerShell 5.1 and .NET Framework, as shipped with Windows 10/11 and Windows Server 2016+.
- **Offline**: tools do not use the network unless that is their purpose (for example a port check).
  Reference data such as the MAC vendor list ships in `Data/`.
- **GUI and console**: every tool is a plain PowerShell function that returns objects. The GUI is a thin
  layer on top, so you can also use each tool in scripts.

## Quick start

1. Copy the `PSTools` folder anywhere (local disk, USB stick, share).
2. Double-click **`Start-PSTools.cmd`**.
3. Pick a tool on the left.

| Command | Effect |
|---|---|
| `Start-PSTools.cmd` | Starts the GUI without a console window. |
| `Start-PSTools.cmd debug` | Starts the GUI and keeps the console open (shows errors and warnings). |

The launcher runs `powershell.exe -ExecutionPolicy Bypass -STA` for this process only. It does not change
the machine's execution policy.

**Administrator rights:** PSTools starts as a standard user. Actions that need admin rights (for example
adding a firewall rule or an IP address) are disabled and have a tooltip. Click
**Restart as administrator** in the status bar to restart PSTools elevated; the selected tool stays open.

## Tools

### Network

#### Find APIPA Device

Finds devices that gave themselves a link-local address (`169.254.x.x`) because no DHCP server answered.
This is typical for factory-new or reset devices such as cameras, PLCs, printers or access points
connected straight to the PC.

- Pings the subnet in parallel and reads the ARP cache, so it also finds devices that do not answer ping.
- Shows the MAC address and the vendor (offline lookup in the IEEE OUI list).
- If the PC has no APIPA address itself, shows the `netsh` command to add one, plus a button that adds it (admin).
- A full `/16` scan takes about 2 minutes. You can stop it after the first hit.

```powershell
. .\Tools\Network\Find-ApipaDevice\Find-ApipaDevice.ps1
Find-ApipaDevice -InterfaceAlias 'Ethernet 2' -StopOnFirst
```

#### DHCP Server

A minimal DHCP server for debugging. It gives addresses from a pool to devices on one adapter, for example a
device connected straight to the PC that expects DHCP.

- Supports DISCOVER/OFFER, REQUEST/ACK/NAK, DECLINE, RELEASE, INFORM and relay agents. Optional router,
  DNS servers and domain name.
- Shows leases live, with MAC vendor and host name. Logs every packet.
- Safety checks: it refuses to start on a DHCP-assigned address, and it stops if another DHCP server answers.
- Needs a static IPv4 address on the adapter and an inbound firewall rule for UDP 67. The page offers both
  as one-click actions (admin).

> Never run it on a production network.

```powershell
. .\Tools\Network\Start-DhcpDebugServer\Start-DhcpDebugServer.ps1
Start-DhcpDebugServer -InterfaceAlias 'Ethernet 2' -Verbose      # stop with Ctrl+C
```

#### Port Check

Checks whether TCP or UDP ports on a host are reachable. It distinguishes **open**, **closed** (reset or ICMP
port unreachable) and **filtered** (no answer).

- Accepts single ports and ranges (`80,443,8000-8010`), with presets for common services (RDP, SMB, AD,
  SQL, mail, printers, …).
- For UDP, it sends real requests for DNS, NTP, NetBIOS and SNMP, so those services answer.
- Shows the source address and interface Windows uses to reach the target.
- Keeps the last 20 checks. Double-click an entry to run it again.

```powershell
. .\Tools\Network\Test-PortConnection\Test-PortConnection.ps1
Test-PortConnection -ComputerName server01 -Port 3389
Test-PortConnection dc01 -Port 53 -Protocol TCP, UDP | Format-Table
```

## Using the tools from the console

Each tool is one PowerShell function in `Tools\<Category>\<Tool>\<Tool>.ps1`. Dot-source the file, then
call the function:

```powershell
. .\Tools\Network\Test-PortConnection\Test-PortConnection.ps1
Get-Help Test-PortConnection -Full
Test-PortConnection server01 -Port 443 | Export-Csv result.csv -NoTypeInformation
```

Each function returns objects, never formatted text, and reports progress with `Write-Progress`. Use
`-Verbose` for details.

## Data and privacy

| Folder | Content |
|---|---|
| `Data/` | Shipped reference data, e.g. `oui.txt` (MAC address vendors from the IEEE registry). |
| `UserData/` | Created at runtime: history and last inputs as JSON. Not in git. Delete it to reset PSTools. |

PSTools writes nothing to the registry or the user profile. If the folder is read-only (for example a
share), history is kept in memory for the session and a warning appears in the tool's log.

### Updating the MAC vendor list

`Data/oui.txt` is generated from the IEEE registries (MA-L, MA-M, MA-S). This is the only script that
downloads anything, and it runs only when you start it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Data\Update-OuiTable.ps1
```

## Folder layout

```
PSTools/
├── Start-PSTools.cmd          # launcher (Bypass, STA, hidden console)
├── PSTools.ps1                # main window: discovers and hosts tools
├── Core/                      # shared helpers (network, OUI lookup, storage, GUI)
├── Data/                      # shipped data files and their update scripts
├── UserData/                  # created at runtime, not in git
└── Tools/
    └── <Category>/
        ├── category.psd1      # optional: name and sort order of the category
        └── <ToolName>/
            ├── tool.psd1      # manifest
            ├── <ToolName>.ps1 # logic: the public function (usable from the console)
            ├── Page.xaml      # GUI: WPF UserControl
            └── Page.ps1       # GUI: Initialize-ToolPage
```

## Adding a tool

Tools are plugins. PSTools scans `Tools/*/*/tool.psd1` at startup, so to add a tool you only drop a folder
in. Nothing is registered in `PSTools.ps1`. **Reload tools** in the main window rescans the folder without
a restart. Folders whose names start with `_` are ignored, which is useful for drafts.

Minimal `tool.psd1`:

```powershell
@{
    Name          = 'My Tool'
    Description   = 'One sentence shown in the tool header.'
    Command       = 'Get-Something'      # public function in <ToolName>.ps1
    Order         = 40                   # sort order within the category
    RequiresAdmin = $false
    Version       = '1.0.0'
}
```

Most important rules (all rules are in [CLAUDE.md](CLAUDE.md)):

- Windows PowerShell 5.1 syntax only: no `??`, `?.`, ternary operator, `&&` or `ForEach-Object -Parallel`.
- Save `.ps1` and `.psd1` files as **UTF-8 with BOM**. Without the BOM, PowerShell 5.1 reads them as ANSI
  and characters such as `–` or `…` break.
- The logic returns `[pscustomobject]`s with a `PSTypeName`, streams results, and uses `Write-Progress`,
  `Write-Warning` and `Write-Verbose`. The GUI picks these streams up automatically.
- Long-running work in the GUI runs in a background runspace (`Start-PSToolsJob`) with Start, Cancel, a
  progress bar and a status line. The UI thread is never blocked.
- Use the shared styles of the main window. Do not hard-code colors or fonts.

## Development

The repository follows **git flow**:

- `main` contains released versions only. Every release is tagged, e.g. `0.3.0`.
- `develop` is the integration branch.
- New work happens on `feature/<name>` branches and is merged into `develop` with `--no-ff`.
- `release/<version>` prepares a release. `hotfix/<version>` fixes a released version.

The toolbox version is `$AppVersion` in `PSTools.ps1`. Each tool has its own `Version` in `tool.psd1`.
Details and plain-git commands are in [CLAUDE.md](CLAUDE.md).

## Troubleshooting

| Problem | Solution |
|---|---|
| Nothing happens on double-click | Run `Start-PSTools.cmd debug` to see the error in the console. |
| A tool shows a red error instead of its page | The tool failed to load; the message shows file and line. Other tools still work. |
| Garbled characters or parser errors after editing a file | The file was saved without a BOM. Save it again as "UTF-8 with BOM". |
| Downloaded ZIP: Windows warns about the files | Unblock the ZIP before extracting (Properties → Unblock), or run `Get-ChildItem -Recurse \| Unblock-File`. |
| An action button is disabled | It needs admin rights. Use **Restart as administrator** in the status bar. |
