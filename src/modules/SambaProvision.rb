require "yast"

module Yast

  class SambaProvisionClass < Module

    def main
      Yast.import "UI"

      textdomain "samba-provision"

      Yast.import "Message"
      Yast.import "Progress"
      Yast.import "SambaConfig"
      Yast.import "Kerberos"
      Yast.import "DNS"
      Yast.import "SambaToolDomainAPI"

      @operation = ""
      @parent_domain_name = ""

      @dns = true
      @rodc = false
      @rfc2307 = true

      @forest_level = "2008_R2"
      @dns_backend = "NONE"

      @admin_password = ""

      @credentials_username = ""
      @credentials_password = ""

    end

    def Write

      caption = _("Provisioning Samba Active Directory Domain controller...")

      no_stages = 3
      stages = [
        _("Write the settings"),
        _("Provision"),
        _("Write kerberos settings")
      ]
      steps = [
        _("Writting the settings..."),
        _("Provisioning..."),
        _("Writting kerberos settings...")
      ]

      if @dns
        no_stages = Ops.add(no_stages, 2)
        stages = Builtins.add(stages, _("Write DNS settings"))
        stages = Builtins.add(stages, _("Update network configuration"))

        steps = Builtins.add(steps, _("Writting DNS settings..."))
        steps = Builtins.add(steps, _("Updating network configuration..."))
      end

      Progress.New(caption, " ", no_stages, stages, steps, "")

      # Write settings
      Progress.NextStage

      if !set_role_dc
        Report.Error(Message.CannotWriteSettingsTo("/etc/samba/smb.conf"))
        return false
      end

      progress_orig = Progress.set(false)
      ret = SambaConfig.Write(true)
      Progress.set(progress_orig)

      if !ret
        Report.Error(Message.CannotWriteSettingsTo("/etc/samba/smb.conf"))
        return false
      end

      # Provision
      Progress.NextStage

      case @operation
      when "new_forest"
        if !write_provision
          Report.Error(_("Error provisioning database. Check logs for details."))
          return false
        end
      when "new_dc"
        if !write_join
          Report.Error(_("Error joining to domain. Check logs for details."))
        end
      end

      # Write krb
      Progress.NextStage
      if !write_kerberos
        Report.Error(Message.CannotWriteSettingsTo("/etc/krb5.conf"))
        return false
      end

      # Write DNS
      if @dns
        Progress.NextStage
        if !write_dns
          Report.Error(Message.CannotWriteSettingsTo("/etc/sysconfig/network/config"))
          return false
        end

        Progress.NextStage
        SCR.Execute(path(".target.bash"), "/sbin/netconfig update")
      end

      # Final stage
      Progress.Finish

      true

    end

    def set_role_dc

      lcrealm = SambaConfig.GlobalGetStr("realm", "").downcase

      # Set netlogon share
      netlogon = {
        "path" => "/var/locks/sysvol/#{lcrealm}/scripts",
        "read only" => "No"
      }
      SambaConfig.ShareSetMap("netlogon", netlogon)

      # Set sysvol share
      sysvol = {
        "path" => "/var/locks/sysvol",
        "read only" => "No"
      }
      SambaConfig.ShareSetMap("sysvol", sysvol)

      # Set settings
      SambaConfig.GlobalSetStr("security", "AUTO")
      SambaConfig.GlobalSetStr("passdb backend", "samba_dsdb")
      SambaConfig.GlobalSetStr("map to guest", "Never")
      SambaConfig.GlobalSetStr("idmap backend", nil)

      # Check for non-existent included files and create them empty
      incfile = SambaConfig.GlobalGetStr("include", "")
      if incfile.size > 0 and !FileUtils::Exists(incfile)
        SCR.Write(path(".target.string"), incfile, "");
      end

      true

    end

    def write_provision

      domain = SambaConfig.GlobalGetStr("workgroup", "")
      realm = SambaConfig.GlobalGetStr("realm", "")

      output = SambaToolDomainAPI.provision(realm,
                                            domain,
                                            admin_password,
                                            forest_level,
                                            dns_backend,
                                            rfc2307)
      Builtins.y2milestone("Samba provision result: #{output}")

      output == ""

    end

    def write_join

      domain = SambaConfig.GlobalGetStr("realm", "").downcase
      role = @rodc ? "RODC" : "DC"
      output = SambaToolDomainAPI.join(domain,
                                       role,
                                       dns_backend,
                                       credentials_username,
                                       credentials_password)
      Builtins.y2milestone("Samba domain join result: #{output}")

      output == ""

    end

    def write_kerberos

      realm = SambaConfig.GlobalGetStr("realm", "")

      new_cfg = {
        "pam_login" => {
          "use_kerberos" => false
        },
        "kerberos_client" => {
          "default_realm" => realm.upcase,
          "default_domain" => realm.downcase,
          "kdc_server" => "",
          "trusted_servers" => ""
        }
      }
      Kerberos.Read()
      Kerberos.Import(new_cfg)
      Kerberos.dns_used = true
      Kerberos.modified = true

      # Do not show progress
      progress_orig = Progress.set(false)
      Kerberos.Write()
      Progress.set(progress_orig)

      true

    end

    def write_dns

      resolvlist = Builtins.splitstring(
        Convert.to_string(
          SCR.Read(
            path(".sysconfig.network.config.NETCONFIG_DNS_STATIC_SERVERS")
          )
        ),
        " "
      )

      if resolvlist.index("127.0.0.1") == nil
        resolvlist = Builtins.prepend(resolvlist, "127.0.0.1")
      end

      SCR.Write(
        path(".sysconfig.network.config.NETCONFIG_DNS_STATIC_SERVERS"),
        Builtins.mergestring(resolvlist, " ")
      )

      SCR.Write(path(".sysconfig.network.config"), nil)

      true

    end

    publish variable: :operation, type: "string"
    publish variable: :parent_domain_name, type: "string"
    publish variable: :admin_password, type: "string"
    publish variable: :credentials_username, type: "string"
    publish variable: :credentials_password, type: "string"
    publish variable: :dns, type: "boolean"
    publish variable: :rodc, type: "boolean"
    publish variable: :rfc2307, type: "boolean"
    publish variable: :forest_level, type: "string"
    publish variable: :dns_backend, type: "string"

  end

  SambaProvision = SambaProvisionClass.new
  SambaProvision.main

end
