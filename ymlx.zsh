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
    local curated_file="$script_dir/curated_LLMs.md"
    typeset -A curated
    local entries=()

    if [[ -r "$curated_file" ]]; then
      local title="" source="" tags="" block_line=0 line
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
          block_line=0
          continue
        fi
        if [[ "$line" == *"GB RAM:"* ]]; then
          entries+=("── ${line%:} ──")
          block_line=0
          continue
        fi
        (( block_line++ ))
        case $block_line in
          1) title="$line" ;;
          2) source="$line" ;;
          3)
            tags="$line"
            local display="$title — $tags"
            entries+=("$display")
            curated[$display]="$source"
            ;;
        esac
      done < "$curated_file"
      # drop file header block ("Title/Source/Tags/Description")
      unset 'curated[Title — Tags]'
      entries=("${(@)entries:#Title — Tags}")
    fi

    entries+=("──────────────" "Custom (paste HuggingFace ID)…" "Step back")

    local pick=$(printf "%s\n" "${entries[@]}" | gum choose --header $'\nDownload new model:' --height 20)
    [[ -z "$pick" ]] && return 1

    if [[ "$pick" == "Step back" || "$pick" == ──* ]]; then
      ymlx
      return
    fi

    local model
    if [[ "$pick" == "Custom (paste HuggingFace ID)…" ]]; then
      model=$(gum input --placeholder "e.g. mlx-community/Ministral-3-3B-Instruct-2512-4bit" --prompt "Model: ")
    else
      model="${curated[$pick]}"
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
