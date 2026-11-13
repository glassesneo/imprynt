{
  runCommand,
  zig,
  impryntSource ? ../.,
}:
runCommand "imprynt-0.1.0"
  {
    nativeBuildInputs = [ zig ];
    meta.mainProgram = "imprynt";
  }
  ''
    cp -R ${impryntSource} source
    chmod -R u+w source
    cd source
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
    zig build -Doptimize=ReleaseSafe --prefix "$out" --summary all
  ''
