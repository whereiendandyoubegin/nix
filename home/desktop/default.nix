{ config, pkgs, inputs, lib, ... }:

{
  imports = [
    ../shared/shell.nix
    ../shared/editor.nix
    ../shared/git.nix
    ../shared/terminal.nix
    ../shared/yazelix.nix
    ./niri.nix
    ./dunst.nix
    inputs.dank-material-shell.homeModules.dank-material-shell
    ./dms.nix
  ];

  home.stateVersion = "24.11";
  
  home.packages = import ../../modules/development/packages.nix {
    inherit pkgs inputs lib;
    system = pkgs.system;
  };
  
  home.sessionVariables = {
    EDITOR = "hx";
  };
}
