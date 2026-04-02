/**
 * dpr_test.c — Test DPR + HWICAP debug
 */

#include <stdint.h>
#include <stdio.h>

// =============================================================================
// Adresses
// =============================================================================

#define ACCEL1_BASE    0x50000000ULL
#define ACCEL2_BASE    0x50001000ULL
#define HWICAP_BASE    0x40010000ULL

#define HWICAP_WF   (HWICAP_BASE + 0x100)
#define HWICAP_RF   (HWICAP_BASE + 0x104)
#define HWICAP_SZ   (HWICAP_BASE + 0x108)
#define HWICAP_CR   (HWICAP_BASE + 0x10C)
#define HWICAP_SR   (HWICAP_BASE + 0x110)
#define HWICAP_WFV  (HWICAP_BASE + 0x114)
#define HWICAP_RFO  (HWICAP_BASE + 0x118)

// CR bits
#define HWICAP_CR_WRITE  (1u << 4)  // cr_i(0) = Send_wr = bit 4 CPU
#define HWICAP_CR_FIFO_RST (1u << 2) // cr_i(2) = fifo_rst = bit 2 CPU

#define HWICAP_WFV_MAX   0x3F
#define HWICAP_TIMEOUT   10000000

// =============================================================================
// Bitstreams partiels (DDR)
// =============================================================================

#define BS_ACCEL1_ADDR  0x81000000ULL
#define BS_ACCEL2_ADDR  0x81300000ULL
#define BS_ACCEL1_WORDS 534818UL
#define BS_ACCEL2_WORDS 1030202UL

// =============================================================================
// MMIO helpers
// =============================================================================

static inline uint32_t mmio_read32(uint64_t addr) {
    return *(volatile uint32_t *)addr;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
}

// =============================================================================
// Override arch_init — évite les CSRs S-mode sans SBI
// =============================================================================

void arch_init(void) {
    // Pas de PLIC, pas d'interruptions en mode standalone
}

// =============================================================================
// Utilitaires HWICAP
// =============================================================================

static void print_status(const char *label) {
    printf("[HWICAP] %s : SR=0x%08lx WFV=0x%02lx RFO=0x%02lx\r\n",
           label,
           (unsigned long)mmio_read32(HWICAP_SR),
           (unsigned long)mmio_read32(HWICAP_WFV),
           (unsigned long)mmio_read32(HWICAP_RFO));
}

// Reset de la FIFO — à appeler avant chaque write_bitstream
static void hwicap_fifo_reset(void) {
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    int timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
    printf("[HWICAP] FIFO reset : WFV=0x%02lx\r\n",
           (unsigned long)mmio_read32(HWICAP_WFV));
}

// =============================================================================
// Lecture IDCODE via ICAP (UG470 7-series)
// =============================================================================

static void hwicap_read_idcode(void) {
    printf("\r\n[HWICAP] Lecture IDCODE FPGA\r\n");

    // Reset FIFO avant test
    hwicap_fifo_reset();

    static const uint32_t seq[] = {
        0xFFFFFFFF,  // dummy
        0xFFFFFFFF,  // dummy
        0xAA995566,  // sync word
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x28018001,  // Type 1 Read IDCODE (1 word)
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x20000000,  // NOOP
    };

    mmio_write32(HWICAP_SZ, sizeof(seq)/sizeof(seq[0]));
    print_status("avant sequence");

    for (int i = 0; i < (int)(sizeof(seq)/sizeof(seq[0])); i++)
        mmio_write32(HWICAP_WF, seq[i]);

    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    // Attendre FIFO vidée
    int timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);

    print_status("apres sequence");

    // Attente supplémentaire pour que l'ICAP place la donnée
    for (volatile int i = 0; i < 100000; i++);

    uint32_t rfo = mmio_read32(HWICAP_RFO);
    printf("[HWICAP] RFO = 0x%02lx\r\n", (unsigned long)rfo);

    uint32_t idcode = mmio_read32(HWICAP_RF);
    printf("[HWICAP] IDCODE = 0x%08lx (attendu 0x03647093)\r\n",
           (unsigned long)idcode);

    if (idcode == 0x03647093)
        printf("[HWICAP] [OK] IDCODE correct\r\n");
    else
        printf("[HWICAP] [FAIL] IDCODE inattendu\r\n");
}

