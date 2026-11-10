{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.rift;
  tomlFormat = pkgs.formats.toml { };
  inherit (pkgs.stdenv.hostPlatform) system;

  toolchain = inputs.fenix.packages.${system}.stable.minimalToolchain;
  craneLib = (inputs.crane.mkLib pkgs).overrideToolchain (_: toolchain);

  commonArgs = {
    src = inputs.rift-src;
    strictDeps = true;
    cargoExtraArgs = "--locked --package rift-wm";
    buildInputs = [ pkgs.apple-sdk_26 ];
  };

  rift = craneLib.buildPackage (commonArgs // {
    cargoArtifacts = craneLib.buildDepsOnly commonArgs;
    doCheck = false;
    meta.mainProgram = "rift";
  });

  workspaceKeys = mod:
    lib.listToAttrs (lib.concatMap
      (n: [
        (lib.nameValuePair "${mod} + ${toString n}" { switch_to_workspace = n; })
        (lib.nameValuePair "${mod} + Shift + ${toString n}" { move_window_to_workspace = n; })
      ])
      (lib.range 0 (cfg.workspaces - 1)));

  defaultKeys = mod: workspaceKeys mod // {
    "${mod} + Z" = "toggle_space_activated";

    "${mod} + H" = { move_focus = "left"; };
    "${mod} + J" = { move_focus = "down"; };
    "${mod} + K" = { move_focus = "up"; };
    "${mod} + L" = { move_focus = "right"; };

    "${mod} + Shift + H" = { move_node = "left"; };
    "${mod} + Shift + J" = { move_node = "down"; };
    "${mod} + Shift + K" = { move_node = "up"; };
    "${mod} + Shift + L" = { move_node = "right"; };

    "${mod} + Tab" = "switch_to_last_workspace";

    "${mod} + Shift + Left" = { join_window = "left"; };
    "${mod} + Shift + Right" = { join_window = "right"; };
    "${mod} + Shift + Up" = { join_window = "up"; };
    "${mod} + Shift + Down" = { join_window = "down"; };
    "${mod} + Ctrl + E" = "unjoin_windows";

    "${mod} + Comma" = "toggle_stack";
    "${mod} + Slash" = "toggle_orientation";
    "${mod} + Shift + Space" = "toggle_window_floating";
    "${mod} + Shift + Ctrl + Space" = "toggle_focus_floating";
    "${mod} + F" = "toggle_fullscreen";
    "${mod} + Shift + F" = "toggle_fullscreen_within_gaps";
    "${mod} + Shift + Equal" = "resize_window_grow";
    "${mod} + Shift + Minus" = "resize_window_shrink";

    "${mod} + Enter" = { exec = [ "/usr/bin/open" "-a" "Terminal" ]; };
    "${mod} + Shift + D" = "debug";
    "${mod} + Ctrl + S" = "serialize";
    "${mod} + Ctrl + Q" = "save_and_exit";
  };

  # A key set to null in services.rift.keys removes that bind
  finalKeys = lib.filterAttrs (_: action: action != null)
    (defaultKeys cfg.modifier // cfg.keys);

  # Upstream defaults, then your config, then the generated keymap
  defaults = lib.importTOML "${inputs.rift-src}/rift.default.toml";
  finalConfig = lib.recursiveUpdate (lib.recursiveUpdate defaults cfg.config) {
    virtual_workspaces.default_workspace_count = cfg.workspaces;
  } // { keys = finalKeys; };

  configFile = tomlFormat.generate "rift-config.toml" finalConfig;
in
{
  options.services.rift = {
    enable = lib.mkEnableOption "the Rift tiling window manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = rift;
      defaultText = lib.literalMD "Rift built from `inputs.rift-src` with crane and fenix";
      description = "The Rift package to install and run.";
    };

    modifier = lib.mkOption {
      type = lib.types.str;
      default = "OptionRight";
      example = "Ctrl + Alt";
      description = "Modifier used by every default keybinding.";
    };

    workspaces = lib.mkOption {
      type = lib.types.ints.between 2 10;
      default = 4;
      description = "Number of virtual workspaces, each given number keys starting from 0.";
    };

    config = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      example = lib.literalExpression ''{ settings.layout.mode = "bsp"; }'';
      description = "TOML settings merged over rift.default.toml. Use services.rift.keys for keybindings.";
    };

    keys = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr tomlFormat.type);
      default = { };
      description = "Keybindings merged over the defaults. Set a default bind to null to remove it.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      (lib.hm.assertions.assertPlatform "services.rift" pkgs lib.platforms.darwin)
    ];

    home.packages = [ cfg.package ];

    launchd.agents.rift = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe' cfg.package "rift") "--config" "${configFile}" ];
        RunAtLoad = true;
        KeepAlive = {
          Crashed = true;
          SuccessfulExit = false;
        };
        ProcessType = "Interactive";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/rift.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/rift.err.log";
      };
    };
  };
}
