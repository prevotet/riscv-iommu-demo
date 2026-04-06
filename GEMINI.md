# GEMINI.md — RISC-V IOMMU & DPR HWICAP Demo

This file serves as a foundational mandate for Gemini CLI in this workspace. It takes precedence over general workflows.

## Project Context
- **Repository**: `github.com/prevotet/riscv-iommu-demo.git`
- **Target Hardware**: Genesys2 (XC7K325T-2FFG900)
- **Primary Tool**: Vivado 2022.2
- **Key Architecture**: CVA6 (64-bit), RISC-V IOMMU, BAO Hypervisor, DPR (Dynamic Partial Reconfiguration) with AXI HWICAP.

## Critical SoC Addresses
| Peripheral | Base Address |
|---|---|
| ACCEL1 | `0x50000000` |
| ACCEL2 | `0x50001000` |
| HWICAP | `0x40010000` |
| DDR Bitstream Accel1 | `0x81000000` |
| DDR Bitstream Accel2 | `0x81300000` |
| Baremetal Entry | `0x90000000` |

## Build & Test Workflows

### Standalone DPR Test (Workflow B)
Utilisez `3_build_B2.sh` pour l'automatisation GDB :
```bash
./3_build_B2.sh dpr          # Bitstream generation (check coherence)
./3_build_B2.sh baremetal    # Compile baremetal guest (with FENCE)
./3_build_B2.sh program      # Program FPGA via JTAG
./3_build_B2.sh openocd      # Terminal 1 (blocking)
./3_build_B2.sh load         # Terminal 2: Auto-load BS1, BS2 + ELF and RUN
```

## Technical Implementation Rules

### AXI HWICAP Protocol & CVA6 Stability
1. **Memory Barriers (FENCE)**: Obligatoires pour chaque accès MMIO sur CVA6 pour garantir l'ordre (Data avant Commande).
   - `asm volatile ("fence i, r" ::: "memory");` avant lecture.
   - `asm volatile ("fence w, o" ::: "memory");` après écriture.
2. **AXI ID Width**: La largeur des IDs sur le bus est de **6 bits**. Tous les modules RM (`accel_wrap`) doivent utiliser `AXI_SLV_ID_WIDTH = 6` pour éviter les erreurs de routage `RTSTAT-2`.
3. **Write Sequence**: `SZ` (mots) -> `WF` (données) -> `CR = 0x01` (WRITE).

### 64-to-32 bit Conversion (Bridge APB)
- CVA6 (64-bit) vers HWICAP (32-bit).
- Le bridge `axi2apb_64_32` est **aveugle aux strobes (WSTRB)**.
- **Règle d'or logicielle** : Utiliser exclusivement des accès 32 bits (`uint32_t`) alignés. Interdiction des accès 64 bits (`sd`/`ld`) vers les périphériques.

### DFX / Partial Reconfiguration
- **Pblocks**: `accel1` (X0Y250:X71Y299), `accel2` (X72Y250:X145Y299).
- **RM Output Rule**: Toutes les sorties (`b_id`, `r_id`, `b_valid`, `r_valid`) doivent être enregistrées (`always_ff`) avec `(* dont_touch = "true" *)` pour passer le routage DFX.

## Operational Guidelines for Gemini
- **Conciseness**: Follow the "Minimal Output" rule.
- **Verification**: Vérifier la cohérence bitstream/checkpoint avant tout chargement.
- **Git Hygiene**: Ne pas tracker `ariane.xpr` ou les dossiers `.gen`.
