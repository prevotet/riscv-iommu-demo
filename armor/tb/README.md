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
./run_sim.sh all      # les trois

BUG=1   ./run_sim.sh 0   # rejoue le défaut resp_t/resp_slv_t (non-régression)
WAVES=1 ./run_sim.sh 1   # produit en plus work/tb_accel_armor.vcd
```

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
de cycles coûte l'IOMMU ». Un seul accélérateur est instancié, donc les
scénarios de contention (SC08 low-and-slow, blocage en tête de file) restent
hors de portée. Le comportement sur carte après ce correctif n'est pas encore
vérifié.
