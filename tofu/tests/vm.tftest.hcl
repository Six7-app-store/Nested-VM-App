# Prüft, wie VMs, Einrichtung und Zugangsdaten aus den Variablen entstehen.
# Alle Provider sind gemockt: der Test braucht keinen OpenStack-Zugang und
# legt nichts an.
#
#   cd tofu && tofu init -backend=false && tofu test

mock_provider "openstack" {
  mock_data "openstack_images_image_v2" {
    defaults = {
      id = "00000000-0000-0000-0000-00000000image"
    }
  }
  mock_resource "openstack_compute_instance_v2" {
    defaults = {
      network = { fixed_ip_v6 = "2001:db8::42", fixed_ip_v4 = "10.200.0.42" }
    }
  }
  mock_resource "openstack_networking_port_v2" {
    defaults = {
      all_fixed_ips = ["141.72.10.7", "2001:db8:4::7"]
      mac_address   = "fa:16:3e:00:00:07"
    }
  }
}

mock_provider "random" {}

variables {
  users = {
    "Team #1" = [{ email = "Anna.Alt@dhbw.de" }]
    "2b"      = [{ email = "ben@dhbw.de" }, { email = "2fast.cem@dhbw.de" }]
  }
}

run "eine_vm_je_person" {
  command = apply

  assert {
    condition     = toset(keys(openstack_compute_instance_v2.user_vm)) == toset(["Team #1-Anna-Alt", "2b-ben", "2b-2fast-cem"])
    error_message = "Jede Person bekommt eine eigene VM, Schlüssel wie im Plattformvertrag (<team>-<lokalteil>)."
  }
  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : vm.flavor_name == "gp1.large"])
    error_message = "Ohne Auswahl muss gp1.large gelten."
  }
  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : length(vm.block_device) == 0])
    error_message = "disk_size_gb = 0 darf kein Volume anlegen."
  }
  assert {
    condition     = openstack_compute_instance_v2.user_vm["2b-ben"].name == "nested-vm-ben"
    error_message = "Der VM-Name muss den Benutzernamen tragen."
  }
}

run "benutzernamen_sind_gueltige_linux_namen" {
  command = apply

  assert {
    condition     = toset(output.teams_summary.usernames) == toset(["annaalt", "ben", "u2fastcem"])
    error_message = "Benutzernamen: klein, ohne Punkte, mit Buchstaben vorne (\"2fast.cem\" -> u2fastcem)."
  }
  assert {
    condition     = [for u in yamldecode(local.cloud_init["Team #1-Anna-Alt"]).users : u.name] == ["annaalt"]
    error_message = "Jede VM bekommt genau das Konto ihrer Person."
  }
  assert {
    condition     = length(yamldecode(local.cloud_init["2b-ben"]).chpasswd.users) == 1
    error_message = "Jede VM setzt genau ein Passwort."
  }
}

run "nested_installiert_den_hypervisor" {
  command = apply

  assert {
    condition     = startswith(local.cloud_init["2b-ben"], "#cloud-config\n")
    error_message = "user_data muss mit #cloud-config beginnen."
  }
  assert {
    condition     = length(setintersection(toset(yamldecode(local.cloud_init["2b-ben"]).packages), toset(["qemu-system-x86", "libvirt-daemon-system", "virtinst"]))) == 3
    error_message = "Mit nested_virtualization gehören QEMU, libvirt und virt-install auf die VM."
  }
  assert {
    condition     = length([for f in yamldecode(local.cloud_init["2b-ben"]).write_files : f if f.path == "/usr/local/sbin/nested-vm-setup"]) == 1
    error_message = "Das Einrichtungsskript muss auf die VM."
  }
  assert {
    condition     = length([for f in yamldecode(local.cloud_init["2b-ben"]).write_files : f if startswith(f.path, "/etc/skel/virt-kurs/")]) == 8
    error_message = "Alle acht Dateien des Lernverzeichnisses gehören nach /etc/skel."
  }
  assert {
    condition     = one([for f in yamldecode(local.cloud_init["2b-ben"]).write_files : f.content if f.path == "/etc/nested-vm/users"]) == "ben\n"
    error_message = "nested-vm-setup muss wissen, wer libvirt-Rechte bekommt."
  }
  assert {
    condition     = length([for c in yamldecode(local.cloud_init["2b-ben"]).runcmd : c if strcontains(jsonencode(c), "nested-vm-setup")]) == 1
    error_message = "runcmd muss den Hypervisor einrichten und den Selbsttest starten."
  }
  assert {
    condition     = yamldecode(local.cloud_init["2b-ben"]).runcmd[0] == "set -e"
    error_message = "runcmd muss beim ersten Fehler abbrechen, sonst überdeckt der Log-Eintrag einen gescheiterten Selbsttest."
  }
  assert {
    condition     = openstack_compute_instance_v2.user_vm["2b-ben"].metadata.nested_virtualization == "true"
    error_message = "Die Metadaten der VM müssen die Option nennen."
  }
}

run "ohne_nested_kein_hypervisor" {
  command = apply

  variables {
    nested_virtualization = false
  }

  assert {
    condition     = length(setintersection(toset(yamldecode(local.cloud_init["2b-ben"]).packages), toset(local.virt_packages))) == 0
    error_message = "Ohne die Option darf kein Hypervisor-Paket installiert werden."
  }
  assert {
    condition     = length([for f in yamldecode(local.cloud_init["2b-ben"]).write_files : f if strcontains(f.path, "nested-vm") && f.path != "/etc/nested-vm/users"]) == 0
    error_message = "Ohne die Option keine Hypervisor-Skripte."
  }
  assert {
    condition     = length([for c in yamldecode(local.cloud_init["2b-ben"]).runcmd : c if strcontains(jsonencode(c), "nested-vm-setup")]) == 0
    error_message = "Ohne die Option läuft kein Selbsttest."
  }
}

