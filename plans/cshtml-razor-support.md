# Plan: `.cshtml` (Razor) Support

**Status:** Implemented in `eglot-csharp.el` (with one design correction
found along the way — see "Correction: contact-function shape" under
Design step 5). `README.md` and `CHANGELOG.md` are updated. **Partially
manually verified** — see "Manual Verification Findings" below: real-world
testing against `~/src/test-csharp-web`'s `Pages/Index.cshtml` uncovered
that this plan's own claim of `~/.config/doom/config.el` already being
wired up was **false** (the hook was never actually added, despite the
"Done" status recorded below), which is why `.cshtml` support silently did
nothing in practice. That downstream wiring bug is now fixed. The
`eglot-csharp.el` connection/adoption mechanism itself (contact function,
`eglot-csharp--server` class, `csharp-ls` handshake) has now been confirmed
working at runtime for the "`.cshtml` opened, no prior `.cs` server"
case. The rest of the Manual Verification Plan below (shared-connection
adoption in both orderings, cross-file xref, the `t`/`nil` toggle) is
still outstanding. `DESIGN.md` is deliberately *not* updated yet; per this
plan's own step 8, that happens only once manual verification passes.

## Goal

Make `eglot-csharp-mode` work for ASP.NET Core Razor view files (`.cshtml`),
using [`web-mode`](https://web-mode.org/) as the base major mode, with
`csharp-ls`'s Razor support enabled via workspace configuration
(`csharp.razorSupport`). Opening a `.cshtml` file in a project already being
edited (e.g. an MVC/Razor Pages project with `Controllers/*.cs` and
`Views/*.cshtml`) should get the same eglot experience — diagnostics, hover,
completion, go-to-definition, references, rename — as `.cs` files, ideally
sharing the *same* running `csharp-ls` process as the project's `.cs`
buffers rather than spawning a second, redundant one.

## Background

### `csharp-ls` already supports Razor — it's a client-side wiring problem

`csharp-ls` has first-class support for `.cshtml` documents already (see
`~/src/csharp-language-server`):

- `csharp.razorSupport` workspace-configuration setting (default `false`),
  documented in `docs/features.md`: <br>
  *"Can be enabled via the `csharp.razorSupport` configuration setting or by
  passing the `--features razor-support` CLI flag."*
- Internally, `.cshtml` documents are tracked as
  `AdditionalDocument`s per workspace folder (`Lsp/WorkspaceFolder.fs`,
  `Handlers/DocumentSync.fs`'s `didOpenCshtmlFile`/etc.), routed purely by
  the `.cshtml` URI suffix — **not** by the LSP `languageId` string the
  client reports in `didOpen`.
- `Types.fs` defines `razorCsharpDocumentFilter = { Language = Some "razor";
  Scheme = Some "file"; Pattern = Some "**/*.cshtml" }`, used (only) for
  *dynamic* capability registration when the client advertises
  `dynamicRegistration: true` for text-document sync — which eglot does not,
  so eglot gets `.cshtml` sync for free via the static
  `textDocumentSync` capability already used for `.cs` files. No dynamic
  registration handling is required on the client side.
- Razor go-to-definition/hover/etc. resolve through Roslyn's Razor source
  generator (`RazorSourceGenerator`), which is part of the *same* Roslyn
  `Solution`/`MSBuildWorkspace` that also holds the project's `.cs` files —
  see `~/src/csharp-language-server/plans/razor-sdk-300-investigation.md`
  for the (unrelated, already-fixed) SDK 10.0.300 compatibility saga, which
  confirms this architecture. There is exactly one workspace/solution load
  per project; `.cshtml` is just another document kind inside it.

So `csharp-ls` needs no changes. Everything here is `eglot-csharp` client
wiring: (1) getting eglot to run `csharp-ls` for `.cshtml` buffers at all,
(2) doing it, ideally, through the *same* connection already managing that
project's `.cs` buffers, and (3) turning on `csharp.razorSupport`.

### Why "just add `web-mode` to `eglot-server-programs`" doesn't work

`eglot-server-programs` entries are matched purely by *major mode* (via
`eglot--lookup-mode`, which calls `provided-mode-derived-p`) — there is no
filename-based dispatch. `web-mode` is a generic mode used for HTML, PHP,
ERB, Vue SFCs, JSX, plain `.cshtml`, etc. If we registered `web-mode` itself
as an `eglot-server-programs` key mapped to `csharp-ls`, *every* `web-mode`
buffer in an eglot-csharp-enabled project — including unrelated `.html`
files — would try to start `csharp-ls`. We need a major mode symbol that
uniquely identifies "this buffer is a `.cshtml` file", while still being
`web-mode` under the hood (for HTML/CSS/JS fontification, indentation,
etc.). The standard Emacs answer is a thin `define-derived-mode`.

### Why a naive per-buffer `eglot-server-programs` registration causes two servers

`eglot-csharp--activate` currently does, on every activation:

```elisp
(add-to-list 'eglot-server-programs
             (cons major-mode (list eglot-csharp-server-program)))
```

This adds a *separate* alist entry per major mode the minor mode has ever
been turned on for (today: `csharp-mode`, `csharp-ts-mode`, each as its own
entry, both pointing at `("csharp-ls")`). `eglot--lookup-mode` treats each
top-level entry as an independent group of "modes managed together by one
server"; it does **not** merge separate entries that happen to share the
same contact. Consequently:

- `eglot-server-programs` having a `(csharp-mode . ("csharp-ls"))` entry and
  a *separate* `(eglot-csharp-cshtml-mode . ("csharp-ls"))` entry would make
  eglot treat a fresh `.cshtml` buffer as needing an **unrelated** server
  connection from a `.cs` buffer's, even in the same project.
- `eglot--connect` (the function that actually spawns the process) has no
  "is a suitable server for this project already running?" check of its
  own — that job normally falls to `eglot--maybe-activate-editing-mode`
  (hooked on `after-change-major-mode-hook`), which looks for an *already
  connected* server whose **fixed-at-connect-time** `eglot--languages` slot
  includes the current buffer's major mode (see `eglot--languageId`). A
  running server's `eglot--languages` is set once, in `eglot--connect`, and
  is not affected by later changes to `eglot-server-programs`. So even if we
  cleverly rewrote `eglot-server-programs` to merge modes into one entry
  right when the second mode is first seen, that only prevents *duplicate*
  connections for projects where the entry was already fully merged
  *before* any buffer of any of those modes was first opened — it does
  nothing for a project where a `.cs` buffer (and its server) already exist
  by the time the first `.cshtml` buffer shows up, which is the *common*
  case (e.g. opening `Controllers/HomeController.cs` before
  `Views/Home/Index.cshtml`).
- Two independent `csharp-ls` processes for the same project is worse than
  just wasteful: `.cs` edits made in one process's in-memory Roslyn
  workspace (via `textDocument/didChange`) are invisible to the other
  process, which only sees what's on disk. Cross-navigation between a
  `.cshtml` view and a `.cs` controller/model could silently use stale
  information whenever the "wrong" process serves the request.

**Conclusion:** we need buffers to be added to an *already-running*
project server after the fact, not merely to get `eglot-server-programs`
right before the first connection. This means reaching into eglot's
internals a bit (as `eglot-csharp.el` already does elsewhere — see
`eglot-csharp--find-server`, and the `eglot-path-to-uri` advice documented
in `DESIGN.md`). No changes to eglot itself are required; a small amount of
(carefully scoped, already-precedented in this codebase) use of internal
eglot accessors in `eglot-csharp.el` is enough. If, during implementation,
this turns out to be insufficient for some edge case, falling back to
`advice-add` on an eglot internal (e.g. `eglot-current-server` or
`eglot--guess-contact`) is an acceptable escape hatch — but should not be
needed for the core mechanism below.

## Design

### 1. Tag our own connections with a dedicated server class

```elisp
(defclass eglot-csharp--server (eglot-lsp-server) ()
  "eglot-lsp-server subclass identifying csharp-ls connections started
by `eglot-csharp-mode', regardless of which major mode(s) the connection
currently manages. Lets `eglot-csharp--find-project-server' distinguish
\"our\" server from any other, unrelated LSP server that might be running
for the same project (e.g. an HTML/CSS server also managing `web-mode`
buffers).")
```

`eglot-server-programs` entries can specify a class as the first element of
CONTACT (eglot supports this already — see `eglot--guess-contact`'s
`class` computation). Registrations below use `eglot-csharp--server`
instead of relying on the default `eglot-lsp-server`.

### 2. New minor mode: `eglot-csharp-cshtml-mode`, derived from `web-mode`

```elisp
(declare-function web-mode "web-mode")

(define-derived-mode eglot-csharp-cshtml-mode web-mode "Razor"
  "Major mode for ASP.NET Core Razor (`.cshtml') files.
A thin wrapper around `web-mode' (which already auto-detects the Razor
\"engine\" from the `.cshtml' extension for fontification purposes) whose
only job is to give `.cshtml' buffers a distinct major-mode symbol that
`eglot-server-programs' can key on, without affecting other `web-mode'
buffers (`.html', `.php', `.vue', ...) that have nothing to do with C#.")
```

`web-mode` is *not* declared as a hard dependency (`Package-Requires`) —
most `eglot-csharp` users have no `.cshtml` files and shouldn't be forced
to install it. `(declare-function web-mode "web-mode")` silences the
byte-compiler; if a user without `web-mode` installed actually opens a
`.cshtml` file, they'll get a normal `void-function` error at that point,
same as using any Emacs feature whose package isn't installed.

### 3. New customization

```elisp
(defcustom eglot-csharp-enable-cshtml t
  "When non-nil, associate `.cshtml' files with `eglot-csharp-cshtml-mode'
in `auto-mode-alist' and register it with `eglot-server-programs'.
Set to nil if you don't want `.cshtml' files touched by this package at
all (e.g. you use a different major mode or LSP setup for Razor views).
Takes effect at load time; changing it afterwards via `customize' has no
effect on an already-loaded `eglot-csharp'."
  :type 'boolean
  :group 'eglot-csharp)

(defcustom eglot-csharp-razor-support t
  "When non-nil, ask csharp-ls to enable Razor (`.cshtml') document support
via the `csharp.razorSupport' workspace-configuration setting. Requires
csharp-ls with Razor support (see csharp-ls's docs/features.md)."
  :type 'boolean
  :group 'eglot-csharp)
```

### 4. `auto-mode-alist` + `eglot-server-programs` registration (load time)

Mirrors how the existing `csharp:/` file-name-handler is registered
unconditionally at load time (not tied to the minor mode):

```elisp
(when eglot-csharp-enable-cshtml
  (add-to-list 'auto-mode-alist '("\\.cshtml\\'" . eglot-csharp-cshtml-mode)))
```

`eglot-csharp--activate` keeps registering `eglot-server-programs` entries
per activated major mode (as today), just switching the contact to include
our server class and, for `eglot-csharp-cshtml-mode`, an explicit
`:language-id`:

```elisp
(defun eglot-csharp--contact (&rest _)
  "Returns (CLASS . PROGRAM-LIST) via a *function result*, not baked
into the literal `eglot-server-programs' entry — see the \"Correction\"
note under Design step 5 for why that distinction matters."
  (list 'eglot-csharp--server eglot-csharp-server-program))

(defun eglot-csharp--activate ()
  (add-to-list 'eglot-server-programs
               (cons (if (eq major-mode 'eglot-csharp-cshtml-mode)
                         (list major-mode
                               :language-id (eglot-csharp--language-id-for-mode major-mode))
                       major-mode)
                     #'eglot-csharp--contact))
  ...)
```

(`eglot-csharp--language-id-for-mode` is the shipped name for what this
plan originally called `eglot-csharp--language-id-for` — see Design step 5.)

(`:language-id "razor"` matches `razorCsharpDocumentFilter`'s `Language =
Some "razor"` on the server side — mostly cosmetic/for-the-record since
`csharp-ls` doesn't gate `.cshtml` handling on `languageId`, but it's the
technically correct value to send and costs nothing.)

Using a named, `&rest`-accepting *function* as the whole entry's contact,
rather than a literal `(list eglot-csharp-server-program)` snapshot, also
fixes a latent (minor, pre-existing) issue: today, customizing
`eglot-csharp-server-program` *after* a mode has already been activated
once has no effect on that mode's registered entry, since the literal list
value was captured at `add-to-list` time. It also, as a side effect, makes
`add-to-list`'s deduplication reliable across repeated activations of the
same mode (a plain interned function symbol is trivially `equal` to
itself every time, unlike a freshly-allocated `(lambda ...)` closure
literal evaluated anew on each call).

### 5. Adopt into an already-running project server instead of always calling `eglot-ensure`

This is the core of the fix. As shipped, the existing
`eglot-csharp--find-server` (previously used only by the metadata-URI
handler) was extended in place — rather than adding a second, near-duplicate
lookup function as originally sketched here — to filter by the
`eglot-csharp--server` class, and is now reused for both purposes:

```elisp
(defun eglot-csharp--find-server ()
  "Return the active `eglot-csharp--server' for the current project, or nil."
  (when-let* ((project (eglot--current-project))
              (servers (gethash project eglot--servers-by-project)))
    (cl-find-if (lambda (s) (cl-typep s 'eglot-csharp--server)) servers)))

(defun eglot-csharp--language-id-for-mode (mode)
  "Best-effort LSP languageId string for MODE."
  (if (eq mode 'eglot-csharp-cshtml-mode) "razor" "csharp"))

(defun eglot-csharp--adopt-into (server)
  "Add the current buffer's major mode to SERVER's managed languages and
activate `eglot--managed-mode' against it, without starting a new
connection.

Used when a `.cs'/`.cshtml' buffer's major mode isn't yet among an
already-running project SERVER's `eglot--languages' (e.g. the project's
first `.cshtml' buffer is opened after its `.cs' buffers already started
a server) -- avoids spinning up a redundant second `csharp-ls' process for
the same project, which would otherwise desync in-memory edits between
the two connections (see plans/cshtml-razor-support.md for the full
rationale)."
  (cl-pushnew (cons major-mode (eglot-csharp--language-id-for-mode major-mode))
              (eglot--languages server)
              :key #'car)
  (eglot--maybe-activate-editing-mode))
```

And change `eglot-csharp--activate`'s tail from unconditionally calling
`(eglot-ensure)` to:

```elisp
  (if-let* ((server (eglot-csharp--find-server)))
      (eglot-csharp--adopt-into server)
    (eglot-ensure)))
```

Walking through both orderings:

- **`.cs` opened first, then `.cshtml`:** first buffer finds no existing
  server, `eglot-ensure` connects normally (managing just `csharp-mode`
  initially). Second buffer (`eglot-csharp-cshtml-mode`) *does* find the
  now-running `eglot-csharp--server` for the project via
  `eglot-csharp--find-server`, pushes `(eglot-csharp-cshtml-mode
  . "razor")` onto its `eglot--languages`, and calls
  `eglot--maybe-activate-editing-mode` — which re-checks
  `eglot-current-server` (now matching, since `eglot--languageId` scans
  the just-updated `eglot--languages`), activates `eglot--managed-mode`,
  and sends `textDocument/didOpen` for the `.cshtml` buffer against the
  *same* connection. No new process spawned.
- **`.cshtml` opened first:** symmetric — the first buffer starts the
  server (managing just `eglot-csharp-cshtml-mode`), and a later `.cs`
  buffer gets adopted into it the same way.
- **Two buffers of the same mode, same project (today's existing
  behaviour):** unaffected — `eglot-csharp--find-server` finds the
  already-registered mode and `eglot--maybe-activate-editing-mode`'s own
  pre-existing dedup logic (looking at `eglot-current-server`) already
  handles this correctly without any adoption needed; `cl-pushnew ... :key
  #'car` is a no-op in this case since the mode's already present.
- **`csharp-mode` and `csharp-ts-mode` both used in the same project
  session (today's pre-existing, latent limitation)** — as a side effect,
  this same mechanism fixes that case too, since it no longer depends on
  `eglot-server-programs` pre-merging modes before the first connection.

No `advice-add` on eglot internals ends up being necessary for this;
`eglot--languages`'s accessor is `setf`-able (it's a plain EIEIO slot
accessor) and `eglot--maybe-activate-editing-mode` /
`eglot--servers-by-project` / `eglot--current-project` are already used or
precedented as "internal but stable enough to lean on" in this codebase
(see `eglot-csharp--find-server`, and the `eglot-path-to-uri` advice
described in `DESIGN.md`). Should this approach prove fragile in practice
(e.g. some other internal invariant `eglot--maybe-activate-editing-mode`
relies on turns out not to hold when called this way), the fallback is
`:around` advice on `eglot-current-server` teaching it to also recognize
"any running `eglot-csharp--server` for this project" as usable for *any*
`eglot-csharp`-registered mode, sidestepping the manual
`eglot--languages` mutation entirely — but try the simpler mutation
approach first.

### Correction: contact-function shape (found while implementing step 4)

The first implementation attempt registered the `eglot-server-programs`
entry as:

```elisp
;; WRONG — do not do this
(add-to-list 'eglot-server-programs
             (list (if (eq major-mode 'eglot-csharp-cshtml-mode)
                       (list major-mode :language-id "razor")
                     major-mode)
                   'eglot-csharp--server
                   (lambda (&rest _) (list eglot-csharp-server-program))))
```

This looks reasonable but is broken. `(list mode-spec 'eglot-csharp--server
LAMBDA)` as a *proper* list means, once read as a `(modes . contact)` cons,
`contact = (eglot-csharp--server LAMBDA)` — i.e. a two-element list whose
*second* element happens to be a function, not a function itself.

Tracing `eglot--guess-contact`: it first checks `(functionp guess)` on the
*raw* contact value from the alist — false here, since a list containing a
function isn't itself `functionp` — so the lambda is never invoked at all.
It then strips a leading class symbol directly from that same raw value:
`class = eglot-csharp--server`, and what's left, `(cdr guess)`, is `(LAMBDA)`
— a one-element list *containing* the still-uncalled closure, not a program
string list. Every later branch that expects `(car guess)` to be a string
(building `program`, and eventually `eglot--connect`'s `initargs` `cond`)
fails to match, `initargs` ends up `nil`, and `make-instance` is called
without a `:process` initarg — a broken connection.

The key realization, from re-reading `eglot--guess-contact` line by line
(rather than just pattern-matching against the built-in table's *literal*-
list examples, none of which combine a function with an explicit class):
eglot only strips a leading class symbol from a contact **after**
funcalling it, if it's a function — not from the literal entry data. So a
function-valued contact must, when *called*, itself return the
`(CLASS . PROGRAM-LIST)`-shaped value; it must be the *whole* cdr of the
entry (`(mode-spec . my-function)`, a dotted pair), not one element buried
inside a longer literal list.

The fix (shown corrected in step 4 above): a named top-level function
`eglot-csharp--contact` that, when called, returns `(list
'eglot-csharp--server eglot-csharp-server-program)`; the
`eglot-server-programs` entry is `(cons mode-spec #'eglot-csharp--contact)`.

This was caught before any manual/runtime testing, by manually tracing
`eglot--guess-contact` and `eglot--connect` step by step against the
installed eglot source (`~/.config/emacs/.local/straight/repos/eglot/eglot.el`),
then confirmed empirically with a `batch --eval` smoke test that loads
`eglot-csharp.el` and exercises `eglot-csharp--contact`,
`eglot--lookup-mode`, and the class-stripping logic directly:

```
contact: (eglot-csharp--server "csharp-ls")
lookup-mode cshtml: (((eglot-csharp-cshtml-mode . "razor")) . eglot-csharp--contact)
guess funcall result: (eglot-csharp--server "csharp-ls")
class: eglot-csharp--server, remaining guess (program list): ("csharp-ls")
```

That smoke test only exercises the contact/class-resolution machinery in
isolation, though — it does not start a real `csharp-ls` process or a real
buffer/project, so it does not substitute for the Manual Verification Plan
below.

### 6. Workspace configuration: report `csharp.razorSupport`

```elisp
(defun eglot-csharp--workspace-configuration (_server)
  "Return the eglot workspace configuration plist for csharp-ls."
  `(:csharp (:useMetadataUris ,(if eglot-csharp-use-metadata-uris t :false)
             :razorSupport ,(if eglot-csharp-razor-support t :false))))
```

No CLI-flag equivalent (`--features razor-support`) is needed — per
csharp-ls's `docs/features.md`, the workspace-configuration setting alone
is sufficient, exactly like `useMetadataUris` today.

### 7. Docstring/comment updates

Update the `;;; Commentary:` block and module docstring listing key
features to mention `.cshtml`/Razor, matching the existing bullet-point
style.

## Manual Verification Plan

**Outstanding as of this writing** — the code below has been implemented,
byte-compiles cleanly, and its `eglot-server-programs`/class-resolution
logic has been traced/smoke-tested in isolation (see the "Correction" note
above), but none of the following has actually been run against a live
`csharp-ls` and a real ASP.NET project yet.

Using an ASP.NET Core MVC or Razor Pages test project (e.g.
`~/src/test-csharp/aspnet-project1`, or the `aspnetProject` test fixture
under `~/src/csharp-language-server/tests/.../Fixtures/aspnetProject`
copied out to a scratch directory):

1. `web-mode` is already installed (pulled in by Doom's `:lang web`
   module); `eglot-csharp-razor-support` defaults to `t`. `~/.config/doom/
   config.el`'s `eglot-csharp` hook has already been updated to:
   ```elisp
   (use-package! eglot-csharp
     :hook ((csharp-mode csharp-ts-mode eglot-csharp-cshtml-mode) . eglot-csharp-mode))
   ```
   (Doom's `+lsp-csharp-improvements.el` also references `web-mode` for an
   old, unrelated `lsp-mode`/`rzls` experiment; it isn't `load!`-ed from
   `config.el` so it's inert and shouldn't interfere.)
2. Open a `.cs` controller file first. Confirm `eglot-csharp-mode` starts a
   `csharp-ls` connection (`M-x eglot-events-buffer`, `M-x
   eglot-list-connections` or equivalent) and `xref-find-definitions`/hover
   work as before (regression check).
3. Open a `.cshtml` view in the *same* project. Confirm:
   - The buffer is in `eglot-csharp-cshtml-mode` (check `major-mode`);
     `web-mode`'s usual HTML/CSS/JS fontification and indentation work.
   - **No new `csharp-ls` process was spawned** — check
     `M-x list-processes` / `(gethash (eglot--current-project)
     eglot--servers-by-project)` shows a single server for the project, and
     that server's `(eglot--major-modes server)` now includes both
     `csharp-mode` and `eglot-csharp-cshtml-mode`.
   - `eglot--managed-mode` is on in the `.cshtml` buffer and
     `flymake-mode`/diagnostics, hover, and completion work for C#
     expressions inside `@{ }`/`@Model...` Razor syntax.
4. Reverse the order: kill both buffers and the server, then open the
   `.cshtml` file *first*, confirm it starts a server on its own, then open
   the `.cs` file and confirm it gets adopted into that same server
   (mirror-image of step 3's checks).
5. `xref-find-definitions` from a `.cshtml` buffer on a symbol defined in a
   `.cs` file in the same project (e.g. a Razor Page's code-behind
   property, or a Model type used via `@model`) navigates correctly to the
   `.cs` file.
6. `xref-find-references` on a C# symbol used from a Razor view finds the
   reference inside the `.cshtml` file (exercises `csharp-ls`'s
   `SourceGeneratedDocument`-aware `FindReferencesAsync` handling, per
   `~/src/csharp-language-server/plans/razor-sdk-300-investigation.md`
   Part C).
7. Toggle `eglot-csharp-enable-cshtml` to `nil` in a fresh Emacs, confirm
   `.cshtml` files are *not* auto-associated with `eglot-csharp-cshtml-mode`
   (fall back to whatever `auto-mode-alist` would otherwise pick) and no
   `eglot-server-programs` entry for it is added.
8. **Only once steps 1–7 above pass against a real project and a real
   `csharp-ls`** (i.e. the single-shared-connection adoption mechanism is
   confirmed working at runtime, not just by code review): update
   `DESIGN.md` with the "Mechanism 5" section described in Files Changed
   Summary below. Don't write up the mechanism in `DESIGN.md` — which is
   documentation for contributors describing how the *shipped* code
   actually behaves — before it's been verified to behave that way;
   `DESIGN.md`'s existing sections (see the "Correction" episode in
   `plans/transitive-metadata-navigation.md`) are written from confirmed
   runtime behaviour, not from the pre-implementation design, and this
   addition should follow the same discipline.

## Manual Verification Findings (real-world regression found & fixed)

Investigated after a report that `~/src/test-csharp-web`'s
`Pages/Index.cshtml` "does not work" in Emacs.

### Root cause: downstream wiring was never actually done

This plan's own status line and "Files Changed Summary" table (as
originally written) claimed `~/.config/doom/config.el` had already been
updated to hook `eglot-csharp-mode` onto `eglot-csharp-cshtml-mode`,
marking that row **Done**. Inspecting the *actual* file found this was
untrue — `~/.config/doom/config.el` only had:

```elisp
(add-hook 'csharp-mode-hook    #'eglot-csharp-mode)
(add-hook 'csharp-ts-mode-hook #'eglot-csharp-mode)
```

with no `eglot-csharp-cshtml-mode-hook` entry at all. Confirmed via the
live Emacs instance: `Pages/Index.cshtml` was correctly visited in
`eglot-csharp-cshtml-mode` (so the `auto-mode-alist` half of the feature
*was* working — `web-mode` is installed, `eglot-csharp-cshtml-mode` is
defined), but the buffer's `eglot-csharp-mode` variable was `nil`. Since
nothing ever called `eglot-csharp-mode` for that major mode, `eglot` never
started or attached a `csharp-ls` connection for the buffer at all — no
diagnostics, hover, completion, or navigation, exactly matching the "does
not work" report. This is a plain documentation/inventory error in this
plan (the config change was designed and written up here, but the actual
edit to the downstream file was apparently never applied), not a bug in
`eglot-csharp.el` itself.

**Fix applied:** added the missing line to
`~/.config/doom/config.el`:

```elisp
(add-hook 'eglot-csharp-cshtml-mode-hook #'eglot-csharp-mode)
```

### Runtime confirmation of the core mechanism

With the hook fix in place (and applied live to the running Emacs via
`eglot-csharp-mode`/`eglot--connect` calls in the already-open
`Index.cshtml` buffer, since that buffer had been visited before the
config fix), the underlying `eglot-csharp.el` machinery was exercised
directly against the real `csharp-ls` executable
(`/Users/bob/bin/csharp-ls`) and the real `test-csharp-web` project:

- `eglot--lookup-mode` and `eglot--guess-contact` resolve
  `eglot-csharp-cshtml-mode` correctly to
  `(eglot-csharp--server ("csharp-ls") ("razor"))` — confirming the
  contact-function fix from the "Correction" note (Design step 4/5) holds
  up outside the earlier isolated smoke test.
- Calling `eglot--connect` with that guessed contact against the real
  project successfully spawned `csharp-ls` and completed the LSP
  `initialize` handshake, returning real server capabilities
  (`diagnosticProvider`, `hoverProvider`, `completionProvider`,
  `definitionProvider`, `referencesProvider`, `semanticTokensProvider`,
  etc.), and the resulting `eglot-csharp--server` object's
  `eglot--languages` slot correctly recorded
  `((eglot-csharp-cshtml-mode . "razor"))`.
- After connecting, `eglot-current-server` / `eglot--managed-mode` in the
  buffer reflected the live connection as expected.

This confirms the "`.cshtml` opened with no pre-existing project server"
path (one half of Design step 5's two orderings) works end-to-end against
a real `csharp-ls`, not just via code tracing. It does **not** yet confirm:
the shared-connection *adoption* path (opening a `.cs` buffer in the same
project afterwards, or before, and checking only one `csharp-ls` process
exists), cross-file `xref-find-definitions`/`references` between `.cshtml`
and `.cs`, or the `eglot-csharp-enable-cshtml` toggle — those parts of the
Manual Verification Plan below remain outstanding.

### Secondary, non-bug observation: `eglot-ensure`/`eglot--maybe-activate-editing-mode` need a selected buffer

While reproducing this via MCP-driven `eval-elisp` calls (which run code
inside a transient `with-current-buffer`, not by actually selecting the
`.cshtml` buffer in a window), `eglot-ensure`'s buffer-local
`post-command-hook` addition and `eglot--maybe-activate-editing-mode` did
not fire, because Emacs only runs a buffer-local hook when that buffer is
the *currently selected* one when the hook runs — which it wasn't in that
test harness. This is expected Emacs behaviour, not a bug in
`eglot-csharp.el` or `eglot` itself, and does not affect normal
interactive use (where the visited buffer *is* selected in a window). Only
directly calling `eglot--connect` with the guessed contact — bypassing
`eglot-ensure`'s deferred scheduling — demonstrated the connection working
in that non-interactive test setup. Noted here so future
non-interactive/scripted verification of this feature isn't misdiagnosed
as a connection bug.

## Known Limitations / Out of Scope

- **`web-mode` is a soft dependency.** Not declared in `Package-Requires`;
  users must install it themselves for `.cshtml` support. Document this in
  the README.
- **Razor cohosting** (`UseRazorCohostServer=true`, VS 2026+/Roslyn's newer
  in-process Razor architecture) suppresses `RazorSourceGenerator`'s
  output entirely; per
  `~/src/csharp-language-server/plans/razor-sdk-300-investigation.md`,
  `csharp-ls` doesn't yet detect or warn about this. If a project enables
  it, Razor support will silently stop working — not something
  `eglot-csharp` can detect or fix from the client side.
- **No special handling for Razor-specific completion triggers** (e.g. `@`
  triggering a C#-expression completion context inside otherwise-HTML
  markup). `eglot`'s completion-at-point relies on the server's declared
  trigger characters; whatever `csharp-ls` reports is used as-is. If
  `@`-triggered completion feels wrong in practice, that would be a
  separate, targeted follow-up (likely in `csharp-ls` itself, not here).
- **`eglot-csharp--metadata-uri-handler`'s decompiled/generated buffers**
  are always opened as plain `.cs` files (never `.cshtml`), so this
  feature is orthogonal to and unaffected by the metadata-URI mechanism
  described in `DESIGN.md`.
- This plan does not attempt to support `.razor` (Blazor component) files.
  `csharp-ls`'s Razor support and `razorCsharpDocumentFilter` are scoped to
  `**/*.cshtml` only; Blazor's compilation model differs enough that it
  would need separate investigation on the server side first.

## Files Changed Summary

| File | Change | Status |
|---|---|---|
| `eglot-csharp.el` | Add `eglot-csharp-enable-cshtml` and `eglot-csharp-razor-support` defcustoms; add `eglot-csharp--server` class; add `eglot-csharp-cshtml-mode` (derived from `web-mode`) + `auto-mode-alist` entry, gated by `eglot-csharp-enable-cshtml`; update `eglot-csharp--workspace-configuration` to include `:razorSupport`; update `eglot-csharp--activate` to register per-mode `eglot-server-programs` entries tagged with `eglot-csharp--server` (with `:language-id "razor"` for the cshtml mode, via a proper `#'eglot-csharp--contact` function contact — see the "Correction" note) and to adopt into an already-running project server via `eglot-csharp--find-server` (extended, not duplicated) / `eglot-csharp--adopt-into` / `eglot-csharp--language-id-for-mode` instead of unconditionally calling `eglot-ensure`; update module `;;; Commentary:` | **Done**; byte-compiles clean; contact/class-resolution logic smoke-tested in isolation; **not yet runtime-verified** (Manual Verification Plan) |
| `README.md` | Document `.cshtml`/Razor support: `web-mode` soft dependency, `eglot-csharp-cshtml-mode-hook` setup snippet, `eglot-csharp-enable-cshtml` / `eglot-csharp-razor-support` customization entries, updated `use-package`/Doom snippets | **Done** |
| `CHANGELOG.md` | Add entry under an `Unreleased`/next-version heading | **Done** |
| `DESIGN.md` | **After** manual verification (Manual Verification Plan) confirms the mechanism works at runtime — add a "Mechanism 5: sharing one connection across `.cs` and `.cshtml`" section documenting the adoption mechanism and why naive `eglot-server-programs` merging isn't sufficient (condensed version of the "Background" section above). Not written up-front alongside the code change. | **Pending** manual verification |
| `~/.config/doom/config.el` (downstream, not part of this repo) | `(add-hook 'eglot-csharp-cshtml-mode-hook #'eglot-csharp-mode)` | Previously recorded here as **Done**, but this row was **inaccurate** — the actual file was never edited, which is the root cause of the real-world "`Index.cshtml` does not work" report (see "Manual Verification Findings" above). **Now actually applied** (both to the file and live-loaded into the running Emacs) and confirmed the `.cshtml`-first connection path works against a real `csharp-ls`. |
