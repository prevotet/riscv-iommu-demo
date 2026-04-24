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
#define HWICAP_TIMEOUT   10000000

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
    printf("[HWICAP] %s : SR=0x%08x WFV=0x%02x RFO=0x%02x\r\n",
           label,
           (unsigned int)mmio_read32(HWICAP_SR),
           (unsigned int)mmio_read32(HWICAP_WFV),
           (unsigned int)mmio_read32(HWICAP_RFO));
}

static void hwicap_diag(void) {
    printf("[HWICAP] === DIAG ===\r\n");

    // Test R/W sur SZ (registre safe, 12 bits, pas d'effet de bord)
    uint32_t sz_orig = mmio_read32(HWICAP_SZ);
    mmio_write32(HWICAP_SZ, 0xAA);
    uint32_t sz_rb = mmio_read32(HWICAP_SZ);
    mmio_write32(HWICAP_SZ, sz_orig);
    printf("[HWICAP] SZ write 0xAA -> readback = 0x%08x (%s)\r\n",
           (unsigned int)sz_rb,
           (sz_rb & 0xFFF) == 0xAA ? "OK" : "FAIL - shift probable");

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

static void hwicap_fifo_reset(void) {
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    int timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
    mmio_write32(HWICAP_CR, 0x00);
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
        0x28018001,              // Type 1 Read IDCODE (reg 12), 1 word
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
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);

    print_status("apres write");
    for (volatile int i = 0; i < 100000; i++);

    // Déclencher lecture
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);

    timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && timeout-- > 0);

    print_status("apres read");

    uint32_t idcode = mmio_read32(HWICAP_RF);
    printf("[HWICAP] IDCODE = 0x%08x (attendu 0x0362D093)\r\n",
           (unsigned int)idcode);

    if (idcode == 0x0362D093)
        printf("[HWICAP] [OK] IDCODE correct\r\n");
    else
        printf("[HWICAP] [FAIL] IDCODE inattendu\r\n");

    // DESYNC : remet l'ICAP en état IDLE avant toute écriture de bitstream
    static const uint32_t desync_seq[] = {
        0x20000000,  // NOOP
        0x30008001,  // Type 1 Write 1 word → CMD register
        0x0000000D,  // DESYNC
        0x20000000,  // NOOP
        0x20000000,  // NOOP
    };
    uint32_t nd = sizeof(desync_seq)/sizeof(desync_seq[0]);
    hwicap_fifo_reset();
    mmio_write32(HWICAP_SZ, nd);
    for (uint32_t i = 0; i < nd; i++)
        mmio_write32(HWICAP_WF, desync_seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    int timeout2 = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout2-- > 0);
    print_status("apres desync");
}

// =============================================================================
// Écriture bitstream via HWICAP
//
// Les .bin Vivado sont écrits directement dans WF — PAS de bswap logiciel.
// L'IP HWICAP fait le bit-swap interne (SWAP_BITS) avant d'envoyer à ICAP.
// =============================================================================

static void hwicap_dump_bs_header(const uint32_t *data, uint32_t nwords) {
    printf("[BS] Premiers mots (écrits tels quels dans WF) :\r\n");
    uint32_t n = nwords < 8 ? nwords : 8;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t raw = data[i];
        printf("  [%u] 0x%08x", (unsigned)i, (unsigned)raw);
        if (raw == 0xAA995566) printf(" <- SYNC WORD");
        if (raw == 0xFFFFFFFF) printf(" <- DUMMY");
        if (raw == 0xBB000000) printf(" <- BUS WIDTH DETECT (LE)");
        printf("\r\n");
    }
}

