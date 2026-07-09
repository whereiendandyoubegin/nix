{ config, pkgs, ... }:
{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
        Experimental = true; # needed for battery reporting + some codec negotiation paths
        ControllerMode = "bredr";
        DeviceID = "bluetooth:004C:0000:0000";
      };
    };
  };

  services.blueman.enable = true;

  programs.librepods.enable = true;

  services.pipewire = {
    enable = true;
    pulse.enable = true; # gets you pactl back
    wireplumber.extraConfig."51-bluez" = {
      "monitor.bluez.properties" = {
        "bluez5.roles" = [ "a2dp_sink" "a2dp_source" ];
        "bluez5.codecs" = [ "aac" "sbc" "sbc_xq" ];
        "bluez5.enable-msbc" = true;
        "bluez5.enable-sbc-xq" = true;
        "bluez5.enable-hw-volume" = true;
      };
    };
  };
}
