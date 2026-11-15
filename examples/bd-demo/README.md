# back-directory asciinema demo

This directory contains a reproducible asciinema demo for back-directory using a shell-based automation script.

## Files

- `demo.sh`: automated demo script
- `demo-magic.sh`: vendored helper for simulated typing
- `pv`: minimal local shim for typing speed control (avoids external dependency)

## Prerequisites

- `asciinema`
- `bash`
- `bd-core` available on PATH, or a local build at `target/release/bd-core`

Enter the pinned environment first:

```bash
nix develop
```

## Record

```bash
scripts/demo-media.sh record
```

The recording starts in `examples/bd-demo`, and all demo paths are relative to that directory.

## Re-record

```bash
scripts/demo-media.sh record
```

## Play

```bash
asciinema play examples/bd-demo/media/bd-demo.cast
```

## Convert to WebP

Convert the recording directly to WebP:

```bash
scripts/demo-media.sh render
```

Recording requires an interactive terminal and therefore stays a local operation. CI runs
`scripts/demo-media.sh check` to validate that the committed cast and WebP are present.

After converting, replace the demo image in the repository root `README.md` with
`examples/bd-demo/media/bd-demo.webp`.

## Notes

- The demo relies on directory structure only; no prompt customization is used.
