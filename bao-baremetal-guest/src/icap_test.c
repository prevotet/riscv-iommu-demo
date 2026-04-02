/**
 * icap_test.c — Test diagnostique de l'ICAP via AXI HWICAP
 *
 * Objectif : vérifier que l'ICAPE2 répond correctement en lecture
 *            (IDCODE) et en écriture (NOOP).
 *
 * Appel depuis main.c :
 *   void icap_test(void);
 */

#include <stdint.h>
#include <stdio.h>

// =============================================================================
// Registres AXI HWICAP
// =============================================================================

#define HWICAP_BASE  0x40010000ULL

#define HWICAP_WF    (HWICAP_BASE + 0x100)  // Write FIFO data
#define HWICAP_RF    (HWICAP_BASE + 0x104)  // Read FIFO data
#define HWICAP_SZ    (HWICAP_BASE + 0x108)  // Size register
#define HWICAP_CR    (HWICAP_BASE + 0x10C)  // Control register
#define HWICAP_SR    (HWICAP_BASE + 0x110)  // Status register
#define HWICAP_WFV   (HWICAP_BASE + 0x114)  // Write FIFO Vacancy
#define HWICAP_RFO   (HWICAP_BASE + 0x118)  // Read FIFO Occupancy

// CR bits (VHDL big-endian : cr_i(0 to 4) = Bus2IP_Data(27 to 31))
// cr_i(0) = Send_wr = bit 4 CPU
// cr_i(3) = Send_rd = bit 1 CPU  (à confirmer)
#define HWICAP_CR_WRITE  (1u << 4)   // 0x10 — déclenche écriture vers ICAP
#define HWICAP_CR_READ   (1u << 3)   // 0x08 — déclenche lecture depuis ICAP

// SR bits
// bit 0 : send_done
// bit 1 : hang
// bit 2 : eos
#define HWICAP_SR_DONE   (1u << 0)
#define HWICAP_SR_EOS    (1u << 2)

#define HWICAP_WFV_MAX   0x3F
#define HWICAP_TIMEOUT   10000000

// =============================================================================
// MMIO helpers
// =============================================================================

static inline uint32_t rd32(uint64_t addr) {
    return *(volatile uint32_t *)addr;
}

static inline void wr32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
}

// =============================================================================
// Utilitaires HWICAP
// =============================================================================

static void dump_regs(const char *label) {
    uint32_t sr  = rd32(HWICAP_SR);
    uint32_t wfv = rd32(HWICAP_WFV);
    uint32_t rfo = rd32(HWICAP_RFO);
    printf("  [%s] SR=0x%08lx (DONE=%lu HANG=%lu EOS=%lu) WFV=0x%02lx RFO=0x%02lx\r\n",
           label,
           (unsigned long)sr,
           (unsigned long)(sr & 1),
           (unsigned long)((sr >> 1) & 1),
           (unsigned long)((sr >> 2) & 1),
           (unsigned long)wfv,
           (unsigned long)rfo);
}

