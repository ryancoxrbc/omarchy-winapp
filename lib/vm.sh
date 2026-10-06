# shellcheck shell=bash
# The VM itself: Omarchy's Windows VM, a dockur/windows container that
# `omarchy-windows-vm install` sets up. winapp never creates or reconfigures
# it; it only starts it, waits for it, and stops it.
#
# Omarchy keeps users out of the docker group by default, so there are two ways
# to reach the container:
#   direct  the Docker socket is writable (sudoless Docker is on)
#   prompt  it is not, and starting or stopping goes through Omarchy's own
#           privileged helper behind polkit, the same way its launcher does
# Everything that polls (the bar asks every few seconds) has to work without
# Docker, so "is it running" falls back to probing the published ports.

VM_DIR=${WINAPP_VM_DIR:-/var/lib/omarchy/windows}
COMPOSE=$VM_DIR/docker-compose.yml
LEGACY_COMPOSE=$HOME/.config/windows/docker-compose.yml
MOUNTS=$VM_DIR/mounts/users/$UID
CONTAINER=omarchy-windows
VM_HELPER=${WINAPP_VM_HELPER:-/usr/bin/omarchy-windows-vm}
STORAGE_DIR=$HOME/.windows
SHARED_DIR=$HOME/Windows
# where Omarchy's compose file publishes the guest's RDP and web console
RDP_HOST=${WINAPP_RDP_HOST:-127.0.0.1}
RDP_PORT=${WINAPP_RDP_PORT:-3389}
WEB_PORT=${WINAPP_WEB_PORT:-8006}

docker_direct() { have docker && [[ -w ${OMARCHY_DOCKER_SOCKET:-/var/run/docker.sock} ]]; }

compose() {
  if have docker-compose; then docker-compose "$@"; else docker compose "$@"; fi
}

vm_installed() { [[ -e $COMPOSE || -f $LEGACY_COMPOSE ]]; }

port_open() { timeout 1 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

vm_running() {
  if docker_direct; then
    [[ $(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null) == running ]]
  else
    # Docker publishes the web console for exactly as long as the container runs.
    port_open "$RDP_HOST" "$WEB_PORT"
  fi
}

marker_alive() { # a file holding the pid of the process that is doing something
  local pid
  pid=$(cat "$RUN_DIR/$1" 2>/dev/null) || return 1
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}
vm_starting() { marker_alive starting; }
vm_stopping() { marker_alive stopping; }

# Something that changes whenever the VM has been restarted. Without Docker
# there is nothing to ask, so a marker stands in: it is made the first time the
# VM is seen running and dropped the first time it is seen stopped.
vm_boot_id() {
  if docker_direct; then
    docker inspect --format='{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null
    return
  fi
  ensure_dirs
  [[ -s $RUN_DIR/boot ]] || date +%s.%N >"$RUN_DIR/boot"
  cat "$RUN_DIR/boot"
}

# Forget everything that belonged to the boot that just ended.
vm_note_stopped() {
  idle_cancel
  rm -f "$RUN_DIR"/{boot,primed,drives.tsv}
}

# --- sessions and windows ----------------------------------------------------

# Every RDP client winapp starts leaves a pid file, so "is anything open" does
# not mistake an unrelated xfreerdp3 for one of ours.
clients_alive() {
  local f pid
  for f in "$RUN_DIR"/clients/*; do
    [[ -e $f ]] || continue
    pid=${f##*/}
    if [[ $(cat "/proc/$pid/comm" 2>/dev/null) == xfreerdp3 ]]; then return 0; fi
    rm -f "$f"
  done
  return 1
}

clients_kill() {
  local f
  for f in "$RUN_DIR"/clients/*; do
    [[ -e $f ]] || continue
    kill "${f##*/}" 2>/dev/null
    rm -f "$f"
  done
}

# Titled windows of our RDP clients that are real app windows (FreeRDP also
# maps an off-screen "RemoteApp Marker Window").
APP_WINDOWS='select((.class == "winapp" or .class == "winapp-desktop") and .title != "" and .title != "RemoteApp Marker Window")'

