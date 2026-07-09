{ ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      spotify-player = prev.spotify-player.overrideAttrs (old: {
        cargoBuildFeatures = [ "pulseaudio-backend" ];
        buildInputs = (old.buildInputs or []) ++ [ prev.pulseaudio ];
      });
    })
  ];
}
