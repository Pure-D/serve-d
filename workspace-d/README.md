# THE workspace-d CLI IS NO LONGER MAINTAINED - API/LIBRARY USERS SEE [serve-d:workspace-d](https://github.com/Pure-D/serve-d/tree/master/workspace-d)

workspace-d started out as executable for different IDEs to implement D functionality within them back before LSP was a thing. Over time all functionality got exposed using workspace-d as a library in a new program called [serve-d](https://github.com/Pure-D/serve-d) which is a server implementation of the Microsoft Language Server Protocol. (LSP)

As the LSP server has been very stable for a while and workspace-d as a standalone not being used anymore I decided to deprecate the workspace-d command line interface with its proprietary RPC protocol.

The source code of workspace-d now lives in serve-d as a subpackage ([serve-d:workspace-d](https://github.com/Pure-D/serve-d/tree/master/workspace-d)).

As the proprietary RPC protocol has been removed a lot of template code has been removed and compilation times as library have sped up. Furthermore it's possible to use all of D's features in workspace-d APIs now, without needing to take care of the custom RPC protocol.

---

Old README:

# workspace-d [![Build Status](https://travis-ci.org/Pure-D/workspace-d.svg?branch=master)](https://travis-ci.org/Pure-D/workspace-d)

Join the chat: [![Join on Discord](https://discordapp.com/api/guilds/242094594181955585/widget.png?style=shield)](https://discord.gg/Bstj9bx)

workspace-d wraps dcd, dfmt and dscanner to one unified environment managed by dub.

It uses process pipes and json for communication.

## Special Thanks

**Thanks to the following big GitHub sponsors** financially supporting the code-d/serve-d tools:

* Jaen ([@jaens](https://github.com/jaens))

_[become a sponsor](https://github.com/sponsors/WebFreak001)_

## Installation

[Precompiled binaries for windows & linux](https://github.com/Pure-D/workspace-d/releases)

**Automatic Installation**

Just run install.sh or install.bat (Windows/WIP)

```sh
sh install.sh
```

**Manual Installation**

First, install the dependencies:
 
* [dcd](https://github.com/dlang-community/DCD) - Used for auto completion
* [dfmt](https://github.com/dlang-community/dfmt) - Used for code formatting
* [dscanner](https://github.com/dlang-community/Dscanner) - Used for static code linting

Then, run:

```sh
git clone https://github.com/Pure-D/workspace-d.git
cd workspace-d
git submodule init
git submodule update
dub build --build=release --compiler=ldc2
```

Either move all the executable binaries to one path and add that path to the Windows PATH
variable or $PATH on Posix, or change the binary path configuration in your editor.

## Usage

**For users**

* Visual Studio Code: [code-d](https://github.com/Pure-D/code-d)

**For plugin developers**

Microsoft Language Server Protocol (LSP) wrapper: [serve-d](https://github.com/Pure-D/serve-d)

[Wiki/Message Format](https://github.com/Pure-D/workspace-d/wiki/Message-Format)

