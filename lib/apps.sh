# shellcheck shell=bash
# The app list (~/.config/winapp/apps.json), the menu entries and file
# associations generated from it, and finding what is installed in the VM.
#
# An app is {id, name, exe} plus, optionally: label (short name), args (fixed
# arguments), icon, categories, ext (file types that are its own), opens (file
# types it can also open), mime (the same as explicit MIME types), default
# (true: always the default app for its own types; false: never; unset: only
# for types nothing on Linux opens), panel/menu (false hides it there; a hidden
# menu entry still opens its file types).

APPS_FILE=$CONFIG_DIR/apps.json
CATALOG=$ROOT/catalog.json
SCAN_FILE=$CACHE_DIR/installed.json
ICON_DIR=$DATA_DIR/icons
APP_DIR=$DATA_HOME/applications
MIME_DIR=$DATA_HOME/mime
MIMEAPPS=${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list
FALLBACK_ICON=application-x-executable
MENU_STAMP=$CACHE_DIR/menu.stamp
COMMANDS='run|open|explorer|desktop|apps|scan|add|remove|manage|icons|sync|start|stop|mode|idle|resources|status|state|shares|share|changes|setup|doctor|uninstall|logs|version|help'

ensure_apps() {
  [[ -s $APPS_FILE ]] && return 0
  mkdir -p "$CONFIG_DIR"
  printf '{\n  "apps": []\n}\n' >"$APPS_FILE"
}

apps_json() {
  ensure_apps
  jq -e . "$APPS_FILE" 2>/dev/null || die "$APPS_FILE is not valid JSON"
}

app_field() { # app_field <id> <field>: a scalar field, empty when unset
  apps_json | jq -r --arg id "$1" --arg f "$2" '.apps[] | select(.id == $id) | .[$f] | select(. != null)'
}

app_list() { # app_list <id> <field>: a list field, one item per line
  apps_json | jq -r --arg id "$1" --arg f "$2" '.apps[] | select(.id == $id) | (.[$f] // [])[]'
}

app_ids() { apps_json | jq -r '.apps[].id'; }

# apps_update <jq filter> [jq options...]: rewrite apps.json in one step.
apps_update() {
  ensure_apps
  json_edit "$APPS_FILE" "$@"
}

# --- file types ----------------------------------------------------------------

# The MIME type for a file extension: the one the system already knows, else a
# private type registered for it so the app can be offered for those files.
ext_mime() { # ext_mime <ext> <app name>
  local ext=${1,,} name=$2 found
  [[ $ext =~ ^[a-z0-9_+-]{1,16}$ ]] || return 0
  found=$(awk -F: -v glob="*.$ext" 'tolower($3) == glob { print $1 "\t" $2 }' \
    /usr/share/mime/globs2 "$MIME_DIR/globs2" 2>/dev/null | sort -t$'\t' -k1,1nr | head -n1 | cut -f2)
  if [[ -z $found ]]; then
    found=application/x-winapp-$ext
    mkdir -p "$MIME_DIR/packages"
    cat >"$MIME_DIR/packages/winapp-$ext.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="$found">
    <comment>${name//[<>&]/} file (.$ext)</comment>
    <glob pattern="*.$ext"/>
  </mime-type>
</mime-info>
EOF
  fi
  printf '%s\n' "$found"
}

# MIME types some other installed app already opens. Read straight from the
# association files: asking xdg-mime about each type takes seconds in total.
handled_mimes() {
  awk -F'[=;]' '
    /^\[/ || NF < 2 || $1 == "" { next }
    { for (i = 2; i <= NF; i++) if ($i != "" && $i !~ /^winapp-/) { print $1; break } }
  ' "$MIMEAPPS" "$APP_DIR/mimeinfo.cache" /usr/local/share/applications/mimeinfo.cache \
    /usr/share/applications/mimeinfo.cache 2>/dev/null | sort -u
}

# Take a removed app out of the user's association file, leaving the rest.
forget_associations() { # forget_associations <desktop id>
  local id=$1 tmp
  [[ -f $MIMEAPPS ]] && grep -q -- "$id" "$MIMEAPPS" || return 0
  tmp=$(mktemp "${MIMEAPPS%/*}/.mimeapps.XXXXXX") || return 0
  awk -v drop="$id" '
    /^\[/ || !/=/ { print; next }
    {
      eq = index($0, "=")
      key = substr($0, 1, eq - 1)
      n = split(substr($0, eq + 1), parts, ";")
      out = ""
      for (i = 1; i <= n; i++) if (parts[i] != "" && parts[i] != drop) out = out parts[i] ";"
      if (out != "") print key "=" out
    }' "$MIMEAPPS" >"$tmp" || {
    rm -f "$tmp"
    return 0
  }
  mv -f "$tmp" "$MIMEAPPS"
}

# --- menu entries --------------------------------------------------------------

# The path menu entries call: the link on PATH when it is ours, so entries
# survive the plugin folder moving.
exec_path() {
  if cli_linked; then
    printf '%s\n' "$BIN_LINK"
  else
    printf '%s\n' "$SELF"
  fi
}

# That path as the first word of an Exec line. Left bare whenever the desktop
# entry rules allow it: xdg-mime takes the first word quotes and all, cannot
# find a command by that name, and then passes the entry over as a default
# app in favour of any other program that opens the type. A path that does
# need quoting is replaced by the bare command name when that finds the same
# file, and quoted only as a last resort.
exec_word() {
  local bin
  bin=$(exec_path)
  if [[ $bin =~ ^[A-Za-z0-9_./+@:,=-]+$ ]]; then
    printf '%s\n' "$bin"
  elif [[ $(command -v winapp 2>/dev/null) -ef $bin ]]; then
    printf 'winapp\n'
  else
    printf '"%s"\n' "$bin"
  fi
}

# The names other launcher entries go by, lower case, one per line. Omarchy's
# Microsoft web apps are called "Microsoft Word" and so on, exactly like the
# real programs; two entries with one name cannot be told apart in the launcher.
other_menu_names() {
  local f
  for f in "$APP_DIR"/*.desktop /usr/local/share/applications/*.desktop /usr/share/applications/*.desktop; do
    [[ -e $f && ${f##*/} != winapp-* ]] || continue
    grep -m1 '^Name=' "$f" 2>/dev/null
  done | cut -d= -f2- | tr '[:upper:]' '[:lower:]' | sort -u
}

