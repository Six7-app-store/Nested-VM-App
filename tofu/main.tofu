# OpenTofu erwartet weiterhin das Schluesselwort "terraform"; die Provider
# werden ueber registry.opentofu.org aufgeloest.
terraform {
  required_version = ">= 1.13.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "openstack" {
  cloud = "openstack"
  # Auth via OS_CLOUD + clouds.yaml (oder OS_* env vars)
}

############################
# APP-DEFAULTS (vom App-Entwickler vorgegeben)
############################

locals {
  app_name = "nested-vm"

  # Basis-Image auf newstack; eingerichtet wird beim ersten Boot per
  # cloud-init (cloud-init.tofu), ein eigenes Image wird nicht gebaut. Die
  # Paketnamen in cloud-init.tofu sind die von Ubuntu 24.04.
  image_name = "Ubuntu 24.04"

  # Systemplatte als Cinder-Volume nur, wenn eine Groesse gewaehlt ist.
  boot_from_volume = var.disk_size_gb > 0
}

# Keine Floating IP: sie liesse sich in diesem Projekt zwar anlegen, aber
# nicht zuweisen - zwischen VM-Subnetz und externem Netz fehlt der Router
# ("External network ... is not reachable from subnet"). Erreichbar sind die
# Instanzen ueber die feste Adresse der gewaehlten Familie (var.ip_mode).

############################
# ADRESSFAMILIEN (var.ip_mode)
############################

locals {
  ethertypes = {
    ipv4 = ["IPv4"]
    ipv6 = ["IPv6"]
    dual = ["IPv4", "IPv6"]
  }[var.ip_mode]

  # Hauptschnittstelle. Bei dual liegt sie im IPv6-Netz: dessen private
  # IPv4 bringt den Weg nach draussen (Paketquellen, Images fuer die
  # verschachtelten VMs) ueber NAT mit, und das oeffentliche IPv4 kommt als
  # zweite Schnittstelle dazu.
  primary_network_id = var.ip_mode == "ipv4" ? var.network_v4_uuid : var.network_uuid

  dual = var.ip_mode == "dual"
}

# SSH je Adressfamilie - eine IPv4-Regel laesst kein IPv6-Paket durch und
# umgekehrt. Die gemeinsame Security Group bleibt zusaetzlich dran; sie wird
# ausserhalb dieses Templates gepflegt.
#
# Die verschachtelten VMs brauchen hier keine Regel: sie haengen hinter dem
# NAT von libvirt und sind von aussen nicht erreichbar, nur aus ihrer VM.
resource "openstack_networking_secgroup_v2" "ssh" {
  name        = "${local.app_name}-ssh"
  description = "SSH zu den Nested-VM-Instanzen (${var.ip_mode})"
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  for_each = toset(local.ethertypes)

  security_group_id = openstack_networking_secgroup_v2.ssh.id
  direction         = "ingress"
  ethertype         = each.key
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.key == "IPv4" ? "0.0.0.0/0" : "::/0"
  description       = "SSH (${each.key})"
}

############################
# USER MANAGEMENT (CONTRACT)
############################

locals {
  roster = flatten([
    for team, members in var.users : [
      for member in members : {
        id    = "${team}-${replace(split("@", member.email)[0], ".", "-")}"
        team  = team
        email = member.email

        # Linux-Namen: klein, nur Buchstaben und Ziffern. "Anna.Alt" wird
        # zu "annaalt". Was danach nicht mit einem Buchstaben beginnt,
        # bekommt ein "u" davor - cloud-init legt "2fast" sonst nicht an,
        # und die ganze Einrichtung der VM scheitert.
        stem = substr(lower(replace(split("@", member.email)[0], "/[^A-Za-z0-9]/", "")), 0, 30)
      }
    ]
  ])

  all_users = [
    for user in local.roster : merge(user, {
      username = can(regex("^[a-z]", user.stem)) ? user.stem : substr("u${user.stem}", 0, 30)
    })
  ]

  # Gruppiert statt direkt als Map: zwei Eintraege mit demselben Schluessel
  # (dieselbe Person zweimal im Team, oder zwei Adressen mit gleichem
  # Lokalteil) wuerden sonst mit "Duplicate object key" abbrechen, ohne zu
  # sagen, wer gemeint ist. Die Pruefung unten nennt die Schluessel.
  users_by_id = { for user in local.all_users : user.id => user... }
  users_map   = { for id, entries in local.users_by_id : id => entries[0] }

  duplicate_ids = [for id, entries in local.users_by_id : id if length(entries) > 1]

  unique_teams = distinct([for user in local.all_users : user.team])

  # Eine VM pro Person. Verschachtelte VMs brauchen root-Rechte auf ihrem
  # Hypervisor und den Arbeitsspeicher der VM fuer sich - auf einer
  # geteilten VM kaemen sich die Studierenden gegenseitig in die Quere.
  vm_count = length(local.users_map)

  usernames = [for user in local.all_users : user.username]
  emails    = [for user in local.all_users : user.email]
}

# Bricht ab, bevor irgendetwas angelegt wird. Ohne diese Pruefung liefe der
# Apply bis zum Quota-Fehler von Nova und liesse dabei bereits erzeugte
# Instanzen stehen.
resource "terraform_data" "user_limit" {
  input = local.vm_count

  lifecycle {
    precondition {
      condition     = local.vm_count <= var.max_users
      error_message = "Diese App legt eine VM je Person an. Angefordert: ${local.vm_count}, erlaubt: ${var.max_users}. Entweder max_users anheben oder den Kurs aufteilen."
    }
    precondition {
      condition     = length(local.duplicate_ids) == 0
      error_message = "Mehrere Eintraege ergeben denselben Schluessel: ${join(", ", local.duplicate_ids)}. Jede Person darf je Team nur einmal vorkommen."
    }
  }
}

