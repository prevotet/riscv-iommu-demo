# Reprendre le travail ARMOR sur une autre machine

État au **2026-09-11, 23h15**, branche `testbench`, poussée sur GitHub. Ce document
existe parce que le README amont ne dit rien de la chaîne de bench, et que tout le
reste vivait dans les messages de commit.

## 0. Où reprendre, exactement

**Configuration de référence, VALIDÉE SUR CARTE : `W_SKID + FRESH + RESP_HOLD + W_FATE`**
(`CTRL` relu `0x331`). **Bitstream archivé : v10** (`c0df50b`) — `tools/bitstream.sh use
bench`, puis `check bench` doit dire À JOUR.

**Validation de `W_FATE` sur carte, 2026-09-11 17:00**, même bitstream v10, chargement par
`capture_uart.sh -j` :

| | `wfate0` (`results/bench_2026-09-11_170057.log`) | `wfate1` (`170253`) |
|---|---|---|
| `CTRL` relu | `0x131` | `0x331` |
| `W V- last` en aval du wrapper 2 | 9 / 21 | **0 / 21** |
| SC04 `SUMMARY-TX` p99 / max | 65 671 / 65 687 (timeout) | **1230 / 1230** |
| SC02 p99 / max | 565 / 565 | 560 / 565 |
| SC03 `b-r` | 0 | 0 |
| ERR SC02 / SC04 | 0 / 0 | 0 / 0 |
| `tx_sum` SC06 / SC07 | 3712 / 3711 | 3712 / 3753 |
| FIFO débordée (`STATUS[22]`) | — | 0 sur 21 instantanés |

Détection SC02 18 → 34, SC04 41 → 45, SC03 et SC01 50/50, zéro faux positif — sans
aucune ERR, donc sans l'artefact de timeout de `W_CAPDEBT`.

**Runs répétés, A/B, 2026-09-11 22:45–22:54** — même bitstream v10, même chargement
`capture_uart.sh -j`, sur une seconde machine : 7 campagnes `wfate1` (`170253`, `224519`,
`224645`, `224731`, `224757`, `224823`, `224849`) et 6 `wfate0` (`170057`, `225208`, `225234`,
`225301`, `225328`, `225354`). Toutes vont jusqu'à `END` avec le `CTRL` attendu, sans
`ATTENTION` ; partout zéro faux positif, SC03 et SC01 50/50, SC03 `b-r=0`, zéro ERR sur
SC02 et SC04.

| | `wfate0` ×6 | `wfate1` ×7 |
|---|---|---|
| SC02 TP / 50 | 18 à 30, moy. 23,3 | **34 à 48, moy. 39,3** |
| SC04 TP / 50 | 38 à 43, moy. 41,0 | **44 à 48, moy. 46,4** |
| `SUMMARY-TX` max SC02 / SC04 | timeout (65 6xx) sur 5 runs / sur 6 | ≤ 565 / ≤ 1241 |
| `W V- last` en aval de w2 | 9 à 11 / 21, dans chaque run | 0, dans chaque run |
| latence moyenne exacte SC06 / SC07 | 37,12–37,22 / 37,11–37,65 | 37,12–37,16 / 37,10–37,65 |

**Les plages sont disjointes** (SC02 30 < 34, SC04 43 < 44) : le gain de détection est
attribuable à `W_FATE`, pas au bruit d'un run. Coût en latence légitime : nul, sous le bruit.
Le lien avec les timeouts de `wfate0` est plausible mais **non vérifié itération par
itération**. `224849` a perdu sur l'UART des lignes de trace de SC01 (blocs `pre-ctrl`
incomplets, d'où `W V- last` 0/19) ; ses lignes `SUMMARY` et `STATUS_final` sont intactes.
`224519` a été lancé depuis un autre terminal que la série : ne jamais lancer deux captures
ou deux chargements JTAG à la fois, ils se partagent le câble et `/dev/ttyUSB0`.

