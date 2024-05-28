# Using serve-d with [Zed][1]

---

Support for D including serve-d is included with the Zed "D" plugin.

This plugin can be installed using the "zed: extensions" command
or the `Zed ... Extensions ...` menu item.

The plugin will automatically download the most recent release of serve-d.

This also makes use of a [Tree-sitter grammar for D][2] so syntax highlighting
and related functionality is very fast, and of serve-d for other advanced
capabilities.

Various settings for serve-d can be made in either your global personal
settings, or in project specific settings.

The settings object is a JSON file, and serve-d can be added under the
"serve-d" member of the "lsp" top-level settings.
The binary can also be relocated if a custom binary should be used instead.

An example configuration:

```json
  "lsp": {
    "serve-d": {
      "settings": {
        "d": {
          "enableFormatting": false,
          "manyProjectsThreshold": 20
        },
        "dscanner": {
          "ignoredKeys": ["dscanner.style.long_line"]
        }
      },
      "binary": {
        "path": "/Users/garrett.damore/Projects/serve-d/serve-d"
      }
    }
  }
```

[1]: https://zed.dev "Zed Editor Web Site""
[2]: https://github.com/gdamore/tree-sitter-d/ "Tree-sitter Grammar for D"
