#!/usr/bin/env zsh

ymlx() {
  local YMLX_DEBUG=false
  local hub_dir=~/.cache/huggingface/hub
  local state_dir=~/.cache/ymlx
  local state_file="$state_dir/servers.tsv"
  local size_cache_file="$state_dir/sizes.tsv"
  local log_dir="$state_dir/logs"
  local config_file="$state_dir/config.zsh"

  typeset -ga YMLX_CHAT_FLAGS=( --max-tokens 2048 --temp 0.7 --top-p 0.9 )
  typeset -ga YMLX_SERVER_FLAGS=()

  local cmd missing=()
  for cmd in gum curl uvx mlx_lm.server mlx_lm.chat; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    print -u2 "ymlx: missing required tool(s): ${missing[*]}"
    print -u2 ""
    print -u2 "Install with:"
    print -u2 "  brew install uv gum && uv tool install mlx-lm"
    return 1
  fi

  mkdir -p "$state_dir" "$log_dir"
  [[ -f "$state_file" ]] || : > "$state_file"

  _ymlx_write_default_config() {
    cat > "$1" <<'CFG'
# ymlx config — sourced on startup. Use "Settings" in the main menu for the
# common toggles (thinking / temp / max-tokens / system prompt); they live in
# the managed block below and ymlx rewrites it. Hand-edit anything below the
# block to add advanced flags — see `mlx_lm.chat --help` / `mlx_lm.server --help`.
# --model / --port / --host are managed by ymlx (port auto-discovery 11500-11519).

# >>> ymlx-managed quick settings — edit via "Settings" menu, not by hand <<<
YMLX_QUICK_THINKING="default"      # default | on | off  (default = use model's built-in)
YMLX_QUICK_TEMP=""                 # e.g. 0.7, or empty to use YMLX_CHAT_FLAGS default
YMLX_QUICK_MAX_TOKENS=""           # e.g. 2048, or empty to use YMLX_CHAT_FLAGS default
YMLX_QUICK_SYSTEM_PROMPT=""        # chat only; empty disables
# <<< end ymlx-managed >>>

YMLX_CHAT_FLAGS=(
  --max-tokens 2048
  --temp 0.7
  --top-p 0.9
  # --xtc-probability 0.0
  # --xtc-threshold 0.1
  # --seed 42
  # --max-kv-size 4096
  # --system-prompt "You are a helpful assistant."
  # --chat-template-args '{"enable_thinking": true}'
  # --trust-remote-code
  # --adapter-path /path/to/adapter
  # --pipeline
)

YMLX_SERVER_FLAGS=(
  # --temp 0.7
  # --top-p 0.9
  # --top-k 40
  # --min-p 0.05
  # --max-tokens 2048
  # --draft-model mlx-community/some-draft-model
  # --num-draft-tokens 4
  # --trust-remote-code
  # --log-level INFO
  # --chat-template ""
  # --use-default-chat-template
  # --chat-template-args '{"enable_thinking": true}'
  # --decode-concurrency 1
  # --prompt-concurrency 1
  # --prefill-step-size 2048
  # --prompt-cache-size 0
  # --prompt-cache-bytes 0
  # --pipeline
  # --adapter-path /path/to/adapter
  # --allowed-origins "*"
)
CFG
  }

  typeset -g YMLX_QUICK_THINKING="default"
  typeset -g YMLX_QUICK_TEMP=""
  typeset -g YMLX_QUICK_MAX_TOKENS=""
  typeset -g YMLX_QUICK_SYSTEM_PROMPT=""

  _ymlx_talk_info() {
    local m="$1" p="$2"
    gum style --foreground 212 --bold "Server details"
    echo "  OpenAI-compatible base URL:  http://127.0.0.1:$p/v1"
    echo "  Endpoints:                   /v1/chat/completions   /v1/completions   /v1/models"
    echo "  No API key required (any string works if a client demands one)."
    echo
    gum style --foreground 244 "  curl -s http://127.0.0.1:$p/v1/chat/completions \\"
    gum style --foreground 244 "    -H 'Content-Type: application/json' \\"
    gum style --foreground 244 "    -d '{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' | jq -r .choices[0].message.content"
    echo
    gum style --foreground 244 "  # Python (openai SDK):"
    gum style --foreground 244 "  #   client = OpenAI(base_url='http://127.0.0.1:$p/v1', api_key='-')"
    gum style --foreground 244 "  #   client.chat.completions.create(model='$m', messages=[...])"
  }

  _ymlx_chat_repl() {
    local model="$1" port="$2"
    if ! command -v python3 >/dev/null 2>&1; then
      gum style --foreground 196 "python3 not found — install Xcode Command Line Tools (xcode-select --install) to use 'Talk to it'."
      gum input --placeholder "(press enter to continue)" >/dev/null
      return 1
    fi
    local url="http://127.0.0.1:$port/v1/chat/completions"
    local sysp="$YMLX_QUICK_SYSTEM_PROMPT"
    echo
    gum style --foreground 212 --bold "Chatting with $model on :$port"
    echo "  Commands: /reset clears history · /exit or Ctrl-D to leave"
    [[ -n "$sysp" ]] && echo "  System prompt: ${sysp:0:80}$([[ ${#sysp} -gt 80 ]] && echo '…')"
    case "$YMLX_QUICK_THINKING" in
      off)     echo "  Thinking: off (hiding <think>/[THINK] blocks from output)" ;;
      on)      echo "  Thinking: on" ;;
      *)       echo "  Thinking: default (model decides — change in Settings to force off)" ;;
    esac
    echo
    python3 -c "$(cat <<'PY'
