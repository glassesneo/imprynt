{
  lib,
  runCommand,
  stdenv,
  zig,
  impryntSource ? lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../build.zig
      ../src
      ../LICENSE
    ];
  },
}:
let
  # Nix shares these packages across CPUs of the same system.
  target =
    {
      aarch64-darwin = "aarch64-macos";
      aarch64-linux = "aarch64-linux";
      x86_64-linux = "x86_64-linux";
    }
    .${stdenv.hostPlatform.system};
in
runCommand "imprynt-0.1.0"
  {
    nativeBuildInputs = [ zig ];
    meta = {
      description = "Journaled real-file deployment for Nix-built files";
      homepage = "https://github.com/glassesneo/imprynt";
      license = lib.licenses.mit;
      mainProgram = "imprynt";
      platforms = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    };
  }
  ''
    cp -R ${impryntSource} source
    chmod -R u+w source
    cd source
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
    zig build -Dtarget=${target} -Dcpu=baseline -Doptimize=ReleaseSafe --prefix "$out" --summary all
    mkdir -p "$out/share/licenses/imprynt"
    cp LICENSE "$out/share/licenses/imprynt/LICENSE"
  ''
