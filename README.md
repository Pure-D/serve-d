# serve-d [![Join on Discord](https://discordapp.com/api/guilds/242094594181955585/widget.png?style=shield)](https://discord.gg/Bstj9bx)

[Microsoft language server protocol](https://github.com/Microsoft/language-server-protocol) implementation for [D](https://dlang.org) using [workspace-d](https://github.com/Pure-D/workspace-d).

This program is basically a combination of workspace-d and most of [code-d](https://github.com/Pure-D/code-d).

The purpose of this project is to give every editor the same capabilities and editing features as code-d with even less code required on the editor side than with workspace-d due to a more widely available protocol.

This is pretty much another abstraction layer on top of workspace-d to simplify and speed up extension development as most of the editor extension can now be written in D.

## Installation

```
dub build
```

