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
- **BAO hypervisor** + Linux guest + baremetal guest
- **Deux accélérateurs DPR** (`accel_wrap #1` et `#2`) dans des zones reconfigurables

### Adresses clés

| Périphérique | Adresse base |
|---|---|
| ACCEL1 | `0x50000000` |
| ACCEL2 | `0x50001000` |
| HWICAP  | `0x40010000` |
| DDR bitstream accel1 | `0x81000000` |
| DDR bitstream accel2 | `0x81300000` |
| Baremetal | `0x90000000` |

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

## Fichiers modifiés

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

### Baremetal (`bao-baremetal-guest/src/dpr_test.c`)

- `arch_init()` overridée vide (évite CSRs S-mode sans SBI)
- `HWICAP_CR_WRITE = 0x01` (Rnc(1)=cr_i(4))
- Attente `CR=0` après chaque chunk (machine d'état acquitte)
- Uniquement `mmio_write32` — pas de `mmio_write64`

---

## Workflow de build

```bash
# Build complet (BAO + Linux + DPR)
FORCE_FPGA=1 DPR_MODE=static ./2_build_HB.sh fpga-dpr
RM=accel_A ./2_build_HB.sh fpga-dpr
RM=accel_B ./2_build_HB.sh fpga-dpr

# Test DPR standalone
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

1. `hwicap_reset()` : écrire `CR=CR_FIFO_RST`, attendre `WFV=0x3F`
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

**Fix appliqué** dans `dpr_test.c` et `dpr_test_full.c` :
- WF = 0x100, RF = 0x104, SZ = 0x108, CR = 0x10C, SR = 0x110, WFV = 0x114, RFO = 0x118
- Suppression des defines GIER/ISR/IER erronés (les registres d'interruption sont à 0x01C, 0x020, 0x028 dans la plage 0x00-0x3F)

### EOS
Avec `C_INCLUDE_STARTUP=1`, la STARTUPE2 interne gère EOS.  
`eos_in=1'b1` connecté dans `ariane_peripherals_xilinx.sv`.

### `arch_init` override
Le baremetal standalone tourne en mode M sans BAO.  
`plic_init()` et `CSRS(sie/sstatus)` causent des traps → override vide obligatoire.

### Règle DFX — feedthrough nets et PPLOC (HDPostRouteDRC-02)

**Symptôme** : `ERROR: HDPostRouteDRC-02: boundary net ... does not have PPLOC on it`

**Cause** : dans un RM, si un port de sortie est piloté combinatoirement depuis un port d'entrée (ex. `assign b_id = aw_id`), le net entre ET sort du pblock — Vivado ne peut pas placer deux PPLOCs sur le même net avec `CONTAIN_ROUTING=true`.

**Règle** : tout port de sortie d'un RM (`b_id`, `r_id`, `b_valid`, `r_valid`…) doit être piloté par un **FF interne au pblock**, avec `(* dont_touch = "true" *)`.

**Correction appliquée** dans `dpr/rm/accel_default/accel_blank.sv`, `accel_A/accel_wrap.sv`, `accel_B/accel_wrap.sv` : `b_id`, `b_valid`, `r_id`, `r_valid` sont maintenant des `always_ff` internes au RM. Latence +1 cycle sur les réponses AXI cfg — sans impact fonctionnel.
