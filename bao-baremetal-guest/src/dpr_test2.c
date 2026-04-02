/**
 * hwicap_dpr_test.c — Test complet DPR avec HWICAP
 *
 * Prérequis :
 *   - eos_in = 1'b1 dans ariane_peripherals_xilinx.sv
 *   - Bitstreams partiels en DDR à BS_ACCEL1_ADDR et BS_ACCEL2_ADDR
 *
 * Scénario :
 *   1. Lire IDCODE FPGA via ICAP
 *   2. Reconfigurer accel1 et accel2 avec bitstreams partiels
 *   3. Vérifier les IDs post-reconfiguration
 */

#include <stdint.h>
#include <stdio.h>

// -----------------------------------------------------------------------------
// Base addresses
// -----------------------------------------------------------------------------
#define ACCEL1_BASE    0x50000000ULL
#define ACCEL2_BASE    0x50001000ULL
#define HWICAP_BASE    0x40010000ULL

// -----------------------------------------------------------------------------
// HWICAP registers
// -----------------------------------------------------------------------------
#define HWICAP_WF   (HWICAP_BASE + 0x100)
#define HWICAP_RF   (HWICAP_BASE + 0x104)
#define HWICAP_SZ   (HWICAP_BASE + 0x108)
#define HWICAP_CR   (HWICAP_BASE + 0x10C)
#define HWICAP_SR   (HWICAP_BASE + 0x110)
#define HWICAP_WFV  (HWICAP_BASE + 0x114)
#define HWICAP_RFO  (HWICAP_BASE + 0x118)

// Control bits
#define HWICAP_CR_WRITE  (1u << 4)

// FIFO parameters
#define HWICAP_WFV_MAX   0x3F
#define HWICAP_TIMEOUT   10000000

// -----------------------------------------------------------------------------
// Bitstreams partiels (DDR)
#define BS_ACCEL1_ADDR  0x81000000ULL
#define BS_ACCEL2_ADDR  0x81300000ULL
#define BS_ACCEL1_WORDS 534818UL
#define BS_ACCEL2_WORDS 1030202UL

// -----------------------------------------------------------------------------
// Helpers MMIO
// -----------------------------------------------------------------------------
static inline uint32_t mmio_read32(uint64_t addr) {
    return *(volatile uint32_t *)addr;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
}

// -----------------------------------------------------------------------------
// ICAP trigger
// -----------------------------------------------------------------------------
static void hwicap_start_write(uint32_t cr_val) {
    mmio_write32(HWICAP_CR, cr_val);
}

// -----------------------------------------------------------------------------
// HWICAP IDCODE
// -----------------------------------------------------------------------------
static void hwicap_read_idcode(void) {
    printf("\n[HWICAP] Lecture IDCODE FPGA\n");

    static const uint32_t seq[] = {
        0xFFFFFFFF,  // dummy
        0xFFFFFFFF,  // dummy
        0xAA995566,  // sync
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x28018001,  // Type1 Read IDCODE (1 word)
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x20000000,  // NOOP
    };

    // Taille = nombre de mots de la séquence
    mmio_write32(HWICAP_SZ, sizeof(seq)/sizeof(seq[0]));

    for (int i = 0; i < sizeof(seq)/sizeof(seq[0]); i++)
        mmio_write32(HWICAP_WF, seq[i]);

    hwicap_start_write(HWICAP_CR_WRITE);

    // Petite attente pour FIFO
    for (volatile int i = 0; i < 10000; i++);

    // Lire le résultat depuis RF
    uint32_t idcode = mmio_read32(HWICAP_RF);
    printf("[HWICAP] IDCODE lu = 0x%08lx (attendu 0x03647093)\n",
           (unsigned long)idcode);
}

// -----------------------------------------------------------------------------
// HWICAP write bitstream
// -----------------------------------------------------------------------------
static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    uint32_t written = 0;

    while (written < size_words) {
        int timeout = HWICAP_TIMEOUT;

        // Attendre WFV > 0
        while (mmio_read32(HWICAP_WFV) == 0 && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout WFV mot %lu\n", (unsigned long)written);
            return -1;
        }

        // Combien de mots on peut écrire
        uint32_t vacancy = mmio_read32(HWICAP_WFV);
        uint32_t to_write = (size_words - written) < vacancy ? (size_words - written) : vacancy;

        // Remplir FIFO
        for (uint32_t i = 0; i < to_write; i++)
            mmio_write32(HWICAP_WF, data[written++]);

        // Déclencher l'écriture
        hwicap_start_write(HWICAP_CR_WRITE);

        // Attendre que FIFO se vide
        timeout = HWICAP_TIMEOUT;
        while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout flush bloc mot %lu\n", (unsigned long)written);
            return -1;
        }
    }

    printf("[HWICAP] Bitstream %lu mots envoyé avec succès\n", (unsigned long)size_words);
    return 0;
}

// -----------------------------------------------------------------------------
// DPR test principal
// -----------------------------------------------------------------------------
void dpr_test2(void) {
    printf("\n=================================================\n");
    printf(" DPR Test — Lecture IDCODE + Reconfiguration\n");
    printf("=================================================\n");

    // 1️⃣ Lecture IDCODE
    hwicap_read_idcode();

    // 2️⃣ Reconfiguration partielle
    const uint32_t *bs_accel1 = (const uint32_t *)BS_ACCEL1_ADDR;
    const uint32_t *bs_accel2 = (const uint32_t *)BS_ACCEL2_ADDR;

    printf("\n[HWICAP] Reconfiguration accel1...\n");
    if (hwicap_write_bitstream(bs_accel1, BS_ACCEL1_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel1 échouée\n");
        return;
    }

    printf("[HWICAP] Reconfiguration accel2...\n");
    if (hwicap_write_bitstream(bs_accel2, BS_ACCEL2_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel2 échouée\n");
        return;
    }

    printf("\n[HWICAP] DPR terminé — vérifier les IDs des accélérateurs\n");

    uint64_t id1 = *(volatile uint64_t *)ACCEL1_BASE;
    uint64_t id2 = *(volatile uint64_t *)ACCEL2_BASE;

    printf("  accel1 ID = 0x%08lx%08lx\n",
           (unsigned long)(id1 >> 32),
           (unsigned long)(id1 & 0xFFFFFFFF));
    printf("  accel2 ID = 0x%08lx%08lx\n",
           (unsigned long)(id2 >> 32),
           (unsigned long)(id2 & 0xFFFFFFFF));
}

