# shellcheck shell=bash
# Opening things. Windows is shown as one desktop in one window, and
# everything opens in it: an app, a file in its app, a program by path.
#
# One connection, made by `winapp __desktop`, which runs detached so that the
# desktop outlives whatever asked for it (a file manager, the bar, a
# terminal). Every later request is a file in a folder that connection
# redirects (\\tsclient\winappq), which the agent in Windows takes and opens
# (lib/agent.sh, guest/agent.cs). No second logon, no window of its own.

RDP_PID=""
REQUESTS=$RUN_DIR/requests

# The Windows command line for a list of Linux files: each one translated to
# its \\tsclient path and quoted.
win_args() {
  local out="" f p w
  for f in "$@"; do
    p=$(local_path "$f") || die "no such file: $f"
    w=$(win_path "$p") || exit 1
    out+="${out:+ }\"$w\""
  done
  printf '%s' "$out"
}

# --- the desktop ---------------------------------------------------------------

desktop_pid() { # our desktop client, when one is connected
  local pid
  pid=$(cat "$RUN_DIR/desktop.pid" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ && $(cat "/proc/$pid/comm" 2>/dev/null) == xfreerdp3 ]] && echo "$pid"
}
desktop_ours() { [[ -n $(desktop_pid) ]]; }

# Folders are redirected when a connection is made and cannot be added later.
# The connection that is open reaches a file when it redirects every folder
# the request needs, which is what drive_args prints now.
desktop_reaches() {
  local pid
  pid=$(desktop_pid) && [[ -n $pid && $(cat "$RUN_DIR/clients/$pid" 2>/dev/null) == "$(drive_args)" ]]
}

OMARCHY_DESKTOP="Windows is open in Omarchy's own window (Omarchy Windows), which cannot be handed files. Close it, then open the file again: it opens in winapp's Windows window"

# Open the desktop when it is not, and connect it again when the request needs
# a folder it does not redirect: the session, and every app in it, stays as
# it is; only the picture of it is drawn anew. Returns once a client is up.
desktop_ensure() {
  local pid i
  desktop_elsewhere && die "$OMARCHY_DESKTOP"
  desktop_reaches && return 0
  pid=$(desktop_pid)
  if [[ -n $pid ]]; then
    : >"$RUN_DIR/reconnecting"
    kill "$pid" 2>/dev/null
    for ((i = 0; i < 50; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  vm_up "Windows opens when the VM is up."
  # Windows' copy of the agent and the settings, while nothing is connected
  standing_refresh
  commit_drives
  rm -f "$RUN_DIR/desktop.pid"
  detached "$SELF" __desktop
  for ((i = 0; i < 100; i++)); do
    desktop_ours && return 0
    sleep 0.1
  done
  die "the Windows window did not open (log: $(cat "$RUN_DIR/desktop.log" 2>/dev/null))"
}

# Bring the Windows window forward, switching to its workspace. A client that
# has only just started has no window yet to focus: wait for it.
desktop_focus() {
  local pid i n
  pid=$(desktop_pid) && [[ -n $pid ]] || return 0
  for ((i = 0; i < 100; i++)); do
    n=$(windows "$pid")
    ((${n:-0} > 0)) && break
    sleep 0.1
  done
  hyprctl dispatch "hl.dsp.focus({ window = \"pid:$pid\" })" >/dev/null 2>&1 ||
    hyprctl dispatch focuswindow "pid:$pid" >/dev/null 2>&1
  return 0
}

# Why the desktop's client ended, in words, or nothing when it is still up.
desktop_failure() {
  local log
  desktop_ours && return 0
  log=$(cat "$RUN_DIR/desktop.log" 2>/dev/null)
  case $(rdp_failure "$log") in
  auth) echo "Windows rejected the sign-in. Check the account in $CREDENTIALS" ;;
  unreachable) echo "could not reach the Windows VM on $RDP_HOST:$RDP_PORT" ;;
  bump) echo "Windows is signed in elsewhere and asked whether to take over; answer in its window, or close the other session" ;;
  *) echo "the Windows window closed (log: $log)" ;;
  esac
}

