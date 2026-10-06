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

Memory and processors are part of that compose file. `winapp resources`
changes them by handing Omarchy's privileged writer the same full set of
values its installer does (memory, processors, disk size, account, time zone),
with only the first two altered. The disk size is read back from the compose
file or, where that cannot be read, from the size of the disk image, and the
command refuses rather than guess: dockur would take a larger figure as a
request to grow the disk.

## Cold or warm

Cold, the VM is started by the first app and stopped by a timer once the last
window has been closed for a while. Warm (`winapp mode warm`, or the panel),
there is no timer, and the VM is started once per login: by the first
`winapp state`, which the bar widget asks for as soon as it is up. Once, so
that stopping Windows by hand holds until the next app or the next login.
What warm costs is memory: Windows touches all it is given soon after it
boots, so the VM holds its full allowance for as long as it runs. After a
reboot of the computer, the start asks for your password like any other first
start does, this time at login.

## Apps are RemoteApp sessions

An app is started with FreeRDP in RemoteApp mode: one RDP connection that shows
the program's windows instead of a desktop. dockur enables this in Windows when
it installs it (`fAllowUnlistedRemotePrograms`, `fDisabledAllowList`), and
`winapp setup` sets it again in case your VM predates that.

Things that were learned the hard way and are handled:

- **The first logon after a boot.** As dockur installs it, Windows signs the
  VM's user in on its console at every boot, on a desktop nobody looks at. A
  RemoteApp logon cannot take a console session over; it is refused
  (`LOGON_MSG_BUMP_OPTIONS`) and FreeRDP shows a Windows prompt in a bare
  window instead. An ordinary, windowless logon first claims that session, but
  it has to wait: one that arrives while Windows is still signing in on the
  console leaves Remote Desktop Services stuck for a minute. Nothing outside
  Windows shows when that sign-in is over, so the wait was for dockur's
  "Windows started successfully", which is a fixed 30 seconds.
  So winapp offers to switch the console sign-in off (see
  [what is changed in Windows](#what-is-changed-in-windows)). With nobody on
  the console there is nothing to claim and nothing to wait for: the app's own
  logon is the first, made the moment Windows answers on the RDP port. On the
  machine this was measured on, Word's window is up 13 seconds after a cold
  start instead of 41. Should a logon be refused after all, winapp claims the
  session the old way, retries, and goes back to waiting until the setting has
  been applied again.
- **Is Windows listening?** Docker accepts connections on the published RDP
  port from the moment the container starts, long before Windows does, so an
  open port says nothing. winapp sends the protocol's first packet, a
  connection request, and looks for Windows' confirmation. Nobody is signed in
  by that.
- **One session, and the next app.** A second RemoteApp connection by the same
  user takes over the first one's session: every window moves to the new
  connection and is shown anew, and the old client is disconnected. So the
  next app is not started by a connection at all when it can be helped. The
  [frame program](#window-frames) that runs in the session watches a folder
  redirected for the purpose (`\\tsclient\winappq`), winapp writes the command
  line there, and the program starts it: under a second, no logon, and the
  windows that are open stay as and where they are. Taking a request is a
  rename, which only one side can win, so a request nobody takes within three
  seconds is withdrawn and a connection made instead. That is also what
  happens for a file no redirected folder of the open session reaches, since a
  connection cannot be given another folder later. The windows a new
  connection takes over are then put back on the workspaces they were on; they
  would otherwise all land on the one in view. Two launches made at the same
  instant are serialised.
- **A start screen is not a document.** Word and Excel opened without a file
  show a start screen, and turn that window into the next file they are given.
  So while a window with exactly that title is open (`startScreen` in
  `catalog.json`), a file is opened with the switch that starts another copy
  of the app (`/w` for Word, `/x` for Excel), which gives it a window of its
  own. Only then: each copy is some 230 MB. PowerPoint does the same and
  cannot be talked out of it. It runs as one copy, and neither a switch nor
  its automation interface opens a presentation beside the start screen.
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

## The helper-window fix

Windows programs keep windows around that nobody is meant to see or touch: the
hidden windows of an embedded Internet Explorer control, pseudo-console
windows, and also every classic menu and tooltip. xfreerdp shows them as
unmanaged (override-redirect) X11 windows, which is right, but two things then
go wrong on a compositor like Hyprland:

- xfreerdp labels them as dialogs, and Hyprland gives keyboard focus to
  unmanaged windows of that type. xfreerdp answers focus by telling Windows to
  activate the hidden window.
- xfreerdp reports whatever geometry the compositor gives such a window back
  to Windows as the user having resized it. Hyprland does not leave a window
  smaller than 20 pixels, and when it scales X11 programs it also rounds
  geometry by a pixel. A helper window that Windows keeps at 0x0 ends up 20x20
  (21x21 at a fractional scale) and visible; a menu can come back a pixel
  wider.

A program does not expect either to happen to a window it hides. One with an
Internet Explorer control, CorelDRAW's welcome screen for instance, answers by
spinning its UI thread: "Not Responding", for good. It happens the moment the
resize is relayed, which can be at start-up or minutes later, when some other
window opens.

`shim/xshim.c` is about a hundred lines of C that winapp loads into xfreerdp
(`LD_PRELOAD`). For unmanaged windows only, it changes the label to the one
xfreerdp itself first picks for them, which compositors do not focus, and
withholds geometry notifications, since Windows alone decides where such a
window is. One that Windows keeps at 0x0 is not shown at all until Windows
gives it a size: mapped, it would be listed among the desktop's windows and
get an icon in workspace indicators. Ordinary windows are untouched. It is compiled from the source in
the plugin the first time an app is opened, and again when that source changes;
`"helperWindowFix": false` in `config.json` switches it off.

The behaviour is reported to FreeRDP as
[FreeRDP/FreeRDP#13610](https://github.com/FreeRDP/FreeRDP/issues/13610); once
a release with a fix is in use, the shim has nothing left to do and can go.

## The mouse pointer

On a scaled monitor Windows is asked to draw at that scale itself, because
Hyprland leaves X11 windows unscaled. At 200% it therefore sends a pointer
twice the size, which xfreerdp hands to X as it comes. But the desktop shows
an X11 program's pointer enlarged by the monitor's scale whatever it does with
the windows (that is why an ordinary X11 program's 24 pixel pointer looks
right), so the Windows pointer came out scaled twice. The same shim reduces
each pointer picture by the monitor's scale before X gets it. Measured at
160%: the arrow went from 42 pixels tall to 26, with its tip where it was.
`"pointerScale"` in `config.json` sets the percentage by hand; `100` leaves
the pointer as Windows draws it.

## The Super key

On Omarchy every Super shortcut belongs to the desktop. Hyprland still hands
the Super press itself to the focused window, the client forwards it, and when
the shortcut moves the focus away the client releases it. Windows sees its
Windows key tapped and opens the Start menu, which is waiting there on the way
back. The same shim therefore keeps Super, and any key pressed while it is
down, from the client, and never reports Super as held.
`"superKey": "windows"` in `config.json` hands the key back to Windows, for
those who want Win+V or Win+. in the combinations Omarchy leaves free.

## Window frames

Windows draws a title bar on a program's main window and, since Windows 11,
rounds every window's corners. On a tiling desktop the title bar repeats what
the desktop already does, and what shows in the cut-off corners is Windows'
background, not yours. The picture of each window arrives finished, so neither
can be changed on the Linux side. A small program inside Windows does it:
`winapp-frame.exe`, built in the VM from `guest/frame.cs` by the C# compiler
Windows carries, and kept in `C:\ProgramData\winapp`. Apps are started through
it. It starts the app and, for as long as the session is connected,

- takes the title bar and sizing border off main windows whose title bar
  Windows draws. A menu bar is a separate part of the window and stays. Dialogs
  keep their title, and so do floating palettes, which are moved by it;
- asks Windows not to round the corners of any window.

A program that draws its own title bar, as Office does, has nothing here to
remove: its name and buttons are part of the program. It still gets square
corners.

While it is there it also starts the next app winapp asks for, as described
under "One session, and the next app" above.

The program does nothing unless winapp starts an app through it, keeps no
state, and leaves when the session disconnects. `"titleBars": true` and
`"roundedCorners": true` in `config.json` leave either to Windows, and
`"titleBar": true` on an app in `apps.json` keeps that one app's title bar. A
change reaches Windows with the next app opened while no other is open. If the
program cannot be built or started, apps open as they did before it existed,
and `winapp doctor --deep` says why.

## What is changed in Windows

`winapp changes` lists all of it. There are two kinds.

What every install needs, made by `winapp setup`: RemoteApp may start any
program, the `~/Windows` share shows Linux-side changes at once, your shared
folders are pinned to Quick access, and the frame program is built.

What is yours to decide. Neither is made until you have said yes:

- **Start Windows faster** (`fastStart`): nobody is signed in on the console
  at boot (`AutoAdminLogon`), for the reason given above. The full desktop
  still opens with `winapp desktop` and from Omarchy's *Windows* launcher,
  which sign in themselves. The web console on port 8006 shows Windows'
  sign-in screen instead of a desktop; the account is the one in
  `~/.config/windows/credentials`.
- **Search indexer and Widgets off** (`trimWindows`). Neither does anything
  for an app shown on its own, and both run in the background after every
  boot. Measured, they make no difference to how fast an app opens; switching
  them off leaves the VM's processors and disk alone.

The question is put once: in `winapp setup` when you run it in a terminal,
otherwise as a notification the first time you open an app, with three
answers. *Yes* makes the change with the next app opened while no other is
open. *Don't ask again* is a no. *Not now*, or no answer, leaves Windows as it
is and asks again in a week. A later version that wants another change asks
for that one the same way. While a question is open the panel has a *Changes
to Windows* row for it. An answer can be changed at any time with
`winapp changes allow|deny|ask <fast|trim>`.

What Windows was set to before a change is kept (under `HKLM\SOFTWARE\winapp`)
and restored when the answer becomes no. Nothing else is touched: no service
beyond the indexer, nothing of Defender's, no update setting.

## Files are redirected, not shared

FreeRDP's drive redirection makes a Linux folder appear in the session as
`\\tsclient\<name>`. winapp redirects the folders listed under `shares` in
`config.json` into every session (none until you choose some: whatever is
shared, every program in Windows can read and change), translates the
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
| `$XDG_RUNTIME_DIR/winapp/` | pid files, the idle countdown, locks, requests to an open session |
| `C:\ProgramData\winapp\` (in the VM) | the window-frame program and its settings |
| `HKLM\SOFTWARE\winapp` (in the VM) | what Windows was set to before winapp changed it |
