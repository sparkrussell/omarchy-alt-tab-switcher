-- luacheck config for the Hyprland Lua module.
--
-- switcher.lua runs inside Hyprland's embedded Lua with two interpreter-injected
-- globals: `hl` (the compositor API) and `o` (Omarchy's bind helper). Declare
-- them read-only so luacheck stops flagging them as undefined, while still
-- catching typos on any *other* undefined global.
std = "max"
read_globals = { "hl", "o" }

-- Line length is a style choice, not a regression; the prose comments wrap wide.
max_line_length = false
