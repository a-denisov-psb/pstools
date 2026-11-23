# PSTools – project rules

Portable PowerShell toolbox with a WPF GUI for Windows diagnostics (network, system, …).
Copy the folder, double-click `Start-PSTools.cmd`, done. No installation, no modules from the gallery.

## Platform

- Windows PowerShell **5.1** only, .NET Framework, built-in Windows components only.
  No PowerShell 7 syntax (`??`, `?.`, ternary, `-Parallel`, `&&`), no external modules, no compiled DLLs.
- GUI: **WPF** (XAML loaded at runtime via `XamlReader`). No WinForms for new UI.
- Started with `-ExecutionPolicy Bypass -STA` by `Start-PSTools.cmd`. `Start-PSTools.cmd debug` keeps the console open.
- Tools must work without admin rights where possible. Actions that need admin are disabled
  (with a tooltip) when not elevated; the status bar offers "Restart as administrator".
- No network requests at runtime unless that is the tool's explicit purpose (e.g. data is shipped in `Data/`).
- Data a tool remembers (history, last inputs) goes to `UserData/` via `Get-PSToolsUserData` /
  `Save-PSToolsUserData`, never into the tool folder or the registry. Saving can fail (read-only share):
  catch it, keep the data in memory and log one warning.

## File encoding

- `.ps1` / `.psd1` files **must be UTF-8 with BOM**. Windows PowerShell 5.1 reads BOM-less files as ANSI,
  so characters like `–`, `…`, `⟳` break strings and cause parser errors. Check after creating a file:
  `Get-Content -Encoding Byte -TotalCount 3 <file>` must return `239 187 191`.
- XAML files can be plain UTF-8 (they are read with `ReadAllText`, which detects UTF-8).

## Language

- Chat with the user: German.
- Everything in the code base is **English**: UI texts, comments, comment-based help, messages, file names.

## Folder layout

```
PSTools/
├── Start-PSTools.cmd          # launcher (Bypass, STA, hidden console)
├── PSTools.ps1                # main window: discovers and hosts tools
├── Core/
│   ├── Core.ps1               # loads all non-GUI helpers (Common, Network, Oui, Storage)
│   ├── Common.ps1             # tool discovery, admin check, misc helpers
│   ├── Network.ps1            # adapters, ARP/neighbor table, IPv4/CIDR math
│   ├── Oui.ps1                # offline MAC vendor lookup (Data/oui.txt)
│   ├── Storage.ps1            # local user data as JSON in UserData/ (history, settings)
│   └── Gui.ps1                # XAML loading, background jobs, dialogs (GUI only)
├── Data/                      # shipped data files + their update scripts
├── UserData/                  # created at runtime, per installation; not in git (.gitignore)
└── Tools/
    └── <Category>/
        ├── category.psd1      # optional: @{ Name = 'Network'; Order = 10 }
        └── <ToolName>/        # one folder per tool, e.g. Find-ApipaDevice
            ├── tool.psd1      # manifest (required)
            ├── <ToolName>.ps1 # logic: the public function, CLI usable (required)
            ├── Page.xaml      # GUI: UserControl (required for GUI)
            └── Page.ps1       # GUI: defines Initialize-ToolPage (required for GUI)
```

Folders starting with `_` are ignored by discovery (use for drafts).

## Tool contract (plugin model)

The main window scans `Tools/*/*/tool.psd1` at startup. **Dropping a tool folder in is all it takes** –
never register tools in `PSTools.ps1`.

`tool.psd1`:
```powershell
@{
    Name          = 'Find APIPA Device'   # display name
    Description   = 'One sentence shown in the tool header.'
    Command       = 'Find-ApipaDevice'    # public function in <ToolName>.ps1
    Order         = 10                    # sort order within the category
    RequiresAdmin = $false
    Version       = '1.0.0'
}
```

Logic file `<ToolName>.ps1`:
- Dot-sources `Core/Core.ps1` relative to `$PSScriptRoot`, then defines **one public function** (`Verb-Noun`,
  approved verbs) with `[CmdletBinding()]`, typed and validated parameters and **comment-based help in English**
  inside the function.
- Returns **objects** (`[pscustomobject]` with `PSTypeName = 'PSTools.<Something>'`), never formatted text.
  No `Write-Host` except for interactive console prompts.
- Reports progress with `Write-Progress`, notices with `Write-Warning`, details with `Write-Verbose`.
  The GUI picks these streams up automatically – the logic must not know about the GUI.
- Emit results as soon as they are found (streaming), so the GUI can show them live.
- Helper functions that are only used by this tool are nested inside the public function
  (avoids name clashes when several tools are dot-sourced into one session). Shared helpers go to `Core/`
  with the prefix `PSTools` in the noun (e.g. `Get-PSToolsArpTable`).
- CLI use: `. .\Tools\Network\Find-ApipaDevice\Find-ApipaDevice.ps1; Find-ApipaDevice -Verbose`

Page files:
- `Page.xaml` is a `UserControl` with `x:Name` on every control the code needs. No `x:Class`, no code-behind.
- `Page.ps1` defines `Initialize-ToolPage -Context` and returns the loaded root element.
  Each page runs in its **own dynamic module** (Core + Gui + logic + page are dot-sourced into it), so
  `$script:` variables are private to the page and survive between events.
- `Context` provides: `AppRoot`, `ToolRoot`, `Tool` (manifest + paths), `Window`, `IsAdmin`.
- Long-running work **always** runs via `Start-PSToolsJob` (background runspace) – never block the UI thread.
  Provide Start + Cancel, a progress bar and a status text.
