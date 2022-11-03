# Using serve-d with [Helix][1]
---

NOTE: Support for D is already in the master branch of Helix, so
if you build it from source, or install a release later than
22.08.1 (which as of this writing is the newest release available)
then you should be good to go, as long as serve-d is on your path.)
These instructiosn will become obsolete once the next release
of Helix is made.

At the moment configuration options are limited.

## The Easy Way

The easiest solution is just to build Helix from source and use it.
Please see the [directions][2] in the Helix repository for details.

## The Hard Way

It is recommended to pair this with Syntax support via the
[Tree-sitter plugin][3].

The following configuration can stanzas can be added to your
`languages.toml` file, following these  [directions][4].

```toml
[[grammar]]
name="d"
source={ git="https://github.com/gdamore/tree-sitter-d", rev="main" }

[[language]]
name="d"
language-server = { command = "serve-d" }
scope="source.d"
file-types=["d", "di", "dd"]
roots=["dub.json", "dub.sdl"]
indent={tab-width = 4, unit="    "}
```

### Copying Queries

Queries for highlighting, indentation, language injections, and
text objects are located in the [Helix repository][5]:

Those files can be downloaded and placed in your Helix runtime folder
in `${HELIX_RUNTIME}/queries/d`

[1]: https://helix-editor.com "Helix Web Site"
[2]: https://github.com/helix-editor/helix#installation "Helix Installation"
[3]: https://github.com/gdamore/tree-sitter-d/ "Tree-sitter Grammar for D"
[4]: https://docs.helix-editor.com/guides/adding_languages.html "Adding Languages to Helix"
[5]: https://github.com/helix-editor/helix/tree/master/runtime/queries/d "D syntax queries for Helix"
 
