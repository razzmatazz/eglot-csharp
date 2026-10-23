# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
* **Breaking:** require csharp-ls 0.29.0+; settings go in `initializationOptions`, leaving `eglot-workspace-configuration` to you.
* Test on Emacs 30.2 and 31.1 in CI.
* Fix `LICENSE` to hold the GPL v3 text the headers state.

## [0.2.1] - 2026-10-20
* Fix settings never reaching csharp-ls when a boolean option was off. Reported by Craig Brozefsky.

## [0.2.0] - 2026-07-03
* **Breaking:** require Emacs 30.1+.
* Add `.cshtml` (Razor) support via `eglot-csharp-cshtml-mode`, sharing the `.cs` buffers' connection.
* Fix `eglot-csharp-use-metadata-uris` and `eglot-csharp-razor-support` never reaching csharp-ls.
* Add options for analyzers, formatting options, locale, solution path, log level and debug mode.
* Fix navigation inside decompiled and source-generated buffers, which are now read-only.
* Add a Docker/Eask build harness and GitHub Actions CI.

## [0.1.0] - 2026
* Initial release: csharp-ls for `csharp-mode`/`csharp-ts-mode`, with navigation into decompiled sources.
