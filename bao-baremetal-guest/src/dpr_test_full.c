/**
 * dpr_test_full.c — Scénario de test DPR complet
 * 
 * Incorpore :
 *   - Reset ICAP explicite
 *   - Diagnostic de bridge 64->32
 *   - Lecture IDCODE
 *   - Reconfiguration dynamique avec mesure de cycles (Performance)
 *   - Validation Ping-Pong des IDs d'accélérateurs
 */

#include <stdint.h>
#include <stdio.h>

// =============================================================================
// Adresses et Constantes
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

#define HWICAP_CR_WRITE    0x01
#define HWICAP_CR_READ     0x02
#define HWICAP_CR_FIFO_RST 0x04

#define HWICAP_WFV_MAX   0x3F
#define HWICAP_TIMEOUT   10000000

// Bitstreams partiels (DDR) — Valeurs par défaut (à mettre à jour via 3_build_B2.sh)
#define BS_ACCEL1_ADDR  0x81000000ULL
#define BS_ACCEL2_ADDR  0x81300000ULL
#define BS_ACCEL1_WORDS 534818UL
#define BS_ACCEL2_WORDS 1030202UL

// =============================================================================
// Helpers MMIO & CSR
// =============================================================================

static inline uint32_t mmio_read32(uint64_t addr) {
    uint32_t val;
    asm volatile ("fence i, r" ::: "memory");
    val = *(volatile uint32_t *)addr;
    return val;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    // Règle d'or : Accès 32 bits alignés impératifs pour le bridge 64->32
    *(volatile uint32_t *)addr = val;
    asm volatile ("fence w, o" ::: "memory");
}

static inline uint64_t read_cycles(void) {
    uint64_t cycles;
    asm volatile ("rdcycle %0" : "=r" (cycles));
    return cycles;
}

// =============================================================================
// Diagnostic et Utilitaires
// =============================================================================

static void hwicap_reset(void) {
    printf("[HWICAP] Reset FIFO...\n");
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    int timeout = HWICAP_TIMEOUT;
    // Attendre que la FIFO soit vide (WFV = MAX)
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);

    // CRITIQUE : cr_i est un registre tenu (CONTROL_REGISTER_PROCESS, line 445 VHDL).
    // Tant que cr_i(2)=FIFO_RST=1, fifo_clear=1 → Ainit du FIFO est actif (reset async
    // permanent) → toute écriture WF est immédiatement effacée.
    // Il faut écrire 0x00 pour libérer le FIFO avant de le remplir.
    mmio_write32(HWICAP_CR, 0x00);

    uint32_t wfv = mmio_read32(HWICAP_WFV);
    uint32_t sr  = mmio_read32(HWICAP_SR);
    uint32_t cr  = mmio_read32(HWICAP_CR);

    printf("[HWICAP] Reset done: WFV=0x%02x SR=0x%02x CR=0x%02x %s\n",
           wfv, sr, cr, (timeout <= 0) ? "[TIMEOUT]" : "[OK]");
}

static void check_accel_state(int index) {
    uint64_t base = (index == 1) ? ACCEL1_BASE : ACCEL2_BASE;
    // INTERDICTION DES ACCÈS 64 BITS (GEMINI.md)
    uint32_t id_lo = mmio_read32(base);
    uint32_t id_hi = mmio_read32(base + 4);
    uint32_t suffix = (uint32_t)(id_lo & 0xFFFFFF);

    printf("[CHECK] Accel%d ID: 0x%08x%08x -> ", index, id_hi, id_lo);
    if (suffix == 0xAAAAAA) printf("ACCEL_A\n");
    else if (suffix == 0xBBBBBB) printf("ACCEL_B\n");
    else printf("INCONNU (Default/Blank)\n");
}

static void hwicap_diag_bridge(void) {
    printf("[HWICAP] Diagnostic Bridge 64->32...\n");
    uint32_t sr  = mmio_read32(HWICAP_SR);
    uint32_t wfv = mmio_read32(HWICAP_WFV);
    printf("[HWICAP] SR=0x%08x WFV=0x%02x\n", sr, wfv);
    if (wfv == 0 && sr == 0xFFFFFFFF) {
        printf("[HWICAP] [ERROR] Bridge non répondant (Bus Hang?)\n");
    } else {
        printf("[HWICAP] [OK] Bridge accessible\n");
    }
}

// =============================================================================
// Lecture IDCODE
// =============================================================================

