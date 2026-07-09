{ pkgs, inputs, ... }:

{
  imports = [
    inputs.chaotic.nixosModules.default
  ];

  boot.kernelPackages = pkgs.linuxPackages_cachyos-lto;
  boot.kernelParams = [ "preempt=full" ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
  };

  # Keep swappiness low so zram is only used under real pressure
  boot.kernel.sysctl."vm.swappiness" = 10;
}