- Do not use `.GetNewClosure()` in event handlers (it detaches them from the page module). Keep state in
  `$script:` variables or in the sender's `Tag`.

## GUI conventions (apply to every tool)

Pick the control that fits each option:
- Free text / addresses: `TextBox` (validate on start, show a clear message on invalid input).
- Fixed choice list: `ComboBox` (not editable). Choice list with suggestions but free input allowed:
  editable `ComboBox` (e.g. subnet, timeout presets).
- On/off options: `CheckBox`. Mutually exclusive small sets (2–4): `RadioButton`s in a `GroupBox`.
- Numbers: editable `ComboBox` with presets or `TextBox` with range validation.
- **Lists filled automatically from the system** (adapters, drives, services, …) get a **⟳ refresh button
  right next to them** (devices can be plugged in later, e.g. USB network adapters). Keep the previous
  selection after refreshing if it still exists.
- Results: `DataGrid` (read-only, sortable) with actions below: Copy, Export CSV (`-UseCulture`), and
  tool-specific actions (e.g. open web UI).
- Hints/warnings that need user action: a notice bar at the top of the page with the exact command to fix it
  (copyable `TextBox`) and, where possible, a button that does it (disabled without admin rights).
- Use the shared implicit styles from the main window; do not hard-code colors or fonts in pages.
  Keyed shared styles (`RefreshButtonStyle`, `NoticeBarStyle`, `LogBoxStyle`) must be referenced with
  `{DynamicResource ...}` – pages are loaded before they are attached to the window, so `StaticResource` fails.
- Optional log: `Expander` "Log" at the bottom with a read-only `TextBox` (`LogBoxStyle`); expand it
  automatically on warnings/errors.
- Every event handler is wrapped in `Invoke-PSToolsUiAction { … }` so errors end up in a message box
  instead of killing the GUI.

## PowerShell 5.1 pitfalls (learned in this project)

- `$PSScriptRoot` is empty in `param()` default values of scripts – resolve paths in the script body.
- `Write-Warning ("...") -f $a` is parsed as a parameter `-f` – wrap it: `Write-Warning (("...") -f $a)`.
- Net* cmdlets autoload modules and their script properties import helper modules; with Verbose enabled this
  floods the log. `Core/Network.ps1` imports NetTCPIP/NetAdapter quietly; pass `-Verbose:$false` to Net* calls.
- Use `[long]` for IPv4 arithmetic (UInt32 silently overflows into other types).
- Hex literals are Int32: `0xFFFFFFFF` is `-1`, even as `[long]0xFFFFFFFF`. Write `[long]4294967295`
  (and `[long]4294967040` instead of `0xFFFFFF00`).

## Error handling

- Logic: `throw` for invalid input / unrecoverable errors, `Write-Warning` for recoverable notices.
- GUI: errors from jobs are shown in the status text / log, never as unhandled exceptions.
- A tool that fails to load must not break the main window – it shows its error in its own page.

## Git workflow (git flow)

Development follows **git flow**. The repository is configured for it (`gitflow.*` in `.git/config`):

| Branch | Purpose |
|---|---|
| `main` | Released versions only. Every commit on `main` is a merge from `release/*` or `hotfix/*` and is tagged. |
| `develop` | Integration branch; finished features are merged here. |
| `feature/<name>` | New tools, changes, refactorings, docs. Branched from `develop`, merged back into `develop`. |
| `release/<version>` | Release preparation (version bump, last fixes). From `develop`, merged into `main` **and** `develop`. |
| `hotfix/<version>` | Urgent fix of a released version. From `main`, merged into `main` **and** `develop`. |

Rules:
- **Never commit directly on `main` or `develop`** – every change, however small, starts on a `feature/*`
  branch (or `hotfix/*` for a released bug). Branch names: short, English, kebab-case
  (e.g. `feature/dhcp-debug-server`, `hotfix/0.1.1`).
- Merges into `develop`/`main` always use `--no-ff`, so every feature stays visible as one unit.
- **Claude finishes a feature (merge into `develop`) only after the user has tested it or asks for it.**
  Release and hotfix merges into `main` and tags only on the user's explicit request. Push only on request.
- Before finishing, bring a long-running feature up to date with `git merge develop`.
- Versions: SemVer `MAJOR.MINOR.PATCH`. `$AppVersion` in `PSTools.ps1` is the toolbox version; the tag on
  `main` is that version **without prefix** (`0.2.0`, not `v0.2.0`). Bump `Version` in a tool's `tool.psd1`
  when that tool changes (in the feature branch).
- Commit messages in English, imperative mood ("Add DHCP debug server"), with a short body for non-trivial changes.

The `git flow` command may not be installed; plain git equivalents:

```powershell
# feature
git switch -c feature/<name> develop
git switch develop; git merge --no-ff feature/<name>; git branch -d feature/<name>
# release
git switch -c release/<version> develop        # bump $AppVersion, commit
git switch main; git merge --no-ff release/<version>; git tag -a <version> -m "PSTools <version>"
git switch develop; git merge --no-ff release/<version>; git branch -d release/<version>
# hotfix
git switch -c hotfix/<version> main            # fix, bump patch version, commit
git switch main; git merge --no-ff hotfix/<version>; git tag -a <version> -m "PSTools <version>"
git switch develop; git merge --no-ff hotfix/<version>; git branch -d hotfix/<version>
```
