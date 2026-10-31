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
            nativeBuildInputs = [ final.pkg-config final.rustPlatform.bindgenHook ];
            buildInputs = [ final.openssl final.portaudio ];
            cargoBuildFeatures = features;
            cargoCheckFeatures = features;
            meta = old.meta // { platforms = lib.platforms.linux ++ lib.platforms.darwin; };
          });
    })
  ];
}
