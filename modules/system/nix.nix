{ config, pkgs, ... }:
{
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      
      max-jobs = 4;
      cores = 3;
      builders-use-substitutes = true;
      auto-optimise-store = true;

      http-connections = 128;
      max-substitution-jobs = 128;

      download-buffer-size = 1073741824;

      min-free = 10737418240;
      max-free = 32212254720;

      connect-timeout = 5;
      narinfo-cache-negative-ttl = 60;
      keep-going = true;
      warn-dirty = false;
      
      trusted-users = [ "root" "dan" ];
      accept-flake-config = true;
      
      substituters = [
        "http://hydra.thesta.rs"
        "https://cache.nixos.org/"
        "https://nyx-cache.chaotic.cx/"
        "https://nix-community.cachix.org"
        "https://yazelix.cachix.org"
        "https://fenix.cachix.org"
        "https://crane.cachix.org"
        "https://helix.cachix.org"
      ];

      fallback = true;

      trusted-public-keys = [
        "nix-cache.local-1:9YjK620BxyXAl7uPGRrzxmxdWB5Z5jwqfcB29s0OV2E="
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nyx-cache.chaotic.cx:dJxTrgMC3V3cFfyIiBQDQorG6k1LsqurH/srpMSq7qk="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "yazelix.cachix.org-1:ZgxIjQvaP0VTWL8Racx27mpUNzDJ97xC2y7QWYjmGNM="
        "fenix.cachix.org-1:ecJhr+RdYEdcVgUkjruiYhjbBloIEGov7bos90cZi0Q="
        "crane.cachix.org-1:8Scfpmn9w+hGdXH/Q9tTLiYAE/2dnJYRJP7kl80GuRk="
        "helix.cachix.org-1:ejp9KQpR1FBI2onstMQ34yogDm4OgU2ru6lIwPvuCVs="
      ];
    };
    
    buildMachines = [
      {
        hostName = "flake-updater";
        sshUser = "dan";
        sshKey = "/home/dan/.ssh/id_ed25519_nixology";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        maxJobs = 4;
        speedFactor = 1;
        supportedFeatures = [ "big-parallel" "benchmark" ];
      }
    ];
    distributedBuilds = true;

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  programs.ssh.knownHosts."flake-updater".publicKey =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBMJ1tdDkbHls2a7An/DojGIwiaov/mfdzN/cKI0GpZW";

  programs.ssh.extraConfig = ''
    Host flake-updater
      User dan
      IdentityFile /home/dan/.ssh/id_ed25519_nixology
  '';
}
