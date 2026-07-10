{ config, pkgs, ... }:
let
  nvidia-oc = pkgs.rustPlatform.buildRustPackage rec {
    pname = "nvidia_oc";
    version = "unstable";
    src = pkgs.fetchFromGitHub {
      owner = "Dreaming-Codes";
      repo = "nvidia_oc";
      rev = "master";
      hash = "sha256-PIe4oJndISf6wDxHGQvTeN37cFa+3m6RwmxXRlseePc=";
    };
    cargoHash = "sha256-e6cX9P5dHDOLS06Bx1VuMpH/ilcpyFnHpttG7DDwz8U=";
  };
in
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = false;
    powerManagement.finegrained = false;
    open = false;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    nvidiaPersistenced = true;
  };

  boot.extraModprobeConfig = ''
    options nvidia_drm fbdev=1
    options nvidia NVreg_UsePageAttributeTable=1 NVreg_EnableGpuFirmware=0
  '';

  boot.kernelParams = [
    "pcie_aspm=off"
    "mitigations=off"
  ];

  powerManagement.cpuFreqGovernor = "performance";

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  environment.systemPackages = [ nvidia-oc ];

  environment.etc."nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json".text = builtins.toJSON {
    rules = [
      {
        pattern = { feature = "procname"; matches = "niri"; };
        profile = "Limit Free Buffer Pool On Wayland Compositors";
      }
    ];
    profiles = [
      {
        name = "Limit Free Buffer Pool On Wayland Compositors";
        settings = [
          { key = "GLVidHeapReuseRatio"; value = 0; }
        ];
      }
    ];
  };

  systemd.services.nvidia-oc = {
    description = "NVML-based GPU clock offset";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Environment = "LD_LIBRARY_PATH=/run/opengl-driver/lib";
      ExecStart = "${nvidia-oc}/bin/nvidia_oc set --index 0 --power-limit 350000 --freq-offset 100 --mem-offset 800 --min-clock 0 --max-clock 2000";
    };
  };
}

