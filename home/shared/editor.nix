{ config, pkgs, ... }:
{
  programs.helix = {
	        enable = true;

	        extraPackages = with pkgs; [
	          python3Packages.python-lsp-server
	          typescript-language-server
	          gopls
	          clang-tools
	          nil
            elixir-ls
            haskell-language-server
	        ];

	        settings = {
	          theme = "gruvbox";

	          editor = {
	            mouse = true;
	            "auto-save" = true;
	            rulers = [80 120];
	            cursorline = true;
	            cursorcolumn = true;
	            bufferline = "always";
	            "auto-completion" = true;
	            "completion-trigger-len" = 1;
	            "preview-completion-insert" = true;
	            "auto-info" = true;

	            "cursor-shape" = {
	              insert = "bar";
	              normal = "block";
	              select = "underline";
	            };

	            "soft-wrap" = {
	              enable = true;
	              "wrap-indicator" = "↩ ";
	            };

	            whitespace = {
	              render = {
	                space = "all";
	                tab = "all";
	                newline = "none";
	              };
	              characters = {
	                space = " ";
	                nbsp = "⍽";
	                tab = "→";
	                newline = "⏎";
	                tabpad = "·";
	              };
	            };

	            statusline = {
	              left = ["mode" "spinner" "diagnostics"];
	              center = ["file-name" "separator" "version-control" "separator"];
	              right = ["position" "position-percentage" "total-line-numbers"];
	              separator = "│";
	              mode = {
	                normal = "NORMAL";
	                insert = "INSERT";
	                select = "SELECT";
	              };
	            };

	            lsp = {
	              "display-inlay-hints" = true;
	            };

	            "indent-guides" = {
	              render = true;
	              character = "╎";
	              "skip-levels" = 1;
	            };

	            "file-picker" = {
	              hidden = false;
	            };
	          };
	        };

	        languages = {
	          language-server.clangd = {
	            command = "clangd";
	            args = ["--background-index" "--clang-tidy"];
	          };

	          language-server.pylsp = {
	            command = "pylsp";
	            config.pylsp.plugins = {
	              pycodestyle = { enabled = false; };
	              mccabe = { enabled = false; };
	              pyflakes = { enabled = false; };
	              flake8 = { enabled = false; };
	            };
	          };

	          language-server.gopls = {
	            command = "gopls";
	          };

            language-server.elixir-ls = {
              command = "elixir-ls";
            };

            language-server.haskell-language-server = {
              command = "haskell-language-server-wrapper";
              args = ["--lsp"];
            };

	          language-server.typescript-language-server = {
	            command = "typescript-language-server";
	            args = ["--stdio"];
	          };

	          language = [
	            {
	              name = "c";
	              scope = "source.c";
	              file-types = ["c" "h"];
	              language-servers = ["clangd"];
	              auto-format = true;
	            }
              {
                name = "elixir";
                scope = "source.ex";
                file-types = ["ex" "exs"];
                language-servers = ["elixir-ls"];
                auto-format = true;
              }
	            {
	              name = "cpp";
	              scope = "source.cpp";
	              file-types = ["cpp" "cc" "cxx" "hpp" "hxx"];
	              language-servers = ["clangd"];
	              auto-format = true;
	            }
	            {
	              name = "python";
	              scope = "source.python";
	              file-types = ["py" "pyi"];
	              language-servers = ["pylsp"];
	              auto-format = true;
	            }
	            {
	              name = "go";
	              scope = "source.go";
	              file-types = ["go"];
	              language-servers = ["gopls"];
	              auto-format = true;
	            }
	            {
	              name = "typescript";
	              scope = "source.ts";
	              file-types = ["ts"];
	              language-servers = ["typescript-language-server"];
	              auto-format = true;
	            }
	            {
	              name = "javascript";
	              scope = "source.js";
	              file-types = ["js" "jsx"];
	              language-servers = ["typescript-language-server"];
	              auto-format = true;
	            }
	            {
	              name = "haskell";
	              scope = "source.haskell";
	              file-types = ["hs"];
	              language-servers = ["haskell-language-server"];
	              auto-format = true;
	            }
	          ];
	        };
	      };
      }
