# Using serve-d with Lite-XL
---

Requirments:
    - lite-xl-lsp Plugin: https://github.com/lite-xl/lite-xl-lsp

Add the following to your user `init.lua` file (Access it quickly with `Core: Open User Module` command):

```lua
local lsp = require "plugins.lsp"

lsp.add_server {
  name = "serve-d",
  language = "d",
  file_patterns = { "%.d$" },
  command = { "serve-d" },
  incremental_changes = true,
}
```