// =============================================================================
// Écriture bitstream via HWICAP
// =============================================================================

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    hwicap_fifo_reset();
    print_status("debut write_bitstream");

    uint32_t written = 0;

    while (written < size_words) {

        // Taille du chunk (max 4095 pour SZ sur 12 bits)
        uint32_t chunk = size_words - written;
        if (chunk > 4095) chunk = 4095;

        // Écrire SZ = taille du chunk complet
        mmio_write32(HWICAP_SZ, chunk);

        uint32_t sent = 0;
        while (sent < chunk) {

            // Attendre WFV > 0
            int timeout = HWICAP_TIMEOUT;
            while (mmio_read32(HWICAP_WFV) == 0 && timeout-- > 0);
            if (timeout <= 0) {
                printf("[HWICAP] ERROR: timeout WFV mot %lu\r\n",
                       (unsigned long)(written + sent));
                return -1;
            }

            // Remplir la FIFO autant que possible dans ce chunk
            uint32_t vacancy = mmio_read32(HWICAP_WFV);
            uint32_t to_write = chunk - sent;
            if (to_write > vacancy) to_write = vacancy;

            for (uint32_t i = 0; i < to_write; i++)
                mmio_write32(HWICAP_WF, data[written + sent++]);
        }

        // Déclencher une seule fois après avoir rempli tout le chunk
        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

        // Attendre SR_DONE avant le prochain chunk
        int timeout = HWICAP_TIMEOUT;
        while (!(mmio_read32(HWICAP_SR) & 0x01) && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout SR_DONE chunk mot %lu\r\n",
                   (unsigned long)written);
            print_status("timeout SR_DONE");
            return -1;
        }

        // Attendre que la FIFO se vide
        timeout = HWICAP_TIMEOUT;
        while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout flush chunk mot %lu\r\n",
                   (unsigned long)written);
            print_status("timeout flush");
            return -1;
        }

        written += chunk;
          // Reset FIFO entre les chunks
        if (written < size_words) {
            hwicap_fifo_reset();}
    }

    print_status("fin write_bitstream");
    printf("[HWICAP] %lu mots envoyés\r\n", (unsigned long)size_words);
    return 0;
}
// =============================================================================
// Test DPR principal
// =============================================================================

void dpr_test(void) {
    printf("\r\n=================================================\r\n");
    printf(" DPR Test — Lecture IDCODE + Reconfiguration\r\n");
    printf("=================================================\r\n");

    // Lecture IDCODE
    hwicap_read_idcode();

    // IDs initiaux
    asm volatile ("fence" ::: "memory");
    uint64_t id1 = *(volatile uint64_t *)ACCEL1_BASE;
    uint64_t id2 = *(volatile uint64_t *)ACCEL2_BASE;
    printf("\r\n[1] IDs initiaux :\r\n");
    printf("  accel1 = 0x%08lx%08lx\r\n",
           (unsigned long)(id1 >> 32), (unsigned long)(id1 & 0xFFFFFFFF));
    printf("  accel2 = 0x%08lx%08lx\r\n",
           (unsigned long)(id2 >> 32), (unsigned long)(id2 & 0xFFFFFFFF));

    // Reconfiguration accel1
    printf("\r\n[2] Reconfiguration accel1...\r\n");
    const uint32_t *bs_accel1 = (const uint32_t *)BS_ACCEL1_ADDR;
    if (hwicap_write_bitstream(bs_accel1, BS_ACCEL1_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel1 échouée\r\n");
        return;
    }
    printf("[OK] accel1 reconfiguré\r\n");

    // Reconfiguration accel2
    printf("\r\n[3] Reconfiguration accel2...\r\n");
    const uint32_t *bs_accel2 = (const uint32_t *)BS_ACCEL2_ADDR;
    if (hwicap_write_bitstream(bs_accel2, BS_ACCEL2_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel2 échouée\r\n");
        return;
    }
    printf("[OK] accel2 reconfiguré\r\n");

    // IDs post-reconfiguration
    asm volatile ("fence" ::: "memory");
    id1 = *(volatile uint64_t *)ACCEL1_BASE;
    id2 = *(volatile uint64_t *)ACCEL2_BASE;
    printf("\r\n[4] IDs post-reconfiguration :\r\n");
    printf("  accel1 = 0x%08lx%08lx\r\n",
           (unsigned long)(id1 >> 32), (unsigned long)(id1 & 0xFFFFFFFF));
    printf("  accel2 = 0x%08lx%08lx\r\n",
           (unsigned long)(id2 >> 32), (unsigned long)(id2 & 0xFFFFFFFF));

    if ((id1 & 0xFFFFFF) == 0xBBBBBB && (id2 & 0xFFFFFF) == 0xBBBBBB)
        printf("[OK] accel_B détecté — DPR réussi !\r\n");
    else
        printf("[FAIL] IDs inattendus\r\n");

    printf("\r\n=================================================\r\n");
    printf(" Test terminé\r\n");
    printf("=================================================\r\n");
}