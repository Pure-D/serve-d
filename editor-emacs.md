# serve-d with Emacs

## Using eglot

Download or build

* [serve-d](README.md#Installation)
* [eglot](https://github.com/joaotavora/eglot#1-2-3)
* [d-mode](https://github.com/Emacs-D-Mode-Maintainers/Emacs-D-Mode)

And edit your `$HOME/.emacs` or `$HOME/.emacs.d/init.el`.

```elisp
(add-hook 'd-mode-hook 'eglot-ensure)
(add-to-list 'eglot-server-programs `(d-mode . ("/path/to/your/serve-d")))
```

OPTIONAL: If you want to customize serve-d (e.g. specifying paths), add

```elisp
(setq-default eglot-workspace-configuration
  '((:d . (:stdlibPath ("/path/to/dmd-2.098.0/src/phobos"
                        "/path/to/dmd-2.098.0/src/druntime/src")))))
```

For per-project config, add [.dir-locals.el](https://github.com/joaotavora/eglot#per-project-server-configuration) in your project root.
