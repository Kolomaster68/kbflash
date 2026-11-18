# kbflash for zsh: flash the keyboard when a terminal command takes a while.
#   KBFLASH_MIN     seconds a command must run before it flashes (default 30)
#   KBFLASH_IGNORE  programs that never flash (editors, pagers, agents, ssh...)
zmodload zsh/datetime
typeset -g _kbflash_t _kbflash_cmd
_kbflash_preexec() { _kbflash_t=$EPOCHSECONDS; _kbflash_cmd=${${(z)1}[1]} }
_kbflash_precmd() {
  local s=$?
  [[ -z $_kbflash_t ]] && return
  local took=$(( EPOCHSECONDS - _kbflash_t )); _kbflash_t=
  (( took < ${KBFLASH_MIN:-30} )) && return
  [[ " ${KBFLASH_IGNORE:-vi vim nvim nano emacs less more man ssh top htop btop watch tail tmux screen claude codex gemini} " == *" ${_kbflash_cmd:t} "* ]] && return
  ( "${KBFLASH_BIN:-$HOME/.local/bin/kbflash}" $( (( s )) && echo error || echo done ) >/dev/null 2>&1 & ) 
}
autoload -Uz add-zsh-hook
add-zsh-hook preexec _kbflash_preexec
add-zsh-hook precmd _kbflash_precmd
