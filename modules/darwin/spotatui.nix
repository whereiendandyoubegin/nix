{ lib, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      spotatui =
        (prev.spotatui.override { withPipewireVisualizer = false; }).overrideAttrs (old:
          let
            features = old.cargoBuildFeatures ++ [ "audio-viz-cpal" "macos-media" ];
          in
          {
            nativeBuildInputs = old.nativeBuildInputs ++ [ final.rustPlatform.bindgenHook ];
            buildInputs =
              builtins.filter (p: (p.pname or "") != "alsa-lib") old.buildInputs
              ++ [ final.portaudio ];
            cargoBuildFeatures = features;
            cargoCheckFeatures = features;
            meta = old.meta // { platforms = lib.platforms.linux ++ lib.platforms.darwin; };
          });
      
      concord-tui = prev.concord-tui.overrideAttrs (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [ final.rustPlatform.bindgenHook ];
      });
    })
  ];
}
