# imprynt

Managed materialization of Nix-built files outside the Nix store.

**Early development: use only disposable directories.** The internal Zig engine
can install, update, and remove regular files with journaled recovery. There is
no stable public API, deployment CLI, tree generator, or framework module yet.

The first use case is real-file font installation on macOS. Planned first-party
integrations are Home Manager, nix-darwin, and NixOS; other integrations will
use the same generation and application building blocks. The engine takes
explicit destinations and runs with the caller's privileges.

## Behavior

- Own individual files, leaving unrelated manual files alone.
- Reject conflicts before changing managed destinations.
- Recover interrupted applications by rolling back before commit or finishing
  cleanup after commit.
- Stop recovery rather than silently overwrite unexpected external changes.
- Materialize source symlinks as regular files.

See [deployment behavior and safety limits](docs/deployment.md) before working
with the engine. Its current tests do not establish production safety.

## Development

```sh
nix develop
zig build test
zig fmt --check build.zig src
```

The lock file pins `silversquirl/zig-flake`; the shell provides Zig 0.17.1 and
ZLS 0.17.0. Zig is a build dependency, not a runtime dependency.

Run the Nix formatting and native engine-test gate with:

```sh
nix fmt -- flake.nix
nix build .#checks.aarch64-darwin.engine
```

Use the corresponding check attribute on Linux. Tests use isolated temporary
directories under `.zig-cache/tmp`, not the user's home or font directories.
To cross-compile tests without executing them:

```sh
zig build check -Dtarget=aarch64-linux
zig build check -Dtarget=x86_64-linux
```

Runtime tests are currently exercised on aarch64-darwin. Linux runtime behavior
and editor integration have not been verified. The pinned Nixpkgs does not
support x86_64-darwin.
