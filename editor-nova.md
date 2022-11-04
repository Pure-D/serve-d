# Using serve-d with [Nova][1]
---

## Summary

An extension for Nova is [available][2] via the normal
extension facility.

Installing this will enable D support to work in Nova.

It will also enable syntax highlighting, folding, and
indentation features via the Tree-sitter [D grammar][4].

## Requirements

You will need a version of serve-d newer than **0.7.4**.
As of this moment, no such release exists, but if you
use a current nightly or build serve-d yourself, then it
should work fine.

## Configuration

If the `serve-d` binary is not in `/usr/local/bin`,
then you will need to set the path.  This can be done
in the **Extensions → Extension Library...** panel
by clicking the **Settings** tab for the *Serve-D* extension. 

Set the `Language Server Path` to the location where your
`serve-d` binary can be found.

[1]: https://nova.app "Nova Editor" 
[2]: https://extensions.panic.com/extensions/tech.staysail/tech.staysail.ServeD/ "Serve-D plugin for nova"
[3]: https://github.com/gdamore/tree-sitter-d/ "Tree-sitter Grammar for D"
 
