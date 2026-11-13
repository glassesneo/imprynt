{
  pkgs,
  impryntLib,
  package,
}:
let
  source = pkgs.runCommand "imprynt-test-source" { } ''
    mkdir -p "$out/fonts"
    printf 'font version one' > "$out/fonts/original.ttf"
    ln -s original.ttf "$out/fonts/linked.otf"
    printf 'ignored metadata' > "$out/fonts/README"
  '';
  manifest = impryntLib.mkManifest {
    inherit pkgs package;
    trees = [
      {
        source = "${source}/fonts";
        prefix = "nested/fonts";
        extensions = [
          ".ttf"
          ".otf"
        ];
      }
    ];
  };
  empty = pkgs.writeText "imprynt-empty.json" (
    builtins.toJSON {
      version = 1;
      files = [ ];
    }
  );
in
pkgs.runCommand "imprynt-integration-tests"
  {
    nativeBuildInputs = [
      package
      pkgs.jq
    ];
  }
  ''
    set -eu
    mkdir -p root state
    root="$PWD/root"
    state="$PWD/state"
    jq -e '.files | length == 2' ${manifest}
    imprynt apply --root "$root" --state "$state" --manifest ${manifest}
    test ! -L "$root/nested/fonts/linked.otf"
    cmp "$root/nested/fonts/linked.otf" "${source}/fonts/original.ttf"
    imprynt apply --root "$root" --state "$state" --manifest ${manifest}
    printf 'manual replacement' > "$root/nested/fonts/linked.otf"
    if imprynt apply --root "$root" --state "$state" --manifest ${empty} 2> conflicts; then
      echo 'unexpected success with an externally changed file' >&2
      exit 1
    fi
    grep -F 'nested/fonts/linked.otf (changed)' conflicts
    test -f "$root/nested/fonts/original.ttf"
    printf 'font version one' > "$root/nested/fonts/linked.otf"
    printf 'manual sibling' > "$root/nested/manual"
    imprynt apply --root "$root" --state "$state" --manifest ${empty}
    test ! -e "$root/nested/fonts"
    test "$(cat "$root/nested/manual")" = 'manual sibling'
    rm "$root/nested/manual"
    imprynt recover --root "$root" --state "$state"
    imprynt apply --root "$root" --state "$state" --manifest ${empty}
    test ! -e "$root/nested"
    touch "$out"
  ''
