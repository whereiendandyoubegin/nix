{ config, pkgs, inputs, lib, ... }:

let
  registry = inputs.dms-registry;

  pluginManifests = builtins.fromJSON
    (builtins.readFile "${registry}/nix/plugins-prefetch.json");

  runsOnNiri = plugin:
    let
      compositors = plugin.meta.compositors or [ "any" ];
    in
    builtins.elem "any" compositors || builtins.elem "niri" compositors;

  excluded = {
    missingDependencies = [
      "chatManager"
      "voxTypeOsd"
      "voxtype"
      "voxtypeActivityOverlay"
      "voxtypeOverlay"
    ];

    otherVendorHardware = [
      "acerSense"
      "aerox3Battery"
      "asusControlCenter"
      "awcc"
      "dankAsusControlCenter"
      "dankRazer"
      "dmsFrameworkBattery"
      "dmsLenovoBatterySettings"
      "dmsNothingX"
      "fwFanctrl"
      "pulsarX3"
      "zmkBattery"
    ];

    nonNvidiaGpu = [
      "amdGpuMonitor"
      "amdGpuMonitorRevive"
      "intelGpuMonitor"
    ];

    laptopPower = [
      "backlightIdleActions"
      "batteryOSD"
      "batteryPlus"
      "dgpuStatus"
      "kbdBacklightOSD"
      "tlpControl"
      "tlpPowerProfile"
    ];

    localeSpecific = [
      "brSoccer"
      "chineseCalendar"
      "dolarBlue"
      "magyarNevnapok"
      "nepaliCalendar"
      "persianCalendar"
      "prayerTimes"
      "quranWidget"
      "stockManager"
      "wienerLinien"
    ];

    brokenUpstream = [
      "dankAIUsage"
    ];

    unwanted = [
      "spotifyMatugen"
      "wallpaperByWorkspace"
    ];
  };

  disabledPlugins = lib.concatLists (lib.attrValues excluded);

  verseApi = "https://labs.bible.org/api/?passage=votd&type=json";

  verseReference = ''curl -s '${verseApi}' | jq -r '.[0] | "\(.bookname) \(.chapter):\(.verse)"' '';

  versePassage = ''curl -s '${verseApi}' | jq -r '.[] | "\(.bookname) \(.chapter):\(.verse)  \(.text)"' '';

  registryPlugins = import "${registry}/nix/default.nix" { inherit pkgs; };

  musicLyricsPatched = pkgs.runCommand "dms-plugin-musicLyrics-patched" { } ''
    cp -r ${registryPlugins.musicLyrics} $out
    chmod -R u+w $out
    substituteInPlace $out/MusicLyrics.qml \
      --replace-fail "DankAlbumArt {" "MediaArtwork {" \
      --replace-fail "width: Math.min(implicitWidth, 300)" "width: Math.min(implicitWidth, 800)"
    sed -i -e '/activePlayer: root.activePlayer/{N;s/activePlayer: root\.activePlayer\n *showAnimation: true/artUrl: root.activePlayer?.trackArtUrl ?? ""/}' $out/MusicLyrics.qml
    grep -q 'artUrl: root.activePlayer' $out/MusicLyrics.qml
    if grep -q 'showAnimation: true' $out/MusicLyrics.qml; then exit 1; fi
  '';

  niriPlugins = lib.filterAttrs
    (name: plugin: runsOnNiri plugin && !(builtins.elem name disabledPlugins))
    pluginManifests;
in
{
  imports = [ "${registry}/nix/module.nix" ];

  programs.dank-material-shell = {
    enable = true;
    systemd.enable = true;

    package = (inputs.dank-material-shell.lib.mkDmsShell pkgs).override {
      extraQtPackages = with pkgs.kdePackages; [ qt5compat qtwebsockets ];
    };

    managePluginSettings = true;

    plugins = lib.mapAttrs
      (name: _: {
        enable = true;
      } // lib.optionalAttrs (name == "musicLyrics") {
        src = lib.mkForce musicLyricsPatched;
      } // lib.optionalAttrs (name == "enderPulse") {
        settings = {
          barLength = 420;
          bandCount = 96;
        };
      } // lib.optionalAttrs (name == "intervalCommand") {
        settings = {
          icon = "menu_book";
          refreshInterval = 3600;
          popoutEnabled = true;
          command = verseReference;
          clickCommand = versePassage;
        };
      })
      niriPlugins;

    settings = {
      configVersion = 29;
      currentThemeName = "dynamic";

      barConfigs = [
        {
          id = "default";
          name = "Main Bar";
          enabled = true;
          position = 0;
          screenPreferences = [ "all" ];
          leftWidgets = [ "launcherButton" "workspaceSwitcher" "focusedWindow" ];
          centerWidgets = [
            { id = "music"; mediaSize = 3; }
            "musicLyrics"
            "clock"
            "weather"
            "intervalCommand"
          ];
          rightWidgets = [
            "enderPulse"
            "volumeMixer"
            "audioSwitcher"
            "systemTray"
            "clipboard"
            "cpuUsage"
            "memUsage"
            "notificationButton"
            "controlCenterButton"
          ];
          fontScale = 2;
          innerPadding = 8;
          spacing = 8;
        }
      ];
    };
  };

  xdg.configFile."DankMaterialShell/themes" = {
    source = "${registry}/themes";
    recursive = true;
  };
}
