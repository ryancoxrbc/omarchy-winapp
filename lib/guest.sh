# shellcheck shell=bash
# Running something inside the VM. There is no guest agent: a job is a
# PowerShell script started as a hidden RemoteApp, handed a redirected folder
# (\\tsclient\winapp) to read its input from and write its results to.

GUEST_DIR=$RUN_DIR/guest
GUEST_ERROR=""

# guest_run <job> [input json] [timeout seconds]
# Runs guest/<job>.ps1 and leaves its results in $GUEST_DIR (out.json, icons/).
# Returns non-zero with GUEST_ERROR set when it could not.
#
# A job is one more logon, and a logon takes the Windows session (and every
# window in it) away from an app that is open, so it refuses while one is.
guest_run() {
  local job=$1 input=${2:-} timeout=${3:-120} log i
  local -a drives
  GUEST_ERROR=""
  if clients_alive || desktop_elsewhere; then
    GUEST_ERROR="close the open Windows apps and desktop first (this needs the VM's only session)"
    return 1
  fi
  vm_up "Windows is needed for a moment."
  rm -rf "$GUEST_DIR"
  mkdir -p "$GUEST_DIR"
  cp "$ROOT/guest/run.ps1" "$GUEST_DIR/run.ps1"
  cp "$ROOT/guest/$job.ps1" "$GUEST_DIR/job.ps1"
  [[ -n $input ]] && printf '%s' "$input" >"$GUEST_DIR/in.json"
  printf '%s\n' "$RANDOM$RANDOM" >"$GUEST_DIR/probe.txt"
  log=$(new_log guest)
  mapfile -t drives < <(drive_args)
  rdp_spawn xfreerdp3 "$log" "" "/drive:winapp,$GUEST_DIR" "${drives[@]}" /wm-class:winapp-helper "/title:winapp" \
    '/app:program:powershell.exe,cmd:-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \\tsclient\winapp\run.ps1'
  for ((i = 0; i < timeout * 2; i++)); do
    [[ -e $GUEST_DIR/done ]] && break
    kill -0 "$RDP_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill "$RDP_PID" 2>/dev/null
  wait "$RDP_PID" 2>/dev/null
  RDP_PID=""
  clients_alive || idle_arm
  if [[ ! -e $GUEST_DIR/done ]]; then
    if [[ $(rdp_failure "$log") == bump ]]; then
      rm -f "$RUN_DIR/primed" "$RUN_DIR/boot"
      GUEST_ERROR="Windows was restarted; try again"
    else
      GUEST_ERROR="the job did not finish inside the VM (log: $log)"
    fi
    return 1
  fi
  if [[ -s $GUEST_DIR/error.txt ]]; then
    GUEST_ERROR="the job failed inside the VM: $(tr -d '\r' <"$GUEST_DIR/error.txt" | sed '/^[[:space:]]*$/d' | head -n 3 | tr '\n' ' ')"
    return 1
  fi
  return 0
}

guest_out() { # guest_out [jq options] <filter>: read the last job's result
  jq -r "$@" "$GUEST_DIR/out.json" 2>/dev/null
}