windows() { # windows [pid]: how many app windows are on screen (of one client)
  local filter=.
  [[ -n ${1:-} ]] && filter="select(.pid == $1)"
  hyprctl clients -j 2>/dev/null | jq "[.[] | $filter | $APP_WINDOWS] | length" 2>/dev/null
}

# --- starting ----------------------------------------------------------------

# Releases of Omarchy before the fix for omacom/omarchy#9334 fail to start the
# VM a second time: dockur leaves the setgid bit on the shared folder, the
# helper's `chmod 0700` keeps it (GNU chmod preserves it for four-digit modes),
# and its exact-mode check then refuses the mount. A five-digit mode clears the
# bit. Omarchy sets these two directories to 0700 itself, so this changes
# nothing on a release that has the fix.
harden_dirs() {
  local d
  for d in "$SHARED_DIR" "$STORAGE_DIR"; do
    [[ -d $d && -O $d ]] && chmod 00700 "$d" 2>/dev/null
  done
  return 0
}

# Omarchy binds ~/.windows and ~/Windows onto root-owned anchors and gives
# Docker only those. The binds are gone after a reboot and only root can
# recreate them; `compose up` without them would boot the VM on an empty disk.
anchors_ready() {
  local anchor source
  for anchor in storage shared; do
    [[ $anchor == storage ]] && source=$STORAGE_DIR || source=$SHARED_DIR
    mountpoint -q "$MOUNTS/$anchor" 2>/dev/null || return 1
    [[ $(stat -Lc '%d:%i' "$MOUNTS/$anchor" 2>/dev/null) == "$(stat -Lc '%d:%i' "$source" 2>/dev/null)" ]] || return 1
  done
}

# Why a pkexec call failed, in words: 126 is "dismissed", 127 "not authorized".
explain_pkexec() {
  case $1 in
  126 | 127) echo "authorization was cancelled" ;;
  *) echo "see $2" ;;
  esac
}

vm_start() { # vm_start <log>
  local log=$1 rc=0
  harden_dirs
  if docker_direct && [[ -r $COMPOSE ]] && anchors_ready; then
    compose -f "$COMPOSE" up -d >>"$log" 2>&1 || rc=$?
  else
    [[ -x $VM_HELPER ]] || die "Omarchy's Windows VM helper is missing ($VM_HELPER); run: omarchy update"
    pkexec "$VM_HELPER" __priv up_wait >>"$log" 2>&1 || rc=$?
  fi
  ((rc == 0)) || die "could not start the Windows VM ($(explain_pkexec "$rc" "$log"))"
}

# After a boot Windows signs the user in on its own console, and a single-app
# (RemoteApp) logon cannot take that session over: it fails with
# LOGON_MSG_BUMP_OPTIONS until an ordinary RDP logon has claimed the session.
# So one ordinary logon is made per boot, with FreeRDP's windowless sample
# client. That logon doubles as the test for "the guest is ready".
primed() {
  local id
  id=$(vm_boot_id)
  [[ -n $id && $(cat "$RUN_DIR/primed" 2>/dev/null) == "$id" ]]
}

# --- the desktop -------------------------------------------------------------
# Windows on a desktop edition shows one session at a time: either the desktop
# or the session single apps run in. Whichever is connected, a logon to the
# other is refused (or, for the desktop, answered with a "someone else is
# signed in" prompt). So the two are kept apart here, with a message that says
# so, instead of failing in the middle of a launch.

# Omarchy's own "Windows" launcher holding the desktop open. A logon of ours
# would take its session away, which that launcher answers by shutting the VM
# down. (Its client names the server on its command line; ours are given
# theirs over stdin.)
desktop_elsewhere() { pgrep -f "xfreerdp3 .*/v:$RDP_HOST:$RDP_PORT" >/dev/null 2>&1; }

desktop_open() { # ours (`winapp desktop`), or that launcher's
  local pid
  pid=$(cat "$RUN_DIR/desktop.pid" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ && $(cat "/proc/$pid/comm" 2>/dev/null) == xfreerdp3 ]] || desktop_elsewhere
}

DESKTOP_IN_THE_WAY="the Windows desktop is open, and Windows shows either its desktop or single apps, not both. Close the desktop window first"

