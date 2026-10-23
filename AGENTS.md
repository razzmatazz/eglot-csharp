# Agent Instructions

See [README.md](README.md) for full project documentation.
See [CONTRIBUTING.md](CONTRIBUTING.md) for code conventions.

## Rules

- **Update `CHANGELOG.md` for significant changes**: anything a user would notice (features, key bindings, fixed bugs) or that changes which Emacs versions are supported or tested. Add a line under `## [Unreleased]`, worded for users, in the style of the entries already there. Keep each entry to one short line: what changed, not how or why.
- **Keep `Assisted-by:` headers complete.** Every `.el` file, tests included, lists each model that has worked on it, one line per model, as MELPA asks (`;; Assisted-by: AGENT_NAME:MODEL_VERSION`, e.g. `;; Assisted-by: Claude:claude-opus-5-5`). When you edit or create a file and your model is not listed there, add a line after the existing `Assisted-by:` lines, or, in a file with none, after the title line. Never remove a line. If the model is new to the project, also add it to the list in README.md's "AI Assistance" section. Every commit you make names your model in a `Co-Authored-By:` trailer, so `git log` shows which models worked on which file; check that history when you update a file's lines.
