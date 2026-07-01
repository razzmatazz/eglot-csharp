# Design

This document describes the internal mechanisms `eglot-csharp` uses to
integrate `csharp-ls`'s decompiled/generated document support
(`csharp:/` URIs) into eglot. It's aimed at contributors; end users should
read [README.md](README.md).

For the historical investigation that led to the transitive-navigation
mechanism below, see [plans/transitive-metadata-navigation.md](plans/transitive-metadata-navigation.md).

## Background: `csharp:/` metadata URIs

When `csharp.useMetadataUris` is enabled, `csharp-ls` returns `csharp:/` URIs
(instead of ordinary `file://` URIs) for symbols that live outside the
user's own source — i.e. in compiled BCL/NuGet assemblies, or in
source-generated files:

```
csharp:/<project.csproj>/decompiled/<Symbol>.cs
csharp:/<project.csproj>/generated/<HintName>
```

These are returned from `textDocument/definition` and friends. The actual
source text for such a URI is fetched via the custom `csharp/metadata` LSP
request (see `csharp-language-server`'s
[docs/features.md](https://github.com/razzmatazz/csharp-language-server/blob/main/docs/features.md)).

Crucially, **`csharp-ls` tracks decompiled/generated documents solely by
this URI string** — not by any path on disk. Internally, the server matches
incoming request URIs against a workspace folder by checking whether the
URI starts with either the workspace folder's own URI or its
metadata-URI base (`workspaceFolder` in `Lsp/Workspace.fs`), and resolves a
specific document by parsing `(projectFilePath, symbolName)` straight out
of the URI string and looking it up in an in-memory table
(`workspaceFolderDocumentDetails` in `Lsp/WorkspaceFolder.fs`) that's
populated the first time `csharp/metadata` is called for that URI. There is
no filesystem access on the server side for these documents at all.

This has a direct consequence for the client: **any LSP request concerning
a decompiled/generated document must be addressed with the exact same
`csharp:/...` URI it was discovered with** — a `file://` URI pointing at
wherever the client happened to cache the source text is meaningless to the
server and will resolve to nothing.

## Mechanism 1: the `csharp:/` file-name-handler

Emacs (and eglot, as of ≥ 1.16) leaves URIs it doesn't recognize as
`file://` untouched, and expects `file-name-handler-alist` to be the
extension point for handling them
([bug#58790](https://debbugs.gnu.org/cgi/bugreport.cgi?bug=58790)). This is
the same mechanism [eglot-java](https://github.com/yveszoundi/eglot-java)
uses for `jdt://` URIs.

`eglot-csharp` registers `eglot-csharp--metadata-uri-handler` for any
filename matching `\`csharp:/` in `file-name-handler-alist`, at load time
(not tied to the minor mode, since eglot may resolve `csharp:/` URIs from
any buffer at any time):

```elisp
(add-to-list 'file-name-handler-alist
             (cons "\\`csharp:/" #'eglot-csharp--metadata-uri-handler))
```

The handler is intentionally *operation-agnostic* — it ignores the
`_operation` argument (`expand-file-name`, `file-exists-p`,
`insert-file-contents`, ...) and always does the same thing: resolve the
`csharp:/...` string to a concrete on-disk cache file path (fetching and
writing it first, if necessary) and return that path.

This works because `find-file`/`find-file-noselect` always calls
`expand-file-name` on the target *first*. That call is dispatched to our
handler, which returns a plain, real path that no longer matches
`\`csharp:/`. Every subsequent file operation Emacs performs while opening
the buffer therefore bypasses the handler entirely and proceeds as normal
disk I/O against the cache file. Emacs never has to understand the
`csharp:/` scheme beyond that single dispatch.

### Cache file placement

`eglot-csharp--metadata-uri-cache-file` maps a URI to
`<project-root>/<eglot-csharp-metadata-cache-directory>/<basename>`, e.g.:

```
csharp:/.../project1.csproj/decompiled/System.Console.cs
  -> <project-root>/.cache/eglot-csharp/metadata/System.Console.cs
```

It deliberately uses `string-match` rather than `file-name-nondirectory` to
pull out the basename, so that `file-name-handler-alist` isn't triggered
recursively while parsing the `csharp:/` URI itself.

> **Known limitation:** the cache key is the URI's basename only — the
> project/assembly path components are discarded. Two distinct decompiled
> types that happen to share a basename across different projects would
> collide. Not yet addressed.

## Mechanism 2: workspace configuration

`eglot-csharp-mode` sets `eglot-workspace-configuration` to
`eglot-csharp--workspace-configuration`, which reports
`csharp.useMetadataUris` to the server according to
`eglot-csharp-use-metadata-uris`. This is one of three independent ways to
enable the feature server-side (see `csharp-language-server`'s
`docs/features.md`); eglot-csharp always uses workspace configuration.

## Mechanism 3: transitive navigation via the `.metadata-uri` sidecar

Mechanism 1 gets the *first* navigation into a decompiled/generated symbol
working: `xref-find-definitions` on, say, `Console.WriteLine` opens a
buffer visiting the cache file. But per the "Background" section above,
every *subsequent* LSP request for that buffer must still be addressed by
the original `csharp:/...` URI — and once the buffer is visiting a real
on-disk file, eglot has no reason to know that.

eglot computes the URI it sends to the server for a buffer via
`eglot-path-to-uri`, called from the single low-level chokepoint
`eglot--TextDocumentIdentifier`:

```elisp
(defun eglot--TextDocumentIdentifier ()
  (unless eglot--TextDocumentIdentifier-cache
    (let ((truename (file-truename (or buffer-file-name ...))))
      (setq eglot--TextDocumentIdentifier-cache
            `(,truename . (:uri ,(eglot-path-to-uri truename :truenamep t))))))
  (cdr eglot--TextDocumentIdentifier-cache))
```

Note the result is cached in the buffer-local
`eglot--TextDocumentIdentifier-cache` — but that cache is **not stable**:
`eglot--signal-textDocument/didOpen` unconditionally resets it to `nil`
right before every `didOpen`, forcing a fresh recomputation via
`eglot-path-to-uri`. (An earlier version of this mechanism tried presetting
that cache directly, mirroring `lsp-mode`'s `lsp-buffer-uri`; it didn't
stick, for exactly this reason — see
[plans/transitive-metadata-navigation.md](plans/transitive-metadata-navigation.md)
for the full account.)

Because `eglot-path-to-uri` is the one function *every* recomputation path
goes through, `eglot-csharp` instead:

1. Writes a **sidecar file** `<cache-file>.metadata-uri` next to each cache
   file, containing the original `csharp:/...` URI text, whenever
   `eglot-csharp--metadata-uri-handler` runs (whether serving a fresh fetch
   or an already-cached file, so a cache left over from an older version of
   this package without a sidecar self-heals on next access).

2. Installs `eglot-csharp--path-to-uri` as `:around` advice on
   `eglot-path-to-uri`, registered globally at load time:

   ```elisp
   (defun eglot-csharp--path-to-uri (orig-fun path &rest args)
     (or (eglot-csharp--metadata-uri-for-path path)
         (apply orig-fun path args)))

   (advice-add 'eglot-path-to-uri :around #'eglot-csharp--path-to-uri)
   ```

   `eglot-csharp--metadata-uri-for-path` looks up `path`'s `.metadata-uri`
   sidecar and returns its contents verbatim if present; otherwise the
   advice defers to eglot's normal `file://` derivation. This makes the fix
   immune to *how many times*, or from *which code path*, eglot ends up
   recomputing the identifier — every recomputation lands back on
   `eglot-path-to-uri`.

`textDocument/didOpen`/`didClose` notifications sent with these URIs are
harmless no-ops server-side: `csharp-language-server`'s
`didOpenCsharpFile`/`didCloseCsharpFile` look the document up and, finding
it typed as `DecompiledDocument`/`GeneratedDocument` rather than
`UserDocument`, take a no-op branch.

## Mechanism 4: read-only metadata buffers

`eglot-csharp--maybe-mark-metadata-buffer-read-only`, run from
`eglot-csharp--activate`, marks a buffer read-only whenever
`eglot-csharp--metadata-uri-for-path` finds a sidecar for its
`buffer-file-name`. Decompiled/generated sources have no meaningful save
target, and edits would desync the buffer's contents from the URI the
server still thinks it's serving (the server, not the client, owns the
"true" source of a decompiled/generated document).

## Summary of moving parts

| Piece | Purpose |
|---|---|
| `file-name-handler-alist` entry for `\`csharp:/` | Get the *first* `find-file` on a metadata URI to open a real, cached file |
| `<cache-file>.metadata-uri` sidecar | Remember which `csharp:/...` URI a cache file was fetched from |
| `:around` advice on `eglot-path-to-uri` | Make *every* later LSP request for that buffer re-address it by the original URI, however many times eglot recomputes it |
| `eglot-workspace-configuration` → `csharp.useMetadataUris` | Ask the server to hand out `csharp:/` URIs in the first place |
| Read-only marking | Prevent edits that would desync the buffer from server state |
