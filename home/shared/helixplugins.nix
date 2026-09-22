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
      owner = "whereiendandyoubegin";
      repo = "scooter.hx";
      rev = "76bf578b59821934c2f0df872cd7a866a30c0aeb";
      hash = "sha256-17L7g4EMLfc1Y693kM6xOpUrjnbLyDkj+lPHsakk+KY=";
      id = "scooter";
      source = "scooter.scm";
      support_files = [
        "ui/window.scm"
        "ui/fields.scm"
        "ui/drawing.scm"
        "ui/styles.scm"
        "ui/utils.scm"
      ];
      public_commands = [ "scooter" "scooter-new" ];
    }
    {
      owner = "mattwparas";
      repo = "helix-file-watcher";
      rev = "8cd0726da47be4a1011c3246ff308c1dfefda9d1";
      hash = "sha256-auqS4wcJGCUJXzRVj4neQLJnqErvty3+3shfq5DU/pg=";
      id = "helix-file-watcher";
      source = "file-watcher.scm";
      support_files = [ "helix-file-watcher.scm" ];
      public_commands = [ "spawn-watcher" ];
      outputHashes = {
        "steel-core-0.8.2" = "sha256-qPDz0ax290E7UEFTDfrmLmsn1r9dIuOxMiRmNrDkfZo=";
      };
    }
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
    }
  ];
}
