#!/usr/bin/env bash
# festplatten_rettung.sh  –  interaktive Version
#
# Phase 1: ddrescue erstellt ein Abbild der defekten Platte/Karte (unterbrechbar,
#          Neustart setzt dank Mapfile automatisch fort)
# Phase 2: Partitionen des Abbilds read-only mounten, alle Dateien nach rohdaten/
#          kopieren. Mount unmöglich -> tsk_recover liest die MFT/Metadaten direkt
#          (behält Dateinamen und Pfade). Auch das erfolglos -> photorec-Carving.
# Phase 3: Eigene Dateien (Bilder, Dokumente, Videos, Musik, Mails, Archive) nach
#          sortiert/ einsortieren. System-/Programmpfade und Mini-Bilder werden
#          ausgeschlossen. Namenskollisionen werden case-insensitiv geprüft,
#          damit sich sortiert/ ohne Nachfragen auf FAT32/exFAT/NTFS/Windows
#          kopieren lässt.
#
# Unterstützt Festplatten, USB-Sticks und SD-Karten (USB-Kartenleser /dev/sdX
# wie auch eingebaute Leser /dev/mmcblkN).
#
# Aufruf:  bash ./festplatten_rettung.sh                     (komplett interaktiv)
#          bash ./festplatten_rettung.sh /dev/sdX /pfad/ziel (direkt)
#
# Fehlende Pakete (gddrescue, ntfs-3g, exfatprogs, sleuthkit, ggf. testdisk)
# werden automatisch per apt nachinstalliert. Zielverzeichnis wird automatisch
# angelegt.

set -uo pipefail

# ==== Anpassbare Filter ====
MIN_BILD_KB=100      # Bilder unter 100 KB = Icons/Thumbnails -> ignorieren
MIN_AUDIO_KB=500     # filtert Systemklänge
MIN_VIDEO_KB=1000    # filtert UI-/Programmclips

[[ $EUID -eq 0 ]] || { echo "FEHLER: als root ausführen (sudo)."; exit 1; }

