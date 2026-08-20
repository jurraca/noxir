{
  lib,
  beamPackages,
  cmake,
  extend,
  lexbor,
  fetchFromGitHub,
  oniguruma,
  overrides ? (x: y: { }),
  overrideFenixOverlay ? null,
  rustlerPrecompiledOverrides ? { },
  stdenv,
  pkg-config,
  vips,
  writeText,
}:

let
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;

  workarounds = {
    portCompiler = _unusedArgs: old: {
      buildPlugins = [ beamPackages.pc ];
    };

    rustlerPrecompiled =
      {
        toolchain ? null,
        buildInputs ? [ ],
        nativeBuildInputs ? [ ],
        env ? { },
        ...
      }:
      old:
      let
        extendedPkgs = extend fenixOverlay;
        fenixOverlay =
          if overrideFenixOverlay == null then
            import "${
              fetchTarball {
                url = "https://github.com/nix-community/fenix/archive/6399553b7a300c77e7f07342904eb696a5b6bf9d.tar.gz";
                sha256 = "sha256-C6tT7K1Lx6VsYw1BY5S3OavtapUvEnDQtmQB5DSgbCc=";
              }
            }/overlay.nix"
          else
            overrideFenixOverlay;
        nativeDir = "${old.src}/native/${with builtins; head (attrNames (readDir "${old.src}/native"))}";
        fenix =
          if toolchain == null then
            extendedPkgs.fenix.stable
          else
            extendedPkgs.fenix.fromToolchainName toolchain;
        native =
          (
            (extendedPkgs.makeRustPlatform {
              inherit (fenix) cargo rustc;
            }).buildRustPackage
            {
              inherit env buildInputs;
              pname = "${old.beamModuleName}-native";
              version = old.version;
              src = nativeDir;
              cargoLock = {
                lockFile = "${nativeDir}/Cargo.lock";
              };
              nativeBuildInputs = [ extendedPkgs.cmake ] ++ nativeBuildInputs;
              doCheck = false;
            }
          ).overrideAttrs
            rustlerPrecompiledOverrides.${old.beamModuleName} or { };

      in
      {
        nativeBuildInputs = [ extendedPkgs.cargo ];

        env.RUSTLER_PRECOMPILED_FORCE_BUILD_ALL = "true";
        env.RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "unused-but-required";

        preConfigure = ''
          mkdir -p priv/native
          for lib in ${native}/lib/*
          do
            dest="$(basename "$lib")"
            if [[ "''${dest##*.}" = "dylib" ]]
            then
              dest="''${dest%.dylib}.so"
            fi
            dest="''${dest#lib}"
            ln -s "$lib" "priv/native/$dest"
          done
        '';

        preBuild = ''
          suggestion() {
            echo "***********************************************"
            echo "                 deps_nix                      "
            echo
            echo " Rust dependency build failed.                 "
            echo
            echo " If you saw network errors, you might need     "
            echo " to disable compilation on the appropriate     "
            echo " RustlerPrecompiled module in your             "
            echo " application config.                           "
            echo
            echo " We think you need this:                       "
            echo
            echo -n " "
            grep -Rl 'use RustlerPrecompiled' lib \
              | xargs grep 'defmodule' \
              | sed 's/defmodule \(.*\) do/config :${old.beamModuleName}, \1, skip_compilation?: true/'
            echo "***********************************************"
            exit 1
          }
          trap suggestion ERR
        '';
      };

    elixirMake = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';
    };

    lazyHtml = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';

      postPatch = ''
        substituteInPlace mix.exs \
          --replace-fail "Fine.include_dir()" '"${packages.fine}/src/c_include"' \
          --replace-fail '@lexbor_git_sha "244b84956a6dc7eec293781d051354f351274c46"' '@lexbor_git_sha ""'
      '';

      preBuild = ''
        install -Dm644           -t _build/c/third_party/lexbor/$LEXBOR_GIT_SHA/build           ${lexbor}/lib/liblexbor_static.a
      '';
    };
  };

  defaultOverrides = (
    final: prev:

    let
      apps = {
        crc32cer = [
          {
            name = "portCompiler";
          }
        ];
        explorer = [
          {
            name = "rustlerPrecompiled";
            toolchain = {
              name = "nightly-2025-06-23";
              sha256 = "sha256-UAoZcxg3iWtS+2n8TFNfANFt/GmkuOMDf7QAE0fRxeA=";
            };
          }
        ];
        snappyer = [
          {
            name = "portCompiler";
          }
        ];
      };

      applyOverrides =
        appName: drv:
        let
          allOverridesForApp = builtins.foldl' (
            acc: workaround: acc // (workarounds.${workaround.name} workaround) drv
          ) { } apps.${appName};

        in
        if builtins.hasAttr appName apps then drv.override allOverridesForApp else drv;

    in
    builtins.mapAttrs applyOverrides prev
  );

  self = packages // (defaultOverrides self packages) // (overrides self packages);

  packages =
    with beamPackages;
    with self;
    {

      bandit =
        let
          version = "1.12.4";
          drv = buildMix {
            inherit version;
            name = "bandit";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "84513318c5752a2a8017664450f889b47fae5d53d64698ddf1e4fb09a7449e8d";
            };

            beamDeps = [
              hpax
              plug
              telemetry
              thousand_island
              websock
            ];
          };
        in
        drv;

      bechamel =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "bechamel";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "bechamel";
              sha256 = "42b3a5720ec94aa2ede20930f88d91efbe64179ae9764dbc2f560ddee102cbe5";
            };
          };
        in
        drv;

      cors_plug =
        let
          version = "3.0.3";
          drv = buildMix {
            inherit version;
            name = "cors_plug";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "cors_plug";
              sha256 = "3f2d759e8c272ed3835fab2ef11b46bddab8c1ab9528167bd463b6452edf830d";
            };

            beamDeps = [
              plug
            ];
          };
        in
        drv;

      db_connection =
        let
          version = "2.10.2";
          drv = buildMix {
            inherit version;
            name = "db_connection";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "510b14482330f1af6490a2fa0efd8d4f1435d1529b165647df22ac0f2df0fa93";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      decimal =
        let
          version = "3.1.1";
          drv = buildMix {
            inherit version;
            name = "decimal";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "decimal";
              sha256 = "c5f25f2ced74a0587d03e6023f595db8e924c9d3922c8c8ffd9edfc4498cf1f6";
            };
          };
        in
        drv;

      deps_nix =
        let
          version = "3.1.1";
          drv = buildMix {
            inherit version;
            name = "deps_nix";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "deps_nix";
              sha256 = "8264b699341e7f7c90e8ccda70c7730ce524ad1e5ee7102992eff5b7fb2373ea";
            };

            beamDeps = [
              ex_nar
              mint
            ];
          };
        in
        drv;

      ecto =
        let
          version = "3.14.2";
          drv = buildMix {
            inherit version;
            name = "ecto";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "25d60b8c816a07d19d85b80bdf60978bd8b102209dda198d768cd7c6745339a6";
            };

            beamDeps = [
              decimal
              telemetry
            ];
          };
        in
        drv;

      ecto_sql =
        let
          version = "3.14.0";
          drv = buildMix {
            inherit version;
            name = "ecto_sql";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ecto_sql";
              sha256 = "f4d8d36faf294c9417b5a37ec7ac8217ee2abdef5fcf197ba690f361548d3949";
            };

            beamDeps = [
              db_connection
              decimal
              ecto
              postgrex
              telemetry
            ];
          };
        in
        drv;

      elixir_make =
        let
          version = "0.10.0";
          drv = buildMix {
            inherit version;
            name = "elixir_make";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "elixir_make";
              sha256 = "dc1f09fb7fa68866b886abd5f0f3c83553b1a19a52359a899e92af1bb3b31982";
            };
          };
        in
        drv;

      ex_nar =
        let
          version = "0.3.0";
          drv = buildMix {
            inherit version;
            name = "ex_nar";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "ex_nar";
              sha256 = "cbb42d047764feac6c411efddcadc31866e9a998dd6e2bc1eb428cec1c49fdcd";
            };
          };
        in
        drv;

      hpax =
        let
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "hpax";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "afc7cb142ebcc2d01ce7816190b98ce5dd49e799111b24249f3443d730f377ca";
            };
          };
        in
        drv;

      lib_secp256k1 =
        let
          version = "0.7.2";
          drv = buildMix {
            inherit version;
            name = "lib_secp256k1";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "lib_secp256k1";
              sha256 = "120ff74f586bfb22b95ac8039dbfd096a31ab1ffaab56d6b8d3474fd128ac43f";
            };

            beamDeps = [
              elixir_make
            ];
          };
        in
        drv.override (workarounds.elixirMake { } drv);

      memento =
        let
          version = "0.4.1";
          drv = buildMix {
            inherit version;
            name = "memento";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "memento";
              sha256 = "e5723b2af790da7d3179af17a2ab65768c11c4b1f4e2c232e994f51d8f99ca16";
            };
          };
        in
        drv;

      mime =
        let
          version = "2.0.7";
          drv = buildMix {
            inherit version;
            name = "mime";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "mime";
              sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
            };
          };
        in
        drv;

      mint =
        let
          version = "1.9.3";
          drv = buildMix {
            inherit version;
            name = "mint";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "5f7c9342480c069dbbc4eeac3490303c9e01870ff01a7f1d29b6107054fc1e74";
            };

            beamDeps = [
              hpax
            ];
          };
        in
        drv;

      nostr_core =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "nostr_core";
            appConfigPath = ./config;

            src = fetchFromGitHub {
              owner = "jurraca";
              repo = "nostr_core";
              rev = "8fc8ff547f040d131299cc881a46d210a1a167c4";
              hash = "sha256-Z7W5PDYgJBIVfmuhRpRU5gp8IdK/Yty7yui1LJ73wkk=";
            };

            beamDeps = [
              lib_secp256k1
              bechamel
            ];
          };
        in
        drv;

      plug =
        let
          version = "1.20.3";
          drv = buildMix {
            inherit version;
            name = "plug";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "be266aee1b8536ef6409d58cf39a3121319f0ec47cfa1b24024485aa0e76ad76";
            };

            beamDeps = [
              mime
              plug_crypto
              telemetry
            ];
          };
        in
        drv;

      plug_crypto =
        let
          version = "2.2.0";
          drv = buildMix {
            inherit version;
            name = "plug_crypto";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "plug_crypto";
              sha256 = "83a95744ab1c75876542b6fab135fcc176280e0f301a111c1f757fddcec95d2c";
            };
          };
        in
        drv;

      postgrex =
        let
          version = "0.22.4";
          drv = buildMix {
            inherit version;
            name = "postgrex";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "4aae45a2d60e35b04eea2602440be152fae332901f1fc7a60fc7cb7f0f9a9c5a";
            };

            beamDeps = [
              db_connection
              decimal
            ];
          };
        in
        drv;

      telemetry =
        let
          version = "1.4.2";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "928f6495066506077862c0d1646609eed891a4326bee3126ba54b60af61febb1";
            };
          };
        in
        drv;

      thousand_island =
        let
          version = "1.5.0";
          drv = buildMix {
            inherit version;
            name = "thousand_island";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "708923d40523e43cf99041ab37a0d4b0ec426ac6438fa3716ab23d919eaeb412";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      websock =
        let
          version = "0.5.3";
          drv = buildMix {
            inherit version;
            name = "websock";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "websock";
              sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
            };
          };
        in
        drv;

      websock_adapter =
        let
          version = "0.5.7";
          drv = buildMix {
            inherit version;
            name = "websock_adapter";
            appConfigPath = ./config;

            src = fetchHex {
              inherit version;
              pkg = "websock_adapter";
              sha256 = "d0f478ee64deddfec64b800673fd6e0c8888b079d9f3444dd96d2a98383bdbd1";
            };

            beamDeps = [
              bandit
              plug
              websock
            ];
          };
        in
        drv;

    };
in
self