Images (`payloads/` n'est pas versionné) : § 2, étape 2, avec
`-DARMOR_WSKID=1 -DARMOR_FRESH=1 -DARMOR_RHOLD=1 -DARMOR_WFATE=1`, en copiant
**`fw_payload.elf` et `fw_payload.bin`** dans `payloads/`. Campagne :

```sh
./2_build_HB.sh program
pkill -x hw_server
tools/capture_uart.sh -j payloads/fw_payload_v10_fresh1_wskid1_rhold1_wfate1.elf
```

**Bitstream v11 synthétisé et archivé le 2026-09-12** (`a402202`) : `CTRL[10] B_FATE`, un B
par écriture (§ 5, « Encore ouvert », et `armor/tb/README.md`, « Canal B »). WNS +0,177 ns
inchangé, 107 567 LUT et 73 385 bascules, soit +179 et +110 sur le v10. `check bench` dit
À JOUR. Images : `payloads/fw_payload_v11_fresh1_wskid1_rhold1_wfate1_bfate0.elf` et
`_bfate1.elf`.

**A/B sur carte, 2026-09-12 08:54 — `B_FATE` ÉCHOUE, NE PAS L'ACTIVER.**

| | `bfate0` (`results/bench_2026-09-12_085414.log`) | `bfate1` (`085533`) |
|---|---|---|
| `CTRL` relu | `0x331` | `0x731` |
| Campagne | jusqu'à `END` | **gelée dans SC04, vers l'itération 18** |
| `STATUS[24]`, file pleine | 0 | **1 (collant)** |
| SC02 / SC04 détectées | 34/50, 48/50 | 38/50 puis plus rien |

Le témoin `bfate0` reproduit exactement le v10 (SC02 34, SC04 48, SC03 et SC01 50/50, zéro
faux positif, latence 37,08 / 37,10) : **le v11 ne change rien tant que le bit est à 0.**

**Cause.** La file de sort ne fait que **16 entrées**, alors que SC04-MSI émet **48 écritures**
d'affilée (`MSI_REQS`) et SC02 seize (`STORM_REQS`), sans attendre leurs B. Il suffit que la
tête soit une écriture admise dont le B réel tarde : rien ne se dépile, les AW acquittés
s'empilent, et la poussée en trop est **perdue** — `bq_ovf_q` — au lieu d'être refusée. Le
compte est alors désynchronisé pour toujours ; au gel, le maître tient `b_ready` sans qu'aucun
B ne lui soit présenté (`B -R` en amont) et ARMOR n'en prend aucun en aval (`B --`), la tête
étant une écriture coupée dont le W-last ne viendra jamais.

**Le banc ne pouvait pas le voir** : son aval n'acceptait **qu'une écriture à la fois**
(sixième angle mort). Avec `DN_AWOUT` et `DN_BLAT`, ajoutés le 2026-09-12
(`armor/tb/README.md`), seize écritures en vol et 8 cycles de latence de B ne suffisent
toujours pas — la file monte à 2 sur 16. C'est la **lenteur du B**, pas le nombre
d'écritures, qui bloque la tête.

**Correctif écrit et validé au banc le 2026-09-12** : la file passe à **64** — au-dessus des
48 écritures de SC04-MSI — et, pleine, elle **refuse l'AW** (`aw_ready` à 0 au maître,
`aw_valid` coupé en aval) au lieu de perdre la poussée. Aval historique et aval réaliste :
0 B en trop, 0 manquant, 0 débordement, remplissage 1 et 14 sur 64, verdicts inchangés.
Le point qui débordait (48 écritures en vol, B à 200 cycles) ne déborde plus. Détail et
tableaux : `armor/tb/README.md`, « La file de 16 déborde sur carte ».

**Prochaine action** : synthétiser le **v12** (`XILINXD_LICENSE_FILE=/home/jc/Xilinx.lic
FORCE_FPGA=1 BENCH_PROFILE=1 ./2_build_HB.sh fpga --force`, ~42 min), l'archiver, puis
refaire l'A/B sur carte `bfate0` / `bfate1`. `STATUS[24]` doit rester à 0 et la campagne
aller jusqu'à `END` des deux côtés.

## 1. Mise en route

```sh
git clone --recurse-submodules git@github.com:prevotet/riscv-iommu-demo.git
cd riscv-iommu-demo
tools/bitstream.sh use bench     # réinstalle le .bit versionné dans build/hw/
tools/bitstream.sh check bench   # doit dire « À JOUR »
```

`check` compare une empreinte du RTL (`armor/SRC`, `armor/Include`,
`cva6-overlay`, plus le commit du sous-module `cva6`) à celle enregistrée dans
`bitstreams/*.provenance`. **S'il dit PÉRIMÉ, ne pas lancer de campagne** : un
`.bit` qui ne correspond pas au RTL produit des logs qu'on peut passer des
heures à réinterpréter. C'est arrivé le 2026-09-08.

Outils attendus sur la machine :

