#!/usr/bin/env zsh

unsetopt xtrace verbose 2>/dev/null

# Pids ymlx launched in this shell session. The EXIT trap kills these so child
# servers don't outlive their manager. Servers from other sessions or external
# processes are discovered live via lsof+ps in _ymlx_running and aren't tracked
# here, so we won't kill what we didn't start.
typeset -ga _YMLX_SESSION_PIDS=()

# Self-contained helpers (no dependence on ymlx()'s locals) live in lib/.
source "${0:A:h}/lib/ymlx-helpers.zsh"

ymlx() {
  local YMLX_DEBUG=false
  local hub_dir=~/.cache/huggingface/hub
  local state_dir=~/.cache/ymlx
  local size_cache_file="$state_dir/sizes.tsv"
  local log_dir="$state_dir/logs"
  local config_file="$state_dir/config.zsh"
  local last_model_file="$state_dir/last.txt"
  local chat_dir="$state_dir/chats"

  typeset -ga YMLX_CHAT_FLAGS=( --max-tokens 2048 --temp 0.7 --top-p 0.9 )
  typeset -ga YMLX_SERVER_FLAGS=()

  local cmd missing=()
  for cmd in gum curl uvx mlx_lm.server mlx_lm.chat mlx_lm.generate; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    print -u2 "ymlx: missing required tool(s): ${missing[*]}"
    print -u2 ""
    print -u2 "Install with:"
    print -u2 "  brew install uv gum && uv tool install mlx-lm"
    return 1
  fi

  mkdir -p "$state_dir" "$log_dir" "$chat_dir"

  # The curated download list lives in the standalone ymlx-curator repo; pull
  # the latest copy at startup and cache it. If the fetch fails (offline),
  # fall back to the last cached copy.
  local curated_url="https://raw.githubusercontent.com/pavsefcik/ymlx-curator/main/ymlx-curator.md"
  local curated_file="$state_dir/curated-llms.md"
  if ! curl -fsSL --connect-timeout 3 --max-time 5 "$curated_url" -o "$curated_file" 2>/dev/null; then
    [[ -f "$curated_file" ]] || : > "$curated_file"
  fi

  _ymlx_write_default_config() {
    cat > "$1" <<'CFG'
# ymlx config — sourced on startup. Use "Settings" in the main menu for the
# common toggles (thinking / temp / max-tokens / system prompt); they live in
# the managed block below and ymlx rewrites it. Hand-edit anything below the
# block to add advanced flags — see `mlx_lm.chat --help` / `mlx_lm.server --help`.
# --model / --port / --host are managed by ymlx (port auto-discovery 11500-11519).

# >>> ymlx-managed quick settings — edit via "Settings" (expert mode via Advanced settings) <<<
YMLX_QUICK_THINKING="default"      # default | on | off  (default = use model's built-in)
YMLX_QUICK_TEMP=""                 # e.g. 0.7, or empty to use YMLX_CHAT_FLAGS default
YMLX_QUICK_MAX_TOKENS=""           # e.g. 2048, or empty to use YMLX_CHAT_FLAGS default
YMLX_QUICK_SYSTEM_PROMPT=""        # chat only; empty disables
YMLX_QUICK_EXPERT="off"            # off | on  (on exposes raw mlx_lm.* commands in menus)
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
  typeset -g YMLX_QUICK_EXPERT="off"
  typeset -g _YMLX_TMP_CFG=""
  typeset -g _YMLX_STTY_SAVED=""
  typeset -g _YMLX_MENU_QUIT=0
  typeset -g _YMLX_MENU_EXPERT=0
  typeset -g _YMLX_MENU_KEY=""
  typeset -ga _YMLX_MENU_LINES=()
  typeset -ga _YMLX_MENU_KINDS=()
  typeset -ga _YMLX_MENU_MODELS=()
  typeset -ga _YMLX_MENU_PORTS=()
  typeset -ga _YMLX_MENU_ACTIONS=()
  typeset -gi _YMLX_MENU_CURSOR=0
  typeset -gi _YMLX_MENU_SCROLL=0
  typeset -gi _YMLX_MENU_VIS=10
  typeset -gi _YMLX_MENU_WIDTH=80
  typeset -gi _YMLX_MENU_DRAWN=0
  typeset -gi _YMLX_MENU_NLINES=0
  typeset -gi _YMLX_MENU_NO_MODELS=0
  _YMLX_STTY_SAVED="$(stty -g 2>/dev/null)"

  _ymlx_talk_info() {
    local m="$1" p="$2"
    gum style --foreground 212 --bold "Use from another app"
    echo "  Drop-in OpenAI-compatible endpoint. Most apps that work with OpenAI"
    echo "  accept these three values — paste them where the app asks for them:"
    echo
    echo "    Base URL:   http://localhost:$p/v1"
    echo "    Model:      $m"
    echo "    API key:    not required (use any non-empty string if asked)"
    echo
    gum style --foreground 244 "  Quick test from a terminal:"
    gum style --foreground 244 "    curl -s http://localhost:$p/v1/chat/completions \\"
    gum style --foreground 244 "      -H 'Content-Type: application/json' \\"
    gum style --foreground 244 "      -d '{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
  }

  _ymlx_chat_repl() {
    local model="$1" port="$2"
    if ! command -v python3 >/dev/null 2>&1; then
      gum style --foreground 196 "python3 not found — install Xcode Command Line Tools (xcode-select --install) to use the built-in chat."
      gum input --placeholder "(press enter to continue)" >/dev/null
      return 1
    fi
    local friendly=$(_ymlx_display_name "$model")
    local url="http://127.0.0.1:$port/v1/chat/completions"
    local sysp="$YMLX_QUICK_SYSTEM_PROMPT"
    local thinking="${YMLX_QUICK_THINKING:-default}"
    local stamp=$(date +%Y-%m-%d_%H%M%S)
    local safe="${model//\//_}"
    local chat_log="$chat_dir/${stamp}_${safe}.txt"
    {
      echo "# Chat with $friendly on :$port"
      echo "# Model: $model"
      echo "# Base URL: http://localhost:$port/v1"
      echo "# Started: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "# Thinking: $thinking"
      echo
    } > "$chat_log"
    echo
    gum style --foreground 212 --bold "Chatting with $friendly on :$port"
    echo "  Base URL:   http://localhost:$port/v1"
    echo "  Model:      $model"
    echo "  Commands:   /reset clears history • /exit or Ctrl-D to leave"
    echo "  Thinking:   $thinking • tab toggle thinking"
    echo
    python3 -c "$(cat <<'PY'
import sys, json, re, signal, urllib.request, urllib.error

url, model = sys.argv[1], sys.argv[2]
sysp = sys.argv[3] if len(sys.argv) > 3 else ""
thinking = sys.argv[4] if len(sys.argv) > 4 else "default"
log_path = sys.argv[5] if len(sys.argv) > 5 else ""

strip_think = (thinking == "off")
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

flt = Filter(strip_think)
PROMPT = "\033[1;36myou>\033[0m "

def log(msg):
    if log_path:
        try:
            with open(log_path, "a") as f:
                f.write(msg + "\n")
        except OSError:
            pass

def toggle_thinking(signum, frame):
    global strip_think, thinking
    strip_think = not strip_think
    flt.on = strip_think
    thinking = "off" if strip_think else "on"
    sys.stdout.write("\r\033[2m(thinking %s)\033[0m\r\n" % thinking)
    sys.stdout.flush()

try:
    signal.signal(signal.SIGINFO, toggle_thinking)
except Exception:
    pass

try:
    while True:
        try:
            user = input(PROMPT)
        except EOFError:
            print()
            break
        s = user.strip()
        if not s:
            continue
        if s in ("/exit", "/quit", "exit", "quit"):
            break
        if s == "/reset":
            messages = list(base)
            print("\033[2m(history cleared)\033[0m")
            log("(history cleared)")
            continue
        messages.append({"role":"user","content":user})
        log("you> " + user)
        body = json.dumps({"model":model,"messages":messages,"stream":True}).encode()
        req = urllib.request.Request(url, data=body, headers={"Content-Type":"application/json"})
        print("\033[1;35massistant>\033[0m ", end="", flush=True)
        full = ""
        visible = ""
        try:
            with urllib.request.urlopen(req) as r:
                for raw in r:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                        delta = chunk["choices"][0]["delta"].get("content","")
                        if delta:
                            full += delta
                            shown = flt.feed(delta)
                            if shown:
                                visible += shown
                                print(shown, end="", flush=True)
                    except (json.JSONDecodeError, KeyError, IndexError):
                        pass
            tail = flt.flush()
            if tail:
                visible += tail
                print(tail, end="", flush=True)
        except urllib.error.URLError as e:
            print("\n\033[31m[error] %s\033[0m" % e)
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
        log("assistant> " + visible)
except KeyboardInterrupt:
    print()

PY
)" "$url" "$model" "$sysp" "$thinking" "$chat_log"
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
      _ymlx_replace_or_append YMLX_SERVER_FLAGS --system-prompt "$YMLX_QUICK_SYSTEM_PROMPT"
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
          '# >>> ymlx-managed quick settings — edit via "Settings" (expert mode via Advanced settings) <<<' \
          "YMLX_QUICK_THINKING=${(qq)YMLX_QUICK_THINKING}" \
          "YMLX_QUICK_TEMP=${(qq)YMLX_QUICK_TEMP}" \
          "YMLX_QUICK_MAX_TOKENS=${(qq)YMLX_QUICK_MAX_TOKENS}" \
          "YMLX_QUICK_SYSTEM_PROMPT=${(qq)YMLX_QUICK_SYSTEM_PROMPT}" \
          "YMLX_QUICK_EXPERT=${(qq)YMLX_QUICK_EXPERT}" \
          '# <<< end ymlx-managed >>>' \
          ''
      fi
      local in_block=0 line
      while IFS= read -r line; do
        if [[ "$line" == '# >>> ymlx-managed'* ]]; then
          in_block=1
          printf '%s\n' \
            '# >>> ymlx-managed quick settings — edit via "Settings" (expert mode via Advanced settings) <<<' \
            "YMLX_QUICK_THINKING=${(qq)YMLX_QUICK_THINKING}" \
            "YMLX_QUICK_TEMP=${(qq)YMLX_QUICK_TEMP}" \
            "YMLX_QUICK_MAX_TOKENS=${(qq)YMLX_QUICK_MAX_TOKENS}" \
            "YMLX_QUICK_SYSTEM_PROMPT=${(qq)YMLX_QUICK_SYSTEM_PROMPT}" \
            "YMLX_QUICK_EXPERT=${(qq)YMLX_QUICK_EXPERT}" \
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
      local cur_expert="${YMLX_QUICK_EXPERT:-off}"
      local -a settings_entries=(
        "Thinking:       $cur_t"
        "Temperature:    $cur_temp"
        "Max tokens:     $cur_max"
        "System prompt:  $cur_sys"
        "───────────────────────"
        "Advanced settings"
        "Open Local LLM Folder"
      )
      if [[ "$cur_expert" == "on" ]]; then
        settings_entries+=( "Connect agentic CLI" "Turn off expert mode" )
      fi
      settings_entries+=("Back to Top")
      local choice=$(printf "%s\n" "${settings_entries[@]}" | gum choose --header $'\nSettings (current values shown):' --height 14)
      [[ -z "$choice" || "$choice" == "Back to Top" ]] && return
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
        "Connect agentic CLI"*)
          echo
          gum style --foreground 212 --bold "ymlx — one URL for every agentic CLI"
          echo "  Base URL:  http://127.0.0.1:11500/v1/  (ymlx pins the active model to :11500)"
          echo "  Auth:      none required — pass any string if your client demands one"
          echo
          gum style --foreground 244 "  # crush (~/.config/crush/crush.json):"
          gum style --foreground 244 "  #   providers.ymlx.base_url = http://localhost:11500/v1/"
          gum style --foreground 244 "  #   providers.ymlx.type     = openai-compat"
          gum style --foreground 244 "  #   crush requires models[] declared explicitly."
          gum style --foreground 244 "  # aider:        aider --openai-api-base http://localhost:11500/v1 --openai-api-key dummy"
          gum style --foreground 244 "  # OpenAI SDK:   OpenAI(base_url='http://localhost:11500/v1', api_key='-')"
          echo
          if [[ -f ~/.config/crush/crush.json ]] && gum confirm "Sync ~/.config/crush/crush.json with installed models?"; then
            _ymlx_sync_crush
          fi
          gum input --placeholder "(press enter to continue)" >/dev/null
          ;;
        "Turn off expert mode")
          YMLX_QUICK_EXPERT="off"
          ;;
        "Open Local LLM Folder")
          open "$hub_dir"
          ;;
      esac
      _ymlx_write_managed_block "$config_file"
      _ymlx_reload_config
    done
  }

  [[ -f "$config_file" ]] || _ymlx_write_default_config "$config_file"
  _ymlx_reload_config

  # Discover currently running mlx_lm.server processes on our port range by
  # asking the OS, not a state file. Emits TSV lines: pid<TAB>port<TAB>model.
  # The model id is parsed from the process's --model arg.
  _ymlx_running() {
    local p lpid cmd m
    for p in {11500..11519}; do
      lpid=$(lsof -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null | head -n1)
      [[ -z "$lpid" ]] && continue
      cmd=$(ps -o command= -p "$lpid" 2>/dev/null)
      [[ "$cmd" != *"--model "* ]] && continue
      m="${cmd#*--model }"
      m="${m%% *}"
      [[ -z "$m" ]] && continue
      printf '%s\t%s\t%s\n' "$lpid" "$p" "$m"
    done
  }

  # Remove a pid from the session-tracked list (called after we kill it, so
  # the EXIT trap doesn't redundantly target a dead pid).
  _ymlx_drop() {
    local target="$1" i
    local -a keep=()
    for i in "${_YMLX_SESSION_PIDS[@]}"; do
      [[ "$i" == "$target" ]] && continue
      keep+=( "$i" )
    done
    _YMLX_SESSION_PIDS=( "${keep[@]}" )
  }

  _ymlx_stop_all() {
    local pid port model
    while IFS=$'\t' read -r pid port model; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && echo "Stopped: $model (:$port)"
    done < <(_ymlx_running)
    _YMLX_SESSION_PIDS=()
  }

  # Update ~/.config/crush/crush.json's `ymlx` provider models[] from the
  # installed hub. Crush requires every usable model to be listed explicitly —
  # it does not auto-discover from /v1/models. Preserves everything else in
  # crush.json.
  _ymlx_sync_crush() {
    local cf=~/.config/crush/crush.json
    [[ -f "$cf" ]] || { echo "crush.json not found at $cf — nothing to sync."; return 1; }
    command -v python3 >/dev/null 2>&1 || { echo "python3 required for sync."; return 1; }
    local models_csv=""
    local m
    for m in $(ls "$hub_dir" 2>/dev/null | grep '^models--' | sed 's/models--//' | sed 's/--/\//g'); do
      models_csv+="$m"$'\n'
    done
    YMLX_CRUSH_MODELS="$models_csv" python3 - "$cf" <<'PY'
import json, os, sys
cf = sys.argv[1]
with open(cf) as f:
    cfg = json.load(f)
ids = [x for x in os.environ.get("YMLX_CRUSH_MODELS","").splitlines() if x.strip()]
def short(mid):
    base = mid.split("/", 1)[-1]
    return base.replace("-MLX", "").replace("-4bit", "").replace("--", "-").strip("-")
prov = cfg.setdefault("providers", {}).setdefault("ymlx", {})
prov["name"] = prov.get("name", "ymlx (local MLX)")
prov["base_url"] = "http://localhost:11500/v1/"
prov["type"] = "openai-compat"
prov.setdefault("api_key", "dummy")
prov["models"] = [
    {"id": mid, "name": short(mid), "context_window": 32768, "default_max_tokens": 8192}
    for mid in ids
]
with open(cf, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"Synced {len(ids)} model(s) into {cf}")
PY
  }

  _ymlx_size_load "$size_cache_file"

  _ymlx_launch() {
    local model="$1"
    local port=$(_ymlx_find_port)
    if [[ -z "$port" ]]; then
      if [[ "$YMLX_QUICK_EXPERT" == "on" ]]; then
        echo "No free port in 11500-11519."
      else
        echo "Port :11500 is busy. Stop the running model (^s in the menu) first."
      fi
      return 1
    fi
    local safe="${model//\//_}"
    local log="$log_dir/${safe}-${port}.log"
    mlx_lm.server --model "$model" --port "$port" "${YMLX_SERVER_FLAGS[@]}" >"$log" 2>&1 &
    local pid=$!
    _YMLX_SESSION_PIDS+=( "$pid" )
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
      print -r -- "$model" > "$last_model_file"
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

  _ymlx_download_menu() {
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
    local models m
    models=$(ls "$hub_dir" 2>/dev/null | grep '^models--' | sed 's/models--//' | sed 's/--/\//g')
    for m in ${(f)models}; do installed[$m]=1; done

    local dim_on=$'\e[2m' dim_off=$'\e[0m'
    typeset -A tier_header
    local -a entry_tiers=() entry_sources=() entry_tags=() entry_dim=()
    local source tags block_line=0 line current_tier=0 header num friendly max_w=0 fw

    if [[ -r "$curated_file" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
          block_line=0
          continue
        fi
        if [[ "$line" == *"GB RAM"* ]]; then
          header="$line"
          num="${header//[^0-9]/}"
          tier_header[$num]="$header"
          current_tier=$num
          block_line=0
          continue
        fi
        (( block_line++ ))
        if (( block_line == 1 )); then
          source="$line"
        elif (( block_line == 2 )); then
          tags="$line"
          if [[ -z "${installed[$source]}" ]]; then
            if (( current_tier == tier_active || current_tier == tier_dim )); then
              friendly="${source##*/}"
              entry_tiers+=( "$current_tier" )
              entry_sources+=( "$source" )
              entry_tags+=( "$tags" )
              entry_dim+=( $(( current_tier == tier_dim )) )
              fw=${#friendly}
              (( fw > max_w )) && max_w=$fw
            fi
          fi
          block_line=0
        fi
      done < "$curated_file"
    fi
    (( max_w < 12 )) && max_w=12

    typeset -A curated
    local entries=() curated_count=0
    local prev_tier=-1 hdr_line="" display
    for (( i=1; i<=${#entry_sources[@]}; i++ )); do
      if (( entry_tiers[$i] != prev_tier )); then
        if (( entry_tiers[$i] == tier_dim )); then
          hdr_line="${dim_on}  # ${tier_header[${entry_tiers[$i]}]}${dim_off}"
        else
          hdr_line="  # ${tier_header[${entry_tiers[$i]}]}"
        fi
        entries+=("$hdr_line")
        prev_tier=${entry_tiers[$i]}
      fi
      friendly="${entry_sources[$i]##*/}"
      if (( entry_dim[$i] )); then
        display="${dim_on}$(printf '    %-*s  // %s' "$max_w" "$friendly" "${entry_tags[$i]}")${dim_off}"
      else
        display=$(printf '    %-*s  // %s' "$max_w" "$friendly" "${entry_tags[$i]}")
      fi
      entries+=("$display")
      curated[$display]="${entry_sources[$i]}"
      (( curated_count++ ))
    done

    if (( curated_count == 0 )); then
      entries+=("    No more hand picked models available")
    fi
    entries+=("    ──────────────────────────────────────────" "    Custom            (paste HuggingFace ID)…" "    Back to Top")

    local pick=$(printf "%s\n" "${entries[@]}" | gum choose --header $'\nDownload new model:' --height 30)
    [[ -z "$pick" ]] && return

    if [[ "$pick" == *"Back to Top"* || "$pick" == *──* || "$pick" == *"No more hand picked models available"* ]]; then
      return
    fi

    local model
    if [[ "$pick" == *"Custom"* ]]; then
      model=$(gum input --placeholder "e.g. mlx-community/Ministral-3-3B-Instruct-2512-4bit" --prompt "Model: ")
    else
      model="${curated[$pick]}"
    fi
    [[ -z "$model" ]] && return
    echo
    gum style --foreground 212 --bold "Downloading $model"
    echo "(progress will stream below — Ctrl-C to abort)"
    echo
    if uvx --from mlx-lm python3 -c "from mlx_lm import load; load('$model')"; then
      echo
      gum style --foreground 42 "✓ Downloaded: $model"
      echo
      if gum confirm "Start $model now?"; then
        _ymlx_launch "$model"
        _preselect_model="$model"
      fi
    else
      echo
      gum style --foreground 196 "✗ Download failed or cancelled."
      gum input --placeholder "(press enter to continue)" >/dev/null
    fi
  }

  _ymlx_chat_history_menu() {
    while true; do
      local -a hist_entries=()
      typeset -A hist_files
      local f friendly started label
      local -a chat_files=( "$chat_dir"/*.txt(N) )
      local -a sorted_files=( ${(On)chat_files} )
      for f in "${sorted_files[@]}"; do
        friendly=$(sed -n 's/^# Chat with //p' "$f" | head -n1 | sed 's/ on :[0-9]*$//')
        started=$(sed -n 's/^# Started: //p' "$f" | head -n1)
        [[ -z "$friendly" ]] && friendly="${f:t}"
        [[ -z "$started" ]] && started="${f:t:r}"
        label="$friendly  —  $started"
        hist_entries+=("$label")
        hist_files[$label]="$f"
      done
      if (( ${#hist_entries[@]} == 0 )); then
        hist_entries+=("No chats yet.")
      fi
      hist_entries+=("──────────────" "Clear history" "Back to Top")
      local pick=$(printf "%s\n" "${hist_entries[@]}" | gum choose --header $'\nChat History:' --height 20)
      [[ -z "$pick" ]] && return
      if [[ "$pick" == "Back to Top" || "$pick" == *──* || "$pick" == "No chats yet." ]]; then
        return
      fi
      if [[ "$pick" == "Clear history" ]]; then
        if gum confirm "Delete all chat history?"; then
          rm -f "$chat_dir"/*.txt(N)
          echo "Chat history cleared."
        fi
        continue
      fi
      local file="${hist_files[$pick]}"
      [[ -n "$file" && -f "$file" ]] && gum pager < "$file"
    done
  }

  _ymlx_main_build() {
    local pid port model models m friendly rport think_suffix display first_running_idx=-1
    _YMLX_MENU_LINES=()
    _YMLX_MENU_KINDS=()
    _YMLX_MENU_MODELS=()
    _YMLX_MENU_PORTS=()
    _YMLX_MENU_ACTIONS=()
    typeset -A running_for_model
    while IFS=$'\t' read -r pid port model; do
      [[ -z "$pid" ]] && continue
      running_for_model[$model]="$pid"$'\t'"$port"
    done < <(_ymlx_running)

    _YMLX_MENU_NO_MODELS=0
    models=$(ls "$hub_dir" 2>/dev/null | grep '^models--' | sed 's/models--//' | sed 's/--/\//g')
    if [[ -z "$models" ]]; then
      _YMLX_MENU_NO_MODELS=1
      _YMLX_MENU_LINES=( "Download your first model" "Chat History" "Settings" "Quit" )
      _YMLX_MENU_KINDS=( "action" "action" "action" "action" )
      _YMLX_MENU_MODELS=( "" "" "" "" )
      _YMLX_MENU_PORTS=( "" "" "" "" )
      _YMLX_MENU_ACTIONS=( "download" "history" "settings" "quit" )
    else
      for m in ${(f)models}; do
        friendly=$(_ymlx_display_name "$m")
        if [[ -n "${running_for_model[$m]}" ]]; then
          rport="${running_for_model[$m]##*	}"
          think_suffix=""
          [[ "$YMLX_QUICK_THINKING" == "on" ]] && think_suffix=" thinking"
          [[ "$YMLX_QUICK_THINKING" == "off" ]] && think_suffix=" thinking off"
          display="● $friendly$think_suffix"
          _YMLX_MENU_LINES+=( "$display" )
          _YMLX_MENU_KINDS+=( "model" )
          _YMLX_MENU_MODELS+=( "$m" )
          _YMLX_MENU_PORTS+=( "$rport" )
          _YMLX_MENU_ACTIONS+=( "" )
          (( first_running_idx < 0 )) && first_running_idx=$(( ${#_YMLX_MENU_LINES[@]} - 1 ))
        else
          _YMLX_MENU_LINES+=( "$friendly" )
          _YMLX_MENU_KINDS+=( "model" )
          _YMLX_MENU_MODELS+=( "$m" )
          _YMLX_MENU_PORTS+=( "" )
          _YMLX_MENU_ACTIONS+=( "" )
        fi
      done
      _YMLX_MENU_LINES+=( "──────────────────────" )
      _YMLX_MENU_KINDS+=( "separator" )
      _YMLX_MENU_MODELS+=( "" ); _YMLX_MENU_PORTS+=( "" ); _YMLX_MENU_ACTIONS+=( "" )
      _YMLX_MENU_LINES+=( "Chat History" "Settings" "Download" "Quit" )
      _YMLX_MENU_KINDS+=( "action" "action" "action" "action" )
      _YMLX_MENU_MODELS+=( "" "" "" "" ); _YMLX_MENU_PORTS+=( "" "" "" "" )
      _YMLX_MENU_ACTIONS+=( "history" "settings" "download" "quit" )
    fi
    _YMLX_MENU_SCROLL=0
    if (( first_running_idx >= 0 )); then
      _YMLX_MENU_CURSOR=$first_running_idx
    else
      _YMLX_MENU_CURSOR=0
    fi
    _ymlx_main_scroll_cursor
  }

  _ymlx_main_render() {
    local i idx line prefix kind n end footer has_running=0
    if (( _YMLX_MENU_DRAWN )); then
      print -n -- "\033[${_YMLX_MENU_NLINES}A\033[J"
    fi
    local -a out=()
    if (( _YMLX_MENU_NO_MODELS )); then
      out+=( $'\e[1;35mNo models installed yet.\e[0m' )
    else
      out+=( $'\e[1;35mSelect model:\e[0m' )
    fi
    n=${#_YMLX_MENU_LINES[@]}
    end=$(( _YMLX_MENU_SCROLL + _YMLX_MENU_VIS ))
    (( end > n )) && end=n
    for (( i=_YMLX_MENU_SCROLL; i<end; i++ )); do
      idx=$i
      line="${_YMLX_MENU_LINES[$((idx+1))]}"
      kind="${_YMLX_MENU_KINDS[$((idx+1))]}"
      prefix="  "
      if (( idx == _YMLX_MENU_CURSOR )); then
        prefix="> "
      fi
      if [[ "$kind" == "separator" ]]; then
        out+=( $'\e[2m'"$line"$'\e[0m' )
      elif (( idx == _YMLX_MENU_CURSOR )); then
        out+=( $'\e[1;36m'"$prefix$line"$'\e[0m' )
      else
        out+=( "$prefix$line" )
      fi
    done
    for (( i=1; i<=${#_YMLX_MENU_PORTS[@]}; i++ )); do
      [[ -n "${_YMLX_MENU_PORTS[$i]}" ]] && { has_running=1; break; }
    done
    local footer_text
    if (( has_running )); then
      footer_text="↓↑ navigate • enter submit/start • tab toggle thinking • ^s stop server • ^d delete • esc back • ^q quit"
    else
      footer_text="↓↑ navigate • enter submit/start • ^d delete • esc back • ^q quit"
    fi
    footer_text="${footer_text:0:$(( _YMLX_MENU_WIDTH - 1 ))}"
    out+=( $'\e[2m'"$footer_text"$'\e[0m' )
    _YMLX_MENU_NLINES=0
    for line in "${out[@]}"; do
      print -n -- "$line\033[K\n"
      (( _YMLX_MENU_NLINES++ ))
    done
    _YMLX_MENU_DRAWN=1
  }

  _ymlx_main_clear() {
    if (( _YMLX_MENU_DRAWN )); then
      print -n -- "\033[${_YMLX_MENU_NLINES}A\033[J"
      _YMLX_MENU_DRAWN=0
    fi
  }

  _ymlx_main_full_render() {
    print -n -- "\033[2J\033[H"
    _YMLX_MENU_DRAWN=0
    echo
    gum style --foreground 212 --bold "▌▌ YMLX"
    gum style --foreground 244 "Runs an MLX model behind an OpenAI-compatible REST API at localhost:11500"
    _ymlx_main_render
  }

  _ymlx_main_scroll_cursor() {
    local n=${#_YMLX_MENU_LINES[@]} max_scroll=$(( n - _YMLX_MENU_VIS ))
    (( max_scroll < 0 )) && max_scroll=0
    (( _YMLX_MENU_SCROLL > max_scroll )) && _YMLX_MENU_SCROLL=$max_scroll
    if (( _YMLX_MENU_CURSOR < _YMLX_MENU_SCROLL )); then
      _YMLX_MENU_SCROLL=$_YMLX_MENU_CURSOR
    elif (( _YMLX_MENU_CURSOR >= _YMLX_MENU_SCROLL + _YMLX_MENU_VIS )); then
      _YMLX_MENU_SCROLL=$(( _YMLX_MENU_CURSOR - _YMLX_MENU_VIS + 1 ))
    fi
    (( _YMLX_MENU_SCROLL < 0 )) && _YMLX_MENU_SCROLL=0
  }

  _ymlx_main_move() {
    local delta="$1" n=${#_YMLX_MENU_LINES[@]} new=$_YMLX_MENU_CURSOR
    while true; do
      new=$(( new + delta ))
      if (( new < 0 )); then return; fi
      if (( new >= n )); then return; fi
      if [[ "${_YMLX_MENU_KINDS[$((new+1))]}" != "separator" ]]; then
        _YMLX_MENU_CURSOR=$new
        break
      fi
    done
    _ymlx_main_scroll_cursor
  }

  _ymlx_main_rebuild_preserving() {
    local kind="${_YMLX_MENU_KINDS[$((_YMLX_MENU_CURSOR+1))]}"
    local model="${_YMLX_MENU_MODELS[$((_YMLX_MENU_CURSOR+1))]}"
    local action="${_YMLX_MENU_ACTIONS[$((_YMLX_MENU_CURSOR+1))]}"
    _ymlx_main_build
    local i
    for (( i=1; i<=${#_YMLX_MENU_KINDS[@]}; i++ )); do
      if [[ "${_YMLX_MENU_KINDS[$i]}" == "$kind" && "${_YMLX_MENU_MODELS[$i]}" == "$model" && "${_YMLX_MENU_ACTIONS[$i]}" == "$action" ]]; then
        _YMLX_MENU_CURSOR=$(( i - 1 ))
        break
      fi
    done
    _ymlx_main_scroll_cursor
    _ymlx_main_render
  }

  _ymlx_main_rebuild_full() {
    local kind="${_YMLX_MENU_KINDS[$((_YMLX_MENU_CURSOR+1))]}"
    local model="${_YMLX_MENU_MODELS[$((_YMLX_MENU_CURSOR+1))]}"
    local action="${_YMLX_MENU_ACTIONS[$((_YMLX_MENU_CURSOR+1))]}"
    _ymlx_main_build
    local i
    for (( i=1; i<=${#_YMLX_MENU_KINDS[@]}; i++ )); do
      if [[ "${_YMLX_MENU_KINDS[$i]}" == "$kind" && "${_YMLX_MENU_MODELS[$i]}" == "$model" && "${_YMLX_MENU_ACTIONS[$i]}" == "$action" ]]; then
        _YMLX_MENU_CURSOR=$(( i - 1 ))
        break
      fi
    done
    _ymlx_main_scroll_cursor
    _ymlx_main_full_render
  }

  _ymlx_main_toggle_thinking() {
    local kind="${_YMLX_MENU_KINDS[$((_YMLX_MENU_CURSOR+1))]}"
    [[ "$kind" != "model" ]] && return
    if [[ "$YMLX_QUICK_THINKING" == "on" ]]; then
      YMLX_QUICK_THINKING="off"
    else
      YMLX_QUICK_THINKING="on"
    fi
    _ymlx_write_managed_block "$config_file"
    _ymlx_reload_config
    _ymlx_main_rebuild_preserving
  }

  _ymlx_main_stop() {
    local idx=$(( _YMLX_MENU_CURSOR + 1 ))
    local kind="${_YMLX_MENU_KINDS[$idx]}"
    local port="${_YMLX_MENU_PORTS[$idx]}"
    local model="${_YMLX_MENU_MODELS[$idx]}"
    if [[ "$kind" != "model" || -z "$port" ]]; then
      return
    fi
    _ymlx_main_clear
    local pid _p _pt _m
    while IFS=$'\t' read -r _p _pt _m; do
      if [[ "$_m" == "$model" && "$_pt" == "$port" ]]; then
        pid="$_p"
        break
      fi
    done < <(_ymlx_running)
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null && echo "Stopped: $model on :$port"
      _ymlx_drop "$pid"
    else
      echo "Server for $model was already gone."
    fi
    _ymlx_main_rebuild_full
  }

  _ymlx_main_delete() {
    local idx=$(( _YMLX_MENU_CURSOR + 1 ))
    local kind="${_YMLX_MENU_KINDS[$idx]}"
    local model="${_YMLX_MENU_MODELS[$idx]}"
    local port="${_YMLX_MENU_PORTS[$idx]}"
    if [[ "$kind" != "model" ]]; then
      return
    fi
    _ymlx_main_clear
    local folder="$hub_dir/models--${model//\//--}"
    if [[ ! -d "$folder" ]]; then
      echo "Folder not found: $folder"
    else
      local warn=""
      [[ -n "$port" ]] && warn=" (running server will be stopped first)"
      if gum confirm "Remove $model from $hub_dir?$warn"; then
        if [[ -n "$port" ]]; then
          local pid _p _pt _m
          while IFS=$'\t' read -r _p _pt _m; do
            if [[ "$_m" == "$model" && "$_pt" == "$port" ]]; then
              pid="$_p"; break
            fi
          done < <(_ymlx_running)
          [[ -n "$pid" ]] && kill "$pid" 2>/dev/null && _ymlx_drop "$pid"
        fi
        rm -rf "$folder"
        unset "_ymlx_size_mt[$model]" "_ymlx_size_kb[$model]"
        _ymlx_size_save "$size_cache_file"
        echo "Removed: $model"
      fi
    fi
    _ymlx_main_rebuild_full
  }

  _ymlx_main_quit() {
    _ymlx_main_clear
    if gum confirm "Quit ymlx and stop all running models?"; then
      _ymlx_stop_all >/dev/null 2>&1
      _YMLX_MENU_QUIT=1
      return 0
    fi
    _ymlx_main_full_render
    return 1
  }

  _ymlx_main_activate() {
    local idx=$(( _YMLX_MENU_CURSOR + 1 ))
    local kind="${_YMLX_MENU_KINDS[$idx]}"
    local model="${_YMLX_MENU_MODELS[$idx]}"
    local port="${_YMLX_MENU_PORTS[$idx]}"
    local action="${_YMLX_MENU_ACTIONS[$idx]}"
    [[ "$kind" == "separator" ]] && return
    _ymlx_main_clear
    if [[ "$kind" == "model" ]]; then
      if [[ -n "$port" ]]; then
        _ymlx_chat_repl "$model" "$port"
      else
        local _occ_pid="" _occ_model="" _p _pt _m
        while IFS=$'\t' read -r _p _pt _m; do
          if [[ "$_pt" == "11500" ]]; then
            _occ_pid="$_p"; _occ_model="$_m"
            break
          fi
        done < <(_ymlx_running)
        if [[ -n "$_occ_pid" ]]; then
          echo "Port :11500 is busy running $_occ_model."
          echo "Stop it with ^s, then try again."
          gum input --placeholder "(press enter to continue)" >/dev/null
        else
          _ymlx_launch "$model"
          _preselect_model="$model"
        fi
      fi
    else
      case "$action" in
        download) _ymlx_download_menu ;;
        history) _ymlx_chat_history_menu ;;
        settings) _ymlx_settings_menu ;;
        quit) _ymlx_main_quit ;;
      esac
    fi
    (( _YMLX_MENU_QUIT )) && return
    if [[ "$YMLX_QUICK_EXPERT" == "on" ]]; then
      _YMLX_MENU_EXPERT=1
      return
    fi
    _ymlx_main_rebuild_full
  }

  _ymlx_main_read_key() {
    local k1 k2 k3
    read -s -k1 k1
    local st=$?
    if (( st != 0 )); then
      _YMLX_MENU_KEY=""
      return
    fi
    if [[ "$k1" == $'\e' ]]; then
      if read -s -k1 -t 0.05 k2; then
        if read -s -k1 -t 0.05 k3; then
          _YMLX_MENU_KEY=$'\e'"$k2$k3"
        else
          _YMLX_MENU_KEY=$'\e'"$k2"
        fi
      else
        _YMLX_MENU_KEY=$'\e'
      fi
    else
      _YMLX_MENU_KEY="$k1"
    fi
  }

  _ymlx_main_standard() {
    local _up1=$'\e'[A _up2=$'\e'OA _down1=$'\e'[B _down2=$'\e'OB
    local _term_lines=${LINES:-24}
    (( _term_lines < 8 )) && _term_lines=24
    _YMLX_MENU_VIS=$(( _term_lines - 6 ))
    (( _YMLX_MENU_VIS < 1 )) && _YMLX_MENU_VIS=1
    _YMLX_MENU_WIDTH=${COLUMNS:-80}
    (( _YMLX_MENU_WIDTH < 40 )) && _YMLX_MENU_WIDTH=80
    (( _YMLX_MENU_VIS < 1 )) && _YMLX_MENU_VIS=1
    _YMLX_MENU_QUIT=0
    _YMLX_MENU_EXPERT=0
    _YMLX_MENU_DRAWN=0
    _YMLX_MENU_NLINES=0
    stty -ixon 2>/dev/null
    _ymlx_main_build
    _ymlx_main_render
    while true; do
      _ymlx_main_read_key
      if [[ -z "$_YMLX_MENU_KEY" ]]; then
        _ymlx_stop_all >/dev/null 2>&1
        _YMLX_MENU_QUIT=1
        break
      fi
      local key="$_YMLX_MENU_KEY"
      if [[ "$key" == "$_up1" || "$key" == "$_up2" ]]; then
        _ymlx_main_move -1
        _ymlx_main_render
      elif [[ "$key" == "$_down1" || "$key" == "$_down2" ]]; then
        _ymlx_main_move 1
        _ymlx_main_render
      elif [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
        _ymlx_main_activate
        (( _YMLX_MENU_QUIT )) && break
        (( _YMLX_MENU_EXPERT )) && return 0
      elif [[ "$key" == $'\t' ]]; then
        _ymlx_main_toggle_thinking
      elif [[ "$key" == $'\x13' ]]; then
        _ymlx_main_stop
      elif [[ "$key" == $'\x04' ]]; then
        _ymlx_main_delete
      elif [[ "$key" == $'\x11' || "$key" == $'\e' ]]; then
        if _ymlx_main_quit; then
          break
        fi
      fi
    done
  }

  local models selected
  local _preselect_model=""
  [[ -f "$last_model_file" ]] && _preselect_model="$(<"$last_model_file")"

  clear
  echo
  gum style --foreground 212 --bold "▌▌ YMLX"
  gum style --foreground 244 "Runs an MLX model behind an OpenAI-compatible REST API at localhost:11500"

  while true; do
    if [[ "$YMLX_QUICK_EXPERT" != "on" ]]; then
      _ymlx_main_standard
      (( _YMLX_MENU_QUIT )) && return
      continue
    fi

    models=$(ls "$hub_dir" 2>/dev/null | grep '^models--' | sed 's/models--//' | sed 's/--/\//g')

    local main_entries=() pid="" port="" model="" display="" rss_h="" _preselect_display=""
    typeset -A active_pid active_port active_model installed_model running_for_model
    active_pid=() active_port=() active_model=() installed_model=() running_for_model=()
    while IFS=$'\t' read -r pid port model; do
      [[ -z "$pid" ]] && continue
      running_for_model[$model]="$pid"$'\t'"$port"
    done < <(_ymlx_running)

    local total_kb=0 m="" m_kb=0
    typeset -A model_kb
    if [[ -n "$models" ]]; then
      for m in ${(f)models}; do
        m_kb=$(_ymlx_disk_kb "$m" "$hub_dir" "$size_cache_file")
        model_kb[$m]=$m_kb
        (( total_kb += m_kb ))
      done
      local _label=""
      for m in ${(f)models}; do
        _label=$(_ymlx_friendly_name "$m")
        if [[ -n "${running_for_model[$m]}" ]]; then
          local _rp="${running_for_model[$m]%%	*}" _rport="${running_for_model[$m]##*	}"
          rss_h=$(_ymlx_rss_h "$_rp")
          display="● $_label  :$_rport  $rss_h  ($(_ymlx_format_size ${model_kb[$m]}))"
          active_pid[$display]="$_rp"
          active_port[$display]="$_rport"
          active_model[$display]="$m"
        else
          display="$_label  ($(_ymlx_format_size ${model_kb[$m]}))"
          installed_model[$display]="$m"
        fi
        main_entries+=("$display")
        [[ -n "$_preselect_model" && "$m" == "$_preselect_model" ]] && _preselect_display="$display"
      done
    fi
    local _no_models=0
    if (( ${#main_entries[@]} == 0 )); then
      _no_models=1
      main_entries=( "Download your first model" "Settings" "Quit" )
    else
      main_entries+=("──────────────────────" "Settings" "Download")
      [[ "$YMLX_DEBUG" == true ]] && main_entries+=("Debug: ports 11500-11519")
      [[ "$YMLX_QUICK_EXPERT" == "on" ]] && main_entries+=("Stop All")
      main_entries+=("Quit")
    fi

    local _dim_on=$'\e[2m' _dim_off=$'\e[0m'
    local _hdr=$'\n'
    if (( _no_models )); then
      _hdr+="No models installed yet."
    else
      _hdr+="Select model:"
      if (( total_kb > 0 )); then
        _hdr+=$'\n'"${_dim_on}$(_ymlx_format_size $total_kb) installed total${_dim_off}"
      fi
    fi
    local -a _gum_args=( --header "$_hdr" --height 30 )
    [[ -n "$_preselect_display" ]] && _gum_args+=( --selected "$_preselect_display" )
    selected=$(printf "%s\n" "${main_entries[@]}" | gum choose "${_gum_args[@]}")
    _preselect_model=""
    [[ -z "$selected" ]] && continue

    if [[ "$selected" == *───* ]]; then
      continue
    elif [[ "$selected" == "Download your first model" ]]; then
      selected="Download"
    fi
    if [[ "$selected" == "Stop All" ]]; then
      _ymlx_stop_all
      continue
    elif [[ "$selected" == "Quit" ]]; then
      gum confirm "Quit ymlx and stop all running models?" || continue
      _ymlx_stop_all >/dev/null 2>&1
      return
    elif [[ -n "${active_pid[$selected]}" ]]; then
      local a_pid="${active_pid[$selected]}"
      local a_port="${active_port[$selected]}"
      local a_model="${active_model[$selected]}"
      local _stay_in_submenu=1
      while (( _stay_in_submenu )); do
      _stay_in_submenu=0
      local action
      if [[ "$YMLX_QUICK_EXPERT" == "on" ]]; then
        action=$(printf "Chat via mlx_lm.server\nServer details\nStop server\nRestart\nAdjust settings\nCopy name\nTail logs\nBack" | gum choose --header $'\n'"$a_model running on :$a_port (pid $a_pid)" --height 12)
      else
        action=$(printf "Chat\nUse from another app\nAdjust settings\nStop\nBack" | gum choose --header $'\n'"$a_model running on :$a_port (pid $a_pid)" --height 10)
      fi
      [[ -z "$action" ]] && break
      case "$action" in
        "Adjust settings")
          local tmp_cfg=$(mktemp -t ymlx_cfg.XXXXXX)
          _YMLX_TMP_CFG="$tmp_cfg"
          cp "$config_file" "$tmp_cfg"
          local _bk_t="$YMLX_QUICK_THINKING" _bk_temp="$YMLX_QUICK_TEMP"
          local _bk_max="$YMLX_QUICK_MAX_TOKENS" _bk_sys="$YMLX_QUICK_SYSTEM_PROMPT"
          local -a _bk_chat=( "${YMLX_CHAT_FLAGS[@]}" )
          local -a _bk_srv=( "${YMLX_SERVER_FLAGS[@]}" )
          local action_done=""
          while [[ -z "$action_done" ]]; do
            local cur_t="${YMLX_QUICK_THINKING:-default}"
            local cur_temp="${YMLX_QUICK_TEMP:-default}"
            local cur_max="${YMLX_QUICK_MAX_TOKENS:-default}"
            local cur_sys
            if [[ -n "$YMLX_QUICK_SYSTEM_PROMPT" ]]; then
              cur_sys="(${#YMLX_QUICK_SYSTEM_PROMPT} chars)"
            else
              cur_sys="(none)"
            fi
            local -a _adj_entries=(
              "Thinking:       $cur_t"
              "Temperature:    $cur_temp"
              "Max tokens:     $cur_max"
              "System prompt:  $cur_sys"
              "──────────────"
            )
            [[ "$YMLX_QUICK_EXPERT" == "on" ]] && _adj_entries+=( "Advanced settings" )
            _adj_entries+=( "Discard changes" "Restart" )
            local sub=$(printf "%s\n" "${_adj_entries[@]}" | gum choose --header $'\nAdjust settings for '"$a_model"$' (this server only)' --height 14)
            case "$sub" in
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
                local sub2=$(printf "Edit\nClear\nCancel" | gum choose --header "System prompt")
                case "$sub2" in
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
                eval "$ed \"\$tmp_cfg\""
                source "$tmp_cfg"
                continue
                ;;
              "Restart")
                action_done="restart"
                break
                ;;
              *)
                action_done="discard"
                break
                ;;
            esac
            _ymlx_write_managed_block "$tmp_cfg"
            source "$tmp_cfg"
          done
          if [[ "$action_done" == "restart" ]]; then
            _ymlx_apply_quick
            kill "$a_pid" 2>/dev/null
            _ymlx_drop "$a_pid"
            _ymlx_launch "$a_model"
          fi
          YMLX_QUICK_THINKING="$_bk_t"
          YMLX_QUICK_TEMP="$_bk_temp"
          YMLX_QUICK_MAX_TOKENS="$_bk_max"
          YMLX_QUICK_SYSTEM_PROMPT="$_bk_sys"
          YMLX_CHAT_FLAGS=( "${_bk_chat[@]}" )
          YMLX_SERVER_FLAGS=( "${_bk_srv[@]}" )
          _ymlx_reload_config
          rm -f "$tmp_cfg"
          _YMLX_TMP_CFG=""
          if [[ "$action_done" == "restart" ]]; then
            local _np="" _npt="" _p _pt _m
            while IFS=$'\t' read -r _p _pt _m; do
              [[ "$_m" == "$a_model" ]] && { _np="$_p"; _npt="$_pt"; break; }
            done < <(_ymlx_running)
            if [[ -n "$_np" ]]; then
              a_pid="$_np"; a_port="$_npt"
              _stay_in_submenu=1
            fi
          else
            _stay_in_submenu=1
          fi
          ;;
        "Chat"|"Chat via mlx_lm.server")
          _ymlx_chat_repl "$a_model" "$a_port"
          ;;
        "Server details"|"Use from another app")
          _ymlx_talk_info "$a_model" "$a_port"
          gum input --placeholder "(press enter to continue)" >/dev/null
          _stay_in_submenu=1
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
          _preselect_model="$a_model"
          ;;
        "Stop"|"Stop server")
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
      done
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
    elif [[ "$selected" == "Download" ]]; then
      _ymlx_download_menu
      continue
    fi

    [[ -n "${installed_model[$selected]}" ]] && selected="${installed_model[$selected]}"

    local action
    local _occupant_pid="" _occupant_model="" _p _pt _m
    while IFS=$'\t' read -r _p _pt _m; do
      if [[ "$_pt" == "11500" ]]; then
        _occupant_pid="$_p"; _occupant_model="$_m"
        break
      fi
    done < <(_ymlx_running)

    # Lowest free port in [11501, 11519] — for "Run new" in expert mode.
    local _next_extra_port=""
    local _try=11501
    while (( _try <= 11519 )); do
      if _ymlx_port_free "$_try"; then _next_extra_port="$_try"; break; fi
      (( _try++ ))
    done

    if [[ "$YMLX_QUICK_EXPERT" == "on" ]]; then
      local -a _xa=()
      if [[ -z "$_occupant_pid" ]]; then
        _xa+=( "Start mlx_lm.server on port 11500" )
      elif [[ "$_occupant_model" != "$selected" ]]; then
        _xa+=( "Swap mlx_lm.server on port 11500" )
      fi
      [[ -n "$_occupant_pid" && -n "$_next_extra_port" ]] && _xa+=( "Run mlx_lm.server on port $_next_extra_port" )
      _xa+=( "Run mlx_lm.chat" "Run mlx_lm.generate" "Copy name" "Delete" "Back" )
      action=$(printf "%s\n" "${_xa[@]}" | gum choose --header $'\n'"$selected:" --height 12)
    else
      local _std_first
      if [[ "$_occupant_model" == "$selected" ]]; then
        _std_first="Already running on :11500"
      elif [[ -n "$_occupant_model" ]]; then
        _std_first="Swap"
      else
        _std_first="Start"
      fi
      action=$(printf "%s\nDelete\nBack" "$_std_first" | gum choose --header $'\n'"$selected:" --height 8)
    fi
    [[ -z "$action" ]] && continue

    case "$action" in
      "Start"|"Start mlx_lm.server on port 11500")
        _ymlx_launch "$selected"
        _preselect_model="$selected"
        ;;
      "Swap"|"Swap mlx_lm.server on port 11500")
        if [[ -n "$_occupant_pid" ]]; then
          echo "Stopping $_occupant_model on :11500…"
          kill "$_occupant_pid" 2>/dev/null
          _ymlx_drop "$_occupant_pid"
          local _wait=0
          while (( _wait < 20 )) && ! _ymlx_port_free 11500; do
            sleep 0.1; (( _wait++ ))
          done
        fi
        _ymlx_launch "$selected"
        _preselect_model="$selected"
        ;;
      "Run mlx_lm.server on port "*)
        _ymlx_launch "$selected"
        _preselect_model="$selected"
        ;;
      "Already running on :11500")
        _preselect_model="$selected"
        ;;
      "Run mlx_lm.chat")
        mlx_lm.chat --model "$selected" "${YMLX_CHAT_FLAGS[@]}"
        ;;
      "Run mlx_lm.generate")
        local prompt
        prompt=$(gum write --placeholder "Type a prompt — Ctrl-D to run, Esc to cancel" --width 80 --height 12)
        if [[ $? -eq 0 && -n "$prompt" ]]; then
          mlx_lm.generate --model "$selected" --prompt "$prompt"
          gum input --placeholder "(press enter to continue)" >/dev/null
        fi
        ;;
      "Copy name")
        echo "$selected" | pbcopy
        echo "Copied: $selected"
        ;;
      "Delete")
        local folder="$hub_dir/models--${selected//\//--}"
        if [[ ! -d "$folder" ]]; then
          echo "Folder not found: $folder"
        elif gum confirm "Remove $selected from $hub_dir?"; then
          rm -rf "$folder"
          unset "_ymlx_size_mt[$selected]" "_ymlx_size_kb[$selected]"
          _ymlx_size_save "$size_cache_file"
          echo "Removed: $selected"
        fi
        ;;
      "Back")
        ;;
    esac
  done
}

_ymlx_cleanup() {
  [[ -n "$_YMLX_TMP_CFG" && -f "$_YMLX_TMP_CFG" ]] && rm -f "$_YMLX_TMP_CFG"
  local pid
  for pid in "${_YMLX_SESSION_PIDS[@]}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  [[ -n "$_YMLX_STTY_SAVED" ]] && stty "$_YMLX_STTY_SAVED" 2>/dev/null
}
trap _ymlx_cleanup EXIT INT TERM HUP

ymlx "$@"
