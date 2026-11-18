# kbflash

Flash a MacBook's keyboard backlight to get your attention — e.g. when Claude Code finishes or needs you. A keyboard-backlight take on [LogoLight](https://github.com/Ark0N/LogoLight), for MacBooks without the glowing lid logo.

- Keyboard already lit (≥ 50%): it dips off and back.
- Keyboard dark or dim: it pulses to 100% and off.
- Either way it ends on the brightness you had, and never changes your saved setting.

## Build

```sh
clang -fobjc-arc -O2 kbflash.m -o ~/bin/kbflash \
  -framework Foundation -F/System/Library/PrivateFrameworks -framework CoreBrightness
```

## Use

```sh
kbflash            # 3 flashes, 150 ms on / 150 ms off
kbflash 2 250 150  # flashes, on ms, off ms
```

### Claude Code hooks

In `~/.claude/settings.json`:

```json
"hooks": {
  "Stop": [{ "hooks": [{ "type": "command", "command": "$HOME/bin/kbflash 3 120 120 >/dev/null 2>&1 &" }] }],
  "Notification": [{ "hooks": [{ "type": "command", "command": "$HOME/bin/kbflash 2 250 150 >/dev/null 2>&1 &" }] }]
}
```

`Stop` fires when Claude finishes a reply; `Notification` when it needs input or permission.

## Caveats

- Uses CoreBrightness's private `KeyboardBrightnessClient`. A macOS update can break it. Tested on an M5 MacBook Pro, macOS 27.
- Hard to see in a bright room; no use with the lid closed or the display asleep.
- Only one flash runs at a time; a second request while one is running is skipped.
- The 50% "already bright" threshold is `BRIGHT` in `kbflash.m`.

## License

MIT
