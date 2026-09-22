{ config, pkgs, ... }:

{
  services.displayManager.sessionPackages = [ pkgs.niri ];
  
  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gnome
      xdg-desktop-portal-gtk
    ];
    config = {
      common.default = [ "gtk" ];
      niri = {
        default = [ "gnome" "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "gnome" ];
        "org.freedesktop.impl.portal.Screenshot" = [ "gnome" ];
      };
    };
  };
  
  security.polkit.enable = true;
  services.dbus.enable = true;

  services.power-profiles-daemon.enable = true;
  services.accounts-daemon.enable = true;
  services.geoclue2.enable = true;
  
  environment.sessionVariables = {
    XDG_CURRENT_DESKTOP = "niri";
    XDG_SESSION_DESKTOP = "niri";
    XDG_SESSION_TYPE = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
  };
  
  systemd.user.settings.Manager = {
    DefaultEnvironment = [
      "XDG_CURRENT_DESKTOP=niri"
      "XDG_SESSION_DESKTOP=niri"
      "XDG_SESSION_TYPE=wayland"
    ];
  };
}
