{ pkgs, nyxt-src, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      nyxt = prev.nyxt.overrideAttrs (oldAttrs: {
        version = "unstable-${builtins.substring 0 7 nyxt-src.rev}";
        makeFlags = (oldAttrs.makeFlags or []) ++ [ "NYXT_SUBMODULES=false" ];
      });
    })
  ];
}