import sys, json, re, urllib.request, urllib.error
url, model = sys.argv[1], sys.argv[2]
sysp = sys.argv[3] if len(sys.argv) > 3 else ""
strip_think = (sys.argv[4] == "off") if len(sys.argv) > 4 else False
base = ([{"role":"system","content":sysp}] if sysp else [])
messages = list(base)

OPEN = re.compile(r'<think>|\[THINK\]', re.IGNORECASE)
CLOSE = re.compile(r'</think>|\[/THINK\]', re.IGNORECASE)
TAIL = 10  # max bytes to hold back in case a tag straddles chunks

class Filter:
    def __init__(self, on):
        self.on = on
        self.in_think = False
        self.buf = ""
    def feed(self, text):
        if not self.on:
            return text
        self.buf += text
        out = []
        while True:
            if self.in_think:
                m = CLOSE.search(self.buf)
                if not m:
                    if len(self.buf) > TAIL:
                        self.buf = self.buf[-TAIL:]
                    break
                self.buf = self.buf[m.end():]
                self.in_think = False
            else:
                m = OPEN.search(self.buf)
                if m:
                    out.append(self.buf[:m.start()])
                    self.buf = self.buf[m.end():]
                    self.in_think = True
                else:
                    if len(self.buf) > TAIL:
                        out.append(self.buf[:-TAIL])
                        self.buf = self.buf[-TAIL:]
                    break
        return "".join(out)
    def flush(self):
        if not self.on or self.in_think:
            self.buf = ""
            self.in_think = False
            return ""
        rest, self.buf = self.buf, ""
        return rest

try:
    while True:
        try:
            user = input("\033[1;36myou>\033[0m ")
        except EOFError:
            print(); break
        s = user.strip()
        if not s: continue
        if s in ("/exit","/quit","exit","quit"): break
        if s == "/reset":
            messages = list(base)
            print("\033[2m(history cleared)\033[0m"); continue
        messages.append({"role":"user","content":user})
        body = json.dumps({"model":model,"messages":messages,"stream":True}).encode()
        req = urllib.request.Request(url, data=body, headers={"Content-Type":"application/json"})
        print("\033[1;35massistant>\033[0m ", end="", flush=True)
        full = ""
        flt = Filter(strip_think)
        try:
            with urllib.request.urlopen(req) as r:
                for raw in r:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"): continue
                    data = line[5:].strip()
                    if data == "[DONE]": break
                    try:
                        chunk = json.loads(data)
                        delta = chunk["choices"][0]["delta"].get("content","")
                        if delta:
                            full += delta
                            visible = flt.feed(delta)
                            if visible:
                                print(visible, end="", flush=True)
                    except json.JSONDecodeError:
                        pass
            tail = flt.flush()
            if tail:
                print(tail, end="", flush=True)
        except urllib.error.URLError as e:
            print(f"\n\033[31m[error] {e}\033[0m")
            messages.pop()
            continue
        except KeyboardInterrupt:
            print("\n\033[2m[interrupted]\033[0m")
            messages.pop()
            continue
        print()
        # Keep full (with thinking) in history so the model has context;
        # only display is filtered.
        messages.append({"role":"assistant","content":full})
