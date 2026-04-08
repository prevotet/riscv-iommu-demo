# CLAUDE.md — riscv-iommu-demo / DPR HWICAP

## Projet

**Repo** : `github.com/prevotet/riscv-iommu-demo.git`
**Cible** : Genesys2 XC7K325T-2FFG900
**Outil** : Vivado 2022.2
**Script principal** : `2_build_HB.sh` (full build BAO+Linux+DPR)
**Script test DPR standalone** : `3_build_B.sh` / `3_build_B2.sh` (GDB automatisé)

---

## Architecture SoC

- **CVA6** RISC-V 64 bits, crossbar AXI 64 bits
- **RISC-V IOMMU** (rv_iommu)
- **BAO hypervisor** + Linux guest + DPR Manager guest (baremetal)
- **Deux accélérateurs DPR** (`accel_wrap #1` et `#2`) dans des zones reconfigurables

### Adresses clés

| Périphérique | Adresse base |
|---|---|
| ACCEL1 | `0x50000000` |
| ACCEL2 | `0x50001000` |
| HWICAP  | `0x40010000` |
| DDR bitstream accel1 | `0x81000000` |
| DDR bitstream accel2 | `0x81300000` |
| DPR Manager / Baremetal | `0x90000000` |

---

## Architecture DPR

### Zones reconfigurables (pblocks)

| Instance | STREAM_ID | Adresse cfg | Pblock |
|---|---|---|---|
| `gen_dma.i_accel1` | 1 | `0x50000000` | `pblock_accel1` (X0Y250:X71Y299) |
| `gen_dma.gen_accel2.i_accel2` | 2 | `0x50001000` | `pblock_accel2` (X72Y250:X145Y299) |

### RMs disponibles

| RM | accel1 ID | accel2 ID |
|---|---|---|
| `accel_A` | `0xDEAD_000001_AAAAAA` | `0xDEAD_000002_AAAAAA` |
| `accel_B` | `0xDEAD_000001_BBBBBB` | `0xDEAD_000002_BBBBBB` |
| `accel_default` | SLVERR | SLVERR |

---

## Configurations BAO

### `cva6-baremetal` — VM unique (test standalone)

- VM0 : baremetal (`baremetal.bin`) à `0x90000000`
- Accès direct à tous les périphériques

### `cva6-baremetal-linux` — Baremetal + Linux

- VM0 : baremetal à `0x90000000`
- VM1 : Linux (`linux-rv64-cva6.bin`), pa=`0x82400000`, va=`0x80200000`, 220 Mo
- IPC partagée : shmem[0] 64 Ko, adresse VA `0xF0000000`, IRQ 52

### `cva6-dpr-linux` — DPR Manager + Linux *(nouveau)*

Voir section dédiée ci-dessous.

---

## VM DPR Manager (`cva6-dpr-linux`)

### Principe

VM0 est un service baremetal dédié à la reconfiguration partielle. Elle a l'accès **exclusif** à l'HWICAP, aux accélérateurs et aux bitstreams en DDR. Les autres VMs (Linux…) passent par la mémoire partagée BAO pour demander une reconfiguration.

### Layout mémoire (pas de chevauchement)

| Plage physique | Usage | VM |
|---|---|---|
| `0x81000000` – `0x81700000` | Bitstreams partiels DDR | VM0 DPR Manager |
| `0x82400000` – `0x90000000` | Linux (220 Mo) | VM1 |
| `0x90000000` – `0x94000000` | Code DPR Manager (64 Mo) | VM0 |

### Périphériques VM0

| Périphérique | Adresse |
|---|---|
| UART (console debug) | `0x10000000` |
| APB Timer | `0x18000000` |
| AXI HWICAP | `0x40010000` |
| Accel1 | `0x50000000` |
| Accel2 | `0x50001000` |

### Protocole IPC (`dpr_ipc.h`)

Mémoire partagée BAO à `0xF0000000` dans chaque VM, structure `dpr_ipc_msg_t` :

