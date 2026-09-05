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
  local log_dir="$state_dir/logs"
  local config_file="$state_dir/config.zsh"
  local chat_dir="$state_dir/chats"

  typeset -ga YMLX_CHAT_FLAGS=( --max-tokens 2048 --temperature 0.7 )
  typeset -ga YMLX_SERVER_FLAGS=()

  local cmd missing=()
  for cmd in gum curl uvx mlx_vlm.server; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    print -u2 "ymlx: missing required tool(s): ${missing[*]}"
    print -u2 ""
    print -u2 "Install with:"
    print -u2 "  brew install uv gum && uv tool install mlx-vlm --with jinja2"
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
# ymlx config — sourced on startup. Use "Basic settings" in the main menu for the
# common toggles (thinking / temp / max-tokens / system prompt); they live in
# the managed block below and ymlx rewrites it. Hand-edit anything below the
# block to add advanced flags — see `mlx_vlm.chat --help` / `mlx_vlm.server --help`.
# --model / --port / --host are managed by ymlx (pinned to :11500).

# >>> ymlx-managed quick settings — edit via "Basic settings" <<<
YMLX_QUICK_THINKING="default"      # default | on | off  (default = use model's built-in)
YMLX_QUICK_TEMP=""                 # e.g. 0.7, or empty to use YMLX_CHAT_FLAGS default
YMLX_QUICK_MAX_TOKENS=""           # e.g. 2048, or empty to use YMLX_CHAT_FLAGS default
YMLX_QUICK_SYSTEM_PROMPT=""        # chat only; empty disables
# <<< end ymlx-managed >>>

# CHAT_FLAGS are informational: the built-in REPL talks to the running server
# over HTTP, so the SERVER_FLAGS below are the ones that take effect at runtime.
YMLX_CHAT_FLAGS=(
  --max-tokens 2048
  --temperature 0.7
  # --enable-thinking
  # --thinking-budget 100
  # --thinking-mode enabled
  # --max-kv-size 4096
  # --kv-bits 8
  # --kv-quant-scheme turboquant
  # --quantized-kv-start 2048
)

YMLX_SERVER_FLAGS=(
  # --max-tokens 2048
  # --enable-thinking      # Basic settings manages on/off; requests may override per-request
  # --thinking-budget 100
  # --thinking-start-token " thinking"
  # --thinking-end-token " response"
  # --draft-model mlx-community/some-draft-model
  # --draft-kind dflash
  # --max-num-seqs 1
  # --kv-bits 8
  # --kv-quant-scheme turboquant
  # --max-kv-size 4096
  # --quantized-kv-start 2048
  # --prefill-step-size 2048
  # --vision-cache-size 100
  # --adapter-path /path/to/adapter
  # --image-model mlx-community/some-image-model    # preload alongside the chat model
  # --tts-model mlx-community/some-tts-model        # preload text-to-speech
  # --stt-model mlx-community/some-stt-model        # preload speech-to-text
  # --embedding-model mlx-community/some-embedder
  # --reranker-model mlx-community/some-reranker
  # --trust-remote-code
  # --log-level INFO
)
CFG
  }

  typeset -g YMLX_QUICK_THINKING="default"
  typeset -g YMLX_QUICK_TEMP=""
  typeset -g YMLX_QUICK_MAX_TOKENS=""
  typeset -g YMLX_QUICK_SYSTEM_PROMPT=""
  typeset -g _YMLX_TMP_CFG=""
  typeset -g _YMLX_STTY_SAVED=""
  typeset -g _YMLX_MENU_QUIT=0
  typeset -gi _YMLX_HF_SKIPPED=0
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
    echo "  Thinking:   $thinking • tab toggle thinking • esc stops output"
    echo
python3 -c "$(cat <<'PY'
import sys, json, re, signal, termios, tty, select, os, codecs, urllib.request, urllib.error

