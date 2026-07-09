{ config, pkgs, ... }:

{
  programs.wezterm = {
    enable = true;
    extraConfig = ''
      return {
        color_scheme = "Gruvbox dark, medium (base16)",
      }
    '';
  };
}
