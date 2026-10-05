# shellcheck shell=bash
# `winapp doctor`: check each thing winapp depends on and say how to fix what
# is not right.

DOCTOR_FAILED=0

mark() { # mark <colour code> <symbol>: coloured only when someone is looking
  if [[ -t 1 ]]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}
ok() { printf '  %s %s\n' "$(mark 32 ✓)" "$1"; }
note() {
  printf '  %s %s\n' "$(mark 33 !)" "$1"
  [[ -z ${2:-} ]] || printf '      %s\n' "$2"
}
bad() {
  printf '  %s %s\n' "$(mark 31 ✗)" "$1"
  [[ -z ${2:-} ]] || printf '      %s\n' "$2"
  DOCTOR_FAILED=1
}

cmd_doctor() {
  local deep=0 cmd id name dir exes job missing
  while (($#)); do
    case $1 in
    --deep) deep=1 ;;
    *) die "usage: winapp doctor [--deep]   (--deep starts Windows to test it)" ;;
    esac
    shift
  done

  say "winapp $(version)"
  say ""
  say "This computer"
  for cmd in xfreerdp3 jq hyprctl flock; do
    if have "$cmd"; then ok "$cmd"; else bad "$cmd is missing" "run: winapp setup"; fi
  done
  have sfreerdp3 || note "sfreerdp3 is missing" "the first sign-in after each Windows start will flash a window"
  have notify-send || note "notify-send is missing" "errors from the bar and the app launcher will not be shown"
  have gum || note "gum is missing" "winapp manage needs it: omarchy pkg add gum"
  if ! shim_wanted; then
    note "the helper-window fix is switched off (helperWindowFix in config.json)" "apps with an embedded browser, such as CorelDRAW, can freeze without it"
  elif ensure_shim; then
    ok "helper-window fix built"
  else
    note "the helper-window fix could not be built" "it needs a C compiler: omarchy pkg add gcc. Without it, apps such as CorelDRAW can freeze"
  fi
  if [[ -e /dev/kvm ]]; then ok "KVM is available"; else bad "/dev/kvm is missing" "enable virtualization in the firmware setup"; fi
  if [[ -L $BIN_LINK && $(realpath -- "$BIN_LINK" 2>/dev/null) == "$SELF" ]]; then
    ok "winapp is on PATH ($BIN_LINK)"
  else
    note "the winapp command is not linked into ${BIN_LINK%/*}" "run: winapp setup"
  fi

  say ""
  say "The Windows VM"
  if [[ -x $VM_HELPER ]]; then
    ok "Omarchy's Windows VM helper"
    grep -q 'up_wait' "$VM_HELPER" 2>/dev/null || bad "this Omarchy's helper has no 'up_wait' action" "run: omarchy update"
  else
    bad "$VM_HELPER is missing" "winapp builds on Omarchy's Windows VM; run: omarchy update"
  fi
  if ! vm_installed; then
    bad "the Windows VM is not installed" "Omarchy menu > Install > Windows, or: omarchy-windows-vm install"
    say ""
    return 1
  fi
  if [[ -e $COMPOSE ]]; then
    ok "installed"
  else
    bad "installed in Omarchy's old layout" "open Windows once from the app launcher to migrate it"
  fi
  if docker_direct; then
    ok "Docker is reachable directly (sudoless Docker)"
  elif [[ $(cfg .passwordless false) == true ]]; then
    ok "starting and stopping without a password (winapp passwordless on)"
  else
    note "Omarchy asks for a password to start and to stop Windows" "skip the prompts with: winapp passwordless on"
  fi
  if [[ -r $CREDENTIALS ]]; then
    ok "sign-in details ($CREDENTIALS)"
  else
    note "no $CREDENTIALS" "falling back to the installer's default account (docker / admin)"
  fi
  say "  · state: $(vm_state), idle shutdown after $(idle_minutes) min$([[ $(idle_minutes) == 0 ]] && echo ' (never)')"

  say ""
  say "Folders Windows can reach"
  while IFS=$'\t' read -r name dir; do
    dir=$(expand_path "$dir")
    if [[ -d $dir ]]; then ok "\\\\tsclient\\$name  =  $dir"; else bad "share '$name' points at $dir, which does not exist" "winapp share remove $name"; fi
  done < <(cfg_json | jq -r '.shares[]? | "\(.name)\t\(.path)"')
  [[ -n $(shares) ]] || note "nothing is shared" "each opened file's folder is redirected on its own; share more with: winapp share add"

  say ""
  say "Apps"
  if [[ $(apps_json | jq '.apps | length') -eq 0 ]]; then
    note "no apps added yet" "pick some with: winapp manage"
  else
    while IFS= read -r id; do
      [[ -f $APP_DIR/winapp-$id.desktop || $(app_field "$id" menu) == false || $(app_field "$id" desktop) == false ]] ||
        note "$id has no menu entry" "run: winapp sync"
    done < <(app_ids)
    ok "$(apps_json | jq -r '.apps | map(.id) | join(", ")')"
  fi

  say ""
  say "Inside Windows"
  if clients_alive || desktop_elsewhere; then
    say "  · skipped: Windows is in use, and the test needs the VM's only session"
  elif ! vm_running && ((!deep)); then
    say "  · skipped: Windows is not running (winapp doctor --deep starts it to test)"
  else
    exes=$(apps_json | jq -c '[.apps[].exe]')
    job=$(jq -cn --argjson exes "$exes" '{exists: $exes}')
    if guest_run apply "$job" 120; then
      ok "signed in and started a program ($(guest_out '.windows.caption'))"
      if [[ $(guest_out '.echo') == "$(cat "$GUEST_DIR/probe.txt")" ]]; then
        ok "Windows reads and writes Linux folders"
      else
        bad "Windows could not read the redirected folder" "see the newest guest log in $LOG_DIR"
      fi
      if [[ $(guest_out '.remoteapp.allowUnlisted') == 1 && $(guest_out '.remoteapp.allowListDisabled') == 1 ]]; then
        ok "RemoteApp may start any program"
      else
        note "RemoteApp is limited to an allow-list" "fix with: winapp setup"
      fi
      missing=$(guest_out '.exists | to_entries[] | select(.value == false) | .key')
      if [[ -n $missing ]]; then
        while IFS= read -r name; do bad "not found in Windows: $name" "find where it is now with: winapp scan"; done <<<"$missing"
      else
        ok "every added app is installed"
      fi
    else
      bad "$GUEST_ERROR"
    fi
  fi

  say ""
  if ((DOCTOR_FAILED)); then
    say "Some checks failed."
    return 1
  fi
  say "Everything checked out."
}

cmd_logs() {
  local newest
  # shellcheck disable=SC2012 # names are ours
  newest=$(ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -n1)
  [[ -n $newest ]] || die "no logs yet in $LOG_DIR"
  if [[ ${1:-} == --path ]]; then
    say "$newest"
  else
    say "$newest"
    say ""
    # the FreeRDP client repeats a few "TODO: implement" warnings endlessly
    grep -v 'TODO: implement\|xf_Pointer\|FAT_IOCTL_GET_ATTRIBUTES' "$newest" | tail -n 60
  fi
}
