# CLAUDE.md — riscv-iommu-demo / DPR HWICAP

## Projet

**Repo** : `github.com/prevotet/riscv-iommu-demo.git`  
**Cible** : Genesys2 XC7K325T-2FFG900  
**Outil** : Vivado 2022.2  
**Branche active** : `dpr`

---

## Architecture SoC

- **CVA6** RISC-V 64 bits, crossbar AXI 64 bits
- **BAO hypervisor** + guests baremetal
- **Deux accélérateurs DPR** (`accel_wrap #1` et `#2`) dans des zones reconfigurables

### Adresses clés

| Périphérique | Adresse base |
|---|---|
| ACCEL1 | `0x50000000` |
| ACCEL2 | `0x50001000` |
| HWICAP  | `0x40010000` |
| DDR bitstream accel1 | `0x81000000` |
| DDR bitstream accel2 | `0x81300000` |

---

## AXI HWICAP — registres

| Offset | Registre | Description |
|---|---|---|
| `0x100` | WF  | Write FIFO data |
| `0x104` | RF  | Read FIFO data |
| `0x108` | SZ  | Size register (write-only) |
| `0x10C` | CR  | Control register |
| `0x110` | SR  | Status register |
| `0x114` | WFV | Write FIFO Vacancy (max=0x3F) |
| `0x118` | RFO | Read FIFO Occupancy |

### Bits CR

| Valeur | Description |
|---|---|
| `0x01` | `CR_WRITE` |
| `0x02` | `CR_READ` |
| `0x04` | `CR_FIFO_RST` |

### SR=0x05 = état normal

- Bit 0 : `send_done`
- Bit 2 : `EOS` (STARTUPE2 terminé)
- Bit 1 = 0 : pas de hang

---

## Convention d'écriture HWICAP

### Séquences manuelles (constantes hardcodées)

Écrire les **mots logiques directement** dans HWICAP_WF, sans transformation :
- Sync word : `0xAA995566`
- NOOP : `0x20000000`
- Type 1 Read STAT (reg 7) : `0x2800E001`
- Type 1 Read IDCODE (reg 12) : `0x28018001`
- Type 1 Write CMD (reg 4) : `0x30008001` suivi de la valeur CMD

L'IP fait le SWAP_BITS interne (bit-reversal par byte) avant ICAP. Après SWAP_BITS, `0xAA995566` donne `0x5599AA66` au pin ICAP = sync word valide.

### Bitstream .bin chargé depuis DDR (GDB restore)

**Appliquer `bswap32()` à chaque mot avant écriture dans WF.**

Le fichier `.bin` Vivado est big-endian (sync = octets `AA 99 55 66`).  
GDB `restore` charge les octets tels quels en mémoire little-endian CVA6.  
`*(uint32_t*)DDR` pour le sync word donne `0x665599AA` (bytes inversés).  
Sans bswap32 → ICAP reçoit `0x6699AA55` (invalide) → ignore silencieusement le bitstream.  
Avec bswap32 → `0xAA995566` → après SWAP_BITS → `0x5599AA66` ✓

```c
for (uint32_t i = 0; i < nwords; i++)
    mmio_write32(HWICAP_WF, bswap32(data[i]));
```

### Protocole d'écriture (chunk ≤ 63 mots)

1. `hwicap_fifo_reset()` : CR=0x04, attendre WFV=0x3F, CR=0x00
2. Écrire `SZ` = taille du chunk
3. Remplir WF mot par mot (vérifier WFV > 0)
4. Écrire `CR = 0x01` (CR_WRITE)
5. Attendre `CR == 0`

**SZ est write-only** — relire SZ retourne 0, c'est normal.

---

## Bridge AXI→HWICAP

Chaîne : `AXI 64b (crossbar) → axi2apb_64_32 → APB 32b → apb_to_axilite → AXI-Lite 32b → xlnx_axi_hwicap`

---

## RMs disponibles

