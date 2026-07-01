# Plan: Fix Transitive Navigation Inside Decompiled/Generated Buffers

## Symptom

Go-to-definition on a BCL/NuGet symbol (e.g. `Console.WriteLine`) works: it
opens a decompiled metadata buffer via the `csharp:/` URI handler. But
go-to-definition *from within* that decompiled buffer (e.g. on `bool` in
`public static void WriteLine(bool value)`) silently does nothing.

## Root Cause

`eglot-csharp--metadata-uri-handler` fetches decompiled/generated source via
`csharp/metadata` and writes it to a real on-disk cache file
(`eglot-csharp--metadata-uri-cache-file`), then returns that path so Emacs
opens it as a normal file. This is the correct trick to get the *first*
`find-file` to work (mirrors eglot-java's `jdt://` handler), but it has a
side effect: once the buffer is visiting a real file, `buffer-file-name` is
the cache path, not the original `csharp:/...` URI.

Eglot computes the LSP `TextDocumentIdentifier` for a buffer once, lazily,
and caches it in the buffer-local `eglot--TextDocumentIdentifier-cache`
(see `eglot--TextDocumentIdentifier` in `eglot.el`):

```elisp
(unless eglot--TextDocumentIdentifier-cache
  (let ((truename (file-truename (or buffer-file-name ...))))
    (setq eglot--TextDocumentIdentifier-cache
          `(,truename . (:uri ,(eglot-path-to-uri truename :truenamep t))))))
```

For our metadata buffer, `buffer-file-name` is the cache file, so every LSP
request (`textDocument/didOpen`, `textDocument/definition`, `hover`, ...)
sent from that buffer uses a `file://.../.cache/eglot-csharp/metadata/...`
URI.

But csharp-ls does **not** know decompiled/generated documents by that path.
It tracks them purely by the original `csharp:/<project.csproj>/decompiled/
<Symbol>.cs` (or `.../generated/<HintName>`) URI string, registered in
`LspWorkspaceFolder.DecompiledSymbolMetadata` the first time `csharp/metadata`
is called for it. Confirmed in `csharp-language-server` sources:

- `Lsp/Workspace.fs` `workspaceFolder`: a request URI is matched against a
  workspace folder via `uri.StartsWith wf.Uri || uri.StartsWith
  (workspaceFolderMetadataUriBase wf)` — i.e. `csharp:/...` URIs are
  explicitly expected as first-class request URIs, not just as
  `csharp/metadata` request payloads.
- `Lsp/WorkspaceFolder.fs` `workspaceFolderDocumentDetails`: resolves a
  decompiled document by looking up `(projectFilePath, symbolMetadataName)`
  — parsed straight out of the URI string — in `wf.DecompiledSymbolMetadata`.
  There is no filesystem lookup involved at all for this path.
- `Handlers/Definition.fs`: calls `context.LoadWorkspaceFolder
  p.TextDocument.Uri` then `workspaceFolderDocumentSymbol ... p.TextDocument.Uri
  ...` — so definitions are resolved by symbol lookup inside the (virtual)
  Roslyn document matching that URI.

So when eglot sends `textDocument/definition` with a `file://` URI for the
cache file, `workspaceFolder`/`workspaceFolderDocumentDetails` find nothing,
and the server correctly (from its point of view) returns no location.

## Prior Art: `lsp-mode`'s `csharp-ls` client

`lsp-csharp--cls-metadata-uri-handler` in `~/src/lsp-mode/clients/lsp-csharp.el`
already solves this:

1. When writing the cache file, it also writes a sidecar file
   `<cache-file>.metadata-uri` containing the original `csharp:/...` URI text.
2. It registers a `:before-file-open-fn` (`lsp-csharp--cls-before-file-open`)
   that, when a buffer is opened, checks for a sidecar file next to
   `buffer-file-name` and, if present, sets `lsp-buffer-uri` (a buffer-local
   override lsp-mode consults instead of deriving the URI from the file path)
   to the original URI.

We need the equivalent for eglot. eglot has no public per-buffer URI
override like `lsp-buffer-uri`, so this plan originally proposed presetting
the buffer-local `eglot--TextDocumentIdentifier-cache` before eglot ever
computes it for the buffer. **That approach turned out to be insufficient
in practice** — see "Correction" below — and was replaced with advising the
lower-level `eglot-path-to-uri` instead.

## Implementation Steps

### 1. `eglot-csharp.el`: write a sidecar file recording the origin URI

In `eglot-csharp--metadata-uri-handler`, alongside writing `cache-file`, also
write `<cache-file>.metadata-uri` containing the raw `csharp:/...` URI, e.g.:

```elisp
(defun eglot-csharp--metadata-uri-sidecar-file (cache-file)
  "Path of the sidecar file recording CACHE-FILE's originating metadata URI.")
```

Write it whenever the handler runs (idempotent — same content every time),
not only on first fetch, so it self-heals if the cache file exists but the
sidecar is missing (e.g. cache created by an older version of this package).

### 2. `eglot-csharp.el`: make eglot re-derive the metadata URI on demand

Rather than presetting a per-buffer cache (see "Correction" below), advise
`eglot-path-to-uri` itself — the single low-level function eglot always
routes through whenever it needs the URI for a path, no matter how many
times it recomputes it:

