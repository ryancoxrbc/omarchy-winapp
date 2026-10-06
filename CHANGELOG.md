# Changelog

## 2.4.0 - 2026-10-06

### Changed

- In the panel, "Stop when idle for" is above "Start-up", so that the note
  about cold and warm is what runs off the bottom, not a control.
- You choose which folders Windows can reach, and none is shared until you
  have. A new install no longer redirects your whole home folder: `winapp
  setup` shows a checklist of the folders in it, and so do *Shared folders* in
  the panel and `winapp share pick`. A file outside every shared folder still
  opens, bringing just its own folder along. If you already use winapp, your
  shares stay as they are (the whole home folder, unless you changed it);
  narrowing them is one `winapp share pick` away.
- winapp asks before it changes anything optional inside Windows. 2.3.0
  switched off the console sign-in, the search indexer and Widgets on its own;
  each is now a question with three answers (yes, not now, don't ask again),
  put in `winapp setup` or as a notification the first time you open an app.
  Until you answer, Windows is left as it is: what 2.3.0 already switched off
  stays off, and "don't ask again" puts it back. `winapp changes` lists
  everything winapp does in Windows and changes an answer; the panel shows a
  *Changes to Windows* row while a question is open. `"consoleSignIn"` from 2.3.0 is replaced by
  `"fastStart"`; `"consoleSignIn": true` is still read as a no.
- `winapp explorer` without a folder opens the first shared folder instead of
  the home folder.

## 2.3.0 - 2026-10-06

### Added

- Cold or warm start-up, in the panel and as `winapp mode cold|warm`. Cold is
  what there was: Windows starts when you open an app and stops when idle.
  Warm starts it when you log in and keeps it on, so every app opens in about
  3 seconds, at the price of the VM's memory being held all the time. The
  panel says so, with your VM's own figure. Stopping Windows by hand still
  works when warm; it then stays off until you open an app or log in again.

### Changed

- The first app after starting Windows opens much sooner: measured with Word,
  13 seconds from a stopped VM instead of 41. Thirty of those seconds were a
  fixed wait, needed only because Windows signed in on its own console at
  every boot. winapp now switches that sign-in off inside the VM and makes the
  app's logon the first one, the moment Windows listens. The change is applied
  with the first app opened after updating, and is in effect from the start
  after that one. `"consoleSignIn": true` in `config.json` keeps the old
  behaviour. The web console on port 8006 now shows Windows' sign-in screen;
  `winapp desktop` and Omarchy's *Windows* launcher work as before.
- An app opened while another is open is started inside the session that is
  already there: under a second, without a second logon.
- Windows' search indexer and Widgets are switched off in the VM.
  `"trimWindows": false` puts them back.

### Fixed

- The mouse pointer over Windows app windows is no longer too large on a
  scaled monitor (twice the size at 200%). Windows drew it at the monitor's
  scale and the desktop then enlarged it again; it is now reduced by that
  scale first. `"pointerScale": 100` in `config.json` switches this off. (#3)
- Windows' empty helper windows, such as the ones an embedded Internet
  Explorer control keeps, are no longer shown at all. They were harmless since
  2.0.1 but still listed among the desktop's windows, with an icon each in
  workspace indicators. (#1)
- Opening a second document no longer pulls the windows that are already open
  onto the workspace in view. They stay where they are; when a new connection
  cannot be avoided (a file outside every shared folder), they are put back.

## 2.2.0 - 2026-10-05

### Added

- App windows no longer carry the title bar Windows draws (the program's name
  and the minimise, maximise and close buttons), and no window has Windows 11's
  rounded corners. A menu bar stays where it is, and dialogs keep their title.
  A small program built inside the VM does this; apps are started through it.
  Programs that draw their own title bar, such as Office, keep it and get
  square corners. `"titleBars": true` and `"roundedCorners": true` in
  `config.json` switch either off, and `"titleBar": true` on an app keeps that
  app's title bar.

### Fixed

- Windows' Start menu no longer opens when you switch workspace away from a
  Windows window, or tap Super in one. The Super key and anything pressed with
  it now stay with Omarchy. `"superKey": "windows"` restores the old behaviour.
- A file type Linux does not know (for example `.sldprt`) is registered with
  the system as soon as its app is added. Before, the type was written but the
  system's database was not refreshed, so double-clicking such a file could
  fail until something else refreshed it.
- `winapp doctor` shows its ticks and crosses in colour in a terminal again.

### Removed

- `winapp passwordless` and the polkit rule it installed. If you switched it on
  with 2.0 or 2.1, the rule still works; `winapp doctor` shows how to remove
  it, and `winapp uninstall` removes it.

### Changed

- Internal tidy-up with no change in behaviour: duplicated code merged,
  single-use helpers folded into their callers, and the carry-over of a
  setting from the unpublished 1.x removed.

## 2.1.0 - 2026-10-05

### Added

- `winapp resources` shows how much memory and how many processors the
  Windows VM has, and changes them: `winapp resources --ram 8 --cores 4`. The
  bar panel has a "Memory and processors" row that opens a picker. The change
  goes through Omarchy's own configuration writer, so it asks for your
  password, and applies the next time Windows starts.

## 2.0.1 - 2026-10-05

### Fixed

- Programs with an embedded Internet Explorer control froze ("Not Responding",
  one CPU core pinned), at start-up or some time later, and classic menus took
  keyboard focus when opened. CorelDRAW's welcome screen is
  the best-known case (#1). The RDP client was activating and resizing windows
  that Windows programs keep hidden; a small library loaded into it
  (`shim/xshim.c`) now leaves those windows alone. It is built automatically
  and needs a C compiler; `winapp doctor` reports on it.
- An app set as the default for a file type that a Linux app also opens was
  ignored by `xdg-mime` and `xdg-open`, because the launcher entry's `Exec`
  line was quoted (#2). The path is now written bare. Run `winapp sync` to
  rewrite existing entries.

## 2.0.0 - 2026-10-05

First public release. Rewritten from a personal script and widget into a
plugin that sets itself up on any Omarchy machine.

### Added

- `winapp setup`, run by the `setup` script: installs what is missing, links
  the command, enables the widget, prepares Windows and offers the app picker.
- `winapp manage`, a checklist of the programs installed in Windows, and
  `winapp scan` for the same list in a terminal. A catalog of about 40 known
  programs supplies names and file types; any other program works too, with
  the file types Windows has registered for it.
- App icons fetched from Windows at full resolution.
- `winapp desktop`: the full Windows desktop with the same folders redirected,
  for installing software. `winapp run` accepts an installer on the Linux side.
- `winapp open <file>` and `winapp explorer [folder]`.
- Configurable shares (`winapp share add|remove`), and automatic redirection of
  files outside every share for as long as the VM stays up.
- Works without sudoless Docker: state is read without Docker, and starting and
  stopping go through Omarchy's helper. `winapp passwordless on` installs a
  narrowly scoped polkit rule so those two actions stop asking for a password.
- `winapp doctor`, `winapp logs`, `winapp uninstall`.
- Panel: app list with icons, keyboard navigation, a power switch that asks
  before stopping with apps open, a first-run state that offers to install the
  VM, and a setting to hide the icon while Windows is off.
- Launcher names stay distinct from same-named entries such as Omarchy's
  Microsoft web apps: "Microsoft Word (Windows)" when both are installed.
- `--no-menu` hides an app from the launcher but keeps it opening its files.
- A test suite that runs without a VM, and CI.

### Fixed

- File names containing an apostrophe could not be opened: FreeRDP's `/app`
  argument parser rejects them. The program and its arguments now travel in a
  generated connection file.
- A single-app logon refused after the VM was restarted elsewhere left a bare
  Windows sign-in window on screen. It is now detected and retried.
- Two launches at the same moment could lose the first app.
- Files added to `~/Windows` from Linux not appearing in Explorer is fixed once
  inside Windows instead of by patching the container on every start, so it
  also works without Docker access.
- Opening an app while the Windows desktop is open (or the reverse) failed in
  confusing ways; it is now refused with an explanation.
- Superseded idle timers lingered until their timeout.

### Changed

- Settings moved from `idle-minutes` to `config.json` (carried over
  automatically). `apps.json` keeps its format.
