# Banc de simulation ARMOR — `accel_wrap` + `wrapper` + aval comportemental

Banc xsim minimal pour déboguer le chemin de données de l'accélérateur sans
passer par un bitstream. Sur carte, chaque hypothèse coûtait une
recompilation + un flash + un reboot pour un bit d'information ; ici tous les
signaux sont visibles en quelques secondes.

## Lancer

```sh
./run_sim.sh 0        # aval sain          — contrôle, doit atteindre DONE
./run_sim.sh 1        # aval qui accepte AW/AR mais ne renvoie jamais B ni R
./run_sim.sh 2        # aval qui n'accepte rien
./run_sim.sh 3        # campagne : les six scénarios de bench_runner.c
./run_sim.sh all      # les quatre

BUG=1   ./run_sim.sh 0        # rejoue le défaut resp_t/resp_slv_t (non-régression)
PROFILE=demo ./run_sim.sh 3   # profil DEMO au lieu de BENCH
WAVES=1 ./run_sim.sh 1        # produit en plus work/tb_accel_armor.vcd
```

Le banc compile avec `BENCH_PROFILE` par défaut, comme le bitstream de
campagne. Ce n'est pas un détail : voir plus bas.

`xvlog`/`xelab`/`xsim` viennent de Vivado 2022.2 ; le script sourcera
`settings64.sh` tout seul si `xvlog` n'est pas dans le `PATH` (surcharger avec
`VIVADO_SETTINGS=<chemin>`). Ni verilator ni iverilog ne sont installés sur
cette machine.

## Ce que le banc a établi

**La cause racine du « zéro verdict DONE ».** `wrapper.resp_wrapper_iommu_i`
est déclaré `resp_slv_t` (88 bits, identifiants sur 6 bits) mais
`ariane_peripherals_xilinx.sv` y raccordait un `resp_t` (84 bits, identifiants
sur 4 bits). SystemVerilog complète alors par des zéros du côté MSB, ce qui
décale tous les champs :

| champ vu par ARMOR | reçoit réellement |
|---|---|
| `aw_ready`, `ar_ready`, `w_ready`, `b_valid` | **0 en permanence** |
| `b.id` | `{aw_ready, ar_ready, w_ready, b_valid, b.id[3:2]}` |
| `r_valid` | `b.resp[0]` — nul pour `OKAY` comme pour `SLVERR` |
| `r.data` | `r.data` décalé de 4 bits |

ARMOR ne voyait donc jamais l'aval accepter quoi que ce soit ni répondre, et
l'accélérateur en amont non plus. Aucune transaction ne pouvait aboutir, en
lecture comme en écriture, quel que soit l'état de l'IOMMU, de la DDT ou du
bit ENFORCE — ce qui explique que toutes ces pistes aient été éliminées une à
une sans que le comportement change.

Mesures du scénario 0 (aval idéal), avant et après correction :

