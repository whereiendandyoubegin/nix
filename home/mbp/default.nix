{ pkgs, inputs, lib, ... }: {
  imports = [
    ../shared/git.nix
    ../shared/terminal.nix
    ../shared/editor.nix
    ../shared/shell.nix
    ../shared/yazelix.nix
  ];

  ## I am able to set touch id to auth ssh, but I need to write a script for this
  ## TODO: implement ssh auth through touch id
  # programs.ssh.settings."*".SecurityKeyProvider = "/usr/lib/ssh-keychain.dylib";
  
  home.shellAliases.ns = lib.mkForce ''sudo darwin-rebuild switch --flake "/Users/dan/cloned/nix#mbp"'';

  programs.yazelix.config.rio.text = ''
    option-as-alt = "Left"
  '';

  home.stateVersion = "26.05";
  home.packages = with pkgs; [
    git python3 llvm lld ninja tree 
    whois curl jq yq ast-grep fd fzf
    less wget discordo
    spotatui unzip unrar zip uv
    usbutils ffmpeg btop 
    python3Packages.python-lsp-server
    clang-tools clang openssl screen 
    nix-fast-build age sops codex
    concord-tui 
    
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