- **Vivado 2022.2** (synthèse, programmation, et `xsim` pour le banc). La **synthèse exige
  une licence** couvrant le `xc7k325t`, absent de l'édition gratuite : sans elle,
  `2_build_HB.sh fpga` échoue après les premières IP sur `ERROR: [Common 17-345] A valid
  license was not found for feature 'Synthesis'`. La licence est **nodelocked sur
  l'adresse MAC** : son `HOSTID` doit être celle de la machine, sans les deux-points
  (`cat /sys/class/net/<iface>/address`). Sur une VM, une licence émise pour une autre
  VM échoue — rencontré le 2026-09-11, le fichier portait le HOSTID de la machine
  d'origine ; il a fallu le régénérer sur le portail AMD pour cette MAC. Fichier hors
  des chemins par défaut : `XILINXD_LICENSE_FILE=<chemin>/Xilinx.lic`, sinon Vivado ne
  le voit pas ;
- la toolchain **`/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf-`** — à
  adapter dans les commandes si le chemin diffère ; `tools/load_jtag.sh` accepte
  `READELF=<chemin>` ;
- **OpenOCD ≥ 0.12** pour le chargement JTAG : `load_jtag.sh` appelle `/usr/bin/openocd`,
  `OPENOCD=<chemin>` sinon. Celui de Quartus (0.11) ne comprend pas la config ;
- **`dtc`** (paquet `device-tree-compiler`), pour le DTB chargé par JTAG ;
- les **fichiers de carte Digilent**, pour la synthèse seulement
  (`digilentinc.com:genesys2:part0:1.1`). Sans eux, `2_build_HB.sh fpga` s'arrête en
  6 s sur `ERROR: [Board 49-71]`, dès la première IP. Sans droits sur l'installation
  Vivado : `git clone https://github.com/Digilent/vivado-boards`, puis dans
  `~/.Xilinx/Vivado/Vivado_init.tcl` :
  `set_param board.repoPaths [list <clone>/new/board_files]`. Rencontré le 2026-09-11
  sur la seconde machine.

Même carte, même câblage : la **console** passe par l'adaptateur **FT232R séparé**
(`0403:6001`, en général `/dev/ttyUSB0`), le **JTAG** par l'USB de la Genesys2
(`0403:6010`). `capture_uart.sh` trouve le premier tout seul.

## 2. Chaîne complète

Utiliser **`2_build_HB.sh`** (hyperviseur + baremetal), jamais `1_build_HLB.sh`
qui construit la variante Linux : sa VM ajouterait du trafic parasite sur le bus
et sur l'UART pendant les mesures, et son `do_all` appelle `init_submodules`, ce
qui détruit les IP Vivado générées.

```sh
# 1. bitstream (~45 min) — seulement si le RTL a changé
BENCH_PROFILE=1 ./2_build_HB.sh fpga --force
tools/bitstream.sh save bench          # puis committer bitstreams/

# 2. guest de bench — À LA MAIN, les scripts ne propagent pas BENCH=1
cd bao-baremetal-guest
make clean                              # obligatoire : sources.mk change de fichier
make PLATFORM=cva6 \
     CROSS_COMPILE=/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf- \
     BENCH=1 ARCH_CPPFLAGS="-DBENCH_QUICK -DBENCH_TRACE_MMIO -DBENCH_NO_LHA_BG \
                            -DARMOR_WSKID=1 -DARMOR_FRESH=1 -DARMOR_RHOLD=1 \
                            -DARMOR_WFATE=1" \
     -j$(nproc)
# Les quatre ARMOR_* donnent la configuration de référence, validée sur carte le
# 2026-09-11 sur le bitstream v10 (CTRL relu 0x331). -DARMOR_WFATE=0 donne le témoin
# de W_FATE (0x131). Ne PAS mettre -DARMOR_WCAP=1 : il fait caler le maître jusqu'au
# timeout. Retirer tous les ARMOR_* donne le témoin historique, sur le même bitstream.
cd .. && cp bao-baremetal-guest/build/cva6/baremetal.bin build/guests/baremetal.bin

# 3. hyperviseur et firmware
./2_build_HB.sh bao && ./2_build_HB.sh opensbi

# 4. carte SD, puis FPGA, puis capture — DANS CET ORDRE
sudo dd if=opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin \
        of=/dev/sdX1 oflag=sync bs=1M status=progress
./2_build_HB.sh program
tools/capture_uart.sh

# 4 bis. SANS carte SD, par le JTAG de débogage de CVA6 — VALIDÉ SUR CARTE le
#        2026-09-11 14:19 (recette KERONEv2) : du lancement de la capture au
#        « ###### END » en moins d'une minute, contre le dd + la carte à déplacer
./2_build_HB.sh program
pkill -x hw_server                              # program en laisse un, qui tient le câble
tools/capture_uart.sh -j payloads/<image>.elf   # ouvre le port, PUIS charge ; pas de reset
```

