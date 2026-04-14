# glyf

Semantic, local-first terminal emulator.

Written in Zig. Cross-platform (Linux / macOS / Windows). GPU-accelerated.
Target latency under 5 ms.

Status: pre-alpha. Nothing works yet.

## Build

```sh
zig build           # build the binary
zig build run       # run glyf
zig build test      # run unit tests
```

Requires Zig 0.15.2 or newer.

## What makes glyf different

- Semantic blocks built on OSC 133 (open standard, not a closed
  Warp-style protocol). Folding, replay, export.
- Local-first. Optional local AI (Ollama, llama.cpp). No mandatory
  account, no telemetry by default.
- Integrated multiplexer. Persistent sessions without tmux or Zellij.
- Agent-friendly. Structured blocks exposed via MCP so external
  agents (Claude Code, Cursor, others) can read them.

## License

MIT. See [LICENSE](LICENSE).
