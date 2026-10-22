#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Nested-VM-App: Hypervisor einrichten (beim ersten Boot, als root)
#
# QEMU, libvirt und virt-install hat cloud-init schon installiert. Dieses
# Skript schaltet libvirt ein, gibt der Person das Recht, VMs zu starten,
# legt Ablage und Testimage an und startet zum Schluss eine CirrOS-VM als
# Selbsttest (nested-vm-test).
#
# Scheitert der Selbsttest, endet das Skript mit Fehler. cloud-final schlaegt
# dann fehl, und der App Store meldet das Deployment als gescheitert
# (ADR 0011 im deployment-Repo) - statt eine VM auszuliefern, in der keine
# VM startet. Nur ein gescheiterter Download des Testimages laesst den
# Selbsttest aus: das ist eine Stoerung im Netz, keine im Hypervisor.
# -----------------------------------------------------------------------------

URI=qemu:///system
USERS_FILE=/etc/nested-vm/users
ACCEL_FILE=/etc/nested-vm/accel
STATE_DIR=/var/lib/nested-vm
VM_DIR=/srv/vms
IMAGE_DIR=$VM_DIR/images
TEST_IMAGE=$IMAGE_DIR/cirros.img

# CirrOS: ein Linux von gut 20 MB, gebaut zum Testen von Clouds. Bootet auch
# ohne Hardwarebeschleunigung in unter einer Minute.
CIRROS_VERSION=0.6.3
CIRROS_FILE=cirros-${CIRROS_VERSION}-x86_64-disk.img
CIRROS_URL=https://download.cirros-cloud.net/${CIRROS_VERSION}/${CIRROS_FILE}
# Aus https://download.cirros-cloud.net/0.6.3/SHA256SUMS
CIRROS_SHA256=7d6355852aeb6dbcd191bcda7cd74f1536cfe5cbf8a10495a7283a8396e4b75b

log() { echo "[nested-vm $(date -Is)] $*"; }

install -d -m 0755 "$STATE_DIR"

# -----------------------------------------------------------------------------
# [1] Hardwarebeschleunigung
# -----------------------------------------------------------------------------
# KVM in der VM geht nur, wenn OpenStack die Virtualisierungsfunktion der CPU
# (vmx bei Intel, svm bei AMD) an die Instanz durchreicht. Das entscheidet der
# Betrieb der Cloud, nicht diese App. Fehlt sie, laufen die inneren VMs mit
# QEMU-Emulation (TCG): deutlich langsamer, aber sie laufen.
if grep -qw vmx /proc/cpuinfo; then
  modprobe kvm_intel 2>/dev/null || true
elif grep -qw svm /proc/cpuinfo; then
  modprobe kvm_amd 2>/dev/null || true
fi

if [ -e /dev/kvm ]; then
  accel=kvm
  accel_text="KVM (hardwarebeschleunigt)"
else
  accel=tcg
  accel_text="QEMU-Emulation (TCG, ohne Hardwarebeschleunigung - langsamer)"
fi
echo "$accel" >"$ACCEL_FILE"
log "Beschleunigung: $accel_text"
kvm-ok 2>&1 | sed 's/^/  kvm-ok: /' || true

# -----------------------------------------------------------------------------
# [2] libvirt und sein NAT-Netz
# -----------------------------------------------------------------------------
log "libvirt starten..."
systemctl enable --now libvirtd.service

# Das Netz "default" (virbr0, 192.168.122.0/24, NAT nach aussen) bringt das
# Paket mit. Es fehlt nur, wenn jemand es geloescht hat.
#
# Kein "virsh ... | grep -q": grep beendet sich beim ersten Treffer, virsh
# bekommt SIGPIPE, und pipefail macht daraus einen Fehler. Deshalb erst
# einlesen, dann suchen.
network_active() {
  grep -qx default <<<"$(virsh -c "$URI" net-list --name)"
}

if ! virsh -c "$URI" net-info default >/dev/null 2>&1; then
  virsh -c "$URI" net-define /usr/share/libvirt/networks/default.xml