prime_once() { # prime_once <log>
  local log=$1 i ok=1
  local client=sfreerdp3 extra=()
  # Without the sample client, a small ordinary window shows for a moment.
  have sfreerdp3 || client=xfreerdp3 extra=(/size:640x480 /wm-class:winapp-helper "/title:Signing in to Windows")
  : >"$log"
  rdp_spawn "$client" "$log" "" "${extra[@]}"
  for ((i = 0; i < 40; i++)); do
    if grep -q 'Logon Extended Info' "$log" 2>/dev/null; then
      ok=0
      break
    fi
    kill -0 "$RDP_PID" 2>/dev/null || break
    sleep 0.5
  done
  ((ok == 0)) && sleep 1 # let the logon finish before dropping it
  kill "$RDP_PID" 2>/dev/null
  wait "$RDP_PID" 2>/dev/null
  RDP_PID=""
  return $ok
}

# Wait until Windows accepts a logon. The container reports "started" as soon
# as QEMU runs; the guest needs most of a minute more.
wait_guest() { # wait_guest <log>
  local log=$1 deadline=$((SECONDS + 240)) started
  if docker_direct; then
    # docker logs persist across restarts, hence --since this start
    while ((SECONDS < deadline)); do
      started=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)
      [[ -n $started ]] || return 1 # the container is gone
      docker logs --since "$started" "$CONTAINER" 2>&1 | grep -qi "windows started successfully" && break
      sleep 2
    done
  fi
  while ((SECONDS < deadline)); do
    vm_running || return 1
    if port_open "$RDP_HOST" "$RDP_PORT" && prime_once "${log%.log}-prime.log"; then
      vm_boot_id >"$RUN_DIR/primed"
      return 0
    fi
    sleep 2
  done
  return 1
}

# Start the VM if needed and return once a RemoteApp logon will work.
vm_up() { # vm_up [what to tell the user while it boots]
  vm_installed || die "the Windows VM is not set up yet; run: omarchy-windows-vm install"
  [[ -e $COMPOSE ]] || die "the Windows VM uses Omarchy's old layout; open Windows once from the app launcher to migrate it"
  rdp_credentials
  with_lock vm vm_up_locked "$@"
}

vm_up_locked() {
  local log i
  idle_cancel
  # a shutdown that is under way has to finish before Windows can start again
  for ((i = 0; i < 150; i++)); do
    vm_stopping || break
    sleep 1
  done
  if vm_running && { primed || desktop_elsewhere; }; then return 0; fi
  log=$(new_log vm)
  echo $$ >"$RUN_DIR/starting"
  if ! vm_running; then
    notify "Starting Windows…" "${1:-This takes about a minute.}"
    vm_start "$log"
  fi
  if ! wait_guest "$log"; then
    rm -f "$RUN_DIR/starting"
    clients_alive || idle_arm
    die "Windows did not accept a sign-in. If it is still installing, watch http://$RDP_HOST:$WEB_PORT (log: $log)"
  fi
  rm -f "$RUN_DIR/starting"
}

# --- stopping ----------------------------------------------------------------

vm_stop() {
  local rc=0
  ensure_dirs
  idle_cancel
  if ! vm_running; then
    vm_note_stopped
    return 0
  fi
  echo $$ >"$RUN_DIR/stopping"
  if docker_direct && [[ -r $COMPOSE ]]; then
    compose -f "$COMPOSE" down >/dev/null 2>&1 || rc=$?
  else
    "$VM_HELPER" stop >/dev/null 2>&1 || rc=$?
  fi
  rm -f "$RUN_DIR/stopping"
  ((rc == 0)) || return $rc
  clients_kill
  vm_note_stopped
}

