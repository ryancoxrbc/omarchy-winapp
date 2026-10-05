# shellcheck shell=bash
# Linux files as Windows sees them.
#
# Nothing is copied into the VM. FreeRDP redirects folders into the session
# ("shares", by default the whole home directory as \\tsclient\home) and an app
# opens the file there, so a save writes the Linux file directly. A file outside
# every share gets a drive of its own for as long as the VM stays up: every
# later connection redirects it again, because a new connection replaces the
# previous one's drives and an app may still have that file open.

DRIVES_FILE=$RUN_DIR/drives.tsv # this boot's extra drives: name<TAB>directory
# Drives a launch has asked for but not started the VM for yet. They are kept
# apart until the VM is up: "the VM is stopped" clears the list above, and the
# bar asks about that every few seconds.
DRIVES_PENDING=$RUN_DIR/drives.$$.new

# shellcheck disable=SC2088 # the tilde is matched and written as text on purpose
expand_path() { # ~ and $HOME in a configured path; no trailing slash
  local p=$1
  [[ $p == "~" ]] && p=$HOME
  [[ $p == "~/"* ]] && p=$HOME/${p#"~/"}
  p=${p//\$HOME/$HOME}
  [[ $p == / ]] || p=${p%/}
  printf '%s\n' "$p"
}

shares() { # configured shares that exist, as name<TAB>directory
  local name dir
  cfg_json | jq -r '.shares[]? | "\(.name)\t\(.path)"' | while IFS=$'\t' read -r name dir; do
    dir=$(expand_path "$dir")
    [[ -d $dir ]] && printf '%s\t%s\n' "$name" "$dir"
  done
}

all_drives() {
  shares
  cat "$DRIVES_FILE" "$DRIVES_PENDING" 2>/dev/null | sort -u
  return 0
}

commit_drives() { # once the VM is up: this launch's drives join the boot's list
  [[ -s $DRIVES_PENDING ]] && cat "$DRIVES_PENDING" >>"$DRIVES_FILE"
  rm -f "$DRIVES_PENDING"
}

# The absolute path of a file argument, as the user wrote it (symlinks are not
# resolved: ~/Documents may point at another disk and still be reachable
# through the home share). Accepts the file:// URIs some launchers pass.
local_path() {
  local arg=$1 p
  if [[ $arg == file://* ]]; then
    arg=${arg#file://}
    arg=/${arg#*/}
    printf -v arg '%b' "${arg//%/\\x}"
  fi
  p=$(realpath -s -- "$arg" 2>/dev/null) || return 1
  [[ -e $p ]] || return 1
  printf '%s\n' "$p"
}

# Which drive covers a path: prints name<TAB>directory of the deepest match.
covering_drive() {
  local path=$1 name dir best="" bestdir=""
  while IFS=$'\t' read -r name dir; do
    [[ $dir == / || $path == "$dir" || $path == "$dir"/* ]] || continue
    if ((${#dir} >= ${#bestdir})); then best=$name bestdir=$dir; fi
  done < <(all_drives)
  [[ -n $best ]] && printf '%s\t%s\n' "$best" "$bestdir"
}

# What to redirect for a file no share covers: a whole removable or data disk
# when the file is on one (its sibling folders are usually wanted too),
# otherwise just the file's folder.
adhoc_root() {
  local path=$1 mount
  mount=$(findmnt -n -o TARGET -T "$path" 2>/dev/null)
  case $mount in
  /run/media/* | /media/* | /mnt/*) printf '%s\n' "$mount" ;;
  *) if [[ -d $path ]]; then printf '%s\n' "$path"; else dirname -- "$path"; fi ;;
  esac
}

# Windows cannot name a file with these in it, and FreeRDP does not translate.
check_windows_name() {
  local rest=$1 part
  local -a parts
  [[ $rest != *[[:cntrl:]]* ]] || die "Windows cannot open a file whose name contains control characters"
  IFS=/ read -ra parts <<<"$rest"
  for part in "${parts[@]}"; do
    if [[ $part == *[\<\>:\"\|?*\\]* ]]; then
      die "Windows cannot open \"$part\": the name contains one of < > : \" | ? * \\"
    fi
    if [[ $part == *" " || ($part == *. && $part != . && $part != ..) ]]; then
      die "Windows cannot open \"$part\": the name ends in a space or a dot"
    fi
  done
}

# win_path <absolute linux path>: prints the path Windows reaches it by.
win_path() {
  local path=$1 hit name dir rest physical
  hit=$(covering_drive "$path")
  if [[ -z $hit ]]; then
    # reached through a symlink that leaves every share? try where it really is
    physical=$(realpath -- "$path" 2>/dev/null)
    if [[ -n $physical && $physical != "$path" ]]; then
      hit=$(covering_drive "$physical")
      [[ -n $hit ]] && path=$physical
    fi
  fi
  if [[ -z $hit ]]; then
    dir=$(adhoc_root "$path")
    name=x$(printf '%s' "$dir" | sha1sum | cut -c1-6)
    ensure_dirs
    printf '%s\t%s\n' "$name" "$dir" >>"$DRIVES_PENDING"
    hit=$name$'\t'$dir
  fi
  name=${hit%%$'\t'*}
  dir=${hit#*$'\t'}
  rest=${path#"$dir"}
  rest=${rest#/}
  check_windows_name "$rest"
  printf '\\\\tsclient\\%s%s\n' "$name" "${rest:+\\${rest//\//\\}}"
}

# One "/drive:name,directory" per line for every share and extra drive.
# FreeRDP splits the value on commas and trips over quote characters, so a
# directory with either is redirected through a plainly named link.
drive_args() {
  local name dir
  while IFS=$'\t' read -r name dir; do
    if [[ $dir == *[,\'\"]* ]]; then
      mkdir -p "$RUN_DIR/drives"
      ln -sfn -- "$dir" "$RUN_DIR/drives/$name"
      dir=$RUN_DIR/drives/$name
    fi
    printf '/drive:%s,%s\n' "$name" "$dir"
  done < <(all_drives | sort -u -t$'\t' -k1,1)
}

# --- commands ----------------------------------------------------------------

cmd_shares() {
  local name dir
  {
    cfg_json | jq -r '.shares[]? | "\(.name)\t\(.path)"' | while IFS=$'\t' read -r name dir; do
      printf '%s\t%s\t%s\n' "$name" "\\\\tsclient\\$name" "$(expand_path "$dir")$([[ -d $(expand_path "$dir") ]] || echo "  (missing)")"
    done
    [[ -s $DRIVES_FILE ]] && sort -u "$DRIVES_FILE" | while IFS=$'\t' read -r name dir; do
      printf '%s\t%s\t%s\n' "$name" "\\\\tsclient\\$name" "$dir  (until Windows stops)"
    done
  } | column -t -s $'\t' -N "SHARE,IN WINDOWS,LINUX FOLDER"
}

cmd_share() {
  local action=${1:-} name=${2:-} dir=${3:-}
  case $action in
  add)
    [[ $name =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] || die "usage: winapp share add <name> <folder>  (name: a letter, then up to 14 letters, digits, - or _)"
    [[ ${name,,} != winapp ]] || die "the share name 'winapp' is used by winapp itself"
    [[ -n $dir ]] || die "usage: winapp share add <name> <folder>"
    dir=$(realpath -s -- "$(expand_path "$dir")") && [[ -d $dir ]] || die "no such folder: ${3:-}"
    # stored relative to home, so the config still reads right for another user
    [[ $dir == "$HOME" ]] && dir='~'
    [[ $dir == "$HOME"/* ]] && dir='~/'${dir#"$HOME"/}
    cfg_json >/dev/null
    cfg_edit '.shares = ((.shares // []) | map(select(.name != $n)) + [{name: $n, path: $p}])' \
      --arg n "$name" --arg p "$dir" || die "could not update $CONFIG_FILE"
    say "Shared $dir as \\\\tsclient\\$name (from the next app you open)"
    ;;
  remove | rm)
    [[ -n $name ]] || die "usage: winapp share remove <name>"
    [[ -n $(cfg_json | jq -r --arg n "$name" '.shares[]? | select(.name == $n) | .name') ]] || die "no share called '$name' (see: winapp shares)"
    cfg_edit '.shares |= map(select(.name != $n))' --arg n "$name" || die "could not update $CONFIG_FILE"
    say "Stopped sharing '$name' (from the next app you open)"
    ;;
  *) die "usage: winapp share add <name> <folder> | winapp share remove <name>" ;;
  esac
}