url, model = sys.argv[1], sys.argv[2]
sysp = sys.argv[3] if len(sys.argv) > 3 else ""
thinking = sys.argv[4] if len(sys.argv) > 4 else "default"
log_path = sys.argv[5] if len(sys.argv) > 5 else ""
temp = sys.argv[6] if len(sys.argv) > 6 else ""
max_tokens = sys.argv[7] if len(sys.argv) > 7 else ""

# thinking: "default" | "on" | "off". enable_thinking is the per-request
# override mlx_vlm.server reads as the top-level "enable_thinking" field;
# None = leave it to the server default (--enable-thinking).
if thinking == "on":
    enable_thinking = True
elif thinking == "off":
    enable_thinking = False
else:
    enable_thinking = None

base = ([{"role":"system","content":sysp}] if sysp else [])
messages = list(base)

OPEN = re.compile(r' thinking|\[THINK\]', re.IGNORECASE)
CLOSE = re.compile(r' response|\[/THINK\]', re.IGNORECASE)
TAIL = 10  # max bytes to hold back in case a tag straddles chunks
GRAY = "\033[2m"
RESET = "\033[0m"
ANSI = re.compile(r'\x1b\[[0-9;]*m')
decoder = codecs.getincrementaldecoder("utf-8")("replace")

class Filter:
    # mode "show" renders thinking dim/gray; mode "strip" drops it entirely.
    def __init__(self, mode):
        self.mode = mode
        self.in_think = False
        self.buf = ""
    def feed(self, text):
        self.buf += text
        out = []
        while True:
            if self.in_think:
                m = CLOSE.search(self.buf)
                if not m:
                    break
                if self.mode == "show":
                    out.append(GRAY + self.buf[:m.start()] + RESET)
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
        if self.in_think:
            out = (GRAY + self.buf + RESET) if self.mode == "show" else ""
            self.buf = ""
            self.in_think = False
            return out
        rest, self.buf = self.buf, ""
        return rest

flt = Filter("strip" if enable_thinking is False else "show")
PROMPT = "\033[1;36myou>\033[0m "

def log(msg):
    if log_path:
        try:
            with open(log_path, "a") as f:
                f.write(msg + "\n")
        except OSError:
            pass

def toggle_thinking():
    global enable_thinking
    if enable_thinking is None:
        enable_thinking = True
    else:
        enable_thinking = not enable_thinking
    flt.mode = "show" if enable_thinking else "strip"
    state = "on" if enable_thinking else "off"
    sys.stdout.write("\r\033[2m(thinking %s)\033[0m\r\n" % state)
    sys.stdout.flush()

# Ctrl-T (SIGINFO) also toggles thinking when the terminal delivers it.
try:
    signal.signal(signal.SIGINFO, lambda s, f: toggle_thinking())
except Exception:
    pass

# Raw-mode terminal so we can see Tab and Esc as bytes instead of cooked input.
FD = 0
IN = ""  # leftover type-ahead / partially read input

def key_available(timeout=0.0):
    return bool(select.select([FD], [], [], timeout)[0])

def fill(timeout=None):
    global IN
    if IN:
        return True
    # Incremental decoder keeps a multibyte UTF-8 char intact even if a
    # paste lands on a read() boundary (os.read(FD, 32) may split it).
    while True:
        if not key_available(timeout):
            return False
        raw = os.read(FD, 32)
        if not raw:
            return False  # EOF
        IN = decoder.decode(raw)
        if IN:
            return True
        # Decoded nothing yet (partial multibyte char). Keep reading only
        # when blocking; for bounded peeks, report "nothing yet".
        if timeout is not None:
            return False

def next_byte(timeout=None):
    global IN
    if not fill(timeout):
        return ""
    b = IN[0]
    IN = IN[1:]
    return b

def peek_byte(timeout=0.05):
    if fill(timeout):
        return IN[0]
    return ""

