{ config, pkgs, lib, ... }:

let
  wallpapers = {
    "cwmavon-panorama.jpg" = pkgs.fetchurl {
      url = "https://upload.wikimedia.org/wikipedia/commons/d/dd/Cwmavon_Panorama_from_Mynydd_Dinas_-_panoramio.jpg";
      hash = "sha256-LZR3WcS6N/Ah1LPyytWDhd+yTm9ix5hy3IVq6IziFok=";
    };

    "churchill-village-panorama.jpg" = pkgs.fetchurl {
      url = "https://upload.wikimedia.org/wikipedia/commons/0/0c/Panorama_of_Churchill_village_taken_from_Windmill_Hill.jpg";
      hash = "sha256-J1e+XBcbM4KVn8tlSbB3mO5WCPkOFabQ8zxJutMu/hA=";
    };

    "ambleside-waterhead-panorama.jpg" = pkgs.fetchurl {
      name = "ambleside-waterhead-panorama.jpg";
      url = "https://upload.wikimedia.org/wikipedia/commons/2/25/Ambleside_%26_Waterhead_Panorama_2%2C_Cumbria%2C_England_-_Oct_2009.jpg";
      hash = "sha256-Xe+tzomvCD6s2C1WY8n45tFKXDMGZe+gDB2NXge0kFM=";
    };
  };
in
{
  home.file = lib.mapAttrs'
    (name: src: lib.nameValuePair "Pictures/Wallpapers/${name}" { source = src; })
    wallpapers;
}
