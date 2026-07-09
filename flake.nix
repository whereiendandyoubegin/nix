{
  description = "Dan's Modular NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
            
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    zaphkiel = {
      url = "github:Rexcrazy804/Zaphkiel";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    quickshell = {
      url = "git+https://git.outfoxxed.me/outfoxxed/quickshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    caelestia = {
      url = "git+https://git.dan-gilmour.com/dan/flake-only.git";
      inputs.quickshell.follows = "quickshell";
    };

    yazelix = {
      url = "github:luccahuguet/yazelix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    steel-plugin-nix = {
      url = "git+https://git.dan-gilmour.com/dan/steel-plugin-nix.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, caelestia, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in {
      nixosConfigurations = {
        dan-nix = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            ./modules/system/overlays.nix
            ./hosts/desktop/configuration.nix
            ./modules/system/nix.nix
            ./modules/hardware/nvidia.nix
            ./modules/hardware/bluetooth.nix
            ./modules/hardware/audio.nix
            ./modules/desktop/niri.nix
            ./modules/desktop/plasma.nix
            ./modules/development/virtualisation.nix
            ./modules/system/kernel.nix
            
            home-manager.nixosModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                backupFileExtension = ".backup";
                users.dan = import ./home/desktop;
                extraSpecialArgs = { inherit inputs; };
              };
            }
          ];
        };
      };

      homeConfigurations."dan@dan-nix" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = { inherit inputs; };
        modules = [
          ./home/desktop
          {
            home.username = "dan";
            home.homeDirectory = "/home/dan";
          }
        ];
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = import ./modules/development/packages.nix { inherit pkgs inputs system; lib = pkgs.lib; };
        shellHook = ''
          export EDITOR=hx
          export KUBECONFIG=$HOME/.kube/config
          echo "Development environment loaded"
        '';
      };
    };
}
