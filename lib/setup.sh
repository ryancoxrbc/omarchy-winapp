# shellcheck shell=bash
# Installing and removing winapp itself. `omarchy plugin add` only clones the
# repository; the setup script next to the manifest runs `winapp setup`, which
# does the rest and can be run again at any time.

# winapp 2.0 and 2.1 could install this rule (`winapp passwordless on`), which
# lets the user start and stop the VM without a password. The command is gone;
# a rule left behind is still removed on uninstall, and `winapp doctor` says
# how to remove it by hand. The directory is not readable, so whether it is
# there is known only from the "passwordless" setting that command wrote.
POLKIT_RULE=/etc/polkit-1/rules.d/49-winapp-$ME.rules

as_root() { # with a terminal sudo can ask; without one only polkit can
  if [[ -t 0 ]]; then sudo "$@"; else pkexec "$@"; fi
}

# --- setup ---------------------------------------------------------------------

step() { printf '  %s\n' "$*"; }

install_packages() {
  local missing=() cmd
  local -A package=([xfreerdp3]=freerdp [jq]=jq [notify-send]=libnotify [gum]=gum [xdg-mime]=xdg-utils
    [update-desktop-database]=desktop-file-utils [update-mime-database]=shared-mime-info [flock]=util-linux
    [cc]=gcc)
  for cmd in "${!package[@]}"; do have "$cmd" || missing+=("${package[$cmd]}"); done
  ((${#missing[@]})) || return 0
  step "Installing: ${missing[*]}"
  if have omarchy-pkg-add; then
    omarchy-pkg-add "${missing[@]}"
  else
    as_root pacman -S --needed --noconfirm "${missing[@]}"
  fi || die "could not install ${missing[*]}"
}

link_cli() {
  local backup
  mkdir -p "${BIN_LINK%/*}"
  if [[ -e $BIN_LINK || -L $BIN_LINK ]]; then
    [[ $(realpath -- "$BIN_LINK" 2>/dev/null) == "$SELF" ]] && return 0
    backup=$DATA_DIR/backup/winapp.$(date +%Y%m%d%H%M%S)
    mkdir -p "${backup%/*}"
    mv -- "$BIN_LINK" "$backup"
    step "An older winapp was in the way; moved it to $backup"
  fi
  ln -s -- "$SELF" "$BIN_LINK"
  step "Linked $BIN_LINK"
  [[ :$PATH: == *:${BIN_LINK%/*}:* ]] || step "Note: ${BIN_LINK%/*} is not on your PATH"
}

# One-time changes inside Windows that make it work with Linux files: RemoteApp
# may start any program, the ~/Windows share shows Linux-side changes at once,
# and the shared folders are pinned to Quick access so file dialogs offer them.
# The standing settings (lib/guest.sh) go along.
# Remembered per VM (a reinstalled VM has a new MAC address), safe to repeat.
vm_identity() { cat "$STORAGE_DIR/windows.mac" 2>/dev/null || echo unknown; }

guest_prepared() { [[ $(cfg .guestPrepared "") == "$(vm_identity)" ]]; }

guest_prepare() {
  local job
  job=$(pins_job | jq -c '{remoteapp: true, smbCache: true} + .')
  frame_wanted && job=$(frame_job | jq -c --argjson job "$job" '$job + .')
  job=$(tune_job | jq -c --argjson job "$job" '$job + .')
  guest_run apply "$job" 120 || return 1
  if [[ $(guest_out '.echo') != "$(cat "$GUEST_DIR/probe.txt")" ]]; then
    GUEST_ERROR="Windows could not read the redirected folder"
    return 1
  fi
  tune_noted
  pins_noted
  # cosmetic, so not a reason to call Windows unprepared; winapp doctor reports it
  frame_wanted && { frame_noted || true; }
  cfg_set guestPrepared "$(vm_identity | jq -R .)"
}

enable_plugin() {
  local id dir
  id=$(plugin_id)
  dir=$HOME/.config/omarchy/plugins/$id
  have omarchy-plugin-list && [[ -n $id && $(realpath -- "$dir" 2>/dev/null) == "$ROOT" ]] || return 0
  if omarchy-plugin-list --json 2>/dev/null | jq -e --arg id "$id" 'any(.[]; .id == $id and .enabled == true)' >/dev/null; then
    return 0
  fi
  if omarchy-plugin-enable "$id" >/dev/null 2>&1; then
    step "Added the Windows widget to the bar"
  else
    step "Add the widget to the bar with: omarchy plugin enable $id"
  fi
}

cmd_setup() {
  local scan=ask change
  while (($#)); do
    case $1 in
    -y | --yes) ASSUME_YES=1 ;;
    --no-scan) scan=no ;;
    *) die "usage: winapp setup [--yes] [--no-scan]" ;;
    esac
    shift
  done

  say "Setting up Windows apps for Omarchy"
  [[ -x $VM_HELPER ]] || die "this needs Omarchy's Windows VM support ($VM_HELPER is missing). Is this an up-to-date Omarchy?"
  install_packages
  link_cli
  ensure_config
  ensure_apps
  sync_desktop
  enable_plugin
  if shim_wanted && ! ensure_shim; then
    step "Could not build the helper-window fix (see: winapp doctor); apps still open without it"
  fi

  if ! vm_installed; then
    say ""
    say "The Windows VM itself is not installed yet. Install it from the Omarchy menu"
    say "(Install > Windows) or with:  omarchy-windows-vm install"
    say "Then run this again:  winapp setup"
    return 0
  fi

  # the two things that are the user's to decide, while someone is there to ask
  if interactive && have gum && ((!ASSUME_YES)); then
    if [[ -z $(shares all) ]]; then
      say ""
      share_pick
    fi
    for change in "${CHANGES[@]}"; do
      [[ $(change_state "$change") == ask ]] && change_choose "$change"
    done
  fi

  if [[ $scan == ask ]] && interactive && have gum; then
    say ""
    confirm "Start Windows now to prepare it and pick your apps? (about a minute)" && scan=yes
  fi
  if [[ $scan == yes ]]; then
    step "Starting Windows…"
    if guest_prepare; then
      step "Windows is ready ($(guest_out '.windows.caption'))"
      cmd_manage
    else
      warn "$GUEST_ERROR"
      step "Fix that, then run: winapp doctor"
    fi
  fi

  say ""
  say "Done. Next:"
  say "  winapp manage     pick which Windows apps appear on Linux"
  say "  winapp share pick choose the folders Windows apps can open and save in"
  say "  winapp desktop    open the Windows desktop to install more programs"
  say "  winapp doctor     check that everything works"
}

# --- uninstall -----------------------------------------------------------------

cmd_uninstall() {
  local purge=0 f
  while (($#)); do
    case $1 in
    --purge) purge=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    *) die "usage: winapp uninstall [--purge] [--yes]" ;;
    esac
    shift
  done
  clients_alive && die "close the open Windows apps first"
  confirm "Remove the Windows app menu entries, file associations and the winapp command? (the VM itself is not touched)" || die "cancelled"
  idle_cancel

  for f in "$APP_DIR"/winapp-*.desktop; do
    [[ -e $f ]] || continue
    rm -f "$f"
    forget_associations "${f##*/}"
  done
  rm -f "$MIME_DIR"/packages/winapp-*.xml
  update-mime-database "$MIME_DIR" >/dev/null 2>&1
  update-desktop-database "$APP_DIR" >/dev/null 2>&1
  step "Removed menu entries and file associations"

  if [[ $(cfg .passwordless false) == true ]]; then
    if as_root rm -f "$POLKIT_RULE"; then step "Removed $POLKIT_RULE"; else warn "could not remove $POLKIT_RULE"; fi
  fi
  if cli_linked; then
    rm -f "$BIN_LINK"
    step "Removed $BIN_LINK"
  fi
  # $DATA_DIR/backup, if there is one, holds a file of the user's that setup moved aside
  rm -rf "$ICON_DIR" "$SHIM" "$CACHE_DIR" "$RUN_DIR" "${LOG_DIR%/log}"
  rmdir "$DATA_DIR" 2>/dev/null
  if ((purge)); then
    rm -rf "$CONFIG_DIR"
    step "Removed $CONFIG_DIR"
  else
    step "Kept your app list in $CONFIG_DIR (--purge removes it)"
  fi
  say ""
  say "To remove the bar widget too:  omarchy plugin remove $(plugin_id)"
}
