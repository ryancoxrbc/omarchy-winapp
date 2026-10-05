# shellcheck shell=bash
# How much memory and how many processors the VM gets.
#
# Both live in Omarchy's compose file, which is root-owned and only ever
# written by Omarchy's own helper from values it validates. A change here goes
# through that same writer (`__priv write_compose`), which takes the whole set:
# memory, processors, disk size, account and time zone. Everything but the
# first two is handed back exactly as it is now. The disk size in particular
# must not drift: dockur would take a larger figure as a request to grow the
# disk.

HOST_CORES=$(nproc 2>/dev/null || echo 1)
HOST_RAM_GB=$(awk '/^MemTotal:/ { printf "%d", $2 / 1048576 }' /proc/meminfo 2>/dev/null)

# What the VM is set to, as "<ram> <cores>" (for example "16G 4"); nothing
# when it cannot be told. The compose file says, when it can be read (sudoless
# Docker); otherwise a running VM shows what it was started with, and failing
# that the values last set from here are remembered.
# The command line of the VM's emulator, when it is running. dockur names the
# process "windows", so it has to be found by its arguments.
qemu_args() { pgrep -af 'qemu-system' 2>/dev/null | grep -m1 -- ' -name windows'; }

vm_resources() {
  local ram="" cores="" args
  if [[ -r $COMPOSE ]]; then
    ram=$(compose_value RAM_SIZE)
    cores=$(compose_value CPU_CORES)
  fi
  if [[ -z $ram || -z $cores ]]; then
    args=" $(qemu_args) "
    [[ $args =~ \ -m\ ([0-9]+G)\  ]] && ram=${BASH_REMATCH[1]}
    [[ $args =~ \ -smp\ ([0-9]+)[,\ ] ]] && cores=${BASH_REMATCH[1]}
  fi
  [[ -n $ram ]] || ram=$(cfg .vmRam "")
  [[ -n $cores ]] || cores=$(cfg .vmCores "")
  [[ -n $ram && -n $cores ]] && printf '%s %s\n' "$ram" "$cores"
}

# The disk size the VM was created with, as dockur wants it ("100G").
vm_disk() {
  local disk bytes
  if [[ -r $COMPOSE ]]; then
    disk=$(compose_value DISK_SIZE)
    [[ $disk =~ ^[0-9]+G$ ]] && { echo "$disk"; return 0; }
  fi
  # the image is exactly as large as the size it was created with
  bytes=$(stat -Lc %s "$STORAGE_DIR/data.img" 2>/dev/null) || return 1
  ((bytes > 0 && bytes % 1073741824 == 0)) || return 1
  echo "$((bytes / 1073741824))G"
}

