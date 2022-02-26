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