**Pas de reset de carte en JTAG** : `load_jtag.sh` fait `reset halt`, charge, puis
`resume`. Avec `-j`, c'est la capture qui lance le chargement une fois la lecture
démarrée : l'en-tête ne peut plus être perdu. Avec deux terminaux il l'a été
(`results/bench_2026-09-11_143200.log`, capture ouverte trop tard). La sortie
d'OpenOCD va dans `<journal>.openocd`. `tools/load_jtag.sh` seul reste utilisable.

`load_jtag.sh` appelle `/usr/bin/openocd` (0.12) : celui de Quartus, souvent
premier dans le `PATH`, est en 0.11 et ne comprend pas la config. Le rebind de
`ftdi_sio` de `capture_uart.sh` n'a lieu que si **aucun** FT232R n'expose de tty :
avec l'adaptateur console branché, il ne gêne pas OpenOCD. Pour avoir un ELF,
copier `opensbi/build/platform/fpga/ariane/firmware/fw_payload.elf` à côté du `.bin`.

**Pièges de cette chaîne, tous rencontrés :**

- Après l'étape 2, n'appeler **que** `bao`, `opensbi`, `sdcard`, `program`.
  `all` ou `baremetal` recompilent `main.c` et écrasent `build/guests/baremetal.bin`
  **sans le signaler** : la campagne mesure alors le guest de démo.
- Vérifier que le bench est bien embarqué : `ls bao-baremetal-guest/build/cva6/*.o`
  ne doit montrer que `bench_runner.o` à la racine, pas `main.o`.
- **Programmer le FPGA AVANT d'ouvrir la capture.** Vivado prend le câble par
  libusb et détache `ftdi_sio` des deux canaux du FT2232 ; les `ttyUSB` ne
  reviennent pas seuls.
- La table GPT de la carte SD est déjà bonne : écrire directement sur la
  partition 1 évite de repartitionner 118 Go pour rien.
- Les logs de capture contiennent parfois des octets non ASCII. `grep` les
  déclare alors binaires et **renvoie silencieusement zéro résultat** : utiliser
  `grep -a`.

## 3. Lire un log de campagne

Dans l'ordre, avant toute interprétation :

1. `# ARMOR CSR magic` doit valoir la version attendue et **aucune ligne
   `ATTENTION`** ne doit suivre. Sinon le firmware et le bitstream sont
   désappariés et le reste ne vaut rien.
2. `# ARMOR arme : ENFORCE=…, W_SKID=…` — vérifier que c'est bien la
   configuration voulue. Deux images qui ne diffèrent que par un bit se
   confondent vite.
3. `# IT,<k>,…` — un digest par itération, imprimé **après** la fin de
   l'itération. La dernière ligne date donc le gel : c'est l'état d'entrée du
   lancement qui n'est jamais revenu.

Lignes produites : `ARMORLAT` (latences matérielles), `ARMORHW` (cycles,
transferts), `ARMORSTALL` (attentes par canal), `ARMORW` / `ARMORRETR`
(canal W, `bad_id`, retraits de VALID), et `ARMORSNAP` / `ARMORHS` / `ARMORDBG`
avant chaque lancement tracé.

## 4. Banc de simulation

```sh
./armor/tb/run_sim.sh 0            # aval sain
./armor/tb/run_sim.sh 1            # aval qui accepte mais ne répond jamais
./armor/tb/run_sim.sh 2            # aval qui n'accepte rien
DN_LAT=4 ./armor/tb/run_sim.sh 3   # campagne complète
OBS_CHECK=1 DN_LAT=4 ./armor/tb/run_sim.sh 3   # + contrôle croisé des compteurs
WSKID=1 DN_LAT=4 ./armor/tb/run_sim.sh 3       # + étage W actif
WSKID=1 FRESH=1 RHOLD=1 WFATE=1 BFATE=1 DN_LAT=4 ./armor/tb/run_sim.sh 3   # configuration v11
```

`DN_LAT` doit valoir **au moins 2** : à 0 le banc validait précisément ce sur
quoi la carte gelait.

`OBS_CHECK` est **désactivé par défaut**, et ce n'est pas de la prudence
excessive : ses quatre lectures CSR par pas suffisent à changer l'issue de SC03
et SC04. Une campagne de **vérification** et une campagne de **mesure** ne
peuvent pas être le même run.

Le banc ne modélise **ni l'IOMMU, ni le crossbar partagé, ni la contention
LHA/MHA**, et un seul accélérateur y est instancié. Il a validé du vide quatre
fois : vérifier ce qu'il ne modélise pas avant d'accuser le RTL.

## 5. Où en est l'enquête

