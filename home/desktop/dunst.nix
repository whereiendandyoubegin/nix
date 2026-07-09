{ config, pkgs, ... }:

{
  services.dunst = {
    enable = true;
    settings = {
      global = {
        geometry = "300x5-30+20";
        transparency = 10;
        font = "JetBrains Mono 10";
      };
      
      urgency_low = {
        background = "#2b3339";
        foreground = "#ffffff";
        timeout = 5;
      };
      
      urgency_normal = {
        background = "#2b3339";
        foreground = "#ffffff";
        timeout = 10;
      };
      
      urgency_critical = {
        background = "#f53c3c";
        foreground = "#ffffff";
        timeout = 0;
      };
      
      spotify = {
        appname = "Spotify";
        skip_display = true;
      };
    };
  };
}
