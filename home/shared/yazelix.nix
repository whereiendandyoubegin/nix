{ config, inputs, lib, pkgs, ... }:
let
  spn = inputs.steel-plugin-nix.lib.${pkgs.system};

  tomlFormat = pkgs.formats.toml { };
  
  starshipNuInit = pkgs.runCommand "starship-nushell-config.nu" { } ''
    ${lib.getExe config.programs.starship.package} init nu >> "$out"
  '';

  keychainBin = lib.getExe config.programs.keychain.package;

    pluginSpecs = import ./helixplugins.nix;

  helixConfigRepo = pluginSpecs.helixConfigRepo;

  helixConfigSrc = pkgs.fetchFromGitHub helixConfigRepo;

  plugins = spn.collect (
    map spn.fromGitHub pluginSpecs.interpreted
    ++ map spn.fromCompiledGitHub pluginSpecs.compiled
  );

  requireLine = m: ''(require "steel_plugins/${m.source}")'';
  allProvided = lib.concatMap (m: m.public_commands or [ ]) plugins.manifests;
  allStartup = lib.concatMap (m: m.startup_commands or [ ]) plugins.manifests;

  helixScm = ''
    ${lib.concatMapStringsSep "\n" requireLine plugins.manifests}

    (require "cogs/themes/spacemacs.scm")
    (require (only-in "helix/commands.scm" theme))
    (theme "spacemacs")

    (provide
      ${lib.concatStringsSep "\n  " allProvided})
  '';

  initScm = lib.concatMapStringsSep "\n" (cmd: "(${cmd})") allStartup;

  helixSettings = {
    theme = "spacemacs";

    editor = {
      auto-format = true;
      bufferline = "always";
      color-modes = true;
      cursorline = true;
      end-of-line-diagnostics = "hint";

      lsp.display-inlay-hints = true;
      cursor-shape.insert = "bar";
      file-picker.hidden = true;
      indent-guides.render = true;
      inline-diagnostics.cursor-line = "warning";
      soft-wrap.enable = true;

      statusline = {
        center = [ "file-name" ];
        left = [
          "mode"
          "spinner"
          "version-control"
        ];
        right = [
          "diagnostics"
          "selections"
          "position"
          "total-line-numbers"
          "position-percentage"
          "file-encoding"
        ];
        separator = "│";
      };
    };

    keys.normal = {
      ":" = "command_mode";
      A-r = '':sh yzx reveal "%{buffer_name}"'';
      A-ret = [
        "move_line_up"
        "goto_first_nonwhitespace"
      ];
      C-j = [
        "extend_to_line_bounds"
        "delete_selection"
        "paste_after"
      ];
      C-k = [
        "extend_to_line_bounds"
        "delete_selection"
        "move_line_up"
        "paste_before"
      ];
      C-r = [
        ":config-reload"
        ":reload"
      ];
      X = "extend_line_up";
      ret = [
        "move_line_down"
        "goto_first_nonwhitespace"
      ];
      "{" = "goto_prev_paragraph";
      "}" = "goto_next_paragraph";

      A-g = {
        b = ":sh git blame -L %{cursor_line},+1 %{buffer_name}";
        l = ":sh git log --oneline -10 %{buffer_name}";
        s = ":sh git status --porcelain";
      };

      backspace = {
        c = ":config-open";
        d = ":yank-diagnostic";
        h = ":toggle-option file-picker.hidden";
        i = ":toggle-option file-picker.git-ignore";
        l = ":o ~/.config/yazelix/helix/languages.toml";
      };

      g.e = "goto_file_end";
    };
  };

  helixLanguages = {
    language-server = {
      rust-analyzer.config = {
        check = {
          command = "clippy";
          workspace = true;
        };

        cargo = {
          features = "all";
          buildScripts.enable = true;
        };

        procMacro.enable = true;

        imports = {
          granularity.group = "crate";
          prefix = "crate";
          merge.glob = false;
        };

        completion = {
          autoimport.enable = true;
          autoself.enable = true;
          postfix.enable = true;
          privateEditable.enable = true;
          termSearch.enable = true;
          fullFunctionSignatures.enable = true;
          limit = 100;
        };

        signatureInfo = {
          detail = "full";
          documentation.enable = true;
        };

        diagnostics = {
          experimental.enable = true;
          styleLints.enable = true;
        };

        hover = {
          actions = {
            enable = true;
            implementations.enable = true;
            references.enable = true;
            run.enable = true;
            debug.enable = true;
          };
          documentation.enable = true;
          show = {
            enumVariants = 20;
            tructFields = 20;
            traitAssocItems = 20;
          };
        };

        assist = {
          emitMustUse = true;
          expressionFillDefault = "todo";
        };

        inlayHints = {
          reborrowHints.enable = "mutable";
          expressionAdjustmentHints.enable = "reborrow";
          implicitDrops.enable = true;
          closureCaptureHints.enable = true;
          typeHints.enable = true;
          parameterHints.enable = true;
          chainingHints.enable = true;
          bindingModeHints.enable = false;
          lifetimeElisionHints.enable = "skip_trivial";
        };
      };

      nil.config.nil.nix.flake.autoArchive = false;
    };

    language = [
      {
        name = "rust";
        auto-format = true;
        formatter = {
          command = "rustfmt";
          args = [ "--edition" "2024" ];
        };
      }
    ];
  };
