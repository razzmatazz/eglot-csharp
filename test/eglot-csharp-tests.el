;;; eglot-csharp-tests.el --- ERT tests for eglot-csharp.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; Minimal starter test suite for eglot-csharp.el.  Run via:
;;   eask test ert test/eglot-csharp-tests.el
;; or, via the Docker-based harness (see README.md's "Development" section):
;;   make test
;;
;; These are deliberately limited to pure, in-process logic that needs no
;; running `csharp-ls' (or even a live eglot connection) — the
;; `eglot-server-programs' / `eglot--guess-contact' resolution logic and the
;; workspace-configuration plist builder.  This suite is a starting
;; scaffold, not full coverage; see the "TODO" comments below for the
;; obvious next things to add once there's a strategy for exercising a real
;; (or stubbed) `eglot-csharp--server' connection in CI.

;;; Code:

(require 'ert)
(require 'eglot)
(require 'eglot-csharp)

;;; eglot-csharp--language-id-for-mode

(ert-deftest eglot-csharp-test-language-id-for-cshtml-mode ()
  "cshtml mode maps to the \"razor\" languageId."
  (should (equal (eglot-csharp--language-id-for-mode 'eglot-csharp-cshtml-mode)
                 "razor")))

(ert-deftest eglot-csharp-test-language-id-for-csharp-modes ()
  "csharp-mode and csharp-ts-mode both map to the \"csharp\" languageId."
  (should (equal (eglot-csharp--language-id-for-mode 'csharp-mode) "csharp"))
  (should (equal (eglot-csharp--language-id-for-mode 'csharp-ts-mode) "csharp")))

;;; eglot-csharp--contact

(ert-deftest eglot-csharp-test-contact-shape ()
  "eglot-csharp--contact returns (CLASS . PROGRAM-LIST), not a nested list.

Regression test for the contact-function shape bug described in
plans/cshtml-razor-support.md (\"Correction: contact-function shape\") —
see that section for the full trace of why the naive, obvious-looking
shape is broken."
  (let ((eglot-csharp-server-program "csharp-ls"))
    (should (equal (eglot-csharp--contact) '(eglot-csharp--server "csharp-ls")))))

(ert-deftest eglot-csharp-test-contact-respects-customized-server-program ()
  "eglot-csharp--contact re-reads eglot-csharp-server-program on every call."
  (let ((eglot-csharp-server-program "/opt/bin/csharp-ls"))
    (should (equal (eglot-csharp--contact)
                   '(eglot-csharp--server "/opt/bin/csharp-ls")))))

;;; eglot-csharp--workspace-configuration

(defmacro eglot-csharp-test--with-server (var &rest body)
  "Run BODY with VAR bound to a real `eglot-csharp--server' instance.

The instance is backed by a throwaway pipe process rather than an actual
`csharp-ls', so nothing external is spawned; the process and any buffers
created alongside it are cleaned up afterwards."
  (declare (indent 1))
  `(let* ((before (buffer-list))
          (proc (make-pipe-process :name "eglot-csharp-test" :noquery t)))
     (unwind-protect
         (let ((,var (make-instance 'eglot-csharp--server :process proc)))
           ,@body)
       (delete-process proc)
       (dolist (buf (buffer-list))
         (unless (memq buf before)
           (kill-buffer buf))))))

(ert-deftest eglot-csharp-test-workspace-configuration-ignores-other-servers ()
  "Returns nil for any SERVER that isn't an `eglot-csharp--server'.

This is what makes it safe to install as the *global default* value of
`eglot-workspace-configuration' (see DESIGN.md, \"Mechanism 2\") without
affecting unrelated language servers' configuration."
  (should (null (eglot-csharp--workspace-configuration nil)))
  (should (null (eglot-csharp--workspace-configuration 'not-a-server))))

(ert-deftest eglot-csharp-test-workspace-configuration-encodes-false ()
  "Disabled boolean settings serialize as JSON false via jsonrpc.

Regression test: these used to be sent as `:false', which
`jsonrpc--json-encode' (`json-serialize' with `:false-object :json-false')
rejects with `wrong-type-argument', so the whole `:csharp' section never
reached csharp-ls.  See CONTRIBUTING.md."
  (eglot-csharp-test--with-server server
    (let ((eglot-csharp-use-metadata-uris nil)
          (eglot-csharp-razor-support nil)
          (eglot-csharp-analyzers-enabled nil)
          (eglot-csharp-apply-formatting-options nil))
      (should (equal (jsonrpc--json-encode
                      (eglot-csharp--workspace-configuration server))
                     (concat "{\"csharp\":{\"useMetadataUris\":false,"
                             "\"razorSupport\":false,"
                             "\"analyzersEnabled\":false,"
                             "\"applyFormattingOptions\":false}}"))))))

(ert-deftest eglot-csharp-test-workspace-configuration-optional-settings ()
  "String settings are omitted when nil and included when set."
  (eglot-csharp-test--with-server server
    (let ((eglot-csharp-locale nil)
          (eglot-csharp-solution-path-override nil)
          (eglot-csharp-log-level nil))
      (let ((section (plist-get (eglot-csharp--workspace-configuration server)
                                :csharp)))
        (should-not (plist-member section :locale))
        (should-not (plist-member section :solutionPathOverride))
        (should-not (plist-member section :logLevel))))
    (let ((eglot-csharp-locale "en-US")
          (eglot-csharp-solution-path-override "/src/Foo.sln")
          (eglot-csharp-log-level "debug"))
      (let ((section (plist-get (eglot-csharp--workspace-configuration server)
                                :csharp)))
        (should (equal (plist-get section :locale) "en-US"))
        (should (equal (plist-get section :solutionPathOverride) "/src/Foo.sln"))
        (should (equal (plist-get section :logLevel) "debug"))))))

;;; eglot-csharp-cshtml-mode

(ert-deftest eglot-csharp-test-cshtml-mode-derives-from-web-mode ()
  "eglot-csharp-cshtml-mode is a thin web-mode derivative."
  (skip-unless (require 'web-mode nil t))
  (with-temp-buffer
    (eglot-csharp-cshtml-mode)
    (should (derived-mode-p 'web-mode))))

(provide 'eglot-csharp-tests)
;;; eglot-csharp-tests.el ends here
