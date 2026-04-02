/**
 * dpr_test.c — Test DPR + HWICAP
 *
 * Note importante sur le convertisseur AXI 64→32 bits :
 *   Le xlnx_axi_dwidth_converter bufferise le 1er mot de chaque paire 64 bits.
 *   Il faut toujours écrire par paires via write64 pour que les données
 *   arrivent effectivement dans la FIFO HWICAP.
 *   → Toutes les écritures WF se font via mmio_write64.
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

// CR bits (Xilinx embeddedsw SDK)
#define HWICAP_CR_WRITE    0x01
#define HWICAP_CR_READ     0x02
#define HWICAP_CR_FIFO_RST 0x04

#define HWICAP_WFV_MAX   0x3F
#define HWICAP_TIMEOUT   10000000

// =============================================================================
// Bitstreams partiels (DDR)
// =============================================================================

#define BS_ACCEL1_ADDR  0x81000000ULL
#define BS_ACCEL2_ADDR  0x81300000ULL
#define BS_ACCEL1_WORDS 534818UL
#define BS_ACCEL2_WORDS 1030202UL

// NOOP ICAP
#define ICAP_NOOP 0x20000000UL

// =============================================================================
// MMIO helpers
// =============================================================================

static inline uint32_t mmio_read32(uint64_t addr) {
    return *(volatile uint32_t *)addr;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
}

// Écriture 64 bits — envoie 2 mots dans la FIFO en une transaction
// Le convertisseur 64→32 bits libère les 2 mots simultanément
static inline void hwicap_write_pair(uint32_t w0, uint32_t w1) {
    *(volatile uint64_t *)HWICAP_WF = ((uint64_t)w1 << 32) | w0;
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

// Aligne le convertisseur 64→32 en envoyant une paire de NOOPs
// À appeler au début de chaque session d'écriture
static void hwicap_align(void) {
    hwicap_write_pair(ICAP_NOOP, ICAP_NOOP);
    printf("[HWICAP] align : WFV=0x%02lx\r\n",
           (unsigned long)mmio_read32(HWICAP_WFV));
}

// =============================================================================
// Lecture IDCODE via ICAP (UG470 7-series)
// =============================================================================

static void hwicap_read_idcode(void) {
    printf("\r\n[HWICAP] Lecture IDCODE FPGA\r\n");
    print_status("init");

    hwicap_align();

    // Séquence de lecture IDCODE
    static const uint32_t seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF,  // dummy words
        0xAA995566,              // sync word
        0x20000000, 0x20000000,  // NOOP
        0x28018001,              // Type 1 Read IDCODE (1 word)
        0x20000000, 0x20000000,  // NOOP
        0x20000000, 0x20000000,  // NOOP
    };

    uint32_t n = sizeof(seq)/sizeof(seq[0]);
    mmio_write32(HWICAP_SZ, n);

    // Envoyer par paires
    for (uint32_t i = 0; i < n; i += 2)
        hwicap_write_pair(seq[i], seq[i+1]);

    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    // Attendre CR_WRITE remis à 0
    int timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);

    print_status("apres write");
    for (volatile int i = 0; i < 100000; i++);

    // Déclencher la lecture
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);

    timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && timeout-- > 0);

    print_status("apres read");

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
//
// Protocole :
//   - Aligner le convertisseur au début
//   - Chunks de max 4094 mots (pair, SZ 12 bits max 4095)
//   - Écrire SZ, remplir FIFO par paires de 2 mots (write64)
//   - Déclencher CR_WRITE, attendre CR=0
//   - PAS de reset FIFO entre chunks
//   - PAS de bswap (l'IP fait le bit-swap interne)
// =============================================================================

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    hwicap_align();
    print_status("debut write_bitstream");

    uint32_t written = 0;

    while (written < size_words) {

        // Chunk pair de max 4094 mots
        uint32_t chunk = size_words - written;
        if (chunk > 4094) chunk = 4094;
        if (chunk % 2 != 0) chunk--;  // forcer multiple de 2

        mmio_write32(HWICAP_SZ, chunk);

        // Remplir FIFO par paires
        uint32_t sent = 0;
        while (sent < chunk) {

            // Attendre au moins 2 places libres
            int timeout = HWICAP_TIMEOUT;
            while (mmio_read32(HWICAP_WFV) < 2 && timeout-- > 0);
            if (timeout <= 0) {
                printf("[HWICAP] ERROR: timeout WFV mot %lu\r\n",
                       (unsigned long)(written + sent));
                print_status("timeout WFV");
                return -1;
            }

            hwicap_write_pair(data[written + sent],
                              data[written + sent + 1]);
            sent += 2;
        }

        // Déclencher
        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

        // Attendre CR_WRITE remis à 0 par la machine d'état
        int timeout = HWICAP_TIMEOUT;
        while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout CR mot %lu\r\n",
                   (unsigned long)written);
            print_status("timeout CR");
            return -1;
        }

        written += chunk;
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

    hwicap_read_idcode();

    asm volatile ("fence" ::: "memory");
    uint64_t id1 = *(volatile uint64_t *)ACCEL1_BASE;
    uint64_t id2 = *(volatile uint64_t *)ACCEL2_BASE;
    printf("\r\n[1] IDs initiaux :\r\n");
    printf("  accel1 = 0x%08lx%08lx\r\n",
           (unsigned long)(id1 >> 32), (unsigned long)(id1 & 0xFFFFFFFF));
    printf("  accel2 = 0x%08lx%08lx\r\n",
           (unsigned long)(id2 >> 32), (unsigned long)(id2 & 0xFFFFFFFF));

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