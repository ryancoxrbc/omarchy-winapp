# shellcheck shell=bash
# Running something inside the VM. There is no guest agent: a job is a
# PowerShell script started as a hidden RemoteApp, handed a redirected folder
# (\\tsclient\winapp) to read its input from and write its results to.

GUEST_DIR=$RUN_DIR/guest
GUEST_ERROR=""
GUEST_BUMPED=0
SESSION_IN_USE="close the open Windows apps and desktop first (this needs the VM's only session)"

# guest_run <job> [input json] [timeout seconds]
# Runs guest/<job>.ps1 and leaves its results in $GUEST_DIR (out.json, icons/).
# Returns non-zero with GUEST_ERROR set when it could not.
#
# A job is one more logon, and a logon takes the Windows session (and every
# window in it) away from an app that is open, so it refuses while one is.
guest_run() {
  guest_run_once "$@" && return 0
  # refused because the console turned out to be signed in: that session has
  # been claimed by now (console_taken), so the second try is not refused
  ((GUEST_BUMPED)) && guest_run_once "$@"
}

guest_run_once() {
  local job=$1 input=${2:-} timeout=${3:-120} log i
  local -a drives
  GUEST_ERROR="" GUEST_BUMPED=0
  if clients_alive || desktop_elsewhere; then
    GUEST_ERROR=$SESSION_IN_USE
    return 1
  fi
  vm_up "Windows is needed for a moment."
  rm -rf "$GUEST_DIR"
  mkdir -p "$GUEST_DIR"
  cp "$ROOT/guest/run.ps1" "$GUEST_DIR/run.ps1"
  cp "$ROOT/guest/$job.ps1" "$GUEST_DIR/job.ps1"
  cp "$ROOT/guest/frame.cs" "$GUEST_DIR/frame.cs" # what the apply job builds, when asked to
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
      console_taken
      GUEST_BUMPED=1
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
}

guest_out() { # guest_out [jq options] <filter>: read the last job's result
  jq -r "$@" "$GUEST_DIR/out.json" 2>/dev/null
}

# --- what winapp keeps set in Windows ----------------------------------------
# Two standing settings, applied by the apply job like the frame program and
# brought up to date the same way, before an app is started from cold:
#
#   console  Nobody is signed in on the VM's console at boot. As installed,
#            Windows signs the user in there, on a desktop nobody looks at,
#            and every start then has to wait for that and claim the session
#            (lib/vm.sh, "primed"). "consoleSignIn": true in config.json keeps
#            the sign-in, and the slow start that goes with it.
#   trim     The search indexer and Widgets are off: neither is of use to an
#            app shown on its own. "trimWindows": false leaves them on.
#
# Windows keeps what it was set to before, and gets it back when a setting
# here is switched off again.
tune_options() { cfg_json | jq -c '{console: (.consoleSignIn == true), trim: (.trimWindows != false)}'; }

tune_job() { tune_options | jq -c '{tune: .}'; }

# What the VM was last set to, and whether its console signs in ("console"),
# which is what the job found there afterwards, not what was asked for.
tune_current() {
  [[ $(cfg_json | jq -r '.guestTune | "\(.vm) \(.asked)"') == "$(vm_identity) $(tune_options)" ]]
}

tune_record() { # tune_record <what was asked, or ""> <console signs in: true|false>
  cfg_edit '.guestTune = {vm: $vm, asked: $asked, console: $console}' \
    --arg vm "$(vm_identity)" --arg asked "$1" --argjson console "$2"
}

# Record what the last apply job said. A job that did not say is taken to have
# left a console that signs in: that is the start that always works.
tune_noted() {
  local console
  console=$(guest_out '.tune.console')
  [[ $console == false ]] || console=true
  tune_record "$(tune_options)" "$console"
}

console_free() {
  [[ $(cfg_json | jq -r '.guestTune | "\(.vm) \(.console)"') == "$(vm_identity) false" ]]
}

# A single-app logon was refused: someone is signed in on the console. This
# boot needs the ordinary logon first, and so does every later one until the
# setting has been applied again.
console_taken() {
  rm -f "$RUN_DIR/primed" "$RUN_DIR/boot"
  console_free && tune_record "" true
  return 0
}

# Before an app is started: bring the VM's copy of the frame program and its
# settings up to date when that can be done now, and do without, quietly, when
# it cannot. A job is a logon of its own, so the session has to be free
# (guest_run says so when it is not; nothing is recorded then, and the next
# launch from cold tries again).
standing_refresh() {
  local job='{}'
  if frame_wanted && ! frame_current; then job=$(frame_job); fi
  tune_current || job=$(tune_job | jq -c --argjson job "$job" '$job + .')
  [[ $job != '{}' ]] || return 0
  clients_alive && return 0
  if guest_run apply "$job" 120; then
    [[ $(jq 'has("frame")' <<<"$job") == true ]] && { frame_noted || true; }
    [[ $(jq 'has("tune")' <<<"$job") == true ]] && tune_noted
  fi
  idle_cancel # the job armed the idle timer, and an app is about to open
}