// Lecture du registre STAT de l'ICAP (reg 7) via séquence de lecture config
// STAT bits utiles (UG470) :
//   bit  7 : WRERR_B  (0 = write error occurred)
//   bit 14 : INIT_B   (1 = init done)
//   bit 16 : DONE     (1 = configuration done)
static void hwicap_read_stat(void) {
    hwicap_fifo_reset();

    static const uint32_t seq[] = {
        0xFFFFFFFF,  // dummy
        0xAA995566,  // sync
        0x20000000,  // NOOP
        0x2800E001,  // Type1 Read STAT (reg 7), 1 word
        0x20000000, 0x20000000, 0x20000000, 0x20000000,  // NOOP x4
    };
    uint32_t n = sizeof(seq)/sizeof(seq[0]);
    mmio_write32(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++)
        mmio_write32(HWICAP_WF, seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    int t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0);

    for (volatile int i = 0; i < 100000; i++);

    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);
    t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && t-- > 0);

    uint32_t stat = mmio_read32(HWICAP_RF);
    printf("[ICAP] STAT = 0x%08x", (unsigned)stat);
    printf(" WRERR_B=%d", (stat >> 7) & 1);
    printf(" INIT_B=%d", (stat >> 14) & 1);
    printf(" DONE=%d", (stat >> 16) & 1);
    printf("\r\n");
    if (!((stat >> 7) & 1))
        printf("[ICAP] [WARN] WRERR_B=0 : une erreur d'écriture a été détectée\r\n");
    if (!((stat >> 16) & 1))
        printf("[ICAP] [WARN] DONE=0 : configuration non terminée\r\n");

    // DESYNC
    static const uint32_t desync[] = {
        0x20000000, 0x30008001, 0x0000000D,
        0x20000000, 0x20000000,
    };
    hwicap_fifo_reset();
    mmio_write32(HWICAP_SZ, 5);
    for (uint32_t i = 0; i < 5; i++)
        mmio_write32(HWICAP_WF, desync[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0);
}

static void hwicap_check_sr(const char *label) {
    uint32_t sr = mmio_read32(HWICAP_SR);
    printf("[HWICAP] SR après %s : 0x%08x", label, (unsigned)sr);
    if (sr & 0x1) printf(" DONE");
    if (sr & 0x2) printf(" HANG/ERR");
    if (sr & 0x4) printf(" EOS");
    printf("\r\n");
    if (sr & 0x2)
        printf("[HWICAP] [WARN] ICAP signale une erreur (hang bit)\r\n");
}

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    hwicap_fifo_reset();
    print_status("debut write_bitstream");

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
            while (mmio_read32(HWICAP_WFV) == 0 && timeout-- > 0);
            if (timeout <= 0) {
                printf("[HWICAP] ERROR: timeout WFV mot %u\r\n",
                       (unsigned int)(written + sent));
                print_status("timeout WFV");
                return -1;
            }

            uint32_t vacancy = mmio_read32(HWICAP_WFV);
            uint32_t to_write = chunk - sent;
            if (to_write > vacancy) to_write = vacancy;

            for (uint32_t i = 0; i < to_write; i++)
                mmio_write32(HWICAP_WF, data[written + sent++]);
        }

        // Déclencher
        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

        // Attendre CR_WRITE remis à 0 par la machine d'état
        int timeout = HWICAP_TIMEOUT;
        while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout CR mot %u\r\n",
                   (unsigned int)written);
            print_status("timeout CR");
            return -1;
        }

        written += chunk;
    }

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
    hwicap_read_idcode();

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
    hwicap_dump_bs_header(bs_accel1, BS_ACCEL1_WORDS);
    if (hwicap_write_bitstream(bs_accel1, BS_ACCEL1_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel1 échouée\r\n");
        return;
    }
    hwicap_check_sr("DPR accel1");
    hwicap_read_stat();
    printf("[OK] accel1 reconfiguré\r\n");

    printf("\r\n[3] Reconfiguration accel2...\r\n");
    const uint32_t *bs_accel2 = (const uint32_t *)BS_ACCEL2_ADDR;
    hwicap_dump_bs_header(bs_accel2, BS_ACCEL2_WORDS);
    if (hwicap_write_bitstream(bs_accel2, BS_ACCEL2_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel2 échouée\r\n");
        return;
    }
    hwicap_check_sr("DPR accel2");
    printf("[OK] accel2 reconfiguré\r\n");

    printf("\r\n[3b] Re-lecture IDCODE post-DPR (vérifie que l'ICAP répond encore)\r\n");
    hwicap_read_idcode();

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