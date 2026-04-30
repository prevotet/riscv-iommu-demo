# DPR Test Guide — CVA6 / Genesys2

Two scripts cover DPR validation:

| Script | Context | Target firmware |
|---|---|---|
| `3_build_B2.sh` | Standalone baremetal | `baremetal-dpr/` running directly on CVA6 |
| `2_BUILD_HB.sh` | Baremetal under BAO hypervisor | `bao-baremetal-guest/` inside a BAO VM |

Both scripts share the same 7 tests and the same bitstreams.

---

## Hardware prerequisites

- Genesys2 board (XC7K325T) connected via USB-JTAG
- Vivado 2022.2 installed in `/tools/Xilinx/Vivado/2022.2`
- RISC-V toolchain: `riscv64-unknown-elf-gcc` (path configured in the script)
- OpenOCD installed and available in PATH

---

## 3_build_B2.sh — Standalone baremetal tests

### Startup workflow

Open **two terminals** in the repository root directory.

**Terminal 1 — OpenOCD (keep running)**
```bash
./3_build_B2.sh openocd
```

**Terminal 2 — Program the FPGA, then run tests**
```bash
# 1. Program the FPGA with the full bitstream (accel_A)
./3_build_B2.sh program

# 2. Run tests in order
./3_build_B2.sh test1
./3_build_B2.sh test2
./3_build_B2.sh test3
./3_build_B2.sh test4
./3_build_B2.sh test5
./3_build_B2.sh test6
./3_build_B2.sh test7
```

Each `testN` command compiles the firmware, loads it via GDB and prints UART output.

### Available targets

| Target | Description |
|---|---|
| `test1` | HWICAP infrastructure + ICAP registers (IDCODE, STAT, MASK) |
| `test2` | IDCODE / MASK — full validation before DPR |
| `test3` | Chunk-by-chunk write + ICAP abort detection |
| `test4` | Full DPR accel1 (accel_A → accel_B) |
| `test5` | Ping-pong accel_A ↔ accel_B (10 rounds) |
| `test6` | Full DPR accel2 (accel_A → accel_B) |
| `test7` | Ping-pong accel2 accel_A ↔ accel_B (10 rounds) |
| `dpr` | Regenerate bitstreams via Vivado |
| `baremetal` | Compile baremetal firmware only |
| `program` | Program the FPGA (full_accel_A.bit via Vivado JTAG) |
| `openocd` | Start OpenOCD (keep running in background) |
| `load` | Load firmware + bitstreams via GDB |
| `convert-bin` | Convert `.bit` files to `.bin` |
| `logs` | Show session history |
| `help` | Show full help |

### Options

| Option | Effect |
|---|---|
| `--force` | Force full rebuild (IP + bitstreams + baremetal) |
| `--force-hwicap` | Force rebuild AXI HWICAP IP only |
| `--force-static` | Force rebuild Vivado static checkpoint |
| `--force-baremetal` | Force recompilation of baremetal firmware |

### Environment variables

```bash
RM_INIT=accel_A      # Starting RM   (default: accel_A)
RM_TARGET=accel_B    # Target RM     (default: accel_B)
VIVADO_VERSION=2022.2
CROSS_COMPILE=<path>/riscv64-unknown-elf-
```

### DDR layout (loaded by GDB)

| Address | Content |
|---|---|
| `0x90000000` | `baremetal.bin` (firmware) |
| `0x81000000` | `partial_accel_B_accel1.bin` (test4/5) |
| `0x81300000` | `partial_accel_A_accel1.bin` (test5) / `partial_accel_B_accel2.bin` (test6/7) |
| `0x81600000` | `partial_accel_A_accel2.bin` (test7) |

---

## 2_BUILD_HB.sh — Tests under BAO hypervisor

### Prerequisites

Bitstreams must have been generated beforehand by `3_build_B2.sh`:
```bash
./3_build_B2.sh dpr
```

### Startup workflow

Open **two terminals**.

**Terminal 1 — OpenOCD (keep running)**
```bash
./2_BUILD_HB.sh openocd
```

**Terminal 2 — Build + tests**
```bash
# 1. Program the FPGA
./2_BUILD_HB.sh program

# 2. Run tests in order
./2_BUILD_HB.sh test1
./2_BUILD_HB.sh test2
./2_BUILD_HB.sh test3
./2_BUILD_HB.sh test4
./2_BUILD_HB.sh test5
./2_BUILD_HB.sh test6
./2_BUILD_HB.sh test7
```

Each `testN` compiles the full stack (DPR Manager → BAO → OpenSBI → `fw_payload.bin`), programs the FPGA if needed, loads via GDB and reads UART output.

### Available targets

| Target | Description |
|---|---|
| `test1` … `test7` | Same logic as `3_build_B2.sh`, in the BAO context |
| `baremetal` | Compile DPR Manager + BAO + OpenSBI → `fw_payload.bin` |
| `dpr-manager` | Compile the DPR Manager guest only |
| `bao` | Compile BAO only |
| `opensbi` | Compile OpenSBI only |
| `program` | Program the FPGA (full_accel_A.bit) |
| `openocd` | Start OpenOCD (dedicated terminal) |
| `load` | Load `fw_payload.bin` + 4 bitstreams via GDB |
| `bitstreams` | Check presence of the 4 DDR bitstreams |
| `logs` | Show session history |
| `help` | Show full help |

### Options

| Option | Effect |
|---|---|
| `--force` | Force recompilation of DPR Manager + BAO + OpenSBI |
| `--force-baremetal` | Same |
| `--dry-run` | Print commands without executing them |

### Environment variables

```bash
RM_INIT=accel_A              # Starting RM  (default: accel_A)
RM_TARGET=accel_B            # Target RM    (default: accel_B)
BAO_CONFIG=cva6-dpr-baremetal
OPENOCD_PORT=3333
LOGLEVEL=INFO
```

### DDR layout (loaded by GDB)

| Address | Content |
|---|---|
| `0x80000000` | `fw_payload.bin` (OpenSBI + BAO + DPR Manager) |
| `0x81000000` | `partial_accel_A_accel1.bin` |
| `0x81300000` | `partial_accel_B_accel1.bin` |
| `0x81600000` | `partial_accel_A_accel2.bin` |
| `0x81B00000` | `partial_accel_B_accel2.bin` |

---

## Test descriptions

| Test | Validates |
|---|---|
| **test1** | HWICAP registers readable (SR=0x05, WFV=0x3F), IDCODE=0x43651093, STAT, MASK |
| **test2** | MASK write via ICAP, persistence after RCRC, preamble 0xF0000000 |
| **test3** | Chunk-by-chunk bitstream write on accel1, ICAP abort detection |
| **test4** | Full DPR accel1: accel_A (0xAAAAAA) → accel_B (0xBBBBBB) |
| **test5** | Ping-pong accel_A ↔ accel_B on accel1 (5 rounds = 10 reconfigurations) |
| **test6** | Full DPR accel2: accel_A (0xAAAAAA) → accel_B (0xBBBBBB) |
| **test7** | Ping-pong accel_A ↔ accel_B on accel2 (5 rounds = 10 reconfigurations) |

Success criteria:
- SR=0x05 and ASR=0 throughout all writes
- Correct accel ID after each reconfiguration
- Unreconfigured accel unchanged (RP isolation)
