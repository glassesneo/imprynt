{ lib }:
let
  inherit (lib) mkOption types;
  relative =
    value:
    value != ""
    && lib.all (
      part:
      !(lib.elem part [
        ""
        "."
        ".."
      ])
    ) (lib.splitString "/" value);
  pathType = types.addCheck types.str relative // {
    description = "relative destination path without empty, dot or parent components";
  };
  mode = mkOption {
    type = types.ints.between 0 511;
    default = 420;
    description = "POSIX permission bits, as an integer (420 is 0644).";
  };
in
{
  entry = types.submodule {
    options = {
      path = mkOption {
        type = pathType;
        description = "Destination relative to the managed root.";
      };
      source = mkOption {
        type = types.path;
        description = "Source file; symlinks are followed and materialized as regular files.";
      };
      inherit mode;
    };
  };
  tree = types.submodule {
    options = {
      source = mkOption {
        type = types.path;
        description = "Source directory enumerated during the manifest build.";
      };
      prefix = mkOption {
        type = types.addCheck types.str (value: value == "" || relative value);
        default = "";
        description = "Relative destination prefix; empty places the tree directly below the managed root.";
      };
      extensions = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Included last filename extensions, with leading dots, compared ignoring case; null includes every regular file.";
      };
      inherit mode;
    };
  };
}
