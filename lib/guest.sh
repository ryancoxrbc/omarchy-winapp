# shellcheck shell=bash
# Running something inside the VM. A job is a PowerShell script, handed a
# redirected folder (\\tsclient\winapp) to read its input from and write its
# results to. While the Windows window is open the agent in it starts the job
# (a hidden request, lib/launch.sh); otherwise it runs as a hidden RemoteApp
# of its own, which is how Windows is first prepared, before there is an agent.

GUEST_DIR=$RUN_DIR/guest
GUEST_ERROR=""
GUEST_BUMPED=0
SESSION_IN_USE="close Omarchy's own Windows window first (winapp cannot reach into it)"
GUEST_COMMAND='powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \\tsclient\winapp\run.ps1'

# guest_run <job> [input json] [timeout seconds]
# Runs guest/<job>.ps1 and leaves its results in $GUEST_DIR (out.json, icons/).
# Returns non-zero with GUEST_ERROR set when it could not.
guest_run() {
  guest_run_once "$@" && return 0
  # refused because the console turned out to be signed in: that session has
  # been claimed by now (console_taken), so the second try is not refused
  ((GUEST_BUMPED)) && guest_run_once "$@"
}

# The folder stays: the desktop's connection redirects it for as long as it is
# open. Only what is in it is replaced.
guest_files() { # guest_files <job> [input json]
  mkdir -p "$GUEST_DIR"
  find "$GUEST_DIR" -mindepth 1 -delete 2>/dev/null
  cp "$ROOT/guest/run.ps1" "$GUEST_DIR/run.ps1"
  cp "$ROOT/guest/$1.ps1" "$GUEST_DIR/job.ps1"
  cp "$ROOT/guest/agent.cs" "$GUEST_DIR/agent.cs" # what the apply job builds, when asked to
  [[ -n ${2:-} ]] && printf '%s' "$2" >"$GUEST_DIR/in.json"
  printf '%s\n' "$RANDOM$RANDOM" >"$GUEST_DIR/probe.txt"
}

guest_wait() { # guest_wait <timeout seconds> [client pid]
  local i
  for ((i = 0; i < $1 * 2; i++)); do
    [[ -e $GUEST_DIR/done ]] && return 0
    if [[ -n ${2:-} ]]; then kill -0 "$2" 2>/dev/null || return 1; else desktop_ours || return 1; fi
    sleep 0.5
  done
  return 1
}

guest_run_once() {
  local job=$1 input=${2:-} timeout=${3:-120} log
  local -a drives
  GUEST_ERROR="" GUEST_BUMPED=0
  if desktop_elsewhere; then
    GUEST_ERROR=$SESSION_IN_USE
    return 1
  fi
  if desktop_ours; then
    if ! agent_usable; then
      GUEST_ERROR="close the Windows window first: winapp's agent is not set up in it yet"
      return 1
    fi
    guest_files "$job" "$input"
    if ! request hidden "$GUEST_COMMAND" 10; then
      GUEST_ERROR="the agent in the Windows window did not take the job"
      return 1
    fi
    guest_wait "$timeout"
  else
    vm_up "Windows is needed for a moment."
    guest_files "$job" "$input"
    log=$(new_log guest)
    mapfile -t drives < <(drive_args)
    rdp_spawn xfreerdp3 "$log" "" "/drive:winapp,$GUEST_DIR" "${drives[@]}" /wm-class:winapp-helper "/title:winapp" \
      "/app:program:powershell.exe,cmd:${GUEST_COMMAND#powershell.exe }"
    guest_wait "$timeout" "$RDP_PID"
    kill "$RDP_PID" 2>/dev/null
    wait "$RDP_PID" 2>/dev/null
    RDP_PID=""
    clients_alive || idle_arm
  fi
  if [[ ! -e $GUEST_DIR/done ]]; then
    if [[ -n ${log:-} && $(rdp_failure "$log") == bump ]]; then
      console_taken
      GUEST_BUMPED=1
      GUEST_ERROR="Windows was restarted; try again"
    else
      GUEST_ERROR="the job did not finish inside the VM${log:+ (log: $log)}"
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

# --- changes to Windows that are the user's to decide --------------------------
# Windows works without either of these, so neither is made until the user has
# said yes, and each is undone when they change their mind (the apply job keeps
# what Windows was set to before):
#
#   fast  ("fastStart" in config.json) Nobody is signed in on the VM's console
#         at boot. As installed, Windows signs the user in there, on a desktop
#         nobody looks at, and every start then has to wait for that and claim
#         the session (lib/vm.sh, "primed").
#   trim  ("trimWindows") The search indexer and Widgets are off.
#
# A setting that is true is applied, false is undone, and one that is not
# there has not been decided: Windows is left as it is, and the question is
# put (changes_ask). What every install needs (RemoteApp for any program, the
# share's cache, the agent) is not asked; `winapp changes` lists it.
CHANGES=(fast trim)

change_key() {
  case $1 in
  fast) echo fastStart ;;
  trim) echo trimWindows ;;
  esac
}

