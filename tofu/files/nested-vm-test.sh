#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Nested-VM-App: Selbsttest - startet eine VM in dieser VM
#
# Legt eine Overlay-Platte auf das CirrOS-Image, startet damit eine kleine VM
# im libvirt-Netz "default" und wartet, bis sie per DHCP eine Adresse bekommt.
# Eine Adresse heisst: der Gast hat sein Betriebssystem gebootet und spricht
# ueber das Netz. Danach wird die Test-VM wieder entfernt.
#
# Laeuft beim ersten Boot einmal als root (nested-vm-setup) und steht danach
# allen in der Gruppe libvirt zur Verfuegung:  nested-vm-test
# -----------------------------------------------------------------------------

URI=qemu:///system
IMAGE=/srv/vms/images/cirros.img
NAME="selbsttest-$(id -un)"
DISK="/srv/vms/${NAME}.qcow2"
# Ohne Hardwarebeschleunigung bootet CirrOS in rund einer Minute; die Frist
# laesst Luft fuer einen ausgelasteten Hypervisor darunter.
TIMEOUT=${NESTED_VM_TEST_TIMEOUT:-600}

cleanup() {
  virsh -c "$URI" destroy "$NAME" >/dev/null 2>&1 || true
  virsh -c "$URI" undefine "$NAME" >/dev/null 2>&1 || true
  rm -f "$DISK"
}

start_vm() {
  qemu-img create -q -f qcow2 -F qcow2 -b "$IMAGE" "$DISK"
  virt-install --connect "$URI" --name "$NAME" --virt-type "$1" \
    --memory 256 --vcpus 1 --import \
    --disk "path=$DISK,format=qcow2,bus=virtio" \
    --network network=default,model=virtio \
    --osinfo detect=on,require=off \
    --graphics none --noautoconsole
}

if [ ! -r "$IMAGE" ]; then
  echo "FEHLER: Testimage fehlt: $IMAGE" >&2
  exit 2
fi

trap cleanup EXIT
cleanup

if [ -e /dev/kvm ]; then
  virt_type=kvm
else
  virt_type=qemu
fi

echo "Starte Test-VM $NAME (libvirt-Typ: $virt_type)..."
if ! start_vm "$virt_type"; then
  [ "$virt_type" = kvm ] || exit 1
  # /dev/kvm ist da, aber libvirt kann es nicht nutzen. Die Emulation
  # erfuellt den Zweck trotzdem; der Hinweis zeigt, dass KVM klemmt.
  echo "WARN: Start mit KVM fehlgeschlagen, versuche QEMU-Emulation" >&2
  cleanup
  virt_type=qemu
  start_vm "$virt_type"
fi

# awk liest jeweils bis zum Ende statt beim ersten Treffer abzubrechen:
# sonst bekaeme virsh SIGPIPE, und pipefail machte daraus einen Fehler.
mac=$(virsh -c "$URI" domiflist "$NAME" | awk 'NR > 2 && $5 ~ /:/ && m == "" { m = $5 } END { print m }')
if [ -z "$mac" ]; then
  echo "FEHLER: Test-VM hat keine Netzwerkkarte" >&2
  exit 1
fi

echo "Warte bis zu ${TIMEOUT}s auf eine DHCP-Adresse fuer $mac..."
deadline=$((SECONDS + TIMEOUT))
ip=""
while [ "$SECONDS" -lt "$deadline" ]; do
  state=$(virsh -c "$URI" domstate "$NAME" 2>/dev/null || true)
  if [ "$state" != "running" ]; then
    echo "FEHLER: Test-VM laeuft nicht mehr (Zustand: ${state:-unbekannt})" >&2
    exit 1
  fi
  # Spalten: Datum Uhrzeit MAC Protokoll Adresse/Praefix Hostname Client-ID
  ip=$(virsh -c "$URI" net-dhcp-leases default --mac "$mac" 2>/dev/null |
    awk '$4 == "ipv4" && a == "" { a = $5; sub(/\/.*/, "", a) } END { print a }')
  [ -n "$ip" ] && break
  sleep 5
done

if [ -z "$ip" ]; then
  echo "FEHLER: Test-VM hat nach ${TIMEOUT}s keine Adresse bekommen" >&2
  exit 1
fi

# Ping nur als Zusatz: die Adresse beweist den Boot schon.
if ping -c 3 -W 2 "$ip" >/dev/null 2>&1; then
  ping_text=", antwortet auf Ping"
else
  ping_text=", Ping blieb ohne Antwort"
fi

echo "OK: Test-VM ($virt_type) gebootet nach ${SECONDS}s, Adresse $ip$ping_text."
