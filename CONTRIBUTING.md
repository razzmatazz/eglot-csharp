# Contributing to eglot-csharp

See README.md's "Development" section for building and testing (`make ci`).

Before building any plist that's sent to `csharp-ls`, read
[`(elisp) Parsing JSON`](https://www.gnu.org/software/emacs/manual/html_node/elisp/Parsing-JSON.html)
and how `jsonrpc--json-encode` in `jsonrpc.el` calls `json-serialize`.

In particular, jsonrpc encodes with `:false-object :json-false`. Use
`:json-false` for JSON `false`, not `:false` (which is `json-serialize`'s
default). A `:false` value makes the whole payload fail with
`(wrong-type-argument json-value-p :false)`. Note that `nil` encodes as
`null`, not `false`.
