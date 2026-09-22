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

  wallpaperDir = "${config.home.homeDirectory}/Pictures/Wallpapers";
  defaultWallpaper = "${wallpaperDir}/cwmavon-panorama.jpg";

  seedDefaults = pkgs.writeText "dms-defaults.py" ''
    import json, os

    targets = {
        os.path.expanduser("~/.local/state/DankMaterialShell/session.json"): {
            "wallpaperPathDark": "${defaultWallpaper}",
            "wallpaperPathLight": "${defaultWallpaper}",
            "wallpaperCyclingEnabled": True,
            "wallpaperCyclingRandom": True,
            "wallpaperCyclingMode": "interval",
            "wallpaperCyclingInterval": 1800,
            "wallpaperCyclingFolderPath": "${wallpaperDir}",
        },
        os.path.expanduser("~/.config/DankMaterialShell/settings.json"): {
            "currentThemeName": "dynamic",
        },
    }

    for path, defaults in targets.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            data = {}

        missing = {k: v for k, v in defaults.items() if k not in data}
        if not missing:
            continue

        data.update(missing)
        tmp = path + ".new"
        with open(tmp, "w") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp, path)
        print(os.path.basename(path), "seeded:", ", ".join(sorted(missing)))
  '';
in
{
  home.file = lib.mapAttrs'
    (name: src: lib.nameValuePair "Pictures/Wallpapers/${name}" { source = src; })
    wallpapers;

  home.activation.dmsSessionDefaults = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.python3}/bin/python3 ${seedDefaults}
  '';
}