normal_ram() { # "8", "8g", "8GB", "8 GiB" -> "8G"; nothing for anything else
  local value=${1,,}
  value=${value// /}
  value=${value%ib}
  value=${value%b}
  value=${value%g}
  [[ $value =~ ^[0-9]{1,3}$ ]] && echo "$((10#$value))G"
}

# Hand Omarchy's writer the full set with new memory and processors.
resources_write() { # resources_write <ram> <cores>
  local ram=$1 cores=$2 disk tz rc=0
  disk=$(vm_disk) || die "could not tell the VM's disk size, so its configuration was left alone"
  [[ -r $CREDENTIALS || -r $COMPOSE ]] || die "could not read the VM's account ($CREDENTIALS), so its configuration was left alone"
  rdp_credentials
  tz=""
  [[ -r $COMPOSE ]] && tz=$(compose_value TZ)
  [[ -n $tz ]] || tz=$(timedatectl show -p Timezone --value 2>/dev/null)
  [[ -n $tz ]] || tz=UTC
  [[ -x $VM_HELPER ]] || die "Omarchy's Windows VM helper is missing ($VM_HELPER); run: omarchy update"
  # over stdin, as Omarchy does: the password must not be on a command line
  printf 'RAM=%s\nCORES=%s\nDISK=%s\nUSERNAME=%s\nPASSWORD=%s\nTZ=%s\n' \
    "$ram" "$cores" "$disk" "$RDP_USER" "$RDP_PASS" "$tz" |
    pkexec "$VM_HELPER" __priv write_compose >/dev/null 2>&1 || rc=$?
  ((rc == 0)) || die "the VM's configuration was not changed ($(explain_pkexec "$rc" "Omarchy's helper refused the values"))"
  cfg_set vmRam "\"$ram\""
  cfg_set vmCores "$cores"
}

resources_show() {
  local now ram cores
  now=$(vm_resources)
  if [[ -z $now ]]; then
    say "Windows VM: memory and processors are not known yet (they show once it has run)"
  else
    read -r ram cores <<<"$now"
    say "Windows VM: ${ram%G} GB of memory, $cores processor$([[ $cores == 1 ]] || echo s)"
  fi
  say "This computer: $HOST_RAM_GB GB, $HOST_CORES processors"
}

# Ask for both in a terminal; what the bar panel opens.
resources_pick() {
  local now ram="" cores="" size options=() picked
  have gum || die "this needs gum (omarchy pkg add gum). Without it: winapp resources --ram <GB> --cores <n>"
  now=$(vm_resources)
  [[ -n $now ]] && read -r ram cores <<<"$now"
  resources_show
  say ""
  for size in 2 4 6 8 12 16 24 32 48 64 96 128; do
    ((size <= HOST_RAM_GB)) && options+=("${size}G")
  done
  picked=$(printf '%s\n' "${options[@]}" | gum choose --header="Memory for Windows" --selected="${ram:-4G}") || die "cancelled"
  PICK_RAM=$picked
  options=()
  for ((size = 1; size <= HOST_CORES; size++)); do options+=("$size"); done
  picked=$(printf '%s\n' "${options[@]}" | gum choose --height=12 --header="Processors for Windows" --selected="${cores:-2}") || die "cancelled"
  PICK_CORES=$picked
}
PICK_RAM="" PICK_CORES=""

cmd_resources() {
  local ram="" cores="" pick=0 json=0 now old_ram="" old_cores=""
  while (($#)); do
    case $1 in
    --ram) ram=${2:?--ram needs a size in GB, for example 8} && shift ;;
    --cores) cores=${2:?--cores needs a number} && shift ;;
    --pick) pick=1 ;;
    --json) json=1 ;;
    *) die "usage: winapp resources [--ram <GB>] [--cores <n>]   (no options: show the current values)" ;;
    esac
    shift
  done
  vm_installed || die "the Windows VM is not set up yet; run: omarchy-windows-vm install"
  now=$(vm_resources)
  [[ -n $now ]] && read -r old_ram old_cores <<<"$now"

  if ((json)); then
    jq -cn --arg ram "$old_ram" --arg cores "$old_cores" --argjson hostRam "${HOST_RAM_GB:-0}" --argjson hostCores "$HOST_CORES" \
      '{ram: $ram, cores: ($cores | tonumber? // null), hostRam: $hostRam, hostCores: $hostCores}'
    return
  fi
  if ((pick)); then
    resources_pick
    ram=$PICK_RAM cores=$PICK_CORES
  elif [[ -z $ram && -z $cores ]]; then
    resources_show
    say ""
    say "Change with: winapp resources --ram <GB> --cores <n>"
    return
  fi

  # one of the two given: the other stays, and so has to be known
  if [[ -z $ram ]]; then ram=$old_ram; else ram=$(normal_ram "$ram"); fi
  [[ -n $cores ]] || cores=$old_cores
  [[ -n $ram ]] || die "give the memory as a whole number of GB, for example: --ram 8 (and both --ram and --cores when the current values are not known)"
  [[ $cores =~ ^[0-9]{1,2}$ ]] || die "give the processors as a number, for example: --cores 4 (and both --ram and --cores when the current values are not known)"
  cores=$((10#$cores))
  ((${ram%G} >= 2)) || die "Windows 11 needs at least 2 GB of memory"
  ((${ram%G} <= HOST_RAM_GB)) || die "this computer has $HOST_RAM_GB GB of memory; ${ram%G} GB is more than there is"
  ((cores >= 1 && cores <= HOST_CORES)) || die "this computer has $HOST_CORES processors; choose between 1 and $HOST_CORES"

  if [[ $ram == "$old_ram" && $cores == "$old_cores" ]]; then
    say "Already set to ${ram%G} GB and $cores processor$([[ $cores == 1 ]] || echo s); nothing to change."
    return 0
  fi
  if clients_alive || desktop_elsewhere; then
    die "close the open Windows apps and desktop first: the change needs Windows to restart"
  fi
  ((HOST_RAM_GB - ${ram%G} >= 4)) || warn "that leaves under 4 GB for Linux while Windows is running"

  resources_write "$ram" "$cores"
  say "Windows VM set to ${ram%G} GB of memory and $cores processor$([[ $cores == 1 ]] || echo s)."
  if vm_running; then
    say "Stopping Windows so it starts with the new settings…"
    vm_stop || warn "could not stop Windows; the new settings apply the next time it starts"
  fi
  say "They apply the next time Windows starts."
}
