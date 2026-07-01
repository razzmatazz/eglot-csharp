;;; eglot-csharp.el --- C# extension for the eglot LSP client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Saulius Menkevičius

;; Version: 0.1.0
;; Author: Saulius Menkevičius <sauliusmenkevicius@fastmail.com>
;; Maintainer: Saulius Menkevičius <sauliusmenkevicius@fastmail.com>
;; Assisted-by: Claude:claude-sonnet-4-6
;; URL: https://github.com/razzmatazz/eglot-csharp
;; Keywords: convenience, languages, csharp, dotnet
;; Package-Requires: ((emacs "28.1") (eglot "1.16") (jsonrpc "1.0.0"))

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; C# extension for the eglot LSP client, built around csharp-language-server
;; (csharp-ls): https://github.com/razzmatazz/csharp-language-server
;;
;; Key features:
;;
;;   - Registers csharp-ls as the eglot server for csharp-mode / csharp-ts-mode
;;   - Registers csharp-ls for `.cshtml' (Razor) files too, via a thin
;;     `web-mode'-derived `eglot-csharp-cshtml-mode', sharing the same
;;     connection as a project's .cs buffers rather than starting a second,
;;     redundant csharp-ls process
;;   - Enables `useMetadataUris' so that go-to-definition, go-to-implementation,
;;     and find-references all navigate into decompiled BCL/NuGet sources
;;   - Enables `razorSupport' so that `.cshtml' documents get diagnostics,
;;     hover, completion, and navigation from csharp-ls
;;   - Handles `csharp:/' URIs returned by csharp-ls by fetching the decompiled
;;     source via `csharp/metadata' and caching it to disk as a regular file
;;
;; The `csharp:/' URI handler is modeled after eglot-java's `jdt://' handler:
;; https://github.com/yveszoundi/eglot-java/blob/main/eglot-java.el
;; Both write decompiled source to a per-project cache directory and return
;; the on-disk path so Emacs opens it as a normal file.
;;
;; Usage:
;;
;;   (require 'eglot-csharp)
;;
;;   Then open any .cs file in a project that has a .sln or .csproj —
;;   `eglot-csharp-mode' activates eglot automatically via the mode hook.
;;
;; Or activate manually:
;;
;;   M-x eglot-csharp-mode
;;
;; Sample minimal configuration (use-package):
;;
;;   (use-package eglot-csharp
;;     :hook ((csharp-mode csharp-ts-mode) . eglot-csharp-mode))

;;; Code:

(require 'eglot)
(require 'jsonrpc)
(require 'project)
(require 'subr-x)
(require 'cl-lib)
(require 'eieio)

;;; Customization

(defgroup eglot-csharp nil
  "C# language support for eglot via csharp-language-server."
  :prefix "eglot-csharp-"
  :group 'eglot
  :link '(url-link :tag "GitHub" "https://github.com/razzmatazz/eglot-csharp")
  :link '(url-link :tag "csharp-ls" "https://github.com/razzmatazz/csharp-language-server"))

(defcustom eglot-csharp-server-program "csharp-ls"
  "Path or name of the csharp-ls executable."
  :type 'string
  :group 'eglot-csharp)

(defcustom eglot-csharp-use-metadata-uris t
  "When non-nil, ask csharp-ls to return `csharp:/' URIs for metadata symbols.
This enables go-to-definition, go-to-implementation, and find-references to
navigate into decompiled BCL and NuGet sources.  Requires csharp-ls ≥ 0.21."
  :type 'boolean
  :group 'eglot-csharp)

(defcustom eglot-csharp-metadata-cache-directory ".cache/eglot-csharp/metadata"
  "Directory for caching decompiled source files, relative to the project root.
Each decompiled file is cached here as a plain .cs file so Emacs can open it
without special handling on subsequent visits."
  :type 'string
  :group 'eglot-csharp)

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
via the `csharp.razorSupport' workspace-configuration setting.  Requires
csharp-ls with Razor support (see csharp-ls's docs/features.md)."
  :type 'boolean
  :group 'eglot-csharp)

;;; Server class

(defclass eglot-csharp--server (eglot-lsp-server) ()
  "`eglot-lsp-server' subclass identifying csharp-ls connections started by
`eglot-csharp-mode', regardless of which major mode(s) the connection
currently manages.

Lets `eglot-csharp--find-server' distinguish \"our\" server from any other,
unrelated LSP server that might be registered for the same project (e.g. an
HTML/CSS language server also managing `web-mode' buffers).")

;;; Internal helpers

(defun eglot-csharp--metadata-uri-cache-file (uri)
  "Return the cache file path for a `csharp:/' URI.

Example:
  csharp:/.../project1.csproj/decompiled/System.Console.cs
  -> <project-root>/.cache/eglot-csharp/metadata/System.Console.cs

Uses `string-match' rather than `file-name-nondirectory' to extract the
basename, so that `file-name-handler-alist' is not triggered recursively
on the `csharp:/' URI itself.  This mirrors how eglot-java parses `jdt://'
URIs with `string-match' rather than path functions."
  (let* ((proj-root (project-root (project-current t)))
         (cache-dir (expand-file-name eglot-csharp-metadata-cache-directory
                                      proj-root))
         (basename  (and (string-match "/\\([^/]+\\)\\'" uri)
                         (match-string 1 uri))))
    (expand-file-name basename cache-dir)))

(defun eglot-csharp--find-server ()
  "Return the active `eglot-csharp--server' for the current project, or nil.

Filters by the `eglot-csharp--server' class (see above) so that, if some
other unrelated LSP server also happens to be registered for the current
project (e.g. a JSON or HTML language server), it isn't mistaken for the
csharp-ls connection this package manages."
  (when-let* ((project (eglot--current-project))
              (servers (gethash project eglot--servers-by-project)))
    (cl-find-if (lambda (s) (cl-typep s 'eglot-csharp--server)) servers)))

(defun eglot-csharp--metadata-uri-sidecar-file (cache-file)
  "Return the sidecar file path recording CACHE-FILE's originating URI.

csharp-ls tracks decompiled/generated documents purely by their `csharp:/'
URI (see `csharp/metadata'); it has no notion of the on-disk cache file
eglot-csharp writes them to.  We record the original URI here so that LSP
requests concerning CACHE-FILE can later be addressed using that URI again
(see `eglot-csharp--path-to-uri'), instead of a meaningless `file://' URI
derived from CACHE-FILE.  This mirrors `lsp-csharp--cls-before-file-open'
in lsp-mode's csharp-ls client, which uses the same `.metadata-uri' sidecar
convention."
  (concat cache-file ".metadata-uri"))

(defun eglot-csharp--metadata-uri-for-path (path)
  "Return the metadata URI PATH was cached from, or nil.

Looks up the `.metadata-uri' sidecar written by
`eglot-csharp--metadata-uri-handler' next to PATH (see
`eglot-csharp--metadata-uri-sidecar-file').  Returns nil for ordinary
project files, which have no such sidecar."
  (let ((sidecar (eglot-csharp--metadata-uri-sidecar-file path)))
    (when (file-readable-p sidecar)
      (string-trim
       (with-temp-buffer
         (insert-file-contents sidecar)
         (buffer-string))))))

;;; `csharp:/' URI handler

(defun eglot-csharp--metadata-uri-handler (_operation &rest args)
  "Handle file operations for `csharp:/' URIs.

Fetches decompiled source via the `csharp/metadata' LSP extension method,
writes it to a per-project cache file, and returns that file path so Emacs
opens it as a normal file.

Modeled after eglot-java's `eglot-java--jdt-uri-handler':
https://github.com/yveszoundi/eglot-java/blob/main/eglot-java.el"
  (let* ((uri        (car args))
         (cache-file (eglot-csharp--metadata-uri-cache-file uri))
         (sidecar    (eglot-csharp--metadata-uri-sidecar-file cache-file)))
    (unless (file-readable-p cache-file)
      (let* ((server   (or (eglot-csharp--find-server)
                           (user-error
                            "eglot-csharp: no active server for %s" uri)))
             (response (jsonrpc-request server
                         :csharp/metadata
                         `(:textDocument (:uri ,uri))))
             (source   (or (plist-get response :source)
                           (user-error
                            "eglot-csharp: csharp/metadata returned no source for %s" uri))))
        (make-directory (file-name-directory cache-file) t)
        (with-temp-file cache-file
          (insert source))))
    ;; Record the originating `csharp:/' URI next to the cached source, so
    ;; that `eglot-csharp--metadata-uri-for-path' can later re-associate a
    ;; buffer visiting this file with it.  Written unconditionally (not just
    ;; on first fetch) so a cache file left over from an older version of
    ;; this package without a sidecar self-heals on next access.
    (unless (and (file-readable-p sidecar)
                (equal uri (with-temp-buffer
                            (insert-file-contents sidecar)
                            (buffer-string))))
      (with-temp-file sidecar
        (insert uri)))
    cache-file))

;; Register the handler globally at load time.  The handler must be present
;; whenever csharp-ls is running, not only while a particular buffer's minor
;; mode is active, because eglot may resolve `csharp:/' URIs at any time.
(add-to-list 'file-name-handler-alist
             (cons "\\`csharp:/" #'eglot-csharp--metadata-uri-handler))

;;; Workspace configuration

(defun eglot-csharp--workspace-configuration (server)
  "Return the eglot workspace configuration plist for csharp-ls SERVER.

Only returns the `:csharp' section when SERVER is one of this package's
own connections (an `eglot-csharp--server'; see `eglot-csharp--find-server')
so this is safe to install as the *global default* value of
`eglot-workspace-configuration' (see the installation form below) without
stepping on configuration some other, unrelated language server might need
for its own project."
  (when (cl-typep server 'eglot-csharp--server)
    `(:csharp (:useMetadataUris ,(if eglot-csharp-use-metadata-uris t :false)
               :razorSupport ,(if eglot-csharp-razor-support t :false)))))

;; Install `eglot-csharp--workspace-configuration' as the *global default*
;; value of `eglot-workspace-configuration', once, at load time — composing
;; with whatever function (if any) was already installed there so this
;; doesn't clobber configuration some other package already set up for its
;; own servers.
;;
;; This must NOT be done with `setq-local' inside `eglot-csharp--activate'
;; (what earlier versions of this package did and which silently had no
;; effect — confirmed at runtime against a real csharp-ls; see DESIGN.md's
;; "Mechanism 2: workspace configuration" for the full explanation of why
;; `setq-local' doesn't work here, and why this is a global-default
;; `setq-default' rather than `advice-add' on an eglot internal).
(let ((eglot-csharp--previous-workspace-configuration
       (default-value 'eglot-workspace-configuration)))
  (setq-default eglot-workspace-configuration
                (if (functionp eglot-csharp--previous-workspace-configuration)
                    (lambda (server)
                      (append (eglot-csharp--workspace-configuration server)
                              (funcall eglot-csharp--previous-workspace-configuration
                                       server)))
                  #'eglot-csharp--workspace-configuration)))

;;; Transitive navigation inside decompiled/generated buffers

(defun eglot-csharp--path-to-uri (orig-fun path &rest args)
  "Around advice for `eglot-path-to-uri' preserving metadata URIs.

If PATH is a cache file written out by `eglot-csharp--metadata-uri-handler'
(i.e. decompiled BCL/NuGet source or a source-generated file fetched via
`csharp/metadata'), return the `csharp:/' URI it was cached from instead of
calling ORIG-FUN (which would derive a `file://' URI from PATH).

`eglot--TextDocumentIdentifier' — the sole place eglot computes the URI
sent to the server for a buffer — always routes through `eglot-path-to-uri'
\(including every time it is recomputed, e.g. `eglot--signal-textDocument/
didOpen' unconditionally resets the per-buffer cache before reopening\), so
advising it here is sufficient to make every LSP request concerning such a
buffer address it by its original metadata URI.

This matters because csharp-ls tracks decompiled/generated documents
solely by that `csharp:/' URI (see `workspaceFolder' and
`workspaceFolderDocumentDetails' in csharp-language-server); a request
addressed by the cache file's `file://' URI matches nothing server-side and
silently returns no result — breaking navigation performed *from within*
such a buffer (e.g. go-to-definition on a parameter type appearing in a
decompiled method signature).

Does nothing for ordinary project source files, since no sidecar file
exists next to them; ORIG-FUN is called as usual in that case."
  (or (eglot-csharp--metadata-uri-for-path path)
      (apply orig-fun path args)))

(advice-add 'eglot-path-to-uri :around #'eglot-csharp--path-to-uri)

(defun eglot-csharp--maybe-mark-metadata-buffer-read-only ()
  "Make the current buffer read-only if it is visiting cached metadata source.

Decompiled/generated sources (see `eglot-csharp--metadata-uri-handler')
have no meaningful save target, and editing them would desync the buffer
from the URI the server thinks it is serving (see
`eglot-csharp--path-to-uri'), so mark them read-only.  Does nothing for
ordinary project source files."
  (when (and buffer-file-name
            (eglot-csharp--metadata-uri-for-path buffer-file-name))
    (setq buffer-read-only t)))

;;; `.cshtml' (Razor) support

(declare-function web-mode "web-mode")

(define-derived-mode eglot-csharp-cshtml-mode web-mode "Razor"
  "Major mode for ASP.NET Core Razor (`.cshtml') files.

A thin wrapper around `web-mode' (which already auto-detects the Razor
\"engine\" from the `.cshtml' extension for fontification purposes) whose
only job is to give `.cshtml' buffers a distinct major-mode symbol that
`eglot-server-programs' can key on, without affecting other `web-mode'
buffers (`.html', `.php', `.vue', ...) that have nothing to do with C#.

`web-mode' itself is not a dependency of this package — it must be
installed separately to use this mode.  See `eglot-csharp-enable-cshtml'
to disable this mode's `auto-mode-alist' registration below.")

;; Associate `.cshtml' files with `eglot-csharp-cshtml-mode' at load time,
;; mirroring how the `csharp:/' file-name-handler above is registered
;; unconditionally rather than tied to the minor mode.
(when eglot-csharp-enable-cshtml
  (add-to-list 'auto-mode-alist '("\\.cshtml\\'" . eglot-csharp-cshtml-mode)))

;;; Minor mode

(defvar eglot-csharp-mode-map (make-sparse-keymap)
  "Keymap for `eglot-csharp-mode'.")

;;;###autoload
(define-minor-mode eglot-csharp-mode
  "Toggle C# language support via eglot and csharp-ls.

When enabled:
  - Registers csharp-ls as the eglot server for the current major mode
  - Configures `useMetadataUris' so that go-to-definition and friends
    navigate into decompiled BCL/NuGet sources via `csharp:/' URIs
  - Configures `razorSupport' so that `.cshtml' buffers get diagnostics,
    hover, completion, and navigation
  - Starts (or reconnects) the eglot session — or, if a csharp-ls
    connection is already managing this project under a different major
    mode (e.g. `.cs' vs `.cshtml'), adopts this buffer into it instead of
    starting a redundant second connection"
  :init-value nil
  :lighter nil
  :keymap eglot-csharp-mode-map
  (if eglot-csharp-mode
      (eglot-csharp--activate)
    (eglot-csharp--deactivate)))

(defun eglot-csharp--language-id-for-mode (mode)
  "Return the LSP `languageId' string to use for MODE.

Used both when registering MODE with `eglot-server-programs' in
`eglot-csharp--activate' and when adopting a buffer into an
already-running server in `eglot-csharp--adopt-into'.  `eglot-server-programs'
would otherwise default to a language ID derived from MODE's name (stripping
a trailing `-mode'/`-ts-mode'), which is correct for `csharp-mode' and
`csharp-ts-mode' (\"csharp\") but wrong for `eglot-csharp-cshtml-mode'; the
latter needs \"razor\" to match csharp-ls's `razorCsharpDocumentFilter'."
  (if (eq mode 'eglot-csharp-cshtml-mode) "razor" "csharp"))

(defun eglot-csharp--adopt-into (server)
  "Add the current buffer's major mode to SERVER's managed languages and
activate `eglot--managed-mode' against it, without starting a new
connection.

Used when the current buffer's major mode isn't yet among an
already-running project SERVER's managed languages — e.g. a project's
first `.cshtml' buffer is opened after its `.cs' buffers already started a
server, or vice versa.  Without this, eglot would start a second,
redundant csharp-ls process for the same project (since a running
server's managed languages are fixed at connect time and eglot has no
built-in notion of \"this other connection would do just as well\"),
which would desync in-memory edits between the two connections.  See
plans/cshtml-razor-support.md for the full rationale."
  (cl-pushnew (cons major-mode (eglot-csharp--language-id-for-mode major-mode))
              (eglot--languages server)
              :key #'car)
  (eglot--maybe-activate-editing-mode))

(defun eglot-csharp--contact (&rest _)
  "Contact function for `eglot-server-programs' entries registered by
`eglot-csharp-mode' (see `eglot-csharp--activate').

Returns `eglot-csharp-server-program' wrapped with the `eglot-csharp--server'
class — evaluated fresh on every connection attempt (per eglot's contract
for function-valued CONTACTs, see `eglot--guess-contact') rather than a
literal list snapshotted once at `add-to-list' time, so that customizing
`eglot-csharp-server-program' at runtime is respected.

Must return `(CLASS . PROGRAM-LIST)'-shaped data as a *function result*
here, not as the literal `eglot-server-programs' entry itself: eglot only
strips a leading class symbol from the value returned after funcalling a
function-valued CONTACT (see the `class' binding in
`eglot--guess-contact'), not from a literal list that merely *contains* a
function among its elements."
  (list 'eglot-csharp--server eglot-csharp-server-program))

(defun eglot-csharp--activate ()
  "Set up csharp-ls and start eglot for the current buffer."
  ;; Register the server program for the active major mode, tagged with
  ;; `eglot-csharp--server' (see `eglot-csharp--find-server') and, for
  ;; `eglot-csharp-cshtml-mode', an explicit `:language-id'.
  (add-to-list 'eglot-server-programs
               (cons (if (eq major-mode 'eglot-csharp-cshtml-mode)
                         (list major-mode
                               :language-id (eglot-csharp--language-id-for-mode major-mode))
                       major-mode)
                     #'eglot-csharp--contact))
  ;; Workspace configuration (useMetadataUris/razorSupport) is wired up
  ;; globally at load time — see the `eglot-workspace-configuration'
  ;; installation form above `eglot-csharp--workspace-configuration'.
  ;; Cached decompiled/generated source buffers aren't meant to be edited.
  (eglot-csharp--maybe-mark-metadata-buffer-read-only)
  ;; If csharp-ls is already managing this project (e.g. reached via a `.cs'
  ;; buffer while this one is `.cshtml', or vice versa), share that
  ;; connection instead of starting a redundant second one.  Otherwise
  ;; start (or reconnect) normally.
  (if-let* ((server (eglot-csharp--find-server)))
      (eglot-csharp--adopt-into server)
    (eglot-ensure)))

(defun eglot-csharp--deactivate ()
  "Shut down the eglot session for the current buffer."
  (ignore-errors
    (call-interactively #'eglot-shutdown)))

(provide 'eglot-csharp)
;;; eglot-csharp.el ends here
