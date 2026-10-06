# Troubleshooting

Start with `winapp doctor`. It checks each piece and prints the fix next to
whatever fails. `winapp doctor --deep` also boots Windows and tests it from the
inside: signing in, starting a program, reading and writing a Linux folder, and
whether every app you added is still installed.

`winapp logs` prints the newest session log; all of them are in
`~/.local/state/winapp/log/`.

## An app does not open

**"Windows could not start C:\…"**
The program is not at that path any more, usually after an update moved it.
`winapp scan` shows where it is now; `winapp add <id>` again picks that up.

**"no window appeared"**
The program started but never showed a window, or took more than three minutes
to. Open it once from `winapp desktop` to see what it is waiting for: a licence
dialog and a first-run wizard are the usual answers.

**"Windows did not accept a sign-in"**
Windows is not ready. If it is still installing or updating, watch it at
<http://127.0.0.1:8006>. If it is up, check that the account in
`~/.config/windows/credentials` is the one you chose when installing the VM.

**A window with a Windows sign-in prompt appears instead of the app**
Someone is signed in on the VM's console, or Windows restarted while winapp
thought it had that session. It normally notices and retries by itself; if you
do see the prompt, close the window and open the app again.

**The web console (port 8006) shows Windows' sign-in screen**
You said yes to "Start Windows faster": nobody is signed in on the console, so
that the first app does not have to wait for that. Sign in there with the
account in `~/.config/windows/credentials`, or use `winapp desktop`.
`winapp changes deny fast` brings the old behaviour back.

**The first app after starting Windows takes most of a minute**
Windows signs in on its console, and the app waits for that. `winapp changes`
shows whether you have agreed to switch that off; once you have, it takes
effect the second time Windows starts.

**A Windows app cannot find or save to a folder**
Only the folders you share reach Windows: `winapp shares` lists them and
`winapp share pick` changes them. A file opened from anywhere else brings just
its own folder along.

**The app's window is black or white, says "Not Responding", and ignores the
mouse; tiny extra windows may appear next to it.**
This was CorelDRAW's welcome screen before 2.0.1, and can be any program with
an embedded Internet Explorer control. Update the plugin, then check that
`winapp doctor` says "helper-window fix built"; it needs a C compiler
(`omarchy pkg add gcc`). To get out of a frozen app: `winapp stop`, then open
it again.

**"the Windows desktop is open…"**
Windows shows either its desktop or single apps, not both at once. Close the
desktop window (winapp's, or the one Omarchy's own *Windows* launcher opened)
and open the app again.

## The VM

**It asks for my password a lot.**
Without sudoless Docker, Omarchy asks on every start and stop, including the
automatic stop after the VM has sat idle. Turning on sudoless Docker in Omarchy
is the way to stop the prompts; a longer `idleMinutes`, or `0`, makes the
automatic stop rarer.

**It asks once after every reboot even with sudoless Docker.**
Expected: the mounts between your home folder and the VM have to be recreated
by root after a reboot.

**It stops while I am still using it.**
The idle timer only runs while no app window is open. A program that sits in
the tray with no window counts as closed. Set a longer timeout in the panel, or
`winapp idle 0` to stop it only by hand.

**It never stops.**
Check `winapp status`. A window that is still open somewhere, on another
workspace perhaps, keeps it up.

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

**An app still has its title bar and buttons.**
Office and other programs that draw their own title bar keep it: it is part of
the program, not something Windows adds. For a program with an ordinary Windows
title bar, run `winapp doctor --deep`; it rebuilds the piece that removes it
and says so if Windows would not. Dialogs keep their title on purpose.

**I want the Windows title bar, or rounded corners, back.**
Set `"titleBars": true` or `"roundedCorners": true` in
`~/.config/winapp/config.json`, or `"titleBar": true` on one app in
`apps.json`. Windows that are already open keep the look they have.

**The Windows key does nothing in Windows.**
That is deliberate: Super belongs to Omarchy's shortcuts, and passing it on
made the Start menu open whenever you switched workspace. Ctrl+Esc opens the
Start menu. `"superKey": "windows"` in `config.json` passes the key through.

**Splash screens and tool windows tile.**
They are ordinary windows to Hyprland. A window rule for the class `winapp`
(for example, float everything that is not maximised) is the cure; app windows
all carry that class.

## Starting over

`winapp uninstall --purge` followed by the setup script gives you a clean
slate without touching the VM.
