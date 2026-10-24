# -----------------------------------------------------------------------------
# Einrichtung der VMs beim ersten Boot
#
# Kein Image-Bau (ADR 0010 im deployment-Repo): cloud-init installiert alles
# beim ersten Start. Jede VM bekommt ihre eigene Konfiguration mit genau
# einem Konto.
#
# Die Konfiguration wird mit yamlencode gebaut statt als Template. yamlencode
# quotet jeden Wert selbst: ein Passwort mit fuehrendem ! @ % oder * bleibt
# gueltiges YAML. Skripte und Lernmaterial gehen gzip+base64 hinein - so
# bleibt user_data weit unter dem Nova-Limit von 64 KB.
# -----------------------------------------------------------------------------

locals {
  base_packages = [
    "ca-certificates",
    "curl",
    "git",
    "htop",
    "nano",
    "tmux",
    "tree",
    "vim",
    "wget",
  ]

  # Der Hypervisor. Paketnamen von Ubuntu 24.04; qemu-kvm ist dort nur noch
  # ein Uebergangspaket, deshalb qemu-system-x86 direkt.
  virt_packages = [
    "cloud-image-utils", # cloud-localds: Startkonfiguration fuer Cloud-Images als Gast
    "cpu-checker",       # kvm-ok
    "dnsmasq-base",      # DHCP und DNS im libvirt-Netz "default"
    "libvirt-clients",   # virsh
    "libvirt-daemon-system",
    "qemu-system-x86",
    "qemu-utils", # qemu-img
    "virtinst",   # virt-install
  ]

  # Lernmaterial nach /etc/skel. write_files laeuft vor dem Anlegen der
  # Benutzer, das Verzeichnis ist also schon da, wenn der Home-Ordner
  # entsteht.
  kurs_files = [
    for f in sort(fileset("${path.module}/files/virt-kurs", "**")) : {
      path        = "/etc/skel/virt-kurs/${f}"
      encoding    = "gz+b64"
      content     = base64gzip(file("${path.module}/files/virt-kurs/${f}"))
      permissions = "0644"
    }
  ]

  nested_files = concat(
    [
      {
        path        = "/usr/local/sbin/nested-vm-setup"
        encoding    = "gz+b64"
        content     = base64gzip(file("${path.module}/files/nested-vm-setup.sh"))
        permissions = "0755"
      },
      {
        path        = "/usr/local/bin/nested-vm-test"
        encoding    = "gz+b64"
        content     = base64gzip(file("${path.module}/files/nested-vm-test.sh"))
        permissions = "0755"
      },
      {
        path        = "/etc/profile.d/nested-vm.sh"
        encoding    = "gz+b64"
        content     = base64gzip(file("${path.module}/files/profile.sh"))
        permissions = "0644"
      },
    ],
    local.kurs_files,
  )

  cloud_init_config = {
    for id, user in local.users_map : id => {
      ssh_pwauth     = true
      package_update = true
      packages       = concat(local.base_packages, var.nested_virtualization ? local.virt_packages : [])

      # Die Gruppen libvirt und kvm kommen erst mit den Paketen. Stuenden sie
      # hier, legte cloud-init sie vorher als normale Gruppen an, und das
      # Paket faende eine gleichnamige Gruppe vor, die keine Systemgruppe
      # ist. nested-vm-setup traegt die Person nachtraeglich ein.
      users = [
        {
          name        = user.username
          shell       = "/bin/bash"
          sudo        = ["ALL=(ALL) ALL"]
          lock_passwd = false
        },
      ]

      chpasswd = {
        expire = false
        users = [
          {
            name     = user.username
            password = random_password.user_passwords[id].result
            type     = "text"
          },
        ]
      }

      write_files = concat(
        [
          {
            # Vorne einsortiert, damit es vor 60-cloudimg-settings.conf des
            # Ubuntu-Images gilt: sshd nimmt den ersten Wert.
            path        = "/etc/ssh/sshd_config.d/01-click-n-deploy.conf"
            permissions = "0644"
            content     = <<-EOT
              PasswordAuthentication yes
              PubkeyAuthentication yes
              PermitRootLogin no
              UsePAM yes
            EOT
          },
          {
            # Wer libvirt-Rechte bekommt; liest nested-vm-setup.
            path        = "/etc/nested-vm/users"
            permissions = "0644"
            content     = "${user.username}\n"
          },
        ],
        var.nested_virtualization ? local.nested_files : [],
        # ip_mode = dual: die IPv4-Schnittstelle, die OpenTofu nach dem Boot
        # anhaengt. Ihre Default-Route ueber das Gateway des IPv4-Netzes steht
        # in einer eigenen Tabelle, und nur Pakete mit ihrer Adresse als
        # Absender nehmen diese Tabelle. Ohne das gingen Antworten ueber die
        # Default-Route der Hauptschnittstelle hinaus, und Neutrons
        # Port-Security verwirft sie als gefaelschten Absender. Gleiches Muster
        # wie in der Ubuntu-App und im Staging-Aufbau des deployment-Repos.
        local.dual ? [
          {
            path        = "/etc/netplan/60-secondary-ipv4.yaml"
            permissions = "0600"
            content = yamlencode({
              network = {
                version = 2
                ethernets = {
                  secondary = {
                    match           = { macaddress = local.secondary_mac[id] }
                    dhcp4           = true
                    dhcp6           = false
                    accept-ra       = false
                    dhcp4-overrides = { use-routes = false }
                    routes          = [{ to = "default", via = local.secondary_gateway, table = 100 }]
                    routing-policy  = [{ from = local.secondary_ipv4[id], table = 100 }]
                  }
                }
              }
            })
          },
        ] : [],
      )

      # Keine ufw wie in der Ubuntu-App: sie saesse im Forward-Pfad der
      # libvirt-Netze und kappte den NAT der verschachtelten VMs. Von aussen
      # schuetzt die Security Group, sie laesst nur SSH durch.
      runcmd = concat(
        [
          # cloud-init fuehrt runcmd als ein sh-Skript aus, und dessen
          # Ergebnis ist das des letzten Befehls. Ohne set -e ueberdeckte der
          # Log-Eintrag am Ende einen gescheiterten Selbsttest.
          "set -e",
          "systemctl restart ssh",
        ],
        local.dual ? [
          # Die IPv4-Schnittstelle kommt erst nach dem Boot dazu
          # (interface_attach). Bis zu fuenf Minuten auf ihre MAC warten,
          # dann die netplan-Datei oben anwenden. Kommt sie nicht, bleibt die
          # VM ueber IPv6 erreichbar.
          ["sh", "-c", "for i in $(seq 1 60); do if ip -o link | grep -qi \"$1\"; then netplan apply; break; fi; sleep 5; done", "sh", local.secondary_mac[id]],
        ] : [],
        var.nested_virtualization ? [
          # Hypervisor einschalten und Selbsttest. Scheitert er, scheitert
          # cloud-final - und damit das Deployment (ADR 0011), statt eine VM
          # auszuliefern, in der keine VM startet. tee schreibt den Verlauf
          # zusaetzlich auf die Konsole, die der App Store mitliest.
          ["bash", "-c", "set -o pipefail; /usr/local/sbin/nested-vm-setup 2>&1 | tee -a /var/log/nested-vm-setup.log"],
        ] : [],
        [
          # Setup-Log (OHNE Passwoerter).
          ["sh", "-c", "printf 'Setup abgeschlossen: %s\\nBenutzer: %s\\nVerschachtelte Virtualisierung: %s\\n' \"$(date)\" \"$1\" \"$2\" >> /var/log/setup-complete.log", "sh", user.username, tostring(var.nested_virtualization)],
        ],
      )

      final_message = <<-EOT
        ================================================
        Nested-VM-App bereit
        ================================================
        Benutzer: ${user.username}
        Verschachtelte Virtualisierung: ${var.nested_virtualization ? "an" : "aus"}
        ================================================
      EOT
    }
  }

  cloud_init = {
    for id, config in local.cloud_init_config : id => "#cloud-config\n${yamlencode(config)}"
  }
}