| Champ | Direction | Description |
|---|---|---|
| `cmd` | Linux → DPR Mgr | `DPR_CMD_IDLE/RECONFIG/QUERY` |
| `accel_id` | Linux → DPR Mgr | `DPR_ACCEL_1` ou `DPR_ACCEL_2` |
| `bs_words` | Linux → DPR Mgr | Taille du bitstream en mots 32 bits |
| `status` | DPR Mgr → Linux | `IDLE/BUSY/DONE/ERROR` |
| `error_code` | DPR Mgr → Linux | Code d'erreur si `ERROR` |
| `cycles_hi/lo` | DPR Mgr → Linux | Durée de la reconfig en cycles |

**Séquence côté Linux (polling) :**
```c
dpr_ipc_msg_t *ipc = /* mmap 0xF0000000 */;
ipc->accel_id = DPR_ACCEL_1;
ipc->bs_words = 534818;
ipc->cmd      = DPR_CMD_RECONFIG;
while (ipc->status == DPR_STATUS_BUSY || ipc->status == DPR_STATUS_IDLE);
// lire ipc->status, ipc->error_code, ipc->cycles_*
ipc->cmd = DPR_CMD_IDLE;
```

**Note** : la notification d'interruption (IRQ 52) entre VMs nécessite le hypercall BAO `sbi_ecall(0x424F4F00, ...)`. Non implémenté dans le MVP — polling suffisant.

### Fichiers DPR Manager

| Fichier | Description |
|---|---|
| `bao-baremetal-guest/src/dpr_ipc.h` | Protocole IPC partagé (commandes, codes) |
| `bao-baremetal-guest/src/dpr_manager.c` | VM de service : boucle de polling + HWICAP |
| `vm-configs/cva6-dpr-linux/config.c` | Config BAO : DPR Manager (VM0) + Linux (VM1) |

---

## AXI HWICAP

### Registres (offset depuis `0x40010000`)

| Offset | Registre | Description |
|---|---|---|
| `0x100` | WF  | Write FIFO data |
| `0x104` | RF  | Read FIFO data |
| `0x108` | SZ  | Size register (12 bits, write-only) |
| `0x10C` | CR  | Control register |
| `0x110` | SR  | Status register |
| `0x114` | WFV | Write FIFO Vacancy (max=0x3F) |
| `0x118` | RFO | Read FIFO Occupancy |

### Bits CR (Xilinx embeddedsw SDK)

| Bit | Valeur | Description |
|---|---|---|
| 0 | `0x01` | `CR_WRITE` — déclenche écriture vers ICAP |
| 1 | `0x02` | `CR_READ`  — déclenche lecture depuis ICAP |
| 2 | `0x04` | `CR_FIFO_RST` — reset FIFO |

### Bits SR

| Bit | Description |
|---|---|
| 0 | `send_done` — écriture terminée |
| 1 | `hang` — ICAP bloqué |
| 2 | `eos` — End Of Startup |

### Mapping CDC VHDL (cr_i → domaine ICAP)

```
cr_i(0 to 4) = Bus2IP_Data(27 to 31)
cr_i(0) → Abort         (bit 4 CPU = 0x10)  ← PAS Send_wr !
cr_i(3) → Rnc(0)        (bit 1 CPU = 0x02)
cr_i(4) → Rnc(1)        (bit 0 CPU = 0x01)  ← CR_WRITE = 0x01
```

`Rnc="01"` (write) = `cr_i(3)=0, cr_i(4)=1` = `CR = 0x01`

---

## Conversion 64→32 bits : solution implémentée

### Cause racine

Le crossbar CVA6 est en 64 bits. Même si le CPU génère des `sw` (store word 32 bits), le crossbar encapsule les transactions en AXI 64 bits avec `wstrb=8'h0F`.

Le `xlnx_axi_dwidth_converter` attendait les deux beats 32 bits avant de libérer → WFV ne diminuait que tous les 2 mots (buffering).

### Solution appliquée

Remplacement du `xlnx_axi_dwidth_converter` par `axi2apb_64_32` + `apb_to_axilite`, comme pour UART/PLIC/Timer.

