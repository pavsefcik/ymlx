#!/usr/bin/env zsh
# Unit tests for the thinking classifier/spec in lib/ymlx-helpers.zsh.
# Hermetic: builds a throwaway HF hub fixture.
# Run:  zsh tests/test_helpers.zsh

emulate -L zsh
setopt no_unset

source "${0:A:h}/../lib/ymlx-helpers.zsh"

typeset -g fail=0

check() { # expected actual label
  if [[ "$1" != "$2" ]]; then
    print -u2 "FAIL: $3 — expected '$1', got '$2'"
    fail=1
  else
    print "ok: $3"
  fi
}

hub=$(mktemp -d)
trap 'rm -rf "$hub"' EXIT

mk() { # model-id model_type-or-empty
  local id="$1" mt="$2" dir="$hub/models--${1//\//--}/snapshots/abc"
  mkdir -p "$dir"
  [[ -n "$mt" ]] && print -r -- "{\"model_type\": \"$mt\"}" > "$dir/config.json"
}

mk "acme/Qwen3.5-9B" qwen3_5
mk "acme/Qwen3.6-MoE" qwen3_5_moe
mk "acme/gemma-4-12B" gemma4_unified
mk "acme/Ministral-3-8B-Reasoning-2512-4bit" mistral3
mk "acme/Ministral-3-8B-Instruct-2512-4bit" mistral3
mk "acme/LFM2.5-8B" lfm2_moe
mk "acme/SomeModel" ""                       # name fallback
mk "acme/Mystery-Qwen-X" ""                  # name fallback

check qwen "$(_ymlx_model_family acme/Qwen3.5-9B "$hub")" "qwen3_5 -> qwen"
check qwen "$(_ymlx_model_family acme/Qwen3.6-MoE "$hub")" "qwen3_5_moe -> qwen"
check gemma "$(_ymlx_model_family acme/gemma-4-12B "$hub")" "gemma4_unified -> gemma"
check ministral-reasoning "$(_ymlx_model_family acme/Ministral-3-8B-Reasoning-2512-4bit "$hub")" "mistral3 reasoning"
check ministral-instruct "$(_ymlx_model_family acme/Ministral-3-8B-Instruct-2512-4bit "$hub")" "mistral3 instruct"
check lfm "$(_ymlx_model_family acme/LFM2.5-8B "$hub")" "lfm2_moe -> lfm"
check generic "$(_ymlx_model_family acme/SomeModel "$hub")" "unknown -> generic"
check qwen "$(_ymlx_model_family acme/Mystery-Qwen-X "$hub")" "name fallback qwen"

check $'enable_thinking\tthink\t0' "$(_ymlx_thinking_spec acme/Qwen3.5-9B "$hub")" "qwen spec"
check $'enable_thinking\tchannel\t0' "$(_ymlx_thinking_spec acme/gemma-4-12B "$hub")" "gemma spec"
check $'variant\tbracket\t1' "$(_ymlx_thinking_spec acme/Ministral-3-8B-Reasoning-2512-4bit "$hub")" "ministral-r spec"
check $'variant\tnone\t0' "$(_ymlx_thinking_spec acme/Ministral-3-8B-Instruct-2512-4bit "$hub")" "ministral-i spec"
check $'none\tthink\t0' "$(_ymlx_thinking_spec acme/LFM2.5-8B "$hub")" "lfm spec"

# Launch flags: resolved --enable-thinking + Ministral markers.
YMLX_QUICK_THINKING=on
local -a flags
flags=( --max-tokens 2048 )
_ymlx_apply_launch_thinking flags acme/Ministral-3-8B-Reasoning-2512-4bit "$hub"
check "1" "$(( ${flags[(I)--enable-thinking]} > 0 ))" "ministral on: --enable-thinking added"
check "1" "$(( ${flags[(I)--thinking-start-token]} > 0 ))" "ministral on: start token added"
check "1" "$(( ${flags[(I)--thinking-end-token]} > 0 ))" "ministral on: end token added"

flags=( --max-tokens 2048 --enable-thinking )
YMLX_QUICK_THINKING=default
_ymlx_apply_launch_thinking flags acme/Qwen3.5-9B "$hub"
check "0" "$(( ${flags[(I)--enable-thinking]} > 0 ))" "qwen default: stale flag dropped"
check "0" "$(( ${flags[(I)--thinking-start-token]} > 0 ))" "qwen: no bracket markers"

exit $fail