# Something that changes when another launcher entry comes, goes or is
# rewritten: the user's other entries and when each was last written.
menu_fingerprint() {
  find "$APP_DIR" -maxdepth 1 -name '*.desktop' ! -name 'winapp-*' -printf '%f %T@\n' 2>/dev/null | sort | cksum
}

# True when launcher entries have been added or removed since the last sync, so
# a name that has just become ambiguous (or stopped being) can be put right.
menu_stale() { [[ -s $APPS_FILE && $(menu_fingerprint) != "$(cat "$MENU_STAMP" 2>/dev/null)" ]]; }

# Regenerate the menu entries and file associations from the app list.
sync_desktop() {
  local id name shown icon categories own also mimes claim ext m f bin suffix keep=() wanted=()
  local -A is_handled=() is_taken=()
  mkdir -p "$APP_DIR"
  bin=$(exec_word)
  while IFS= read -r m; do [[ -n $m ]] && is_handled[$m]=1; done < <(handled_mimes)
  # "(Windows)" after a name: auto = only where another entry has that name
  suffix=$(cfg .windowsSuffix auto)
  while IFS= read -r m; do [[ -n $m ]] && is_taken[$m]=1; done < <(other_menu_names)

  while IFS= read -r id; do
    name=$(app_field "$id" name)
    shown=${name:-$id}
    if [[ $suffix == always || ($suffix != never && -n ${is_taken[${shown,,}]:-}) ]]; then
      shown+=" (Windows)"
    fi
    icon=$(app_field "$id" icon)
    categories=$(app_field "$id" categories)
    # its own types (ext, mime) and the ones it merely can open (opens)
    own=$(app_list "$id" mime)
    while IFS= read -r ext; do
      m=$(ext_mime "$ext" "${name:-$id}")
      [[ -n $m ]] && own+=$'\n'$m && wanted+=("winapp-${ext,,}.xml")
    done < <(app_list "$id" ext)
    also=""
    while IFS= read -r ext; do
      m=$(ext_mime "$ext" "${name:-$id}")
      [[ -n $m ]] && also+=$'\n'$m && wanted+=("winapp-${ext,,}.xml")
    done < <(app_list "$id" opens)
    own=$(sed '/^$/d' <<<"$own" | sort -u)
    mimes=$(printf '%s\n%s\n' "$own" "$also" | sed '/^$/d' | sort -u)

    {
      echo "[Desktop Entry]"
      echo "Type=Application"
      echo "Name=$shown"
      echo "Comment=Windows app; opens Linux files in place"
      echo "Exec=$bin $id %F"
      echo "Icon=${icon:-$FALLBACK_ICON}"
      echo "Terminal=false"
      echo "Categories=${categories:-Utility;}"
      echo "StartupWMClass=winapp"
      # out of the launcher, but still there to open its file types with
      [[ $(app_field "$id" menu) == false || $(app_field "$id" desktop) == false ]] && echo "NoDisplay=true"
      [[ -n $mimes ]] && echo "MimeType=$(tr '\n' ';' <<<"$mimes")"
    } >"$APP_DIR/winapp-$id.desktop"
    keep+=("winapp-$id.desktop")

    # default app: always, never, or only where nothing on Linux opens the type
    claim=""
    case $(app_field "$id" default) in
    true) claim=$own ;;
    false) ;;
    *) while IFS= read -r m; do [[ -n $m && -z ${is_handled[$m]:-} ]] && claim+=$m$'\n'; done <<<"$own" ;;
    esac
    if [[ -n ${claim//$'\n'/} ]]; then
      [[ -f $MIMEAPPS && ! -e $MIMEAPPS.before-winapp ]] && cp -p "$MIMEAPPS" "$MIMEAPPS.before-winapp"
      # shellcheck disable=SC2086 # one argument per MIME type
      xdg-mime default "winapp-$id.desktop" $claim 2>/dev/null
    fi
  done < <(app_ids)

  for f in "$APP_DIR"/winapp-*.desktop; do
    [[ -e $f && " ${keep[*]} " != *" ${f##*/} "* ]] || continue
    rm -f "$f"
    forget_associations "${f##*/}"
  done
  for f in "$MIME_DIR"/packages/winapp-*.xml; do
    [[ -e $f && " ${wanted[*]} " != *" ${f##*/} "* ]] || continue
    rm -f "$f"
  done
  # Every time: it is quick, and ext_mime, which writes a new type, is always
  # called inside $( ) and so cannot say that it did.
  [[ -d $MIME_DIR/packages ]] && update-mime-database "$MIME_DIR" >/dev/null 2>&1
  update-desktop-database "$APP_DIR" >/dev/null 2>&1
  mkdir -p "$CACHE_DIR"
  menu_fingerprint >"$MENU_STAMP"
  return 0
}

# --- what is installed in the VM -----------------------------------------------

scan_guest() {
  # the first visit to a VM also sets it up for working with Linux files
  guest_prepared || guest_prepare || return 1
  guest_run scan "" 240 || return 1
  if ! jq -e '.apps' "$GUEST_DIR/out.json" >/dev/null 2>&1; then
    GUEST_ERROR="the VM returned no program list"
    return 1
  fi
  mkdir -p "$CACHE_DIR"
  jq --argjson now "$(date +%s)" '. + {scanned: $now}' "$GUEST_DIR/out.json" >"$SCAN_FILE"
}

# The scan matched against the catalog: known programs get their catalog id,
# short name and file types; anything else is named after its Start Menu entry
# and keeps the file types Windows has registered for it. `all` keeps the
# uninstallers, help files and system tools the default view leaves out.
installed() { # installed [all]
  ensure_apps
  jq --slurpfile catalog "$CATALOG" --slurpfile mine "$APPS_FILE" --arg all "${1:-}" --arg commands "$COMMANDS" '
    def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "");
    def base: split("\\") | last | ascii_downcase;
    "uninstall|read ?me|help|documentation|manual|licen[sc]e|web ?site|release notes|what.s new|feedback|troubleshoot|diagnos|repair|tutorial|getting started|user guide|check for updates|updater" as $junk
    | $catalog[0].apps as $known
    | ($mine[0].apps // [] | map({key: .id, value: true}) | from_entries) as $have
    | [ .apps[]
        | . as $a
        | ($a.exe | base) as $file
        | ($a.exe | ascii_downcase) as $path
        | (first($known[] | select((.exe | index($file)) != null
              and ((.pathContains // "") as $c | $c == "" or ($path | contains($c))))) // null) as $k
        | if $k != null then
            { id: $k.id,
              name: (if ($a.name | length) > (($k.label // $k.name) | length) then $a.name else $k.name end),
              label: ($k.label // $k.name), exe: $a.exe, args: "",
              ext: ($k.ext // []), opens: ($k.opens // []), categories: ($k.categories // ""), known: true }
          else
            { id: ($a.name | slug | if test("^(" + $commands + ")$") then . + "-app" else . end),
              name: $a.name, label: $a.name, exe: $a.exe, args: ($a.args // ""),
              ext: ($a.ext // []), opens: [], categories: "", known: false }
          end ]
    | map(select(.id != "" and (.known or $all == "all"
          or ((.name | test($junk; "i") | not) and (.exe | test("^[a-z]:\\\\windows\\\\"; "i") | not)))))
    | group_by(.id) | map(sort_by(.args | length) | .[0])
    | map(. + {added: ($have[.id] == true)})
    | sort_by((.known | not), (.name | ascii_downcase))
  ' "$SCAN_FILE"
}

# --- icons and per-app guest settings ------------------------------------------

# Fetch the programs' own icons from the VM and apply the settings the catalog
# lists for them, in one visit. Quietly does less when the VM cannot be used
# right now: an app works without its icon.
guest_refresh() { # guest_refresh <id>...
  local ids=("$@") job documents="" id note=""
  ((${#ids[@]})) || return 0
  if clients_alive; then
    warn "icons were not fetched because Windows is in use; run 'winapp icons' later"
    return 0
  fi
  # Office's default save folder, when the Documents folder is shared
  documents=$(xdg-user-dir DOCUMENTS 2>/dev/null)
  if [[ -d $documents && -n $(covering_drive "$documents") ]]; then
    documents=$(win_path "$documents")
  else
    documents=""
  fi
  job=$(jq -n --slurpfile mine "$APPS_FILE" --slurpfile catalog "$CATALOG" --arg documents "$documents" \
    --arg icons "$ICON_DIR" '$ARGS.positional as $ids
    | ($mine[0].apps | map(select(.id as $i | $ids | index($i)))) as $apps
    | { icons: ($apps | map(select((.icon // "") == "" or ((.icon // "") | startswith($icons))) | {id, exe})),
        exists: ($apps | map(.exe)),
        registry: [ $catalog[0].apps[] | select(.id as $i | $ids | index($i)) | (.registry // [])[]
                    | select($documents != "" or (.value | contains("{documents}") | not))
                    | .value |= sub("\\{documents\\}"; $documents) ] | unique }' --args "${ids[@]}")
  if ! guest_run apply "$job" 180; then
    warn "$GUEST_ERROR"
    return 0
  fi
  mkdir -p "$ICON_DIR"
  for id in "${ids[@]}"; do
    if [[ -s $GUEST_DIR/icons/$id.png ]]; then
      cp -f "$GUEST_DIR/icons/$id.png" "$ICON_DIR/$id.png"
      apps_update '(.apps[] | select(.id == $id)).icon = $icon' --arg id "$id" --arg icon "$ICON_DIR/$id.png"
    fi
    if [[ $(guest_out --arg exe "$(app_field "$id" exe)" '.exists[$exe]') == false ]]; then
      note+="  $id: the VM has no file at $(app_field "$id" exe)"$'\n'
    fi
  done
  [[ -z $note ]] || warn "check these paths (winapp scan lists the real ones):"$'\n'"${note%$'\n'}"
}

# --- commands ------------------------------------------------------------------

cmd_apps() {
  if [[ ${1:-} == --json ]]; then
    apps_json
    return
  fi
  if [[ $(apps_json | jq '.apps | length') -eq 0 ]]; then
    say "No apps yet. See what is installed in Windows with: winapp scan"
    return 0
  fi
  # not @tsv: it would double the backslashes in the Windows paths
  apps_json | jq -r '.apps[] | [.id, (.name // .id), .exe,
      ((((.ext // []) | map("." + .)) + (if (.mime // []) | length > 0 then ["\(.mime | length) MIME types"] else [] end)) | join(" ") | if . == "" then "-" else . end),
      (if .default == true then "always" elif .default == false then "never" else "if free" end)] | join("\t")' |
    column -t -s $'\t' -N "ID,NAME,PROGRAM,FILE TYPES,DEFAULT APP"
}

cmd_scan() {
  local json=0 all="" cached=0 pattern=""
  while (($#)); do
    case $1 in
    --json) json=1 ;;
    --all) all=all ;;
    --cached) cached=1 ;;
    -*) die "unknown option for scan: $1" ;;
    *) pattern=$1 ;;
    esac
    shift
  done
  if ((cached)); then
    [[ -s $SCAN_FILE ]] || die "nothing scanned yet; run: winapp scan"
  else
    ((json)) || say "Looking at what is installed in Windows…" >&2
    scan_guest || die "$GUEST_ERROR"
  fi
  if ((json)); then
    installed "$all"
    return
  fi
  installed "$all" | jq -r --arg p "$pattern" '.[] | select($p == "" or ((.name + " " + .id + " " + .exe) | ascii_downcase | contains($p | ascii_downcase)))
      | [(if .added then "*" else " " end), .id, .name, ((.ext | map("." + .) | .[0:6] | join(" ")) | if . == "" then "-" else . end), .exe] | join("\t")' |
    column -t -s $'\t' -N " ,ID,NAME,FILE TYPES,PROGRAM"
  say ""
  say "Add one with: winapp add <id>     (* = already added; --all shows system tools too)"
}

cmd_add() {
  local id=${1:-} name="" label="" exe="" args="" icon="" ext="" opens="" mime="" default="" panel="" menu="" categories=""
  local set_args=0 found patch
  [[ $id =~ ^[a-z0-9][a-z0-9_.+-]*$ ]] || die "usage: winapp add <id> [--exe '<Windows path>'] ...  (id: lowercase letters, digits, - _ . +)"
  [[ ! $id =~ ^($COMMANDS)$ ]] || die "'$id' is a winapp command, pick another id"
  shift
  while (($#)); do
    case $1 in
    --name) name=${2:?--name needs a value} && shift ;;
    --label) label=${2:?--label needs a value} && shift ;;
    --exe) exe=${2:?--exe needs a value} && shift ;;
    --args) args=${2-} set_args=1 && shift ;;
    --icon) icon=$(realpath -- "${2:?--icon needs a file}") && [[ -f $icon ]] || die "no such icon file: ${2:-}"; shift ;;
    --ext) ext=${2:?--ext needs a value} && shift ;;
    --opens) opens=${2:?--opens needs a value} && shift ;;
    --mime) mime=${2:?--mime needs a value} && shift ;;
    --categories) categories=${2:?--categories needs a value} && shift ;;
    --default) default=true ;;
    --no-default) default=false ;;
    --no-panel) panel=false ;;
    --no-menu) menu=false ;;
    *) die "unknown option for add: $1" ;;
    esac
    shift
  done
  ensure_apps

  # With no --exe and no such app yet, the id names something the scan found.
  if [[ -z $exe && -z $(app_field "$id" exe) ]]; then
    if [[ ! -s $SCAN_FILE ]]; then
      say "Looking at what is installed in Windows…" >&2
      scan_guest || die "$GUEST_ERROR"
    fi
    found=$(installed all | jq -c --arg id "$id" 'map(select(.id == $id))[0] // empty')
    [[ -n $found ]] || die "nothing called '$id' was found in Windows. List what is there with: winapp scan
Or give the program yourself: winapp add $id --exe 'C:\\Program Files\\...\\app.exe'"
    apps_update '.apps += [$app | {id, name, label, exe, ext, opens, categories, args}
        | with_entries(select(.value != "" and .value != []))]' --argjson app "$found"
  fi

  patch=$(jq -n --arg name "$name" --arg label "$label" --arg exe "$exe" --arg args "$args" --argjson set_args "$set_args" \
    --arg icon "$icon" --arg ext "$ext" --arg opens "$opens" --arg mime "$mime" --arg categories "$categories" \
    --arg default "$default" --arg panel "$panel" --arg menu "$menu" '
    def list($s): $s | split(",") | map(ascii_downcase | gsub("^[ .]+|\\s+$"; "")) | map(select(. != ""));
    (if $name != "" then {name: $name} else {} end)
    + (if $label != "" then {label: $label} else {} end)
    + (if $exe != "" then {exe: $exe} else {} end)
    + (if $set_args == 1 then {args: $args} else {} end)
    + (if $icon != "" then {icon: $icon} else {} end)
    + (if $ext != "" then {ext: list($ext)} else {} end)
    + (if $opens != "" then {opens: list($opens)} else {} end)
    + (if $mime != "" then {mime: list($mime)} else {} end)
    + (if $categories != "" then {categories: $categories} else {} end)
    + (if $default != "" then {default: ($default == "true")} else {} end)
    + (if $panel != "" then {panel: false} else {} end)
    + (if $menu != "" then {menu: false} else {} end)')
  apps_update '(.apps | map(.id) | index($id)) as $at
    | if $at == null then .apps += [{id: $id, name: $id} + $patch] else .apps[$at] += $patch end' \
    --arg id "$id" --argjson patch "$patch" || die "could not update $APPS_FILE"

  [[ -n $icon ]] || guest_refresh "$id"
  sync_desktop
  say "Added $(app_field "$id" name): $(app_field "$id" exe)"
  say "Open it with: winapp $id [file]   (it is in the app launcher and the bar panel too)"
}

cmd_remove() {
  local id=${1:-}
  [[ -n $id && -n $(app_field "$id" id) ]] || die "no such app: ${id:-<none>} (see: winapp apps)"
  apps_update '.apps |= map(select(.id != $id))' --arg id "$id" || die "could not update $APPS_FILE"
  rm -f "$ICON_DIR/$id.png"
  sync_desktop
  say "Removed $id"
}

cmd_icons() { # fetch icons again, for every app or the ones named
  local ids=("$@")
  ((${#ids[@]})) || mapfile -t ids < <(app_ids)
  ((${#ids[@]})) || die "no apps yet"
  clients_alive && die "$SESSION_IN_USE"
  guest_refresh "${ids[@]}"
  sync_desktop
}

cmd_sync() {
  with_lock sync sync_desktop
  [[ ${1:-} == --quiet ]] || say "Menu entries and file associations refreshed"
}

# Pick the apps to show from what is installed: a checklist with the current
# ones ticked. This is what "Add or remove apps" in the bar panel opens.
cmd_manage() {
  local list line id was picked="" chosen=() add=() drop=() selected=() labels=() take=yes
  local -A id_of=()
  have gum || die "winapp manage needs gum (omarchy pkg add gum). Without it: winapp scan, then winapp add <id>"
  clients_alive && die "$SESSION_IN_USE"
  say "Looking at what is installed in Windows…"
  scan_guest || die "$GUEST_ERROR"
  list=$(installed | jq -r '.[] | [.id, (.name + (if (.ext | length) > 0 then "  (" + (.ext | map("." + .) | .[0:4] | join(" ")) + ")" else "" end) | gsub(","; " ")),
      (if .added then "1" else "0" end)] | join("\t")')
  [[ -n $list ]] || die "no programs were found in Windows. Install one from the desktop first: winapp desktop"
  while IFS=$'\t' read -r id line was; do
    id_of[$line]=$id
    labels+=("$line")
    [[ $was == 1 ]] && selected+=("$line")
  done <<<"$list"

  picked=$(printf '%s\n' "${labels[@]}" | gum choose --no-limit --height=20 \
    --header="Windows apps to show on Linux (space to tick, enter to confirm)" \
    --selected="$(
      IFS=,
      echo "${selected[*]}"
    )") || die "cancelled"
  while IFS= read -r line; do [[ -n $line ]] && chosen+=("${id_of[$line]}"); done <<<"$picked"

  while IFS=$'\t' read -r id line was; do
    if [[ " ${chosen[*]} " == *" $id "* ]]; then
      [[ $was == 0 ]] && add+=("$id")
    else
      [[ $was == 1 ]] && drop+=("$id")
    fi
  done <<<"$list"
  if ((${#add[@]} + ${#drop[@]} == 0)); then
    say "Nothing to change."
    return 0
  fi

  for id in "${drop[@]}"; do
    apps_update '.apps |= map(select(.id != $id))' --arg id "$id"
    rm -f "$ICON_DIR/$id.png"
    say "Removed $id"
  done
  if ((${#add[@]})); then
    confirm "Open the new apps' own file types with them by default? (No keeps your current default apps)" || take=no
    for id in "${add[@]}"; do
      apps_update '.apps += [$app | {id, name, label, exe, ext, opens, categories, args}
          + (if $take == "yes" then {default: true} else {} end)
          | with_entries(select(.value != "" and .value != []))]' \
        --argjson app "$(installed all | jq -c --arg id "$id" 'map(select(.id == $id))[0]')" --arg take "$take"
      say "Added $(app_field "$id" name)"
    done
    say "Fetching icons…"
    guest_refresh "${add[@]}"
  fi
  sync_desktop
  say "Done. The apps are in the app launcher and the bar panel."
}
