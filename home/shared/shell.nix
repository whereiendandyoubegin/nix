{ config, pkgs, ... }:

{
  home.shellAliases = {
    ns = "sudo nixos-rebuild switch --flake ~/cloned/nixpublic --fast";
    ga = "git add .";
    ndir = "cd ~/cloned/nix";  
  };

  programs.nushell = {
    enable = true;
    configFile.text = ''
      $env.config = {
        show_banner: false
      }

      $env.STARSHIP_SHELL = "nu"

      def --env starship_prompt [] {
        starship prompt
      }

      $env.PATH = ($env.PATH | prepend $"($env.HOME)/.local/bin" | prepend $"/etc/profiles/per-user/($env.USER)/bin")
      $env.PROMPT_COMMAND = { || starship_prompt }
      $env.PROMPT_INDICATOR = ""
      $env.PROMPT_MULTILINE_INDICATOR = "… "
    '';
  };

  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;
      format = "╭─$directory$git_branch$git_status$git_state$cmd_duration$fill$time\n╰─$character\n";
      
      time = {
        disabled = false;
        style = "bright-black";
        format = "[$time]($style)";
      };
      
      cmd_duration = {
        min_time = 2;
        style = "yellow";
        format = "took [$duration]($style)";
      };
      
      directory = { style = "cyan"; };
      git_branch = { style = "magenta"; };
      git_status = { style = "red"; };
      
      character = {
        success_symbol = "[❯](green)";
        error_symbol = "[❯](red)";
        vicmd_symbol = "[❮](blue)";
      };
    };
  };

  services.ssh-agent.enable = true;
  
  programs.ssh = {
    enable = true;
    addKeysToAgent = "yes";
  };

  programs.keychain = {
    enable = true;
    keys = [ "id_ed25519" ];
    extraFlags = [ "--quiet" ];
  };
}
