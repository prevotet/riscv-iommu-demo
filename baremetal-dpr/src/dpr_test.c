/**
 * dpr_test.c — Test DPR + HWICAP
 *
 * Utilise uniquement mmio_write32 (instruction SW 32 bits)
 * pour être compatible avec le xlnx_axi_dwidth_converter 64→32.
 */

#include <stdint.h>
#include <stdio.h>

// =============================================================================
// Adresses
// =============================================================================

#define ACCEL1_BASE    0x50000000ULL
#define ACCEL2_BASE    0x50001000ULL
#define HWICAP_BASE    0x40010000ULL

// Registres données HWICAP (HWICAP_REG_B_ADR=0x100, HWICAP_REG_H_ADR=0x11F)
// Source: axi_hwicap_v3_0_vh_rfs.vhd dans l'IP généré
#define HWICAP_WF   (HWICAP_BASE + 0x100)
#define HWICAP_RF   (HWICAP_BASE + 0x104)
#define HWICAP_SZ   (HWICAP_BASE + 0x108)
#define HWICAP_CR   (HWICAP_BASE + 0x10C)
#define HWICAP_SR   (HWICAP_BASE + 0x110)
#define HWICAP_WFV  (HWICAP_BASE + 0x114)
#define HWICAP_RFO  (HWICAP_BASE + 0x118)

// CR bits (Xilinx embeddedsw SDK xhwicap_l.h)
#define HWICAP_CR_WRITE    0x01
#define HWICAP_CR_READ     0x02
#define HWICAP_CR_FIFO_RST 0x04

#define HWICAP_WFV_MAX   0x3F
#define HWICAP_TIMEOUT   1000000

// =============================================================================
// Bitstreams partiels (DDR)
// =============================================================================

#define BS_ACCEL1_ADDR  0x81000000ULL
#define BS_ACCEL2_ADDR  0x81300000ULL
#define BS_ACCEL1_WORDS 534823UL
#define BS_ACCEL2_WORDS 1030207UL

// =============================================================================
// MMIO helpers — uniquement 32 bits pour compatibilité avec dwidth converter
// =============================================================================

static inline uint32_t mmio_read32(uint64_t addr) {
    uint32_t val;
    asm volatile ("fence i, r" ::: "memory");
    val = *(volatile uint32_t *)addr;
    return val;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
    asm volatile ("fence w, o" ::: "memory");
}

static void delay(int loops) {
    for (volatile int i = 0; i < loops; i++) asm volatile("nop");
}

// =============================================================================
// Override arch_init — évite les CSRs S-mode sans SBI
// =============================================================================

void arch_init(void) {
    // Pas de PLIC, pas d'interruptions en mode standalone
    asm volatile ("fence.i" ::: "memory");
}

// =============================================================================
// Utilitaires HWICAP
// =============================================================================

static void print_status(const char *label) {
    printf("[HWICAP] %s : SR=0x%08x WFV=0x%02x RFO=0x%02x\r\n",
           label,
           (unsigned int)mmio_read32(HWICAP_SR),
           (unsigned int)mmio_read32(HWICAP_WFV),
           (unsigned int)mmio_read32(HWICAP_RFO));
}

static void hwicap_diag(void) {
    printf("[HWICAP] === DIAG ===\r\n");

    // Test d'écriture sur SZ (registre write-only, on vérifie juste qu'il ne bloque pas le bus)
    mmio_write32(HWICAP_SZ, 0xAA);
    printf("[HWICAP] SZ write 0xAA (write-only, readback non testé)\r\n");

    // Dump de tous les registres 0x100..0x118
    const char *names[] = {"WF ", "RF ", "SZ ", "CR ", "SR ", "WFV", "RFO"};
    for (int i = 0; i < 7; i++) {
        uint64_t addr = HWICAP_BASE + 0x100 + i * 4;
        printf("[HWICAP] [0x%03x] %s = 0x%08x\r\n",
               (unsigned int)(addr - HWICAP_BASE),
               names[i],
               (unsigned int)mmio_read32(addr));
    }
    printf("[HWICAP] === FIN DIAG ===\r\n");
}
static void hwicap_desync(void) {
    static const uint32_t seq[] = {
        0x20000000, 0x20000000,  // NOOP
        0x30008001,              // Type 1 Write CMD (1 word)
        0x0000000A,              // GRESTORE
        0x20000000, 0x20000000,  // NOOP
        0x30008001,              // Type 1 Write CMD (1 word)
        0x0000000D,              // DESYNC
        0x20000000, 0x20000000,  // NOOP
    };
    uint32_t n = sizeof(seq)/sizeof(seq[0]);
    mmio_write32(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++)
        mmio_write32(HWICAP_WF, seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    int timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0) delay(10);
    delay(100);
    printf("[HWICAP] desync : SR=0x%08x\r\n", (unsigned int)mmio_read32(HWICAP_SR));
}

