{
  config,
  lib,
  pkgs,
  noxirFlake,
  ...
}: let
  inherit
    (lib)
    mkEnableOption
    mkIf
    mkOption
    ;
  inherit
    (lib.types)
    bool
    ints
    listOf
    nullOr
    package
    port
    str
    ;

  cfg = config.services.noxir;

  strEnv = lib.concatStringsSep ",";
in {
  options.services.noxir = {
    enable = mkEnableOption "Noxir Nostr relay";

    package = mkOption {
      type = package;
      default = noxirFlake.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description = "The noxir package to run.";
    };

    port = mkOption {
      type = port;
      default = 4000;
      description = "HTTP/WebSocket port to listen on.";
    };

    openFirewall = mkOption {
      type = bool;
      default = false;
      description = "Open the firewall for the configured port.";
    };

    relayName = mkOption {
      type = str;
      default = "Noxir";
      description = "NIP-11 relay name.";
    };

    relayDescription = mkOption {
      type = str;
      default = "The Nostr relay implemented in Elixir.";
      description = "NIP-11 relay description.";
    };

    ownerPubkey = mkOption {
      type = nullOr str;
      default = null;
      description = "NIP-11 owner pubkey.";
    };

    ownerContact = mkOption {
      type = nullOr str;
      default = null;
      description = "NIP-11 contact URI (e.g. mailto:).";
    };

    authRequired = mkOption {
      type = bool;
      default = false;
      description = "Require NIP-42 AUTH before EVENT/REQ.";
    };

    allowedPubkeys = mkOption {
      type = listOf str;
      default = [];
      description = "Pubkey allowlist. Empty = allow all.";
    };

    subscriptionIndexKeys = mkOption {
      type = listOf str;
      default = ["authors" "#h"];
      description = ''
        Index keys that route live events to subscribers (any-of).
        Any "#x" tag key works — e.g. ["authors" "#h" "#e" "#p"] to also
        accept thread (#e) and mention (#p) REQs.
      '';
    };

    indexKeysRequired = mkOption {
      type = nullOr (listOf str);
      default = null;
      description = ''
        Index keys that REQ filters must include (any-of).
        Null (default) derives the requirement from
        <option>services.noxir.subscriptionIndexKeys</option>;
        empty list disables the requirement — unindexed REQs then get
        historical results without live events.
      '';
    };

    maxConnections = mkOption {
      type = ints.positive;
      default = 10000;
      description = "Maximum concurrent WebSocket connections.";
    };

    maxSubscriptionsPerConnection = mkOption {
      type = ints.positive;
      default = 100;
      description = "Maximum subscriptions per connection.";
    };

    maxEventsPerMinute = mkOption {
      type = ints.positive;
      default = 1000;
      description = "EVENT rate limit per connection.";
    };

    environment = mkOption {
      type = lib.types.attrsOf str;
      default = {};
      description = "Extra environment variables for the service.";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts =
      mkIf cfg.openFirewall [cfg.port];

    systemd.services.noxir = {
      description = "Noxir Nostr relay";

      after = ["network.target"];
      wantedBy = ["multi-user.target"];

      environment =
        (lib.filterAttrs (_: v: v != null) {
          LANG = "C.utf8";
          MIX_ENV = "prod";
          # mixRelease strips releases/COOKIE; single-node so any value works
          RELEASE_COOKIE = "noxir";
          PORT = toString cfg.port;
          RELAY_NAME = cfg.relayName;
          RELAY_DESC = cfg.relayDescription;
          OWNER_PUBKEY = cfg.ownerPubkey;
          OWNER_CONTACT = cfg.ownerContact;
          AUTH_REQUIRED =
            if cfg.authRequired
            then "true"
            else "false";
          ALLOWED_PUBKEYS =
            if cfg.allowedPubkeys == []
            then null
            else strEnv cfg.allowedPubkeys;
          SUBSCRIPTION_INDEX_KEYS = strEnv cfg.subscriptionIndexKeys;
          INDEX_KEYS_REQUIRED =
            if cfg.indexKeysRequired == null
            then null
            else strEnv cfg.indexKeysRequired;
          MAX_CONNECTIONS = toString cfg.maxConnections;
          MAX_SUBSCRIPTIONS_PER_CONNECTION = toString cfg.maxSubscriptionsPerConnection;
          MAX_EVENTS_PER_MINUTE = toString cfg.maxEventsPerMinute;
        })
        // cfg.environment;

      serviceConfig = {
        Type = "exec";
        ExecStart = "${cfg.package}/bin/noxir start";
        Restart = "on-failure";

        DynamicUser = true;
        StateDirectory = "noxir";
        WorkingDirectory = "/var/lib/noxir";
        Environment = ["HOME=/var/lib/noxir"];

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = ["/var/lib/noxir"];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = ["native"];
        CapabilityBoundingSet = [""];
        SystemCallFilter = ["@system-service"];
      };
    };
  };
}
