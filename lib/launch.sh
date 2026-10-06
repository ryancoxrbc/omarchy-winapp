# shellcheck shell=bash
# Opening things: an app, a file in its app, a program by path, the desktop.

RDP_PID=""
SEEN=0
FAILURE=""

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

# Start the client for one app and return once its session has settled. Runs
# under the launch lock: a second connection takes over the Windows session,
# and taking it over before the first has asked for its app would lose that app.
app_spawn() { # app_spawn <log> <title> <exe> <command line>
  local log=$1 title=$2 exe=$3 cmdline=$4 file=$RUN_DIR/launch-$$.rdp i n
  local -a args
  # Through the frame program when this VM has it: it starts the app and keeps
  # the session's windows free of Windows' title bar and rounded corners.
  frame_refresh
  FRAMED=0
  if frame_wanted && frame_usable; then
    cmdline="\"$exe\"${cmdline:+ $cmdline}"
    exe=$FRAME_EXE
    FRAMED=1
  fi
  # The program and its arguments travel in a connection file: its values are
  # taken literally, while /app:...,cmd:... is a comma-separated list whose
  # parser gives up on a file name with an apostrophe in it.
  {
    printf 'remoteapplicationmode:i:1\n'
    printf 'remoteapplicationprogram:s:%s\n' "$exe"
    [[ -n $cmdline ]] && printf 'remoteapplicationcmdline:s:%s\n' "$cmdline"
  } >"$file"
  mapfile -t args < <(session_args)
  if [[ $exe == *[,\'\"]* ]]; then
    args+=(+workarea -wallpaper) # what /app:program would have switched on
  else
    args+=("/app:program:$exe")
  fi
  rdp_spawn xfreerdp3 "$log" "$file" "${args[@]}" /wm-class:winapp "/title:$title"
  : >"$RUN_DIR/clients/$RDP_PID"
  SEEN=0
  for ((i = 0; i < 60; i++)); do
    kill -0 "$RDP_PID" 2>/dev/null || break
    # When Windows refuses the single-app logon it shows its own "someone else
    # is signed in" screen in a plain window. That is not an app window.
    if [[ $(rdp_failure "$log") == bump ]]; then
      kill "$RDP_PID" 2>/dev/null
      break
    fi
    n=$(windows "$RDP_PID")
    if [[ ${n:-0} -gt 0 ]]; then
      sleep 1
      [[ $(rdp_failure "$log") == bump ]] && continue
      SEEN=1
      break
    fi
    sleep 0.5
  done
  rm -f "$file"
}

# The RDP session outlives its last app window, so the client never exits by
# itself: drop the connection once every window it showed has been closed.
# Returns 0 when the session ran, 2 when the logon has to be retried, and 1
# with FAILURE set when it never showed anything.
app_watch() { # app_watch <log> <exe>
  local log=$1 exe=$2 seen=$SEEN gone=0 blind=0 n
  while kill -0 "$RDP_PID" 2>/dev/null; do
    sleep 2
    n=$(windows "$RDP_PID") && [[ -n $n ]] || continue
    if ((n > 0)); then
      seen=1 gone=0
    elif ((seen)) && ((++gone >= 4)); then
      kill "$RDP_PID" 2>/dev/null
    elif ((!seen)) && ((++blind >= 90)); then
      # three minutes and nothing to show for it
      kill "$RDP_PID" 2>/dev/null
    fi
  done
  wait "$RDP_PID" 2>/dev/null
  rm -f "$RUN_DIR/clients/$RDP_PID"
  RDP_PID=""
  ((seen)) && return 0

  case $(rdp_failure "$log") in
  bump) return 2 ;;
  replaced) return 0 ;; # a newer launch took the session over; the app lives on there
  exec) FAILURE="Windows could not start $exe. If the app was moved or removed, run: winapp scan" ;;
  auth) FAILURE="Windows rejected the sign-in. Check the account in $CREDENTIALS" ;;
  unreachable) FAILURE="could not reach the Windows VM on $RDP_HOST:$RDP_PORT" ;;
  *) FAILURE="no window appeared for $exe (log: $log)" ;;
  esac
  return 1
}

