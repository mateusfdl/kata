{
  description = "Tree-sitter-based linter for coding-style rules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      homeModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.kata;
        in
        {
          options.programs.kata = {
            enable = lib.mkEnableOption "kata, a tree-sitter-based linter for coding-style rules";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "kata.packages.\${system}.default";
              description = "The kata package to install.";
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];
          };
        };

      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = pkgs.zig;
        in
        {
          default = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "kata";
            version = "1.12.0";
            src = self;

            zigDeps = zig.fetchDeps {
              inherit (finalAttrs) pname version src;
              hash = "sha256-MDXyvUtQgSn5iE5oDQPmgzoBXfjox4hv7EDmtzqHIFE=";
            };

            nativeBuildInputs = [ zig.hook ];

            dontSetZigDefaultFlags = true;

            postConfigure = ''
              ln -s ${finalAttrs.zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
            '';

            zigBuildFlags = [
              "-Doptimize=ReleaseFast"
              "-Dstrip=true"
            ];

            meta = {
              description = "Tree-sitter-based linter for coding-style rules";
              homepage = "https://github.com/mateusfdl/kata";
              license = pkgs.lib.licenses.mit;
              mainProgram = "kata";
              platforms = systems;
            };
          });
        }
      );
    };
}
