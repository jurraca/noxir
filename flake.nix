{
  description = "Nostr relay in Elixir";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-26.05;
  };

  outputs = { self, nixpkgs }: let
    overlay = prev: final: rec {
      beamPackages = prev.beamMinimal29Packages;
      elixir = beamPackages.elixir_1_20;
      erlang = beamPackages.erlang;
      hex = beamPackages.hex;
    };

    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
    ];

    nixpkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [overlay];
      };

    noxirMixRelease = system: let
      pkgs = nixpkgsFor system;
      beamPackages = pkgs.beamPackages;
      mixNixDeps = import ./deps.nix {
        inherit (pkgs) lib stdenv cmake extend lexbor fetchFromGitHub oniguruma pkg-config vips writeText;
        inherit beamPackages;
      };
    in
      pkgs.beamPackages.mixRelease {
        pname = "noxir";
        version = "0.2.0";
        src = ./.;
        inherit mixNixDeps;
      };

    # Docker image built entirely from Nix. No Dockerfile needed.
    # Load with: docker load < $(nix build .#dockerImage --print-out-paths)/stream-noxir.tar.gz
    noxirDocker = system: let
      pkgs = nixpkgsFor system;
      release = noxirMixRelease system;
    in
      pkgs.dockerTools.streamLayeredImage {
        name = "noxir";
        tag = "latest";

        contents = [
          release
          pkgs.openssl
        ];

        config = {
          Cmd = ["${release}/bin/noxir" "start"];
          ExposedPorts = [4000];
          Env = [
            "LANG=C.utf8"
            "MIX_ENV=prod"
          ];
          WorkingDir = "/app";
        };
      };
  in {
    devShells = forAllSystems (system: let
      pkgs = nixpkgsFor system;
    in {
      default = pkgs.callPackage ./shell.nix {};
    });

    packages = forAllSystems (system: {
      default = noxirMixRelease system;
      dockerImage = noxirDocker system;
    });

    apps = forAllSystems (system: {
      default = {
        type = "app";
        program = "${noxirMixRelease system}/bin/noxir";
      };
    });
  };
}
