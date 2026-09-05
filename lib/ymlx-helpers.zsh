# ymlx helpers — self-contained, arg-driven utilities extracted from the main
# ymlx() body. None of these read ymlx()'s locals. Sourced once by ymlx.zsh
# before ymlx() is defined.

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

# Ensure (add=1) or remove (add=0) a valueless flag in a named array (e.g.
# --enable-thinking). Removes duplicates, then appends if adding.
_ymlx_flag_set() {
  local name="$1" flag="$2" add="$3"
  local -a arr out
  eval "arr=( \"\${${name}[@]}\" )"
  local i
  for (( i=1; i<=${#arr[@]}; i++ )); do
    [[ "${arr[i]}" == "$flag" ]] && continue
    out+=( "${arr[i]}" )
  done
  (( add )) && out+=( "$flag" )
  eval "${name}=( \"\${out[@]}\" )"
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
