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
        { config, lib, pkgs, ... }:
        let
          cfg = config.programs.kata;

          renderIds =
            key: ids:
            lib.optionalString (ids != [ ]) ("${key}:\n" + lib.concatMapStrings (id: "  - ${id}\n") ids);

          renderMetrics =
            metrics:
            lib.optionalString (metrics != { }) (
              "metrics:\n"
              + lib.concatStrings (lib.mapAttrsToList (name: threshold: "  ${name}: ${toString threshold}\n") metrics)
            );

          renderProjectRule =
            id: rule:
            "  ${id}:\n    kind: ${rule.kind}\n"
            + lib.optionalString (rule.calleeSuffix != null) "    callee-suffix: ${rule.calleeSuffix}\n"
            + lib.optionalString (rule.callerSuffix != null) "    caller-suffix: ${rule.callerSuffix}\n"
            + lib.optionalString (rule.from != null) "    from: ${rule.from}\n"
            + lib.optionalString (rule.deny != null) "    deny: ${rule.deny}\n";

          renderProjectRules =
            rules:
            lib.optionalString (rules != { }) (
              "project-rules:\n" + lib.concatStrings (lib.mapAttrsToList renderProjectRule rules)
            );

          rulesYaml =
            renderIds "disabled" cfg.settings.disabled
            + renderIds "warnings" cfg.settings.warnings
            + renderMetrics cfg.settings.metrics
            + renderProjectRules cfg.settings.projectRules
            + lib.optionalString cfg.settings.ratchet "ratchet: true\n";
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

            settings = {
              disabled = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [
                  "ts/no-console"
                  "no-any"
                ];
                description = "Rule ids to disable, optionally scoped by language.";
              };

              warnings = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "go/no-panic" ];
                description = "Rule ids demoted to warnings, optionally scoped by language.";
              };

              metrics = lib.mkOption {
                type = lib.types.attrsOf lib.types.ints.positive;
                default = { };
                example = {
                  complexity = 10;
                };
                description = "Metric thresholds keyed by metric name.";
              };

              projectRules = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.submodule {
                    options = {
                      kind = lib.mkOption {
                        type = lib.types.enum [
                          "restricted-callers"
                          "import-boundary"
                        ];
                        description = "Project rule kind.";
                      };
                      calleeSuffix = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "restricted-callers: suffix of the restricted callee type.";
                      };
                      callerSuffix = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "restricted-callers: suffix callers must have.";
                      };
                      from = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "import-boundary: glob of files the rule applies to.";
                      };
                      deny = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "import-boundary: glob of denied import targets.";
                      };
                    };
                  }
                );
                default = { };
                description = "Project rules keyed by rule id.";
              };

              ratchet = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Block only violation growth per file in daemon mode.";
              };
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];
            xdg.configFile."kata/rules.yaml" = lib.mkIf (rulesYaml != "") { text = rulesYaml; };
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
            version = "1.1.0";
            src = self;

            zigDeps = zig.fetchDeps {
              inherit (finalAttrs) pname version src;
              hash = "sha256-CgyvBABSygnMmKFeUCNM9FFPkdBNNWWJ6Hxs55ozdUw=";
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
