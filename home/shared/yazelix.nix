{ inputs, lib, pkgs, ... }:
let
  spn = inputs.steel-plugin-nix.lib.${pkgs.system};

  helixConfigRepo = {
    owner = "mattwparas";
    repo = "helix-config";
    rev = "a101da0852932f10792f098dbb14ea88811985ff";
    hash = "sha256-N4Y78H9HDJernQkdH+24tylfl1bleBZewTB7Fk9LlGg=";
  };

  plugins = spn.collect [
    (spn.fromGitHub (helixConfigRepo // {
      id = "keymaps";
      source = "cogs/keymaps.scm";
    }))
    (spn.fromGitHub (helixConfigRepo // {
      id = "labelled-buffers";
      source = "cogs/labelled-buffers.scm";
    }))
    (spn.fromGitHub (helixConfigRepo // {
      id = "git-status-picker";
      source = "cogs/git-status-picker.scm";
      public_commands = [ "create-gs-picker" "add-modified-file" ];
    }))
    (spn.fromGitHub (helixConfigRepo // {
      id = "file-tree";
      source = "cogs/file-tree.scm";
      public_commands = [
        "open-file-from-picker"
        "create-file"
        "fold-directory"
        "create-directory"
        "fold-all"
        "unfold-all-one-level"
      ];
    }))
    (spn.fromGitHub {
      owner = "thomasschafer";
      repo = "smooth-scroll.hx";
      rev = "1ed8b088e465fb139389c36ad158ba4a2d9e1bbc";
      hash = "sha256-4lxGZrT4cEcg3jqae3uJGGGCSy4WeVZeJ0hIApMb7jY=";
      id = "smooth-scroll";
      source = "smooth-scroll.scm";
      support_files = [ "src/utils.scm" ];
      public_commands = [
        "half-page-up-smooth"
        "half-page-down-smooth"
        "page-up-smooth"
        "page-down-smooth"
      ];
    })
    (spn.fromCompiledGitHub {
      owner = "whereiendandyoubegin";
      repo = "scooter.hx";
      rev = "41fce7910a6ddf54dc34e96093804ab467ab9d48";
      hash = "sha256-w1otVo8MCSOJUf0rfLoNCEt1jduThMid2Meli3Kq8A4=";
      id = "scooter";
      source = "scooter.scm";
      support_files = [
        "ui/window.scm"
        "ui/fields.scm"
        "ui/drawing.scm"
        "ui/styles.scm"
        "ui/utils.scm"
      ];
      public_commands = [ "scooter" "scooter-new" ];
    })
    (spn.fromCompiledGitHub {
      owner = "mattwparas";
      repo = "helix-file-watcher";
      rev = "e118b7552ec7697c560a24b48880c92d6aa4476e";
      hash = "sha256-AvUihtnJtVZ6cLJJrNzhTmt/ZT1lZzprCRbuAfbzRc0=";
      id = "helix-file-watcher";
      source = "file-watcher.scm";
      support_files = [ "helix-file-watcher.scm" ];
      public_commands = [ "spawn-watcher" ];
      outputHashes = {
        "steel-core-0.8.2" = "sha256-qPDz0ax290E7UEFTDfrmLmsn1r9dIuOxMiRmNrDkfZo=";
      };
    })
    (spn.fromCompiledGitHub {
      owner = "Ciflire";
      repo = "presence.hx";
      rev = "5b5f134c30c3a3d9a6f3565e8cc56973230bc7ef";
      hash = "sha256-L+fExKl4X1BHi+BIKHgBPtqyHHjqAc0qwyvCq8c0B0E=";
      id = "helix-discord-rpc";
      source = "helix-discord-rpc.scm";
      support_files = [ "helix-discord-rpc.scm" ];
      public_commands = [ "discord-rpc-connect" ];
      startup_commands = [ "discord-rpc-connect" ];
    })
  ];

  requireLine = m: ''(require "steel_plugins/${m.id}/${m.source}")'';
  allProvided = lib.concatMap (m: m.public_commands or [ ]) plugins.manifests;
  allStartup = lib.concatMap (m: m.startup_commands or [ ]) plugins.manifests;

  helixScm = ''
    ${lib.concatMapStringsSep "\n" requireLine plugins.manifests}

    (provide
      ${lib.concatStringsSep "\n  " allProvided})
  '';

  initScm = lib.concatMapStringsSep "\n" (cmd: "(${cmd})") allStartup;