```elisp
(defun eglot-csharp--metadata-uri-for-path (path)
  "Return the metadata URI PATH was cached from, via its `.metadata-uri' sidecar, or nil.")

(defun eglot-csharp--path-to-uri (orig-fun path &rest args)
  (or (eglot-csharp--metadata-uri-for-path path)
      (apply orig-fun path args)))

(advice-add 'eglot-path-to-uri :around #'eglot-csharp--path-to-uri)
```

Registered globally at load time (like the `csharp:/` file-name-handler),
not tied to the minor mode: if `path` has a `.metadata-uri` sidecar next to
it, return that URI verbatim; otherwise defer to eglot's normal `file://`
derivation. No-op for ordinary project files (no sidecar exists next to
them).

Separately, `eglot-csharp--maybe-mark-metadata-buffer-read-only`, called
from `eglot-csharp--activate`, marks a buffer read-only whenever
`eglot-csharp--metadata-uri-for-path` matches its `buffer-file-name` — it's
a decompiled/generated view with no meaningful save target, and accidental
edits would desync it from the URI the server thinks it's serving.

### Correction: presetting `eglot--TextDocumentIdentifier-cache` doesn't stick

The first implementation of this plan set
`eglot--TextDocumentIdentifier-cache` directly (buffer-locally) before
calling `eglot-ensure`, mirroring `lsp-buffer-uri`. Manual testing (see
"Manual verification" below) showed the *first* `textDocument/definition`
request from a freshly-opened metadata buffer still went out with a
`file://` URI, despite the preset value being observably correct
immediately after being set.

The cause: `eglot--signal-textDocument/didOpen` (in `eglot.el`)
unconditionally resets the cache right before sending `didOpen`:

```elisp
(defun eglot--signal-textDocument/didOpen ()
  (setq eglot--recent-changes nil
        eglot--versioned-identifier 0
        eglot--TextDocumentIdentifier-cache nil)   ; <-- wipes our preset
  (jsonrpc-notify ... :textDocument/didOpen `(:textDocument ,(eglot--TextDocumentItem))))
```

`eglot--TextDocumentItem` then calls `eglot--TextDocumentIdentifier` again,
which — finding the cache nil — recomputes it fresh via `(eglot-path-to-uri
truename :truenamep t)`, deriving a plain `file://` URI. Our one-time
preset in `eglot-csharp--activate` was gone by the time it mattered.

Since `eglot-path-to-uri` is the one function both the original computation
*and* every later recomputation always call, advising it directly (rather
than presetting its cached output) makes the fix immune to however many
times, or from whatever code path, eglot decides to recompute the
identifier.

### 3. Sanity-check `textDocument/didOpen`/`didClose` are harmless for these URIs

Verified in `csharp-language-server`'s `Handlers/DocumentSync.fs`:
`didOpenCsharpFile`/`didCloseCsharpFile` look the URI up via
`workspaceFolderDocumentDetails AnyDocument`; for `DecompiledDocument` /
`GeneratedDocument` doc types they take the `| _ -> []` branch (no-op), and if
lookup fails entirely `workspaceFolderUriToPath` returns `None` for a
non-`file:` URI, which also short-circuits to `[]`. So there's no risk of the
didOpen/didClose lifecycle corrupting server state for these virtual URIs.

### 4. Manual verification

Performed live, against a running Emacs with `~/src/test-csharp/project1/Program.cs`
open and `eglot-csharp-mode` active:

1. `xref-find-definitions` on `Console.WriteLine` → opened decompiled
   `System.Console.cs` (existing behaviour, unaffected). ✅
2. Inside that buffer, `xref-find-definitions` on `bool` in `public static
   void WriteLine(bool value)` → navigated into a newly-decompiled
   `System.Boolean.cs` buffer. ✅ (previously did nothing)
3. Both metadata buffers came up read-only, with `eglot--TextDocumentIdentifier-cache`
   and `(eglot-path-to-uri buffer-file-name)` both correctly showing the
   original `csharp:/.../decompiled/<Symbol>.cs` URI, and a `.metadata-uri`
   sidecar present next to each cache file. ✅
4. `Program.cs` itself remained writable, with a normal `file://` identifier
   and `eglot-csharp--metadata-uri-for-path` returning nil for it. ✅

(Verification of the original preset-based approach in step 2 is what
surfaced the bug described in "Correction" above — the first attempt
opened `System.Console.cs` correctly but transitive definition on `bool`
still failed silently, tracing back to the `file://` URI being sent.)

## Files Changed Summary

| File | Change |
|---|---|
| `eglot-csharp.el` | `(require 'subr-x)`; add `eglot-csharp--metadata-uri-sidecar-file` and `eglot-csharp--metadata-uri-for-path`; write sidecar URI file in `eglot-csharp--metadata-uri-handler`; add `eglot-csharp--path-to-uri` and register it as `:around` advice on `eglot-path-to-uri`; add `eglot-csharp--maybe-mark-metadata-buffer-read-only`, called from `eglot-csharp--activate` |

## Known Limitations (pre-existing, out of scope here)

`eglot-csharp--metadata-uri-cache-file` keys the cache purely off the URI's
basename (`<Symbol>.cs` / hint name), ignoring the project/assembly path
components. Two distinct decompiled types that happen to share a basename
across different projects could collide. Not addressed by this plan.
