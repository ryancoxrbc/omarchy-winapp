# shellcheck shell=bash
# Connecting to the guest with FreeRDP.

CREDENTIALS=$HOME/.config/windows/credentials

# Sets RDP_USER and RDP_PASS. Omarchy keeps a private copy of the guest account
# next to its config; installs from before that only have it in the compose
# file (readable in direct mode), and the installer's defaults are docker/admin.
rdp_credentials() {
  local key value
  RDP_USER="" RDP_PASS=""
  if [[ -r $CREDENTIALS ]]; then
    # IFS on the first = keeps a password that itself contains =
    while IFS='=' read -r key value; do
      case $key in
      USERNAME) RDP_USER=$value ;;
      PASSWORD) RDP_PASS=$value ;;
      esac
    done <"$CREDENTIALS"
  fi
  if [[ -z $RDP_USER || -z $RDP_PASS ]] && [[ -r $COMPOSE ]]; then
    [[ -n $RDP_USER ]] || RDP_USER=$(compose_value USERNAME)
    [[ -n $RDP_PASS ]] || RDP_PASS=$(compose_value PASSWORD)
  fi
  : "${RDP_USER:=docker}" "${RDP_PASS:=admin}"

  # FreeRDP tries Kerberos before NTLM, and the krb5.conf Arch ships names MIT's
  # realm: off the network every connect then stalls for ~20 s looking for its
  # KDC. The guest account is local, so hand FreeRDP a config with no realm.
  ensure_dirs
  printf '[libdefaults]\n  dns_lookup_kdc = false\n  dns_lookup_realm = false\n' >"$RUN_DIR/krb5.conf"
  export KRB5_CONFIG=$RUN_DIR/krb5.conf
}

# A value from Omarchy's compose file, undoing the escaping its writer applied
# (compose interpolation first, then the YAML double-quoted scalar).
compose_value() {
  local v
  v=$(sed -n "s/.*$1: \"\(.*\)\"/\1/p" "$COMPOSE" 2>/dev/null | head -n1)
  v=${v//\$\$/\$}
  v=${v//\\\"/\"}
  v=${v//\\\\/\\}
  printf '%s' "$v"
}

# rdp_spawn <client> <log> <.rdp file or ""> [args...]
# Starts the client in the background and sets RDP_PID.
#
# Arguments go in over stdin, one per line: /proc/<pid>/cmdline is readable by
# other users, and the password would sit there for the whole session.
# /args-from must be the client's only argument. FreeRDP block-buffers its log
# when not on a terminal and callers wait for lines in it, hence stdbuf.
rdp_spawn() {
  local client=$1 log=$2 file=$3
  shift 3
  (
    release_locks
    exec stdbuf -oL -eL "$client" /args-from:stdin
  ) >>"$log" 2>&1 < <(
    [[ -n $file ]] && printf '%s\n' "$file"
    printf '%s\n' "/u:$RDP_USER" "/p:$RDP_PASS" "/v:$RDP_HOST:$RDP_PORT" /cert:ignore "$@"
  ) &
  RDP_PID=$!
}

# xfreerdp3 is an X11 client and Hyprland leaves Xwayland unscaled, so Windows
# is asked to render at the monitor's scale itself.
scale_args() {
  local percent
  percent=$(cfg .scale auto)
  if [[ ! $percent =~ ^[0-9]+$ ]]; then
    percent=$(hyprctl monitors -j 2>/dev/null | jq -r '([.[] | select(.focused)][0].scale // 1) * 100 | floor' 2>/dev/null)
  fi
  [[ $percent =~ ^[0-9]+$ ]] || return 0
  if ((percent >= 170)); then
    printf '%s\n' /scale:180 "/scale-desktop:$percent"
  elif ((percent >= 120)); then
    printf '%s\n' /scale:140 "/scale-desktop:$percent"
  fi
}

# Arguments every visible session shares: the redirected folders, scaling,
# and whatever the user added under "rdpArgs" in config.json.
session_args() {
  drive_args
  scale_args
  printf '%s\n' -grab-keyboard +clipboard /sound /gfx:AVC444
  cfg_json | jq -r '.rdpArgs[]? | select(type == "string" and . != "")'
}

# What a client's log says about why it ended, in words; empty when unknown.
rdp_failure() { # rdp_failure <log>
  local log=$1
  if grep -q 'LOGON_MSG_BUMP_OPTIONS' "$log" 2>/dev/null; then
    echo bump
  elif grep -q 'ERRINFO_RPC_INITIATED_DISCONNECT\|ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION' "$log" 2>/dev/null; then
    echo replaced
  elif grep -q 'RAIL_EXEC_E_\|RAIL exec error' "$log" 2>/dev/null; then
    echo exec
  elif grep -q 'ERRCONNECT_LOGON_FAILURE\|ERRCONNECT_AUTHENTICATION_FAILED\|ERRCONNECT_WRONG_PASSWORD\|STATUS_LOGON_FAILURE' "$log" 2>/dev/null; then
    echo auth
  elif grep -q 'ERRCONNECT_CONNECT_FAILED\|ERRCONNECT_CONNECT_TRANSPORT_FAILED\|ERRCONNECT_DNS' "$log" 2>/dev/null; then
    echo unreachable
  fi
}
