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
Windows restarted while winapp thought it was still signed in. It normally
notices and retries by itself; if you do see the prompt, close the window and
open the app again.

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
Without sudoless Docker, Omarchy asks on every start and stop. `winapp
passwordless on` waives the prompt for those two actions only.

**It asks once after every reboot even with sudoless Docker.**
Expected: the mounts between your home folder and the VM have to be recreated
by root after a reboot. `winapp passwordless on` covers this too.

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

**Splash screens and tool windows tile.**
They are ordinary windows to Hyprland. A window rule for the class `winapp`
(for example, float everything that is not maximised) is the cure; app windows
all carry that class.

## Starting over

`winapp uninstall --purge` followed by the setup script gives you a clean
slate without touching the VM.
