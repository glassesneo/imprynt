# imprynt

Managed materialization of Nix-built files outside the Nix store.

**Under development. No deployment CLI or framework modules are available yet.**
The initial use case is real-file font installation on macOS. The shared engine
will accept explicit destinations and run with the caller's privileges.
Planned first-party integrations are Home Manager, nix-darwin, and NixOS;
other integrations will use the same generation and application building blocks.

## Intended behavior

- Own individual deployed files, leaving unrelated manual files alone.
- Detect collisions and external changes before applying a deployment.
- Recover interrupted changes using a journal, without silently overwriting
  externally modified files.
- Materialize source symlinks as regular files.

These are design goals, not implemented safety guarantees. See
[the deployment contract](docs/deployment.md) for boundaries and open work.

## Development

```sh
nix develop
zig version
```

The lock file pins `silversquirl/zig-flake`; the shell provides Zig 0.17.1 and
ZLS 0.17.0. Zig is a build dependency, not a runtime dependency.

Development is currently exercised on aarch64-darwin. Linux runtime behavior
and editor integration have not been verified. The pinned Nixpkgs does not
support x86_64-darwin.