| | AR émis | beats R | verdict | durée |
|---|---|---|---|---|
| `BUG=1` (l'ancien câblage) | 223 | 1784 | `done+error` (timeout) | 21,5 ms |
| corrigé | 1 | 8 | `done`, `error=0` | 1,7 µs |

L'accélérateur maintenait `ar_valid` indéfiniment faute de voir son `ar_ready`,
et l'aval comptait une nouvelle requête à chaque cycle : d'où les 223 rafales
pour une seule lecture de 64 octets.

**Le gel du CPU était une conséquence, pas un défaut séparé.** Une fois la
largeur corrigée, les scénarios 1 et 2 — aval complètement mort — laissent les
deux ports de configuration parfaitement vivants : l'accélérateur part en
timeout proprement et le CPU continue de lire `STATUS` et `MAGIC`. L'absence de
timeout dans les FSM `cw_state_q`/`cr_state_q` de `accel_wrap` et
`w_state_q`/`r_state_q` du wrapper reste une fragilité réelle, mais ce n'est
pas ce qui figeait la campagne.

**La campagne discrimine enfin** (scénario 3, `BENCH_PROFILE`, aval sain,
`ENFORCE=1`, 8 itérations par scénario, verdict = `{MSI, OUTS, STORM, BANNED,
BLOCKED}`) :

| scénario | mode | latence moy. | `fail_cnt` | verdict |
|---|---|---|---|---|
| LEGIT-lect légitime lecture | 0 | 16 cy | 0 | `00000` |
| LEGIT-ecr légitime écriture | 0 | 17 cy | 0 | `00000` |
| SC01-SPOOF | 1 | 515 cy | 3 | `00011` BANNED |
| SC02-STORM | 4 | 55 cy | 3 | `00111` STORM |
| SC04-MSI | 6 | 151 cy | 3 | `10111` MSI |
| SC03-OUTS | 5 | 79 cy | 3 | `01111` OUTS |
| SC08 low-and-slow | 4 / 0 | — | — | voir plus bas |

Chaque attaque lève son bit et **le trafic légitime n'en lève aucun** — les
faux positifs en nappe des campagnes sur carte ont disparu. Les latences sont
du même ordre que l'implémentation de référence (~1450 cy), là où toutes les
mesures précédentes étaient bloquées à `TIMEOUT_CYCLES`.

### SC08 low-and-slow mesure l'inverse de ce qu'il annonce

`run_sc08()` appelle `fire_one('M', 4, ...)`, or **le mode 4 est le mode
tempête** : il émet `STORM_REQS = 16` requêtes par appel. Les 7 de `LAS_BURST`
ne sont donc pas 7 requêtes mais 7 × 16 = 112 par salve, très au-dessus du
seuil de 8 — alors que le commentaire du scénario dit explicitement « on envoie
K AW », `LAS_BURST 7 /* sous le seuil de 8 */`.

Les deux variantes, jouées à salve et écart identiques (12 salves × 7, gap
200 cy > `FLOW_WINDOW_C` = 100) :

| variante | requêtes/salve | passées | bloquées | verdict |
|---|---|---|---|---|
| telle qu'écrite (mode 4) | 112 | 0 | 84 | `00101` STORM |
| conforme au commentaire (mode 0) | 7 | 84 | 0 | `00000` |

L'évasion — la limite intéressante et publiable des détecteurs à fenêtre
glissante — est parfaitement obtenable, mais seulement en mode 0. En mode 4 le
scénario ne démontre rien qu'SC02 ne démontre déjà.

### Le bannissement contamine tout ce qui suit dans les 2 ms

`security_monitor` maintient `block_ip_o` pendant `BLOCK_DURATION` =
`BLOCK_DURATION_C` = 100 000 cycles, soit ~2 ms à 50 MHz, et **aucun CSR ne
l'efface** : `STICKY_CLR` ne vide que le registre collant, `CNT_CLR` que les
compteurs. `failure_count` reste d'ailleurs à 3 pour le reste de la campagne.

Le banc le mesure : `LEGIT-apres01` rejoue exactement le trafic de
`LEGIT-ecr`, mais juste après le spoof.

| | verdict | err |
|---|---|---|
| LEGIT-ecr, wrapper vierge | `00000` | 0/8 |
| LEGIT-apres01, après SC01 | `00011` BANNED | 8/8 |

Conséquence pour la campagne sur carte : dans l'ordre de `bench_runner.c`
(SC01, SC02, SC04, SC06, SC07, SC08, SC03), SC02 et SC04 démarrent forcément
dans cette fenêtre de 2 ms, et les premières itérations de SC06 peuvent y être
encore. C'est une source de faux positifs indépendante de tout défaut de
détecteur. Les scénarios légitimes doivent être joués **avant** tout spoof, ou
espacés de plus de 2 ms.

Deux choses à savoir pour interpréter ces lignes :

- **Une attaque ne se détecte pas en une transaction.** Le bannissement demande
  `MAX_FAILURES = 3` comparaisons d'identifiant fautives. Avec une seule
  itération, SC01-SPOOF ne lève aucun bit et part en timeout : la transaction
  n'est ni bloquée ni laissée passer, elle est simplement retenue. C'est
  pourquoi `bench_runner.c` lance `N_ATK` itérations, et pourquoi le banc en
  fait 8.
- **`err` n'est pas un timeout.** `error_q` se lève aussi sur le SLVERR fabriqué
  par ARMOR, qui revient en quelques cycles. C'est le cas des `err 8/8` des
  lignes d'attaque, dont la latence reste faible.

**Le profil compte autant que le RTL.** En profil DEMO, `FLOW_WINDOW_C` vaut
50 000 cycles pour le même `MAX_REQ_PER_WINDOW = 8` : neuf transactions
légitimes en moins d'une milliseconde suffisent alors à déclencher STORM.
`PROFILE=demo ./run_sim.sh 3` le montre — SC06 et SC07 passent à `00101`
(BLOCKED + STORM) sans qu'une ligne de RTL ait changé. Toute campagne jouée sur
un bitstream DEMO produira des faux positifs de tempête sur le trafic normal,
quel que soit l'état des détecteurs.

## Structure

Le banc instancie la chaîne réelle, pas un modèle :

```
TB (maître AXI) --cfg--> accel_wrap --dma--> wrapper --out--> aval comportemental
TB (maître AXI) --csr----------------------> wrapper
```

Le chemin CSR **ne traverse pas ARMOR** : le CPU attaque `accel_wrap.axi_cfg`
via le XBAR et le port CSR du wrapper directement, ARMOR n'étant que sur le
chemin DMA. Les deux ports sont donc pilotés par le banc, et chaque accès MMIO
est borné par un garde-fou de 500 cycles : sans lui, un handshake perdu fige la
simulation exactement comme il fige le CPU.

La glue interface↔structs est recopiée telle quelle de
`cva6-overlay/corev_apu/fpga/src/ariane_peripherals_xilinx.sv` — c'est du
boilerplate où une faute de frappe se paie cher.

`TIMEOUT_CYCLES` de l'accélérateur est ramené de 65536 à 2000 par paramètre
d'instanciation, sinon la simulation dure inutilement longtemps.

## Limites

L'aval ne modélise pas la latence de l'IOMMU ni le multiplexeur 2:1 partagé
entre LHA et MHA : le banc répond à « qui cale et pourquoi », pas à « combien
de cycles coûte l'IOMMU ». Les latences ci-dessus sont donc celles d'ARMOR seul,
non comparables telles quelles au coût mesuré sur carte.

Un seul accélérateur est instancié : le banc ne peut donc pas distinguer le
baseline LHA (SC06) du baseline MHA (SC07), et ses deux pas légitimes sont
nommés par leur sens — `LEGIT-lect` et `LEGIT-ecr`. Les deux sens comptent :
ils exercent des chemins de réponse différents, R pour la lecture et B pour
l'écriture, et c'est le retour du B qui manquait avant le correctif de largeur.

L'accélérateur porte `STREAM_ID = 2` — le MHA, celui que la
campagne attaque. `SPOOF_STREAM_ID` vaut `24'd1` par défaut et n'est surchargé
nulle part, donc le mode 1 n'usurpe réellement un identifiant que depuis un
accélérateur dont le `STREAM_ID` diffère de 1 : le jouer sur le LHA ne
prouverait rien. Les scénarios de contention (SC08 low-and-slow, blocage en
tête de file) restent hors de portée faute du second accélérateur et du
multiplexeur.

Le comportement sur carte après ces correctifs n'est pas vérifié : la Genesys2
n'est toujours pas détectée.
