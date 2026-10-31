{ pkgs, inputs, ... }: {
  imports = [
    ../shared/git.nix
    ../shared/terminal.nix
    ../shared/editor.nix
    ../shared/shell.nix
    ../shared/yazelix.nix
  ];

  home.stateVersion = "26.05";
  home.packages = with pkgs; [
    git python3 llvm lld ninja tree 
    whois curl jq yq ast-grep fd fzf
    less wget discordo
    spotatui unzip unrar zip uv
    ethtool usbutils ffmpeg btop iotop
    python3Packages.python-lsp-server
    clang-tools clang openssl screen 
    nix-fast-build age sops codex
    
    (inputs.fenix.packages.${system}.stable.withComponents [
      "cargo"
      "clippy"
      "rustc"
      "rustfmt"
      "rust-src"
    ])
    inputs.fenix.packages.${system}.stable.rust-analyzer
    inputs.claude-code-nix.packages.${system}.default 
  ];
}
