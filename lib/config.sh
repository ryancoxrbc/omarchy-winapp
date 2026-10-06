# shellcheck shell=bash
# Settings (~/.config/winapp/config.json). The app list lives next to it in
# apps.json and is handled by apps.sh.

CONFIG_FILE=$CONFIG_DIR/config.json

ensure_config() {
  [[ -s $CONFIG_FILE ]] && return 0
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<'EOF'
{
  "mode": "cold",
  "idleMinutes": 5,
  "shares": [
    { "name": "home", "path": "~" }
  ],
  "scale": "auto",
  "pointerScale": "auto",
  "windowsSuffix": "auto",
  "helperWindowFix": true,
  "superKey": "linux",
  "titleBars": false,
  "roundedCorners": false,
  "consoleSignIn": false,
  "trimWindows": true,
  "rdpArgs": []
}
EOF
}

cfg_json() {
  ensure_config
  jq -e . "$CONFIG_FILE" 2>/dev/null || die "$CONFIG_FILE is not valid JSON"
}

# cfg <jq path> <fallback>: one scalar setting.
cfg() {
  local value
  value=$(cfg_json | jq -r "$1 // empty")
  printf '%s\n' "${value:-$2}"
}

# cfg_edit <jq filter> [jq options...]: rewrite config.json in one step.
cfg_edit() {
  ensure_config
  json_edit "$CONFIG_FILE" "$@"
}

# cfg_set <key> <json value>
cfg_set() { cfg_edit '.[$k] = $v' --arg k "$1" --argjson v "$2"; }

# Cold or warm: whether Windows is started for an app and stopped when idle,
# or started at login and kept. Warm, the first app opens as fast as any other
# (about 3 s, not 15), and Windows holds its memory for as long as you are
# logged in.
warm() { [[ $(cfg .mode cold) == warm ]]; }

# Read when needed, not once at start: the setting can change while an app is open.
idle_minutes() {
  local m
  if warm; then
    echo 0
    return
  fi
  m=$(cfg .idleMinutes 5)
  [[ $m =~ ^[0-9]+$ ]] && echo "$m" || echo 5
}

cmd_idle() {
  [[ ${1:-} =~ ^[0-9]+$ ]] || die "usage: winapp idle <minutes>  (0 = never stop)"
  cfg_set idleMinutes "$1" || die "could not update $CONFIG_FILE"
  # restart the countdown under the new setting when the VM is sitting unused
  if vm_running && ! clients_alive && ! vm_starting; then idle_arm; fi
}

# Warm, Windows is started once per login, by the first `winapp state` (the
# bar asks as soon as it is up). Once, so that stopping it by hand holds: it
# then stays off until an app is opened or you log in again.
warm_start() {
  warm && vm_installed && [[ ! -e $RUN_DIR/warmed ]] || return 0
  ensure_dirs
  : >"$RUN_DIR/warmed"
  detached "$SELF" start
}

cmd_mode() {
  local ram cores
  case ${1:-} in
  "")
    read -r ram cores <<<"$(vm_resources)"
    if warm; then
      say "warm: Windows starts when you log in and stays on, so every app opens in a few seconds."
      say "It holds its memory${ram:+ (${ram%G} GB)} the whole time. Change with: winapp mode cold"
    else
      say "cold: Windows starts when you open an app and stops when idle ($(idle_minutes) min),"
      say "so it uses no memory in between. The first app takes about 15 seconds."
      say "Change with: winapp mode warm"
    fi
    ;;
  warm)
    cfg_set mode '"warm"' || die "could not update $CONFIG_FILE"
    idle_cancel
    ensure_dirs
    : >"$RUN_DIR/warmed"
    vm_installed && ! vm_running && ! vm_starting && detached "$SELF" start
    return 0
    ;;
  cold)
    cfg_set mode '"cold"' || die "could not update $CONFIG_FILE"
    # sitting unused, it is now something to stop
    if vm_running && ! clients_alive && ! vm_starting; then idle_arm; fi
    ;;
  *) die "usage: winapp mode [cold|warm]" ;;
  esac
}