run "zugangsdaten_ueber_ipv6_ohne_klammern" {
  command = apply

  override_resource {
    target = openstack_compute_instance_v2.user_vm
    values = {
      network = { fixed_ip_v6 = "[2001:db8::42]", fixed_ip_v4 = "10.200.0.42" }
    }
  }

  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.ip == "2001:db8::42"])
    error_message = "ssh braucht die nackte IPv6, auch wenn der Provider sie eingeklammert liefert."
  }
  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.protocol == "ssh" && a.port == 22 && a.type == "password"])
    error_message = "Zugang per SSH mit Passwort (ADR 0007: protocol neben type)."
  }
  assert {
    condition     = output.team_vms["2b-ben"].ssh_command == "ssh ben@2001:db8::42"
    error_message = "team_vms muss das SSH-Kommando je Person nennen."
  }
  assert {
    condition     = output.team_vms["2b-ben"].fixed_ip_v4 == null
    error_message = "Die private NAT-IPv4 darf nicht als Adresse erscheinen."
  }
}

run "ipv6_ist_standard" {
  command = apply

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.ssh) == ["IPv6"]
    error_message = "Ohne Auswahl gilt ipv6: nur eine SSH-Regel für IPv6."
  }
  assert {
    condition     = length(openstack_networking_port_v2.v4) == 0 && length(openstack_compute_interface_attach_v2.v4) == 0
    error_message = "ipv6 braucht keine zweite Schnittstelle."
  }
}

run "zugang_ueber_ipv4" {
  command = apply

  variables {
    ip_mode         = "ipv4"
    network_v4_uuid = "00000000-0000-0000-0000-0000000000v4"
  }

  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : vm.network[0].uuid == "00000000-0000-0000-0000-0000000000v4"])
    error_message = "ipv4 muss die VMs ins IPv4-Netz hängen."
  }
  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.ssh) == ["IPv4"]
    error_message = "ipv4 braucht genau eine SSH-Regel für IPv4."
  }
  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.ip == "10.200.0.42"])
    error_message = "Die Zugangsdaten müssen die feste IPv4 der VM nennen."
  }
}

run "dual_haengt_je_vm_eine_ipv4_schnittstelle_an" {
  command = apply

  variables {
    ip_mode         = "dual"
    network_v4_uuid = "00000000-0000-0000-0000-0000000000v4"
  }

  assert {
    condition     = length(openstack_networking_port_v2.v4) == 3 && length(openstack_compute_interface_attach_v2.v4) == 3
    error_message = "dual braucht je VM einen IPv4-Port samt Anbindung."
  }
  assert {
    condition     = toset(keys(openstack_networking_secgroup_rule_v2.ssh)) == toset(["IPv4", "IPv6"])
    error_message = "dual braucht SSH-Regeln für beide Familien."
  }
  assert {
    condition     = alltrue([for a in values(output.user_accounts) : a.ip == "141.72.10.7"])
    error_message = "Bei dual nennen die Zugangsdaten die öffentliche IPv4 der zweiten Schnittstelle."
  }
  assert {
    condition     = output.team_vms["2b-ben"].fixed_ip_v6 == "2001:db8::42"
    error_message = "team_vms muss bei dual auch die IPv6 nennen."
  }
  assert {
    condition     = yamldecode(one([for f in yamldecode(local.cloud_init["2b-ben"]).write_files : f.content if f.path == "/etc/netplan/60-secondary-ipv4.yaml"])).network.ethernets.secondary.routing-policy[0].from == "141.72.10.7"
    error_message = "cloud-init muss die IPv4-Schnittstelle mit eigener Routing-Tabelle einrichten."
  }
}

run "groessere_platte_als_volume" {
  command = apply

  variables {
    flavor       = "win11.medium"
    disk_size_gb = 40
  }

  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : vm.flavor_name == "win11.medium" && length(vm.block_device) == 1])
    error_message = "Gewählter Flavor und Platte müssen an jeder VM ankommen."
  }
  assert {
    condition     = alltrue([for vm in openstack_compute_instance_v2.user_vm : vm.block_device[0].volume_size == 40 && vm.block_device[0].delete_on_termination])
    error_message = "Das Volume muss die gewählte Größe haben und mit der VM verschwinden."
  }
}

run "zu_viele_personen_werden_abgelehnt" {
  command = plan

  variables {
    max_users = 2
  }

  expect_failures = [terraform_data.user_limit]
}

run "doppelte_person_wird_abgelehnt" {
  command = plan

  variables {
    users = {
      "A" = [{ email = "anna@dhbw.de" }, { email = "anna@student.dhbw.de" }]
    }
  }

  expect_failures = [terraform_data.user_limit]
}

run "ipv4_ohne_netz_wird_abgelehnt" {
  command = plan

  variables {
    ip_mode = "ipv4"
  }

  expect_failures = [openstack_compute_instance_v2.user_vm]
}

run "zu_kleiner_flavor_wird_abgelehnt" {
  command = plan

  variables {
    flavor = "gp1.small"
  }

  expect_failures = [var.flavor]
}

run "unbekannter_ip_mode_wird_abgelehnt" {
  command = plan

  variables {
    ip_mode = "ipv5"
  }

  expect_failures = [var.ip_mode]
}

run "zu_kleine_platte_wird_abgelehnt" {
  command = plan

  variables {
    disk_size_gb = 5
  }

  expect_failures = [var.disk_size_gb]
}