in
{
  imports = [
    inputs.yazelix.homeManagerModules.default
  ];

  home.file = plugins.homeFiles // plugins.nativeFiles // {
    ".config/yazelix/helix/cogs/themes/spacemacs.scm".source =
      "${helixConfigSrc}/cogs/themes/spacemacs.scm";
  };

  programs.yazelix = {
    enable = true;

    config = {
      settings = {
        appearance.mode = "dark";
        shell.program = "nu";
        shell.atuin = true;
        welcome.enabled = true;
        welcome.style = "random";
        sidebar.command = "yzx-yazi";
      };

      helix = {
        module.text = helixScm;
        init.text = initScm;

        config.source =
          tomlFormat.generate "yazelix-helix-config.toml" helixSettings;

        languages.source =
          tomlFormat.generate "yazelix-helix-languages.toml" helixLanguages;
      };

      nu = {
        env.text = ''
          $env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/bin" | prepend $"/etc/profiles/per-user/($env.USER)/bin")

          if ("SSH_AUTH_SOCK" not-in $env) or ($env.SSH_AUTH_SOCK | is-empty) or ("SSH_CONNECTION" not-in $env) or ($env.SSH_CONNECTION | is-empty) {
            $env.SSH_AUTH_SOCK = $"($env.XDG_RUNTIME_DIR)/ssh-agent"
          }
        '';

        config.text = ''
          $env.config = {
            show_banner: false
          }

          plugin use typetree

          use ${starshipNuInit}

          let keychain_shell_command = (SHELL=bash ${keychainBin} --eval --quiet id_ed25519| parse -r '(\w+)="?(.*?)"?; export \1' | transpose -ird)
          if not ($keychain_shell_command|is-empty) {
            $keychain_shell_command | load-env
          }

          alias "ns" = sudo nixos-rebuild switch --flake ~/cloned/nixpublic --fast
          alias "cloned" = cd ~/cloned

          export-env {
            $env.config = (
              $env.config?
              | default {}
              | upsert hooks { default {} }
              | upsert hooks.env_change { default {} }
              | upsert hooks.env_change.PWD { default [] }
            )
            let __zoxide_hooked = (
              $env.config.hooks.env_change.PWD | any { try { get __zoxide_hook } catch { false } }
            )
            if not $__zoxide_hooked {
              $env.config.hooks.env_change.PWD = ($env.config.hooks.env_change.PWD | append {
                __zoxide_hook: true,
                code: {|_, dir| ^zoxide add -- $dir}
              })
            }
          }

          def --env --wrapped __zoxide_z [...rest: string] {
            let path = match $rest {
              [] => {'~'},
              [ '-' ] => {'-'},
              [ $arg ] if ($arg | path expand | path type) == 'dir' => {$arg}
              _ => {
                ^zoxide query --exclude $env.PWD -- ...$rest | str trim -r -c "\n"
              }
            }
            cd $path
          }

          def --env --wrapped __zoxide_zi [...rest:string] {
            cd $'(^zoxide query --interactive -- ...$rest | str trim -r -c "\n")'
          }

          alias z = __zoxide_z
          alias zi = __zoxide_zi
        '';
      };
    };
  };
}