static void hwicap_fifo_reset(void) {
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    delay(100);
    int timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0) delay(10);
    mmio_write32(HWICAP_CR, 0x00);
    delay(100);
    timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0) delay(10);
    printf("[HWICAP] FIFO reset : WFV=0x%02x\r\n",
           (unsigned int)mmio_read32(HWICAP_WFV));
}

// =============================================================================
// Lecture IDCODE via ICAP (UG470 7-series)
// =============================================================================

static void hwicap_read_idcode(void) {
    printf("\r\n[HWICAP] Lecture IDCODE FPGA\r\n");

    hwicap_fifo_reset();

    static const uint32_t seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF,  // dummy words
        0xAA995566,              // sync word
        0x20000000, 0x20000000,  // NOOP
        0x28018001,              // Type 1 Read IDCODE Reg 12 (0x0C) (1 word)
        0x20000000, 0x20000000,  // NOOP
        0x20000000, 0x20000000,  // NOOP
    };

    uint32_t n = sizeof(seq)/sizeof(seq[0]);
    mmio_write32(HWICAP_SZ, n);
    print_status("avant sequence");

    for (uint32_t i = 0; i < n; i++)
        mmio_write32(HWICAP_WF, seq[i]);

    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    // Attendre CR_WRITE remis à 0
    int timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0) delay(10);

    print_status("apres write");
    delay(1000);

    // Déclencher lecture
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);

    timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && timeout-- > 0) delay(10);

    print_status("apres read");
    delay(100);

    uint32_t idcode = mmio_read32(HWICAP_RF);
    printf("[HWICAP] IDCODE = 0x%08x (attendu 0x03647093)\r\n",
           (unsigned int)idcode);

    if ((idcode & 0x0FFFFFFF) == 0x03647093)
        printf("[HWICAP] [OK] IDCODE correct\r\n");
    else
        printf("[HWICAP] [FAIL] IDCODE inattendu\r\n");

    hwicap_fifo_reset();
    hwicap_desync();
}

