# shellcheck shell=bash
# Linux files as Windows sees them.
#
# Nothing is copied into the VM. FreeRDP redirects folders into the session
# ("shares", \\tsclient\<name>) and an app opens the file there, so a save
# writes the Linux file directly. Which folders is the user's choice (`winapp
# share pick`), and none is shared until they have made it: whatever is shared,
# every program in Windows can read and change, a macro in a document included.
# A file outside every share gets a drive of its own, just its folder, for as
# long as the VM stays up: every later connection redirects it again, because
# a new connection replaces the previous one's drives and an app may still
# have that file open.

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

shares() { # shares [all]: configured shares as name<TAB>directory; without "all", only those that exist
  local name dir
  cfg_json | jq -r '.shares[]? | "\(.name)\t\(.path)"' | while IFS=$'\t' read -r name dir; do
    dir=$(expand_path "$dir")
    [[ ${1:-} == all || -d $dir ]] && printf '%s\t%s\n' "$name" "$dir"
  done
}

all_drives() {
  shares
  cat "$DRIVES_FILE" "$DRIVES_PENDING" 2>/dev/null | sort -u
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
  if [[ -z $(shares all) && ! -s $DRIVES_FILE ]]; then
    say "Nothing is shared: each file you open brings its own folder along."
    say "Choose folders with: winapp share pick"
    return 0
  fi
  {
    shares all | while IFS=$'\t' read -r name dir; do
      printf '%s\t%s\t%s\n' "$name" "\\\\tsclient\\$name" "$dir$([[ -d $dir ]] || echo "  (missing)")"
    done
    [[ -s $DRIVES_FILE ]] && sort -u "$DRIVES_FILE" | while IFS=$'\t' read -r name dir; do
      printf '%s\t%s\t%s\n' "$name" "\\\\tsclient\\$name" "$dir  (until Windows stops)"
    done
  } | column -t -s $'\t' -N "SHARE,IN WINDOWS,LINUX FOLDER"
}

# A share's name made from its folder's: what FreeRDP and Windows accept, and
# not one of those already taken (given one per line).
share_name() { # share_name <folder> <names taken>
  local name n=2 base
  name=$(printf '%s' "${1##*/}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')
  [[ $1 == "$HOME" ]] && name=home
  [[ $name == [a-z]* ]] || name=f$name
  name=${name:0:13}
  base=$name
  while grep -qxF -- "$name" <<<"$2" || [[ $name == winapp || $name == winappq ]]; do name=$base$((n++)); done
  printf '%s\n' "$name"
}

# How a folder is written in config.json: relative to home, so the file still
# reads right for another user.
# shellcheck disable=SC2088 # the tilde is written as text on purpose
share_path() {
  if [[ $1 == "$HOME" ]]; then
    echo '~'
  elif [[ $1 == "$HOME"/* ]]; then
    echo "~/${1#"$HOME"/}"
  else
    echo "$1"
  fi
}

# The checklist behind `winapp share pick`, "Shared folders" in the bar panel
# and the first `winapp setup`: the folders in home, the ones shared now
# ticked, and the whole of home as the last and widest choice.
share_pick() {
  local name dir label picked taken="" everything
  local -a labels=() selected=() keep=()
  local -A dir_of=() name_of=()
  have gum || die "this needs gum (omarchy pkg add gum). Without it: winapp share add <name> <folder>"
  everything="$(share_path "$HOME")  (everything in your home folder)"
  while IFS=$'\t' read -r name dir; do
    name_of[$dir]=$name
    [[ $dir == "$HOME" ]] && label=$everything || label=$(share_path "$dir")
    label=${label//,/ }
    dir_of[$label]=$dir
    labels+=("$label")
    selected+=("$label")
  done < <(shares all)
  for dir in "$HOME"/*/; do
    dir=${dir%/}
    # ~/Windows is Omarchy's own share: Windows has it already
    [[ -n ${name_of[$dir]:-} || $dir == "$SHARED_DIR" ]] && continue
    label=$(share_path "$dir")
    label=${label//,/ }
    dir_of[$label]=$dir
    labels+=("$label")
  done
  if [[ -z ${name_of[$HOME]:-} ]]; then
    dir_of[$everything]=$HOME
    labels+=("$everything")
  fi

  say "Windows apps open and save files in the folders you share, and every program"
  say "in Windows can read and change everything in them. A file anywhere else still"
  say "opens: its own folder is then shared until Windows stops."
  say ""
  picked=$(printf '%s\n' "${labels[@]}" | gum choose --no-limit --height=20 \
    --header="Folders to share with Windows (space to tick, enter to confirm)" \
    --selected="$(
      IFS=,
      echo "${selected[*]}"
    )") || die "cancelled"

  # a share that stays keeps its name: Windows remembers files by it
  while IFS= read -r label; do
    [[ -n $label ]] || continue
    dir=${dir_of[$label]}
    name=${name_of[$dir]:-$(share_name "$dir" "$taken")}
    taken+=$name$'\n'
    keep+=("$(jq -cn --arg n "$name" --arg p "$(share_path "$dir")" '{name: $n, path: $p}')")
  done <<<"$picked"
  cfg_edit '.shares = $shares' --argjson shares "$(printf '%s\n' "${keep[@]}" | jq -cs .)" || die "could not update $CONFIG_FILE"
  if ((${#keep[@]})); then
    cmd_shares
  else
    say "Nothing is shared. Each file you open brings its own folder along."
  fi
  say "This holds from the next app you open."
}

cmd_share() {
  local action=${1:-} name=${2:-} dir=${3:-}
  case $action in
  pick) share_pick ;;
  add)
    [[ $name =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] || die "usage: winapp share add <name> <folder>  (name: a letter, then up to 14 letters, digits, - or _)"
    [[ ${name,,} != winapp && ${name,,} != winappq ]] || die "the share name '$name' is used by winapp itself"
    [[ -n $dir ]] || die "usage: winapp share add <name> <folder>"
    dir=$(realpath -s -- "$(expand_path "$dir")") && [[ -d $dir ]] || die "no such folder: ${3:-}"
    dir=$(share_path "$dir")
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
  *) die "usage: winapp share pick | winapp share add <name> <folder> | winapp share remove <name>" ;;
  esac
}
