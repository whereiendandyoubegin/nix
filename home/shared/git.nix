{ config, pkgs, ... }:

{
  programs.git = {
    enable = true;
    # Add your git config here
    # userName = "Your Name";
    # userEmail = "your.email@example.com";
  };
}