// =============================================================================
// Écriture bitstream via HWICAP
//
// Protocole (Xilinx SDK xhwicap.c) :
//   - Chunks de max 4095 mots (SZ 12 bits)
//   - Écrire SZ, remplir FIFO mot par mot (mmio_write32 = SW 32 bits)
//   - Déclencher CR_WRITE, attendre CR=0 (machine d'état acquitte)
//   - PAS de bswap (l'IP fait le bit-swap interne)
// =============================================================================

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    hwicap_fifo_reset();
    print_status("debut write_bitstream");

    printf("[HWICAP] Premiers mots bitstream (DDR -> HWICAP) :\r\n");
    for (int i = 0; i < 4; i++) {
        printf("  [%d] DDR=0x%08x -> ICAP=0x%08x\r\n", 
               i, (unsigned int)data[i], (unsigned int)__builtin_bswap32(data[i]));
    }

    uint32_t written = 0;

    while (written < size_words) {

        // Chunk de max 4095 mots
        uint32_t chunk = size_words - written;
        if (chunk > HWICAP_WFV_MAX) chunk = HWICAP_WFV_MAX;

        mmio_write32(HWICAP_SZ, chunk);

        // Remplir FIFO mot par mot
        uint32_t sent = 0;
        while (sent < chunk) {

            // Attendre WFV > 0
            int timeout = HWICAP_TIMEOUT;
            while (mmio_read32(HWICAP_WFV) == 0 && timeout-- > 0) delay(1);
            if (timeout <= 0) {
                printf("[HWICAP] ERROR: timeout WFV mot %u\r\n",
                       (unsigned int)(written + sent));
                print_status("timeout WFV");
                return -1;
            }

            uint32_t to_write = mmio_read32(HWICAP_WFV);
            if (to_write > (chunk - sent)) to_write = chunk - sent;

            for (uint32_t i = 0; i < to_write; i++) {
                mmio_write32(HWICAP_WF, data[written + sent]);
                sent++;
            }
        }

        // Déclencher
        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

        // Attendre CR_WRITE remis à 0
        int timeout = HWICAP_TIMEOUT;
        while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0) delay(1);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout CR mot %u\r\n",
                   (unsigned int)written);
            print_status("timeout CR");
            return -1;
        }

        written += chunk;

        if (written % 10000 < chunk) {
            printf("[HWICAP] Progression : %u / %u mots...\r\n", 
                   (unsigned int)written, (unsigned int)size_words);
        }
    }

    delay(100);
    print_status("fin write_bitstream");
    printf("[HWICAP] %u mots envoyés\r\n", (unsigned int)size_words);

    return 0;
}

// =============================================================================
// Test DPR principal
// =============================================================================

void dpr_test(void) {
    printf("\r\n=================================================\r\n");
    printf(" DPR Test — Lecture IDCODE + Reconfiguration\r\n");
    printf("=================================================\r\n");

    hwicap_diag();

    asm volatile ("fence" ::: "memory");
    uint32_t id1_lo = mmio_read32(ACCEL1_BASE);
    uint32_t id1_hi = mmio_read32(ACCEL1_BASE + 4);
    uint32_t id2_lo = mmio_read32(ACCEL2_BASE);
    uint32_t id2_hi = mmio_read32(ACCEL2_BASE + 4);

    printf("\r\n[1] IDs initiaux :\r\n");
    printf("  accel1 = 0x%08x%08x\r\n", id1_hi, id1_lo);
    printf("  accel2 = 0x%08x%08x\r\n", id2_hi, id2_lo);

    printf("\r\n[2] Reconfiguration accel1...\r\n");
    const uint32_t *bs_accel1 = (const uint32_t *)BS_ACCEL1_ADDR;
    if (hwicap_write_bitstream(bs_accel1, BS_ACCEL1_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel1 échouée\r\n");
        return;
    }
    printf("[OK] accel1 reconfiguré\r\n");

    printf("\r\n[3] Reconfiguration accel2...\r\n");
    const uint32_t *bs_accel2 = (const uint32_t *)BS_ACCEL2_ADDR;
    if (hwicap_write_bitstream(bs_accel2, BS_ACCEL2_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel2 échouée\r\n");
        return;
    }
    printf("[OK] accel2 reconfiguré\r\n");

    asm volatile ("fence" ::: "memory");
    id1_lo = mmio_read32(ACCEL1_BASE);
    id1_hi = mmio_read32(ACCEL1_BASE + 4);
    id2_lo = mmio_read32(ACCEL2_BASE);
    id2_hi = mmio_read32(ACCEL2_BASE + 4);

    printf("\r\n[4] IDs post-reconfiguration :\r\n");
    printf("  accel1 = 0x%08x%08x\r\n", id1_hi, id1_lo);
    printf("  accel2 = 0x%08x%08x\r\n", id2_hi, id2_lo);

    if ((id1_lo & 0xFFFFFF) == 0xBBBBBB && (id2_lo & 0xFFFFFF) == 0xBBBBBB)
        printf("[OK] accel_B détecté — DPR réussi !\r\n");
    else
        printf("[FAIL] IDs inattendus\r\n");

    printf("\r\n=================================================\r\n");
    printf(" Test terminé\r\n");
    printf("=================================================\r\n");
}