{
  description = "Managed materialization of Nix-built files";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/3181085bfd08663b6b9e60bc7a8395c2aaa741bd";
    zig = {
      url = "github:silversquirl/zig-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      zig,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      zigFor = system: zig.packages.${system}.zig_0_17_1;
    in
    {
      lib = import ./nix/lib.nix {
        inherit self;
        inherit (nixpkgs) lib;
      };
      formatter = nixpkgs.lib.genAttrs systems (system: nixpkgs.legacyPackages.${system}.nixfmt);
      checks = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          integration = import ./nix/integration-check.nix {
            inherit pkgs;
            impryntLib = self.lib;
            package = self.packages.${system}.imprynt;
          };
          engine =
            pkgs.runCommand "imprynt-engine-tests"
              {
                nativeBuildInputs = [
                  (zigFor system)
                  pkgs.nixfmt
                ];
              }
              ''
                cp -R ${./.} source
                chmod -R u+w source
                cd source
                export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
                export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
                nixfmt --check flake.nix nix/*.nix
                zig fmt --check build.zig src
                zig build test --summary all
                touch "$out"
              '';
        }
      );
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          imprynt = pkgs.callPackage ./nix/package.nix { zig = zigFor system; };
        in
        {
          inherit imprynt;
          default = imprynt;
          zig = zigFor system;
        }
      );
      apps = nixpkgs.lib.genAttrs systems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.imprynt}/bin/imprynt";
        };
      });
      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              (zigFor system)
              (zigFor system).zls
            ];
          };
        }
      );
    };
}
