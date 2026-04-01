/**
 * dpr_test.c — Test de reconfiguration partielle dynamique (DPR)
 *
 * Scénario :
 *   1. Lire les registres ID des accélérateurs (accel_A attendu)
 *   2. Reconfigurer accel1 et accel2 en accel_B via AXI HWICAP
 *   3. Relire les registres ID pour confirmer (accel_B attendu)
 *
 * Layout DDR (chargé via JTAG avant démarrage) :
 *   BITSTREAM_BASE + 0x000 : uint32_t nb_words_accel1
 *   BITSTREAM_BASE + 0x004 : uint32_t nb_words_accel2
 *   BITSTREAM_BASE + 0x008 : données partial_accel_B_accel1.bin
 *   BITSTREAM_BASE + 0x008 + nb_words_accel1*4 : données partial_accel_B_accel2.bin
 */

#include <stdint.h>
#include <stdio.h>

// =============================================================================
// Adresses SoC (depuis ariane_soc_pkg.sv)
// =============================================================================

#define ACCEL1_BASE 0x50000000ULL    // DMABase  — accel1 cfg
#define ACCEL2_BASE 0x50001000ULL    // DMA2Base — accel2 cfg
#define HWICAP_BASE 0x40010000ULL    // HWICAPBase
#define BITSTREAM_BASE 0x81000000ULL // DDR — bitstreams partiels

// =============================================================================
// AXI HWICAP — registres (UG643 / PG134)
// =============================================================================

#define HWICAP_WF (HWICAP_BASE + 0x100)  // Write FIFO data
#define HWICAP_CR (HWICAP_BASE + 0x108)  // Control Register
#define HWICAP_SR (HWICAP_BASE + 0x110)  // Status Register
#define HWICAP_WFV (HWICAP_BASE + 0x118) // Write FIFO Vacancy

// CR bits
#define HWICAP_CR_WRITE (1u << 0)

// SR bits
#define HWICAP_SR_DONE (1u << 2)
#define HWICAP_TIMEOUT 10000000

#define BS_ACCEL1_ADDR  0x81000000ULL
#define BS_ACCEL2_ADDR  0x81200000ULL  // adresse fixe, pas calculée depuis header
#define BS_ACCEL1_WORDS (TAILLE1 / 4)
#define BS_ACCEL2_WORDS (TAILLE2 / 4)

// =============================================================================
// Helpers MMIO
// =============================================================================

static inline uint64_t mmio_read64(uint64_t addr)
{
    return *(volatile uint64_t *)addr;
}

static inline uint32_t mmio_read32(uint64_t addr)
{
    return *(volatile uint32_t *)addr;
}

static inline void mmio_write32(uint64_t addr, uint32_t val)
{
    *(volatile uint32_t *)addr = val;
}

// Override arch_init pour éviter les CSRs S-mode sans SBI
void arch_init(void)
{
    // Pas de PLIC, pas d'interruptions en mode standalone
}

// =============================================================================
// Driver HWICAP
// =============================================================================

static int wait_for_condition(uint32_t (*cond)(void), uint32_t expected)
{
    int timeout = HWICAP_TIMEOUT;
    while (timeout-- > 0)
    {
        if (cond() == expected)
            return 0;
    }
    return -1;
}

static uint32_t fifo_has_space(void)
{
    return (mmio_read32(HWICAP_WFV) > 0);
}

static uint32_t icap_is_idle(void)
{
    return !(mmio_read32(HWICAP_SR) & HWICAP_SR_DONE);
}


void hwicap_test_registers(void) {
    printf("\r\n[HWICAP] Test des registres :\r\n");
    printf("  SR  (0x%08lx) = 0x%08lx\r\n",
           (unsigned long)HWICAP_SR,
           (unsigned long)mmio_read32(HWICAP_SR));
    printf("  WFV (0x%08lx) = 0x%08lx\r\n",
           (unsigned long)HWICAP_WFV,
           (unsigned long)mmio_read32(HWICAP_WFV));
    printf("  CR  (0x%08lx) = 0x%08lx\r\n",
           (unsigned long)HWICAP_CR,
           (unsigned long)mmio_read32(HWICAP_CR));

    // Écrire un NOOP dans la FIFO et déclencher
    mmio_write32(HWICAP_WF, 0x20000000); // NOOP ICAP
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    // Attendre 1000 cycles et relire SR
    for (volatile int i = 0; i < 1000; i++);
    printf("  SR après write = 0x%08lx\r\n",
           (unsigned long)mmio_read32(HWICAP_SR));
    printf("  WFV après write = 0x%08lx\r\n",
           (unsigned long)mmio_read32(HWICAP_WFV));
}

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words)
{
    uint32_t written = 0;
     printf("  [HWICAP] SR=0x%08lx WFV=0x%08lx CR=0x%08lx\n",
           (unsigned long)mmio_read32(HWICAP_SR),
           (unsigned long)mmio_read32(HWICAP_WFV),
           (unsigned long)mmio_read32(HWICAP_CR));

    while (written < size_words)
    {

        // 🔹 1. Attendre ICAP idle AVANT toute écriture
        if (wait_for_condition(icap_is_idle, 1))
        {
            printf("[HWICAP] ERROR: ICAP not idle\n");
            return -1;
        }

        // 🔹 2. Attendre FIFO disponible
        if (wait_for_condition(fifo_has_space, 1))
        {
            printf("[HWICAP] ERROR: FIFO never available\n");
            return -1;
        }

        // 🔹 3. Remplir FIFO
        while (mmio_read32(HWICAP_WFV) > 0 && written < size_words)
        {
            mmio_write32(HWICAP_WF, data[written++]);
        }

        // 🔹 4. Barrière mémoire
        __sync_synchronize(); // ou dmb()

        // 🔹 5. Lancer write
        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

        // 🔹 6. Attendre fin write
        if (wait_for_condition(icap_is_idle, 1))
        {
            printf("[HWICAP] ERROR: write timeout\n");
            return -1;
        }
    }

    return 0;
}

