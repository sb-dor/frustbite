# Frustbite

Read audio metadata, waveforms and PCM from Dart, powered by Rust through FFI
and WebAssembly.

Read the [documentation](https://sb-dor.github.io/frustbite/) or see the
[package README](packages/frustbite/README.md) for API usage and the
[roadmap](packages/frustbite/README.md#roadmap).

Try it in the minimal [Flutter showcase](packages/showcase/README.md), and see
how it compares with other Dart audio packages in the
[benchmarks](packages/benchmark/README.md).

## Documentation

```bash
cd docs
npm install
npm run docs:dev
```

Blume builds the production site into `docs/dist/` with
`cd docs && npm run docs:build`.

See [AGENTS.md](AGENTS.md) for the repository layout and development commands.

## License

See [LICENSE](LICENSE). Third-party notices are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md); note that the bundled
`symphonia` decoders are MPL-2.0, and that file says where to get their source.

## Acknowledgements

Repository structure, build hooks and release flow adapted from
[hawkkiller/pixer](https://github.com/hawkkiller/pixer) (MIT, © 2026 Michael
Lazebny).
