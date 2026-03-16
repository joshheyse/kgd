-- kgd.nvim plugin entry point
-- This file creates user commands but does NOT auto-connect.
-- Call require("kgd").setup() to connect.

if vim.g.loaded_kgd then return end
vim.g.loaded_kgd = true

vim.api.nvim_create_user_command("KgdStatus", function()
  local kgd = require("kgd")
  if not kgd.is_connected() then
    vim.notify("[kgd] not connected", vim.log.levels.WARN)
    return
  end
  kgd.status(function(status, err)
    if err then
      vim.notify("[kgd] " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format(
      "[kgd] clients=%d placements=%d images=%d terminal=%dx%d",
      status.clients or 0, status.placements or 0, status.images or 0,
      status.cols or 0, status.rows or 0
    ))
  end)
end, { desc = "Show kgd daemon status" })

vim.api.nvim_create_user_command("KgdDisconnect", function()
  require("kgd").disconnect()
  vim.notify("[kgd] disconnected")
end, { desc = "Disconnect from kgd daemon" })