**Mesuré et solide** — surcoût d'ARMOR sur trafic légitime : **2 cycles
d'attente de verdict pour 100 transactions**, zéro coupure, zéro blocage, zéro
retrait de VALID sur 900 itérations. Latence AXI matérielle **37 cycles**
(min 26). L'attente AW de 2 cycles n'existe qu'en amont (0 en aval) : c'est bien
ARMOR ; l'attente W de 38–46 cycles est identique des deux côtés, c'est l'aval.

Ne **pas** opposer ces 37 cycles aux ~275 des campagnes logicielles : le
matériel mesure une transaction AXI, le logiciel une itération d'accélérateur,
MMIO de sondage comprises. Deux colonnes, jamais une.

**Cause racine du gel de SC02-STORM** — `request_manager` retirait un `w_valid`
déjà présenté en aval (violation AXI4). Corrélation mesurée sans exception sur
901 itérations : 900 à `cut=0` sans aucun retrait, 1 à `cut=4` avec quatre
retraits sur le canal W. La règle en cause était le correctif du « W orphelin »
du 2026-09-09 : il avait échangé une violation contre une autre.

**Correctif, VALIDÉ SUR CARTE** — `armor/SRC/w_skid_buffer.sv`, derrière `CTRL[4]`.
La coupure est décidée **à la capture** ; un beat entré est tenu jusqu'à son
`ready` ; et le `ready` rendu au maître est celui de l'étage, jamais celui de
l'aval ni un 1 fabriqué. **Les deux côtés doivent bouger ensemble** — une première
tentative qui tenait le `VALID` sans corriger le `ready` avait fait passer les
retraits de 1 à 33.

Deux runs indépendants : SC02, SC04 et SC03 font **50/50 itérations chacun**,
coupure active sur 49 à 50 d'entre elles, **zéro retrait W, aucun gel**. SC04 et
SC03 n'avaient jamais été atteints sous `ENFORCE=1`. Coût : +1 cycle sur une
écriture légitime, +75 LUT, +134 bascules, marge de timing inchangée.
`w_owed_max` passe de 1 à 2 — preuve que l'étage est bien dans le chemin.

## 5 bis. `FRESH_VERDICT` adopté, VALIDÉ SUR CARTE

**2026-09-11, `results/bench_2026-09-11_105615.log`** — bitstream v7, `CTRL` relu
`0x31` (ENFORCE + W_SKID + FRESH). **La campagne va jusqu'à `###### END`**, pour la
première fois sous `ENFORCE=1`.

| scénario | TP / N | FP | retraits de VALID |
|---|---|---|---|
| SC06, SC07 (légitime) | — | 0 | aucun |
| SC02-STORM | 21 / 50 | 0 | aucun |
| SC04-MSI | 41 / 50 | 0 | aucun |
| SC03-OUTS | 50 / 50 | 0 | `ar=11`, `b-r=73` (voir « Encore ouvert ») |
| **SC01-SPOOF** | **50 / 50** | 0 | **aucun** |

**SC01 ne gèle plus** : 50 itérations, `req_up=50 req_dn=0`, aucune requête usurpée
n'atteint l'aval. Il gelait à la première itération les 08 et 09/09. SC02, SC04 et
SC03 restent dans la plage des deux runs v6 `wskid1`.

**Témoin `fresh0_wskid1`** (`results/bench_2026-09-11_124113.log`, `CTRL` relu
`0x11`) : même bitstream, même firmware, **seul FRESH diffère**.

| mesure | sans FRESH | avec FRESH |
|---|---|---|
| SC01 | **gèle à la 1re itération** | 50/50, aucun gel |
| SC06, latence moyenne exacte | 37,03 | 37,12 (+0,09) |
| SC07, latence moyenne exacte | 37,54 | 37,53 (−0,01) |
| latence minimale | 26 | 28 (+2) |
| SC03, retraits B/R (cause du 1er) | 16 (vide) | 73 (`!verdict`) |

Trois conclusions, par A/B et non par raisonnement :

- **C'est FRESH qui corrige le gel de SC01.**
- **Son coût moyen est sous le bruit d'un run (~0,1 cycle) ; +2 cycles au pire**, sur
  les transactions les plus rapides. Ailleurs, le retard d'AW se superpose à
  l'attente du canal W en aval (~40 cycles).
- **Il multiplie par ~4 les retraits B/R de SC03**, un défaut qui préexistait (voir
  « Encore ouvert »).

SC01 tourne encore **en dernier**, derrière l'OUTS parasite de SC03 : le replacer
avant SC02 pour des verdicts propres.