change_title() {
  case $1 in
  fast) echo "Start Windows faster" ;;
  trim) echo "Switch off Windows' search indexer and Widgets" ;;
  esac
}

change_text() {
  case $1 in
  fast) echo "Windows signs in on the VM's own console at every start, and connecting has to wait half a minute for that. With that sign-in switched off, Windows opens about 13 seconds after a cold start instead of 40. The web console on port 8006 then shows Windows' sign-in screen." ;;
  trim) echo "Both run in the background after every start. Switching them off leaves the VM's processors and disk alone; it does not make Windows open faster, and Start menu search still finds programs." ;;
  esac
}

# yes | no | ask. (2.3.0 applied both unasked and had "consoleSignIn": true
# for keeping the sign-in.)
change_state() {
  cfg_json | jq -r --arg key "$(change_key "$1")" --arg name "$1" '
    if .[$key] == true then "yes" elif .[$key] == false then "no"
    elif $name == "fast" and .consoleSignIn == true then "no" else "ask" end'
}

change_set() { # change_set <name> <yes|no|ask>
  local key
  key=$(change_key "$1")
  case $2 in
  yes) cfg_set "$key" true ;;
  no) cfg_set "$key" false ;;
  ask) cfg_edit 'del(.[$k]) | del(.changesAsked[$n])' --arg k "$key" --arg n "$1" ;;
  esac
}

# Undecided changes whose question is due: not put in the last week.
changes_due() {
  local name asked now
  now=$(date +%s)
  for name in "${CHANGES[@]}"; do
    [[ $(change_state "$name") == ask ]] || continue
    asked=$(cfg_json | jq -r --arg n "$name" '.changesAsked[$n] // 0')
    ((now - asked >= 7 * 86400)) && echo "$name"
  done
  return 0
}

# One question, in a terminal: yes, not now, or no for good.
change_choose() { # change_choose <name>
  local name=$1 answer
  say ""
  say "$(change_title "$name")?"
  say "$(change_text "$name")" | fold -s -w 78
  answer=$(gum choose --header="" "Yes" "Not now" "No, and don't ask again") || answer="Not now"
  case $answer in
  Yes) change_set "$name" yes ;;
  No*) change_set "$name" no ;;
  *) cfg_edit '.changesAsked[$n] = $t' --arg n "$name" --argjson t "$(date +%s)" ;;
  esac
}

# The same question for someone who opened an app from the launcher or the
# bar: a notification with the three answers as buttons. One that goes
# unanswered counts as "not now".
change_notify() { # change_notify <name>
  local name=$1 answer
  cfg_edit '.changesAsked[$n] = $t' --arg n "$name" --argjson t "$(date +%s)"
  answer=$(notify-send -a "Windows apps" -t 0 -A "yes=Yes" -A "later=Not now" -A "no=Don't ask again" \
    "$(change_title "$name")?" "$(change_text "$name")" 2>/dev/null)
  case $answer in
  yes)
    change_set "$name" yes
    notify "$(change_title "$name")" "Will be done the next time an app is opened with no other open. Undo with: winapp changes"
    ;;
  no) change_set "$name" no ;;
  esac
}

# Put the questions that are due, without holding anything up: the app that
# is being opened opens meanwhile, on Windows as it is.
changes_ask() {
  [[ -n $(changes_due) ]] && have notify-send || return 0
  detached "$SELF" __ask
}

