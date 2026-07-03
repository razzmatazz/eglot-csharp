# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [0.2.0] - 2026-07-03
* **Breaking:** raise minimum Emacs version from 28.1 to **30.1**, to lint
  cleanly against the eglot internals this package relies on.
* Add `.cshtml` (Razor) support via a new `eglot-csharp-cshtml-mode`,
  sharing the same `csharp-ls` connection as a project's `.cs` buffers.
  See [plans/cshtml-razor-support.md](plans/cshtml-razor-support.md).
* Fix `eglot-csharp-use-metadata-uris`/`eglot-csharp-razor-support` never
  actually reaching csharp-ls (`setq-local` on `eglot-workspace-configuration`
  doesn't work — see [DESIGN.md](DESIGN.md), "Mechanism 2").
* Expose more of csharp-ls's `workspace/configuration` tunables:
  `eglot-csharp-analyzers-enabled`, `eglot-csharp-apply-formatting-options`,
  `eglot-csharp-locale`, `eglot-csharp-solution-path-override`,
  `eglot-csharp-log-level`, `eglot-csharp-debug-mode` — all overridable
  per-project via `.dir-locals.el`.
* Fix transitive go-to-definition/hover/etc. *inside* decompiled and
  source-generated buffers; such buffers are now also read-only. See
  [DESIGN.md](DESIGN.md) /
  [plans/transitive-metadata-navigation.md](plans/transitive-metadata-navigation.md).
* Add a Docker/Eask `compile`/`lint`/`test`/`ci` harness (imported from
  [octocat.el](https://github.com/octocat.el/octocat.el)) and matching
  GitHub Actions workflow.

## [0.1.0] - 2026
* Initial release: registers csharp-ls as the eglot server for
  `csharp-mode` / `csharp-ts-mode`, enables `useMetadataUris`, and handles
  `csharp:/' URIs returned by csharp-ls by fetching decompiled source via
  `csharp/metadata' and caching it to disk so go-to-definition,
  go-to-implementation, and find-references can navigate into decompiled
  BCL/NuGet sources.
