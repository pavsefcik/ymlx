# ymlx helpers — self-contained, arg-driven utilities extracted from the main
# ymlx() body. None of these read ymlx()'s locals; paths needed by the size
# cache are passed in as arguments. Sourced once by ymlx.zsh before ymlx() is
# defined.

# Pick a beginner-friendly editor: micro > nano > $EDITOR/$VISUAL > vi.
_ymlx_pick_editor() {
  if command -v micro >/dev/null 2>&1; then echo micro
  elif command -v nano >/dev/null 2>&1; then echo nano
  elif [[ -n "$VISUAL" ]] && command -v "${VISUAL%% *}" >/dev/null 2>&1; then echo "$VISUAL"
  elif [[ -n "$EDITOR" ]] && command -v "${EDITOR%% *}" >/dev/null 2>&1; then echo "$EDITOR"
  else echo vi
  fi
}

# Replace --flag value in a named array, or append if absent.
_ymlx_replace_or_append() {
  local name="$1" flag="$2" value="$3"
  local -a arr
  eval "arr=( \"\${${name}[@]}\" )"
  local i found=0
  for (( i=1; i<=${#arr[@]}; i++ )); do
    if [[ "${arr[i]}" == "$flag" ]]; then
      arr[i+1]="$value"
      found=1
      break
    fi
  done
  (( found )) || arr+=( "$flag" "$value" )
  eval "${name}=( \"\${arr[@]}\" )"
}

# Is TCP port $1 free (nothing listening)?
_ymlx_port_free() {
  ! lsof -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1
}

# ymlx pins everything to :11500 so agentic CLIs always find the model.
_ymlx_find_port() {
  if _ymlx_port_free 11500; then
    echo 11500
  else
    echo ""
    return 1
  fi
}

# Friendly display name: drop the org prefix (e.g. `mlx-community/`).
_ymlx_friendly_name() {
  print -r -- "${1##*/}"
}

_ymlx_display_name() {
  _ymlx_friendly_name "$1"
}

# Disk-usage cache. The associative arrays (_ymlx_size_mt/_ymlx_size_kb) are
# declared global here; the cache file path is passed in by the caller.
typeset -gA _ymlx_size_mt _ymlx_size_kb

# Load $cache_file (model<TAB>mtime<TAB>kb) into the size cache.
_ymlx_size_load() {
  local cache_file="$1"
  [[ -f "$cache_file" ]] || return
  local m mt kb
  while IFS=$'\t' read -r m mt kb; do
    [[ -z "$m" ]] && continue
    _ymlx_size_mt[$m]=$mt
    _ymlx_size_kb[$m]=$kb
  done < "$cache_file"
}

# Write the size cache back to $cache_file.
_ymlx_size_save() {
  local cache_file="$1"
  local tmp="$cache_file.tmp" m
  : > "$tmp"
  for m in ${(k)_ymlx_size_kb}; do
    printf '%s\t%s\t%s\n' "$m" "${_ymlx_size_mt[$m]}" "${_ymlx_size_kb[$m]}" >> "$tmp"
  done
  mv "$tmp" "$cache_file"
}