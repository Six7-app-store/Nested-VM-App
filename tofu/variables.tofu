################################################
# Von der Plattform gesetzt
################################################

variable "users" {
  description = "Per-team roster — vom Worker injiziert."
  type = map(list(object({
    email = string
  })))
  default = {}
}

################################################
# Verschachtelte Virtualisierung
################################################

# Die Option, um die es in dieser App geht. Der Wizard baut seine Felder aus
# den Variablen der gewählten App - eine App ohne Hypervisor-Einrichtung
# deklariert die Variable nicht und bietet die Option deshalb gar nicht an.
#
#   true   QEMU/KVM und libvirt werden installiert, die Person darf VMs
#          starten (Gruppen libvirt und kvm), und beim ersten Boot startet
#          ein Selbsttest eine CirrOS-VM in der VM.
#   false  eine normale Ubuntu-VM mit sudo, ohne Hypervisor.
variable "nested_virtualization" {
  description = "Studierende dürfen in ihrer VM weitere VMs starten (QEMU/KVM und libvirt, mit Selbsttest beim Start)"
  type        = bool
  default     = true
}

################################################
# Größe der VM
################################################

# Die äußere VM teilt ihren Arbeitsspeicher mit allen VMs, die darin laufen.
# gp1.small ist dafür zu knapp und fehlt deshalb. win11.medium ist nicht an
# Windows gebunden: er bringt 80 GB Systemplatte ohne Cinder-Volume mit (wie
# bei der Kali-App) und reicht damit auch für DevStack.
#
# Reihenfolge = Reihenfolge im Wizard, klein nach groß.
variable "flavor" {
  description = "Größe der VM (CPU und Arbeitsspeicher) @openstack:flavor"
  type        = string
  default     = "gp1.large"

  validation {
    condition     = contains(["gp1.medium", "gp1.large", "win11.medium"], var.flavor)
    error_message = "flavor muss gp1.medium, gp1.large oder win11.medium sein."
  }
}

# 0 = die Systemplatte des Flavors (bei gp1 10 GB), ohne Cinder. Jeder andere
# Wert legt die Systemplatte als Cinder-Volume dieser Größe an; es wird mit
# der VM gelöscht.
variable "disk_size_gb" {
  description = "Festplatte in GB (0 = Standardgröße des Flavors)"
  type        = number
  default     = 0

  validation {
    condition     = var.disk_size_gb >= 0 && var.disk_size_gb <= 200
    error_message = "disk_size_gb muss zwischen 0 und 200 liegen."
  }

  # Das Ubuntu-Image braucht mindestens 10 GB. Bewusst als eigener Block mit
  # ">": so liest der Wizard nur den Bereich 0–200 oben als Grenzen.
  validation {
    condition     = var.disk_size_gb == 0 || var.disk_size_gb > 9
    error_message = "disk_size_gb muss 0 oder mindestens 10 sein."
  }
}

# Jede Person bekommt eine eigene VM, und jede belegt den vollen Flavor. Die
# Obergrenze bricht den Plan mit einer klaren Meldung ab, statt mitten im
# Apply an der Quota zu scheitern und halbfertige Instanzen stehen zu lassen.
variable "max_users" {
  description = "Obergrenze gleichzeitiger VMs (eine je Person)"
  type        = number
  default     = 10

  validation {
    condition     = var.max_users >= 1 && var.max_users <= 30
    error_message = "max_users muss zwischen 1 und 30 liegen."
  }
}

################################################
# Netz
################################################

# Welche Adressfamilie die Instanzen nach außen anbieten. Wählt das Netz und
# legt die SSH-Regeln je Familie an.
#
#   ipv4  eine Schnittstelle im IPv4-Netz (network_v4_uuid)
#   ipv6  eine Schnittstelle im IPv6-Netz (network_uuid) - Standard
#   dual  IPv6-Netz als Hauptschnittstelle, dazu eine zweite im IPv4-Netz
variable "ip_mode" {
  description = "Adressfamilie: ipv4, ipv6 oder dual (beide)"
  type        = string
  default     = "ipv6"

  validation {
    condition     = contains(["ipv4", "ipv6", "dual"], var.ip_mode)
    error_message = "ip_mode muss \"ipv4\", \"ipv6\" oder \"dual\" sein."
  }
}

variable "network_uuid" {
  description = "Netz mit öffentlicher IPv6, z. B. DHBWV6 - für ipv6 und dual @openstack:network:id"
  type        = string
  default     = "9b579624-d844-4df3-b38d-89978b31d37d"
}

variable "network_v4_uuid" {
  description = "Netz mit öffentlich gerouteter IPv4, z. B. DHBWv4 - für ipv4 und dual @openstack:network:id"
  type        = string
  default     = ""
}

variable "shared_secgroup_id" {
  description = "ID der gemeinsamen Security Group für alle VMs @openstack:security_group:id"
  type        = string
  default     = "7ca4f889-e11e-4a16-83a8-73a77ebdbbe6"
}
