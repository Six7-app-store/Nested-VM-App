# shellcheck shell=sh
# Nested-VM-App: Komfort fuer alle Login-Shells.
# Wird auch von /bin/sh gelesen - deshalb nur POSIX-Syntax.

# virsh und virt-install sprechen damit ohne weitere Angabe mit dem
# systemweiten libvirt, in dem auch der Selbsttest lief und das Netz
# "default" haengt. Ohne das startet virsh fuer normale Nutzer eine eigene
# Sitzungsinstanz und zeigt dort eine leere Liste.
if [ "$(id -u)" -ne 0 ]; then
  export LIBVIRT_DEFAULT_URI=qemu:///system
fi
