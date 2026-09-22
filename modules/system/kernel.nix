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

  boot.kernel.sysctl."vm.swappiness" = 10;
}
