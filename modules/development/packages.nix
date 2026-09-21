{ pkgs, inputs, system, lib, ... }:

with pkgs; [
  # Core tools
  git github-cli vim vscode gimp
  flatpak
  
  # Programming languages
  go nodejs python3 openjdk21 clang llvm lld 
  elixir (lib.lowPrio elixir-ls)
  
  # Editors
  nil niri playerctl ninja 
  
  # Shell tools
  zsh bash-completion tmux htop glances tree ncdu
  jq yq ripgrep fd fzf bat less nano
  wget curl nmap arp-scan bind.dnsutils whois rsync pv
  inxi plocate nushell nushellPlugins.query zoxide
  
  # DevOps tools
  kubectl terraform ansible docker-compose podman
  wireguard-tools awscli2 qemu_kvm virt-manager
  openssh sshpass nfs-utils k9s
  
  # Desktop applications
  firefox discord element-desktop 
  vlc obs-studio qbittorrent
  keepassxc meld brave calibre appflowy
  nyxt spotify-player spotatui
  
  # KDE applications
  # kdePackages.spectacle kdePackages.gwenview
  # kdePackages.dolphin kdePackages.ark
  # kdePackages.okular kdePackages.kate kdePackages.kcalc
  
  # Compression
  unzip unrar zip
  
  # Gaming
  retroarch lutris winetricks steam
  # wineWowPackages.stable
  gamescope
  
  # Database
  postgresql dbeaver-bin
  python3Packages.pip python3Packages.virtualenv
  
  # Hardware tools
  hdparm smartmontools dmidecode hwinfo ethtool
  lsscsi sg3_utils usbutils pciutils
  
  # Filesystems
  dosfstools ntfs3g exfatprogs btrfs-progs cryptsetup
  
  # Networking
  networkmanager-openvpn networkmanager-openconnect
  mullvad-vpn wireguard-tools openresolv
  curl-impersonate
  
  # System utilities
  firewalld nix-index pavucontrol ffmpeg
  lm_sensors parted file btop iotop
  
  # Media libraries
  gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good
  gst_all_1.gst-plugins-bad gst_all_1.gst-plugins-ugly
  gst_all_1.gst-libav libdvdcss feather
  
  # Wayland tools
  wezterm fuzzel dunst xwayland-satellite
  swayidle swaylock swaybg waybar blueman networkmanagerapplet
  alacritty rofi slurp grim wl-clipboard
  
  # Portals
  xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome
  
  # Graphics
  mesa-demos vulkan-tools nvidia-vaapi-driver libva-utils
  
  # Development tools
  python3Packages.python-lsp-server clang-tools
  arduino-ide openssl pkg-config uv
  yazi
  
  # Terminals
  ghostty screen
  
  # Misc
  bc starship zenity
  claude-code
  nix-fast-build
  fastfetch
  codex
  
  # Custom packages
  inputs.caelestia.packages.${system}.default
  (inputs.fenix.packages.${system}.stable.withComponents [
    "cargo"
    "clippy"
    "rustc"
    "rustfmt"
    "rust-src"
  ])
  inputs.fenix.packages.${system}.stable.rust-analyzer
]
