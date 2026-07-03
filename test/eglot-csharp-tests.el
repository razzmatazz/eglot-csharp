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

(ert-deftest eglot-csharp-test-workspace-configuration-ignores-other-servers ()
  "Returns nil for any SERVER that isn't an `eglot-csharp--server'.

This is what makes it safe to install as the *global default* value of
`eglot-workspace-configuration' (see DESIGN.md, \"Mechanism 2\") without
affecting unrelated language servers' configuration.

TODO: once there's a lightweight way to construct (or stub) a real
`eglot-csharp--server' instance without spawning an actual `csharp-ls'
process, add the complementary case here: that a genuine
`eglot-csharp--server' gets the full `:csharp' plist, that
`eglot-csharp-locale'/`eglot-csharp-solution-path-override'/
`eglot-csharp-log-level' are omitted when nil, and included when set."
  (should (null (eglot-csharp--workspace-configuration nil)))
  (should (null (eglot-csharp--workspace-configuration 'not-a-server))))

;;; eglot-csharp-cshtml-mode

(ert-deftest eglot-csharp-test-cshtml-mode-derives-from-web-mode ()
  "eglot-csharp-cshtml-mode is a thin web-mode derivative."
  (skip-unless (require 'web-mode nil t))
  (with-temp-buffer
    (eglot-csharp-cshtml-mode)
    (should (derived-mode-p 'web-mode))))

(provide 'eglot-csharp-tests)
;;; eglot-csharp-tests.el ends here