| RM | accel1 ID (bits 23:0) | accel2 ID (bits 23:0) |
|---|---|---|
| `accel_A` | `0xAAAAAA` | `0xAAAAAA` |
| `accel_B` | `0xBBBBBB` | `0xBBBBBB` |
| `accel_default` | SLVERR | SLVERR |

---

## Progression des tests (baremetal-dpr)

Script de test standalone : `3_build_B2.sh` + `baremetal-dpr/src/dpr_test.c`

### ✅ Étape 1 — Registres HWICAP lisibles (2026-04-23)

Après FIFO reset : CR=0x00, SR=0x05, WFV=0x3F, RFO=0x00. Bridge opérationnel.

### Étape 2 — CR_WRITE acquitté sur mots dummy

Envoyer 4×0xFFFFFFFF, vérifier CR revient à 0.

### ✅ Étape 3 — Lecture IDCODE (2026-04-23)

Séquence sync + Type 1 Read IDCODE = 0x43651093. Confirmé OK.

### Étape 4 — Lecture STAT

Séquence sync + Type 1 Read STAT (reg 7), vérifier DONE=1, EOS=1, CFGERR=0.

### ✅ Étape 5 — DPR accel1 : écriture chunk-by-chunk OK jusqu'au chunk 80 (2026-04-27)

Test3 : chunks 0-80 écrits OK (SR=0x05, ASR=0, ~153 cy/chunk). Hang au chunk 81.

**Cause root** : cellule `irpt_wrack_d1_i_1` (HWICAP AXI FSM) en SLICE_X54Y253 = CR Y5.
DPR réinitialise HCLK CR Y5 → AXI freeze → CPU bloqué sur `mmio_r(HWICAP_SR)`.

**Fix run_static.tcl (2026-04-27)** :
1. `per_slice=8` pour `r_data_ff_reg` → résout HDPR-29 (LOC hors pblock)
2. `pblock_hwicap` soft `SLICE_X0Y0:SLICE_X167Y249` → force HWICAP IP hors CR Y5
3. XDC exporté corrigé : `SLICE_X32Y250:SLICE_X47Y299` (cohérence static/partial)

### ✅ Étape 6 — DPR accel_A → accel_B validé de bout en bout (2026-04-27)

Test3 complet : bitstream accel_B écrit sur accel1 sans hang. Sanity check AXI :
- accel2 (non reconfiguré) = `0xAAAAAA` → bus AXI sain, accel2 intact
- accel1 après DPR = `0xBBBBBB` → accel_B actif, RP fonctionnel

### ✅ Étape 7 — Ping-pong accel_A ↔ accel_B : 5/5 rounds OK (2026-04-27)

test5 : 10 reconfigurations consécutives sans erreur. DPR bidirectionnel stable.

### ✅ Étape 8 — DPR accel2 : accel_A → accel_B OK (2026-04-27)

test6 : accel2 0xAAAAAA → 0xBBBBBB, 0 anomalie sur 1522 chunks. accel1 inchangé (bus AXI sain).
Flags post-DPR (CFGERR=1, ID_ERROR=1, delta=0xa9ef8227) = comportement 7-series normal après PR.

---

## Points techniques importants

### ICAP bit-swap (SWAP_BITS)

L'IP inverse les bits dans chaque byte (SWAP_BITS) avant ICAP.  
Ce n'est PAS un bswap32 (byte-swap) — ce sont deux opérations différentes.  
Voir section "Convention d'écriture HWICAP" pour les règles par contexte.

### Chunk size max = 63 mots

WFV plafonne à 0x3F. Si chunk > 63, le FIFO sature avant CR_WRITE → deadlock.

### IDCODE XC7K325T

`0x43651093` (lu par ICAP3 via HWICAP — version field=4 dans les bits 31:28)

### Séquence RCRC+DESYNC pour effacer CFGERR

```c
0xFFFFFFFF, 0xFFFFFFFF,  // dummy
0xAA995566,              // sync
0x20000000,              // NOOP
0x30008001, 0x00000007,  // CMD = RCRC
0x20000000,              // NOOP
0x30008001, 0x0000000D,  // CMD = DESYNC
0x20000000, 0x20000000,  // NOOP x2
```