cmd___ask() {
  local fd name
  ensure_dirs
  exec {fd}>"$RUN_DIR/ask.lock" || return 0
  flock -n "$fd" || return 0 # the questions are on screen already
  for name in $(changes_due); do change_notify "$name"; done
}

cmd_changes() { # winapp changes [allow|deny|ask <name>]
  local action=${1:-} name=${2:-} state
  case $action in
  allow | deny | ask)
    [[ " ${CHANGES[*]} " == *" $name "* && -n $name ]] || die "usage: winapp changes [allow|deny|ask] <${CHANGES[*]}>"
    case $action in allow) state=yes ;; deny) state=no ;; *) state=ask ;; esac
    change_set "$name" "$state" || die "could not update $CONFIG_FILE"
    say "$(change_title "$name"): $state. It reaches Windows the next time the Windows window is opened."
    return 0
    ;;
  "") ;;
  *) die "usage: winapp changes [allow|deny|ask <${CHANGES[*]}>]" ;;
  esac

  say "Changes winapp makes inside Windows"
  say ""
  say "Yours to decide:"
  for name in "${CHANGES[@]}"; do
    state=$(change_state "$name")
    printf '  %-5s %-12s %s\n' "$name" "$(case $state in yes) echo "yes" ;; no) echo "no" ;; *) echo "not decided" ;; esac)" "$(change_title "$name")"
    change_text "$name" | fold -s -w 70 | sed 's/^/                     /'
  done
  say ""
  say "Always, because winapp does not work without them:"
  say "  RemoteApp may start any program (how Windows is first prepared)"
  say "  the ~/Windows share shows Linux-side changes at once (no listing cache)"
  say "  your shared folders are pinned to Quick access"
  say "  a small program (winapp-agent.exe), started at sign-in by a scheduled task,"
  say "  opens the files and apps you ask for from Linux"
  say ""
  if interactive && have gum; then
    for name in "${CHANGES[@]}"; do
      [[ $(change_state "$name") == ask ]] && change_choose "$name"
    done
    say ""
  fi
  say "Change an answer with: winapp changes allow|deny|ask <${CHANGES[*]}>"
}

tune_options() {
  local name state out='{}'
  for name in "${CHANGES[@]}"; do
    state=$(change_state "$name")
    out=$(jq -c --arg n "$name" --arg s "$state" '.[$n] = (if $s == "yes" then true elif $s == "no" then false else null end)' <<<"$out")
  done
  printf '%s\n' "$out"
}

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

# The shared folders are pinned to Quick access, so that file dialogs offer
# them, and one that is no longer shared is unpinned. Done again whenever the
# list of shares has changed.
pins_job() { shares | jq -Rcn '{pin: [inputs | split("\t")[0] | "\\\\tsclient\\" + .]}'; }
pins_current() { [[ $(cfg .guestPinned "") == "$(vm_identity) $(pins_job)" ]]; }
pins_noted() { cfg_set guestPinned "$(printf '%s %s' "$(vm_identity)" "$(pins_job)" | jq -R .)"; }

# A single-app logon was refused: someone is signed in on the console. This
# boot needs the ordinary logon first, and so does every later one until the
# setting has been applied again.
console_taken() {
  rm -f "$RUN_DIR/primed" "$RUN_DIR/boot"
  console_free && tune_record "" true
  return 0
}

# Before the Windows window is opened: bring the VM's copy of the agent and
# the settings up to date when that can be done now, and do without, quietly,
# when it cannot (nothing is recorded then, and the next opening tries again).
standing_refresh() {
  local job='{}'
  agent_current || job=$(agent_job)
  tune_current || job=$(tune_job | jq -c --argjson job "$job" '$job + .')
  pins_current || job=$(pins_job | jq -c --argjson job "$job" '$job + .')
  [[ $job != '{}' ]] || return 0
  if guest_run apply "$job" 120; then
    [[ $(jq 'has("agent")' <<<"$job") == true ]] && { agent_noted || true; }
    [[ $(jq 'has("tune")' <<<"$job") == true ]] && tune_noted
    [[ $(jq 'has("pin")' <<<"$job") == true ]] && pins_noted
  fi
  idle_cancel # the job armed the idle timer, and Windows is about to open
}
