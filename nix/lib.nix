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
}