except KeyboardInterrupt:
    print()
PY
)" "$url" "$model" "$sysp" "$YMLX_QUICK_THINKING"
  }

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

  _ymlx_apply_quick() {
    local cta=""
    case "$YMLX_QUICK_THINKING" in
      on)  cta='{"enable_thinking": true}' ;;
      off) cta='{"enable_thinking": false}' ;;
    esac
    if [[ -n "$cta" ]]; then
      _ymlx_replace_or_append YMLX_CHAT_FLAGS --chat-template-args "$cta"
      _ymlx_replace_or_append YMLX_SERVER_FLAGS --chat-template-args "$cta"
    fi
    if [[ -n "$YMLX_QUICK_TEMP" ]]; then
      _ymlx_replace_or_append YMLX_CHAT_FLAGS --temp "$YMLX_QUICK_TEMP"
      _ymlx_replace_or_append YMLX_SERVER_FLAGS --temp "$YMLX_QUICK_TEMP"
    fi
    if [[ -n "$YMLX_QUICK_MAX_TOKENS" ]]; then
      _ymlx_replace_or_append YMLX_CHAT_FLAGS --max-tokens "$YMLX_QUICK_MAX_TOKENS"
      _ymlx_replace_or_append YMLX_SERVER_FLAGS --max-tokens "$YMLX_QUICK_MAX_TOKENS"
    fi
    if [[ -n "$YMLX_QUICK_SYSTEM_PROMPT" ]]; then
      _ymlx_replace_or_append YMLX_CHAT_FLAGS --system-prompt "$YMLX_QUICK_SYSTEM_PROMPT"
    fi
  }

  # Rewrite the managed block in config.zsh from current YMLX_QUICK_* values.
  # Preserves everything outside the markers; inserts at top if no block exists.
  _ymlx_write_managed_block() {
    local cf="$1" tmp="$cf.tmp"
    local has_block=0
    grep -q '^# >>> ymlx-managed' "$cf" && has_block=1
    {
      if (( ! has_block )); then
        printf '%s\n' \
          '# >>> ymlx-managed quick settings — edit via "Settings" menu, not by hand <<<' \
          "YMLX_QUICK_THINKING=${(qq)YMLX_QUICK_THINKING}" \
          "YMLX_QUICK_TEMP=${(qq)YMLX_QUICK_TEMP}" \
          "YMLX_QUICK_MAX_TOKENS=${(qq)YMLX_QUICK_MAX_TOKENS}" \
          "YMLX_QUICK_SYSTEM_PROMPT=${(qq)YMLX_QUICK_SYSTEM_PROMPT}" \
          '# <<< end ymlx-managed >>>' \
          ''
      fi
      local in_block=0 line
      while IFS= read -r line; do
        if [[ "$line" == '# >>> ymlx-managed'* ]]; then
          in_block=1
          printf '%s\n' \
            '# >>> ymlx-managed quick settings — edit via "Settings" menu, not by hand <<<' \
            "YMLX_QUICK_THINKING=${(qq)YMLX_QUICK_THINKING}" \
            "YMLX_QUICK_TEMP=${(qq)YMLX_QUICK_TEMP}" \
            "YMLX_QUICK_MAX_TOKENS=${(qq)YMLX_QUICK_MAX_TOKENS}" \
            "YMLX_QUICK_SYSTEM_PROMPT=${(qq)YMLX_QUICK_SYSTEM_PROMPT}" \
            '# <<< end ymlx-managed >>>'
          continue
        fi
        if [[ "$line" == '# <<< end ymlx-managed'* ]]; then
          in_block=0
          continue
        fi
        (( in_block )) && continue
        print -r -- "$line"
      done < "$cf"
    } > "$tmp"
    mv "$tmp" "$cf"
  }

  _ymlx_reload_config() {
    source "$config_file"
    _ymlx_apply_quick
  }

  _ymlx_settings_menu() {
    while true; do
      local cur_t="${YMLX_QUICK_THINKING:-default}"
      local cur_temp="${YMLX_QUICK_TEMP:-default}"
      local cur_max="${YMLX_QUICK_MAX_TOKENS:-default}"
      local cur_sys
      if [[ -n "$YMLX_QUICK_SYSTEM_PROMPT" ]]; then
        cur_sys="(${#YMLX_QUICK_SYSTEM_PROMPT} chars)"
      else
        cur_sys="(none)"
      fi
      local choice=$(printf "%s\n" \
        "Thinking:       $cur_t" \
        "Temperature:    $cur_temp" \
        "Max tokens:     $cur_max" \
        "System prompt:  $cur_sys" \
        "──────────────" \
        "Advanced settings (edit config.zsh)" \
        "Back" \
        | gum choose --header $'\nSettings (current values shown):' --height 12)
      [[ -z "$choice" || "$choice" == "Back" ]] && return
      case "$choice" in
        "Thinking:"*)
          local pick=$(printf "default\non\noff" | gum choose --header "Enable thinking?")
          [[ -n "$pick" ]] && YMLX_QUICK_THINKING="$pick"
          ;;
        "Temperature:"*)
          local pick=$(printf "default\n0.0\n0.3\n0.7\n1.0\nCustom…" | gum choose --header "Temperature")
          case "$pick" in
            default) YMLX_QUICK_TEMP="" ;;
            "Custom…") YMLX_QUICK_TEMP=$(gum input --placeholder "e.g. 0.5" --value "$YMLX_QUICK_TEMP") ;;
            "") ;;
            *) YMLX_QUICK_TEMP="$pick" ;;
          esac
          ;;
        "Max tokens:"*)
          local pick=$(printf "default\n512\n2048\n8192\n32768\nCustom…" | gum choose --header "Max tokens")
          case "$pick" in
            default) YMLX_QUICK_MAX_TOKENS="" ;;
            "Custom…") YMLX_QUICK_MAX_TOKENS=$(gum input --placeholder "e.g. 4096" --value "$YMLX_QUICK_MAX_TOKENS") ;;
            "") ;;
            *) YMLX_QUICK_MAX_TOKENS="$pick" ;;
          esac
          ;;
        "System prompt:"*)
          local sub=$(printf "Edit\nClear\nCancel" | gum choose --header "System prompt")
          case "$sub" in
            Edit)
              local new
              new=$(gum write --placeholder "Type system prompt — Ctrl-D to save, Esc to cancel" --value "$YMLX_QUICK_SYSTEM_PROMPT" --width 80 --height 12)
              [[ $? -eq 0 && -n "$new" ]] && YMLX_QUICK_SYSTEM_PROMPT="$new"
              ;;
            Clear) YMLX_QUICK_SYSTEM_PROMPT="" ;;
          esac
          ;;
        "Advanced settings"*)
          local ed=$(_ymlx_pick_editor)
          eval "$ed \"\$config_file\""
          _ymlx_reload_config
          continue
          ;;
      esac
      _ymlx_write_managed_block "$config_file"
      _ymlx_reload_config
    done
  }

  [[ -f "$config_file" ]] || _ymlx_write_default_config "$config_file"
  _ymlx_reload_config

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
  }

  _ymlx_port_free() {
    ! lsof -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1
  }

  _ymlx_find_port() {
    local p=11500
    while (( p <= 11519 )); do
      _ymlx_port_free "$p" && { echo "$p"; return; }
      (( p++ ))
    done
    echo ""
    return 1
  }

  _ymlx_rss_h() {
    local rss_kb=$(ps -o rss= -p "$1" 2>/dev/null | tr -d ' ')
    [[ -z "$rss_kb" || "$rss_kb" == 0 ]] && { echo "?"; return; }
    if (( rss_kb >= 1048576 )); then
      printf '%.1fG' "$(( rss_kb / 1048576.0 ))"
    else
      printf '%dM' "$(( rss_kb / 1024 ))"
    fi
  }

  typeset -gA _ymlx_size_mt _ymlx_size_kb
  _ymlx_size_load() {
    [[ -f "$size_cache_file" ]] || return
    local m mt kb
    while IFS=$'\t' read -r m mt kb; do
      [[ -z "$m" ]] && continue
      _ymlx_size_mt[$m]=$mt
      _ymlx_size_kb[$m]=$kb
    done < "$size_cache_file"
  }

  _ymlx_size_save() {
    local tmp="$size_cache_file.tmp" m
    : > "$tmp"
    for m in ${(k)_ymlx_size_kb}; do
      printf '%s\t%s\t%s\n' "$m" "${_ymlx_size_mt[$m]}" "${_ymlx_size_kb[$m]}" >> "$tmp"
    done
    mv "$tmp" "$size_cache_file"
  }

  _ymlx_disk_kb() {
    local model="$1"
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
    _ymlx_size_save
    echo $kb
  }

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

  _ymlx_size_load

  _ymlx_launch() {
    local model="$1"
    local port=$(_ymlx_find_port)
    if [[ -z "$port" ]]; then
      echo "No free port in 11500-11519."
      return 1
    fi
    local safe="${model//\//_}"
    local log="$log_dir/${safe}-${port}.log"
    mlx_lm.server --model "$model" --port "$port" "${YMLX_SERVER_FLAGS[@]}" >"$log" 2>&1 &
    local pid=$!
    printf '%s\t%s\t%s\n' "$pid" "$port" "$model" >> "$state_file"
    local rc=0
    gum spin --spinner dot --title "Initializing $model… (Ctrl-C to cancel)" -- zsh -c "
      while kill -0 $pid 2>/dev/null; do
        [[ -s '$log' ]] && exit 0
        sleep 0.3
      done
      exit 1
    "
    rc=$?
    if (( rc == 0 )); then
      echo "  ✓ Initialized"
      gum spin --spinner dot --title "Loading model weights…" -- zsh -c "
        while kill -0 $pid 2>/dev/null; do
          curl -fs -o /dev/null --max-time 1 http://127.0.0.1:$port/v1/models && exit 0
          grep -qE 'Starting|Uvicorn|running|listening|Application startup' '$log' 2>/dev/null && exit 0
          sleep 0.5
        done
        exit 1
      "
      rc=$?
    fi
    if (( rc == 0 )); then
      echo "  ✓ Weights loaded"
      gum spin --spinner dot --title "Warming up server on :$port…" -- zsh -c "
        while kill -0 $pid 2>/dev/null; do
          curl -fs -o /dev/null --max-time 1 http://127.0.0.1:$port/v1/models && exit 0
          sleep 0.5
        done
        exit 1
      "
      rc=$?
      (( rc == 0 )) && echo "  ✓ Server ready"
    fi
    if (( rc == 0 )); then
      echo "Started: $model on :$port (pid $pid)"
      echo "Logs: $log"
      echo
      _ymlx_talk_info "$model" "$port"
    elif kill -0 "$pid" 2>/dev/null; then
      if gum confirm "Loading cancelled. Kill $model (pid $pid)?"; then
        kill "$pid" 2>/dev/null
        _ymlx_drop "$pid"
        echo "Killed: $model"
      else
        echo "Still loading in background on :$port (pid $pid). Logs: $log"
      fi
    else
      _ymlx_drop "$pid"
      echo "Failed to start $model. Last log lines:"
      tail -n 20 "$log"
    fi
  }

  local models selected

  while true; do
    _ymlx_prune
    models=$(ls "$hub_dir" 2>/dev/null | grep '^models--' | sed 's/models--//' | sed 's/--/\//g')

    local main_entries=() pid port model display_a display_i has_active=0 rss_h disk_h
    typeset -A active_pid active_port active_model installed_model
    while IFS=$'\t' read -r pid port model; do
      rss_h=$(_ymlx_rss_h "$pid")
      display_a="● $model  :$port  $rss_h  (pid $pid)"
      (( has_active == 0 )) && main_entries+=("─── Running ───")
      has_active=1
      main_entries+=("$display_a")
      active_pid[$display_a]="$pid"
      active_port[$display_a]="$port"
      active_model[$display_a]="$model"
    done < "$state_file"
    if [[ -n "$models" ]]; then
      local m total_kb=0 m_kb
      typeset -A model_kb
      for m in ${(f)models}; do
        m_kb=$(_ymlx_disk_kb "$m")
        model_kb[$m]=$m_kb
        (( total_kb += m_kb ))
      done
      main_entries+=("─── Installed ($(_ymlx_format_size $total_kb) total) ───")
      for m in ${(f)models}; do
        display_i="$m  ($(_ymlx_format_size ${model_kb[$m]}))"
        main_entries+=("$display_i")
        installed_model[$display_i]="$m"
      done
    fi
    main_entries+=("──────────────────────" "Settings" "Open local LLM folder" "Download new model")
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
      local action=$(printf "Talk to it\nServer details\nRestart\nStop server\nSettings\nCopy name\nTail logs\nBack" | gum choose --header $'\n'"$a_model running on :$a_port (pid $a_pid)")
      [[ -z "$action" ]] && continue
      case "$action" in
        "Settings")
          local _before="$YMLX_QUICK_THINKING|$YMLX_QUICK_TEMP|$YMLX_QUICK_MAX_TOKENS|$YMLX_QUICK_SYSTEM_PROMPT|${(j:\0:)YMLX_CHAT_FLAGS}|${(j:\0:)YMLX_SERVER_FLAGS}"
          _ymlx_settings_menu
          local _after="$YMLX_QUICK_THINKING|$YMLX_QUICK_TEMP|$YMLX_QUICK_MAX_TOKENS|$YMLX_QUICK_SYSTEM_PROMPT|${(j:\0:)YMLX_CHAT_FLAGS}|${(j:\0:)YMLX_SERVER_FLAGS}"
          if [[ "$_before" != "$_after" ]] && kill -0 "$a_pid" 2>/dev/null; then
            if gum confirm "Restart $a_model to apply new settings?"; then
              kill "$a_pid" 2>/dev/null
              _ymlx_drop "$a_pid"
              _ymlx_launch "$a_model"
            else
              gum style --foreground 244 "(new settings will apply on next Restart)"
            fi
          fi
          ;;
        "Talk to it")
          _ymlx_chat_repl "$a_model" "$a_port"
          ;;
        "Server details")
          _ymlx_talk_info "$a_model" "$a_port"
          gum input --placeholder "(press enter to continue)" >/dev/null
          ;;
        "Tail logs")
          local safe="${a_model//\//_}"
          local log="$log_dir/${safe}-${a_port}.log"
          if [[ -f "$log" ]]; then
            local ed=$(_ymlx_pick_editor)
            eval "$ed \"\$log\""
          else
            echo "Log not found: $log"
          fi
          ;;
        "Restart")
          if kill "$a_pid" 2>/dev/null; then
            echo "Stopped: $a_model on :$a_port (pid $a_pid)"
          fi
          _ymlx_drop "$a_pid"
          _ymlx_launch "$a_model"
          ;;
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
    elif [[ "$selected" == "Settings" ]]; then
      _ymlx_settings_menu
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
      echo
      gum style --foreground 212 --bold "Downloading $model"
      echo "(progress will stream below — Ctrl-C to abort)"
      echo
      if uvx --from mlx-lm python3 -c "from mlx_lm import load; load('$model')"; then
        echo
        gum style --foreground 42 "✓ Downloaded: $model"
      else
        echo
        gum style --foreground 196 "✗ Download failed or cancelled."
      fi
      gum input --placeholder "(press enter to continue)" >/dev/null
      continue
    fi

    [[ -n "${installed_model[$selected]}" ]] && selected="${installed_model[$selected]}"

    local action=$(printf "Run server\nRun chat\nSettings\nCopy name\nRemove\nBack" | gum choose --header $'\n'"$selected:")
    [[ -z "$action" ]] && continue

    case "$action" in
      "Settings")
        _ymlx_settings_menu
        ;;
      "Run chat")
        mlx_lm.chat --model "$selected" "${YMLX_CHAT_FLAGS[@]}"
        ;;
      "Run server")
        _ymlx_launch "$selected"
        ;;
      "Copy name")
        echo "$selected" | pbcopy
        echo "Copied: $selected"
        ;;
      "Remove")
        local folder="$hub_dir/models--${selected//\//--}"
        if [[ ! -d "$folder" ]]; then
          echo "Folder not found: $folder"
        elif gum confirm "Remove $selected from $hub_dir?"; then
          rm -rf "$folder"
          unset "_ymlx_size_mt[$selected]" "_ymlx_size_kb[$selected]"
          _ymlx_size_save
          echo "Removed: $selected"
        fi
        ;;
      "Back")
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
}
trap _ymlx_cleanup EXIT INT TERM HUP

ymlx "$@"
