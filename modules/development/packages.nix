{ pkgs, inputs, system, lib, ... }:

with pkgs; [
  git github-cli vim vscode gimp
  flatpak
  
  go nodejs python3 openjdk21 clang llvm lld 
  elixir (lib.lowPrio elixir-ls)
  
  nil niri playerctl ninja 
  
  zsh bash-completion tmux htop glances tree ncdu
  jq yq ripgrep fd fzf bat less nano
  wget curl nmap arp-scan bind.dnsutils whois rsync pv
  inxi plocate nushell nushellPlugins.query zoxide
  
  kubectl terraform ansible docker-compose podman
  wireguard-tools awscli2 qemu_kvm virt-manager
  openssh sshpass nfs-utils k9s
  
  firefox discord element-desktop 
  vlc obs-studio qbittorrent
  keepassxc meld brave calibre appflowy
  nyxt spotify-player spotatui
  
  # kdePackages.spectacle kdePackages.gwenview
  # kdePackages.dolphin kdePackages.ark
  # kdePackages.okular kdePackages.kate kdePackages.kcalc
  
  unzip unrar zip
  
  retroarch lutris winetricks steam
  # wineWowPackages.stable
  gamescope
  
  postgresql dbeaver-bin
  python3Packages.pip python3Packages.virtualenv
  
  hdparm smartmontools dmidecode hwinfo ethtool
  lsscsi sg3_utils usbutils pciutils
  
  dosfstools ntfs3g exfatprogs btrfs-progs cryptsetup
  
  networkmanager-openvpn networkmanager-openconnect
  mullvad-vpn wireguard-tools openresolv
  curl-impersonate
  
  firewalld nix-index pavucontrol ffmpeg
  lm_sensors parted file btop iotop
  libnotify libinput inotify-tools
  yt-dlp songrec easyeffects
  
  gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good
  gst_all_1.gst-plugins-bad gst_all_1.gst-plugins-ugly
  gst_all_1.gst-libav libdvdcss feather
  
  wezterm fuzzel dunst xwayland-satellite
  swayidle swaylock swaybg waybar blueman networkmanagerapplet
  alacritty rofi slurp grim wl-clipboard
  
  xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome
  
  mesa-demos vulkan-tools nvidia-vaapi-driver libva-utils
  
  python3Packages.python-lsp-server clang-tools
  arduino-ide openssl pkg-config uv
  yazi
  
  ghostty screen
  
  bc starship zenity
  claude-code
  nix-fast-build
  fastfetch
  codex
  age sops
  
  # inputs.caelestia.packages.${system}.default
  (inputs.fenix.packages.${system}.stable.withComponents [
    "cargo"
    "clippy"
    "rustc"
    "rustfmt"
    "rust-src"
  ])
  inputs.fenix.packages.${system}.stable.rust-analyzer
]
