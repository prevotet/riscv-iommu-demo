/**
 * dpr_hwicap.c — Test et reconfiguration partielle dynamique (DPR)
 *
 * Supporte :
 *   - Lecture IDCODE via AXI HWICAP
 *   - Reconfiguration partielle des accélérateurs
 */

#include <stdint.h>
#include <stdio.h>

// =============================================================================
// Adresses AXI
// =============================================================================

#define ACCEL1_BASE    0x50000000ULL
#define ACCEL2_BASE    0x50001000ULL
#define HWICAP_BASE    0x40010000ULL

// =============================================================================
// AXI HWICAP registres (UG470 / PG134)
// =============================================================================

#define HWICAP_WF  (HWICAP_BASE + 0x100)
#define HWICAP_RF  (HWICAP_BASE + 0x104)
#define HWICAP_SZ  (HWICAP_BASE + 0x108)
#define HWICAP_CR  (HWICAP_BASE + 0x10C)
#define HWICAP_SR  (HWICAP_BASE + 0x110)
#define HWICAP_WFV (HWICAP_BASE + 0x114)
#define HWICAP_RFO (HWICAP_BASE + 0x118)

// CR bits
#define HWICAP_CR_WRITE 0x10

// WFV max = 63
#define HWICAP_WFV_MAX 0x3F
#define HWICAP_TIMEOUT 10000000

// =============================================================================
// Helpers MMIO
// =============================================================================

static inline uint32_t mmio_read32(uint64_t addr) {
    return *(volatile uint32_t *)addr;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
}

// =============================================================================
// HWICAP write start
// =============================================================================

static inline void hwicap_start_write(uint32_t cr_value) {
    mmio_write32(HWICAP_CR, cr_value);
}

// =============================================================================
// HWICAP write bitstream
// =============================================================================

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    uint32_t written = 0;

    mmio_write32(HWICAP_SZ, size_words & 0xFFF);

    while (written < size_words) {
        int timeout = HWICAP_TIMEOUT;
        while (mmio_read32(HWICAP_WFV) == 0 && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout WFV\n");
            return -1;
        }

        uint32_t vacancy = mmio_read32(HWICAP_WFV);
        uint32_t to_write = vacancy;
        if (to_write > (size_words - written))
            to_write = size_words - written;

        for (uint32_t i = 0; i < to_write; i++)
            mmio_write32(HWICAP_WF, data[written++]);

        hwicap_start_write(HWICAP_CR_WRITE);

        timeout = HWICAP_TIMEOUT;
        while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout flush bloc\n");
            return -1;
        }
    }

    return 0;
}

// =============================================================================
// Lecture IDCODE via ICAP
// =============================================================================

static void hwicap_read_idcode(void) {
    printf("\n[HWICAP] Test IDCODE\n");

    static const uint32_t seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF, 0xAA995566, 0x20000000,
        0x20000000, 0x28018001, 0x20000000, 0x20000000,
        0x20000000, 0x20000000
    };

    mmio_write32(HWICAP_SZ, 10);
    for (int i = 0; i < 10; i++)
        mmio_write32(HWICAP_WF, seq[i]);

    hwicap_start_write(HWICAP_CR_WRITE);

    for (volatile int i = 0; i < 10000; i++);  // petite attente

    printf("[HWICAP] RFO = %lu\n", mmio_read32(HWICAP_RFO));

    printf("[HWICAP] Lecture FIFO:\n");
    for (int i = 0; i < 8; i++) {
        uint32_t val = mmio_read32(HWICAP_RF);
        printf("  RF[%d] = 0x%08lx\n", i, (unsigned long)val);
    }

    printf("[HWICAP] IDCODE attendu = 0x03647093 (XC7K325T)\n");
}

// =============================================================================
// Test DPR principal
// =============================================================================

void hwicap_test(void) {
    printf("=================================\n");
    printf(" HWICAP BASIC TEST\n");
    printf("=================================\n");

    // Test lecture IDCODE
    hwicap_read_idcode();

    // Ici tu peux ajouter les bitstreams partiels pour reconfig DPR
    // Exemple : hwicap_write_bitstream(bs_accel1, BS_ACCEL1_WORDS);
}

// =============================================================================
// Init bare-metal
// =============================================================================
 void hwicap_test_min(void) {
    // SZ = 1 mot
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_WF, 0x20000000); // NOOP
    hwicap_start_write(HWICAP_CR_WRITE);

    for (volatile int i = 0; i < 10000; i++);

    printf("RFO=%lu SR=0x%08lx\n",
           mmio_read32(HWICAP_RFO),
           (unsigned long)mmio_read32(HWICAP_SR));
}