# The detached half of desktop_ensure: the client, for as long as it is open.
cmd___desktop() {
  local log
  local -a args
  rdp_credentials
  mkdir -p "$RUN_DIR/clients" "$REQUESTS" "$GUEST_DIR"
  rm -f "$REQUESTS"/*
  log=$(new_log desktop)
  echo "$log" >"$RUN_DIR/desktop.log"
  mapfile -t args < <(session_args)
  rdp_spawn xfreerdp3 "$log" "" "${args[@]}" "/drive:winappq,$REQUESTS" "/drive:winapp,$GUEST_DIR" \
    /wm-class:winapp-desktop "/title:Windows" /dynamic-resolution \
    "/floatbar:sticky:off,default:visible,show:fullscreen"
  # the folders it redirects, which decide what can be opened in it
  drive_args >"$RUN_DIR/clients/$RDP_PID"
  echo "$RDP_PID" >"$RUN_DIR/desktop.pid"
  rm -f "$RUN_DIR/reconnecting"
  wait "$RDP_PID" 2>/dev/null
  rm -f "$RUN_DIR/clients/$RDP_PID"
  [[ $(cat "$RUN_DIR/desktop.pid" 2>/dev/null) == "$RDP_PID" ]] && rm -f "$RUN_DIR/desktop.pid"
  RDP_PID=""
  # closed to be connected again at once, with another folder
  [[ -e $RUN_DIR/reconnecting ]] && return 0
  clients_alive && return 0
  idle_arm
  still_open_warning
}

# Closing the window does not close the apps in it. Where Windows can sleep,
# that keeps them as they are; where it can only be shut down when idle, that
# would lose what they have not saved. The agent keeps a list of their windows
# in the request folder; what it said last is what was open.
still_open_warning() {
  local open minutes
  can_sleep && return 0
  minutes=$(idle_minutes)
  ((minutes > 0)) || return 0
  open=$(sed '/^[[:space:]]*$/d' "$REQUESTS/open.txt" 2>/dev/null | head -n 6)
  [[ -n $open ]] || return 0
  open=${open//\\/\\\\} # notify-send reads backslash escapes and markup
  open=${open//&/&amp;}
  open=${open//</&lt;}
  open=${open//>/&gt;}
  notify -u critical "Still open in Windows" "$open

These keep running. Windows stops after $minutes idle minutes, and anything not saved is lost then. Open Windows again to get back to them."
}

# --- requests ------------------------------------------------------------------

# request <open|hidden> <command line> <seconds>: hand the desktop a command
# line. Taking it is a rename, which only one side can win, so a request that
# nobody took in time is withdrawn and the caller told.
request() {
  local kind=$1 line=$2 seconds=$3 file i
  mkdir -p "$REQUESTS"
  file=$REQUESTS/$$-$RANDOM
  printf '%s\n%s\n' "$kind" "$line" >"$file.new" && mv "$file.new" "$file.req" || return 1
  for ((i = 0; i < seconds * 10; i++)); do
    [[ -e $file.req ]] || return 0
    ((i % 10)) || desktop_ours || break
    sleep 0.1
  done
  mv "$file.req" "$file.gone" 2>/dev/null || return 0 # taken at the last moment
  rm -f "$file.gone"
  return 1
}

# launch <exe> <command line>: open a program, with its arguments, in Windows.
launch() {
  local line="\"${1//\//\\}\"${2:+ $2}"
  changes_ask
  with_lock launch launch_locked "$line"
}

launch_locked() {
  local line=$1 seconds=10
  # a desktop that is only now signing in takes a while to start the agent
  desktop_reaches || seconds=120
  desktop_ensure
  desktop_focus
  if ! agent_usable; then
    die "Windows is open, but winapp's agent could not be set up in it, so nothing can be opened from Linux. See: winapp doctor --deep"
  fi
  if request open "$line" "$seconds"; then
    desktop_focus
    return 0
  fi
  desktop_ours || die "$(desktop_failure)"
  die "Windows did not pick up the request. If it is still signing in, try again in a moment; otherwise see: winapp doctor --deep"
}

launch_cleanup() {
  rm -f "$DRIVES_PENDING" "$REQUESTS/$$"-*
  [[ $(cat "$RUN_DIR/starting" 2>/dev/null) == "$$" ]] && rm -f "$RUN_DIR/starting"
  [[ -n $RDP_PID ]] || return 0
  kill "$RDP_PID" 2>/dev/null
  rm -f "$RUN_DIR/clients/$RDP_PID"
}

# --- commands ----------------------------------------------------------------

cmd_app() { # winapp <app> [file...]
  local id=$1 exe fixed files
  shift
  exe=$(app_field "$id" exe)
  [[ -n $exe ]] || die "no app called '$id' (see: winapp apps, winapp help)"
  fixed=$(app_field "$id" args)
  files=$(win_args "$@") || exit 1
  launch "$exe" "$fixed${fixed:+${files:+ }}$files"
}

cmd_run() { # winapp run <program> [file...]
  local target=${1:-} p w files
  [[ -n $target ]] || die "usage: winapp run '<Windows path to the .exe>' [file...]   or   winapp run <installer on Linux>"
  shift
  if [[ $target != [A-Za-z]:[\\/]* && $target != \\\\* ]] && p=$(local_path "$target"); then
    # a program or installer that lives on the Linux side
    w=$(win_path "$p") || exit 1
    files=$(win_args "$@") || exit 1
    case ${p,,} in
    *.msi) launch 'C:\Windows\System32\msiexec.exe' "/i \"$w\"" ;;
    *.exe) launch "$w" "$files" ;;
    *) die "$target is not a Windows program; to open it with its Windows app use: winapp open" ;;
    esac
    return
  fi
  files=$(win_args "$@") || exit 1
  launch "$target" "$files"
}

cmd_open() { # winapp open <file>: whatever Windows opens that file type with
  local p w
  [[ -n ${1:-} ]] || die "usage: winapp open <file>"
  p=$(local_path "$1") || die "no such file: $1"
  w=$(win_path "$p") || exit 1
  launch 'C:\Windows\System32\rundll32.exe' "url.dll,FileProtocolHandler $w"
}

cmd_explorer() { # winapp explorer [folder]: the first shared folder when none is given
  local p w first
  first=$(shares | head -n1 | cut -f2)
  [[ -n ${1:-$first} ]] || die "no folder is shared yet; name one (winapp explorer <folder>) or choose some: winapp share pick"
  p=$(local_path "${1:-$first}") && [[ -d $p ]] || die "no such folder: ${1:-$first}"
  w=$(win_path "$p") || exit 1
  launch 'C:\Windows\explorer.exe' "\"$w\""
}

# The Windows window itself: opened when it is not, brought forward when it is.
cmd_desktop() {
  changes_ask
  with_lock launch desktop_ensure
  desktop_focus
}