def input_line():
    global IN
    buf = ""
    sys.stdout.write(PROMPT)
    sys.stdout.flush()
    while True:
        b = next_byte(None)
        if b == "":
            raise EOFError
        if b == "\x1b":
            nxt = peek_byte(0.05)
            if nxt in ("[", "O"):
                next_byte(0.05)  # consume the sequence introducer
                while True:
                    nb = peek_byte(0.05)
                    if not nb:
                        break
                    next_byte(0.05)
                    if 0x40 <= ord(nb) <= 0x7E:
                        break
            continue  # lone Esc is ignored without eating the next key
        if b in ("\r", "\n"):
            sys.stdout.write("\r\n")
            sys.stdout.flush()
            return buf
        if b == "\x03":
            sys.stdout.write("\r\n")
            sys.stdout.flush()
            raise KeyboardInterrupt
        if b == "\x04":
            sys.stdout.write("\r\n")
            sys.stdout.flush()
            raise EOFError
        if b in ("\x7f", "\x08"):
            if buf:
                buf = buf[:-1]
                sys.stdout.write("\b \b")
                sys.stdout.flush()
            continue
        if b == "\t":
            toggle_thinking()
            sys.stdout.write(PROMPT + buf)
            sys.stdout.flush()
            continue
        buf += b
        sys.stdout.write(b)
        sys.stdout.flush()

old_term = termios.tcgetattr(FD)
try:
    tty.setraw(FD)
    while True:
        try:
            user = input_line()
        except EOFError:
            sys.stdout.write("\r\n")
            break
        except KeyboardInterrupt:
            sys.stdout.write("\r\n")
            break
        s = user.strip()
        if not s:
            continue
        if s in ("/exit", "/quit", "exit", "quit"):
            break
        if s == "/reset":
            messages = list(base)
            sys.stdout.write("\r\n\033[2m(history cleared)\033[0m\r\n")
            sys.stdout.flush()
            log("(history cleared)")
            continue
        messages.append({"role":"user","content":user})
        log("you> " + user)
        body = {"model":model, "messages":messages, "stream":True}
        if enable_thinking is not None:
            body["enable_thinking"] = enable_thinking
        if temp:
            try:
                body["temperature"] = float(temp)
            except ValueError:
                pass
        if max_tokens:
            try:
                body["max_tokens"] = int(max_tokens)
            except ValueError:
                pass
        req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type":"application/json"})
        print("\033[1;35massistant>\033[0m ", end="", flush=True)
        full = ""
        visible = ""
        stopped = False
        try:
            with urllib.request.urlopen(req) as r:
                for raw in r:
                    if key_available(0):
                        k = os.read(FD, 4096).decode("utf-8", "replace")
                        if "\x1b" in k:
                            stopped = True
                            break
                        IN = k + IN
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
                                sys.stdout.write(shown.replace("\n", "\r\n"))
                                sys.stdout.flush()
                    except (json.JSONDecodeError, KeyError, IndexError):
                        pass
            if not stopped:
                tail = flt.flush()
                if tail:
                    visible += tail
                    sys.stdout.write(tail.replace("\n", "\r\n"))
                    sys.stdout.flush()
        except urllib.error.URLError as e:
            sys.stdout.write("\r\n\033[31m[error] %s\033[0m\r\n" % e)
            sys.stdout.flush()
            messages.pop()
            continue
        except KeyboardInterrupt:
            sys.stdout.write("\r\n\033[2m[interrupted]\033[0m\r\n")
            sys.stdout.flush()
            messages.pop()
            continue
        sys.stdout.write("\r\n")
        sys.stdout.flush()
        # Esc keeps the partial reply in history so the model has context of
        # what it already generated; only display is filtered.
        plain = ANSI.sub("", visible)
        if stopped:
            sys.stdout.write("\033[2m[stopped]\033[0m\r\n")
            sys.stdout.flush()
            log("assistant> " + plain + " [stopped]")
        else:
            log("assistant> " + plain)
        messages.append({"role":"assistant","content":full})
finally:
    termios.tcsetattr(FD, termios.TCSANOW, old_term)

