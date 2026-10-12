# Agent Instructions

## Project
zmx is a terminal session manager written in Zig.

## Commands
- Build: `zig build -Dtarget=x86_64-linux-gnu --cache-dir /scratch/zmx-cache --global-cache-dir /scratch/zmx-global-cache --prefix /scratch/zmx-out`
- Check: `zig build check -Dtarget=x86_64-linux-gnu --cache-dir /scratch/zmx-cache --global-cache-dir /scratch/zmx-global-cache`
- Test: `zig build test -Dtarget=x86_64-linux-gnu --cache-dir /scratch/zmx-cache --global-cache-dir /scratch/zmx-global-cache`
- Format check: `zig fmt --check src/*.zig build.zig`

## Rules
- The default version is in `build.zig.zon`: `0.8.1-eslgastal.N`. N counts feature-branch merges into `main` and is currently 2. After **each feature-branch merge into main**, increase N by 1 in `build.zig.zon`. Do not increment it for ordinary commits or non-feature merges.
- Put all build caches and artifacts in `/scratch`; do not recreate `.zig-cache` or `zig-out` in the repository.
- Do not edit `zig-pkg/` (vendored dependencies) or generated files unless explicitly asked.

## Done
- Run the narrowest relevant check and report its result.
