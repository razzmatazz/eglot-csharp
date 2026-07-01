# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
* Fix transitive go-to-definition/hover/etc. *inside* decompiled and
  source-generated buffers (e.g. clicking a parameter type in a decompiled
  BCL method signature did nothing). Decompiled/generated buffers are now
  also marked read-only.
  - See [DESIGN.md](DESIGN.md) for how this works, and
    [plans/transitive-metadata-navigation.md](plans/transitive-metadata-navigation.md)
    for the investigation that led to it.

## [0.1.0] - 2026
* Initial release: registers csharp-ls as the eglot server for
  `csharp-mode` / `csharp-ts-mode`, enables `useMetadataUris`, and handles
  `csharp:/' URIs returned by csharp-ls by fetching decompiled source via
  `csharp/metadata' and caching it to disk so go-to-definition,
  go-to-implementation, and find-references can navigate into decompiled
  BCL/NuGet sources.
