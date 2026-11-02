# Troubleshooting

Start with `winapp doctor`. It checks each piece and prints the fix next to
whatever fails. `winapp doctor --deep` also boots Windows and tests it from the
inside: signing in, starting a program, reading and writing a Linux folder, and
whether every app you added is still installed, and building the agent that
opens files in Windows.

`winapp logs` prints the newest session log; all of them are in
`~/.local/state/winapp/log/`.

## An app or a file does not open

**"Windows could not start C:\…"** (a box inside Windows)
The program is not at that path any more, usually after an update moved it.
`winapp scan` shows where it is now; `winapp add <id>` again picks that up.

**"Windows did not pick up the request"**
The agent in Windows did not take it. Right after a cold start Windows may
still be signing in: try again in a moment. Otherwise run
`winapp doctor --deep`, which rebuilds the agent and says whether Windows
would build it. The agent is started by the task `\winapp\winapp-agent` in
Windows' Task Scheduler; a Windows window opened by something other than
winapp has no folder for requests.

**"Windows is open in Omarchy's own window…"**
Omarchy's launcher (*Omarchy Windows*) is showing the desktop, and its window
cannot be handed files. Close it and open the file again; it opens in
winapp's *Windows* window.

**"Windows did not accept a sign-in"**
Windows is not ready. If it is still installing or updating, watch it at
<http://127.0.0.1:8006>. If it is up, check that the account in
`~/.config/windows/credentials` is the one you chose when installing the VM.

**The app opened, but behind another window**
The agent brings the window whose title names the file to the front, or the
first new window. A program that names its window differently, or takes more
than 20 seconds to open it, is left where Windows put it: click it on
Windows' taskbar.

**The web console (port 8006) shows Windows' sign-in screen**
You said yes to "Start Windows faster": nobody is signed in on the console, so
that a cold start does not have to wait for that. Sign in there with the
account in `~/.config/windows/credentials`, or use `winapp desktop`.
`winapp changes deny fast` brings the old behaviour back.

**Windows takes most of a minute to open after a cold start**
Windows signs in on its console, and the window waits for that.
`winapp changes` shows whether you have agreed to switch that off; once you
have, it takes effect the second time Windows starts.

**A Windows app cannot find or save to a folder**
Only the folders you share reach Windows: `winapp shares` lists them and
`winapp share pick` changes them. A file opened from anywhere else brings just
its own folder along.

**The window stops reacting while Windows is fine: keys and clicks do
nothing and the picture does not change.**
Check `pacman -Q freerdp`. 3.32.0 to 3.32.2 deadlock in some cases (FreeRDP
PR #13769 has the fix); 2.x hit this constantly with its window per app, and
the one Windows window should not set it off, but if it does: close the
window (`kill` its `xfreerdp3` if Super+W does not) and open Windows again;
the apps in it are still running. Going back to 3.31.1 avoids it:
`sudo pacman -U /var/cache/pacman/pkg/freerdp-2:3.31.1-1-x86_64.pkg.tar.zst`
while it is still in the cache, with `IgnorePkg = freerdp` in
`/etc/pacman.conf` until a fixed release is out.

## The VM

**It asks for my password a lot.**
Without sudoless Docker, Omarchy asks on every start and stop, including the
automatic stop after the VM has sat idle, and Windows cannot sleep. Turning on
sudoless Docker in Omarchy stops the prompts and lets the timer put Windows to
sleep instead; otherwise a longer `idleMinutes`, or `0`, makes the automatic
stop rarer.

**It asks once after every reboot even with sudoless Docker.**
Expected: the mounts between your home folder and the VM have to be recreated
by root after a reboot.

**It stopped and an app I had open in Windows lost its work.**
Closing the Windows window leaves its apps running, and the idle timer then
stops Windows, apps and all; the notification that names what was still open
says when. Set a longer timeout in the panel, or `winapp idle 0` to stop it
only by hand.

**It never stops.**
Check `winapp status`. The Windows window, open on another workspace perhaps,
keeps it up.

## Files

**The app cannot see a file I just opened it with.**
Run `winapp shares`: the file has to be under one of the folders listed, or be
opened through winapp so its folder is redirected. Files reached through a
symbolic link that leaves every share are redirected by their real location.

**"Windows cannot open …: the name contains one of < > : " | ? *"**
Windows has no way to name that file. Rename it.

**Files I add to `~/Windows` from Linux do not appear in Explorer.**
Run `winapp setup` once and let it start Windows; it turns off the cache in
Windows that causes this.

**Saving is slow.**
Redirected folders are slower than a local disk, most noticeably for programs
that write many small files. Working copies of very large projects are faster
on the VM's own disk.

## Looks

**Everything is tiny, or huge.**
Set `"scale"` in `~/.config/winapp/config.json` to a percentage, for example
`150`. The default follows the focused monitor.

**The wrong keyboard layout.**
Add your layout to `"rdpArgs"`, for example `["/kbd:layout:0x0407"]` for
German. `xfreerdp3 /list:kbd` lists the ids.

**The Windows key does nothing in Windows.**
That is deliberate: Super belongs to Omarchy's shortcuts, and passing it on
made the Start menu open whenever you switched workspace. Ctrl+Esc opens the
Start menu. `"superKey": "windows"` in `config.json` passes the key through.

## Starting over

`winapp uninstall --purge` followed by the setup script gives you a clean
slate without touching the VM.