`axi2apb_64_32` gère correctement la sélection du mot 32 bits via `AWADDR[2]` et byte strobes, sans buffering.

Chaîne : `AXI 64b (crossbar) → axi2apb_64_32 → APB 32b → apb_to_axilite → AXI-Lite 32b → xlnx_axi_hwicap`

**Paramètres `axi2apb_64_32`** : utiliser `AxiAddrWidth`, `AxiDataWidth`, `AxiIdWidth`, `AxiUserWidth` (pas `ariane_axi::`).

---

## Fichiers modifiés / créés

### RTL

| Fichier | Modification |
|---|---|
| `cva6/corev_apu/fpga/src/ariane_peripherals_xilinx.sv` | HWICAP : `xlnx_axi_dwidth_converter` remplacé par `axi2apb_64_32` + `apb_to_axilite` |
| `cva6/corev_apu/fpga/src/apb_to_axilite.sv` | **Nouveau** — adaptateur APB esclave → AXI-Lite maître (machine d'états 5 états) |
| `cva6/corev_apu/tb/ariane_soc_pkg.sv` | `HWICAP=15`, `NB_PERIPHERALS=16`, `HWICAPBase=0x40010000` |
| `cva6/corev_apu/fpga/src/ariane_xilinx.sv` | `InclHWICAP=1'b1`, addr_map HWICAP |

### IP HWICAP (`xlnx_axi_hwicap`)

Paramètres TCL (`xilinx/xlnx_axi_hwicap/tcl/run.tcl`) :

```tcl
CONFIG.C_ICAP_EXTERNAL   {0}
CONFIG.C_DEVICE_ID       {0x03647093}   # XC7K325T
CONFIG.C_INCLUDE_STARTUP {1}            # STARTUPE2 interne, EOS géré en interne
CONFIG.C_OPERATION       {1}            # Pas de BUFGCTRL (horloge ICAP toujours active)
```

### Guests baremetal

| Fichier | Description |
|---|---|
| `bao-baremetal-guest/src/dpr_test.c` | Test DPR basique (standalone M-mode, sans BAO) |
| `bao-baremetal-guest/src/dpr_test_full.c` | Test DPR ping-pong — standalone OU single-VM sous BAO (`VARIANT=dpr_full`) |
| `bao-baremetal-guest/src/dpr_ipc.h` | **Nouveau** — protocole IPC DPR Manager ↔ Linux |
| `bao-baremetal-guest/src/dpr_manager.c` | **Nouveau** — VM service DPR (config cva6-dpr-linux) |
| `bao-baremetal-guest/src/sources.mk` | **Modifié** — `VARIANT=dpr_manager/dpr_full/dpr_client` sélectionne la source |

- `dpr_test_full.c` définit `void arch_init(){}` vide → **obligatoire dans tous les cas** (standalone ET sous BAO single-VM). Voir section `arch_init` override ci-dessous.
- `dpr_manager.c` n'override PAS `arch_init()` → utilise la version par défaut (PLIC init, S-mode IRQ). Sous BAO multi-VM avec Linux, le PLIC est nécessaire pour la communication inter-VMs.

### Configs BAO

| Fichier | Description |
|---|---|
| `vm-configs/cva6-baremetal/config.c` | Config 1 VM (baremetal seul) |
| `vm-configs/cva6-baremetal-linux/config.c` | Config 2 VMs (baremetal + Linux) |
| `vm-configs/cva6-dpr-linux/config.c` | **Nouveau** — Config 2 VMs (DPR Manager + Linux) |
| `vm-configs/cva6-dpr-baremetal/config.c` | **Nouveau** — Config 1 VM (DPR Manager + test fusionnés, `VARIANT=dpr_full`) |

---

## Workflow de build

### Build FPGA DPR

```bash
./2_build_HB.sh hwicap-setup          # une seule fois : intègre HWICAP dans le projet CVA6
FORCE_FPGA=1 DPR_MODE=static ./2_build_HB.sh fpga-dpr
RM=accel_A ./2_build_HB.sh fpga-dpr
RM=accel_B ./2_build_HB.sh fpga-dpr
```

### Build firmware DPR Manager + Linux

```bash
./2_build_HB.sh all-dpr
# équivalent à :
./2_build_HB.sh dpr-manager   # compile dpr_manager.bin (VARIANT=dpr_manager)
./2_build_HB.sh bao-dpr       # BAO avec config cva6-dpr-linux
./2_build_HB.sh opensbi-dpr   # OpenSBI avec payload bao-dpr.bin
```

### Build firmware DPR Single VM (DPR Manager + test fusionnés)

```bash
./2_build_HB_jtag.sh all-dpr-bm    # dpr-full + bao-dpr-bm + opensbi-dpr-bm
./2_build_HB_jtag.sh program       # programme static_full.bit (obligatoire, voir ci-dessous)
./2_build_HB_jtag.sh jtag-dpr-bm   # OpenOCD bg + charge fw + 4 bitstreams + démarre
```

### Build firmware Baremetal (scénario IOMMU attack)

```bash
./2_build_HB.sh baremetal     # compile baremetal.bin (main.c + dpr_test_full.c)
./2_build_HB.sh bao           # BAO avec config cva6-baremetal
./2_build_HB.sh opensbi       # OpenSBI avec payload bao.bin
# ou tout en une commande :
./2_build_HB.sh all
```

### Test DPR standalone (sans BAO, via GDB)

```bash
./3_build_B.sh dpr            # générer bitstreams (détecte obsolètes)
./3_build_B.sh baremetal      # compiler baremetal
./3_build_B.sh program        # programmer FPGA
./3_build_B.sh openocd        # terminal 1 (bloquant)
./3_build_B.sh load           # afficher commandes GDB
```

### Commandes GDB (terminal 2)

```gdb
target remote localhost:3333
restore .../partial_accel_B_accel1.bin binary 0x81000000
restore .../partial_accel_B_accel2.bin binary 0x81300000
load
set $pc = 0x90000000
continue
```

---

## Cohérence des bitstreams

**Règle** : `full_accel_A.bit` et `partial_accel_B_*.bit` doivent être **plus récents** que `static_routed.dcp`.

`3_build_B.sh` vérifie automatiquement et avertit si incohérence.

```bash
./3_build_B.sh bitstreams   # vérifier dates + afficher constantes C
./3_build_B.sh logs         # historique des sessions
```

---

## Reproducibilité sur un autre PC

```bash
git clone --recurse-submodules -b dpr git@github.com:prevotet/riscv-iommu-demo.git
# Toolchain : Vivado 2022.2 (VIVADO_DIR=...), cross-compiler RISC-V (RISCV_BARE=...)
./3_build_B.sh dpr --force    # ~1h : recrée ariane.xpr + full build
./3_build_B.sh baremetal
./3_build_B.sh program
```

`ariane.xpr` n'est pas tracké — recréé automatiquement par `dpr-project`.
`xlnx_axi_hwicap.xci` est généré par `dpr-ips` (ajouté dans `dpr/Makefile`).

---

## Points techniques importants

### ICAP bit-swap
L'IP HWICAP fait le bit-swap interne (process `SWAP_BITS` dans le VHDL) → **pas de bswap côté logiciel**.

### Protocole d'écriture HWICAP

**Taille de chunk : max `HWICAP_WFV_MAX` (63 mots)**

Le FIFO physique est de 64 mots (`C_WRITE_FIFO_DEPTH=64` dans l'IP) mais WFV plafonne à 63 (6 bits, `wrvacancy = FIFO_DEPTH - occupancy - 1`). Si chunk > 63, le FIFO se remplit entièrement avant que CR_WRITE soit envoyé → deadlock (WFV=0, state machine jamais démarrée).

1. `hwicap_reset()` : écrire `CR=CR_FIFO_RST`, attendre `WFV=0x3F`, puis écrire `CR=0x00`
2. Écrire `SZ` = taille du chunk (≤ 63 mots)
3. Remplir FIFO : 63 mots, un par un, en vérifiant `WFV > 0`
4. Écrire `CR = CR_WRITE (0x01)`
5. Attendre `CR == 0` (la machine d'état ICAP acquitte)
6. Répéter pour le chunk suivant

**Piège** : `SZ` est **write-only** — la lire retourne 0 (normal, pas un bug de bridge).

### Bug registres HWICAP — RÉSOLU (2026-04-06)

**Cause racine** : les offsets des registres HWICAP dans le code étaient décalés de +0x10 (WF=0x110, CR=0x11C, WFV=0x124 au lieu des valeurs correctes).

**Preuve** : dans `axi_hwicap_v3_0_vh_rfs.vhd` (IP généré) :
```vhdl
constant HWICAP_REG_B_ADR : std_logic_vector := X"00000100";
constant HWICAP_REG_H_ADR : std_logic_vector := X"0000011F";
```
La plage de données fait 32 octets (8 CE × 4 octets), donc CE3=CR=0x10C, CE5=WFV=0x114.

Le code envoyait CR_WRITE à 0x11C (CE7, registre indéfini) → la state machine ICAP n'était jamais déclenchée.
Le code lisait WFV depuis 0x124 (hors plage) → valeur aléatoire/0x3F.

**Fix appliqué** dans `dpr_test.c`, `dpr_test_full.c` et `dpr_manager.c` :
- WF = 0x100, RF = 0x104, SZ = 0x108, CR = 0x10C, SR = 0x110, WFV = 0x114, RFO = 0x118
- Suppression des defines GIER/ISR/IER erronés (les registres d'interruption sont à 0x01C, 0x020, 0x028 dans la plage 0x00-0x3F)

### EOS
Avec `C_INCLUDE_STARTUP=1`, la STARTUPE2 interne gère EOS — le port `eos_in` **n'est pas exposé**.
**Ne pas** connecter `.eos_in(1'b1)` dans `ariane_peripherals_xilinx.sv` avec ce paramètre (erreur de compilation).
Avec `C_INCLUDE_STARTUP=0` (ancienne config), `eos_in=1'b1` devait être connecté explicitement.

### `arch_init` override

| Contexte | Override ? | Raison |
|---|---|---|
| `dpr_test.c` standalone (M-mode) | **OUI** — `void arch_init(){}` | `plic_init()` + CSRs S-mode causent des traps en M-mode sans SBI |
| `dpr_test_full.c` standalone (M-mode) | **OUI** — `void arch_init(){}` | Même raison |
| `dpr_test_full.c` BAO single-VM (`VARIANT=dpr_full`) | **OUI** — `void arch_init(){}` | `plic_init()` + `sie/sstatus` activent les interruptions → interruptions pendant les longues séquences HWICAP (534K mots ≈ plusieurs dizaines de ms) → IDCODE faux + DPR silencieusement ignoré par l'ICAP |
| `dpr_manager.c` BAO multi-VM (`cva6-dpr-linux`) | **NON** | Sous BAO multi-VM, le PLIC virtualisé est nécessaire pour les IPC inter-VMs avec Linux |

**Règle** : tout guest qui fait des séquences HWICAP longues doit avoir `arch_init(){}` vide pour éviter toute interruption pendant l'écriture du bitstream.

### accel_blank (accel_default) et SLVERR sous BAO

`accel_default` retourne AXI SLVERR sur toute lecture/écriture. Le comportement diverge selon le mode :

- **M-mode standalone** : CVA6 absorbe le SLVERR et retourne une valeur garbage (0xbadcab1e, 0xffffffff…) sans exception → le code continue.
- **S-mode sous BAO (VS-mode)** : SLVERR → load/store access fault (mcause=5/7) → exception non gérée dans le guest baremetal → **hang silencieux**.

**Conséquence** : ne jamais lire les registres des accels avant une DPR réussie sous BAO. Le RM initial du `static_full.bit` est `accel_blank` (SLVERR). Seuls `accel_A` et `accel_B` répondent correctement.

**Symptôme observé** : le programme s'arrête sans message après un `mmio_read32(0x50000000)` ou `mmio_read32(0x50001000)` si le RM est `accel_blank`.

### Bitstream FPGA à programmer pour DPR

**`do_program()` doit charger `static_full.bit`, pas `ariane_xilinx.bit`.**

`ariane_xilinx.bit` = bitstream CVA6 standard sans HWICAP ni zones DPR.
`static_full.bit` = bitstream DPR statique avec HWICAP, pblocks DPR et RM initial.

Si `ariane_xilinx.bit` est chargé → HWICAP renvoie `0xbadcab1e` (default slave AXI) sur toutes les lectures → les boucles de polling WFV/CR court-circuitent immédiatement (valeur sentinel ≠ 0) → la "reconfiguration" part dans le vide → accel_blank persistant → hang sur lecture accel.

**Fix appliqué dans `2_build_HB_jtag.sh`** : `do_program()` donne priorité à `static_full.bit` sur `ariane_xilinx.bit`. Un warning est émis si `ariane_xilinx.bit` est plus récent (rebuild DPR recommandé).

### Paramètres IP HWICAP (`C_OPERATION`, `C_INCLUDE_STARTUP`, `C_DEVICE_ID`)

Ces trois paramètres sont **tous obligatoires** dans le TCL. Sans eux, l'ICAP ne fonctionne pas silencieusement :

| Paramètre | Valeur | Effet si absent/incorrect |
|---|---|---|
| `C_DEVICE_ID` | `0x03647093` | ICAP ne correspond pas au device → configuration refusée |
| `C_INCLUDE_STARTUP` | `1` | Sans STARTUPE2 interne, l'ICAP peut rester en état indéfini après boot |
| `C_OPERATION` | `1` | Sans ce flag, BUFGCTRL peut couper l'horloge ICAP après startup → ICAP accepte les données (WFV/CR cycle normalement) mais **n'exécute rien** → IDCODE faux, DPR silencieusement ignoré |

**Symptôme de `C_OPERATION=0`** : HWICAP se comporte normalement côté AXI (WFV = 0x3F, CR_WRITE acquitté, SR = 0x00000001) mais l'ICAP ne reconfigure pas le fabric. IDCODE retourne une valeur incorrecte (ex. `0x020035e5`).

**Fix appliqué dans `2_build_HB_jtag.sh` `do_hwicap_setup()`** : TCL complété avec les trois paramètres. Régénérer l'IP et rebuilder `static_full.bit` si ces paramètres étaient manquants.

### Règle DFX — feedthrough nets et PPLOC (HDPostRouteDRC-02)

**Symptôme** : `ERROR: HDPostRouteDRC-02: boundary net ... does not have PPLOC on it`

**Cause** : dans un RM, si un port de sortie est piloté combinatoirement depuis un port d'entrée (ex. `assign b_id = aw_id`), le net entre ET sort du pblock — Vivado ne peut pas placer deux PPLOCs sur le même net avec `CONTAIN_ROUTING=true`.

**Règle** : tout port de sortie d'un RM (`b_id`, `r_id`, `b_valid`, `r_valid`…) doit être piloté par un **FF interne au pblock**, avec `(* dont_touch = "true" *)`.

**Correction appliquée** dans `dpr/rm/accel_default/accel_blank.sv`, `accel_A/accel_wrap.sv`, `accel_B/accel_wrap.sv` : `b_id`, `b_valid`, `r_id`, `r_valid` sont maintenant des `always_ff` internes au RM. Latence +1 cycle sur les réponses AXI cfg — sans impact fonctionnel.

### Compilation VARIANT=dpr_manager

`bao-baremetal-guest/src/sources.mk` supporte la variable `VARIANT` :
- `VARIANT=dpr_manager` → compile `dpr_manager.c` uniquement (pas de `arch_init` override)
- (défaut) → compile `main.c` + `dpr_test_full.c` (avec `arch_init` override vide)

Usage dans `2_build_HB.sh` :
```bash
make -C bao-baremetal-guest PLATFORM=cva6 VARIANT=dpr_manager NAME=dpr_manager
```
Produit : `build/cva6/dpr_manager.bin` (chargé à `0x90000000` par BAO).
