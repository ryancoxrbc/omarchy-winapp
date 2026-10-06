# shellcheck shell=bash
# Window frames: making app windows sit in a tiling desktop like any other.
#
# Windows draws a title bar on a program's main window and rounds every
# window's corners, and the picture of each window arrives here finished, so
# neither can be changed on the Linux side. A small program does it inside the
# Windows session instead: winapp-frame.exe (guest/frame.cs says what it does
# and what it leaves alone). The apply job builds it in the VM, and apps are
# started through it: it starts the app, then stays for as long as the session
# is connected.

FRAME_SOURCE=$ROOT/guest/frame.cs
FRAME_EXE='C:\ProgramData\winapp\winapp-frame.exe'
FRAMED=0

# What the settings ask for, as the job's JSON. Both settings default to false:
# no Windows title bar, no rounded corners. An app with "titleBar": true in
# apps.json keeps its title bar.
frame_options() {
  local keep='[]'
  [[ -r $APPS_FILE ]] && keep=$(apps_json | jq -c '[.apps[] | select(.titleBar == true) | .exe | split("\\") | last]')
  [[ -n $keep ]] || keep='[]' # an app list that cannot be read keeps nothing
  cfg_json | jq -c --argjson keep "$keep" \
    '{titleBars: (.titleBars == true), roundedCorners: (.roundedCorners == true), keep: $keep}'
}

# False only when both are left to Windows: there is nothing to do then.
frame_wanted() { [[ $(frame_options | jq -r '.titleBars and .roundedCorners') != true ]]; }

# Changes with the program's source and with the settings; either means the
# VM's copy is out of date.
frame_stamp() { { cat "$FRAME_SOURCE" && frame_options; } | cksum | cut -d' ' -f1; }

# The VM's copy is current when there is nothing to send, and usable when apps
# can be started through it. One that would not build, or that Windows would
# not start, is recorded as current but not usable, so that a launch does not
# try again every time; `winapp setup` does.
frame_current() {
  [[ $(cfg_json | jq -r '.guestFrame | "\(.vm) \(.stamp)"') == "$(vm_identity) $(frame_stamp)" ]]
}
frame_usable() {
  [[ $(cfg_json | jq -r '.guestFrame | "\(.vm) \(.ok)"') == "$(vm_identity) true" ]]
}
frame_record() { # frame_record <true|false>
  cfg_edit '.guestFrame = {vm: $vm, stamp: $stamp, ok: $ok}' \
    --arg vm "$(vm_identity)" --arg stamp "$(frame_stamp)" --argjson ok "$1"
}

# The part of an apply job that builds it in the VM, or brings its settings
# there up to date. It is rebuilt only when its source has changed.
frame_job() {
  frame_options | jq -c --arg stamp "$(cksum <"$FRAME_SOURCE" | cut -d' ' -f1)" '{frame: (. + {stamp: $stamp})}'
}

# Record what the last apply job said about it.
frame_noted() {
  local status
  status=$(guest_out '.frame.status')
  if [[ $status == ok ]]; then
    frame_record true
  else
    GUEST_ERROR="Windows could not build the window-frame program (${status:-no answer})"
    frame_record false
    return 1
  fi
}

# A job is a logon of its own, so the session has to be free (guest_run says so
# when it is not; nothing is recorded then, and the next launch from cold
# tries again).
frame_install() { guest_run apply "$(frame_job)" 120 && frame_noted; }

# Before an app is started: bring the VM's copy up to date when that can be
# done now, and do without, quietly, when it cannot.
frame_refresh() {
  frame_wanted || return 0
  frame_current && return 0
  clients_alive && return 0
  frame_install || true
  idle_cancel # the job armed the idle timer, and an app is about to open
}
