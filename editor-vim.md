# serve-d with Vim / NeoVim

## Using ycmd

[Download or build serve-d](README.md#Installation) and edit your `.vimrc`.

```vimrc
let g:ycm_language_server = [
            \ {
            \     'name': 'd',
            \     'cmdline': ['path/to/your/serve-d/binary'],
            \     'filetypes': ['d'],
            \ }]
```

Familiarize yourself with how ycmd handles `.ycm_extra_conf.py` files.
For serve-d, it is important that you give ycmd the LSP arguments in
the right format. The basic setup for establishing autocomplete with
the D standard library needs the path (or, if multiple paths, an array
of them) to your D standard library on your system.

```python
def Settings(**kwargs):
    lang = kwargs['language']
    if lang == 'd':
        return { 'ls': {
                   'd': { 'stdlibPath': '/path/to/your/stdlib' }
                   # In case you need multiple paths, do
                   # 'd' : { 'stdlibPath': ['/path/to', '/your/stdlibs']}
                   # For other config options, see README.md
                 }
               }
    else:
        return {}
```

Put this in a file called `.ycm_extra_conf.py` and save it in your
project root or move it further up the folder hierarchy, if you know
what you are doing.

## Using coc's

### Using `CocInstall`

```
:CocInstall coc-dlang
```

### Manually through coc-settings.json

First [download or build serve-d](README.md#Installation)

A `coc-settings.json` file looking like this works well (you can open it with `:CocConfig`)

```js
{
	"languageserver": {
		"d": {
			"command": "PATH_TO_SERVE_D_EXECUTABLE/serve-d",
			"filetypes": ["d"],
			"trace.server": "on",
			"rootPatterns": ["dub.json", "dub.sdl"],
			"initializationOptions": {
			},
			"settings": {
			}
		}
	},
	"suggest.autoTrigger": "none",
	"suggest.noselect": false
}
```

## Using nvim-lspconfig

Neovim has a builtin LSP client and official LSP configs for it,
[here](https://github.com/neovim/nvim-lspconfig).

After installing `nvim-lspconfig` using your preferred plugin manager, you must
load serve-d, like the following:

```lua
require'lspconfig'.serve_d.setup{}
```

You can read more about the setup function through `:help lspconfig-setup`

### User Configuration

`serve-d` comes pre-packaged with some server-specific settings. You can find a description of such settings [here](https://github.com/Pure-D/code-d/blob/50ca8ca2831403d50bac10681df87a77b1af1bc4/package.json#L373).

For example, let's assume that you want to change the braces style so that they are on the same line as a function definition.

`dfmt` is used by `serve-d` by default; it allows the option for the `"stroustrup"` style.

```lua
require'lspconfig'.serve_d.setup({
	settings = {
		dfmt = {
			braceStyle = "stroustrup",
		},
	},
})
```
