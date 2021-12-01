import ./make-test-python.nix ({ pkgs, ... }:

let
  dbContents = ''
    dn: dc=example
    objectClass: domain
    dc: example

    dn: ou=users,dc=example
    objectClass: organizationalUnit
    ou: users
  '';
  manualConfig = pkgs.writeText "config.ldif" ''
    dn: cn=config
    cn: config
    objectClass: olcGlobal
    olcLogLevel: stats
    olcPidFile: /run/openldap/slapd.pid

    dn: cn=schema,cn=config
    cn: schema
    objectClass: olcSchemaConfig

    include: file://${pkgs.openldap}/etc/schema/core.ldif
    include: file://${pkgs.openldap}/etc/schema/cosine.ldif
    include: file://${pkgs.openldap}/etc/schema/inetorgperson.ldif

    dn: olcDatabase={0}config,cn=config
    olcDatabase: {0}config
    objectClass: olcDatabaseConfig
    olcRootDN: cn=root,cn=config
    olcRootPW: configpassword

    dn: olcDatabase={1}mdb,cn=config
    objectClass: olcDatabaseConfig
    objectClass: olcMdbConfig
    olcDatabase: {1}mdb
    olcDbDirectory: /var/db/openldap
    olcDbIndex: objectClass eq
    olcSuffix: dc=example
    olcRootDN: cn=root,dc=example
    olcRootPW: notapassword
  '';
in {
  name = "openldap";

  machine = { pkgs, ... }: {
    environment.etc."openldap/root_password".text = "notapassword";
    services.openldap = {
      enable = true;
      urlList = [ "ldap:///" ];
      settings = {
        children = {
          "cn=schema".includes = [
            "${pkgs.openldap}/etc/schema/core.ldif"
            "${pkgs.openldap}/etc/schema/cosine.ldif"
            "${pkgs.openldap}/etc/schema/inetorgperson.ldif"
            "${pkgs.openldap}/etc/schema/nis.ldif"
          ];
          "olcDatabase={0}config" = {
            attrs = {
              objectClass = "olcDatabaseConfig";
              olcDatabase = "{0}config";
              olcRootDN = "cn=root,cn=config";
              olcRootPW = "configpassword";
            };
          };
          "olcDatabase={1}mdb" = {
            # This tests string, base64 and path values, as well as lists of string values
            attrs = {
              objectClass = [ "olcDatabaseConfig" "olcMdbConfig" ];
              olcDatabase = "{1}mdb";
              olcDbDirectory = "/var/lib/openldap/current";
              olcSuffix = "dc=example";
              olcRootDN = {
                # cn=root,dc=example
                base64 = "Y249cm9vdCxkYz1leGFtcGxl";
              };
              olcRootPW = {
                path = "/etc/openldap/root_password";
              };
            };
          };
        };
      };
      declarativeContents."dc=example" = dbContents;
    };
    specialisation = {
      mutableConfig.configuration = { ... }: {
        services.openldap.mutableConfig = true;
      };
      manualConfigDir.configuration = { ... }: {
        services.openldap.configDir = "/var/db/slapd.d";
      };
      localSocket.configuration = { ... }: {
        services.openldap.urlList = [ "ldapi:///" ];
      };
    };
  };

  testScript = { nodes, ... }: let
    config = nodes.machine.config.system.build.toplevel;
    changeRootPW = pkgs.writeText "changeRootPW.ldif" ''
      dn: olcDatabase={1}mdb,cn=config
      changetype: modify
      replace: olcRootPW
      olcRootPW: foobar
    '';
  in ''
    machine.wait_for_unit("openldap.service")
    machine.succeed('ldapsearch -LLL -D "cn=root,dc=example" -w notapassword -b "dc=example"')
    machine.fail("ldapmodify -D cn=root,cn=config -w configpassword -f ${changeRootPW}")

    with subtest("handles mutable config"):
      machine.succeed("${config}/specialisation/mutableConfig/bin/switch-to-configuration test")
      machine.succeed('ldapsearch -LLL -D "cn=root,dc=example" -w notapassword -b "dc=example"')
      machine.succeed("ldapmodify -D cn=root,cn=config -w configpassword -f ${changeRootPW}")
      machine.systemctl('restart openldap')
      machine.succeed('ldapsearch -LLL -D "cn=root,dc=example" -w foobar -b "dc=example"')

    #with subtest("local IPC socket works"):
    #  machine.succeed("${config}/specialisation/localSocket/bin/switch-to-configuration test")

    with subtest("handles manual config dir"):
      machine.succeed(
          "mkdir -p /var/db/slapd.d /var/db/openldap",
          "slapadd -F /var/db/slapd.d -n0 -l ${manualConfig}",
          "slapadd -F /var/db/slapd.d -n1 -l ${pkgs.writeText "data.ldif" dbContents}",
          "chown -R openldap:openldap /var/db/slapd.d /var/db/openldap",
          "${config}/specialisation/manualConfigDir/bin/switch-to-configuration test",
      )
      machine.succeed('ldapsearch -LLL -D "cn=root,dc=example" -w notapassword -b "dc=example"')
      machine.succeed("ldapmodify -D cn=root,cn=config -w configpassword -f ${changeRootPW}")
      machine.succeed('ldapsearch -LLL -D "cn=root,dc=example" -w foobar -b "dc=example"')
  '';
})
