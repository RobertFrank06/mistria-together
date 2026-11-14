# Contributor and Agent Notes

## Ownership and attribution

- Robert (`RobertFrank06`) is the project owner and maintainer.
- Claude and Codex are assistant tools used by the maintainer; do not list or
  credit them as project authors or contributors.
- The next release is `1.1.0`; move through the `1.x` line for ordinary updates
  (for example, `1.2.0`, `1.3.0`). Reserve a new major version such as `2.0.0`
  for a genuinely major compatibility or product change. Use patch versions
  for fixes between minor releases.

## Project map

- `mod/mt/gml/`: in-game mod scripts.
- `companion/src/`: Rust companion and network/session code.
- `companion/tests/`: real-socket companion integration tests.
- `tools/rig.sh` and `tools/e2e.sh`: Linux game test rig. It must use its
  isolated game and save directories; never install test changes into the
  user's live game or modify real saves.
- `README.md`: player-facing install and usage guide, shipped behavior only.
- `DESIGN.md`: the stable decisions: what is being built, why, and the
  constraints. No status or to-do items.
- `IMPLEMENT.md`: the ordered work checklist, status, verified game facts and
  message reference. Follow its order (test suite first, scenario before
  feature) and tick tasks as they land. Change `DESIGN.md` first if a task
  needs a rule to change.
- `tools/gametest.py` (once Phase 0 lands) is the automated game test suite.

## Rules

- Keep game networking in the Rust companion; GML communicates through the
  file bridge.
- Treat farm/world state as host-owned and player inventory, money, skills,
  relationships, character identity, and story as personal. Verify save/load
  ownership before expanding synchronization.
- Never overwrite an existing guest-save backup on reconnect.
- Keep the standalone mod ZIP as a convenience. MOMI needs the extracted
  `mt/manifest.toml` folder.
- Keep `companion/Cargo.toml`, `mod/mt/manifest.toml`, and `MT_VERSION` in
  `mod/mt/gml/MtBoot.gml` on the same release version. Bump `MT_PROTO` only
  when wire messages change.
- Avoid new dependencies and generated files unless the task needs them.

## Useful checks

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features --locked
cargo build --release --locked
tools/package-mod.sh /tmp/mistria-together-package-check
```

The game rig requires a local Linux game install and MOMI. Run
`tools/rig.sh setup` before `tools/rig.sh install`; keep all rig data in its
isolated runtime directory. Do not point MOMI or test scripts at the user's
actual game folder.
