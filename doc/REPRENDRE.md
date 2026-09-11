# Reprendre le travail ARMOR sur une autre machine

État au 2026-09-11 au soir, branche `testbench`. Ce document existe parce que le
README amont ne dit rien de la chaîne de bench, et que tout le reste vivait dans
les messages de commit.

**Bitstream archivé : v8** (`W_CAPDEBT`). **RTL de l'arbre : v9** (+ `RESP_HOLD`,
validé au banc, jamais synthétisé). `tools/bitstream.sh check bench` dit donc
PÉRIMÉ, et c'est normal : resynthétiser avant toute campagne qui a besoin de
`CTRL[8]`. Les campagnes v8 se jouent sur le bitstream archivé
(`tools/bitstream.sh use bench`).

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

Toolchain attendue : Vivado 2022.2, et
`/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf-` — à adapter dans
les commandes ci-dessous si le chemin diffère.

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
                            -DARMOR_WSKID=1 -DARMOR_FRESH=1" \
     -j$(nproc)
# Les deux ARMOR_* donnent la configuration de référence (section 5 bis).
# Les retirer donne le témoin historique, sur le même bitstream.
cd .. && cp bao-baremetal-guest/build/cva6/baremetal.bin build/guests/baremetal.bin

# 3. hyperviseur et firmware
./2_build_HB.sh bao && ./2_build_HB.sh opensbi

# 4. carte SD, puis FPGA, puis capture — DANS CET ORDRE
sudo dd if=opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin \
        of=/dev/sdX1 oflag=sync bs=1M status=progress
./2_build_HB.sh program
tools/capture_uart.sh

# 4 bis. SANS carte SD, par le JTAG de débogage de CVA6 — NON TESTÉ SUR CARTE
#        (recette reprise de KERONEv2 ; essai à blanc seulement, le 2026-09-11)
./2_build_HB.sh program
pkill -x hw_server                       # program en laisse un, qui tient le câble
tools/capture_uart.sh                    # autre terminal : attendre qu'il écoute
tools/load_jtag.sh payloads/<image>.elf  # ELF : ~8 s ; un .bin prend ~2 min
```

`load_jtag.sh` appelle `/usr/bin/openocd` (0.12) : celui de Quartus, souvent
premier dans le `PATH`, est en 0.11 et ne comprend pas la config. L'ordre compte :
`capture_uart.sh` peut recharger `ftdi_sio`, et lancé après OpenOCD il lui
arracherait le câble. Pour avoir un ELF, copier
`opensbi/build/platform/fpga/ariane/firmware/fw_payload.elf` à côté du `.bin`.

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

- **l'étage W décale le canal W — DÉMONTRÉ au banc, corrigé par `CTRL[7]
  W_CAPDEBT` (MAGIC v8), validé en simulation, SYNTHÉTISÉ en v8 (`d172928`), À
  VALIDER SUR CARTE** avec `payloads/fw_payload_v8_fresh1_wskid1_wcap0` puis `_wcap1`. Sur carte,
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
  par `CTRL[8] RESP_HOLD` (MAGIC v9), validé au banc, PAS ENCORE SYNTHÉTISÉ.** Sur
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
