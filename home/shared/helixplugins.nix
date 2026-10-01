let
  helixConfigRepo = {
    owner = "mattwparas";
    repo = "helix-config";
    rev = "a101da0852932f10792f098dbb14ea88811985ff";
    hash = "sha256-N4Y78H9HDJernQkdH+24tylfl1bleBZewTB7Fk9LlGg=";
  };
in
{
  inherit helixConfigRepo;

  interpreted = [
    (helixConfigRepo // {
      id = "keymaps";
      source = "cogs/keymaps.scm";
    })
    (helixConfigRepo // {
      id = "labelled-buffers";
      source = "cogs/labelled-buffers.scm";
    })
    (helixConfigRepo // {
      id = "git-status-picker";
      source = "cogs/git-status-picker.scm";
      public_commands = [ "create-gs-picker" "add-modified-file" ];
    })
    (helixConfigRepo // {
      id = "file-tree";
      source = "cogs/file-tree.scm";
      public_commands = [
        "open-file-from-picker"
        "create-file"
        "fold-directory"
        "create-directory"
        "fold-all"
        "unfold-all-one-level"
      ];
    })
    {
      owner = "thomasschafer";
      repo = "smooth-scroll.hx";
      rev = "1ed8b088e465fb139389c36ad158ba4a2d9e1bbc";
      hash = "sha256-4lxGZrT4cEcg3jqae3uJGGGCSy4WeVZeJ0hIApMb7jY=";
      id = "smooth-scroll";
      source = "smooth-scroll.scm";
      support_files = [ "src/utils.scm" ];
      public_commands = [
        "half-page-up-smooth"
        "half-page-down-smooth"
        "page-up-smooth"
        "page-down-smooth"
      ];
    }
  ];

  compiled = [
    {
      owner = "thomasschafer";
      repo = "scooter.hx";
      rev = "2d4c9244fd184c16fc1e351f5c5bebc2519aeac8";
      hash = "sha256-YZakZAUHDAk48GCdgUbIM7c2u42nWll1V9ug5WanBD0=";
      id = "scooter.hx";
      source = "scooter.scm";
      support_files = [
        "ui/window.scm"
      ];
      public_commands = [ "scooter" "scooter-new" ];
    }
  ];

  steelBumped = [
    {
      owner = "Ciflire";
      repo = "presence.hx";
      rev = "5b5f134c30c3a3d9a6f3565e8cc56973230bc7ef";
      hash = "sha256-L+fExKl4X1BHi+BIKHgBPtqyHHjqAc0qwyvCq8c0B0E=";
      id = "helix-discord-rpc";
      source = "helix-discord-rpc.scm";
      support_files = [ "helix-discord-rpc.scm" ];
      public_commands = [ "discord-rpc-connect" ];
      startup_commands = [ "discord-rpc-connect" ];
      steelCore = { from = "0.7.0"; to = "0.8.3"; };
      lockFile = ./steel/presence-hx.Cargo.lock;
    }
  ];
}