# launch <kind> <title> <exe> <command line>: the whole life of one app session.
launch() {
  local kind=$1 title=$2 exe=$3 cmdline=$4 log rc=0
  exe=${exe//\//\\} # the config may use either slash
  desktop_open && die "$DESKTOP_IN_THE_WAY"
  mkdir -p "$RUN_DIR/clients"
  for _ in 1 2 3; do
    vm_up "The app opens when the VM is up."
    commit_drives
    log=$(new_log "$kind")
    with_lock launch app_spawn "$log" "$title" "$exe" "$cmdline"
    app_watch "$log" "$exe"
    rc=$?
    if ((rc == 1 && FRAMED)) && [[ $(rdp_failure "$log") == exec ]]; then
      # The frame program is gone from the VM, or Windows will not run it:
      # start apps directly from here on. `winapp setup` puts it back.
      frame_record false
      continue
    fi
    ((rc == 2)) || break
    # Windows was restarted behind our back: claim its session again and retry.
    rm -f "$RUN_DIR/primed" "$RUN_DIR/boot"
    FAILURE="Windows would not start a single-app session (log: $log)"
    desktop_open && FAILURE=$DESKTOP_IN_THE_WAY
  done
  # whatever happened, an unused VM must not be left running for good
  clients_alive || idle_arm
  ((rc == 0)) || die "$FAILURE"
}

launch_cleanup() {
  rm -f "$DRIVES_PENDING" "$RUN_DIR/launch-$$.rdp"
  [[ $(cat "$RUN_DIR/starting" 2>/dev/null) == "$$" ]] && rm -f "$RUN_DIR/starting"
  [[ -n $RDP_PID ]] || return 0
  kill "$RDP_PID" 2>/dev/null
  rm -f "$RUN_DIR/clients/$RDP_PID"
}

# --- commands ----------------------------------------------------------------

cmd_app() { # winapp <app> [file...]
  local id=$1 exe title fixed files
  shift
  exe=$(app_field "$id" exe)
  [[ -n $exe ]] || die "no app called '$id' (see: winapp apps, winapp help)"
  title=$(app_field "$id" name)
  fixed=$(app_field "$id" args)
  files=$(win_args "$@") || exit 1
  launch "$id" "${title:-$id}" "$exe" "$fixed${fixed:+${files:+ }}$files"
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
    *.msi) launch run "$(basename -- "$p")" 'C:\Windows\System32\msiexec.exe' "/i \"$w\"" ;;
    *.exe) launch run "$(basename -- "$p" .exe)" "$w" "$files" ;;
    *) die "$target is not a Windows program; to open it with its Windows app use: winapp open" ;;
    esac
    return
  fi
  files=$(win_args "$@") || exit 1
  launch run "$(basename -- "${target//\\//}" .exe)" "$target" "$files"
}

cmd_open() { # winapp open <file>: whatever Windows opens that file type with
  local p w
  [[ -n ${1:-} ]] || die "usage: winapp open <file>"
  p=$(local_path "$1") || die "no such file: $1"
  w=$(win_path "$p") || exit 1
  launch open "$(basename -- "$p")" 'C:\Windows\System32\rundll32.exe' "url.dll,FileProtocolHandler $w"
}

cmd_explorer() { # winapp explorer [folder]
  local p w
  p=$(local_path "${1:-$HOME}") && [[ -d $p ]] || die "no such folder: ${1:-$HOME}"
  w=$(win_path "$p") || exit 1
  launch explorer "Windows Explorer" 'C:\Windows\explorer.exe' "\"$w\""
}

# The whole Windows desktop in a window, with the same folders redirected: the
# place to install programs. Unlike Omarchy's own launcher it leaves the VM
# running when closed, on the idle timer, ready for the app you just installed.
cmd_desktop() {
  local log
  local -a args
  desktop_open && die "the Windows desktop is already open"
  clients_alive && die "Windows apps are open, and Windows shows either its desktop or single apps, not both. Close the apps first"
  vm_up "The desktop opens when the VM is up."
  commit_drives
  mkdir -p "$RUN_DIR/clients"
  log=$(new_log desktop)
  mapfile -t args < <(session_args)
  rdp_spawn xfreerdp3 "$log" "" "${args[@]}" /wm-class:winapp-desktop "/title:Windows" \
    /dynamic-resolution "/floatbar:sticky:off,default:visible,show:fullscreen"
  : >"$RUN_DIR/clients/$RDP_PID"
  echo "$RDP_PID" >"$RUN_DIR/desktop.pid"
  wait "$RDP_PID" 2>/dev/null
  rm -f "$RUN_DIR/clients/$RDP_PID" "$RUN_DIR/desktop.pid"
  RDP_PID=""
  clients_alive || idle_arm
}
