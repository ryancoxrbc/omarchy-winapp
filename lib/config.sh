# shellcheck shell=bash
# Settings (~/.config/winapp/config.json). The app list lives next to it in
# apps.json and is handled by apps.sh.

CONFIG_FILE=$CONFIG_DIR/config.json

default_config() {
  cat <<'EOF'
{
  "idleMinutes": 5,
  "shares": [
    { "name": "home", "path": "~" }
  ],
  "scale": "auto",
  "windowsSuffix": "auto",
  "helperWindowFix": true,
  "rdpArgs": []
}
EOF
}

ensure_config() {
  [[ -s $CONFIG_FILE ]] && return 0
  mkdir -p "$CONFIG_DIR"
  default_config >"$CONFIG_FILE"
  # 1.x kept the idle timeout in a file of its own
  local old=$CONFIG_DIR/idle-minutes minutes
  if [[ -f $old ]]; then
    minutes=$(<"$old")
    [[ $minutes =~ ^[0-9]+$ ]] && cfg_set idleMinutes "$minutes"
    rm -f "$old"
  fi
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
  local filter=$1 tmp
  shift
  ensure_config
  tmp=$(mktemp "$CONFIG_DIR/.config.XXXXXX") || return 1
  if jq "$@" "$filter" "$CONFIG_FILE" >"$tmp"; then
    mv -f "$tmp" "$CONFIG_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
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
