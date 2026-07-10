{ inputs, pkgs, ... }:
{
  imports = [
    inputs.yazelix.homeManagerModules.default
    inputs.steel-plugin-nix.homeManagerModules.default
  ];

  programs.yazelix = {
    enable = true;
    manage_config = true;
    # runtime_variant = "wezterm";
    helix_steel_plugins = {
      enabled = [
        "recentf"
        "splash"
        "spacemacs_theme"
      ];
    };
    
    # transparency = "none";

    runtime_tool_sources = {
      yazi = "bundled";
      helix = "bundled";
    };
    steelPlugins =
      let
        helixConfig = {
          owner = "mattwparas";
          repo = "helix-config";
          rev = "a101da0852932f10792f098dbb14ea88811985ff";
          hash = "sha256-N4Y78H9HDJernQkdH+24tylfl1bleBZewTB7Fk9LlGg=";
        };
      in
      [
        # Library dep — no typed commands, required by labelled-buffers
        (helixConfig // {
          id = "keymaps";
          source = "cogs/keymaps.scm";
        })

        # Library dep — no typed commands, required by file-tree and git-status-picker
        (helixConfig // {
          id = "labelled-buffers";
          source = "cogs/labelled-buffers.scm";
        })

        (helixConfig // {
          id = "git-status-picker";
          source = "cogs/git-status-picker.scm";
          public_commands = [ "create-gs-picker" "add-modified-file" ];
        })

        (helixConfig // {
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
        })
          {
            owner  = "thomasschafer";
            repo   = "smooth-scroll.hx";
            rev    = "1ed8b088e465fb139389c36ad158ba4a2d9e1bbc";
            hash   = "sha256-4lxGZrT4cEcg3jqae3uJGGGCSy4WeVZeJ0hIApMb7jY=";
            id     = "smooth-scroll";
            source = "smooth-scroll.scm";
            support_files = [ "src/utils.scm" ];
            public_commands = [ "half-page-up-smooth" "half-page-down-smooth" "page-up-smooth" "page-down-smooth" ];
          }
        ];
    compiledSteelPlugins =
      let
        sp = inputs.steel-plugin-nix.lib.${pkgs.system};
      in
      [
        (sp.fromCompiledGitHub {
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
          (sp.fromCompiledGitHub {
            owner = "mattwparas";
            repo  = "helix-file-watcher";
            rev   = "e118b7552ec7697c560a24b48880c92d6aa4476e";
            hash  = "sha256-AvUihtnJtVZ6cLJJrNzhTmt/ZT1lZzprCRbuAfbzRc0=";

            id            = "helix-file-watcher";
            source        = "file-watcher.scm";
            support_files = [ "helix-file-watcher.scm" ];
            public_commands = [ "spawn-watcher" ];

            outputHashes = {
              "steel-core-0.8.2" = "sha256-qPDz0ax290E7UEFTDfrmLmsn1r9dIuOxMiRmNrDkfZo=";
            };
          })
          (sp.fromCompiledGitHub {
            owner = "Ciflire";
            repo  = "presence.hx";
            rev   = "5b5f134c30c3a3d9a6f3565e8cc56973230bc7ef";
            hash  = "sha256-L+fExKl4X1BHi+BIKHgBPtqyHHjqAc0qwyvCq8c0B0E=";

            id            = "helix-discord-rpc";
            source        = "helix-discord-rpc.scm";
            support_files = [ "helix-discord-rpc.scm" ];
            public_commands = [ "discord-rpc-connect" ];
            startup_commands = [ "discord-rpc-connect" ];
          }) 
      ];
    };
xdg.configFile."yazelix/shell_nu.nu".text = ''
  $env.config = {
    show_banner: false
  }

  $env.STARSHIP_SHELL = "nu"

  def --env starship_prompt [] {
    starship prompt
  }

  $env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/bin" | prepend $"/etc/profiles/per-user/($env.USER)/bin")
  $env.PROMPT_COMMAND = { || starship_prompt }
  $env.PROMPT_INDICATOR = ""
  $env.PROMPT_MULTILINE_INDICATOR = "… "

  if ("SSH_AUTH_SOCK" not-in $env) or ($env.SSH_AUTH_SOCK | is-empty) or ("SSH_CONNECTION" not-in $env) or ($env.SSH_CONNECTION | is-empty) {
    $env.SSH_AUTH_SOCK = $"($env.XDG_RUNTIME_DIR)/ssh-agent"
  }

  use /nix/store/bhx27fhx53clh3xckp5l7g6lbi2mk5j9-starship-nushell-config.nu

  let keychain_shell_command = (SHELL=bash /nix/store/y4d76k8fvlaah1pacjx4c8nmsqcdq197-keychain-2.9.8/bin/keychain --eval --quiet id_ed25519| parse -r '(\w+)="?(.*?)"?; export \1' | transpose -ird)
  if not ($keychain_shell_command|is-empty) {
    $keychain_shell_command | load-env
  }
  
  alias "ns" = sudo nixos-rebuild switch --flake ~/cloned/nixpublic --fast
  alias "cloned" = cd ~/cloned

  if $nu.is-interactive {
    source ~/.zoxide.nu

    def --env --wrapped cd [...path] {
        __zoxide_z ...$path
    }
  }
'';
xdg.configFile."yazelix/helix/languages.toml".text = ''
  [language-server.rust-analyzer.config]
  check.command = "clippy"
  check.extraArgs = ["--", "-W", "clippy::all", "-W", "clippy::pedantic", "-W", "clippy::nursery"]
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
  hover.show.fields = 20
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
  formatter = { command = "rustfmt", args = ["--edition", "2021"] }
'';

}

 