// Écrire des mots dans la FIFO et déclencher l'ICAP
static int icap_write(const uint32_t *data, uint32_t n) {
    // Écrire SZ
    wr32(HWICAP_SZ, n & 0xFFF);

    // Attendre place dans FIFO
    int timeout = HWICAP_TIMEOUT;
    while (rd32(HWICAP_WFV) < n && timeout-- > 0);
    if (timeout <= 0) {
        printf("  ERROR: FIFO pas assez de place (%lu mots demandés, WFV=0x%08lx)\r\n",
               (unsigned long)n, (unsigned long)rd32(HWICAP_WFV));
        return -1;
    }

    // Remplir FIFO
    for (uint32_t i = 0; i < n; i++) {
        printf("    WF[%lu] = 0x%08lx\r\n", (unsigned long)i, (unsigned long)data[i]);
        wr32(HWICAP_WF, data[i]);
    }

    // Déclencher (pulse)
    wr32(HWICAP_CR, HWICAP_CR_WRITE);
    wr32(HWICAP_CR, 0);

    // Attendre FIFO vidée
    timeout = HWICAP_TIMEOUT;
    while (rd32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
    if (timeout <= 0) {
        printf("  ERROR: timeout flush FIFO\r\n");
        return -1;
    }

    return 0;
}

// =============================================================================
// Test 1 — NOOP simple
// =============================================================================

static void test_noop(void) {
    printf("\r\n--- Test 1 : NOOP simple ---\r\n");
    dump_regs("avant");

    static const uint32_t noop[] = { 0x20000000 };
    icap_write(noop, 1);

    dump_regs("apres");
}

// =============================================================================
// Test 2 — Lecture IDCODE (UG470 7-series)
//
// Séquence :
//   1. Envoyer dummy + sync + commande read IDCODE + NOOPs
//   2. Basculer en mode lecture (CR_READ)
//   3. Lire RF
// =============================================================================

static void test_read_idcode(void) {
    printf("\r\n--- Test 2 : Lecture IDCODE ---\r\n");
    dump_regs("avant");

    // Séquence d'écriture pour demander la lecture IDCODE
    // Selon UG470 — 7-series Configuration User Guide
    static const uint32_t seq_write[] = {
        0xFFFFFFFF,  // dummy word
        0xFFFFFFFF,  // dummy word
        0xAA995566,  // sync word
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x28018001,  // Type 1 Read IDCODE — 1 word
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x20000000,  // NOOP
    };

    printf("  Envoi séquence read IDCODE...\r\n");
    if (icap_write(seq_write, 10) != 0) {
        printf("  ERROR: échec écriture séquence\r\n");
        return;
    }

    dump_regs("apres ecriture");

    // Attente supplémentaire pour que l'ICAP place la donnée sur le bus
    for (volatile int i = 0; i < 100000; i++);

    // Lire RFO pour voir si des données sont disponibles
    uint32_t rfo = rd32(HWICAP_RFO);
    printf("  RFO = 0x%08lx (mots disponibles en lecture)\r\n", (unsigned long)rfo);

    // Lire le RF
    uint32_t idcode = rd32(HWICAP_RF);
    printf("  IDCODE lu    = 0x%08lx\r\n", (unsigned long)idcode);
    printf("  IDCODE attendu = 0x03647093 (XC7K325T)\r\n");

    if (idcode == 0x03647093)
        printf("  [OK] IDCODE correct\r\n");
    else if (idcode == 0x00000000)
        printf("  [FAIL] IDCODE=0 — ICAP ne répond pas en lecture\r\n");
    else
        printf("  [WARN] IDCODE inattendu\r\n");
}

// =============================================================================
// Test 3 — Désync ICAP (remettre l'ICAP en état initial)
// =============================================================================

static void test_desync(void) {
    printf("\r\n--- Test 3 : DESYNC ICAP ---\r\n");

    static const uint32_t seq_desync[] = {
        0x20000000,  // NOOP
        0x20000000,  // NOOP
        0x30008001,  // Write CMD register (1 word)
        0x0000000D,  // DESYNC command
        0x20000000,  // NOOP
        0x20000000,  // NOOP
    };

    if (icap_write(seq_desync, 6) == 0)
        printf("  [OK] DESYNC envoyé\r\n");
    else
        printf("  [FAIL] DESYNC échoué\r\n");

    dump_regs("apres desync");
}

// =============================================================================
// Test 4 — Vérifier CR_READ (lecture active via HWICAP)
// =============================================================================

static void test_cr_read(void) {
    printf("\r\n--- Test 4 : CR_READ ---\r\n");
    dump_regs("avant");

    // D'abord envoyer la séquence de lecture
    static const uint32_t seq[] = {
        0xFFFFFFFF,
        0xAA995566,
        0x20000000,
        0x28018001,  // read IDCODE
        0x20000000,
        0x20000000,
        0x20000000,
        0x20000000,
    };

    icap_write(seq, 8);

    // Tenter CR_READ = 0x08
    printf("  Trigger CR_READ (0x08)...\r\n");
    wr32(HWICAP_CR, HWICAP_CR_READ);
    wr32(HWICAP_CR, 0);

    for (volatile int i = 0; i < 100000; i++);

    dump_regs("apres CR_READ");

    uint32_t rfo = rd32(HWICAP_RFO);
    printf("  RFO = 0x%08lx\r\n", (unsigned long)rfo);

    if (rfo > 0) {
        uint32_t val = rd32(HWICAP_RF);
        printf("  RF[0] = 0x%08lx\r\n", (unsigned long)val);
    }
}

// =============================================================================
// Point d'entrée
// =============================================================================

void icap_test(void) {
    printf("\r\n");
    printf("================================================\r\n");
    printf(" ICAP Diagnostic Test\r\n");
    printf("================================================\r\n");

    dump_regs("init");

    // Vérifier EOS
    if (!(rd32(HWICAP_SR) & HWICAP_SR_EOS)) {
        printf("  [WARN] EOS=0 — FPGA pas encore en mode normal ?\r\n");
    }

    test_noop();
    test_desync();
    test_read_idcode();
    test_cr_read();

    printf("\r\n================================================\r\n");
    printf(" ICAP Test termine\r\n");
    printf("================================================\r\n");
}