#!/usr/bin/env zsh

ymlx() {
  local hub_dir=~/.cache/huggingface/hub
  local models=$(ls "$hub_dir" | grep '^models--' | sed 's/models--//' | sed 's/--/\//g')

  local selected=$(printf "%s\n──────────────────────\nOpen local LLM folder\nDownload new model\nExit" "$models" | gum choose --header $'\nSelect model:' --height 20)
  [[ -z "$selected" ]] && return 1

  if [[ "$selected" == "──────────────────────" ]]; then
    return
  elif [[ "$selected" == "Exit" ]]; then
    return
  elif [[ "$selected" == "Open local LLM folder" ]]; then
    open "$hub_dir"
    return
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
    local entries=()
    local dim_on=$'\e[2m' dim_off=$'\e[0m'
    local source="" tags="" block_line=0 line current_tier=0 header num display

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
            entries+=("── ${header} ──")
          elif (( num == tier_dim )); then
            entries+=("${dim_on}── ${header} ──${dim_off}")
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
              entries+=("$display")
              curated[$display]="$source"
            elif (( current_tier == tier_dim )); then
              display="${dim_on}$source — $tags${dim_off}"
              entries+=("$display")
              curated[$display]="$source"
            fi
          fi
        fi
      done < "$curated_file"
    fi

    entries+=("──────────────" "Custom (paste HuggingFace ID)…" "Step back")

    local pick=$(printf "%s\n" "${entries[@]}" | gum choose --header $'\nDownload new model:' --height 20)
    [[ -z "$pick" ]] && return 1

    if [[ "$pick" == "Step back" || "$pick" == *──* ]]; then
      ymlx
      return
    fi

    local model
    if [[ "$pick" == "Custom (paste HuggingFace ID)…" ]]; then
      model=$(gum input --placeholder "e.g. mlx-community/Ministral-3-3B-Instruct-2512-4bit" --prompt "Model: ")
    else
      local clean=$(print -r -- "$pick" | sed $'s/\x1b\\[[0-9;]*m//g')
      model="${clean%% — *}"
    fi
    [[ -z "$model" ]] && return 1
    uvx --from mlx-lm python3 -c "from mlx_lm import load; load('$model')"
    return
  fi

  local action=$(printf "Run chat\nRun server\nCopy name\nStep back" | gum choose --header $'\n'"$selected:")
  [[ -z "$action" ]] && return 1

  case "$action" in
    "Run chat")
      mlx_lm.chat --model "$selected" --max-tokens 2048 --temp 0.7 --top-p 0.9
      ;;
    "Run server")
      mlx_lm.server --model "$selected"
      ;;
    "Copy name")
      echo "$selected" | pbcopy
      echo "Copied: $selected"
      ;;
    "Step back")
      ymlx
      ;;
  esac
}

ymlx "$@"
