# How it works

Three pieces, each small:

```
Panel.qml      the bar widget: shows `winapp state`, runs `winapp` commands
bin/winapp     the command; lib/*.sh hold its parts
guest/*.ps1    PowerShell run inside Windows for the scan, icons and setup
```

Everything the panel does is a `winapp` command, so anything that works from
the panel works from a terminal, a keybinding or a script, and the other way
round.

## The VM is Omarchy's

winapp does not create or configure a VM. It uses the one
`omarchy-windows-vm install` sets up: a [dockur/windows](https://github.com/dockur/windows)
container whose compose file Omarchy keeps root-owned under
`/var/lib/omarchy/windows`. winapp only starts it, waits for it and stops it.

How it does that depends on whether your user can reach Docker:

| | Start | Stop | "Is it running?" |
|---|---|---|---|
| Sudoless Docker on | `docker-compose up -d` | `docker-compose down` | `docker inspect` |
| Sudoless Docker off | `pkexec omarchy-windows-vm __priv up_wait` | `omarchy-windows-vm stop` | is the web console port (8006) open? |

Two details matter in the first column. After a reboot the bind mounts Omarchy
puts between your home folder and the container are gone, and only root can
recreate them; starting the container without them would boot Windows on an
empty disk. winapp checks for them and goes through Omarchy's helper when they
are missing, which is why the first start after a reboot asks for a password
even with sudoless Docker. And the "is it running" question is asked every few
seconds by the bar, so it must never need a password: hence the port probe.

## Apps are RemoteApp sessions

An app is started with FreeRDP in RemoteApp mode: one RDP connection that shows
the program's windows instead of a desktop. dockur enables this in Windows when
it installs it (`fAllowUnlistedRemotePrograms`, `fDisabledAllowList`), and
`winapp setup` sets it again in case your VM predates that.

Things that were learned the hard way and are handled:

- **The first logon after a boot.** Windows signs the VM's user in on its
  console at boot, and a RemoteApp logon cannot take a console session over; it
  is refused (`LOGON_MSG_BUMP_OPTIONS`) and FreeRDP shows a Windows prompt in a
  bare window instead. So once per boot winapp makes one ordinary, windowless
  logon first. If the VM was restarted behind its back it notices the refusal,
  does that logon, and tries again.
- **One session.** A second RemoteApp connection by the same user takes over
  the first one's session: the windows move to the new connection and the old
  client is disconnected. That is how a second app opens. Two launches made at
  the same instant are serialised so the first has asked for its app before the
  second takes over.
- **Desktop or apps.** A desktop edition of Windows keeps one session
  connected at a time. The full desktop is the console session and apps run in
  another, so while one is connected a logon to the other is refused (or, for
  the desktop, answered with a "someone else is signed in" prompt). winapp
  checks before connecting and says which one to close, instead of failing in
  the middle of a launch. The check covers Omarchy's own *Windows* launcher
  too: taking the session from it would make it shut the VM down.
- **Nobody hangs up.** The RDP session outlives its last window, so the client
  would never exit. winapp watches its windows through Hyprland and drops the
  connection eight seconds after the last one closes. Then the idle timer
  starts.
- **File names.** FreeRDP's `/app:program:…,cmd:…` is a comma-separated list
  whose parser fails on an apostrophe. winapp passes the program and its
  arguments in a generated `.rdp` file instead, where values are literal, so
  `Sam's report, final.docx` opens like any other file.
- **Passwords.** FreeRDP's arguments go in over stdin (`/args-from:stdin`), not
  on the command line, where any user on the machine could read them for as
  long as the session lasts.

## Files are redirected, not shared

FreeRDP's drive redirection makes a Linux folder appear in the session as
`\\tsclient\<name>`. winapp redirects the folders listed under `shares` in
`config.json` (your home folder by default) into every session, translates the
path of the file you opened, and hands that to the app.

A file that no share covers gets a drive of its own: the whole disk when it is
on removable media, otherwise just its folder. That drive is then redirected by
every later connection until the VM stops, because a later connection replaces
the earlier one's drives and the app may still have the file open.

This is separate from Omarchy's `~/Windows` folder, which Windows sees as the
network share `\\host.lan\Data`. That one has a quirk worth knowing: its Samba
server grants directory leases, so Windows caches a folder's listing until the
server says it changed, and a file written on the Linux side never makes it say
so. `winapp setup` turns that client-side cache off in Windows, after which
Linux-side changes show immediately.

## Finding programs

`winapp scan` runs a PowerShell script in the VM that walks the Start Menu,
resolves each shortcut to the executable it really launches (including MSI
"advertised" shortcuts, which point at an icon stub), and collects the file
types Windows has registered for each one.

The result is matched against `catalog.json`. A program the catalog knows gets
a stable id, a short name and a curated list of file types: the ones that are
its own (`ext`) and the ones it merely can open (`opens`). Only the first kind
can make it the default app, so adding Photoshop does not take over your PNGs.
A program the catalog does not know is named after its shortcut and keeps the
types Windows listed.

Icons come from the Windows shell at 256 pixels with their alpha channel, not
from the 32-pixel icon most tools extract.

## Launcher entries and file types

Each app gets `~/.local/share/applications/winapp-<id>.desktop`. File types are
looked up in the system's MIME database; an extension Linux has never heard of
(`.sldprt`, say) gets a private MIME type so it can be associated at all.

When another launcher entry already goes by an app's name, as Omarchy's
Microsoft web apps do ("Microsoft Word"), the entry made here is named
"Microsoft Word (Windows)" instead. The bar's regular state check notices when
launcher entries are added or removed and renames in the background, so the
names stay distinct without anyone running a command. Entries are files named
`winapp-<id>.desktop`, so nothing else's install or removal touches them.

An app becomes the default for a type when you asked for that (`--default`, or
answering yes in `winapp manage`), or when nothing else on the machine opens
that type. Removing an app removes its entry, its private types and its lines
in `mimeapps.list`, and nothing else.

## Where things live

| | |
|---|---|
| `~/.config/winapp/` | `config.json`, `apps.json` |
| `~/.local/share/winapp/icons/` | fetched icons |
| `~/.cache/winapp/` | the last scan |
| `~/.local/state/winapp/log/` | the last 20 session logs |
| `$XDG_RUNTIME_DIR/winapp/` | pid files, the idle countdown, locks |
