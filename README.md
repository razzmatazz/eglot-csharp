# eglot-csharp

C# language support for the [eglot](https://github.com/joaotavora/eglot) LSP client.

Currently built around [csharp-language-server](https://github.com/razzmatazz/csharp-language-server)
(`csharp-ls`), with the intention of supporting additional C# LSP servers
(such as [OmniSharp](https://github.com/OmniSharp/omnisharp-roslyn) and
[roslyn-lsp](https://github.com/dotnet/vscode-csharp)) in the future.

## Features

- Registers `csharp-ls` as the eglot server for `csharp-mode` and `csharp-ts-mode`
- Enables `useMetadataUris` so that **go-to-definition**, **go-to-implementation**, and
  **find-references** all navigate into decompiled BCL and NuGet sources
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
  :hook ((csharp-mode csharp-ts-mode) . eglot-csharp-mode))
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
  :hook ((csharp-mode csharp-ts-mode) . eglot-csharp-mode))
```

Then run `doom sync` and restart Emacs.

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

## Customization

| Variable | Default | Description |
|---|---|---|
| `eglot-csharp-server-program` | `"csharp-ls"` | Path or name of the `csharp-ls` executable |
| `eglot-csharp-use-metadata-uris` | `t` | Enable `csharp:/` URIs for decompiled sources |
| `eglot-csharp-metadata-cache-directory` | `".cache/eglot-csharp/metadata"` | Cache directory for decompiled files, relative to the project root |

All options are in the `eglot-csharp` customization group (`M-x customize-group RET eglot-csharp`).

## How decompilation works

When `useMetadataUris` is enabled, `csharp-ls` returns `csharp:/` URIs for symbols
defined in compiled assemblies (BCL, NuGet packages):

```
csharp:/.../project1.csproj/decompiled/System.Console.cs
```

eglot ≥ 1.16 passes non-`file://` URIs unchanged through `eglot-uri-to-path`
([bug#58790](https://debbugs.gnu.org/cgi/bugreport.cgi?bug=58790)), and
`file-name-handler-alist` is the sanctioned extension point for custom URI schemes.

`eglot-csharp` registers a handler for `csharp:/` URIs that:

1. Calls the `csharp/metadata` LSP extension method to fetch the decompiled C# source
2. Writes it to `<project-root>/.cache/eglot-csharp/metadata/<TypeName>.cs`
3. Returns the cache file path so Emacs opens it as an ordinary read-only file

Subsequent visits use the cached file directly — no RPC round-trip needed.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
