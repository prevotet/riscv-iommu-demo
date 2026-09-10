# Reprendre le travail ARMOR sur une autre machine

État au 2026-09-10, branche `testbench`. Ce document existe parce que le README
amont ne dit rien de la chaîne de bench, et que tout le reste vivait dans les
messages de commit.

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
     BENCH=1 ARCH_CPPFLAGS="-DBENCH_QUICK -DBENCH_TRACE_MMIO -DBENCH_NO_LHA_BG" \
     -j$(nproc)
cd .. && cp bao-baremetal-guest/build/cva6/baremetal.bin build/guests/baremetal.bin

# 3. hyperviseur et firmware
./2_build_HB.sh bao && ./2_build_HB.sh opensbi

# 4. carte SD, puis FPGA, puis capture — DANS CET ORDRE
sudo dd if=opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin \
        of=/dev/sdX1 oflag=sync bs=1M status=progress
./2_build_HB.sh program
tools/capture_uart.sh
```

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

**Correctif** — `armor/SRC/w_skid_buffer.sv`, derrière `CTRL[4]`, à 0 au reset.
La coupure est décidée **à la capture** ; un beat entré est tenu jusqu'à son
`ready` ; et le `ready` rendu au maître est celui de l'étage, jamais celui de
l'aval ni un 1 fabriqué. **À valider sur carte** : le banc n'a jamais reproduit
le retrait sur W. Protocole : `wskid0` doit reproduire `retr=0/0/4/0` et le gel,
`wskid1` doit donner `retr=0/0/0/0` et passer — plusieurs runs de chaque côté,
le point de gel s'étant promené sur six itérations différentes.

**Encore ouvert :**

- retrait de VALID sur **AW** : une première tentative d'inhibition a été
  réfutée (les retraits passaient de 1 à 33) ; le correctif juste doit traiter
  les deux côtés du handshake ensemble ;
- retrait de `b_valid`/`r_valid` dans la branche HOLD de `response_manager` :
  troisième site, jamais examiné ;
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