PY
)" "$url" "$model" "$sysp" "$thinking" "$chat_log" "$YMLX_QUICK_TEMP" "$YMLX_QUICK_MAX_TOKENS"
  }

  _ymlx_apply_quick() {
    # Thinking is a bare flag in mlx_vlm: --enable-thinking turns it on by
    # default for requests that don't send top-level enable_thinking. "on"
    # forces the flag on; "off" removes it (requests can still force it off
    # per request, as the chat REPL does); "default" leaves hand-written flags
    # in the config untouched.
    case "$YMLX_QUICK_THINKING" in
      on)  _ymlx_flag_set YMLX_CHAT_FLAGS --enable-thinking 1
           _ymlx_flag_set YMLX_SERVER_FLAGS --enable-thinking 1 ;;
      off) _ymlx_flag_set YMLX_CHAT_FLAGS --enable-thinking 0
           _ymlx_flag_set YMLX_SERVER_FLAGS --enable-thinking 0 ;;
    esac
    if [[ -n "$YMLX_QUICK_TEMP" ]]; then
      _ymlx_replace_or_append YMLX_CHAT_FLAGS --temperature "$YMLX_QUICK_TEMP"
      # mlx_vlm.server has no server-level temperature flag — temperature is a
      # per-request field, which the chat REPL sends (and API clients send).
    fi
    if [[ -n "$YMLX_QUICK_MAX_TOKENS" ]]; then
      _ymlx_replace_or_append YMLX_CHAT_FLAGS --max-tokens "$YMLX_QUICK_MAX_TOKENS"
      _ymlx_replace_or_append YMLX_SERVER_FLAGS --max-tokens "$YMLX_QUICK_MAX_TOKENS"
    fi
    # System prompts are per-request only: mlx_vlm has no --system-prompt flag
    # (server or chat), and YMLX_CHAT_FLAGS is informational, so there is
    # nothing to write here — the chat REPL injects YMLX_QUICK_SYSTEM_PROMPT
    # into the request messages and API clients pass it in the body.
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
          '# >>> ymlx-managed quick settings — edit via "Basic settings" <<<' \
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
            '# >>> ymlx-managed quick settings — edit via "Basic settings" <<<' \
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

  _ymlx_basic_settings_menu() {
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
      local -a settings_entries=(
        "Thinking:       $cur_t"
        "Temperature:    $cur_temp"
        "Max tokens:     $cur_max"
        "System prompt:  $cur_sys"
        "Back"
      )
      local choice=$(printf "%s\n" "${settings_entries[@]}" | gum choose --header $'\nBasic settings (current values shown):' --height 14)
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
      esac
      _ymlx_write_managed_block "$config_file"
      _ymlx_reload_config
    done
  }

  _ymlx_advanced_settings_menu() {
    local ed=$(_ymlx_pick_editor)
    eval "$ed \"\$config_file\""
    _ymlx_reload_config
  }

  _ymlx_open_models_folder() {
    open "$hub_dir"
  }

  _ymlx_main_restart() {
    _ymlx_main_clear
    local pid port model running_model=""
    while IFS=$'\t' read -r pid port model; do
      [[ -n "$pid" ]] && running_model="$model"
    done < <(_ymlx_running)
    if [[ -n "$running_model" ]]; then
      _ymlx_stop_all >/dev/null 2>&1
      echo "Restarting: $running_model"
      local i
      for i in {1..40}; do
        _ymlx_port_free 11500 && break
        sleep 0.2
      done
      _ymlx_launch "$running_model"
    else
      echo "No model is running — nothing to restart."
      echo "(Menu refreshed.)"
    fi
  }

  [[ -f "$config_file" ]] || _ymlx_write_default_config "$config_file"
  _ymlx_reload_config

#
# HuggingFace token handling. mlx-vlm downloads models from the HF Hub; without
# a token it warns "sending unauthenticated requests". These helpers expose an
# existing token (env or the on-disk cache that `huggingface-cli login` / an
# earlier ymlx login wrote) and offer a one-shot wizard to save one.
#
_ymlx_hf_token_file() {
  print -r -- "${HF_HOME:-$HOME/.cache/huggingface}/token"
}