in
{
  imports = [
    inputs.yazelix.homeManagerModules.default
  ];

  home.file = plugins.homeFiles // plugins.nativeFiles;

  programs.yazelix = {
    enable = true;

    config = {
      settings = {
        appearance.mode = "dark";
        shell.program = "nu";
        shell.atuin = true;
        welcome.enabled = true;
        welcome.style = "random";
      };

      helix = {
        module.text = helixScm;
        init.text = initScm;

        config.text = ''
          theme = "ayu_evolve"

          [editor]
          auto-format = true
          bufferline = "always"
          color-modes = true
          cursorline = true
          end-of-line-diagnostics = "hint"

          [editor.lsp]
          display-inlay-hints = true

          [editor.cursor-shape]
          insert = "bar"

          [editor.file-picker]
          hidden = true

          [editor.indent-guides]
          render = true

          [editor.inline-diagnostics]
          cursor-line = "warning"

          [editor.soft-wrap]
          enable = true

          [editor.statusline]
          center = ["file-name"]
          left = [
              "mode",
              "spinner",
              "version-control",
          ]
          right = [
              "diagnostics",
              "selections",
              "position",
              "total-line-numbers",
              "position-percentage",
              "file-encoding",
          ]
          separator = "│"

          [keys.normal]
          ":" = "command_mode"
          A-r = ':sh yzx reveal "%{buffer_name}"'
          A-ret = [
              "move_line_up",
              "goto_first_nonwhitespace",
          ]
          C-j = [
              "extend_to_line_bounds",
              "delete_selection",
              "paste_after",
          ]
          C-k = [
              "extend_to_line_bounds",
              "delete_selection",
              "move_line_up",
              "paste_before",
          ]
          C-r = [
              ":config-reload",
              ":reload",
          ]
          X = "extend_line_up"
          ret = [
              "move_line_down",
              "goto_first_nonwhitespace",
          ]
          "{" = "goto_prev_paragraph"
          "}" = "goto_next_paragraph"

          [keys.normal.A-g]
          b = ":sh git blame -L %{cursor_line},+1 %{buffer_name}"
          l = ":sh git log --oneline -10 %{buffer_name}"
          s = ":sh git status --porcelain"

          [keys.normal.backspace]
          c = ":config-open"
          d = ":yank-diagnostic"
          h = ":toggle-option file-picker.hidden"
          i = ":toggle-option file-picker.git-ignore"
          l = ":o ~/.config/yazelix/helix/languages.toml"

          [keys.normal.g]
          e = "goto_file_end"
        '';

        languages.text = ''
          [language-server.rust-analyzer.config]
          check.command = "clippy"
          check.workspace = true
          cargo.features = "all"
          cargo.buildScripts.enable = true
          procMacro.enable = true

          imports.granularity.group = "crate"
          imports.prefix = "crate"
          imports.merge.glob = false

          completion.autoimport.enable = true
          completion.autoself.enable = true
          completion.postfix.enable = true
          completion.privateEditable.enable = true
          completion.termSearch.enable = true
          completion.fullFunctionSignatures.enable = true
          completion.limit = 100

          signatureInfo.detail = "full"
          signatureInfo.documentation.enable = true

          diagnostics.experimental.enable = true
          diagnostics.styleLints.enable = true

          hover.actions.enable = true
          hover.actions.implementations.enable = true
          hover.actions.references.enable = true
          hover.actions.run.enable = true
          hover.actions.debug.enable = true
          hover.documentation.enable = true
          hover.show.enumVariants = 20
          hover.show.tructFields = 20
          hover.show.traitAssocItems = 20
          assist.emitMustUse = true
          assist.expressionFillDefault = "todo"

          [language-server.rust-analyzer.config.inlayHints]
          reborrowHints.enable = "mutable"
          expressionAdjustmentHints.enable = "reborrow"
          implicitDrops.enable = true
          closureCaptureHints.enable = true
          typeHints.enable = true
          parameterHints.enable = true
          chainingHints.enable = true
          bindingModeHints.enable = false
          lifetimeElisionHints.enable = "skip_trivial"

          [[language]]
          name = "rust"
          auto-format = true
          formatter = { command = "rustfmt", args = ["--edition", "2024"] }
        '';
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

          $env.STARSHIP_SHELL = "nu"

          def --env starship_prompt [] {
            starship prompt
          }

          plugin use typetree

          $env.PROMPT_COMMAND = { || starship_prompt }
          $env.PROMPT_INDICATOR = ""
          $env.PROMPT_MULTILINE_INDICATOR = "… "

          use /nix/store/bhx27fhx53clh3xckp5l7g6lbi2mk5j9-starship-nushell-config.nu

          let keychain_shell_command = (SHELL=bash /nix/store/y4d76k8fvlaah1pacjx4c8nmsqcdq197-keychain-2.9.8/bin/keychain --eval --quiet id_ed25519| parse -r '(\w+)="?(.*?)"?; export \1' | transpose -ird)
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
