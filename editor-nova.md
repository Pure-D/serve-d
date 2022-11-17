# Using serve-d with [Nova][1]
---

## Summary

An extension for Nova called **D-Velop** is [available][2] via the normal
extension facility.  This extension utilizes serve-d for LSP functionality.

Installing this will enable D support to work in Nova.

It will also enable syntax highlighting, folding, and
indentation features via the Tree-sitter [D grammar][4].

## Requirements

**D-Velop** will offer to automatically download a suitable
version of serve-d, and by default will notify you when new
releases are available, and offer to update as appropriate.

You can use your own installation of serve-d as well, but
be advised that served version **0.8.0-beta.1 or newer** is
required to operate with the extension

[1]: https://nova.app "Nova Editor" 
[2]: https://extensions.panic.com/extensions/tech.staysail/tech.staysail.ServeD/ "Serve-D plugin for nova"
[3]: https://github.com/gdamore/tree-sitter-d/ "Tree-sitter Grammar for D"
 