_ymlx_hf_has_token() {
  [[ -n "$HF_TOKEN" ]] && return 0
  [[ -s "$(_ymlx_hf_token_file)" ]] && return 0
  return 1
}

_ymlx_hf_setup() {
  local action tok tf
  tf=$(_ymlx_hf_token_file)
  echo
  gum style --foreground 212 --bold "HuggingFace authentication"
  gum style --foreground 250 "ymlx downloads models from the HuggingFace Hub. Adding a token gets you"
  gum style --foreground 250 "higher rate limits + faster downloads and unlocks gated/private models."
  gum style --foreground 244 "(Without one, ymlx just warns and still works for public models.)"
  echo
  action=$(printf "Paste a token now\nSkip (public models only)" | gum choose --header "Hugging Face token?" --height 5)
  if [[ -z "$action" || "$action" != "Paste"* ]]; then
    echo "Skipped — public model downloads will simply be unauthenticated."
    return 1
  fi
  tok=$(gum input --prompt "Token: " --placeholder "hf_...  (create one at https://huggingface.co/settings/tokens)")
  tok="${tok//[[:space:]]/}"
  if [[ -z "$tok" ]]; then
    echo "No token entered — skipped."
    return 1
  fi
  mkdir -p "${tf:h}"
  chmod 700 "${tf:h}" 2>/dev/null
  printf '%s\n' "$tok" > "$tf"
  chmod 600 "$tf" 2>/dev/null
  export HF_TOKEN="$tok"
  echo "✓ Authenticated — saved to $tf (shared with other HuggingFace tools)."
  return 0
}

# If a token is already on disk (written by an earlier ymlx login or by
# `uvx huggingface_hub[cli] huggingface-cli login`), export it so every download
# subprocess this session is authenticated and the warning stops appearing.
if [[ -z "$HF_TOKEN" && -s "$(_ymlx_hf_token_file)" ]]; then
  export HF_TOKEN="$(<"$(_ymlx_hf_token_file)")"
fi

