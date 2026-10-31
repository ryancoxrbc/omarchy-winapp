# How it works

Four pieces, each small:

```
Panel.qml       the bar widget: shows `winapp state`, runs `winapp` commands
bin/winapp      the command; lib/*.sh hold its parts
guest/agent.cs  the agent: runs inside Windows and opens what winapp asks for
guest/*.ps1     PowerShell run inside Windows for the scan, icons and setup
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

Cold, the VM is started by the first app or file and stopped by a timer once
the Windows window has been closed for a while. Warm (`winapp mode warm`, or the panel),
there is no timer, and the VM is started once per login: by the first
`winapp state`, which the bar widget asks for as soon as it is up. Once, so
that stopping Windows by hand holds until the next app or the next login.
What warm costs is memory: Windows touches all it is given soon after it
boots, so the VM holds its full allowance for as long as it runs. After a
reboot of the computer, the start asks for your password like any other first
start does, this time at login.

## One window, and everything opens in it

Windows is shown the way it is on a PC: one desktop, with its taskbar, in one
window. That window is a FreeRDP connection to the VM's desktop, made by
`winapp __desktop`, which runs on its own so that the window outlives whatever
asked for it (a file manager, the bar, a terminal). Opening an app or a file
from Linux does not make a connection of its own:

1. If the window is not open, winapp starts the VM when needed and opens it.
2. It writes the Windows command line (the app, its fixed arguments, the
   file's `\\tsclient` path) to a file in a folder that connection redirects,
   `\\tsclient\winappq`.
3. The [agent](#the-agent) in Windows takes the file, starts the command, and
   brings the window it opens to the front. winapp brings the Windows window
   forward on Linux, switching to its workspace.

With the window open that takes under a second. Taking a request is a
rename, which only one side can win, so a request the agent has not taken in
time (10 seconds, or two minutes while Windows is still signing in) is
withdrawn, and you are told.

2.x showed each app in a window of its own (RemoteApp). Every menu, tooltip
and dialog was then an X11 window of its own as well, and the compositor, the
FreeRDP client and Windows did not always agree about them: hidden helper
windows that froze programs such as CorelDRAW, owned windows that tiled
instead of floating, a deadlock in FreeRDP 3.32 set off when a popup closed,
windows moving between connections when the next app opened. Inside one
desktop, Windows draws all of those itself, and none of it arises.

Things that were learned the hard way and are handled:

- **The first logon after a boot.** As dockur installs it, Windows signs the
  VM's user in on its console at every boot. A logon that arrives while
  Windows is still doing that leaves Remote Desktop Services stuck for a
  minute, and nothing outside Windows shows when that sign-in is over, so the
  wait is for dockur's "Windows started successfully", a fixed 30 seconds.
  winapp offers to switch the console sign-in off (see
  [what is changed in Windows](#what-is-changed-in-windows)). With nobody on
  the console there is nothing to wait for: the window's own logon is the
  first, made the moment Windows answers on the RDP port. On the machine this
  was measured on, that is 13 seconds after a cold start instead of 41.
- **Is Windows listening?** Docker accepts connections on the published RDP
  port from the moment the container starts, long before Windows does, so an
  open port says nothing. winapp sends the protocol's first packet, a
  connection request, and looks for Windows' confirmation. Nobody is signed in
  by that.
- **A file outside the shared folders.** Folders are redirected when a
  connection is made and cannot be added to it later. So when a file needs a
  folder the open window does not redirect, the window is connected again,
  with that folder added. The Windows session, and every app in it, stays as
  it is; only the picture is drawn anew.
- **Closing the window is not closing the apps.** The window is a view of the
  session, and the apps in it keep running when it closes, as they would on a
  PC whose screen is switched off. They are there again when it reopens. The
  idle timer then starts, and stopping Windows stops them, unsaved work and
  all: so when the window closes with apps still open, winapp names them in a
  notification that says when Windows will stop. (The agent keeps a list of
  their windows in the request folder, `open.txt`; what it said last is what
  was open.)
- **Omarchy's own window.** Omarchy's launcher (renamed *Omarchy Windows*,
  see [launcher entries](#launcher-entries-and-file-types)) connects to the
  same desktop, without a folder for requests, and shuts the VM down when its
  session is taken away. While it is open winapp opens nothing and says why.
- **File names.** The command line travels in a file, and the agent starts
  it as it is, so `Sam's report, final.docx` opens like any other file.
- **Passwords.** FreeRDP's arguments go in over stdin (`/args-from:stdin`), not
  on the command line, where any user on the machine could read them for as
  long as the session lasts.

## The agent

