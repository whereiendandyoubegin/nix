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
        postPatch = (oldAttrs.postPatch or "") + ''
          substituteInPlace nyxt.asd \
            --replace-fail '(:file "mode/user-script")' "" \
            --replace-fail ':components ((:file "renderer/gtk")' ':components ((:file "mode/user-script") (:file "renderer/gtk")'
          substituteInPlace source/renderer/gtk.lisp \
            --replace-fail '(defmethod enable :after ((mode nyxt/mode/reduce-tracking:' '#+(or) (defmethod enable :after ((mode nyxt/mode/reduce-tracking:' \
            --replace-fail '(defmethod disable :after ((mode nyxt/mode/reduce-tracking:' '#+(or) (defmethod disable :after ((mode nyxt/mode/reduce-tracking:'
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 nyxt $out/bin/nyxt
          install -Dm644 assets/nyxt.desktop $out/share/applications/nyxt.desktop
          install -Dm644 assets/glyphs/nyxt.svg $out/share/icons/hicolor/scalable/apps/nyxt.svg
          runHook postInstall
        '';
        env = oldAttrs.env // {
          LD_LIBRARY_PATH = "${oldAttrs.env.LD_LIBRARY_PATH}:${lib.makeLibraryPath [ prev.enchant ]}";
        };
        makeFlags =(oldAttrs.makeFlags or []) ++ [ "NYXT_SUBMODULES=false" "NYXT_RENDERER=gtk" ];
      });
    })
  ];
}
