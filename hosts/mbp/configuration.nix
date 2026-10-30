{ config, ... }:
let
  xdg = config.home-manager.users.dan.xdg;
in
{
  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;

  system.primaryUser = "dan";
  users.users.dan.home = "/Users/dan";

  nix.gc.interval = { Weekday = 0; Hour = 3; Minute = 0; };

  home-manager.users.dan.xdg.enable = true;
  launchd.user.envVariables = {
    XDG_CONFIG_HOME = xdg.configHome;
    XDG_CACHE_HOME = xdg.cacheHome;
    XDG_DATA_HOME = xdg.dataHome;
    XDG_STATE_HOME = xdg.stateHome;
  };

  system.stateVersion = 6;
}
