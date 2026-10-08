{ config, lib, pkgs, inputs, ... }:

let
  src = inputs.nyxt-config;

  wezterm = lib.getExe config.programs.wezterm.package;
  yzx = lib.getExe' config.programs.yazelix.package "yzx";

  nyxtEdit = pkgs.writers.writeNuBin "nyxt-edit" ''
    def main [file: path] {
      let layout = (mktemp -t nyxt-edit-XXXXXX.kdl)
      $"layout {\n    pane command=\"yzx-hx\" close_on_exit=true borderless=true {\n        args ($file | to json)\n    }\n}\n" | save -f $layout
      ^${wezterm} start --always-new-process -- ${yzx} run zellij --config $"($env.HOME)/.local/share/yazelix/zellij/config.kdl" --new-session-with-layout $layout
      rm $layout
    }
  '';

  base = pkgs.runCommand "nyxt-config-base" { } ''
    cp -r ${src}/base $out
    chmod -R u+w $out
    substituteInPlace $out/commands.lisp \
      --replace-fail '"emacsclient" "-c" "-F" "((name . \"floating\"))"' '"${lib.getExe nyxtEdit}"'
  '';
in
{
  programs.nyxt = {
    enable = true;
    package = null;
    config = ''
      (in-package :nyxt-user)

      (nyxt::load-lisp "~/.config/nyxt/base/urlprompt.lisp")
      (nyxt::load-lisp "~/.config/nyxt/base/domainrules.lisp")
      (nyxt::load-lisp "~/.config/nyxt/base/commands.lisp")
      (nyxt::load-lisp "~/.config/nyxt/base/keybindings.lisp")
      (nyxt::load-lisp "~/.config/nyxt/base/glyphs.lisp")

      (defvar *spacemacs-dark*
        (make-instance 'theme:theme
          :background-color-   "#212026"
          :background-color    "#292b2e"
          :background-color+   "#34323e"
          :on-background-color "#b2b2b2"

          :primary-color-   "#5d4d7a"
          :primary-color    "#bc6ec5"
          :primary-color+   "#c56ec3"
          :on-primary-color "#212026"

          :secondary-color-   "#3b314d"
          :secondary-color    "#444155"
          :secondary-color+   "#5d4d7a"
          :on-secondary-color "#b2b2b2"

          :action-color-   "#7590db"
          :action-color    "#4f97d7"
          :action-color+   "#2aa1ae"
          :on-action-color "#212026"

          :highlight-color-   "#9f8766"
          :highlight-color    "#b1951d"
          :highlight-color+   "#dc752f"
          :on-highlight-color "#212026"

          :success-color-   "#2d9574"
          :success-color    "#67b11d"
          :success-color+   "#86dc2f"
          :on-success-color "#212026"

          :warning-color-   "#dc752f"
          :warning-color    "#e0211d"
          :warning-color+   "#f2241f"
          :on-warning-color "#e3dedd"))

      (define-configuration browser
        ((theme *spacemacs-dark*)
         (search-engines
          (cons (make-instance 'search-engine
                               :name "Yandex"
                               :shortcut "y"
                               :control-url "https://yandex.com/search/?text=~a")
                %slot-value%))))

      (define-configuration prompt-buffer
        ((style (str:concat
                 %slot-default%
                 (theme:themed-css (theme *browser*)
                   `("#selection td"
                     :color ,theme:on-action-color))))))

      (echo "Loaded config.")
    '';
  };

  xdg.configFile."nyxt/base".source = base;
}
