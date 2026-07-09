# Dan's Modular NixOS Configuration

This is a modular NixOS configuration organized for maintainability and clarity.

## Structure

```
.
├── flake.lock
├── flake.nix
├── helpers
│   └── yazelix
│       ├── generate-options.nix
│       └── options.txt
├── home
│   ├── desktop
│   │   ├── default.nix
│   │   ├── dunst.nix
│   │   └── niri.nix
│   └── shared
│       ├── editor.nix
│       ├── git.nix
│       ├── shell.nix
│       ├── terminal.nix
│       └── yazelix.nix
├── hosts
│   └── desktop
│       ├── configuration.nix
│       └── hardware-configuration.nix
├── modules
│   ├── desktop
│   │   ├── niri.nix
│   │   └── plasma.nix
│   ├── development
│   │   ├── packages.nix
│   │   └── virtualisation.nix
│   ├── hardware
│   │   ├── audio.nix
│   │   ├── bluetooth.nix
│   │   └── nvidia.nix
│   └── system
│       ├── kernel.nix
│       ├── nix.nix
│       └── overlays.nix
```


## Adding New Modules

1. Create a new `.nix` file in the appropriate `modules/` subdirectory
2. Import it in `flake.nix` under the relevant configuration
3. Rebuild to apply changes

## Customization

- Edit `hosts/desktop/configuration.nix` for host-specific settings
- Modify modules in `modules/` for system-wide changes
- Customize home-manager settings in `home/`
