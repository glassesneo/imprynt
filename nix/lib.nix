{ self, lib }:
{
  types = import ./types.nix { inherit lib; };
  # The spec references source derivations; enumeration happens in a build,
  # never by reading their outputs during Nix evaluation.
  mkManifest =
    {
      pkgs,
      name ? "imprynt",
      files ? [ ],
      trees ? [ ],
      package ? self.packages.${pkgs.stdenv.hostPlatform.system}.imprynt,
    }:
    let
      spec = pkgs.writeText "${name}-spec.json" (
        builtins.toJSON {
          version = 1;
          inherit files trees;
        }
      );
    in
    pkgs.runCommand "${name}-manifest.json" { passthru = { inherit spec; }; } ''
      ${lib.getExe package} generate --spec ${spec} --output "$out"
    '';

  mkDeployment =
    {
      pkgs,
      name ? "imprynt",
      root,
      stateDirectory,
      files ? [ ],
      trees ? [ ],
      package ? self.packages.${pkgs.stdenv.hostPlatform.system}.imprynt,
    }:
    assert lib.hasPrefix "/" root && lib.hasPrefix "/" stateDirectory;
    let
      manifest = self.lib.mkManifest {
        inherit
          pkgs
          name
          files
          trees
          package
          ;
      };
    in
    pkgs.writeShellScriptBin "apply" ''
      set -eu
      ${pkgs.coreutils}/bin/mkdir -p -- ${lib.escapeShellArg root}
      ${pkgs.coreutils}/bin/install -d -m 0700 -- ${lib.escapeShellArg stateDirectory}
      exec ${lib.getExe package} apply \
        --root ${lib.escapeShellArg root} \
        --state ${lib.escapeShellArg stateDirectory} \
        --manifest ${manifest}
    ''
    // {
      inherit manifest root stateDirectory;
    };

  mkDeployments =
    {
      pkgs,
      stateDirectory,
      deployments,
      package ? self.packages.${pkgs.stdenv.hostPlatform.system}.imprynt,
    }:
    assert lib.hasPrefix "/" stateDirectory;
    assert lib.all (name: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null) (
      lib.attrNames deployments
    );
    assert lib.all (deployment: lib.hasPrefix "/" deployment.root) (lib.attrValues deployments);
    let
      manifests = lib.mapAttrs (
        name: deployment:
        self.lib.mkManifest {
          inherit pkgs name package;
          files = deployment.files or [ ];
          trees = deployment.trees or [ ];
        }
      ) deployments;
      imprynt = lib.getExe package;
      apply = name: deployment: ''
        ${pkgs.coreutils}/bin/mkdir -p -- ${lib.escapeShellArg deployment.root}
        ${pkgs.coreutils}/bin/install -d -m 0700 -- "$states/${name}"
        ${imprynt} apply --root ${lib.escapeShellArg deployment.root} --state "$states/${name}" --manifest ${manifests.${name}}
      '';
    in
    pkgs.writeShellScriptBin "apply" ''
      set -eu
      states=${lib.escapeShellArg stateDirectory}
      ${pkgs.coreutils}/bin/install -d -m 0700 -- "$states"
      for state in "$states"/*; do
        [ -d "$state" ] || continue
        name=${"$"}{state##*/}
        case " ${lib.concatStringsSep " " (lib.attrNames deployments)} " in
          *" $name "*) continue ;;
        esac
        if ! ${imprynt} retire --state "$state"; then
          echo "imprynt: could not retire $name, which is no longer declared; its files and state at $state were left in place" >&2
          exit 1
        fi
        echo "imprynt: retired $name, which is no longer declared"
      done
      ${lib.concatStrings (lib.mapAttrsToList apply deployments)}
    ''
    // {
      inherit stateDirectory;
      deployments = lib.mapAttrs (name: deployment: {
        inherit (deployment) root;
        manifest = manifests.${name};
        stateDirectory = "${stateDirectory}/${name}";
      }) deployments;
    };
}
