#!/usr/bin/env zsh

unsetopt xtrace verbose 2>/dev/null

# Pids ymlx launched in this shell session. The EXIT trap kills these so child
# servers don't outlive their manager. Servers from other sessions or external
# processes are discovered live via lsof+ps in _ymlx_running and aren't tracked
# here, so we won't kill what we didn't start.
typeset -ga _YMLX_SESSION_PIDS=()

# Self-contained helpers (no dependence on ymlx()'s locals) live in lib/.
local _YMLX_SRC_DIR="${0:A:h}"
source "$_YMLX_SRC_DIR/lib/ymlx-helpers.zsh"

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
    # One-shot repair: interactive startup auto-installs a missing mlx-vlm
    # (the one missing piece uv can fix on its own); anything else — or any
    # missing tool in headless mode — still aborts with instructions so
    # automation (pi's model_select hook) fails loudly and fast.
    if (( $# == 0 && ${#missing[@]} == 1 && ${missing[1]} == "mlx_vlm.server" )) \
       && command -v uv >/dev/null 2>&1; then
      print -u2 "ymlx: mlx-vlm not installed — installing (one-time)…"
      if uv tool install mlx-vlm --with jinja2 >/dev/null 2>&1 \
         && command -v mlx_vlm.server >/dev/null 2>&1; then
        print -u2 "ymlx: mlx-vlm installed."
        missing=()
      fi
    fi
    if (( ${#missing[@]} > 0 )); then
      print -u2 "ymlx: missing required tool(s): ${missing[*]}"
      print -u2 ""
      print -u2 "Install with:"
      print -u2 "  brew install uv gum && uv tool install mlx-vlm --with jinja2"
      return 1
    fi
  fi

  mkdir -p "$state_dir" "$log_dir" "$chat_dir"

  # The curated download list lives in the standalone ymlx-curator repo; pull
  # the latest copy at startup and cache it. Retry a few times, then fall back
  # to the github.com mirror, and only if both fail use the last cached copy.
  local curated_url="https://raw.githubusercontent.com/pavsefcik/ymlx-curator/main/ymlx-curator.md"
  local curated_mirror="https://github.com/pavsefcik/ymlx-curator/raw/main/ymlx-curator.md"
  local curated_file="$state_dir/curated-llms.md"
  local curated_tmp="$curated_file.tmp" curated_refreshed=0 attempt
  for attempt in 1 2 3; do
    if curl -fsSL --connect-timeout 8 --max-time 20 "$curated_url" -o "$curated_tmp" 2>/dev/null \
       && [[ -s "$curated_tmp" ]]; then
      mv "$curated_tmp" "$curated_file"
      curated_refreshed=1
      break
    fi
  done
  if (( curated_refreshed == 0 )); then
    if curl -fsSL --connect-timeout 8 --max-time 20 "$curated_mirror" -o "$curated_tmp" 2>/dev/null \
       && [[ -s "$curated_tmp" ]]; then
      mv "$curated_tmp" "$curated_file"
      curated_refreshed=1
    fi
  fi
  if (( curated_refreshed == 0 )); then
    [[ -f "$curated_file" ]] || : > "$curated_file"
    if (( $# == 0 )); then
      print -u2 "ymlx: couldn't refresh the curated model list — using the cached copy."
    fi
  fi
  rm -f "$curated_tmp"

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
  typeset -ga _YMLX_MENU_PAIRS=()
  typeset -gi _YMLX_MENU_CURSOR=0
  typeset -gi _YMLX_MENU_SCROLL=0
  typeset -gi _YMLX_MENU_VIS=10
  typeset -gi _YMLX_MENU_WIDTH=80
  typeset -gi _YMLX_MENU_DRAWN=0
  typeset -gi _YMLX_MENU_NLINES=0
  typeset -gi _YMLX_MENU_NO_MODELS=0
  typeset -g _YMLX_UPDATE_NEW=""
  typeset -g _YMLX_UPDATE_INSTALLED=""
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
    local resume="${3:-}"
    if ! command -v python3 >/dev/null 2>&1; then
      gum style --foreground 196 "python3 not found — install Xcode Command Line Tools (xcode-select --install) to use the built-in chat."
      _ymlx_pause
      return 1
    fi
    local sysp="$YMLX_QUICK_SYSTEM_PROMPT"
    local rc ministral_other co chat_log url friendly
    while true; do
      sysp="$YMLX_QUICK_SYSTEM_PROMPT"
      url="http://127.0.0.1:$port/v1/chat/completions"
      friendly=$(_ymlx_display_name "$model")
      local thinking="${YMLX_QUICK_THINKING:-default}"
      local stamp safe
      # If chatting one half of a Ministral pair (Instruct or Reasoning), tab
      # swaps to the sibling — tell the REPL so it can raise exit-3 to request
      # the swap.
      ministral_other=""
      if [[ "${model##*/}" == *-Instruct-* || "${model##*/}" == *-Reasoning-* ]]; then
        co=$(_ymlx_ministral_sibling "$model")
        [[ -d "$hub_dir/models--${co//\//--}" ]] && ministral_other="$co"
      fi
      # The banner's "Thinking:" reflects the model variant: a Reasoning pair
      # half is inherently "on", an Instruct half "off". YMLX_QUICK_THINKING
      # still drives the enable_thinking request override sent to the REPL.
      local is_reasoning=0 thinking_disp="$thinking"
      if [[ "${model##*/}" == *-Reasoning-* ]]; then
        is_reasoning=1
        thinking_disp="on"
      elif [[ "${model##*/}" == *-Instruct-* ]]; then
        thinking_disp="off"
      fi
      if [[ -n "$resume" && -f "$resume" ]]; then
        # Resume: append to the existing chat's log and seed the conversation
        # from that log inside the python REPL (resume path is arg 8).
        chat_log="$resume"
        echo "# Resumed: $(date '+%Y-%m-%d %H:%M:%S')" >> "$chat_log"
      else
        resume=""
        stamp=$(date +%Y-%m-%d_%H%M%S)
        safe="${model//\//_}"
        chat_log="$chat_dir/${stamp}_${safe}.txt"
        {
          echo "# Chat with $friendly on :$port"
          echo "# Model: $model"
          echo "# Base URL: http://localhost:$port/v1"
          echo "# Started: $(date '+%Y-%m-%d %H:%M:%S')"
          echo "# Thinking: $thinking_disp"
          echo
        } > "$chat_log"
      fi
      echo
      gum style --foreground 212 --bold "Chatting with $friendly on :$port"
      if [[ -n "$resume" ]]; then
        echo "  (resuming an existing conversation — new messages append to its log)"
      fi
      echo "  Base URL:   http://localhost:$port/v1"
echo "  Model:      $model"
      echo "  Commands:   /reset clears history • /exit or Ctrl-D to leave"
      if [[ -n "$ministral_other" ]]; then
        echo "  Thinking:   $thinking_disp • tab swaps instruct↔reasoning"
      else
        echo "  Thinking:   $thinking_disp • tab toggle thinking"
      fi
      echo
python3 -c "$(cat <<'PY'
import sys, json, re, signal, termios, tty, select, os, codecs, urllib.request, urllib.error

url, model = sys.argv[1], sys.argv[2]
sysp = sys.argv[3] if len(sys.argv) > 3 else ""
thinking = sys.argv[4] if len(sys.argv) > 4 else "default"
log_path = sys.argv[5] if len(sys.argv) > 5 else ""
temp = sys.argv[6] if len(sys.argv) > 6 else ""
max_tokens = sys.argv[7] if len(sys.argv) > 7 else ""
# When chatting one half of a Ministral pair, tab drops us back to the shell
# (exit 3) so it can swap to the sibling variant (Instruct <-> Reasoning).
ministral_other = sys.argv[9] if len(sys.argv) > 9 else ""
# True when the chat model is a Reasoning-variant half of a Ministral pair.
# Such models always emit a thinking block, so the REPL knows to treat
# everything up to the closing token as thinking (no opener is required).
is_reasoning = len(sys.argv) > 10 and sys.argv[10] == "1"

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

# Resume: when a previous chat log is provided, seed the conversation from it.
# Lines are `you> …` / `assistant> …`; `(history cleared)` resets context.
resume = sys.argv[8] if len(sys.argv) > 8 else ""
if resume:
    try:
        with open(resume) as _rf:
            for _rl in _rf:
                _rl = _rl.rstrip("\n")
                if _rl.startswith("you> "):
                    messages.append({"role": "user", "content": _rl[5:]})
                elif _rl.startswith("assistant> "):
                    _c = _rl[11:]
                    if _c.endswith(" [stopped]"):
                        _c = _c[:-10]
                    messages.append({"role": "assistant", "content": _c})
                elif _rl == "(history cleared)":
                    messages = list(base)
    except OSError:
        pass

OPEN = re.compile(r' thinking|\[THINK\]', re.IGNORECASE)
CLOSE = re.compile(r' response|\[/THINK\]', re.IGNORECASE)
# Explicit Ministral tags. For reasoning models the thinking is delimited by
# [THINK]…[/THINK]; the loose " thinking"/" response" words must NOT be used
# as the close for Ministral, or a bare " response" inside the reasoning would
# truncate it prematurely. We close strictly on the explicit [\/THINK] tag.
ROPEN  = re.compile(r'\s*\[THINK\]', re.IGNORECASE)
RCLOSE = re.compile(r'\[/THINK\]', re.IGNORECASE)
TAIL = 10  # max bytes to hold back in case a tag straddles chunks
GRAY = "\033[2m"
RESET = "\033[0m"
ANSI = re.compile(r'\x1b\[[0-9;]*m')
decoder = codecs.getincrementaldecoder("utf-8")("replace")

class Filter:
    # mode "show" renders thinking dim/gray; mode "strip" drops it entirely.
    #
    # A reasoning model's thinking can reach the client two ways, depending on
    # the server/template:
    #   * external — streamed in the separate reasoning_content field, leaving
    #     content as the clean answer; or
    #   * inline — embedded in content as [THINK]…[/THINK].
    # This filter handles both. Inline closing is done strictly on [/THINK] so
    # a " response" word inside the reasoning never cuts the block short, and
    # the whole trace from the start is kept grey before the switch to white.
    def __init__(self, mode, reasoning=False):
        self.mode = mode
        self.reasoning = reasoning
        self.external = False   # reasoning arrives via reasoning_content
        self.done = not reasoning   # reasoning: thinking block comes first
        self.in_think = False   # generic (Qwen-style) open/close limiters
        self.buf = ""
    def external_reasoning(self, text):
        # Server routed the trace to reasoning_content; content is the answer.
        body = (self.buf + text) if self.buf else text   # merge any inline tail
        self.buf = ""
        self.external = True
        self.done = True
        self.in_think = False
        return (GRAY + body + RESET) if self.mode == "show" else ""
    def feed_content(self, text):
        if not self.reasoning:
            return self._feed_open_close(text)
        if self.external:
            return text      # clean answer; reasoning already rendered grey
        self.buf += text
        return self._feed_inline()
    def _feed_inline(self):
        # Drop a single leading explicit opener so display starts clean.
        m0 = ROPEN.match(self.buf)
        if m0:
            self.buf = self.buf[m0.end():]
        out = []
        while True:
            if self.done:
                if len(self.buf) > TAIL:
                    out.append(self.buf[:-TAIL])
                    self.buf = self.buf[-TAIL:]
                break
            m = RCLOSE.search(self.buf)
            if not m:
                break
            if self.mode == "show":
                out.append(GRAY + self.buf[:m.start()] + RESET)
            self.buf = self.buf[m.end():]
            self.done = True
        return "".join(out)
    def _feed_open_close(self, text):
        # generic (non-ministral) models: alternate " thinking" / " response".
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
        if self.reasoning:
            rest, self.buf = self.buf, ""
            if not self.done:
                # never closed — whatever remains is still thinking.
                return (GRAY + rest + RESET) if self.mode == "show" else ""
            return rest
        if self.in_think:
            out = (GRAY + self.buf + RESET) if self.mode == "show" else ""
            self.buf = ""
            self.in_think = False
            return out
        rest, self.buf = self.buf, ""
        return rest

flt = Filter("strip" if enable_thinking is False else "show", reasoning=is_reasoning)
PROMPT = "\033[1;36myou>\033[0m "

# Raised on a lone Esc while NOT mid-answer. Esc during an answer stops the
# output; Esc at the prompt leaves the chat and returns to the main menu
# (the server keeps running).
class EscExit(Exception):
    pass

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
            raise EscExit  # lone Esc at the prompt leaves the chat (main menu)
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
            if ministral_other:
                if is_reasoning:
                    sys.stdout.write("\r\n\033[2mSwitching to the instruct version…\033[0m\r\n")
                else:
                    sys.stdout.write("\r\n\033[2mSwitching to the reasoning (thinking) version…\033[0m\r\n")
                sys.stdout.flush()
                sys.exit(3)
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
        except EscExit:
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
                        d = chunk["choices"][0]["delta"]
                        # Server may route reasoning to a separate
                        # reasoning_content field (Qwen-style) OR leave it
                        # inline in content (Ministral). Route both so the
                        # trace always shows in grey.
                        rc = d.get("reasoning_content") or d.get("reasoning") or ""
                        ct = d.get("content") or ""
                        if rc:
                            full += rc
                            shown = flt.external_reasoning(rc)
                            if shown:
                                visible += shown
                                sys.stdout.write(shown.replace("\n", "\r\n"))
                                sys.stdout.flush()
                        if ct:
                            full += ct
                            shown = flt.feed_content(ct)
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
)" "$url" "$model" "$sysp" "$thinking" "$chat_log" "$YMLX_QUICK_TEMP" "$YMLX_QUICK_MAX_TOKENS" "$resume" "$ministral_other" "$is_reasoning"
      rc=$?
      if (( rc != 3 )); then
        return $rc
      fi
      # Ministral pair — tab requested the sibling variant.
      if [[ -z "$ministral_other" ]]; then
        return 3   # safety: shouldn't happen
      fi
      print -r -- "$ministral_other" > "$state_dir/ministral-default"
      _ymlx_ministral_swap_to "$ministral_other" || return 1
      model="$ministral_other"
      port=11500
      resume=""
    done
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
        "Back to Top"
      )
      local choice=$(printf "%s\n" "${settings_entries[@]}" | gum choose --header $'\nBasic settings (current values shown):  esc = back' --height 14)
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

  _ymlx_open_chat_folder() {
    open "$chat_dir"
  }

  # Swap the running model to a Ministral counterpart: stop whatever is up
  # (only one model runs at a time on :11500), wait for the port to free, then
  # launch the requested one. Returns 0 if the new server came up.
  _ymlx_ministral_swap_to() {
    local new="$1"
    _ymlx_stop_all >/dev/null 2>&1
    local i
    for i in {1..40}; do
      _ymlx_port_free 11500 && break
      sleep 0.2
    done
    _ymlx_launch "$new"
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
    local tier_active
    # Tiers in ymlx-curator.md are 8 / 16 / 32 GB; show only the machine's own
    # tier (no cross-tier models and no tier-header lines).
    if (( ram_gb >= 32 )); then
      tier_active=32
    elif (( ram_gb >= 16 )); then
      tier_active=16
    else
      tier_active=8
    fi

    typeset -A installed
    local models m
    models=$(ls "$hub_dir" 2>/dev/null | grep '^models--' | sed 's/models--//' | sed 's/--/\//g')
    for m in ${(f)models}; do installed[$m]=1; done

    # ---- Parse the curated list. New format: blank-line-separated blocks of up
    # to 3 lines (model, tags, optional description). Entries may be commented
    # with a leading '#' — we strip it so every entry shows up (the '#' keeps the
    # full catalog alongside the highlighted picks). The 3rd line for the
    # highlighted entries is used as the description shown under the model.
    # Tier headers are any line containing "GB RAM".
    typeset -A tier_header
    local -a p_title=() p_sub=() p_tags=() p_desc=() p_tier=()
    local line current_tier=0 header num
    if [[ -r "$curated_file" ]]; then
      local -a entry=()
      _D_flush() {
        ((${#entry[@]})) || return
        local a="${entry[1]}" b="${entry[2]:-}" c="${entry[3]:-}"
        entry=()
        [[ -n "$a" ]] || return
        (( current_tier == tier_active )) || return
        local title="" sub="" tags="" desc=""
        if [[ "$a" == */* ]]; then
          # legacy 2/3-line block: model id, tags, optional desc
          sub="$a"; tags="$b"; desc="$c"
        else
          # current 3-line block: title (+flag), model id(s), tags
          title="$a"; sub="$b"; tags="$c"
        fi
        # Hide the block only if every model in it is already installed. A
        # Ministral pair (id & id2) hides once BOTH are present.
        local -a dl=( ${(s: & :)sub} ) m
        local allinst=1
        for m in "${dl[@]}"; do
          [[ -n "${installed[$m]}" ]] || { allinst=0; break; }
        done
        (( allinst )) && return
        p_title+=( "$title" ); p_sub+=( "$sub" ); p_tags+=( "$tags" )
        p_desc+=( "$desc" ); p_tier+=( "$current_tier" )
      }
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
          _D_flush
          continue
        fi
        if [[ "$line" == *"GB RAM"* ]]; then
          _D_flush
          header="$line"
          num="${header//[^0-9]/}"
          tier_header[$num]="$header"
          current_tier=$num
          continue
        fi
        if [[ "$line" == \#* ]]; then
          line="${line#\#}"
          line="${line#"${line%%[![:space:]]*}"}"
        fi
        entry+=( "$line" )
      done < "$curated_file"
      _D_flush
    fi

    # Deduplicate by the model/sub line, keeping the first occurrence.
    typeset -A seen
    local -a srcs=() tags=() descs=() tiers=() titles=()
    local i s
    for (( i=1; i<=${#p_sub[@]}; i++ )); do
      s="${p_sub[$i]}"
      [[ -n "${seen[$s]}" ]] && continue
      seen[$s]=1
      titles+=( "${p_title[$i]}" )
      srcs+=( "$s" ); tags+=( "${p_tags[$i]}" ); descs+=( "${p_desc[$i]}" )
      tiers+=( "${p_tier[$i]}" )
    done

    # ---- Build flat rows for the menu. Cursor/nav only lands on rows with
    # RCUR=1; RDIM records rows that render dimmed when not under the cursor.
    local dim_on=$'\e[2m' dim_off=$'\e[0m'
    local title tline max_w=0
    for (( i=1; i<=${#srcs[@]}; i++ )); do
      title="${titles[$i]}"
      [[ -n "$title" ]] || title="${srcs[$i]##*/}"
      (( ${#title} > max_w )) && max_w=${#title}
    done
    (( max_w < 12 )) && max_w=12
    local -a ROWS=() RCUR=() RSRC=() RTITLE=() RDIM=()
    for (( i=1; i<=${#srcs[@]}; i++ )); do
      # Show the curated title (+flag); fall back to the model basename for
      # legacy blocks that carry no title line. Left-pad titles so the
      # '// tags' column is aligned across rows.
      title="${titles[$i]}"
      [[ -n "$title" ]] || title="${srcs[$i]##*/}"
      tline=$(printf '  %-*s  // %s' "$max_w" "$title" "${tags[$i]}")
      ROWS+=( "$tline" ); RCUR+=( 1 ); RSRC+=( "${srcs[$i]}" ); RTITLE+=( "$title" ); RDIM+=( 0 )
      if [[ -n "${descs[$i]}" ]]; then
        ROWS+=( "    ${descs[$i]}" ); RCUR+=( 0 ); RSRC+=( "" ); RTITLE+=( "" ); RDIM+=( 1 )
      fi
    done

    if (( ${#srcs[@]} == 0 )); then
      ROWS+=( "  No more hand picked models available" ); RCUR+=( 0 ); RSRC+=( "" ); RTITLE+=( "" ); RDIM+=( 1 )
    fi
    ROWS+=( "  ──────────────────────────────────────────" ); RCUR+=( 0 ); RSRC+=( "" ); RTITLE+=( "" ); RDIM+=( 1 )
    ROWS+=( "  Custom (paste HuggingFace ID)…" ); RCUR+=( 1 ); RSRC+=( "__custom__" ); RTITLE+=( "" ); RDIM+=( 0 )
    ROWS+=( "  Open models folder" ); RCUR+=( 1 ); RSRC+=( "__openhub__" ); RTITLE+=( "" ); RDIM+=( 0 )
    ROWS+=( "  Back to Top" ); RCUR+=( 1 ); RSRC+=( "__back__" ); RTITLE+=( "" ); RDIM+=( 0 )

    # If any "t3" shorthand is shown, explain it on the bottom line.
    local has_t3=0
    for (( i=1; i<=${#tags[@]}; i++ )); do
      [[ "${tags[$i]}" == *t3* ]] && { has_t3=1; break; }
    done

    # ---- Terminal/state locals for the key-driven menu.
    local term_lines=${LINES:-24}
    (( term_lines < 8 )) && term_lines=24
    local vis=$(( term_lines - 7 ))
    (( vis < 1 )) && vis=1
    local width=${COLUMNS:-80}
    (( width < 40 )) && width=80
    local cursor=0 scroll=0 drawn=0 nlines=0 quit=0
    local up1=$'\e'[A up2=$'\e'OA down1=$'\e'[B down2=$'\e'OB
    local footer="↑/↓ nav • enter select • esc back"
    if (( has_t3 )); then
      footer="$footer  •  t3 = text, tools, thinking"
    fi

    local k
    for (( k=1; k<=${#RCUR[@]}; k++ )); do
      (( RCUR[$k] )) && { cursor=$(( k - 1 )); break; }
    done

    _D_scroll_cursor() {
      local n=${#ROWS[@]} max=$(( n - vis ))
      (( max < 0 )) && max=0
      (( scroll > max )) && scroll=$max
      if (( cursor < scroll )); then
        scroll=$cursor
      elif (( cursor >= scroll + vis )); then
        scroll=$(( cursor - vis + 1 ))
      fi
      (( scroll < 0 )) && scroll=0
    }
    _D_render() {
      if (( drawn )); then
        print -n -- "\033[${nlines}A\033[J"
      fi
      local -a out=()
      out+=( $'\e[1;35mDownload new model:\e[0m' )
      local n=${#ROWS[@]} end=$(( scroll + vis )) j line
      (( end > n )) && end=n
      for (( j=scroll; j<end; j++ )); do
        line="${ROWS[$((j+1))]}"
        if (( j == cursor )); then
          out+=( $'\e[1;36m>'"${line:1}"$'\e[0m' )
        elif (( RDIM[$((j+1))] )); then
          out+=( "${dim_on}${line}${dim_off}" )
        else
          out+=( "$line" )
        fi
      done
      out+=( $'\e[2m'"${footer:0:$(( width - 1 ))}"$'\e[0m' )
      nlines=0
      for line in "${out[@]}"; do
        print -n -- "$line\033[K\n"
        (( nlines++ ))
      done
      drawn=1
    }
    _D_clear() {
      if (( drawn )); then
        print -n -- "\033[${nlines}A\033[J"
        drawn=0
      fi
    }
    _D_move() {
      local delta="$1" n=${#ROWS[@]} new=$cursor guard=$cursor
      while true; do
        new=$(( new + delta ))
        (( new < 0 )) && new=$(( n - 1 ))
        (( new >= n )) && new=0
        if (( RCUR[$((new+1))] )); then
          cursor=$new
          break
        fi
        (( new == guard )) && break
      done
      _D_scroll_cursor
    }
    _D_do_download() {
      local sub="$1" title="$2" model="" ok=1
      # A Ministral block carries two ids ('instruct & reasoning'); download both.
      local -a dl=( ${(s: & :)sub} )
      if ! _ymlx_hf_has_token && (( _YMLX_HF_SKIPPED == 0 )); then
        if ! _ymlx_hf_setup; then
          _YMLX_HF_SKIPPED=1
        fi
      fi
      echo
      gum style --foreground 212 --bold "Downloading $title"
      echo "(progress will stream below — Ctrl-C to abort)"
      echo
      for model in "${dl[@]}"; do
        echo "  ▶ $model"
        if ! uvx --from mlx-vlm python3 -c "from mlx_vlm.utils import load; load('$model')"; then
          ok=0
        fi
      done
      if (( ok )); then
        echo
        gum style --foreground 42 "✓ Downloaded: $title"
        echo
        if gum confirm "Start ${dl[1]} now?"; then
          _ymlx_launch "${dl[1]}"
        fi
      else
        echo
        gum style --foreground 196 "✗ Download failed or cancelled."
      fi
      _ymlx_pause
    }
    _D_activate() {
      local r=$(( cursor + 1 ))
      (( RCUR[$r] )) || return
      _D_clear
      local src="${RSRC[$r]}" model=""
      if [[ "$src" == "__custom__" ]]; then
        model=$(gum input --placeholder "e.g. mlx-community/Ministral-3-3B-Instruct-2512-4bit" --prompt "Model: ")
        [[ -n "$model" ]] && { _D_do_download "$model" "$model"; quit=1; }
      elif [[ "$src" == "__back__" ]]; then
        quit=1
      elif [[ "$src" == "__openhub__" ]]; then
        _D_clear
        open "$hub_dir"
      else
        _D_do_download "$src" "${RTITLE[$r]}"
        quit=1
      fi
    }

    stty -ixon 2>/dev/null
    _D_render
    while true; do
      _ymlx_main_read_key
      local key="$_YMLX_MENU_KEY"
      if [[ -z "$key" ]]; then
        _D_clear
        return
      fi
      if [[ "$key" == "$up1" || "$key" == "$up2" ]]; then
        _D_move -1; _D_render
      elif [[ "$key" == "$down1" || "$key" == "$down2" ]]; then
        _D_move 1; _D_render
      elif [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
        _D_activate
        if (( quit )); then
          _D_clear
          return
        fi
        _D_render
      elif [[ "$key" == $'\x11' || "$key" == $'\e' ]]; then
        _D_clear
        return
      fi
    done
  }

  _ymlx_chat_history_menu() {
    # Key-driven menu mirroring the main menu. enter = per-chat actions,
    # ^d deletes the highlighted chat, s = search, o = open chat folder,
    # esc/^q = back to main menu.
    local -a _H_LINES=() _H_FILES=()
    local _H_CURSOR=0 _H_SCROLL=0 _H_DRAWN=0 _H_NLINES=0 _H_VIS _H_WIDTH
    local _H_QUIT=0
    local _up1=$'\e'[A _up2=$'\e'OA _down1=$'\e'[B _down2=$'\e'OB
    local _term_lines=${LINES:-24}
    (( _term_lines < 8 )) && _term_lines=24
    _H_VIS=$(( _term_lines - 7 ))
    (( _H_VIS < 1 )) && _H_VIS=1
    _H_WIDTH=${COLUMNS:-80}
    (( _H_WIDTH < 40 )) && _H_WIDTH=80

    _H_name_of() {
      local f="$1" n
      n=$(sed -n 's/^# Name: //p' "$f" | head -n1)
      [[ -z "$n" ]] && n=$(sed -n 's/^# Chat with //p' "$f" | head -n1 | sed 's/ on :[0-9]*$//')
      [[ -z "$n" ]] && n="${f:t:r}"
      print -r -- "$n"
    }

    _H_build() {
      local f friendly started msgs kbytes
      local -a chat_files=( "$chat_dir"/*.txt(N) )
      local -a sorted_files=( ${(On)chat_files} )
      _H_LINES=(); _H_FILES=()
      for f in "${sorted_files[@]}"; do
        friendly=$(_H_name_of "$f")
        started=$(sed -n 's/^# Started: //p' "$f" | head -n1)
        [[ -z "$started" ]] && started="${f:t:r}"
        msgs=$(grep -cE '^(you|assistant)> ' "$f")
        kbytes=$(awk '{s+=length($0)+1} END{printf "%.0f", s/1024}' "$f")
        (( kbytes < 1 )) && kbytes=1
        _H_LINES+=("$friendly  —  $started  · $msgs msgs · ${kbytes}KB")
        _H_FILES+=("$f")
      done
      if (( ${#_H_LINES[@]} == 0 )); then
        _H_LINES+=("No chats yet.")
      fi
      _H_LINES+=("──────────────" "Clear history")
      _H_LINES+=("Open chat folder" "Back to Top")
      (( _H_CURSOR >= ${#_H_LINES[@]} )) && _H_CURSOR=$(( ${#_H_LINES[@]} - 1 ))
      (( _H_CURSOR < 0 )) && _H_CURSOR=0
      _H_scroll_cursor
    }

    _H_scroll_cursor() {
      local n=${#_H_LINES[@]} max=$(( n - _H_VIS ))
      (( max < 0 )) && max=0
      (( _H_SCROLL > max )) && _H_SCROLL=$max
      if (( _H_CURSOR < _H_SCROLL )); then
        _H_SCROLL=$_H_CURSOR
      elif (( _H_CURSOR >= _H_SCROLL + _H_VIS )); then
        _H_SCROLL=$(( _H_CURSOR - _H_VIS + 1 ))
      fi
      (( _H_SCROLL < 0 )) && _H_SCROLL=0
    }

    _H_render() {
      if (( _H_DRAWN )); then
        print -n -- "\033[${_H_NLINES}A\033[J"
      fi
      local -a out=()
      out+=( $'\e[1;35mChat History:\e[0m  (enter actions • esc back)' )
      local n=${#_H_LINES[@]} end=$(( _H_SCROLL + _H_VIS ))
      (( end > n )) && end=n
      local i idx line prefix sep
      for (( i=_H_SCROLL; i<end; i++ )); do
        idx=$i
        line="${_H_LINES[$((idx+1))]}"
        sep=0
        [[ "$line" == "──────────────" ]] && sep=1
        prefix="  "
        (( idx == _H_CURSOR )) && prefix="> "
        if (( sep )); then
          out+=( $'\e[2m'"$line"$'\e[0m' )
        elif (( idx == _H_CURSOR )); then
          out+=( $'\e[1;36m'"$prefix$line"$'\e[0m' )
        else
          out+=( "$prefix$line" )
        fi
      done
      local foot="↑/↓ nav • enter actions • ^d delete • s search • o chat folder • esc back"
      out+=( $'\e[2m'"${foot:0:$(( _H_WIDTH - 1 ))}"$'\e[0m' )
      _H_NLINES=0
      for line in "${out[@]}"; do
        print -n -- "$line\033[K\n"
        (( _H_NLINES++ ))
      done
      _H_DRAWN=1
    }

    _H_clear() {
      if (( _H_DRAWN )); then
        print -n -- "\033[${_H_NLINES}A\033[J"
        _H_DRAWN=0
      fi
    }

    _H_move() {
      local delta="$1" n=${#_H_LINES[@]} new=$_H_CURSOR guard=$_H_CURSOR
      while true; do
        new=$(( new + delta ))
        (( new < 0 )) && new=$(( n - 1 ))
        (( new >= n )) && new=0
        if [[ "${_H_LINES[$((new+1))]}" != "──────────────" ]]; then
          _H_CURSOR=$new
          break
        fi
        (( new == guard )) && break
      done
      _H_scroll_cursor
    }

    _H_delete() {
      local idx=$(( _H_CURSOR + 1 ))
      local file="${_H_FILES[$idx]}"
      [[ -n "$file" && -f "$file" ]] || return
      _H_clear
      if gum confirm "Delete this chat?\n${_H_LINES[$idx]}"; then
        rm -f -- "$file"
        echo "Deleted."
      else
        echo
      fi
      _ymlx_pause
      _H_build; _H_render
    }

    _H_export() {
      local file="$1" mode="${2:-}"
      local md
      md=$( {
        echo "# Chat: $(_H_name_of "$file")"
        echo
        sed -E '/^#[[:space:]]/d; /^\(history cleared\)/d' "$file" \
          | sed -E 's/^you> /**You:** /; s/^assistant> /**Assistant:** /'
      } )
      if [[ "$mode" == "copy" ]]; then
        _H_clear
        if printf '%s' "$md" | pbcopy 2>/dev/null; then
          echo "Copied chat to clipboard (Markdown)."
        else
          echo "Clipboard copy failed (pbcopy unavailable)."
        fi
        _ymlx_pause
        _H_render
        return
      fi
      local out="$chat_dir/${file:t:r}.md"
      _H_clear
      printf '%s\n' "$md" > "$out"
      echo "Exported to: $out"
      if gum confirm "Open the exported file?"; then
        open "$out" 2>/dev/null
      fi
      _ymlx_pause
      _H_render
    }

    _H_rename() {
      local file="$1" cur new
      cur=$(_H_name_of "$file")
      _H_clear
      new=$(gum input --placeholder "New name for this chat" --value "$cur")
      if [[ -n "$new" ]]; then
        python3 - "$file" "$new" <<'PY'
import sys
f, nn = sys.argv[1], sys.argv[2]
lines = open(f).read().splitlines()
out, done = [], False
for ln in lines:
    if ln.startswith("# Name: "):
        out.append("# Name: " + nn); done = True; continue
    if not done and ln.startswith("# Chat with "):
        out.append("# Name: " + nn); done = True
    out.append(ln)
if not done:
    out.insert(0, "# Name: " + nn)
open(f, "w").write("\n".join(out) + "\n")
PY
        echo "Renamed chat."
      fi
      _ymlx_pause
    }

    _H_resume() {
      local idx=$(( _H_CURSOR + 1 ))
      local file="${_H_FILES[$idx]}"
      [[ -n "$file" && -f "$file" ]] || return
      local model=$(sed -n 's/^# Model: //p' "$file" | head -n1)
      if [[ -z "$model" ]]; then
        _H_clear
        gum style --foreground 196 "Can't determine the model for this chat (missing '# Model:' header)."
        _ymlx_pause
        _H_render
        return
      fi
      local port="" pid _p _pt _m
      while IFS=$'\t' read -r _p _pt _m; do
        [[ "$_m" == "$model" ]] && { port="$_pt"; break; }
      done < <(_ymlx_running)
      _H_clear
      if [[ -z "$port" ]]; then
        gum style --foreground 212 --bold "Continuing chat: $(_ymlx_display_name "$model")"
        echo "The model isn't running — starting it first, then resuming the conversation."
        if ! _ymlx_launch "$model"; then
          _ymlx_pause
          _H_render
          return
        fi
        port=11500
      fi
      _ymlx_chat_repl "$model" "$port" "$file"
      _H_render
    }

    _H_search() {
      _H_clear
      local q=$(gum input --placeholder "Search chats (case-insensitive, regex ok)…")
      if [[ -z "$q" ]]; then
        _H_render
        return
      fi
      local -a results=() rfiles=() rlines=()
      local f friendly ln ctx hit
      for f in "$chat_dir"/*.txt(N); do
        friendly=$(_H_name_of "$f")
        while IFS= read -r hit; do
          ln="${hit%%:*}"
          ctx="${hit#*:}"
          results+=("$friendly  @$ln  —  $ctx")
          rfiles+=("$f"); rlines+=("$ln")
        done < <(grep -n -i -E -- "$q" "$f" 2>/dev/null)
      done
      if (( ${#results[@]} == 0 )); then
        echo "No matches for: $q"
        _ymlx_pause
        _H_render
        return
      fi
      local pick=$(printf "%s\n" "${results[@]}" | gum choose --header "Search results for: $q" --height 16)
      if [[ -n "$pick" ]]; then
        local j
        for (( j=1; j<=${#results[@]}; j++ )); do
          [[ "${results[$j]}" == "$pick" ]] && { gum pager < "${rfiles[$j]}"; break; }
        done
      fi
      _H_render
    }

    _H_activate() {
      local idx=$(( _H_CURSOR + 1 ))
      local line="${_H_LINES[$idx]}" file="${_H_FILES[$idx]}"
      if [[ "$line" == "Clear history" ]]; then
        _H_clear
        if gum confirm "Delete all chat history?"; then
          rm -f "$chat_dir"/*.txt(N)
          echo "Chat history cleared."
        else
          echo
        fi
        _ymlx_pause
        _H_build; _H_render
        return
      fi
      if [[ "$line" == "Back to Top" ]]; then
        _H_clear
        _H_QUIT=1
        return
      fi
      if [[ "$line" == "Open chat folder" ]]; then
        _H_clear; _ymlx_open_chat_folder; _H_render
        return
      fi
      if [[ "$line" == "No chats yet." ]]; then
        return
      fi
      [[ -n "$file" && -f "$file" ]] || return
      local act=$(printf "View\nResume this chat\nCopy to clipboard\nRename\nDelete permanently\nCancel" | gum choose --header "$(_H_name_of "$file")" --height 10)
      [[ -z "$act" || "$act" == "Cancel" ]] && { _H_render; return; }
      case "$act" in
        "View") _H_clear; gum pager < "$file"; _H_render ;;
        "Resume this chat") _H_resume ;;
        "Copy to clipboard") _H_export "$file" copy ;;
        "Rename") _H_rename "$file"; _H_build; _H_render ;;
        "Delete permanently")
          _H_clear
          if gum confirm "Permanently delete this chat? (no undo)"; then
            rm -f -- "$file"; echo "Deleted permanently."
          else
            echo
          fi
          _ymlx_pause
          _H_build; _H_render
          ;;
      esac
    }

    stty -ixon 2>/dev/null
    _H_build
    _H_render
    while true; do
      _ymlx_main_read_key
      local key="$_YMLX_MENU_KEY"
      if [[ "$key" == "$_up1" || "$key" == "$_up2" ]]; then
        _H_move -1; _H_render
      elif [[ "$key" == "$_down1" || "$key" == "$_down2" ]]; then
        _H_move 1; _H_render
      elif [[ "$key" == $'\n' || "$key" == $'\r' ]]; then
        _H_activate
        if (( _H_QUIT )); then
          _H_clear
          return
        fi
      elif [[ "$key" == $'\x04' ]]; then
        _H_delete
      elif [[ "$key" == "s" || "$key" == "S" || "$key" == "/" ]]; then
        _H_search
      elif [[ "$key" == "o" || "$key" == "O" ]]; then
        _H_clear; _ymlx_open_chat_folder; _H_render
      elif [[ "$key" == $'\x11' || "$key" == $'\e' || -z "$key" ]]; then
        _H_clear
        return
      fi
    done
  }
  _ymlx_main_build() {
    local pid port model models m friendly rport think_suffix display first_running_idx=-1 sibfull
    _YMLX_MENU_LINES=()
    _YMLX_MENU_KINDS=()
    _YMLX_MENU_MODELS=()
    _YMLX_MENU_PORTS=()
    _YMLX_MENU_ACTIONS=()
    _YMLX_MENU_PAIRS=()
    typeset -A running_for_model
    while IFS=$'\t' read -r pid port model; do
      [[ -z "$pid" ]] && continue
      running_for_model[$model]="$pid"$'\t'"$port"
    done < <(_ymlx_running)

    _YMLX_MENU_NO_MODELS=0
    models=$(ls "$hub_dir" 2>/dev/null | grep '^models--' | sed 's/models--//' | sed 's/--/\//g')
    if [[ -z "$models" ]]; then
      _YMLX_MENU_NO_MODELS=1
      _YMLX_MENU_LINES=( "Download your first model" "──────────────────────" "Chat history" "──────────────────────" "Basic settings" "Advanced settings" "──────────────────────" "Stop & quit" )
      _YMLX_MENU_KINDS=( "action" "separator" "action" "separator" "action" "action" "separator" "action" )
      _YMLX_MENU_MODELS=( "" "" "" "" "" "" "" "" )
      _YMLX_MENU_PORTS=( "" "" "" "" "" "" "" "" )
      _YMLX_MENU_ACTIONS=( "download" "" "history" "" "basic" "advanced" "" "quit" )
      if [[ -n "$_YMLX_UPDATE_NEW" ]]; then
        _YMLX_MENU_LINES=( "Update to latest version" "${_YMLX_MENU_LINES[@]}" )
        _YMLX_MENU_KINDS=( "action" "${_YMLX_MENU_KINDS[@]}" )
        _YMLX_MENU_ACTIONS=( "update" "${_YMLX_MENU_ACTIONS[@]}" )
        _YMLX_MENU_MODELS=( "" "${_YMLX_MENU_MODELS[@]}" )
        _YMLX_MENU_PORTS=( "" "${_YMLX_MENU_PORTS[@]}" )
      fi
    else
      # Append one menu row for a collapsed Ministral Instruct+Reasoning pair.
      # Shows the base name; only one half is active at a time (running variant
      # wins, else the stored default, else Instruct). Never runs both.
      _ymlx_add_ministral_row() {
        local ins="$1" rea="$2" pref="" rp disp base
        local active="$ins"
        if [[ -n "${running_for_model[$rea]}" ]]; then
          active="$rea"
        fi
        if [[ -z "${running_for_model[$ins]}" && -z "${running_for_model[$rea]}" ]]; then
          pref="$(cat "$state_dir/ministral-default" 2>/dev/null)"
          [[ "$pref" == "$rea" ]] && active="$rea"
        fi
        base=$(_ymlx_ministral_base "$active")
        if [[ -n "${running_for_model[$active]}" ]]; then
          rport="${running_for_model[$active]##*	}"
          think_suffix=""
          [[ "$YMLX_QUICK_THINKING" == "on" ]] && think_suffix=" thinking"
          [[ "$YMLX_QUICK_THINKING" == "off" ]] && think_suffix=" thinking off"
          display="● $base$think_suffix"
          _YMLX_MENU_LINES+=( "$display" )
          _YMLX_MENU_KINDS+=( "model" )
          _YMLX_MENU_MODELS+=( "$active" )
          _YMLX_MENU_PORTS+=( "$rport" )
          _YMLX_MENU_ACTIONS+=( "" )
          _YMLX_MENU_PAIRS+=( "$ins"$'\t'"$rea" )
          (( first_running_idx < 0 )) && first_running_idx=$(( ${#_YMLX_MENU_LINES[@]} - 1 ))
        else
          _YMLX_MENU_LINES+=( "$base" )
          _YMLX_MENU_KINDS+=( "model" )
          _YMLX_MENU_MODELS+=( "$active" )
          _YMLX_MENU_PORTS+=( "" )
          _YMLX_MENU_ACTIONS+=( "" )
          _YMLX_MENU_PAIRS+=( "$ins"$'\t'"$rea" )
        fi
      }

      local -a downloaded=( ${(f)models} )
      typeset -A dlset handled
      local mm
      for mm in "${downloaded[@]}"; do dlset[$mm]=1; done
      for m in "${downloaded[@]}"; do
        # Collapse a Ministral pair into a single row (handled via Instruct).
        if [[ "${m##*/}" == *-Instruct-* ]]; then
          sibfull=$(_ymlx_ministral_sibling "$m")
          if [[ -n "${dlset[$sibfull]}" ]]; then
            handled[$sibfull]=1
            _ymlx_add_ministral_row "$m" "$sibfull"
            continue
          fi
        fi
        [[ -n "${handled[$m]}" ]] && continue
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
          _YMLX_MENU_PAIRS+=( "" )
          (( first_running_idx < 0 )) && first_running_idx=$(( ${#_YMLX_MENU_LINES[@]} - 1 ))
        else
          _YMLX_MENU_LINES+=( "$friendly" )
          _YMLX_MENU_KINDS+=( "model" )
          _YMLX_MENU_MODELS+=( "$m" )
          _YMLX_MENU_PORTS+=( "" )
          _YMLX_MENU_ACTIONS+=( "" )
          _YMLX_MENU_PAIRS+=( "" )
        fi
      done
      _YMLX_MENU_LINES+=( "──────────────────────" )
      _YMLX_MENU_KINDS+=( "separator" )
      _YMLX_MENU_MODELS+=( "" ); _YMLX_MENU_PORTS+=( "" ); _YMLX_MENU_ACTIONS+=( "" )
      if [[ -n "$_YMLX_UPDATE_NEW" ]]; then
        _YMLX_MENU_LINES+=( "Update to latest version" )
        _YMLX_MENU_KINDS+=( "action" )
        _YMLX_MENU_MODELS+=( "" ); _YMLX_MENU_PORTS+=( "" ); _YMLX_MENU_ACTIONS+=( "update" )
      fi
      # Chat history group
      _YMLX_MENU_LINES+=( "Chat history" )
      _YMLX_MENU_KINDS+=( "action" )
      _YMLX_MENU_MODELS+=( "" ); _YMLX_MENU_PORTS+=( "" ); _YMLX_MENU_ACTIONS+=( "history" )

      # Settings group
      _YMLX_MENU_LINES+=( "──────────────────────" )
      _YMLX_MENU_KINDS+=( "separator" )
      _YMLX_MENU_MODELS+=( "" ); _YMLX_MENU_PORTS+=( "" ); _YMLX_MENU_ACTIONS+=( "" )
      _YMLX_MENU_LINES+=( "Basic settings" "Advanced settings" "Download new model" )
      _YMLX_MENU_KINDS+=( "action" "action" "action" )
      _YMLX_MENU_MODELS+=( "" "" "" ); _YMLX_MENU_PORTS+=( "" "" "" )
      _YMLX_MENU_ACTIONS+=( "basic" "advanced" "download" )

      # Lifecycle group
      _YMLX_MENU_LINES+=( "──────────────────────" )
      _YMLX_MENU_KINDS+=( "separator" )
      _YMLX_MENU_MODELS+=( "" ); _YMLX_MENU_PORTS+=( "" ); _YMLX_MENU_ACTIONS+=( "" )
      _YMLX_MENU_LINES+=( "Restart & refresh" "Stop & quit" )
      _YMLX_MENU_KINDS+=( "action" "action" )
      _YMLX_MENU_MODELS+=( "" "" ); _YMLX_MENU_PORTS+=( "" "" )
      _YMLX_MENU_ACTIONS+=( "restart" "quit" )
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
      footer_text="↓↑ navigate • enter submit/start • tab toggle thinking • ^s stop server • ^d delete • ^q quit"
    else
      footer_text="↓↑ navigate • enter submit/start • ^d delete • ^q quit"
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

  _ymlx_main_header() {
    gum style --foreground 212 --bold "▌▌ YMLX"
    gum style --foreground 244 "Runs an MLX model behind an OpenAI-compatible REST API at localhost:11500"
    if [[ -n "$_YMLX_UPDATE_NEW" && -n "$_YMLX_UPDATE_INSTALLED" ]]; then
      gum style --foreground 226 --bold "▲ Update available: $_YMLX_UPDATE_INSTALLED → $_YMLX_UPDATE_NEW"
    fi
  }

  _ymlx_main_full_render() {
    print -n -- "\033[2J\033[H"
    _YMLX_MENU_DRAWN=0
    echo
    _ymlx_main_header
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
    local idx=$(( _YMLX_MENU_CURSOR + 1 ))
    local kind="${_YMLX_MENU_KINDS[$idx]}"
    [[ "$kind" != "model" ]] && return
    local pair="${_YMLX_MENU_PAIRS[$idx]}"
    if [[ -n "$pair" ]]; then
      # Ministral: swap between the Instruct and Reasoning halves. Never run
      # both at once — stop whichever is up and launch the other, or just flip
      # the stored default when neither is running.
      local ins="${pair%%$'\t'*}" rea="${pair##*$'\t'}"
      local cur="${_YMLX_MENU_MODELS[$idx]}"
      local other="$ins"; [[ "$cur" == "$ins" ]] && other="$rea"
      local up="" pid port model
      while IFS=$'\t' read -r pid port model; do
        [[ -n "$pid" && ( "$model" == "$ins" || "$model" == "$rea" ) ]] && { up=1; kill "$pid" 2>/dev/null; _ymlx_drop "$pid"; }
      done < <(_ymlx_running)
      print -r -- "$other" > "$state_dir/ministral-default"
      _ymlx_main_clear
      if [[ -n "$up" ]]; then
        local i
        for i in {1..40}; do
          _ymlx_port_free 11500 && break
          sleep 0.2
        done
        echo "Switching to $(_ymlx_ministral_base "$other")…"
        _ymlx_launch "$other"
      else
        echo "Ministral: next start uses $(_ymlx_ministral_base "$other")."
      fi
      _ymlx_pause
      _ymlx_main_rebuild_preserving
      return
    fi
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
    _ymlx_pause
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
    # A Ministral pair should be removed as a whole (both halves).
    local pair="${_YMLX_MENU_PAIRS[$idx]}"
    local -a del=( "$model" )
    if [[ -n "$pair" ]]; then
      local ins="${pair%%$'\t'*}" rea="${pair##*$'\t'}"
      del=( "$ins" "$rea" )
    fi
    _ymlx_main_clear
    local m folder pathdel=()
    for m in "${del[@]}"; do
      pathdel+=( "$hub_dir/models--${m//\//--}" )
    done
    local missing=0
    for folder in "${pathdel[@]}"; do
      [[ -d "$folder" ]] || missing=1
    done
    if (( missing )); then
      echo "Folder not found."
      _ymlx_pause
    else
      local warn="" name="${del[1]}"
      [[ -n "$pair" ]] && name="${del[1]} + ${del[2]}"
      [[ -n "$port" ]] && warn=" (running server will be stopped first)"
      if gum confirm "Remove $name from $hub_dir?$warn"; then
        local pid _p _pt _mm skip
        while IFS=$'\t' read -r _p _pt _mm; do
          skip=""
          for m in "${del[@]}"; do
            [[ "$_mm" == "$m" ]] && { skip=1; break; }
          done
          if [[ -n "$_p" && -n "$skip" ]]; then
            kill "$_p" 2>/dev/null && _ymlx_drop "$_p"
          fi
        done < <(_ymlx_running)
        for folder in "${pathdel[@]}"; do
          rm -rf "$folder"
        done
        rm -f "$state_dir/ministral-default"
        echo "Removed: $name"
        _ymlx_pause
      fi
    fi
    _ymlx_main_rebuild_full
  }

  # "Update to latest version" from the menu — adapts to how ymlx was installed:
  # a git clone pulls + re-runs install.sh; a pi-managed package tells the user
  # to use `pi update`; anything else (e.g. the stable copy from /ymlx-setup) asks
  # for a re-install. Re-checks afterwards so the banner clears once current.
  _ymlx_do_update() {
    _ymlx_main_clear
    gum style --foreground 212 --bold "Updating ymlx"
    if [[ -d "$_YMLX_SRC_DIR/.git" ]]; then
      echo "Pulling latest from git ($_YMLX_SRC_DIR):"
      if git -C "$_YMLX_SRC_DIR" pull --ff-only; then
        sh "$_YMLX_SRC_DIR/install.sh"
        echo
        gum style --foreground 82 --bold "ymlx updated — quit and re-run ymlx to use the new version."
        _ymlx_check_update
      else
        echo "git pull had problems — resolve conflicts in $_YMLX_SRC_DIR, then retry."
      fi
    elif [[ "$_YMLX_SRC_DIR" == "$HOME"/.pi/agent/git/* ]]; then
      echo "This install is managed by pi (a pi package). Update it from a terminal:"
      echo "  pi update --extensions"
      echo "then restart ymlx."
    else
      # Managed copy (installed via curl/install.sh, no .git). Fetch the
      # latest install.sh and re-run it with YMLX_FORCE=1 + YMLX_REF=main so it
      # re-downloads the newest source — a plain re-run of the copy's own
      # install.sh wouldn't refresh it (and an old one won't know the flag).
      echo "Refreshing managed copy from GitHub…"
      local up_sh="$state_dir/install-update.sh"
      if curl -fsSL --connect-timeout 3 --max-time 20 \
           "https://raw.githubusercontent.com/pavsefcik/ymlx/main/install.sh" \
           -o "$up_sh" 2>/dev/null; then
        if YMLX_FORCE=1 YMLX_REF=main sh "$up_sh"; then
          echo
          gum style --foreground 82 --bold "ymlx updated — restart ymlx to use the new version."
          _ymlx_check_update
        else
          echo "Update failed — check the install output above, then retry."
        fi
      else
        echo "Couldn't download the latest install.sh (offline?) — update aborted."
      fi
    fi
    _ymlx_pause
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
          _ymlx_pause
        else
          if _ymlx_launch "$model"; then
            _ymlx_chat_repl "$model" "11500"
          fi
        fi
      fi
    else
      case "$action" in
        update) _ymlx_do_update ;;
        download) _ymlx_download_menu ;;
        history) _ymlx_chat_history_menu ;;
        basic) _ymlx_basic_settings_menu ;;
        advanced) _ymlx_advanced_settings_menu ;;
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

  # Self-update notice: compare the installed version (VERSION file next to this
  # script) with the latest on GitHub. Interactive menu only — headless runs
  # (run/stop/status) skip the network call. Short timeout, mirrors the
  # curated-list fetch; offline = no banner.
  _ymlx_check_update() {
    (( $# == 0 )) || return 0
    local installed="$(<"$_YMLX_SRC_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$installed" ]] || return 0
    _YMLX_UPDATE_NEW=""
    _YMLX_UPDATE_INSTALLED=""
    local latest_file="$state_dir/latest-version" latest
    if curl -fsSL --connect-timeout 3 --max-time 5 "https://raw.githubusercontent.com/pavsefcik/ymlx/main/VERSION" -o "$latest_file" 2>/dev/null; then
      latest="$(tr -d '[:space:]' < "$latest_file")"
      if [[ -n "$latest" ]] && _ymlx_version_gt "$latest" "$installed"; then
        _YMLX_UPDATE_INSTALLED="$installed"
        _YMLX_UPDATE_NEW="$latest"
      fi
    fi
  }

  # Keep the mlx-vlm uv tool current. Interactive mode only, mirroring
  # _ymlx_check_update so headless run/stop/status stay offline and fast; and
  # skipped while a model server is running so an update never swaps the
  # binary under a live process. Uses `uv tool list --outdated`, which does
  # the index comparison itself (no manual version parsing, no sort -V, no
  # hardcoded minimum — LFM2 support landed back in 0.3.3; 0.7.0 only added
  # LFM2 DSpark / OptiQ loading, so "latest" is the right target).
  _ymlx_check_mlx_vlm_update() {
    (( $# == 0 )) || return 0
    command -v mlx_vlm.server >/dev/null 2>&1 || return 0
    _ymlx_running | grep -q . && return 0   # server up → defer until next start
    local out cur new
    out=$(uv tool list --outdated 2>/dev/null | awk '$1 == "mlx-vlm" && /latest:/ {print; exit}')
    [[ -n "$out" ]] || return 0            # current, or offline → nothing to do
    cur=$(print -r -- "$out" | awk '{print $2}')
    new=$(print -r -- "$out" | sed -n 's/.*\[latest: \([^]]*\)\].*/\1/p')
    echo
    print -u2 "ymlx: new mlx-vlm available: $cur → $new — updating…"
    if uv tool update mlx-vlm >/dev/null 2>&1; then
      local now
      now=$(uv tool list 2>/dev/null | awk '$1 == "mlx-vlm" {print $2; exit}')
      print -u2 "ymlx: mlx-vlm updated to ${now:-latest}."
    else
      print -u2 "ymlx: mlx-vlm update failed — retry with: uv tool update mlx-vlm"
    fi
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

  _ymlx_check_update "$@"

  clear
  echo
  _ymlx_main_header
  if ! _ymlx_hf_has_token; then
    gum style --foreground 244 "HF Hub: unauthenticated — downloads still work but are slower. Offer a token at the first download."
  fi
  _ymlx_check_mlx_vlm_update "$@"

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
