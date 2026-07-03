;; -*- mode: eask; lexical-binding: t -*-

(package "eglot-csharp"
         "0.1.0"
         "C# extension for the eglot LSP client")

(website-url "https://github.com/razzmatazz/eglot-csharp")
(keywords "convenience" "languages" "csharp" "dotnet")

(package-file "eglot-csharp.el")

(source "gnu")
(source "melpa")

(depends-on "emacs"   "30.1")
(depends-on "eglot"   "1.16")
(depends-on "jsonrpc" "1.0.0")

;; web-mode is a soft runtime dependency (see eglot-csharp-cshtml-mode) and
;; therefore NOT listed in eglot-csharp.el's Package-Requires header.  It is
;; needed here only so test/eglot-csharp-tests.el can exercise
;; eglot-csharp-cshtml-mode in CI.
(development
 (depends-on "web-mode"))