`CTRL[5] FRESH_VERDICT` supprime le retrait d'AW de **SC01**. Le défaut : `Device_ID_write_enable_o` est registré, donc
`verdict_known_q` ne retombe qu'à T+2 — pendant T et T+1 l'adresse est jugée sur
le verdict de la requête **précédente**. Aujourd'hui rien ne passe (`req up=8
dn=0` sur SC01), mais c'est la **lenteur de l'IOMMU** qui referme la fenêtre, pas
la logique.

Matrice mesurée au banc, `DN_LAT=4`, campagne 10 OK / 1 ÉCHEC partout :

| config | retrait AW SC01 | retrait AW SC04 | surcoût légitime |
|---|---|---|---|
| défaut | 1 | 1 | 0 cy |
| `FRESH` | **0** | 1 | **+2 cy** |
| `FRESH`+`WSKID` | 0 | 1 | +2 cy |
| `FRESH`+`WSKID`+`TXBLOCK` | 0 | **4** | +2 cy |

**Décision prise le 2026-09-11 : `FRESH` est adopté**, sans condition de seuil. On
accepte le surcoût sur chaque transaction légitime en échange d'une garantie
d'identité qui ne dépend plus d'un accident de timing. C'est aussi le seul
correctif prêt pour le gel de SC01. Le « 0 cycle » d'avant venait de ce qu'ARMOR
laissait l'adresse sortir avant de savoir si elle était légitime.

**Deux chiffres à ne pas confondre.** Le « 2 cycles d'attente pour 100
transactions » de la section 5 a été mesuré **sans** `FRESH`. Avec, l'attente de
verdict passe à **2 cycles par transaction** (`cyc_hold` 2 → 200 sur 100, mesuré sur
carte). Mais la **latence moyenne** ne prend qu'**au plus 0,12 à 0,53 cycle** : sur
carte, le retard d'AW se superpose en grande partie à l'attente du canal W en aval.
Le banc, dont l'aval est rapide, donnait +2 cycles partout. L'article publie les
valeurs de la carte, mesurées par A/B contre le témoin `FRESH=0` (tableau
ci-dessus) : ~0,1 cycle en moyenne, +2 au pire.

`CTRL[6] TX_BLOCK` est **câblé mais nuisible seul** (retraits AW de SC04 : 1 → 4).
Il ne redevient nécessaire qu'avec un futur étage sur AW. **Ne pas l'activer.**

Configuration de référence : **`W_SKID` + `FRESH_VERDICT`, sans `TX_BLOCK`**, soit
`-DARMOR_WSKID=1 -DARMOR_FRESH=1` à la compilation du guest. Les deux valent 0 par
défaut, exprès : un témoin se construit sans eux. Au boot, la ligne
`# ARMOR CTRL relu` donne la configuration réellement retenue par le matériel.

**Bitstream v7 synthétisé et archivé le 2026-09-11** : WNS +0,177 ns (inchangé),
107 287 LUT et 73 231 bascules, soit +4 et +2 par rapport au v6. `check bench` dit
À JOUR. Images de boot : `payloads/fw_payload_v7_fresh1_wskid0.bin` (FRESH seul,
à passer en premier pour isoler son coût) puis `_wskid1.bin` (configuration de
référence).

**Encore ouvert :**

