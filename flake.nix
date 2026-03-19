{
  description = "kgd - Kitty Graphics Daemon";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = {
    nixpkgs,
    self,
    ...
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forEachSystem = f:
      nixpkgs.lib.genAttrs supportedSystems (system:
        f {
          pkgs = import nixpkgs {inherit system;};
          inherit system;
        });
  in {
    packages = forEachSystem ({pkgs, ...}: {
      default = pkgs.buildGoModule {
        pname = "kgd";
        version = "0.1.0";
        src = ./.;
        vendorHash = "sha256-bEQIuXh9uZk2qnpdJjAISwxiSHldOi/YninWGwr4ynE=";
      };
    });

    overlays.default = final: _: {
      kgd = self.packages.${final.system}.default;
    };

    devShells = forEachSystem ({pkgs, ...}: {
      default = pkgs.mkShell {
        buildInputs = with pkgs;
          [
            # Core daemon (Go)
            go
            gopls
            gotools
            just
            git
            # C client
            clang
            clang-tools
            cppcheck
            # Python client
            python3
          ]
          ++ lib.optionals stdenv.isLinux [
            # Client toolchains — on Darwin these conflict with clang's Apple SDK,
            # so install them via native package managers (rustup, nvm, etc.)
            rustc
            cargo
            clippy
            rustfmt
            nodejs
            lua
            luarocks
            zig
            kotlin
            gradle
            dotnet-sdk_8
            ocaml
            dune_3
            opam
            swift
          ];
      };
    });
  };
}
