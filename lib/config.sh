# shellcheck shell=bash
# Settings (~/.config/winapp/config.json). The app list lives next to it in
# apps.json and is handled by apps.sh.

CONFIG_FILE=$CONFIG_DIR/config.json

ensure_config() {
  [[ -s $CONFIG_FILE ]] && return 0
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<'EOF'
{
  "idleMinutes": 5,
  "shares": [
    { "name": "home", "path": "~" }
  ],
  "scale": "auto",
  "windowsSuffix": "auto",
  "helperWindowFix": true,
  "superKey": "linux",
  "titleBars": false,
  "roundedCorners": false,
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

# Read when needed, not once at start: the setting can change while an app is open.
idle_minutes() {
  local m
  m=$(cfg .idleMinutes 5)
  [[ $m =~ ^[0-9]+$ ]] && echo "$m" || echo 5
}

cmd_idle() {
  [[ ${1:-} =~ ^[0-9]+$ ]] || die "usage: winapp idle <minutes>  (0 = never stop)"
  cfg_set idleMinutes "$1" || die "could not update $CONFIG_FILE"
  # restart the countdown under the new setting when the VM is sitting unused
  if vm_running && ! clients_alive && ! vm_starting; then idle_arm; fi
}