- **l'étage W décale le canal W — DÉMONTRÉ au banc, `CTRL[7] W_CAPDEBT` (MAGIC v8,
  `d172928`) le corrige mais INTRODUIT DES BLOCAGES JUSQU'AU TIMEOUT.** Sur carte, même
  bitstream, chargement JTAG :

  | | `wcap0` (`141906`) | `wcap1` (`143242`) |
  |---|---|---|
  | `W V- last` bloqué en aval w2 | **11 / 21** instantanés | **0 / 21** |
  | SC06 / SC07 `tx_sum` | 3710 / 3754 | 3712 / 3766 |
  | écart / fantômes / orphelins W | 0 / 0 / 0 | 0 / 0 / 0 |
  | SC02 : DONE / ERR, `SUMMARY-TX` Lp50 | 30 / 0, 514 | **0 / 17, 65 676** |
  | SC04 : DONE / ERR | 8 / 0 | 0 / 2 |

  **Le « SC02 détecté 50/50 » sous `wcap1` est un ARTEFACT, à ne pas publier** : la moitié
  des transactions finissent sur le timeout de l'accélérateur (`TIMEOUT_CYCLES` = 65 536),
  et le firmware compte `ST_ERROR` comme une attaque observée. Mécanisme : pendant un
  blocage, ARMOR fabrique `aw_ready` ; si le blocage retombe avant que le maître présente
  le W de cette adresse coupée, `W_CAPDEBT` refuse — à raison — de le capturer, mais rien
  ne l'absorbe, et le maître attend jusqu'à son timeout. Sans le correctif ce W était
  capturé et partait avec l'adresse suivante : pas de blocage, mais une donnée mal
  adressée. **Correctif complet à concevoir** : suivre CHAQUE transaction — pour chaque
  AW acquitté au maître, retenir s'il a été admis en aval ou coupé (petite FIFO de bits,
  dans l'ordre AXI) — et absorber les W des AW coupés même après la fin du blocage.

  **Reproduit au banc** (`DN_WGATE=1`, `DN_WLAT` 4 et 8 — à 40 SC02 n'y est jamais détecté —,
  après correction de SC08 qui tournait sans aucune option). Photographie au cycle de chaque
  timeout, identique sur les 24 relevées : accélérateur en état **W, beat 0**, `w_valid=1
  w_ready=0`, blocage retombé, `w_owed=0 cap_owed=0`. **La cause est la même avec et sans
  `W_CAPDEBT`** (timeouts à `DN_WLAT=8` : SC02 3 et 4, SC04 4 et 4) ; sans lui, l'étage est
  plein d'un beat d'une autre écriture coupée et 757 beats partent mal adressés, avec lui
  l'étage est vide et aucun. `W_CAPDEBT` répare donc l'intégrité, et ni l'un ni l'autre ne
  sait absorber le W d'un AW coupé hors blocage.

  **`CTRL[9] W_FATE` (MAGIC v10), validé au banc, VALIDÉ SUR CARTE le 2026-09-11 (§ 0).** Une FIFO de 4
  bits garde le sort de chaque AW acquitté au maître — admis en aval dans le même cycle,
  ou coupé — et le W d'un AW coupé est absorbé (`w_valid` coupé en aval, `w_ready = 1`
  au maître) quel que soit l'état du blocage. Supplante `W_CAPDEBT`.

  | aval banc | timeouts en état W, avant → `W_FATE` | itération SC02 / SC04 | beats d'une autre écriture |
  |---|---|---|---|
  | `DN_WLAT=4` | SC08-m4 31 → **0**, SC02 4 → **0**, SC04 2 → **0** | 109 / 246 cy | **0** / 1778 |
  | `DN_WLAT=8` | SC08-m4 31 → **0**, SC02 4 → **0**, SC04 4 → **0** | 110 / 241 cy | **0** / 1772 |
  | `DN_WLAT=40` | — | 672 / 1396 cy | **0** / 2538 |
  | historique | — | 353 / 244 cy | **0** / 1773 |

  `OBS_CHECK` 0 défaut, verdicts inchangés. **Deux points ouverts** : (1) avec l'aval
  historique, SC02 finit UNE fois en timeout en état **DRAIN** (14 B reçus sur 16) —
  **cause établie au banc le 2026-09-11, corrigée par `CTRL[10] B_FATE` (MAGIC v11), non
  synthétisé** : le canal B n'était pas compté par écriture. Pendant un blocage un SLVERR
  est présenté en continu et l'accélérateur en prend un par cycle (2674 B en trop en
  configuration de référence) ; après le blocage, le B d'un AW coupé ne vient jamais (14
  manquants). Les premiers masquaient les seconds, sauf sans `RHOLD`, où s'ajoutaient
  815 B perdus. Sous `B_FATE` : 0 en trop, 0 manquant, 0 perdu, verdicts inchangés, sur
  les avals historique, réaliste et `DN_WLAT=8`, et sous `OBS_CHECK` — voir
  `armor/tb/README.md`, « Canal B » ; (2) à `DN_WLAT=40`, SC04 dure en
  moyenne 1396 cycles sans aucun timeout (775 à 837 avant) — à comprendre ; Sur carte,
  dans les quatre runs `W_SKID=1` (v6 ×2, v7 ×2), un beat W reste présenté en aval
  dès SC02 et jusqu'à la fin, avec `w_owed=0` et `w_pending=0`
  (`ARMORHS,pre-ctrl,w2,dn` : `W V- last`) ; il n'est pas la cause du gel de SC01.
  Mécanisme : pendant un blocage, `response_manager` fabrique `aw_ready`, l'écriture
  suivante coupée envoie son W pendant que le dernier beat de la précédente attend
  encore dans l'étage (40 à 45 cycles en aval), et la dette W, comptée **en aval**,
  autorise sa capture. Ce beat part ensuite avec l'adresse légitime suivante.
  **Aucun compteur matériel ne le voit.** Il a fallu deux ajouts au banc : un aval
  réaliste pour W (`DN_WGATE=1 DN_WLAT=40`, cinquième angle mort) et un contrôle
  d'appariement adresse/donnée — voir `armor/tb/README.md`.

  | aval banc | `WCAP` | beats d'une autre écriture | fantômes | `OBS_CHECK` |
  |---|---|---|---|---|
  | réaliste | 0 | **147** (1er : 63 beats plus vieux) | 0 | — |
  | réaliste | 1 | **0** / 2408 | 0 | 0 défaut |
  | historique | 1 | **0** / 1586 | 0 | — |

  Verdicts de campagne inchangés (8/3 aval réaliste, 10/1 historique). Au passage,
  le détecteur de fantômes — banc ET `cnt_w_ghost_q` — donnait 187 fausses alarmes
  sous `WCAP=1` : handshakes aval et maître sont découplés par l'étage. Il est
  désormais inhibé quand `W_SKID=1`. **À valider sur carte après synthèse** ;
