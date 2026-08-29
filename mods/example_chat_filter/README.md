# example_chat_filter

Example Wasm plugin that filters chat: suppresses messages containing `bad` and
rewrites `hello` to `hi`. The reference for writing a drop-in mod.

## What it is

A minimal user-tier plugin demonstrating the `on_chat` request/reply hook:
read the message from the host-provided buffer, deny or rewrite it, write the
reply back.

## Hooks

- `on_chat(sender, msg_ptr, msg_len, out_ptr, out_cap) -> i32` (<0 deny, 0 keep,
  >0 bytes of the rewritten body)

## Config

None; the filter rules are the example's inline policy.

## Enable

Ships `enabled = false` (demo). Load explicitly via
`[plugin] modules = "mods/example_chat_filter/example_chat_filter.wasm"`.

## Layout (self-contained)

- `manifest.toml`, `example_chat_filter.wasm`, `example_chat_filter.c` (source),
  `README.md`
