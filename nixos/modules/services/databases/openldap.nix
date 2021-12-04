{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.openldap;
  openldap = cfg.package;
  escapeSystemd = s: replaceStrings ["%"] ["%%"] s;
  configDir = if cfg.configDir != null then cfg.configDir else "/var/lib/openldap/slapd.d";

  dbSettings = filterAttrs (name: value: hasPrefix "olcDatabase=" name) cfg.settings.children;
  dataDirs = mapAttrs' (_: value: nameValuePair value.attrs.olcSuffix (removePrefix "/var/lib/openldap/" value.attrs.olcDbDirectory))
    (lib.filterAttrs (_: value: value.attrs ? olcDbDirectory && hasPrefix "/var/lib/openldap/" value.attrs.olcDbDirectory) dbSettings);
  additionalStateDirectories = map (sfx: "openldap/" + sfx) (attrValues dataDirs);

  dataFiles = lib.mapAttrs (dn: contents: pkgs.writeText "${dn}.ldif" contents) cfg.declarativeContents;
  declarativeDNs = attrNames cfg.declarativeContents;

  ldapValueType = let
    # Can't do types.either with multiple non-overlapping submodules, so define our own
    singleLdapValueType = lib.mkOptionType rec {
      name = "LDAP";
      # TODO: It might be worth defining a { secret = ...; } option, leveraging
      # systemd's LoadCredentials for secrets. That should remove the last
      # barrier to using DynamicUser for openldap. However, this is blocked on
      # $CREDENTIALS_DIRECTORY being available in ExecStartPre.
      description = ''
        LDAP value - either a string, or an attrset containing `path` or
        `base64`, for included values or base-64 encoded values respectively.
      '';
      check = x: lib.isString x || (lib.isAttrs x && (x ? path || x ? base64));
      merge = lib.mergeEqualOption;
    };
    # We don't coerce to lists of single values, as some values must be unique
  in types.either singleLdapValueType (types.listOf singleLdapValueType);

  ldapAttrsType =
    let
      options = {
        attrs = mkOption {
          type = types.attrsOf ldapValueType;
          default = {};
          description = "Attributes of the parent entry.";
        };
        children = mkOption {
          # Hide the child attributes, to avoid infinite recursion in e.g. documentation
          # Actual Nix evaluation is lazy, so this is not an issue there
          type = let
            hiddenOptions = lib.mapAttrs (name: attr: attr // { visible = false; }) options;
          in types.attrsOf (types.submodule { options = hiddenOptions; });
          default = {};
          description = "Child entries of the current entry, with recursively the same structure.";
          example = lib.literalExpression ''
            {
                "cn=schema" = {
                # The attribute used in the DN must be defined
                attrs = { cn = "schema"; };
                children = {
                    # This entry's DN is expanded to "cn=foo,cn=schema"
                    "cn=foo" = { ... };
                };
                # These includes are inserted after "cn=schema", but before "cn=foo,cn=schema"
                includes = [ ... ];
                };
            }
          '';
        };
        includes = mkOption {
          type = types.listOf types.path;
          default = [];
          description = ''
            LDIF files to include after the parent's attributes but before its children.
          '';
        };
      };
    in types.submodule { inherit options; };

  valueToLdif = attr: values: let
    listValues = if lib.isList values then values else lib.singleton values;
  in map (value:
    if lib.isAttrs value then
      if lib.hasAttr "path" value
      then "${attr}:< file://${value.path}"
      else "${attr}:: ${value.base64}"
    else "${attr}: ${lib.replaceStrings [ "\n" ] [ "\n " ] value}"
  ) listValues;

  attrsToLdif = dn: { attrs, children, includes, ... }: [''
    dn: ${dn}
    ${lib.concatStringsSep "\n" (lib.flatten (lib.mapAttrsToList valueToLdif attrs))}
  ''] ++ (map (path: "include: file://${path}\n") includes) ++ (
    lib.flatten (lib.mapAttrsToList (name: value: attrsToLdif "${name},${dn}" value) children)
  );
in {
  options = {
    services.openldap = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "
          Whether to enable the ldap server.
        ";
      };

      package = mkOption {
        type = types.package;
        default = pkgs.openldap;
        defaultText = literalExpression "pkgs.openldap";
        description = ''
          OpenLDAP package to use.

          This can be used to, for example, set an OpenLDAP package
          with custom overrides to enable modules or other
          functionality.
        '';
      };

      user = mkOption {
        type = types.str;
        default = "openldap";
        description = "User account under which slapd runs.";
      };

      group = mkOption {
        type = types.str;
        default = "openldap";
        description = "Group account under which slapd runs.";
      };

      urlList = mkOption {
        type = types.listOf types.str;
        default = [ "ldap:///" ];
        description = "URL list slapd should listen on.";
        example = [ "ldaps:///" ];
      };

      settings = mkOption {
        type = ldapAttrsType;
        description = "Configuration for OpenLDAP, in OLC format";
        example = lib.literalExpression ''
          {
            attrs.olcLogLevel = [ "stats" ];
            children = {
              "cn=schema".includes = [
                 "''${pkgs.openldap}/etc/schema/core.ldif"
                 "''${pkgs.openldap}/etc/schema/cosine.ldif"
                 "''${pkgs.openldap}/etc/schema/inetorgperson.ldif"
              ];
              "olcDatabase={-1}frontend" = {
                attrs = {
                  objectClass = "olcDatabaseConfig";
                  olcDatabase = "{-1}frontend";
                  olcAccess = [ "{0}to * by dn.exact=uidNumber=0+gidNumber=0,cn=peercred,cn=external,cn=auth manage stop by * none stop" ];
                };
              };
              "olcDatabase={0}config" = {
                attrs = {
                  objectClass = "olcDatabaseConfig";
                  olcDatabase = "{0}config";
                  olcAccess = [ "{0}to * by * none break" ];
                };
              };
              "olcDatabase={1}mdb" = {
                attrs = {
                  objectClass = [ "olcDatabaseConfig" "olcMdbConfig" ];
                  olcDatabase = "{1}mdb";
                  olcDbDirectory = "/var/lib/openldap/db1";
                  olcDbIndex = [
                    "objectClass eq"
                    "cn pres,eq"
                    "uid pres,eq"
                    "sn pres,eq,subany"
                  ];
                  olcSuffix = "dc=example,dc=com";
                  olcAccess = [ "{0}to * by * read break" ];
                };
              };
            };
          };
        '';
      };

      # This option overrides settings
      configDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Use this config directory instead of generating one from the
          <literal>settings</literal> option. Overrides all NixOS settings.
        '';
        example = "/var/lib/openldap/slapd.d";
      };

      mutableConfig = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to allow writable on-line configuration. If `true`, the NixOS
          settings will only be used to initialize the OpenLDAP configuration
          if it does not exist, and are subsequently ignored.
        '';
      };

      declarativeContents = mkOption {
        type = with types; attrsOf lines;
        default = {};
        description = ''
          Declarative contents for the LDAP database, in LDIF format by suffix.

          All data will be erased when starting the LDAP server. Modifications
          to the database are not prevented, they are just dropped on the next
          reboot of the server. Performance-wise the database and indexes are
          rebuilt on each server startup, so this will slow down server startup,
          especially with large databases.

          Note that the DIT root of the declarative DB must be defined in
          <code>services.openldap.settings</code> AND the <code>olcDbDirectory</code>
          must be prefixed by "/var/lib/openldap/"
        '';
        example = lib.literalExpression ''
          {
            "dc=example,dc=org" = '''
              dn= dn: dc=example,dc=org
              objectClass: domain
              dc: example

              dn: ou=users,dc=example,dc=org
              objectClass = organizationalUnit
              ou: users

              # ...
            ''';
          }
        '';
      };
    };
  };

  meta.maintainers = with lib.maintainers; [ mic92 kwohlfahrt ];

  config = mkIf cfg.enable {
    assertions = [{
      assertion = (cfg.configDir != null) -> declarativeDNs == [];
      message = ''
        Declarative DB contents (${dn}) are not supported with user-managed configuration directory".
      '';
    }] ++ (map (dn: {
      assertion = dataDirs ? "${dn}";
      message = ''
        Declarative DB ${dn} does not exist in "services.openldap.settings" or it exists but the "olcDbDirectory"
        is not prefixed by "/var/lib/openldap/"
      '';
    }) declarativeDNs) ++ (map (dir: {
      assertion = !(hasPrefix "slapd.d" dir);
      message = ''
        Database path may not be "/var/lib/openldap/slapd.d", this path is used for configuration.
      '';
    }) (attrValues dataDirs));
    environment.systemPackages = [ openldap ];

    # Literal attributes must always be set
    services.openldap.settings = {
      attrs = {
        objectClass = "olcGlobal";
        cn = "config";
        olcPidFile = "/run/openldap/slapd.pid";
      };
      children."cn=schema".attrs = {
        cn = "schema";
        objectClass = "olcSchemaConfig";
      };
    };

    systemd.services.openldap = {
      description = "LDAP server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = let
        # This cannot be built in a derivation, because it needs filesystem access for included files
        writeConfig = let
          settingsFile = pkgs.writeText "config.ldif" (lib.concatStringsSep "\n" (attrsToLdif "cn=config" cfg.settings));
        in pkgs.writeShellScript "openldap-config" ''
          set -euo pipefail

          ${lib.optionalString (!cfg.mutableConfig) "rm -rf ${configDir}/*"}
          if [ -z "$(ls -A ${configDir})" ]; then
            ${openldap}/bin/slapadd -F ${configDir} -bcn=config -l ${settingsFile}
          fi
          chmod -R ${if cfg.mutableConfig then "u+rw" else "u+r-w"} ${configDir}
        '';
        writeContents =  pkgs.writeShellScript "openldap-load" ''
          set -euo pipefail

          rm -rf /var/lib/openldap/$2/*
          ${openldap}/bin/slapadd -F ${configDir} -b $1 -l $3
        '';
      in {
        User = cfg.user;
        Group = cfg.group;
        Type = "forking";
        ExecStartPre =
          (lib.optional (cfg.configDir == null) writeConfig)
          ++ (map (dn: lib.escapeShellArgs [writeContents dn (getAttr dn dataDirs) (getAttr dn dataFiles)]) declarativeDNs)
          ++ [ "${openldap}/bin/slaptest -u -F ${configDir}" ];
        ExecStart = lib.escapeShellArgs [
          "${openldap}/libexec/slapd" "-F" configDir
          "-h" (escapeSystemd (lib.concatStringsSep " " cfg.urlList))
        ];
        StateDirectory = lib.optional (cfg.configDir == null) ([ "openldap/slapd.d" ] ++ additionalStateDirectories);
        StateDirectoryMode = "700";
        RuntimeDirectory = "openldap";
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        PIDFile = cfg.settings.attrs.olcPidFile;
      };
    };

    users.users = lib.optionalAttrs (cfg.user == "openldap") {
      openldap = {
        group = cfg.group;
        isSystemUser = true;
      };
    };

    users.groups = lib.optionalAttrs (cfg.group == "openldap") {
      openldap = {};
    };
  };
}
