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

          renderRuleBody =
            rule:
            lib.optionalString (rule.enabled != null) "      enabled: ${lib.boolToString rule.enabled}\n"
            + lib.optionalString (rule.severity != null) "      severity: ${rule.severity}\n"
            + lib.optionalString (rule.exclude != [ ]) (
              "      exclude:\n" + lib.concatMapStrings (glob: "        - '${glob}'\n") rule.exclude
            );

          renderScope =
            scope: rules:
            "  ${scope}:\n"
            + lib.concatStrings (lib.mapAttrsToList (id: rule: "    ${id}:\n" + renderRuleBody rule) rules);

          renderRules =
            rules:
            lib.optionalString (rules != { }) ("rules:\n" + lib.concatStrings (lib.mapAttrsToList renderScope rules));

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
            renderRules cfg.settings.rules
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
              rules = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.attrsOf (
                    lib.types.submodule {
                      options = {
                        enabled = lib.mkOption {
                          type = lib.types.nullOr lib.types.bool;
                          default = null;
                          description = "Whether the rule is active. Listing a rule already activates it; set false to deactivate an inherited one.";
                        };
                        severity = lib.mkOption {
                          type = lib.types.nullOr (
                            lib.types.enum [
                              "error"
                              "warn"
                            ]
                          );
                          default = null;
                          description = "Override the rule's severity.";
                        };
                        exclude = lib.mkOption {
                          type = lib.types.listOf lib.types.str;
                          default = [ ];
                          description = "Glob patterns of files the rule skips.";
                        };
                      };
                    }
                  )
                );
                default = { };
                example = {
                  go.no-panic.severity = "warn";
                  typescript.simple-repositories.exclude = [ "test/**/*.ts" ];
                };
                description = "Rules to activate, keyed by scope (go, ts, tsx, typescript, project) then rule id.";
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
            version = "1.7.0";
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
