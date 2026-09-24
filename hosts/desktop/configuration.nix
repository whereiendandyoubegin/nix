{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/system/kernel.nix
  ];

  nixpkgs.config.allowUnfree = true;

  boot = {
    loader = {
      systemd-boot.enable = true;
      systemd-boot.configurationLimit = 1;
      efi.canTouchEfiVariables = true;
    };
    blacklistedKernelModules = [ "kvm" "kvm_amd" ];
    # extraModulePackages = [ config.boot.kernelPackages.virtualbox ];
  };

  networking = {
    hostName = "dan-nix";
    networkmanager.enable = true;
    wireless.enable = lib.mkForce false;
    wireless.iwd.enable = true;
    firewall.allowedTCPPorts = [ 6443 6780 ];
  };

  users.users.dan = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" "libvirtd" "vboxusers" "pipewire" "librepods" ];
    shell = pkgs.nushell;
  };

  time.timeZone = "Europe/London";
  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_GB.UTF-8";
    LC_IDENTIFICATION = "en_GB.UTF-8";
    LC_MEASUREMENT = "en_GB.UTF-8";
    LC_MONETARY = "en_GB.UTF-8";
    LC_NAME = "en_GB.UTF-8";
    LC_NUMERIC = "en_GB.UTF-8";
    LC_PAPER = "en_GB.UTF-8";
    LC_TELEPHONE = "en_GB.UTF-8";
    LC_TIME = "en_GB.UTF-8";
  };

  services.xserver.xkb = {
    layout = "gb";
    variant = "";
  };

  console.keyMap = "uk";

  services.printing.enable = true;

  environment.systemPackages = with pkgs; [
    wget curl git vim firefox
    networkmanager-openvpn
    grim slurp wl-clipboard
    xdg-desktop-portal
    xdg-desktop-portal-gnome
    xdg-desktop-portal-gtk
  ];

  programs.zsh.enable = true;

  system.stateVersion = "24.05";
}