# Discover the currently running mlx_vlm.server on :11500 by asking the OS, not
# a state file. Emits a TSV line: pid<TAB>port<TAB>model.
# The model id is parsed from the process's --model arg.
_ymlx_running() {
    local lpid cmd m
    lpid=$(lsof -iTCP:11500 -sTCP:LISTEN -t 2>/dev/null | head -n1)
    [[ -z "$lpid" ]] && return
    cmd=$(ps -o command= -p "$lpid" 2>/dev/null)
    [[ "$cmd" != *"--model "* ]] && return
    m="${cmd#*--model }"
    m="${m%% *}"
    [[ -z "$m" ]] && return
    printf '%s\t%s\t%s\n' "$lpid" 11500 "$m"
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

  _ymlx_launch() {
    local model="$1"
    local port=$(_ymlx_find_port)
    if [[ -z "$port" ]]; then
      echo "Port :11500 is busy. Stop the running model (^s in the menu) first."
      return 1
    fi
    local safe="${model//\//_}"
    local log="$log_dir/${safe}-${port}.log"
    mlx_vlm.server --model "$model" --port "$port" "${YMLX_SERVER_FLAGS[@]}" >"$log" 2>&1 &
    local pid=$!
    _YMLX_SESSION_PIDS+=( "$pid" )
    local rc=0
    gum spin --spinner dot --title "Initializing $model… (Ctrl-C to cancel)" -- zsh -c "
      local n=0
      while kill -0 $pid 2>/dev/null; do
        (( n++ > 2400 )) && exit 1
        [[ -s '$log' ]] && exit 0
        sleep 0.3
      done
      exit 1
    "
    rc=$?
    if (( rc == 0 )); then
      echo "  ✓ Initialized"
      gum spin --spinner dot --title "Loading model weights…" -- zsh -c "
        local n=0
        while kill -0 $pid 2>/dev/null; do
          (( n++ > 2400 )) && exit 1
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
        local n=0
        while kill -0 $pid 2>/dev/null; do
          (( n++ > 2400 )) && exit 1
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
    return $rc
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

    # First download of the session without a token: offer to set one so the
    # "unauthenticated requests" warning goes away. Skipping is remembered for
    # the rest of this session, so it stays out of the way.
    if ! _ymlx_hf_has_token && (( _YMLX_HF_SKIPPED == 0 )); then
      if ! _ymlx_hf_setup; then
        _YMLX_HF_SKIPPED=1
      fi
    fi

    echo
    gum style --foreground 212 --bold "Downloading $model"
    echo "(progress will stream below — Ctrl-C to abort)"
    echo
    if uvx --from mlx-vlm python3 -c "from mlx_vlm.utils import load; load('$model')"; then
      echo
      gum style --foreground 42 "✓ Downloaded: $model"
      echo
      if gum confirm "Start $model now?"; then
        _ymlx_launch "$model"
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
      _YMLX_MENU_LINES=( "Download your first model" "Chat history" "Basic settings" "Advanced settings" "Open models folder" "Stop and quit" )
      _YMLX_MENU_KINDS=( "action" "action" "action" "action" "action" "action" )
      _YMLX_MENU_MODELS=( "" "" "" "" "" "" )
      _YMLX_MENU_PORTS=( "" "" "" "" "" "" )
      _YMLX_MENU_ACTIONS=( "download" "history" "basic" "advanced" "openhub" "quit" )
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
      _YMLX_MENU_LINES+=( "Chat history" "Basic settings" "Advanced settings" "Open models folder" "Download new model" "Restart and refresh" "Stop and quit" )
      _YMLX_MENU_KINDS+=( "action" "action" "action" "action" "action" "action" "action" )
      _YMLX_MENU_MODELS+=( "" "" "" "" "" "" "" )
      _YMLX_MENU_PORTS+=( "" "" "" "" "" "" "" )
      _YMLX_MENU_ACTIONS+=( "history" "basic" "advanced" "openhub" "download" "restart" "quit" )
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
    local delta="$1" n=${#_YMLX_MENU_LINES[@]} new=$_YMLX_MENU_CURSOR guard=$_YMLX_MENU_CURSOR
    while true; do
      new=$(( new + delta ))
      if (( new < 0 )); then new=$(( n - 1 )); fi
      if (( new >= n )); then new=0; fi
      if [[ "${_YMLX_MENU_KINDS[$((new+1))]}" != "separator" ]]; then
        _YMLX_MENU_CURSOR=$new
        break
      fi
      if (( new == guard )); then break; fi
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
    gum input --placeholder "(press enter to continue)" >/dev/null
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
      gum input --placeholder "(press enter to continue)" >/dev/null
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
        echo "Removed: $model"
        gum input --placeholder "(press enter to continue)" >/dev/null
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
          if _ymlx_launch "$model"; then
            _ymlx_chat_repl "$model" "11500"
          fi
        fi
      fi
    else
      case "$action" in
        download) _ymlx_download_menu ;;
        history) _ymlx_chat_history_menu ;;
        basic) _ymlx_basic_settings_menu ;;
        advanced) _ymlx_advanced_settings_menu ;;
        openhub) _ymlx_open_models_folder ;;
        restart) _ymlx_main_restart ;;
        quit) _ymlx_main_quit ;;
      esac
    fi
    (( _YMLX_MENU_QUIT )) && return
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

  # Headless (non-interactive) helpers -------------------------------
  _ymlx_running_model() {  # echoes pid\tport\tmodel (or nothing)
    local line
    line="$(_ymlx_running)" && [[ -n "$line" ]] && print "$line"
  }

  _ymlx_headless_launch() {
    local model="$1"
    local port
    port=$(_ymlx_find_port)
    if [[ -z "$port" ]]; then
      print -u2 "ymlx: port 11500 is busy — stop the running model first (ymlx stop)"
      return 1
    fi
    local safe="${model//\//_}"
    local log="$log_dir/${safe}-${port}.log"
    mlx_vlm.server --model "$model" --port "$port" "${YMLX_SERVER_FLAGS[@]}" >"$log" 2>&1 &!
    local pid=$!
    print "ymlx: starting $model on :$port (pid $pid) — log: $log"
    local i
    for i in {1..2400}; do   # ~ up to 20 min for large/quantized models
      if ! kill -0 "$pid" 2>/dev/null; then
        print -u2 "ymlx: server exited while loading — last log lines:"
        tail -n 20 "$log" >&2
        return 1
      fi
      if curl -fs -o /dev/null --max-time 1 "http://127.0.0.1:$port/v1/models" 2>/dev/null; then
        print "ymlx: ready $model on :$port (pid $pid)"
        return 0
      fi
      sleep 0.5
    done
    print -u2 "ymlx: timed out waiting for $model to serve — log: $log"
    return 1
  }

  _ymlx_headless_run() {
    local model="$1"
    if [[ -z "$model" ]]; then
      print -u2 "usage: ymlx run <model-id>, e.g. ymlx run mlx-community/Qwen3-8B"
      return 2
    fi
    # Fast path: the requested model is already serving.
    if [[ -n "$(_ymlx_running_model)" ]]; then
      local pid port cur
      read -r pid port cur <<< "$(_ymlx_running_model)"
      if [[ "$cur" == "$model" ]]; then
        print "ymlx: $model already running on :$port (pid $pid)"
        return 0
      fi
      print "ymlx: stopping $cur (pid $pid) to switch to $model"
      kill "$pid" 2>/dev/null
      local i
      for i in {1..40}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
    fi
    _ymlx_headless_launch "$model"
    return $?
  }

  _ymlx_headless_stop() {
    if [[ -n "$(_ymlx_running_model)" ]]; then
      local pid port cur
      read -r pid port cur <<< "$(_ymlx_running_model)"
      kill "$pid" 2>/dev/null && print "ymlx: stopped $cur (pid $pid)"
      return 0
    fi
    print "ymlx: nothing running on :11500"
    return 0
  }

  _ymlx_headless_status() {
    if [[ -n "$(_ymlx_running_model)" ]]; then
      local pid port cur
      read -r pid port cur <<< "$(_ymlx_running_model)"
      print "$cur\t:$port\tpid $pid"
      return 0
    fi
    print "none"
    return 1
  }

  # ---- headless (non-interactive) mode --------------------------
  # ``ymlx <sub> [args]`` runs and exits without the TUI. Designed for
  # automation (pi's model_select hook), so servers are DETACHED: they must
  # survive this shell exiting, so we clear the EXIT trap, never add the pid
  # to _YMLX_SESSION_PIDS, and disown it.
  if (( $# > 0 )); then
    local _YMLX_HEADLESS=1
    trap - EXIT INT TERM HUP
    local _sub="$1"; shift
    case "$_sub" in
      run)        _ymlx_headless_run      "$@" ;;
      stop)       _ymlx_headless_stop     "$@" ;;
      status)     _ymlx_headless_status   "$@" ;;
      *) print -u2 "ymlx: unknown command '$_sub'"; print -u2 "usage: ymlx {run <model-id>|stop|status}"; return 2 ;;
    esac
    return
  fi

  clear
  echo
  gum style --foreground 212 --bold "▌▌ YMLX"
  gum style --foreground 244 "Runs an MLX model behind an OpenAI-compatible REST API at localhost:11500"
  if ! _ymlx_hf_has_token; then
    gum style --foreground 244 "HF Hub: unauthenticated — downloads still work but are slower. Offer a token at the first download."
  fi

  while true; do
    _ymlx_main_standard
    (( _YMLX_MENU_QUIT )) && return
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
