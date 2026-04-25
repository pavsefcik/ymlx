#!/usr/bin/env zsh

ymlx() {
  local YMLX_DEBUG=false
  local hub_dir=~/.cache/huggingface/hub
  local state_dir=~/.cache/ymlx
  local state_file="$state_dir/servers.tsv"
  local log_dir="$state_dir/logs"
  mkdir -p "$state_dir" "$log_dir"
  [[ -f "$state_file" ]] || : > "$state_file"

  _ymlx_prune() {
    local tmp="$state_file.tmp" pid port model
    : > "$tmp"
    while IFS=$'\t' read -r pid port model; do
      [[ -z "$pid" ]] && continue
      if kill -0 "$pid" 2>/dev/null; then
        printf '%s\t%s\t%s\n' "$pid" "$port" "$model" >> "$tmp"
      fi
    done < "$state_file"
    mv "$tmp" "$state_file"
  }

  _ymlx_drop() {
    local target="$1" tmp="$state_file.tmp" pid port model
    : > "$tmp"
    while IFS=$'\t' read -r pid port model; do
      [[ -z "$pid" || "$pid" == "$target" ]] && continue
      printf '%s\t%s\t%s\n' "$pid" "$port" "$model" >> "$tmp"
    done < "$state_file"
    mv "$tmp" "$state_file"
  }

  _ymlx_stop_all() {
    local pid port model
    while IFS=$'\t' read -r pid port model; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && echo "Stopped: $model (:$port)"
    done < "$state_file"
    : > "$state_file"
    rm -f "$state_dir/last_port"
  }

  _ymlx_port_free() {
    ! lsof -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1
  }

  _ymlx_find_port() {
    local last_file="$state_dir/last_port"
    local last=11499
    [[ -r "$last_file" ]] && last=$(<"$last_file")
    local p=$((last + 1))
    (( p < 11500 || p > 11519 )) && p=11500
    local start=$p tries=0
    while ! _ymlx_port_free "$p"; do
      (( p++, tries++ ))
      (( p > 11519 )) && p=11500
      (( tries >= 20 )) && { echo ""; return 1; }
    done
    print -r -- "$p" > "$last_file"
    echo "$p"
  }

  local models selected

  while true; do
    _ymlx_prune
    models=$(ls "$hub_dir" 2>/dev/null | grep '^models--' | sed 's/models--//' | sed 's/--/\//g')

    local main_entries=() pid port model display_a has_active=0
    typeset -A active_pid active_port active_model
    while IFS=$'\t' read -r pid port model; do
      display_a="● $model  :$port  (pid $pid)"
      (( has_active == 0 )) && main_entries+=("─── Running ───")
      has_active=1
      main_entries+=("$display_a")
      active_pid[$display_a]="$pid"
      active_port[$display_a]="$port"
      active_model[$display_a]="$model"
    done < "$state_file"
    if [[ -n "$models" ]]; then
      main_entries+=("─── Installed ───")
      main_entries+=(${(f)models})
    fi
    main_entries+=("──────────────────────" "Open local LLM folder" "Download new model")
    [[ "$YMLX_DEBUG" == true ]] && main_entries+=("Debug: ports 11500-11519")
    main_entries+=("Stop all running models" "Exit // stops all running models")

    selected=$(printf "%s\n" "${main_entries[@]}" | gum choose --header $'\nSelect model:' --height 30)
    [[ -z "$selected" ]] && return 1

    if [[ "$selected" == *───* ]]; then
      continue
    elif [[ "$selected" == "Stop all running models" ]]; then
      _ymlx_stop_all
      continue
    elif [[ "$selected" == "Exit // stops all running models" ]]; then
      _ymlx_stop_all
      return
    elif [[ -n "${active_pid[$selected]}" ]]; then
      local a_pid="${active_pid[$selected]}"
      local a_port="${active_port[$selected]}"
      local a_model="${active_model[$selected]}"
      local action=$(printf "Stop server\nCopy name\nStep back" | gum choose --header $'\n'"$a_model running on :$a_port (pid $a_pid)")
      [[ -z "$action" ]] && continue
      case "$action" in
        "Stop server")
          if kill "$a_pid" 2>/dev/null; then
            echo "Stopped: $a_model on :$a_port (pid $a_pid)"
          else
            echo "Process $a_pid was already gone."
          fi
          _ymlx_drop "$a_pid"
          ;;
        "Copy name")
          echo "$a_model" | pbcopy
          echo "Copied: $a_model"
          ;;
      esac
      continue
    elif [[ "$selected" == "Open local LLM folder" ]]; then
      open "$hub_dir"
      continue
    elif [[ "$selected" == "Debug: ports 11500-11519" ]]; then
      echo "lsof -i :11500-11519"
      echo
      lsof -iTCP:11500-11519 -sTCP:LISTEN -P -n 2>/dev/null || echo "(no listeners)"
      echo
      gum input --placeholder "(press enter to continue)" >/dev/null
      continue
    elif [[ "$selected" == "Download new model" ]]; then
      local script_dir="${${(%):-%x}:A:h}"
      local curated_file="$script_dir/curated-llms.md"

      local ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
      local tier_active tier_dim
      if (( ram_gb >= 24 )); then
        tier_active=24; tier_dim=16
      elif (( ram_gb >= 16 )); then
        tier_active=16; tier_dim=8
      else
        tier_active=8; tier_dim=0
      fi

      typeset -A installed
      local m
      for m in ${(f)models}; do installed[$m]=1; done

      typeset -A curated
      local entries=() curated_count=0
      local dim_on=$'\e[2m' dim_off=$'\e[0m'
      local source="" tags="" block_line=0 line current_tier=0 header num display pending_header=""

      if [[ -r "$curated_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
          if [[ -z "$line" ]]; then
            block_line=0
            continue
          fi
          if [[ "$line" == *"GB RAM"* ]]; then
            header="${line%:}"
            num="${header//[^0-9]/}"
            current_tier=$num
            if (( num == tier_active )); then
              pending_header="── ${header} ──"
            elif (( num == tier_dim )); then
              pending_header="${dim_on}── ${header} ──${dim_off}"
            else
              pending_header=""
            fi
            block_line=0
            continue
          fi
          (( block_line++ ))
          if (( block_line == 1 )); then
            source="$line"
          elif (( block_line == 2 )); then
            tags="$line"
            if [[ -z "${installed[$source]}" ]]; then
              if (( current_tier == tier_active )); then
                display="$source — $tags"
              elif (( current_tier == tier_dim )); then
                display="${dim_on}$source — $tags${dim_off}"
              else
                display=""
              fi
              if [[ -n "$display" ]]; then
                if [[ -n "$pending_header" ]]; then
                  entries+=("$pending_header")
                  pending_header=""
                fi
                entries+=("$display")
                curated[$display]="$source"
                (( curated_count++ ))
              fi
            fi
          fi
        done < "$curated_file"
      fi

      if (( curated_count == 0 )); then
        entries+=("No more hand picked models available")
      fi
      entries+=("──────────────" "Custom (paste HuggingFace ID)…" "Step back")

      local pick=$(printf "%s\n" "${entries[@]}" | gum choose --header $'\nDownload new model:' --height 30)
      [[ -z "$pick" ]] && continue

      if [[ "$pick" == "Step back" || "$pick" == *──* || "$pick" == "No more hand picked models available" ]]; then
        continue
      fi

      local model
      if [[ "$pick" == "Custom (paste HuggingFace ID)…" ]]; then
        model=$(gum input --placeholder "e.g. mlx-community/Ministral-3-3B-Instruct-2512-4bit" --prompt "Model: ")
      else
        local clean=$(print -r -- "$pick" | sed $'s/\x1b\\[[0-9;]*m//g')
        model="${clean%% — *}"
      fi
      [[ -z "$model" ]] && continue
      uvx --from mlx-lm python3 -c "from mlx_lm import load; load('$model')"
      continue
    fi

    local action=$(printf "Run chat\nRun server\nCopy name\nRemove from folder\nStep back" | gum choose --header $'\n'"$selected:")
    [[ -z "$action" ]] && continue

    case "$action" in
      "Run chat")
        mlx_lm.chat --model "$selected" --max-tokens 2048 --temp 0.7 --top-p 0.9
        ;;
      "Run server")
        local port=$(_ymlx_find_port)
        if [[ -z "$port" ]]; then
          echo "No free port in 11500-11519."
          continue
        fi
        local safe="${selected//\//_}"
        local log="$log_dir/${safe}-${port}.log"
        mlx_lm.server --model "$selected" --port "$port" >"$log" 2>&1 &
        local pid=$!
        printf '%s\t%s\t%s\n' "$pid" "$port" "$selected" >> "$state_file"
        local rc=0
        gum spin --spinner dot --title "Initializing $selected… (Ctrl-C to cancel)" -- zsh -c "
          while kill -0 $pid 2>/dev/null; do
            [[ -s '$log' ]] && exit 0
            sleep 0.3
          done
          exit 1
        " && \
        gum spin --spinner dot --title "Loading model weights…" -- zsh -c "
          while kill -0 $pid 2>/dev/null; do
            curl -fs -o /dev/null --max-time 1 http://127.0.0.1:$port/v1/models && exit 0
            grep -qE 'Starting|Uvicorn|running|listening|Application startup' '$log' 2>/dev/null && exit 0
            sleep 0.5
          done
          exit 1
        " && \
        gum spin --spinner dot --title "Warming up server on :$port…" -- zsh -c "
          while kill -0 $pid 2>/dev/null; do
            curl -fs -o /dev/null --max-time 1 http://127.0.0.1:$port/v1/models && exit 0
            sleep 0.5
          done
          exit 1
        "
        rc=$?
        if (( rc == 0 )); then
          echo "Started: $selected on :$port (pid $pid)"
          echo "Logs: $log"
        elif kill -0 "$pid" 2>/dev/null; then
          if gum confirm "Loading cancelled. Kill $selected (pid $pid)?"; then
            kill "$pid" 2>/dev/null
            _ymlx_drop "$pid"
            echo "Killed: $selected"
          else
            echo "Still loading in background on :$port (pid $pid). Logs: $log"
          fi
        else
          _ymlx_drop "$pid"
          echo "Failed to start $selected. Last log lines:"
          tail -n 20 "$log"
        fi
        ;;
      "Copy name")
        echo "$selected" | pbcopy
        echo "Copied: $selected"
        ;;
      "Remove from folder")
        local folder="$hub_dir/models--${selected//\//--}"
        if [[ ! -d "$folder" ]]; then
          echo "Folder not found: $folder"
        elif gum confirm "Remove $selected from $hub_dir?"; then
          rm -rf "$folder"
          echo "Removed: $selected"
        fi
        ;;
      "Step back")
        ;;
    esac
  done
}

_ymlx_cleanup() {
  local sf=~/.cache/ymlx/servers.tsv
  [[ -f $sf ]] || return
  local pid port model
  while IFS=$'\t' read -r pid port model; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done < "$sf"
  : > "$sf"
  rm -f ~/.cache/ymlx/last_port
}
trap _ymlx_cleanup EXIT INT TERM HUP

ymlx "$@"
