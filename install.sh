#!/bin/sh
# kbflash installer.   ./install.sh              build it and choose what flashes it
#                      ./install.sh --yes        same, saying yes to everything
#                      ./install.sh --uninstall  remove it and everything it hooked up
set -e
cd "$(dirname "$0")"
BIN="${KBFLASH_BIN:-$HOME/.local/bin/kbflash}"
CONF="${KBFLASH_CONF:-$HOME/.config/kbflash}"
CLAUDE="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CODEX="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
MARK="# kbflash: flash the keyboard after long commands"

ask() { # ask "question" -> 0 for yes (the default)
  [ "$YES" = 1 ] && return 0
  printf '%s [Y/n] ' "$1"
  read -r a </dev/tty 2>/dev/null || a=y
  case "$a" in n*|N*) return 1 ;; *) return 0 ;; esac
}

claude_hooks() { # $1 = add | remove. Keeps every other hook; backs the file up first.
  [ "$1" = remove ] && [ ! -f "$CLAUDE" ] && return 0
  mkdir -p "$(dirname "$CLAUDE")"
  [ -f "$CLAUDE" ] && cp "$CLAUDE" "$CLAUDE.bak-kbflash"
  python3 - "$CLAUDE" "$BIN" "$1" <<'PY'
import json, os, sys
path, binary, mode = sys.argv[1:]
d = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
hooks = d.setdefault("hooks", {})
for event, pattern in {"Stop": "done", "Notification": "ask"}.items():
    groups = [g for g in hooks.get(event, [])
              if not any("kbflash" in h.get("command", "") for h in g.get("hooks", []))]
    if mode == "add":
        groups.append({"hooks": [{"type": "command", "command": f"{binary} {pattern} >/dev/null 2>&1 &"}]})
    if groups: hooks[event] = groups
    else: hooks.pop(event, None)
if not hooks: d.pop("hooks")
json.dump(d, open(path, "w"), indent=2)
PY
}

codex_notify() { # $1 = add | remove. Codex allows one notify program, so never replace someone else's.
  if [ "$1" = remove ]; then
    [ -f "$CODEX" ] && grep -v '^notify = \[".*kbflash' "$CODEX" > "$CODEX.tmp" && mv "$CODEX.tmp" "$CODEX"
    return 0
  fi
  mkdir -p "$(dirname "$CODEX")"; touch "$CODEX"
  if grep -q '^notify' "$CODEX"; then
    grep -q kbflash "$CODEX" || echo "    Codex already has a notify program. To use kbflash instead: notify = [\"$BIN\", \"done\"]"
  else
    cp "$CODEX" "$CODEX.bak-kbflash"
    { echo "notify = [\"$BIN\", \"done\"]"; cat "$CODEX.bak-kbflash"; } > "$CODEX" # top level, before any [table]
  fi
}

zsh_hook() { # $1 = add | remove
  if [ -f "$ZSHRC" ]; then grep -v "$MARK" "$ZSHRC" > "$ZSHRC.tmp" || true; mv "$ZSHRC.tmp" "$ZSHRC"; fi
  [ "$1" = add ] && echo "[ -f \"$CONF/kbflash.zsh\" ] && source \"$CONF/kbflash.zsh\"  $MARK" >> "$ZSHRC"
  return 0
}

if [ "$1" = --uninstall ]; then
  claude_hooks remove; codex_notify remove; zsh_hook remove
  rm -f "$BIN" "$CONF/kbflash.zsh"
  echo "kbflash removed, with its Claude Code hooks, Codex notify and zsh hook."
  echo "Your patterns are kept in $CONF/patterns."
  exit 0
fi
[ "$1" = --yes ] && YES=1

command -v clang >/dev/null || { echo "kbflash needs Apple's command line tools: xcode-select --install"; exit 1; }
mkdir -p "$(dirname "$BIN")" "$CONF"
clang -fobjc-arc -O2 kbflash.m -o "$BIN" -framework Foundation -framework IOKit \
  -F/System/Library/PrivateFrameworks -framework CoreBrightness
[ -f "$CONF/patterns" ] || cp extras/patterns "$CONF/patterns"
cp extras/kbflash.zsh "$CONF/kbflash.zsh"
echo "Built $BIN. Watch your keyboard..."
"$BIN" done

echo
echo "What should flash it?"
ask "  Claude Code: when it finishes, and when it needs you?" && claude_hooks add
if command -v codex >/dev/null || [ -d "$HOME/.codex" ] || [ -n "$CODEX_CONFIG" ]; then
  ask "  Codex: when it finishes a turn?" && codex_notify add
fi
case "$SHELL" in *zsh)
  ask "  Terminal: any command that runs longer than 30 seconds?" && zsh_hook add ;;
esac

echo
echo "Done. Change the flashes in $CONF/patterns (kbflash --list to see them)."
echo "Anything else can flash it too:  some-command; kbflash done   or   kbflash -- some-command"
