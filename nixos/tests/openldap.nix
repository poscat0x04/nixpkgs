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
  testDbExists = ''
    machine.wait_for_unit("openldap.service")
    machine.succeed(
        'ldapsearch -LLL -D "cn=root,dc=example" -w notapassword -b "dc=example"',
    )
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
      settings = {
        children = {
          "cn=schema".includes = [
          "${pkgs.openldap}/etc/schema/core.ldif"
          "${pkgs.openldap}/etc/schema/cosine.ldif"
          "${pkgs.openldap}/etc/schema/inetorgperson.ldif"
          "${pkgs.openldap}/etc/schema/nis.ldif"
        ];
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
    specialisation.manualConfigDir.configuration = { ... }: {
      services.openldap.configDir = "/var/db/slapd.d";
    };
  };

  testScript = { nodes, ... }: let config = nodes.machine.config.system.build.toplevel; in ''
    ${testDbExists}

    with subtest("handles manual config dir"):
      machine.succeed(
          "mkdir -p /var/db/slapd.d /var/db/openldap",
          "slapadd -F /var/db/slapd.d -n0 -l ${manualConfig}",
          "slapadd -F /var/db/slapd.d -n1 -l ${pkgs.writeText "data.ldif" dbContents}",
          "chown -R openldap:openldap /var/db/slapd.d /var/db/openldap",
          "${config}/specialisation/manualConfigDir/bin/switch-to-configuration test",
      )
      ${testDbExists}
  '';
})
