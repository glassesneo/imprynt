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
  set =
    deployments:
    impryntLib.mkDeployments {
      inherit pkgs package deployments;
      stateDirectory = "/@states@";
    };
  deployment = name: {
    root = "/@root@/${name}";
    files = [
      {
        path = "${name}.ttf";
        source = "${source}/fonts/original.ttf";
      }
    ];
  };
  both = set {
    a = deployment "a";
    b = deployment "b";
  };
  onlyA = set { a = deployment "a"; };
  rejected = name: !(builtins.tryEval (set { ${name} = deployment "x"; }).drvPath).success;
  unsafeNames = [
    ""
    "."
    ".."
    "../escape"
    "/absolute"
    "nested/name"
  ];
  empty = pkgs.writeText "imprynt-empty.json" (
    builtins.toJSON {
      version = 1;
      files = [ ];
    }
  );
in
assert pkgs.lib.all rejected unsafeNames;
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

    imprynt apply --root "$root" --state "$state" --manifest ${manifest}
    imprynt retire --state "$state"
    test ! -e "$root/nested"
    test ! -e "$state"

    run_set() {
      sed -e "s|/@states@|$PWD/states|g" -e "s|/@root@|$PWD/set|g" "$1/bin/apply" > set-apply
      bash set-apply
    }
    run_set ${both}
    test -f set/a/a.ttf
    test -f set/b/b.ttf
    printf 'manual' > set/b/manual
    run_set ${onlyA} > retired
    grep -F 'imprynt: retired b' retired
    test -f set/a/a.ttf
    test ! -e set/b/b.ttf
    test ! -e states/b
    test "$(cat set/b/manual)" = manual
    mkdir states/foreign && touch states/foreign/notes
    if run_set ${onlyA} 2> refused; then
      echo 'unexpected retirement of a directory that is not imprynt state' >&2
      exit 1
    fi
    test -f states/foreign/notes
    touch "$out"
  ''
