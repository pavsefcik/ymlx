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

# Next free port in 11500-11519 (expert mode), or :11500 only (standard mode).
_ymlx_find_port() {
  if [[ "$YMLX_QUICK_EXPERT" == "on" ]]; then
    local p=11500
    while (( p <= 11519 )); do
      _ymlx_port_free "$p" && { echo "$p"; return; }
      (( p++ ))
    done
    echo ""
    return 1
  fi
  # Standard mode: agentic CLIs talk to :11500 — only that port is allowed.
  # Caller (Swap) is expected to free it before launch.
  if _ymlx_port_free 11500; then
    echo 11500
  else
    echo ""
    return 1
  fi
}

# Human-readable RSS of a pid: ? / 512M / 1.4G.
_ymlx_rss_h() {
  local rss_kb=$(ps -o rss= -p "$1" 2>/dev/null | tr -d ' ')
  [[ -z "$rss_kb" || "$rss_kb" == 0 ]] && { echo "?"; return; }
  if (( rss_kb >= 1048576 )); then
    printf '%.1fG' "$(( rss_kb / 1048576.0 ))"
  else
    printf '%dM' "$(( rss_kb / 1024 ))"
  fi
}

# Human-readable size in KB: ? / 512K / 42M / 1.3G.
_ymlx_format_size() {
  local kb=$1
  if (( kb <= 0 )); then echo "?"; return; fi
  if (( kb >= 1048576 )); then
    printf '%.1fG' "$(( kb / 1048576.0 ))"
  elif (( kb >= 1024 )); then
    printf '%dM' "$(( kb / 1024 ))"
  else
    printf '%dK' "$kb"
  fi
}

# Friendly display name for non-expert users: drop the org prefix
# (e.g. `mlx-community/`). Expert mode keeps the full HF id.
_ymlx_friendly_name() {
  local id="$1"
  if [[ "$YMLX_QUICK_EXPERT" == "on" ]]; then
    print -r -- "$id"
    return
  fi
  print -r -- "${id##*/}"
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

# Cached du -sk of a model's hub folder, refreshed when its mtime changes.
_ymlx_disk_kb() {
  local model="$1" hub_dir="$2" cache_file="$3"
  local folder="$hub_dir/models--${model//\//--}"
  [[ -d "$folder" ]] || { echo 0; return; }
  local mt=$(stat -f %m "$folder" 2>/dev/null)
  if [[ "${_ymlx_size_mt[$model]}" == "$mt" && -n "${_ymlx_size_kb[$model]}" ]]; then
    echo "${_ymlx_size_kb[$model]}"
    return
  fi
  local kb=$(du -sk "$folder" 2>/dev/null | awk '{print $1}')
  _ymlx_size_mt[$model]=$mt
  _ymlx_size_kb[$model]=$kb
  _ymlx_size_save "$cache_file"
  echo $kb
}