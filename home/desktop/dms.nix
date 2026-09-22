{ config, pkgs, inputs, lib, ... }:

{
  programs.dank-material-shell = {
    enable = true;
    systemd.enable = false;
  };
}