/*static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    uint32_t written = 0;

    while (written < size_words) {
        // Attendre de la place dans la FIFO
        uint32_t vacancy = 0;
        int timeout = 100000;
        while (vacancy == 0 && timeout-- > 0)
            vacancy = mmio_read32(HWICAP_WFV);
        if (timeout <= 0) {
            printf("  [HWICAP] ERROR: timeout FIFO vacancy\n");
            return -1;
        }

        // Écrire par blocs
        uint32_t to_write = vacancy;
        if (to_write > (size_words - written))
            to_write = size_words - written;

        for (uint32_t i = 0; i < to_write; i++)
            mmio_write32(HWICAP_WF, data[written++]);
    }

    // Déclencher l'écriture dans l'ICAP
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    // Attendre la fin
    int timeout = 1000000;
    while (!(mmio_read32(HWICAP_SR) & HWICAP_SR_DONE) && timeout-- > 0);
    if (timeout <= 0) {
        printf("  [HWICAP] ERROR: timeout DONE\n");
        return -1;
    }

    return 0;
}*/

// =============================================================================
// Test DPR
// =============================================================================

void dpr_test(void)
{
    hwicap_test_registers();  
    printf("\r\n");
    printf("=================================================\r\n");
    printf(" DPR Test — accel_A -> accel_B\r\n");
    printf("=================================================\r\n");

    // ------------------------------------------------------------------
    // Étape 1 — Lire les IDs initiaux (accel_A attendu)
    // ------------------------------------------------------------------
    printf("\r\n[1] Lecture IDs initiaux (accel_A attendu):\r\n");

    uint64_t id1 = mmio_read64(ACCEL1_BASE);
    uint64_t id2 = mmio_read64(ACCEL2_BASE);

    printf("  accel1 ID = 0x%08lx%08lx\r\n",
           (unsigned long)(id1 >> 32), (unsigned long)(id1 & 0xFFFFFFFF));
    printf("  accel2 ID = 0x%08lx%08lx\r\n",
           (unsigned long)(id1 >> 32), (unsigned long)(id2 & 0xFFFFFFFF));

    if ((id1 & 0xFFFFFF) == 0xAAAAAA && (id2 & 0xFFFFFF) == 0xAAAAAA)
    {
        printf("  [OK] accel_A detecte sur les deux instances\r\n");
    }
    else
    {
        printf("  [WARN] IDs inattendus — verifier le bitstream charge\r\n");
    }

    // ------------------------------------------------------------------
    // Étape 2 — Reconfiguration en accel_B via HWICAP
    // ------------------------------------------------------------------
    printf("\r\n[2] Reconfiguration DPR -> accel_B:\r\n");

    // Lire le header DDR
    volatile uint32_t *hdr = (volatile uint32_t *)BITSTREAM_BASE;
    uint32_t sz_accel1 = hdr[0]; // nb mots 32 bits
    uint32_t sz_accel2 = hdr[1]; // nb mots 32 bits

    const uint32_t *bs_accel1 = (const uint32_t *)(BITSTREAM_BASE + 8);
    const uint32_t *bs_accel2 = bs_accel1 + sz_accel1;

    printf("  Bitstream accel1 : %u octets\r\n", sz_accel1 * 4);
    printf("  Bitstream accel2 : %u octets\r\n", sz_accel2 * 4);

    // Reconfigurer accel1
    printf("  Reconfiguration accel1...\r\n");
    if (hwicap_write_bitstream(bs_accel1, sz_accel1) != 0)
    {
        printf("  [FAIL] Reconfiguration accel1 echouee\r\n");
        return;
    }
    printf("  [OK] accel1 reconfigure\r\n");

    // Reconfigurer accel2
    printf("  Reconfiguration accel2...\r\n");
    if (hwicap_write_bitstream(bs_accel2, sz_accel2) != 0)
    {
        printf("  [FAIL] Reconfiguration accel2 echouee\r\n");
        return;
    }
    printf("  [OK] accel2 reconfigure\r\n");

    // ------------------------------------------------------------------
    // Étape 3 — Vérification post-reconfiguration (accel_B attendu)
    // ------------------------------------------------------------------
    printf("\r\n[3] Lecture IDs post-reconfiguration (accel_B attendu):\r\n");

    id1 = mmio_read64(ACCEL1_BASE);
    id2 = mmio_read64(ACCEL2_BASE);

    printf("  accel1 ID = 0x%016llx\r\n", (unsigned long long)id1);
    printf("  accel2 ID = 0x%016llx\r\n", (unsigned long long)id2);

    if ((id1 & 0xFFFFFF) == 0xBBBBBB && (id2 & 0xFFFFFF) == 0xBBBBBB)
    {
        printf("  [OK] accel_B detecte — reconfiguration reussie !\r\n");
    }
    else
    {
        printf("  [FAIL] IDs inattendus apres reconfiguration\r\n");
    }

    printf("\r\n=================================================\r\n");
    printf(" Test termine\r\n");
    printf("=================================================\r\n");
}