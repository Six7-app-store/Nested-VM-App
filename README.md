# Nested-VM-App

Eine Virtualisierungs-Lernumgebung für Hochschulkurse. Jede Person bekommt
eine **eigene Ubuntu-24.04-VM** und kann darin **weitere VMs starten** – für
Übungen zu Virtualisierung, OpenStack oder Pentesting.

> Als Dozent möchte ich, dass Studierende in ihrer VM weitere VMs starten
> können, damit Übungen zu Virtualisierung, OpenStack oder Pentesting möglich
> sind.
>
> - In der VM lässt sich eine weitere VM starten
> - Option nur bei passenden Templates wählbar

## Wie die App die Akzeptanzkriterien erfüllt

**In der VM lässt sich eine weitere VM starten.** cloud-init installiert
QEMU, libvirt und virt-install, gibt der Person die Rechte dafür und startet
beim ersten Boot einen **Selbsttest**: eine kleine CirrOS-VM in der VM, die
per DHCP eine Adresse bekommen muss. Scheitert der Test, scheitert
`cloud-final` und damit das Deployment (ADR 0011 im `deployment`-Repo) –
der App Store liefert also keine VM aus, in der keine VM startet.

**Option nur bei passenden Templates wählbar.** Die Option ist die Variable
`nested_virtualization` dieser App. Der Wizard baut seine Felder aus den
Variablen der gewählten App und zeigt sie hier als Schalter. Apps ohne
Hypervisor-Einrichtung (Ubuntu-, Docker-, Kali-App, …) deklarieren die
Variable nicht und bieten die Option deshalb gar nicht an. An Backend und
Frontend ist dafür nichts zu ändern.

| `nested_virtualization` | Ergebnis |
|---|---|
| `true` (Standard) | QEMU/KVM, libvirt, virt-install, Gruppen `libvirt` und `kvm`, Lernmaterial, Selbsttest |
| `false` | normale Ubuntu-VM mit sudo, ohne Hypervisor |

## KVM oder Emulation

Ob die inneren VMs mit Hardwarebeschleunigung (KVM) laufen, entscheidet
nicht diese App, sondern der Betrieb der Cloud: OpenStack muss die
Virtualisierungsfunktion der CPU (`vmx` bei Intel, `svm` bei AMD) an die
Instanz durchreichen. Normale Projekte können das weder per Flavor noch per
Image erzwingen.

Die App funktioniert in beiden Fällen:

| | erkannt an | innere VMs |
|---|---|---|
| **KVM** | `/dev/kvm` existiert | fast so schnell wie die äußere VM |
| **Emulation (TCG)** | `/dev/kvm` fehlt | QEMU emuliert die CPU in Software: CirrOS bootet in etwa einer Minute, ein Ubuntu-Gast braucht mehrere Minuten |