# ==== Benötigte Pakete automatisch nachinstallieren ====
FEHLEND=()
command -v ddrescue    >/dev/null || FEHLEND+=(gddrescue)
command -v ntfs-3g     >/dev/null || FEHLEND+=(ntfs-3g)
command -v fsck.exfat  >/dev/null || FEHLEND+=(exfatprogs)
command -v tsk_recover >/dev/null || FEHLEND+=(sleuthkit)
if (( ${#FEHLEND[@]} )); then
    echo "Installiere fehlende Pakete: ${FEHLEND[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${FEHLEND[@]}" \
        || { echo "FEHLER: Paketinstallation fehlgeschlagen."; exit 1; }
fi

QUELLE="${1:-}"
ZIEL="${2:-}"

# Systemplatte ermitteln – wird zur Auswahl gesperrt
SYSDISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)

# ==== Quellgerät wählen ====
if [[ -z "$QUELLE" ]]; then
    echo
    echo "== Verfügbare Laufwerke =="
    lsblk -o NAME,SIZE,MODEL,TRAN -e7
    echo
    echo "SD-Karten: im USB-Leser als sdX, im eingebauten Leser als mmcblkN."
    echo "Geräte mit 0B sind leere Kartenleser-Slots."
    [[ -n "$SYSDISK" ]] && echo "Systemplatte: $SYSDISK (gesperrt, nicht wählbar)"
    read -rp "Zu rettendes Gerät (z.B. sdb oder mmcblk0): " QUELLE
fi
[[ "$QUELLE" == /dev/* ]] || QUELLE="/dev/$QUELLE"
[[ -b "$QUELLE" ]] || { echo "FEHLER: $QUELLE ist kein Blockgerät."; exit 1; }

# Partition angegeben? -> automatisch auf ganze Platte wechseln
ELTERN=$(lsblk -no PKNAME "$QUELLE" | head -1)
if [[ -n "$ELTERN" ]]; then
    echo "Hinweis: $QUELLE ist eine Partition – verwende ganze Platte /dev/$ELTERN."
    QUELLE="/dev/$ELTERN"
fi

if [[ -n "$SYSDISK" && "$QUELLE" == "/dev/$SYSDISK" ]]; then
    echo "FEHLER: $QUELLE ist die Systemplatte – Abbruch."
    exit 1
fi

# Leerer Kartenleser-Slot?
PLATTE_B=$(blockdev --getsize64 "$QUELLE" 2>/dev/null || echo 0)
if (( PLATTE_B == 0 )); then
    echo "FEHLER: $QUELLE hat 0 Byte – keine Karte eingesteckt?"
    exit 1
fi

INFO=$(lsblk -dno SIZE,MODEL,TRAN "$QUELLE" | tr -s ' ')
read -rp "Gerät $QUELLE ($INFO) wirklich retten? [j/N] " a
[[ "$a" =~ ^[jJ]$ ]] || exit 1

# ==== Zielverzeichnis wählen – wird automatisch angelegt ====
if [[ -z "$ZIEL" ]]; then
    STANDARD="$PWD/rettung_$(date +%F)"
    read -rp "Zielverzeichnis [$STANDARD]: " ZIEL
    ZIEL="${ZIEL:-$STANDARD}"
fi
mkdir -p "$ZIEL" || { echo "FEHLER: kann $ZIEL nicht anlegen."; exit 1; }

# Ziel darf nicht auf der Quellplatte liegen
ZIEL_DEV=$(df --output=source "$ZIEL" | tail -1)
if [[ "$ZIEL_DEV" == "$QUELLE"* ]]; then
    echo "FEHLER: Ziel $ZIEL liegt auf der defekten Platte selbst."
    exit 1
fi

# Platzcheck
FREI_B=$(df --output=avail -B1 "$ZIEL" | tail -1)
if (( FREI_B < PLATTE_B )); then
    echo "WARNUNG: Freier Platz ($((FREI_B/1024**3)) GiB) < Plattengröße ($((PLATTE_B/1024**3)) GiB)."
    read -rp "Trotzdem fortfahren? [j/N] " a
    [[ "$a" =~ ^[jJ]$ ]] || exit 1
fi

# Vom Desktop automatisch gemountete Partitionen der Quelle aushängen.
# Über den Gerätenamen statt den Mountpunkt – funktioniert auch bei Labels
# mit Leerzeichen (z.B. "NO NAME" bei SD-Karten).
for dev in $(lsblk -nlpo NAME "$QUELLE"); do
    if findmnt -S "$dev" >/dev/null; then
        umount "$dev" && echo "-> $dev ausgehängt" \
            || { echo "FEHLER: $dev lässt sich nicht aushängen (noch in Benutzung?)."; exit 1; }
    fi
done

IMG="$ZIEL/platte.img"
MAP="$ZIEL/platte.map"
ROH="$ZIEL/rohdaten"
SORT="$ZIEL/sortiert"
MNT="$ZIEL/mnt"
mkdir -p "$ROH" "$SORT" "$MNT"

# ============================================================
echo "== Phase 1: ddrescue – Abbild erstellen =="
# Durchlauf 1: schnell, defekte Bereiche überspringen
ddrescue -f -n "$QUELLE" "$IMG" "$MAP"
# Durchlauf 2: defekte Bereiche gezielt nachlesen (3 Versuche, Direct I/O)
ddrescue -f -d -r3 "$QUELLE" "$IMG" "$MAP"

# ============================================================
echo "== Phase 2: Dateien aus dem Abbild holen =="
LOOP=$(losetup -fP --show "$IMG")

aufraeumen() {
    for m in "$MNT"/p*; do mountpoint -q "$m" 2>/dev/null && umount "$m"; done
    [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP" 2>/dev/null
}
trap aufraeumen EXIT

GEFUNDEN=0
for PART in "$LOOP"p*; do
    [[ -b "$PART" ]] || continue
    P=$(basename "$PART")
    mkdir -p "$MNT/$P" "$ROH/$P"
    if mount -o ro "$PART" "$MNT/$P"; then
        echo "-> $PART gemountet, kopiere nach $ROH/$P ..."
        rsync -a --no-D --ignore-errors "$MNT/$P/" "$ROH/$P/" || true
        umount "$MNT/$P"
        GEFUNDEN=1
    else
        echo "-> $PART: mount fehlgeschlagen – versuche tsk_recover (liest MFT/Metadaten direkt, read-only)"
        tsk_recover -a "$PART" "$ROH/$P" || true
        if [[ -n $(find "$ROH/$P" -type f -print -quit 2>/dev/null) ]]; then
            echo "-> $PART: tsk_recover erfolgreich, Dateien mit Originalnamen in $ROH/$P"
            GEFUNDEN=1
        else
            echo "-> $PART: auch tsk_recover erfolglos"
        fi
    fi
done

# Platte ohne Partitionstabelle (Dateisystem direkt auf dem Gerät)
if [[ $GEFUNDEN -eq 0 ]]; then
    mkdir -p "$MNT/p0" "$ROH/p0"
    if mount -o ro "$LOOP" "$MNT/p0" 2>/dev/null; then
        rsync -a --no-D --ignore-errors "$MNT/p0/" "$ROH/p0/" || true
        umount "$MNT/p0"
        GEFUNDEN=1
    else
        tsk_recover -a "$LOOP" "$ROH/p0" 2>/dev/null || true
        [[ -n $(find "$ROH/p0" -type f -print -quit 2>/dev/null) ]] && GEFUNDEN=1
    fi
fi

# Letzter Fallback: photorec carvt Dateien direkt aus dem Abbild (ohne Namen/Pfade)
if [[ $GEFUNDEN -eq 0 ]]; then
    echo "Weder Mount noch tsk_recover erfolgreich – starte photorec (Datei-Carving)."
    if ! command -v photorec >/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq testdisk
    fi
    mkdir -p "$ZIEL/photorec_out"
    photorec /log /d "$ZIEL/photorec_out" /cmd "$IMG" partition_none,search \
        || { echo "Automatik fehlgeschlagen – manuell starten: photorec $IMG"; exit 2; }
    echo "Carving fertig: $ZIEL/photorec_out (Dateien dort ohne Originalnamen/-pfade)"
    exit 0
fi

# ============================================================
echo "== Phase 3: Eigene Dateien sortieren =="

# System-/Programmordner, die komplett übersprungen werden (bei Bedarf anpassen).
# '.*' schließt alle versteckten Ordner aus (.cache, .thumbnails, .mozilla, ...).
PRUNE=(
    -iname 'Windows' -o -iname 'Program Files*' -o -iname 'ProgramData' -o
    -iname 'PerfLogs' -o -iname '$Recycle.Bin' -o -iname 'System Volume Information' -o
    -iname 'Recovery' -o -iname 'MSOCache' -o -iname 'AppData' -o
    -name 'usr' -o -name 'var' -o -name 'lib' -o -name 'lib64' -o -name 'opt' -o
    -name 'etc' -o -name 'boot' -o -name 'bin' -o -name 'sbin' -o -name 'snap' -o
    -name 'srv' -o -name 'proc' -o -name 'sys' -o -name 'run' -o -name 'dev' -o
    -name 'Library' -o -name 'System' -o -name 'Applications' -o
    -name 'node_modules' -o -name '.*'
)

# Kollisionsprüfung läuft case-insensitiv über ein Namensregister, damit z.B.
# IMG_0505.JPG und IMG_0505.jpg nicht nebeneinander landen (gäbe Überschreib-
# Nachfragen beim Kopieren auf FAT32/exFAT/NTFS/Windows).
sortiere() {
    local name="$1" minkb="$2" regex="$3"
    local zieldir="$SORT/$name" n=0
    mkdir -p "$zieldir"
    local -A belegt=()
    # Bei Wiederholungsläufen: vorhandene Dateien ins Register aufnehmen
    while IFS= read -r -d '' v; do
        belegt[${v,,}]="$zieldir/$v"
    done < <(find "$zieldir" -maxdepth 1 -type f -printf '%f\0')
    while IFS= read -r -d '' f; do
        local base kl ziel h vorhanden
        base=$(basename "$f")
        kl=${base,,}
        vorhanden="${belegt[$kl]:-}"
        if [[ -n "$vorhanden" ]]; then
            h=$(md5sum -- "$f" | awk '{print $1}')
            # identische Datei schon vorhanden -> überspringen (Duplikat)
            [[ $(md5sum -- "$vorhanden" | awk '{print $1}') == "$h" ]] && continue
            # Namenskollision bei anderem Inhalt -> Hash anhängen
            base="${base%.*}_${h:0:8}.${base##*.}"
            kl=${base,,}
            [[ -n "${belegt[$kl]:-}" ]] && continue
        fi
        ziel="$zieldir/$base"
        cp -p -- "$f" "$ziel" && { belegt[$kl]="$ziel"; n=$((n+1)); }
    done < <(find "$ROH" -type d \( "${PRUNE[@]}" \) -prune -o \
             -type f -size +"${minkb}"k -regextype posix-extended -iregex "$regex" -print0)
    echo "-> $name: $n Dateien"
}

sortiere "Bilder"    "$MIN_BILD_KB"  '.*\.(jpg|jpeg|png|gif|bmp|tif|tiff|webp|heic|heif)$'
sortiere "RAW-Fotos" 0               '.*\.(cr2|cr3|nef|arw|dng|orf|rw2|raf|srw)$'
sortiere "Dokumente" 0               '.*\.(pdf|doc|docx|odt|rtf|txt|xls|xlsx|ods|csv|ppt|pptx|odp)$'
sortiere "Videos"    "$MIN_VIDEO_KB" '.*\.(mp4|mov|avi|mkv|wmv|mpg|mpeg|mts|m2ts|3gp|webm)$'
sortiere "Musik"     "$MIN_AUDIO_KB" '.*\.(mp3|flac|wav|m4a|ogg|wma|aac|opus)$'
sortiere "E-Mails"   0               '.*\.(pst|ost|eml|msg|mbox)$'
sortiere "Archive"   0               '.*\.(zip|rar|7z|tar|gz|tgz)$'

# ============================================================
echo
echo "== Fertig =="
echo "Abbild:        $IMG  (aufheben, bis die Rettung geprüft ist!)"
echo "Alle Dateien:  $ROH"
echo "Sortiert:      $SORT"
du -sh "$SORT"/* 2>/dev/null
