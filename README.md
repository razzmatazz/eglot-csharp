# eglot-csharp

C# language support for the [eglot](https://github.com/joaotavora/eglot) LSP client.

> **Note:** This project was largely written with the assistance of an LLM (Claude).
> Source files carry an `Assisted-by:` header line per the [Linux kernel coding-assistants convention](https://docs.kernel.org/process/coding-assistants.html#attribution).

Currently built around [csharp-language-server](https://github.com/razzmatazz/csharp-language-server)
(`csharp-ls`), with the intention of supporting additional C# LSP servers
(such as [OmniSharp](https://github.com/OmniSharp/omnisharp-roslyn) and
[roslyn-lsp](https://github.com/dotnet/vscode-csharp)) in the future.

## Features

- Registers `csharp-ls` as the eglot server for `csharp-mode` and `csharp-ts-mode`
- Registers `csharp-ls` for `.cshtml` (Razor) files too, via a thin `web-mode`-derived
  `eglot-csharp-cshtml-mode` — sharing the *same* connection as a project's `.cs` buffers
  rather than starting a redundant second `csharp-ls` process
- Enables `useMetadataUris` so that **go-to-definition**, **go-to-implementation**, and
  **find-references** all navigate into decompiled BCL and NuGet sources
- Enables `razorSupport` so that `.cshtml` documents get diagnostics, hover, completion,
  and navigation from `csharp-ls`
- Handles `csharp:/` URIs returned by `csharp-ls` by fetching decompiled source via the
  `csharp/metadata` extension method and caching it to disk as a plain `.cs` file

The `csharp:/` URI handler is modeled after
[eglot-java](https://github.com/yveszoundi/eglot-java)'s `jdt://` handler: decompiled
source is written to a per-project cache directory so Emacs opens it as a normal file.

## Installation

### Manual

Clone this repo and add it to your load path:

```elisp
(add-to-list 'load-path "/path/to/eglot-csharp")
(require 'eglot-csharp)
```

### straight.el

```elisp
(straight-use-package
 '(eglot-csharp :type git :host github :repo "razzmatazz/eglot-csharp"))
```

### use-package + straight.el

```elisp
(use-package eglot-csharp
  :straight (eglot-csharp :type git :host github :repo "razzmatazz/eglot-csharp")
  :hook ((csharp-mode csharp-ts-mode eglot-csharp-cshtml-mode) . eglot-csharp-mode))
```

### Doom Emacs

Add to `packages.el`:

```elisp
(package! eglot-csharp
  :recipe (:host github :repo "razzmatazz/eglot-csharp"))
```

Add to `config.el`:

```elisp
(use-package! eglot-csharp
  :hook ((csharp-mode csharp-ts-mode eglot-csharp-cshtml-mode) . eglot-csharp-mode))
```

Then run `doom sync` and restart Emacs.

#### Local checkout (Doom Emacs)

If you have cloned the repo locally and want Doom to load it directly from
disk without fetching from GitHub, use `:local-repo` with the absolute path
in `packages.el`:

```elisp
(package! eglot-csharp
  :recipe (:local-repo "/path/to/eglot-csharp"))
```

straight.el will symlink that directory into its repos folder instead of
cloning it, so edits to your local checkout are reflected immediately after
`doom sync`.

## Configuration

Activate `eglot-csharp-mode` via a hook — this registers `csharp-ls`, enables
`useMetadataUris`, and starts eglot automatically when you open a `.cs` file:

```elisp
(require 'eglot-csharp)
(add-hook 'csharp-mode-hook    #'eglot-csharp-mode)
(add-hook 'csharp-ts-mode-hook #'eglot-csharp-mode)
```

Or activate manually in any `.cs` buffer:

```
M-x eglot-csharp-mode
```

### `.cshtml` (Razor) support

`.cshtml` files are automatically associated with `eglot-csharp-cshtml-mode` — a thin
wrapper around [`web-mode`](https://web-mode.org/) that gives Razor views their own
major-mode symbol without affecting other `web-mode` buffers (`.html`, `.php`, `.vue`,
...). `web-mode` itself is **not** a dependency of this package and must be installed
separately. Wire up eglot the same way as for `.cs` files:

```elisp
(add-hook 'eglot-csharp-cshtml-mode-hook #'eglot-csharp-mode)
```

Opening a `.cshtml` file in a project whose `.cs` files are already managed by
`eglot-csharp-mode` (or vice versa) shares the *same* `csharp-ls` connection rather than
starting a second one — see [DESIGN.md](DESIGN.md) for why that matters and how it works.

Set `eglot-csharp-enable-cshtml` to `nil` (before loading the package) if you'd rather
manage `.cshtml`'s major mode / eglot activation yourself.

## Customization

| Variable | Default | Description |
|---|---|---|
| `eglot-csharp-server-program` | `"csharp-ls"` | Path or name of the `csharp-ls` executable |
| `eglot-csharp-use-metadata-uris` | `t` | Enable `csharp:/` URIs for decompiled sources |
| `eglot-csharp-metadata-cache-directory` | `".cache/eglot-csharp/metadata"` | Cache directory for decompiled files, relative to the project root |
| `eglot-csharp-enable-cshtml` | `t` | Associate `.cshtml` files with `eglot-csharp-cshtml-mode`; takes effect at load time |
| `eglot-csharp-razor-support` | `t` | Enable csharp-ls's Razor (`.cshtml`) document support via workspace configuration |

All options are in the `eglot-csharp` customization group (`M-x customize-group RET eglot-csharp`).

## How decompilation works

When `useMetadataUris` is enabled, `csharp-ls` returns `csharp:/` URIs for symbols
defined in compiled assemblies (BCL, NuGet packages) or generated by source
generators. `eglot-csharp` fetches their source via the `csharp/metadata` LSP
extension method, caches it to disk, and opens it as an ordinary read-only
buffer — including for navigation performed *from within* such a buffer
(e.g. go-to-definition on a type used in a decompiled method signature).

See [DESIGN.md](DESIGN.md) for how this is implemented under the hood.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