fi
virsh -c "$URI" net-autostart default >/dev/null
# libvirtd startet Netze mit Autostart selbst, auch erst kurz nach dem
# Daemon. Scheitert net-start, weil es inzwischen laeuft, ist das kein
# Fehler (gesehen im Containertest: "network is already active").
if ! network_active; then
  virsh -c "$URI" net-start default || network_active
fi

# -----------------------------------------------------------------------------
# [3] Rechte
# -----------------------------------------------------------------------------
# libvirt: VMs im systemweiten libvirt (qemu:///system) anlegen und steuern.
# kvm: /dev/kvm direkt nutzen, etwa mit qemu-system-x86_64 von Hand.
# Beides ist so viel wie root auf dieser VM - die Person hat ohnehin sudo,
# und die VM gehoert ihr allein.
groups=libvirt
getent group kvm >/dev/null && groups=libvirt,kvm

while read -r user <&3; do
  [ -n "$user" ] || continue
  if ! id "$user" >/dev/null 2>&1; then
    log "WARN: Linux-Nutzer $user fehlt, uebersprungen"
    continue
  fi
  usermod -aG "$groups" "$user"
  log "$user: Mitglied in $groups"
done 3<"$USERS_FILE"

# -----------------------------------------------------------------------------
# [4] Ablage fuer Platten und Images
# -----------------------------------------------------------------------------
# /srv/vms gehoert der Gruppe libvirt, damit Platten nicht in den Home-Ordner
# muessen: den darf der QEMU-Prozess (Nutzer libvirt-qemu) nicht lesen.
install -d -m 2775 -o root -g libvirt "$VM_DIR"
install -d -m 0755 -o root -g root "$IMAGE_DIR"

fetch_cirros() {
  local tmp attempt
  tmp=$(mktemp "$IMAGE_DIR/.cirros.XXXXXX")
  for attempt in 1 2 3; do
    if curl -fsSL --retry 2 -o "$tmp" "$CIRROS_URL" &&
      echo "$CIRROS_SHA256  $tmp" | sha256sum -c --quiet -; then
      chmod 0644 "$tmp"
      mv "$tmp" "$TEST_IMAGE"
      echo "$CIRROS_SHA256  $CIRROS_FILE" >"$TEST_IMAGE.sha256"
      return 0
    fi
    log "WARN: Download von $CIRROS_FILE, Versuch $attempt fehlgeschlagen"
    sleep 10
  done
  rm -f "$tmp"
  return 1
}

if [ -r "$TEST_IMAGE" ]; then
  log "Testimage liegt schon da: $TEST_IMAGE"
elif fetch_cirros; then
  log "Testimage geladen: $TEST_IMAGE (CirrOS $CIRROS_VERSION)"
fi

# -----------------------------------------------------------------------------
# [5] Selbsttest: eine VM in dieser VM starten
# -----------------------------------------------------------------------------
result=0
if [ ! -r "$TEST_IMAGE" ]; then
  test_text="uebersprungen - Testimage nicht ladbar (Netz?). Von Hand: nested-vm-test"
  log "WARN: Selbsttest $test_text"
elif nested-vm-test; then
  test_text="bestanden - eine CirrOS-VM hat gebootet und per DHCP eine Adresse bekommen"
else
  result=1
  test_text="FEHLGESCHLAGEN - Verlauf in /var/log/nested-vm-setup.log"
  log "ERROR: Selbsttest fehlgeschlagen"
fi
echo "$test_text" >"$STATE_DIR/selbsttest"

# -----------------------------------------------------------------------------
# [6] Begruessung beim Login
# -----------------------------------------------------------------------------
cat >/etc/motd <<EOF

  Nested-VM-App - VMs in dieser VM starten
  ----------------------------------------
  Beschleunigung:  $accel_text
  Selbsttest:      $test_text

  Lernmaterial:    ~/virt-kurs/LIES_MICH.txt
  Platten, Images: /srv/vms   (Testimage: /srv/vms/images/cirros.img)
  Test wiederholen: nested-vm-test

  Meldet virsh "permission denied": einmal ab- und wieder anmelden.

EOF

log "Fertig."
exit "$result"
