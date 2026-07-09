{ config, pkgs, ... }:
{
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      
      # Build optimizations for Ryzen 5 5600X
      max-jobs = 12;
      cores = 6;
      builders-use-substitutes = true;
      auto-optimise-store = true;

      http-connections = 128;
      max-substitution-jobs = 128;

      download-buffer-size = 1073741824;
      
      # Trust and flake-config auto-accept
      trusted-users = [ "root" "dan" ];
      accept-flake-config = true;
      
      # Binary caches
      substituters = [
        "https://cache.nixos.org/"
        "https://nix-community.cachix.org"
        "https://yazelix.cachix.org"
      ];
      
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "yazelix.cachix.org-1:ZgxIjQvaP0VTWL8Racx27mpUNzDJ97xC2y7QWYjmGNM="
      ];
    };
    
    buildMachines = [ ];
    distributedBuilds = false;
  };
}
