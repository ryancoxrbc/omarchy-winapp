# Changelog

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
