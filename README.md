# omarchy-alt-tab-switcher

A hold-to-preview Alt-Tab window switcher for [Omarchy](https://omarchy.org/) /
Hyprland: hold `ALT`, tap `TAB` to cycle, and a centered card shows **live
thumbnails** of every open window — including windows on other workspaces and
other monitors. Release `ALT` to switch.

No new packages: the key handling is Hyprland's own Lua config API, and the
overlay is a standalone [Quickshell](https://quickshell.org/) process using
`ScreencopyView` against each window's Wayland toplevel.

## Requirements

- Hyprland 0.56+ with the Lua config (Omarchy's `~/.config/hypr/*.lua` layout)
- Quickshell 0.3+ (`quickshell` package; ships with Omarchy)

## Install

```bash
git clone https://github.com/sparkrussell/omarchy-alt-tab-switcher.git ~/projects/omarchy-alt-tab-switcher
~/projects/omarchy-alt-tab-switcher/install.sh
```

The installer symlinks

| Repo file | Installed path |
|---|---|
| `hypr/switcher.lua` | `~/.config/hypr/switcher.lua` |
| `quickshell/omarchy-switcher/` | `~/.config/quickshell/omarchy-switcher/` |

and appends the loader lines to `~/.config/hypr/hyprland.lua`
(`require("hypr.switcher")`) and `~/.config/hypr/autostart.lua`
(`o.exec_on_start("qs -c omarchy-switcher -n -d")`). It is idempotent; existing
non-symlink files are moved to `*.bak.<timestamp>`.

Because the files are symlinks back into the repo, editing the repo is editing
the live config. Quickshell hot-reloads `shell.qml` on save; the Lua module
needs `hyprctl reload`.

## Keys

| Key | Action |
|---|---|
| `ALT + TAB` | Open the switcher / advance (first tap preselects the previous window) |
| `ALT + SHIFT + TAB` | Open backwards / step back |
| `ALT + →` / `ALT + ←` | Step forward / back |
| release `ALT`, or `RETURN` | Switch to the selected window |
| `ESC`, or `ALT + Q` | Cancel |
| mouse | Hover selects, click switches, click outside the card cancels |

Windows are ordered most-recently-used (Hyprland's `focus_history_id`), so a
quick `ALT+TAB` tap behaves like classic Alt-Tab. Hidden windows (e.g. swallowed
terminals) are skipped. An unattended switcher cancels itself after 10 s.

## Design

Two processes, talking over Hyprland's own IPC:

```
~/.config/hypr/switcher.lua                 ~/.config/quickshell/omarchy-switcher
  keybinds, submap, MRU list, selection       thumbnails, labels, theming
             |  hl.dsp.event("omarchy-switcher>>{json}")  ->  custom>> on socket2
             |  <-  hyprctl dispatch 'omarchy_switcher.pick("0x…")'
```

The Lua module is the single source of truth and performs the focus itself, so
**if the overlay process is not running, Alt-Tab still switches windows** — you
just lose the visuals.

Public Lua entry points (also usable from scripts or your own binds):

```bash
hyprctl dispatch 'omarchy_switcher.open(1)'      # open / advance
hyprctl dispatch 'omarchy_switcher.open(-1)'     # open backwards
hyprctl dispatch 'omarchy_switcher.step(1)'
hyprctl dispatch 'omarchy_switcher.commit()'
hyprctl dispatch 'omarchy_switcher.cancel()'
hyprctl dispatch 'omarchy_switcher.pick("0x55…")'
```

Theme colors are read live from
`~/.local/state/omarchy/current/theme/colors.toml`, so the card follows
`omarchy theme set`.

## Four Hyprland behaviors this works around

Verified against Hyprland v0.56.2 source; all four are why the bind flags look
the way they do.

1. **Release binds are matched against the submap that was active when the key
   went down** (`KeybindManager.cpp`, `submapAtPress`). `ALT` goes down before
   `ALT+TAB` enters the switcher submap, so a submap-scoped `Alt_L` release bind
   never matches — hence `submap_universal` plus a state check.
2. **`shadowKeybinds()` shadows every bind whose key is still held**, so
   triggering `ALT+TAB` shadows the `Alt_L` release bind. Only `global` and
   `transparent` binds are exempt — hence `transparent`.
3. **A consumed `ALT` release never reaches the focused client**, leaving apps
   believing `ALT` is stuck down — hence `non_consuming`.
4. **Hyprland refocuses a monitor's last window when a layer that held pointer
   focus unmaps** (`LayerSurface.cpp` `onUnmap`), which silently undid the
   switch. The target is therefore re-focused on the `layer.closed` event.

Also worth knowing: `hl.unbind` is not submap aware, so Omarchy's default
`ALT+TAB` binds must be removed *before* the submap registers its own; and
`HL.Timer` has no `stop()` — a oneshot is cancelled with `set_enabled(false)`.

## Uninstall

```bash
rm ~/.config/hypr/switcher.lua ~/.config/quickshell/omarchy-switcher
pkill -f 'qs -c omarchy-switcher'
```

Then delete the `require("hypr.switcher")` line from `~/.config/hypr/hyprland.lua`
and the `qs -c omarchy-switcher` line from `~/.config/hypr/autostart.lua`, and
run `hyprctl reload`. Omarchy's stock `ALT+TAB` bindings come back on reload.

## License

MIT — see [LICENSE](LICENSE). Contributions and forks welcome.