# Shut the VM down after it has sat unused. The file holds "<token> <deadline>"
# so the bar widget can show a countdown; a new launch cancels the timer, and a
# timer that was somehow left behind finds its token gone and does nothing.
idle_cancel() {
  local pid
  pid=$(cat "$RUN_DIR/idle.pid" 2>/dev/null)
  [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
  rm -f "$RUN_DIR/idle" "$RUN_DIR/idle.pid"
}

idle_arm() {
  local minutes token=$RANDOM$RANDOM
  ensure_dirs
  idle_cancel
  minutes=$(idle_minutes)
  ((minutes > 0)) || return 0
  echo "$token $(($(date +%s) + minutes * 60))" >"$RUN_DIR/idle"
  detached "$SELF" __idle "$token" "$minutes"
}

cmd___idle() { # the detached half of idle_arm
  local token=$1 minutes=$2 sleeper
  echo $$ >"$RUN_DIR/idle.pid"
  sleep $((minutes * 60)) &
  sleeper=$!
  # shellcheck disable=SC2064 # the pid as it is now
  trap "kill $sleeper 2>/dev/null; exit 0" TERM INT
  wait "$sleeper"
  [[ $(cut -d' ' -f1 "$RUN_DIR/idle" 2>/dev/null) == "$token" ]] || exit 0
  rm -f "$RUN_DIR/idle.pid"
  # not ours to stop while something else is using it
  clients_alive && exit 0
  desktop_elsewhere && exit 0
  # In prompt mode the stop asks for a password; say why a prompt is appearing.
  if ! docker_direct && [[ $(cfg .passwordless false) != true ]]; then
    notify "Stopping Windows" "Idle for $minutes min. Omarchy asks for your password to stop the VM."
  fi
  # A dismissed password prompt leaves it running. Say so once rather than ask
  # again every few minutes; the next app that closes starts the timer afresh.
  vm_stop || notify "Windows is still running" "Stopping it was not authorized. Stop it from the bar when you are done."
}

# --- status ------------------------------------------------------------------

vm_state() { # stopped | starting | running | stopping
  if vm_stopping; then
    echo stopping
  elif vm_starting; then
    echo starting
  elif vm_running; then
    echo running
  else
    echo stopped
  fi
}

# One JSON object for the bar widget. Cheap enough to be asked every few seconds.
cmd_state() {
  local vm deadline=0 n=0 installed=false access=prompt desktop=false apps='[]' ram="" cores=""
  vm_installed && installed=true
  docker_direct && access=direct
  vm=$(vm_state)
  if [[ $vm == stopped ]]; then
    vm_note_stopped
  else
    n=$(windows)
    desktop_open && desktop=true
    [[ $vm == running ]] && deadline=$(awk '{print $2}' "$RUN_DIR/idle" 2>/dev/null)
  fi
  read -r ram cores <<<"$(vm_resources)"
  # another launcher entry appeared or went: ours may need renaming to stay distinct
  menu_stale && detached "$SELF" sync --quiet
  [[ -s $APPS_FILE ]] && apps=$(jq -c '[.apps[]? | select(.panel != false)
      | {id, name: (.name // .id), label: (.label // .name // .id), icon: (.icon // "")}]' "$APPS_FILE" 2>/dev/null)
  jq -cn --arg vm "$vm" --arg access "$access" --arg version "$(version)" \
    --argjson installed "$installed" --argjson windows "${n:-0}" --argjson desktop "$desktop" \
    --arg ram "${ram:-}" --arg cores "${cores:-}" \
    --argjson idle "$(idle_minutes)" --argjson deadline "${deadline:-0}" \
    --argjson now "$(date +%s)" --argjson apps "${apps:-[]}" \
    '{version: $version, installed: $installed, vm: $vm, access: $access, windows: $windows, desktop: $desktop,
      ram: $ram, cores: $cores,
      idleMinutes: $idle, idleDeadline: $deadline, now: $now, apps: $apps}'
}

cmd_status() {
  local vm
  vm_installed || { say "Windows VM is not set up (run: omarchy-windows-vm install)"; return 1; }
  vm=$(vm_state)
  if [[ $vm != running ]]; then
    say "Windows VM $vm"
  elif desktop_open; then
    say "Windows VM running, desktop open"
  else
    say "Windows VM running, $(windows) app window(s), idle shutdown after $(idle_minutes) min"
  fi
}

cmd_start() {
  vm_up
  # nothing to show, just leave the VM up on its idle timer
  clients_alive || idle_arm
}

cmd_stop() {
  vm_installed || die "the Windows VM is not set up"
  if ! vm_stop; then
    # still running, so it is still something to shut down when idle
    clients_alive || idle_arm
    die "could not stop the Windows VM (was the password prompt dismissed?)"
  fi
}
