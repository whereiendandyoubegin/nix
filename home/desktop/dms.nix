{ config, pkgs, inputs, lib, ... }:

{
  programs.dank-material-shell = {
    enable = true;
    systemd.enable = true;
  };

  xdg.configFile."DankMaterialShell/themes" = {
    source = "${inputs.dms-theme-registry}/themes";
    recursive = true;
  };
}
