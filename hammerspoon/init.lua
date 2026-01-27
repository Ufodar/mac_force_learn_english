-- Minimal bootstrap. If you already have your own ~/.hammerspoon/init.lua,
-- copy vocab_overlay.lua into ~/.hammerspoon/ and call:
--   require("vocab_overlay").start()
-- (Dock icon hiding is controlled by vocab_overlay.lua -> config.hideDockIcon)
pcall(function()
  require("vocab_overlay").start()
end)