Welcher Fall vorliegt, steht nach dem Login in der Begrüßung und in
`/etc/nested-vm/accel`. **Ob newstack `vmx` durchreicht, ist nicht geprüft**
– siehe [Stand der Erprobung](#stand-der-erprobung).

## User-Management

- **Eine VM pro Person**, ein Account darauf, abgeleitet aus der E-Mail
  (`anna.alt@dhbw.de` → `annaalt`; beginnt der Name mit einer Ziffer, kommt
  ein `u` davor)
- Zufälliges Passwort, SSH-Login mit Passwort
- `sudo` sowie die Gruppen `libvirt` und `kvm`. Das ist so viel wie root –
  auf einer VM, die der Person allein gehört.

**Warum eine VM pro Person?** Verschachtelte VMs teilen sich den
Arbeitsspeicher der äußeren VM, und Übungen wie DevStack oder ein
Pentest-Labor brauchen root-Rechte auf dem Hypervisor. Auf einer geteilten
VM kämen sich die Studierenden gegenseitig in die Quere.

## VM-Deployment

| | |
|---|---|
| VMs | **eine pro Person**, höchstens `max_users` (Standard 10) |
| Größe | wählbar: `gp1.medium`, `gp1.large` (Standard), `win11.medium` |
| Festplatte | wählbar: 10–200 GB, Standard ist die Platte des Flavors |
| Erreichbar über | SSH, wählbar über IPv6 (Standard), IPv4 oder beides |
| Floating IP | Nein |
| Bereit nach | einige Minuten: Pakete, libvirt, Selbsttest |

`gp1.small` fehlt bewusst: die inneren VMs brauchen Arbeitsspeicher.
`win11.medium` ist nicht an Windows gebunden – er bringt 80 GB Platte ohne
Cinder-Volume mit (wie bei der Kali-App) und ist die richtige Wahl für
DevStack.

Die inneren VMs hängen im libvirt-Netz `default` (192.168.122.0/24, NAT):
sie kommen ins Internet, sind aber nur aus ihrer VM erreichbar. Die
Security Group der äußeren VM braucht deshalb nur SSH.

## Konfigurierbare Variablen

| Variable | Beschreibung | Standard |
|---|---|---|
| `nested_virtualization` | Studierende dürfen in ihrer VM weitere VMs starten | `true` |
| `flavor` | Größe der VM; der Wizard zeigt nur die erlaubten Flavors | `gp1.large` |
| `disk_size_gb` | `0` = Platte des Flavors; 10–200 legt die Systemplatte als Volume an, das mit der VM gelöscht wird | `0` |
| `max_users` | Obergrenze gleichzeitiger VMs; bricht den Plan mit klarer Meldung ab | `10` |
| `ip_mode` | `ipv4`, `ipv6` oder `dual` – wie in der Ubuntu-App | `ipv6` |
| `network_uuid` | Netz mit öffentlicher IPv6, für `ipv6` und `dual` | `DHBWV6` |
| `network_v4_uuid` | Netz mit öffentlich gerouteter IPv4, für `ipv4` und `dual` | leer |
| `shared_secgroup_id` | ID der gemeinsamen Security Group | `default` |

`users` setzt der App Store selbst.

## Lernmaterial

Unter `~/virt-kurs/`:

    ~/virt-kurs/
    ├── LIES_MICH.txt            ← Kurzreferenz: virsh, qemu-img, virt-install
    └── uebungen/
        ├── 01-erste-vm/         ← CirrOS starten, anmelden, abräumen
        ├── 02-netzwerke/        ← isoliertes Netz für zwei VMs (labnetz.xml)
        ├── 03-snapshots/        ← Zustand sichern und zurückspringen
        ├── 04-openstack/        ← DevStack in der VM (local.conf)
        └── 05-pentest-labor/    ← Zielsystem in einem Netz ohne Internet

Auf der VM:

| Pfad | Inhalt |
|---|---|
| `/srv/vms` | Platten der Studierenden (Gruppe `libvirt` darf schreiben) |
| `/srv/vms/images/cirros.img` | Testsystem CirrOS 0.6.3, Prüfsumme in `cirros.img.sha256` |
| `/etc/nested-vm/accel` | `kvm` oder `tcg` |
| `/var/lib/nested-vm/selbsttest` | Ergebnis des Selbsttests beim ersten Boot |
| `/var/log/nested-vm-setup.log` | Verlauf der Einrichtung |

`nested-vm-test` wiederholt den Selbsttest jederzeit, auch ohne root.

## Aufbau

Reine OpenTofu-App nach ADR 0010: ein Ordner `tofu/`, kein Packer, kein
Image-Bau.

    Nested-VM-App/
    └── tofu/
        ├── main.tofu              ← VMs, Netz, Security Group, Adressen
        ├── variables.tofu
        ├── outputs.tofu           ← user_accounts mit protocol = "ssh" (ADR 0007)
        ├── cloud-init.tofu        ← cloud-init je VM, per yamlencode
        ├── files/
        │   ├── nested-vm-setup.sh ← libvirt, Rechte, Testimage, Selbsttest
        │   ├── nested-vm-test.sh  ← startet eine CirrOS-VM in der VM
        │   ├── profile.sh         ← LIBVIRT_DEFAULT_URI=qemu:///system
        │   └── virt-kurs/         ← Lernmaterial (→ /etc/skel)
        └── tests/vm.tftest.hcl    ← Tests mit gemockten Providern

Skripte und Lernmaterial gehen gzip-komprimiert in die `user_data` (Nova-Limit
64 KB); gerendert sind es rund 19 KB je VM.

Zwei Abweichungen von der Ubuntu-App, beide mit Grund:

- **Keine ufw.** Sie säße im Forward-Pfad der libvirt-Netze und kappte den
  NAT der inneren VMs. Von außen schützt die Security Group.
- **IPv6 ohne eckige Klammern** in den Zugangsdaten, auch wenn der Provider
  sie liefert (gesehen bei der Kali-App): `ssh` erwartet die nackte Adresse.

## Fehlersuche

Auf der VM:

    cat /var/lib/nested-vm/selbsttest
    cat /var/log/nested-vm-setup.log
    kvm-ok
    virsh -c qemu:///system list --all
    virsh -c qemu:///system net-list --all

## Prüfen

```sh
cd tofu
tofu init -backend=false
tofu fmt -check -recursive
tofu validate
tofu test
```

CI (`.github/workflows/`) fährt dieselben Schritte plus `bash -n` und
ShellCheck für die Skripte – ohne Cloud-Zugang, ohne Apply.

## Stand der Erprobung

**Nachgewiesen:**

- `tofu test`: 15 Fälle mit gemockten Providern – eine VM je Person,
  Benutzernamen, Hypervisor nur mit der Option, alle drei IP-Modi,
  Zugangsdaten, Plattengröße, Obergrenze, doppelte Einträge, ungültige
  Eingaben
- Die gerenderte cloud-config besteht `cloud-init schema` (cloud-init 26.2,
  Ubuntu 24.04)
- Der Wizard-Parser des Backends liest `variables.tofu`:
  `nested_virtualization` als Schalter, Flavor-Auswahl, Bereiche
- ShellCheck ohne Befund
- **Einrichtung und Selbsttest echt ausgeführt**, in einem privilegierten
  Ubuntu-24.04-Container mit denselben Paketen und ohne `/dev/kvm`, also im
  Emulationsfall (22.10.2026):
  - `nested-vm-setup` ohne `HOME` (wie in runcmd): libvirt, Netz
    `default`, Gruppen, `/srv/vms`, CirrOS-Download mit SHA256-Prüfung,
    Begrüßung – fertig nach 26 s
  - Selbsttest: CirrOS bootet mit QEMU-Emulation in rund 20 s, bekommt
    per DHCP eine Adresse und antwortet auf Ping – als root und als
    Studierende ohne root
  - Übungen 1–3 mit den Befehlen aus den Aufgabentexten, als
    Studierende: VM starten und `domifaddr`, `labnetz.xml` anlegen und
    starten, Snapshot anlegen, zurückspringen, löschen
  - Der erste Lauf fand einen echten Fehler (`net-start` auf ein Netz, das
    libvirt gerade selbst gestartet hatte); behoben, ebenso zwei Stellen
    mit `pipefail` und vorzeitig endendem Leser

  Abweichungen vom echten Boot: im Container läuft kein systemd
  (`systemctl` war durch einen Starter für libvirtd ersetzt, cgroups für
  Gäste abgeschaltet) und kein AppArmor.

**Nicht erprobt:**

- Ein Deployment über den App Store auf newstack
- Ob newstack `vmx`/`svm` an die Instanzen durchreicht, also ob die inneren
  VMs dort mit KVM oder mit Emulation laufen. Der KVM-Pfad selbst ist
  deshalb ungetestet.
- Übung 4 (DevStack) und Übung 5 (nmap im Labornetz)

## Release

Der App Store deployt nur Git-Tags im Format `v<Major>.<Minor>.<Patch>`.
