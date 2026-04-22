/**
 * dpr_test.c — Test DPR + HWICAP (diagnostic complet B→A)
 *
 * Séquence :
 *   1. Lire IDs accélérateurs (attendu : accel_B = 0xBBBBBB)
 *   2. Vérifier IDCODE ICAP (attendu : 0x0362D093 = XC7K325T)
 *   3. DESYNC + FIFO reset (nettoyer état ICAP résiduel)
 *   4. Valider bitstreams en DDR (sync word, taille)
 *   5. DPR accel1, lire STAT ICAP, vérifier ID accel1
 *   6. DPR accel2, lire STAT ICAP, vérifier ID accel2
 *   7. Bilan final
 *
 * Utilise uniquement mmio_write32 (instruction SW 32 bits).
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
#define HWICAP_CHUNK_MAX 32U
#define HWICAP_TIMEOUT   1000000

// =============================================================================
// Bitstreams partiels (DDR)
// =============================================================================

#define BS_ACCEL1_ADDR  0x81000000ULL
#define BS_ACCEL2_ADDR  0x81300000ULL
#define BS_ACCEL1_WORDS 534823UL
#define BS_ACCEL2_WORDS 1030207UL

// Sync word attendu dans le bitstream LU DEPUIS LA DDR en uint32_t little-endian.
// Le fichier .bin stocke les octets AA 99 55 66 (big-endian) → LE = 0x665599AA.
// Ne pas confondre avec la valeur logique 0xAA995566 (format UG470 / constantes firmware).
#define XILINX_SYNC_WORD 0x665599AAU

// IDCODE attendu pour XC7K325T-2FFG900
#define EXPECTED_IDCODE 0x0362D093U

// =============================================================================
// MMIO helpers — uniquement 32 bits
// =============================================================================

static inline uint32_t mmio_read32(uint64_t addr) {
    uint32_t val;
    asm volatile ("fence" ::: "memory");
    val = *(volatile uint32_t *)addr;
    return val;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
    asm volatile ("fence" ::: "memory");
}

static void delay(int loops) {
    for (volatile int i = 0; i < loops; i++) asm volatile("nop");
}

// =============================================================================
// Override arch_init — évite les CSRs S-mode sans SBI
// =============================================================================

void arch_init(void) {
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

static void hwicap_desync(void) {
    // Sync word inclus : si l'ICAP est desynced (état normal après un full
    // bitstream ou après un DESYNC précédent), les commandes Type 1 seraient
    // ignorées sans le sync word.
    static const uint32_t seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF,  // dummy words
        0xAA995566,              // sync word
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
    if (timeout <= 0)
        printf("[HWICAP] [WARN] desync: timeout CR\r\n");
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
}

// =============================================================================
// Lecture IDCODE via ICAP — retourne l'IDCODE lu (0 si erreur)
// =============================================================================

static uint32_t hwicap_read_idcode(void) {
    printf("\r\n[2] Lecture IDCODE FPGA via ICAP\r\n");
    hwicap_fifo_reset();

    static const uint32_t seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF,  // dummy words
        0xAA995566,              // sync word
        0x20000000, 0x20000000,  // NOOP
        0x28018001,              // Type 1 Read IDCODE Reg 0x0C (1 word)
        0x20000000, 0x20000000,  // NOOP
        0x20000000, 0x20000000,  // NOOP
    };

    uint32_t n = sizeof(seq)/sizeof(seq[0]);
    mmio_write32(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++)
        mmio_write32(HWICAP_WF, seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    int timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0) delay(10);
    if (timeout <= 0) {
        printf("  [FAIL] timeout CR apres write IDCODE\r\n");
        return 0;
    }

    delay(1000);

    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);
    timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && timeout-- > 0) delay(10);
    if (timeout <= 0) {
        printf("  [FAIL] timeout CR apres read IDCODE\r\n");
        return 0;
    }

    uint32_t rfo = mmio_read32(HWICAP_RFO);
    if (rfo == 0) {
        printf("  [FAIL] RFO=0 apres lecture IDCODE — ICAP n'a pas repondu\r\n");
        return 0;
    }

    uint32_t idcode = mmio_read32(HWICAP_RF);
    printf("  IDCODE = 0x%08x (attendu 0x%08x)\r\n",
           (unsigned)idcode, (unsigned)EXPECTED_IDCODE);

    if (idcode == EXPECTED_IDCODE)
        printf("  [OK] IDCODE correct — ICAP fonctionnel\r\n");
    else if (idcode == 0x00000000 || idcode == 0xFFFFFFFF)
        printf("  [FAIL] IDCODE=%s — ICAP probablement non connecté ou bus cassé\r\n",
               idcode == 0 ? "0x00000000" : "0xFFFFFFFF");
    else
        printf("  [WARN] IDCODE inattendu — mauvais device ou C_DEVICE_ID IP ?\r\n");

    hwicap_fifo_reset();
    hwicap_desync();
    return idcode;
}

// =============================================================================
// Lecture STAT ICAP (reg 7) — UG470 Table 5-26 (7-series)
//
// Bits importants :
//   0  CRC_ERROR    — erreur CRC dans le bitstream
//   3  CFGERR       — erreur de configuration
//   8  WRERR_B      — 0 = erreur d'écriture ICAP
//  13  ID_ERROR     — IDCODE mismatch bitstream vs device
//  16  DONE         — configuration terminée
// =============================================================================

static void hwicap_read_stat(const char *label) {
    hwicap_fifo_reset();
    static const uint32_t seq[] = {
        0xFFFFFFFF,
        0xAA995566,
        0x20000000,
        0x28038001,  // Type1 Read STAT (reg 7), 1 word
        0x20000000, 0x20000000, 0x20000000, 0x20000000,
    };
    uint32_t n = sizeof(seq)/sizeof(seq[0]);
    mmio_write32(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++)
        mmio_write32(HWICAP_WF, seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    int t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0) delay(1);
    delay(1000);
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);
    t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && t-- > 0) delay(1);
    uint32_t stat = mmio_read32(HWICAP_RF);

    unsigned crc_err  = (stat >> 0)  & 1;
    unsigned cfgerr   = (stat >> 3)  & 1;
    unsigned wrerr_b  = (stat >> 8)  & 1;
    unsigned id_err   = (stat >> 13) & 1;
    unsigned done     = (stat >> 16) & 1;

    printf("[ICAP] STAT %s = 0x%08x\r\n", label, (unsigned)stat);
    printf("  CRC_ERROR=%u  CFGERR=%u  WRERR_B=%u  ID_ERROR=%u  DONE=%u\r\n",
           crc_err, cfgerr, wrerr_b, id_err, done);

    if (crc_err)
        printf("  [DIAG] CRC_ERROR=1 : bitstream corrompu ou frame addresses incorrectes\r\n");
    if (cfgerr)
        printf("  [DIAG] CFGERR=1 : erreur de configuration (commande invalide ?)\r\n");
    if (!wrerr_b)
        printf("  [DIAG] WRERR_B=0 : erreur d'ecriture ICAP\r\n");
    if (id_err)
        printf("  [DIAG] ID_ERROR=1 : IDCODE dans le bitstream ne correspond pas au device\r\n");
    if (!done)
        printf("  [DIAG] DONE=0 : configuration non terminee\r\n");
    if (!crc_err && !cfgerr && wrerr_b && !id_err && done)
        printf("  [OK] STAT propre — pas d'erreur ICAP détectée\r\n");

    // DESYNC après lecture STAT
    static const uint32_t desync[] = {
        0x20000000, 0x30008001, 0x0000000D, 0x20000000, 0x20000000,
    };
    hwicap_fifo_reset();
    mmio_write32(HWICAP_SZ, 5);
    for (uint32_t i = 0; i < 5; i++)
        mmio_write32(HWICAP_WF, desync[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0) delay(1);
}

// =============================================================================
// Validation bitstream en DDR — vérifie la présence du sync word
// =============================================================================

static int validate_bitstream(const uint32_t *data, uint32_t size_words,
                              const char *name) {
    printf("[VALID] %s : %u mots (%u Ko) @ 0x%08x\r\n",
           name, (unsigned)size_words,
           (unsigned)(size_words * 4 / 1024),
           (unsigned)(uint64_t)data);

    if (size_words < 16) {
        printf("  [FAIL] Bitstream trop court (%u mots)\r\n", (unsigned)size_words);
        return -1;
    }

    // Afficher les 8 premiers mots
    printf("  Header:");
    for (int i = 0; i < 8; i++)
        printf(" %08x", (unsigned)data[i]);
    printf("\r\n");

    // Chercher le sync word dans les 32 premiers mots
    int sync_found = -1;
    for (int i = 0; i < 32 && i < (int)size_words; i++) {
        if (data[i] == XILINX_SYNC_WORD) {
            sync_found = i;
            break;
        }
    }

    if (sync_found < 0) {
        printf("  [FAIL] Sync word 0xAA995566 absent dans les 32 premiers mots\r\n");
        printf("  Cause probable : fichier .bin corrompu ou mauvais format\r\n");
        return -1;
    }

    printf("  [OK] Sync word trouvé à data[%d]\r\n", sync_found);

    // Vérifier que ce n'est pas que des 0xFF (DDR non initialisée)
    int all_ff = 1;
    for (int i = 0; i < 32 && i < (int)size_words; i++) {
        if (data[i] != 0xFFFFFFFF) { all_ff = 0; break; }
    }
    if (all_ff) {
        printf("  [FAIL] DDR non initialisée (tout à 0xFF)\r\n");
        return -1;
    }

    return 0;
}

// =============================================================================
// Lecture ID accélérateur — retourne les 24 bits bas
// =============================================================================

static uint32_t read_accel_id(uint64_t base, const char *name) {
    asm volatile ("fence" ::: "memory");
    uint32_t lo = mmio_read32(base);
    uint32_t hi = mmio_read32(base + 4);
    printf("  %s = 0x%08x%08x", name, hi, lo);
    uint32_t id = lo & 0xFFFFFF;
    if (id == 0xAAAAAA)      printf(" (accel_A)\r\n");
    else if (id == 0xBBBBBB) printf(" (accel_B)\r\n");
    else if (lo == 0 && hi == 0) printf(" (pas de réponse / SLVERR ?)\r\n");
    else                     printf(" (inconnu)\r\n");
    return id;
}

// =============================================================================
// Écriture bitstream via HWICAP
// =============================================================================

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    hwicap_fifo_reset();
    print_status("debut write_bitstream");

    uint32_t written = 0;

    while (written < size_words) {

        uint32_t chunk = size_words - written;
        if (chunk > HWICAP_CHUNK_MAX) chunk = HWICAP_CHUNK_MAX;

        mmio_write32(HWICAP_SZ, chunk);

        // Remplir FIFO mot par mot
        uint32_t sent = 0;
        while (sent < chunk) {
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

        // Attendre que le FIFO soit vidé (WFV=0x3F) avant le prochain chunk
        timeout = HWICAP_TIMEOUT;
        while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0) delay(10);

        written += chunk;

        if (written % 50000 < chunk) {
            printf("[HWICAP] Progression : %u / %u mots...\r\n",
                   (unsigned int)written, (unsigned int)size_words);
        }
    }

    print_status("fin write_bitstream");
    printf("[HWICAP] %u mots envoyés\r\n", (unsigned int)size_words);

    return 0;
}

// =============================================================================
// Test DPR principal — diagnostic complet B→A
// =============================================================================

void dpr_test(void) {
    printf("\r\n=================================================\r\n");
    printf(" DPR Test — Diagnostic complet B->A\r\n");
    printf("=================================================\r\n");

    int errors = 0;

    // ---- Étape 0 : état initial HWICAP ----
    printf("\r\n[0] État initial HWICAP\r\n");
    print_status("etat initial");

    // ---- Étape 1 : lire IDs accélérateurs avant DPR ----
    printf("\r\n[1] IDs initiaux (attendu: accel_B = 0xBBBBBB)\r\n");
    uint32_t init_a1 = read_accel_id(ACCEL1_BASE, "accel1");
    uint32_t init_a2 = read_accel_id(ACCEL2_BASE, "accel2");

    if (init_a1 != 0xBBBBBB || init_a2 != 0xBBBBBB)
        printf("  [WARN] IDs initiaux != accel_B — test B->A moins significatif\r\n");

    // ---- Étape 2 : IDCODE via ICAP ----
    uint32_t idcode = hwicap_read_idcode();
    if (idcode == 0) {
        printf("\r\n[ABORT] ICAP non fonctionnel — impossible de continuer\r\n");
        return;
    }
    if (idcode != EXPECTED_IDCODE) {
        printf("  [WARN] IDCODE inattendu — la DPR pourrait échouer (ID_ERROR)\r\n");
    }

    // ---- Étape 3 : STAT initiale (avant DPR) ----
    printf("\r\n[3] STAT ICAP initiale (avant DPR)\r\n");
    hwicap_read_stat("initial");

    // ---- Étape 4 : DESYNC + FIFO reset ----
    printf("\r\n[4] Preparation ICAP (DESYNC + FIFO reset)\r\n");
    hwicap_fifo_reset();
    hwicap_desync();
    hwicap_fifo_reset();
    print_status("apres desync+reset");

    // ---- Étape 5 : Valider bitstreams en DDR ----
    printf("\r\n[5] Validation bitstreams en DDR\r\n");
    const uint32_t *bs_accel1 = (const uint32_t *)BS_ACCEL1_ADDR;
    const uint32_t *bs_accel2 = (const uint32_t *)BS_ACCEL2_ADDR;

    if (validate_bitstream(bs_accel1, BS_ACCEL1_WORDS, "partial_accel_A_accel1") != 0) {
        printf("[ABORT] Bitstream accel1 invalide\r\n");
        return;
    }
    if (validate_bitstream(bs_accel2, BS_ACCEL2_WORDS, "partial_accel_A_accel2") != 0) {
        printf("[ABORT] Bitstream accel2 invalide\r\n");
        return;
    }

    // ---- Étape 6 : DPR accel1 ----
    printf("\r\n[6] Reconfiguration accel1 (%u mots)\r\n", (unsigned)BS_ACCEL1_WORDS);
    if (hwicap_write_bitstream(bs_accel1, BS_ACCEL1_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel1 échouée (timeout)\r\n");
        errors++;
    } else {
        hwicap_read_stat("apres accel1");

        // Vérifier immédiatement si accel1 a changé
        printf("  ID accel1 apres DPR :\r\n");
        uint32_t post_a1 = read_accel_id(ACCEL1_BASE, "  accel1");
        if (post_a1 == 0xAAAAAA)
            printf("  [OK] accel1 reconfiguré en accel_A\r\n");
        else if (post_a1 == init_a1)
            printf("  [FAIL] accel1 inchangé — DPR accel1 n'a pas pris effet\r\n");
        else
            printf("  [WARN] accel1 a changé mais pas vers accel_A\r\n");
    }

    // DESYNC entre les deux reconfigurations
    hwicap_fifo_reset();
    hwicap_desync();
    hwicap_fifo_reset();

    // ---- Étape 7 : DPR accel2 ----
    printf("\r\n[7] Reconfiguration accel2 (%u mots)\r\n", (unsigned)BS_ACCEL2_WORDS);
    if (hwicap_write_bitstream(bs_accel2, BS_ACCEL2_WORDS) != 0) {
        printf("[FAIL] Reconfiguration accel2 échouée (timeout)\r\n");
        errors++;
    } else {
        hwicap_read_stat("apres accel2");

        // Vérifier immédiatement si accel2 a changé
        printf("  ID accel2 apres DPR :\r\n");
        uint32_t post_a2 = read_accel_id(ACCEL2_BASE, "  accel2");
        if (post_a2 == 0xAAAAAA)
            printf("  [OK] accel2 reconfiguré en accel_A\r\n");
        else if (post_a2 == init_a2)
            printf("  [FAIL] accel2 inchangé — DPR accel2 n'a pas pris effet\r\n");
        else
            printf("  [WARN] accel2 a changé mais pas vers accel_A\r\n");
    }

    // ---- Étape 8 : Bilan final ----
    printf("\r\n=================================================\r\n");
    printf(" [8] BILAN FINAL\r\n");
    printf("=================================================\r\n");
    uint32_t final_a1 = read_accel_id(ACCEL1_BASE, "accel1");
    uint32_t final_a2 = read_accel_id(ACCEL2_BASE, "accel2");

    if (final_a1 == 0xAAAAAA && final_a2 == 0xAAAAAA) {
        printf("\r\n>>> DPR B->A REUSSI : les deux accélérateurs sont accel_A <<<\r\n");
    } else {
        printf("\r\n>>> DPR ECHOUE <<<\r\n");
        if (final_a1 == init_a1 && final_a2 == init_a2)
            printf("  Diagnostic : aucun ID n'a changé.\r\n"
                   "  Causes possibles :\r\n"
                   "    - ICAP accepte les données mais ne reconfigure pas le fabric\r\n"
                   "    - Bitstreams partiels incohérents avec static_routed.dcp\r\n"
                   "    - IDCODE mismatch dans le header du bitstream\r\n"
                   "    - Vérifier STAT ci-dessus pour CRC_ERROR / ID_ERROR / CFGERR\r\n");
        else if (final_a1 != init_a1 || final_a2 != init_a2)
            printf("  Diagnostic : au moins un ID a changé — DPR partiel.\r\n"
                   "    accel1 : 0x%06x -> 0x%06x %s\r\n"
                   "    accel2 : 0x%06x -> 0x%06x %s\r\n",
                   init_a1, final_a1, final_a1 == 0xAAAAAA ? "[OK]" : "[FAIL]",
                   init_a2, final_a2, final_a2 == 0xAAAAAA ? "[OK]" : "[FAIL]");
        printf("  errors=%d\r\n", errors);
    }

    printf("\r\n=================================================\r\n");
    printf(" Test terminé\r\n");
    printf("=================================================\r\n");
}
