{ pkgs, lib, nyxt-src, ... }:
let
  nyxtSubmodules = lib.importJSON ./nyxt-submodules.json;

  fetchSubmodule = s: builtins.fetchGit {
    inherit (s) url rev;
    allRefs = true;
  };
in
{
  nixpkgs.overlays = [
    (final: prev: {
      nyxt = prev.nyxt.overrideAttrs (oldAttrs: {
        version = "unstable-${builtins.substring 0 7 nyxt-src.rev}";
        src = prev.runCommand "nyxt-src-with-submodules" { } ''
          cp -r ${nyxt-src} $out
          chmod -R u+w $out
          ${lib.concatMapStringsSep "\n" (s: ''
            rm -rf $out/${s.path}
            cp -r ${fetchSubmodule s} $out/${s.path}
          '') nyxtSubmodules}
          rm -rf $out/_build/closer-mop
          cp -r ${prev.sbclPackages.closer-mop.src} $out/_build/closer-mop
          chmod -R u+w $out
        '';
        makeFlags = (oldAttrs.makeFlags or []) ++ [ "NYXT_SUBMODULES=false" "NYXT_RENDERER=gtk" ];
      });
    })
  ];
}
