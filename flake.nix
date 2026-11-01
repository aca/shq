{
  description = "shq: shell job queue with attachable ptys";

  inputs = {
    ghostty.url = "github:ghostty-org/ghostty";
    nixpkgs.follows = "ghostty/nixpkgs";
  };

  outputs = {
    nixpkgs,
    ghostty,
    ...
  }: let
    inherit (nixpkgs) lib;
    forAllSystems = f:
      lib.genAttrs ["x86_64-linux" "aarch64-linux"]
      (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (pkgs: let
      deps = ghostty.packages.${pkgs.stdenv.hostPlatform.system}.deps;
    in {
      default = pkgs.stdenv.mkDerivation {
        pname = "shq";
        version = "0.0.0";

        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [./build.zig ./build.zig.zon ./src];
        };

        nativeBuildInputs = [pkgs.zig_0_17 pkgs.removeReferencesTo];

        # build.zig.zon points at a sibling ghostty checkout; use the flake
        # input instead, and ghostty's pre-fetched Zig packages for its deps.
        postPatch = ''
          cp -r ${ghostty} ghostty
          chmod -R u+w ghostty
          substituteInPlace build.zig.zon \
            --replace-fail '../../ghostty-org/ghostty' './ghostty'
        '';

        dontSetZigDefaultFlags = true;
        zigBuildFlags = [
          "--system"
          "${deps}"
          "-Doptimize=ReleaseSafe"
          "-Dcpu=baseline"
        ];

        # Type names in the binary embed source paths of the Zig packages,
        # which would otherwise pull ~500M of sources into the closure.
        postFixup = ''
          remove-references-to -t ${deps} $out/bin/shq
        '';
        disallowedReferences = [deps];

        meta.mainProgram = "shq";
      };
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {packages = [pkgs.zig_0_17];};
    });
  };
}