# Passwörter für jeden User generieren
resource "random_password" "user_passwords" {
  for_each         = local.users_map
  length           = 16
  special          = true
  override_special = "!@%^*_-+="
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

# Image per Name nachschlagen (keine IDs hardcoden)
data "openstack_images_image_v2" "image" {
  name        = local.image_name
  most_recent = true
}

# Zweite Schnittstelle fuer dual, je VM vorab als Port angelegt: so sind MAC
# und Adresse schon bekannt, wenn cloud-init sein user-data bekommt.
resource "openstack_networking_port_v2" "v4" {
  for_each   = local.dual ? local.users_map : {}
  name       = "${local.app_name}-${each.value.username}-v4"
  network_id = var.network_v4_uuid

  security_group_ids = [
    var.shared_secgroup_id,
    openstack_networking_secgroup_v2.ssh.id,
  ]
}

locals {
  secondary_ipv4 = {
    for id, port in openstack_networking_port_v2.v4 :
    id => [for ip in port.all_fixed_ips : ip if length(regexall(":", ip)) == 0][0]
  }
  secondary_mac = { for id, port in openstack_networking_port_v2.v4 : id => port.mac_address }

  secondary_gateway = local.dual ? data.openstack_networking_subnet_v2.v4[0].gateway_ip : ""
}

# Gateway des IPv4-Netzes fuer die eigene Routing-Tabelle der zweiten
# Schnittstelle (dual), siehe cloud-init.tofu.
data "openstack_networking_subnet_v2" "v4" {
  count      = local.dual ? 1 : 0
  network_id = var.network_v4_uuid
  ip_version = 4

  lifecycle {
    postcondition {
      condition     = self.gateway_ip != ""
      error_message = "Das IPv4-Netz in network_v4_uuid hat kein Gateway; dual braucht eins fuer die Antworten der zweiten Schnittstelle."
    }
  }
}

# -----------------------------------------------------------------------------
# Eine VM je Person
# -----------------------------------------------------------------------------
resource "openstack_compute_instance_v2" "user_vm" {
  for_each = local.users_map

  name        = "${local.app_name}-${each.value.username}"
  image_id    = local.boot_from_volume ? null : data.openstack_images_image_v2.image.id
  flavor_name = var.flavor

  security_groups = [var.shared_secgroup_id, openstack_networking_secgroup_v2.ssh.id]

  # Mit gewaehlter Plattengroesse bootet die VM von einem Volume aus dem
  # Image; ohne bleibt es bei der Systemplatte des Flavors.
  dynamic "block_device" {
    for_each = local.boot_from_volume ? [1] : []
    content {
      uuid                  = data.openstack_images_image_v2.image.id
      source_type           = "image"
      destination_type      = "volume"
      volume_size           = var.disk_size_gb
      boot_index            = 0
      delete_on_termination = true
    }
  }

  timeouts {
    create = "15m"
    delete = "15m"
  }

  # Nur die Hauptschnittstelle. Die zweite bei dual haengt interface_attach
  # unten an: als zweiter network-Block wuerde cloud-init sie beim ersten
  # Boot mit einer eigenen Default-Route einrichten, und zwei Default-Routen
  # in der Haupttabelle schicken Antworten ueber die falsche Schnittstelle.
  network {
    uuid = local.primary_network_id
  }

  user_data = local.cloud_init[each.key]

  lifecycle {
    precondition {
      condition     = var.ip_mode == "ipv6" || var.network_v4_uuid != ""
      error_message = "ip_mode \"${var.ip_mode}\" braucht ein IPv4-Netz in network_v4_uuid."
    }
    precondition {
      condition     = var.ip_mode == "ipv4" || var.network_uuid != ""
      error_message = "ip_mode \"${var.ip_mode}\" braucht ein IPv6-Netz in network_uuid."
    }
  }

  metadata = {
    app                   = local.app_name
    team                  = each.value.team
    user                  = each.value.username
    email                 = each.value.email
    nested_virtualization = tostring(var.nested_virtualization)
  }

  depends_on = [terraform_data.user_limit]
}

# Zweite Schnittstelle (dual) an die laufende Instanz. Eingerichtet wird sie
# von cloud-init, das auf ihre MAC wartet - siehe runcmd in cloud-init.tofu.
resource "openstack_compute_interface_attach_v2" "v4" {
  for_each    = openstack_networking_port_v2.v4
  instance_id = openstack_compute_instance_v2.user_vm[each.key].id
  port_id     = each.value.id
}

############################
# ADRESSEN
############################

locals {
  ipv4_address = {
    for id, vm in openstack_compute_instance_v2.user_vm : id => (
      var.ip_mode == "ipv4" ? vm.network[0].fixed_ip_v4
      : local.dual ? local.secondary_ipv4[id]
      : null
    )
  }

  # Ohne eckige Klammern: je nach Provider-Version kommt fixed_ip_v6 als
  # "[2001:...]" (gesehen bei der Kali-App) oder ohne. ssh erwartet die
  # nackte Adresse ("ssh anna@2001:db8::1"); wo ip:port gebraucht wird,
  # klammert der App Store selbst.
  ipv6_address = {
    for id, vm in openstack_compute_instance_v2.user_vm :
    id => var.ip_mode == "ipv4" ? null : trim(vm.network[0].fixed_ip_v6, "[]")
  }

  # Verbindungsziel fuer die Zugangsdaten. Bei dual IPv4, weil es mehr
  # Heimnetze erreicht; die IPv6 steht in team_vms daneben.
  access_ip = {
    for id in keys(local.users_map) :
    id => try(coalesce(local.ipv4_address[id], local.ipv6_address[id]), null)
  }
}
