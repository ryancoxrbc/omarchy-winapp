# Changelog

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