- retrait de VALID résiduel sur **AW** (cause `block_req` : verdict frais et bon,
  puis verdict volumétrique qui arrive après). Demanderait un étage sur AW de la
  même forme que celui de W — **pas** `TX_BLOCK` ;
- **retrait de `b_valid`/`r_valid` par `response_manager` — troisième site, corrigé
  par `CTRL[8] RESP_HOLD` (MAGIC v9), VALIDÉ SUR CARTE le 2026-09-11.** Même bitstream v9,
  chargement JTAG par `capture_uart.sh -j` : `rhold0` (`results/bench_2026-09-11_151005.log`)
  SC03 `b-r=54`, `rhold1` (`151516`, `CTRL 0x131`) **`b-r=0`** ; latence légitime inchangée
  (`tx_sum` SC06/SC07 3710/3766 → 3712/3759), détection inchangée (SC02 25→24, SC04 43→41,
  SC03 et SC01 50/50), zéro faux positif. Seul écart : ERR de SC03 3 → 7 (retraits AR sans
  cause, timeouts de l'accélérateur), dans la plage habituelle de 3 à 11 — non attribuable
  sur un run. Sur
  carte, SC03 : `b-r` = 16 et 11 en v6 `wskid1`, **73** en v7 avec `FRESH` (cause du
  premier retrait : vide → `!verdict`). Les branches de `response_manager` sont des
  fonctions pures de l'état courant : une réponse présentée sans `ready` retombe dès
  que la branche change — SLVERR fabriqué à la fin d'un blocage, ou R **réelle** à
  l'ouverture d'une attente de verdict (d'où l'effet de `FRESH`, qui en ouvre une à
  chaque front). Sous `RESP_HOLD`, toute réponse présentée est verrouillée, charge
  utile comprise, jusqu'à son `ready` ; tant qu'une réponse *fabriquée* est tenue,
  aucune réponse réelle n'est prise en aval. Banc, aval réaliste : SC03 `b/r` **8 →
  0**, appariement W, `OBS_CHECK` et verdicts inchangés ; aval historique 10/1.
  L'attente laisse aussi passer les réponses de l'aval au maître : **précaution** contre
  une perte lue dans le RTL, **jamais observée** (détecteur « réponses perdues » à 0 sur
  toutes les campagnes). Les `ar=8` qui restent sur SC03 au banc sont le timeout de
  l'accélérateur lui-même (cause vide, 2031 cycles), pas ARMOR ;
- `MAX_REQ_PER_WINDOW = 8` sur une fenêtre de 100 cycles est hors d'atteinte à
  la latence réelle de l'aval (37 cycles par transaction) : SC02 n'est détecté
  que par intermittence ;
- profil DEMO cassé : `FLOW_WINDOW_C` vaut 100 en BENCH et 50 000 en DEMO pour
  le même seuil, donc le trafic légitime y est bloqué comme une tempête ;
- SC03-OUTS échoue en simulation dès `DN_LAT = 2` : `req_fire` compte des
  **fronts** de handshake et non des transferts, et apparie le `valid` du maître
  au `ready` de l'aval.

## 6. Ce qui n'est pas dans le dépôt

- **`payloads/`** est ignoré : les images de boot se reconstruisent en trois
  minutes avec la section 2.
- Les **notes de travail** (27 fichiers) vivent dans
  `~/.claude/projects/<projet>/memory/` sur la machine d'origine. Elles ne
  suivent pas le clone. Ce document en reprend l'essentiel opérationnel, mais
  pas le détail des impasses.
- Les sorties Vivado (`cva6/corev_apu/fpga/work-fpga/`) ne sont pas versionnées ;
  seul le `.bit` l'est, via `tools/bitstream.sh`.
