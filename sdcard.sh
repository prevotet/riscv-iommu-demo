#!/usr/bin/env bash
# Ce script codait /dev/sdc en dur.
#
# Sur cette machine le lecteur expose DEUX slots (sdc et sdd, même numéro de
# série) et sdc est le slot vide : viser /dev/sdc en dur envoyait sgdisk sur un
# périphérique à 0 secteur, avec une volée d'avertissements alarmants
# (« Disk is too small to hold GPT data », « An error was reported when writing
# the partition table ») pour au final ne rien écrire. Un nom de périphérique en
# dur dans un script qui repartitionne est un piège : il suffit d'un
# réénumération USB pour qu'il désigne autre chose.
#
# tools/flash_sd.sh prend le périphérique en argument et vérifie avant d'écrire
# qu'il est amovible, non vide, de taille plausible et non monté.
exec "$(dirname "${BASH_SOURCE[0]}")/tools/flash_sd.sh" "$@"
