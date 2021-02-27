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
