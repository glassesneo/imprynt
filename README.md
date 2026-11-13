# imprynt

Managed materialization of Nix-built files outside the Nix store.

**Experimental.** The Zig engine installs, updates, and removes regular files
with journaled recovery. A CLI and Nix generation/application helpers are
available; their interfaces are not yet stable. First-party framework modules
are not implemented.

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

See [deployment behavior and safety limits](docs/deployment.md) before applying
files. The tests do not establish production safety.

## Nix integration

Given an imprynt flake input, create a deployment with the consumer's `pkgs`:

```nix
imprynt.lib.mkDeployment {
  inherit pkgs;
  name = "example";
  root = "/absolute/destination";
  stateDirectory = "/absolute/private/state";
  trees = [{
    source = "${somePackage}/share/data";
    prefix = "example";
    # Optional: include only these file extensions, ignoring case.
    extensions = [".ttf" ".otf"];
  }];
}
```

Run the resulting package's `bin/apply` from the consumer's activation lifecycle.
It creates the destination root and private state directory, then applies its
manifest. Keep this step registered with an empty declaration when removing
its last file, so removal is reconciled. Do not share one state directory
between unrelated deployments.

`lib.mkManifest { pkgs; files = [...]; trees = [...]; }` exposes generation
separately. Trees are enumerated during a build, without import-from-derivation.
Each tree preserves relative paths beneath its optional prefix. Explicit files
have `path`, `source`, and optional numeric `mode` (default 420, or POSIX 0644).
The deployment package exposes its generated `manifest`.

## CLI

```sh
nix run . -- --help
imprynt apply --root /absolute/destination --state /absolute/private/state --manifest files.json
imprynt recover --root /absolute/destination --state /absolute/private/state
```

Direct CLI use requires existing root and state directories. A manifest is
`{"version":1,"files":[{"path":"relative/file","source":"/absolute/source"}]}`.
`recover` resolves an unfinished transaction without applying a new declaration;
it does not remove an otherwise committed deployment.

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
nix fmt -- flake.nix nix/*.nix
nix build .#checks.aarch64-darwin.engine .#checks.aarch64-darwin.integration
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
