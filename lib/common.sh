# shellcheck shell=bash
# Paths, messages and small helpers shared by every part of winapp.

CONFIG_DIR=${WINAPP_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/winapp}
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
DATA_DIR=$DATA_HOME/winapp
CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/winapp
# Runtime state (pid files, countdown, launch files). Gone at logout, which is
# what it should be: none of it describes anything that survives a session.
RUN_DIR=${WINAPP_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp/winapp-$UID}/winapp}
LOG_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/winapp/log
BIN_LINK=$HOME/.local/bin/winapp
ME=${USER:-$(id -un)}

have() { command -v "$1" >/dev/null 2>&1; }

version() { jq -r '.version // "unknown"' "$ROOT/manifest.json" 2>/dev/null || echo unknown; }
plugin_id() { jq -r '.id // empty' "$ROOT/manifest.json" 2>/dev/null; }

say() { printf '%s\n' "$*"; }
warn() { printf 'winapp: %s\n' "$*" >&2; }

notify() { # notify [notify-send options] <summary> [body]
  have notify-send || return 0
  notify-send -a "Windows apps" "$@" 2>/dev/null || true
}

# A launch from the menu, a file manager or the bar has nobody reading stderr,
# so the message goes to a notification as well.
die() {
  warn "$*"
  # notify-send reads its body as markup with backslash escapes; Windows paths
  # are full of backslashes
  [[ -t 2 ]] || notify -u critical "Windows apps" "${*//\\/\\\\}"
  exit 1
}

ensure_dirs() { mkdir -p "$RUN_DIR" "$LOG_DIR" && chmod 700 "$RUN_DIR"; }

# True when the winapp on PATH is a link to this one.
cli_linked() { [[ -L $BIN_LINK && $(realpath -- "$BIN_LINK" 2>/dev/null) == "$SELF" ]]; }

# json_edit <file> <jq filter> [jq options...]: rewrite a JSON file in one step.
json_edit() {
  local file=$1 filter=$2 tmp
  shift 2
  tmp=$(mktemp "${file%/*}/.${file##*/}.XXXXXX") || return 1
  if jq "$@" "$filter" "$file" >"$tmp"; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# with_lock <name> <command...>: run the command holding an exclusive lock, so
# two launches started together do not both try to boot or sign in to the VM.
LOCK_FDS=()
with_lock() {
  local name=$1 fd rc
  shift
  ensure_dirs
  exec {fd}>"$RUN_DIR/$name.lock" || return 1
  flock "$fd" || return 1
  LOCK_FDS+=("$fd")
  "$@"
  rc=$?
  exec {fd}>&-
  unset 'LOCK_FDS[-1]'
  return $rc
}

# A lock belongs to the open file, and a child process keeps that file open:
# anything started under a lock that outlives the command (the RDP client, a
# detached timer) has to let go of it first, or the lock is held until it exits.
release_locks() {
  local fd
  for fd in "${LOCK_FDS[@]}"; do exec {fd}>&-; done
}

# detached <command...>: run in the background, in its own session.
detached() { (
  release_locks
  setsid -f "$@" >/dev/null 2>&1
); }

new_log() { # new_log <kind> -> prints the path
  local kind=${1//[^A-Za-z0-9_-]/_} f
  ensure_dirs
  # The newest logs are the ones worth keeping for a bug report.
  # shellcheck disable=SC2012 # names are ours: <kind>-<epoch>.log
  ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +21 | while IFS= read -r f; do rm -f -- "$f"; done
  printf '%s/%s-%s.log\n' "$LOG_DIR" "$kind" "$(date +%Y%m%d-%H%M%S)-$$"
}

# True when asked from a terminal someone can answer in.
interactive() { [[ -t 0 && -t 1 ]]; }

confirm() { # confirm <question>: yes unless the answer is no
  local answer
  if ((ASSUME_YES)); then return 0; fi
  interactive || return 0
  if have gum; then
    gum confirm "$1"
    return
  fi
  read -r -p "$1 [Y/n] " answer
  [[ ${answer,,} != n && ${answer,,} != no ]]
}
ASSUME_YES=0