`winapp-agent.exe`, built in the VM from `guest/agent.cs` by the C# compiler
Windows carries, and kept in `C:\ProgramData\winapp`. A scheduled task
(`\winapp\winapp-agent`) starts it in the session at every sign-in and every
time a Remote Desktop connection reaches the session, and one copy runs per
session. It

- takes the requests winapp puts in `\\tsclient\winappq` and starts them;
- brings the window a request opened to the front: the one whose title names
  the file, or else the first new window, for up to 20 seconds. Windows lets
  a program started from the background come up behind whatever has the
  focus, and a document that is open already only flashes on the taskbar;
- keeps the list of open app windows described above;
- starts the jobs winapp runs in Windows (the scan, icons, the settings below)
  while the window is open, hidden. With the window closed, a job runs as a
  hidden RemoteApp of its own, which is also how Windows is first prepared,
  before there is an agent.

It keeps no state and changes nothing in Windows. If it cannot be built,
the Windows window still opens, files cannot be handed to it, and
`winapp doctor --deep` says why. (2.x had `winapp-frame.exe` in its place,
which also took the title bar off app windows; the agent removes it.)

## The mouse pointer

On a scaled monitor Windows is asked to draw at that scale itself, because
Hyprland leaves X11 windows unscaled. At 200% it therefore sends a pointer
twice the size, which xfreerdp hands to X as it comes. But the desktop shows
an X11 program's pointer enlarged by the monitor's scale whatever it does with
the windows (that is why an ordinary X11 program's 24 pixel pointer looks
right), so the Windows pointer came out scaled twice. `shim/xshim.c`, a few
lines of C that winapp loads into xfreerdp (`LD_PRELOAD`), reduces each
pointer picture by the monitor's scale before X gets it. Measured at 160%: the
arrow went from 42 pixels tall to 26, with its tip where it was.
`"pointerScale"` in `config.json` sets the percentage by hand; `100` leaves
the pointer as Windows draws it. The shim is compiled from the source in the
plugin the first time Windows is opened, and again when that source changes.

## The Super key

On Omarchy every Super shortcut belongs to the desktop. Hyprland still hands
the Super press itself to the focused window, the client forwards it, and when
the shortcut moves the focus away the client releases it. Windows sees its
Windows key tapped and opens the Start menu, which is waiting there on the way
back. The same shim therefore keeps Super, and any key pressed while it is
down, from the client, and never reports Super as held.
`"superKey": "windows"` in `config.json` hands the key back to Windows, for
those who want Win+V or Win+. in the combinations Omarchy leaves free.

## What is changed in Windows

`winapp changes` lists all of it. There are two kinds.

What every install needs, made by `winapp setup`: RemoteApp may start any
program, the `~/Windows` share shows Linux-side changes at once, your shared
folders are pinned to Quick access, and the agent is built and its scheduled
task registered.

What is yours to decide. Neither is made until you have said yes:

- **Start Windows faster** (`fastStart`): nobody is signed in on the console
  at boot (`AutoAdminLogon`), for the reason given above. The Windows window
  and Omarchy's own launcher sign in themselves. The web console on port 8006 shows Windows'
  sign-in screen instead of a desktop; the account is the one in
  `~/.config/windows/credentials`.
- **Search indexer and Widgets off** (`trimWindows`). Both run in the
  background after every boot. Measured, they make no difference to how fast
  Windows opens; switching them off leaves the VM's processors and disk alone.
  Start menu search still finds programs.

The question is put once: in `winapp setup` when you run it in a terminal,
otherwise as a notification the first time you open an app, with three
answers. *Yes* makes the change the next time the Windows window opens. *Don't ask again* is a no. *Not now*, or no answer, leaves Windows as it
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
`config.json` into the Windows window (none until you choose some: whatever is
shared, every program in Windows can read and change), translates the
path of the file you opened, and hands that to the app.

A file that no share covers gets a drive of its own: the whole disk when it is
on removable media, otherwise just its folder, and the window is connected
again to add it. That drive is then redirected by every later connection
until the VM stops, because a later connection replaces the earlier one's
drives and the app may still have the file open.

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

The Windows window itself is *Windows* in the launcher
(`winapp-desktop.desktop`), with the icon Omarchy's own entry has. Omarchy's
entry (`windows-vm.desktop`) is left in place and renamed *Omarchy Windows*;
Omarchy writes it again when the VM is reinstalled, and the bar's regular
check renames it again. `winapp uninstall` gives it its name back.

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
| `$XDG_RUNTIME_DIR/winapp/` | pid files, the idle countdown, locks, the request folder (`requests/`) |
| `C:\ProgramData\winapp\` (in the VM) | the agent |
| Task Scheduler, `\winapp\` (in the VM) | the task that starts the agent |
| `HKLM\SOFTWARE\winapp` (in the VM) | what Windows was set to before winapp changed it |