static void hwicap_read_idcode(void) {
    printf("[HWICAP] Lecture IDCODE FPGA...\n");
    hwicap_reset();

    // Séquence pour Kintex-7 (UG470)
    static const uint32_t seq[] = {
        0xFFFFFFFF, // Dummy
        0xAA995566, // Sync Word
        0x20000000, // NOOP
        0x28012001, // Type 1 Read, Address 9 (IDCODE), 1 word
        0x20000000, // NOOP
        0x20000000  // NOOP
    };

    uint32_t n = sizeof(seq)/4;
    mmio_write32(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++) mmio_write32(HWICAP_WF, seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    int timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);

    // Lecture du résultat
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);
    timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && timeout-- > 0);

    uint32_t id = mmio_read32(HWICAP_RF);
    printf("[HWICAP] IDCODE: 0x%08x (Attendu 0x03647093 pour Genesys2)\n", id);
}

// =============================================================================
// Reconfiguration Partielle
// =============================================================================

static int hwicap_load_bs(const uint32_t *data, uint32_t size_words, const char *name) {
    printf("[DPR] Chargement %s (%lu mots)...\n", name, (unsigned long)size_words);
    hwicap_reset();

    uint64_t t_start = read_cycles();
    
    uint32_t written = 0;
    while (written < size_words) {
        uint32_t chunk = (size_words - written > HWICAP_WFV_MAX) ? HWICAP_WFV_MAX : size_words - written;
        mmio_write32(HWICAP_SZ, chunk);
        
        for (uint32_t i = 0; i < chunk; i++) {
            int timeout = HWICAP_TIMEOUT;
            while (mmio_read32(HWICAP_WFV) == 0 && timeout-- > 0);
            if (timeout <= 0) {
                printf("[HWICAP] ERROR: timeout WFV mot %lu\n",
                       (unsigned long)(written + i));
                return -1;
            }
            mmio_write32(HWICAP_WF, data[written++]);
        }
        
        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
        uint32_t cr_rb = mmio_read32(HWICAP_CR);
        uint32_t sr_rb = mmio_read32(HWICAP_SR);
        uint32_t wfv_rb = mmio_read32(HWICAP_WFV);
        printf("[HWICAP] after CR_WRITE: CR=0x%02x SR=0x%02x WFV=0x%02x\n",
               cr_rb, sr_rb, wfv_rb);
        int timeout = HWICAP_TIMEOUT;
        while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] timeout CR: CR=0x%02x SR=0x%02x WFV=0x%02x\n",
                   mmio_read32(HWICAP_CR), mmio_read32(HWICAP_SR), mmio_read32(HWICAP_WFV));
            return -1;
        }
    }
    
    uint64_t t_end = read_cycles();
    printf("[DPR] [OK] Terminé en %lu cycles\n", t_end - t_start);
    return 0;
}

// =============================================================================
// Main Scenario
// =============================================================================

void arch_init(void) {}

void dpr_test_full(void) {
    printf("\n\n");
    printf("*************************************************\n");
    printf("*   SCÉNARIO DE TEST DPR FULL - RISC-V IOMMU    *\n");
    printf("*************************************************\n");

    hwicap_diag_bridge();
    hwicap_read_idcode();

    printf("\n--- ÉTAPE 1 : État Initial ---\n");
    check_accel_state(1);
    check_accel_state(2);

    printf("\n--- ÉTAPE 2 : Reconfiguration ACCEL1 vers ACCEL_B ---\n");
    if (hwicap_load_bs((uint32_t*)BS_ACCEL1_ADDR, BS_ACCEL1_WORDS, "BS_ACCEL1") == 0) {
        check_accel_state(1);
    } else {
        printf("[ERROR] Échec reconfig ACCEL1\n");
    }

    printf("\n--- ÉTAPE 3 : Reconfiguration ACCEL2 vers ACCEL_B ---\n");
    if (hwicap_load_bs((uint32_t*)BS_ACCEL2_ADDR, BS_ACCEL2_WORDS, "BS_ACCEL2") == 0) {
        check_accel_state(2);
    } else {
        printf("[ERROR] Échec reconfig ACCEL2\n");
    }

    printf("\n--- ÉTAPE 4 : Test de Robustesse (Double Reconfig) ---\n");
    printf("[DPR] Tentative de re-reconfiguration Accel1...\n");
    hwicap_load_bs((uint32_t*)BS_ACCEL1_ADDR, BS_ACCEL1_WORDS, "BS_ACCEL1_BIS");
    check_accel_state(1);

    printf("\n*************************************************\n");
    printf("*           FIN DU SCÉNARIO DE TEST             *\n");
    printf("*************************************************\n");
}
