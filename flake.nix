{
  description = "Nostr relay in Elixir";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-26.05;
  };

  outputs = { self, nixpkgs }: let
    overlay = final: prev: let
      beamPackages = prev.beamMinimal29Packages.extend (self: super: {
        elixir = super.elixir_1_20;
      });
    in {
      inherit beamPackages;
      elixir = beamPackages.elixir;
      erlang = beamPackages.erlang;
      hex = beamPackages.hex;
    };

    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
    ];

    pkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [overlay];
      };

    noxir = pkgs:
      pkgs.beamPackages.mixRelease {
        pname = "noxir";
        version = "0.2.0";
        src = ./.;
        mixNixDeps = pkgs.callPackages ./nix/deps.nix {};
      };

    # Docker image built entirely from Nix. No Dockerfile needed.
    # Load with: docker load < $(nix build .#dockerImage --print-out-paths)/stream-noxir.tar.gz
    noxirDocker = pkgs: let
      release = noxir pkgs;
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
            "RELEASE_COOKIE=noxir"
          ];
          WorkingDir = "/app";
        };
      };
  in {
    devShells = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = pkgs.callPackage ./nix/shell.nix {};
    });

    packages = forAllSystems (system: let
      pkgs = pkgsFor system;
    in {
      default = noxir pkgs;
      dockerImage = noxirDocker pkgs;
    });

    apps = forAllSystems (system: {
      default = {
        type = "app";
        program = "${noxir (pkgsFor system)}/bin/noxir";
      };
    });

    nixosModules.default = {
      imports = [./nix/module.nix];
      _module.args.noxirFlake = self;
    };
  };
}
