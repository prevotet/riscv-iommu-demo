/**
 * dpr_manager.c — VM de gestion de la Reconfiguration Partielle Dynamique
 *
 * Cette VM tourne sous BAO en VM0 et a l'accès exclusif à :
 *   - AXI HWICAP (0x40010000)
 *   - accel1 (0x50000000) et accel2 (0x50001000)
 *   - Région DDR des bitstreams partiels (0x81000000 – 0x82000000, 16 Mo)
 *
 * Elle expose un service de reconfiguration à travers la mémoire partagée
 * BAO (dpr_ipc.h). Les autres VMs (Linux...) écrivent une commande dans
 * la région IPC et sondent le champ status jusqu'à DONE ou ERROR.
 *
 * Protocole : voir dpr_ipc.h
 */

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <cpu.h>
#include <wfi.h>
#include <uart.h>
#include <spinlock.h>

#include "dpr_ipc.h"

/* =========================================================================
 * Constantes HWICAP
 * ========================================================================= */

#define HWICAP_BASE   0x40010000ULL

#define HWICAP_WF     (HWICAP_BASE + 0x100)
#define HWICAP_RF     (HWICAP_BASE + 0x104)
#define HWICAP_SZ     (HWICAP_BASE + 0x108)
#define HWICAP_CR     (HWICAP_BASE + 0x10C)
#define HWICAP_SR     (HWICAP_BASE + 0x110)
#define HWICAP_WFV    (HWICAP_BASE + 0x114)
#define HWICAP_RFO    (HWICAP_BASE + 0x118)

#define HWICAP_CR_WRITE    0x01u
#define HWICAP_CR_READ     0x02u
#define HWICAP_CR_FIFO_RST 0x04u
#define HWICAP_WFV_MAX     0x3Fu
#define HWICAP_TIMEOUT     10000000

/* =========================================================================
 * Constantes GPIO (DPR Decoupling)
 * ========================================================================= */

#define GPIO_BASE        0x40000000ULL
#define GPIO_DATA        (GPIO_BASE + 0x00)
#define GPIO_TRI         (GPIO_BASE + 0x04)
#define DECOUPLE_ACCEL1  (1u << 31)
#define DECOUPLE_ACCEL2  (1u << 30)

/* =========================================================================
 * Constantes accélérateurs
 * ========================================================================= */

#define ACCEL1_BASE  0x50000000ULL
#define ACCEL2_BASE  0x50001000ULL

/* =========================================================================
 * Helpers MMIO
 * ========================================================================= */

static inline uint32_t mmio_read32(uint64_t addr)
{
    uint32_t val;
    asm volatile("fence i, r" ::: "memory");
    val = *(volatile uint32_t *)addr;
    return val;
}

static inline void mmio_write32(uint64_t addr, uint32_t val)
{
    *(volatile uint32_t *)addr = val;
    asm volatile("fence w, o" ::: "memory");
}

static inline uint64_t read_cycles(void)
{
    uint64_t c;
    asm volatile("rdcycle %0" : "=r"(c));
    return c;
}

/* =========================================================================
 * Pilote HWICAP
 * ========================================================================= */

static void hwicap_reset(void)
{
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    int t = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && t-- > 0);
    /* Libérer le FIFO avant de l'écrire (cr_i tenu = reset async permanent) */
    mmio_write32(HWICAP_CR, 0x00u);
}

/**
 * hwicap_load_bs — Charge un bitstream partiel depuis la DDR vers l'ICAP.
 *
 * @data        : pointeur vers les données (mots 32 bits, déjà en DDR)
 * @size_words  : nombre de mots 32 bits
 * @cycles_out  : durée en cycles (sortie)
 * @return      : DPR_ERR_NONE ou code d'erreur
 */
static uint32_t hwicap_load_bs(const uint32_t *data, uint32_t size_words,
                                uint64_t *cycles_out)
{
    hwicap_reset();

    uint64_t t0 = read_cycles();
    uint32_t written = 0;

    while (written < size_words) {
        uint32_t chunk = size_words - written;
        if (chunk > HWICAP_WFV_MAX)
            chunk = HWICAP_WFV_MAX;

        mmio_write32(HWICAP_SZ, chunk);

        for (uint32_t i = 0; i < chunk; i++) {
            int t = HWICAP_TIMEOUT;
            while (mmio_read32(HWICAP_WFV) == 0 && t-- > 0);
            if (t <= 0) {
                printf("[DPR] ERROR: timeout WFV @ mot %lu\n",
                       (unsigned long)(written + i));
                *cycles_out = read_cycles() - t0;
                return DPR_ERR_HWICAP_WFV;
            }
            mmio_write32(HWICAP_WF, data[written++]);
        }

        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
        int t = HWICAP_TIMEOUT;
        while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0);
        if (t <= 0) {
            printf("[DPR] ERROR: timeout CR @ mot %lu CR=0x%02x SR=0x%02x WFV=0x%02x\n",
                   (unsigned long)written,
                   mmio_read32(HWICAP_CR), mmio_read32(HWICAP_SR),
                   mmio_read32(HWICAP_WFV));
            *cycles_out = read_cycles() - t0;
            return DPR_ERR_HWICAP_CR;
        }
    }

    *cycles_out = read_cycles() - t0;
    return DPR_ERR_NONE;
}

/* =========================================================================
 * Utilitaires
 * ========================================================================= */

static void check_accel_state(int idx)
{
    uint64_t base = (idx == 1) ? ACCEL1_BASE : ACCEL2_BASE;
    uint32_t lo = mmio_read32(base);
    uint32_t hi = mmio_read32(base + 4);
    uint32_t suffix = lo & 0xFFFFFFu;
    const char *name;
    if      (suffix == 0xAAAAAAu) name = "ACCEL_A";
    else if (suffix == 0xBBBBBBu) name = "ACCEL_B";
    else                          name = "DEFAULT/INCONNU";
    printf("[DPR] Accel%d ID: 0x%08x%08x -> %s\n", idx, hi, lo, name);
}

static void hwicap_diag(void)
{
    uint32_t sr  = mmio_read32(HWICAP_SR);
    uint32_t wfv = mmio_read32(HWICAP_WFV);
    printf("[DPR] HWICAP diag: SR=0x%08x WFV=0x%02x %s\n",
           sr, wfv, (wfv == 0 && sr == 0xFFFFFFFF) ? "[ERREUR bus?]" : "[OK]");
}

/* =========================================================================
 * Traitement d'une commande IPC
 * ========================================================================= */

/* Retourne l'adresse DDR du bitstream en fonction de (accel_id, rm_id).
 * Retourne 0 si la combinaison est invalide. */
static uint64_t get_bs_addr(uint32_t accel, uint32_t rm)
{
    if (accel == DPR_ACCEL_1 && rm == DPR_RM_ACCEL_A) return DPR_BS_ACCEL1_A_PA;
    if (accel == DPR_ACCEL_1 && rm == DPR_RM_ACCEL_B) return DPR_BS_ACCEL1_B_PA;
    if (accel == DPR_ACCEL_2 && rm == DPR_RM_ACCEL_A) return DPR_BS_ACCEL2_A_PA;
    if (accel == DPR_ACCEL_2 && rm == DPR_RM_ACCEL_B) return DPR_BS_ACCEL2_B_PA;
    return 0;
}

static void process_ipc_cmd(dpr_ipc_msg_t *ipc)
{
    uint32_t cmd     = ipc->cmd;
    uint32_t accel   = ipc->accel_id;
    uint32_t rm      = ipc->rm_id;
    uint32_t bswords = ipc->bs_words;

    ipc->error_code = DPR_ERR_NONE;

    if (cmd == DPR_CMD_QUERY) {
        printf("[DPR] CMD QUERY: état courant\n");
        check_accel_state(1);
        check_accel_state(2);
        ipc->status = DPR_STATUS_DONE;
        ipc->cmd    = DPR_CMD_IDLE;
        return;
    }

    if (cmd != DPR_CMD_RECONFIG) {
        ipc->status = DPR_STATUS_IDLE;
        return;
    }

    /* Validation */
    if (accel != DPR_ACCEL_1 && accel != DPR_ACCEL_2) {
        printf("[DPR] ERROR: accel_id invalide (%u)\n", accel);
        ipc->error_code = DPR_ERR_BAD_ACCEL;
        ipc->status     = DPR_STATUS_ERROR;
        ipc->cmd        = DPR_CMD_IDLE;
        return;
    }
    if (rm != DPR_RM_ACCEL_A && rm != DPR_RM_ACCEL_B) {
        printf("[DPR] ERROR: rm_id invalide (%u)\n", rm);
        ipc->error_code = DPR_ERR_BAD_RM;
        ipc->status     = DPR_STATUS_ERROR;
        ipc->cmd        = DPR_CMD_IDLE;
        return;
    }
    if (bswords == 0) {
        printf("[DPR] ERROR: bs_words == 0\n");
        ipc->error_code = DPR_ERR_BS_SIZE;
        ipc->status     = DPR_STATUS_ERROR;
        ipc->cmd        = DPR_CMD_IDLE;
        return;
    }

    uint64_t bs_pa = get_bs_addr(accel, rm);
    const uint32_t *bs = (const uint32_t *)bs_pa;

    const char *rm_name = (rm == DPR_RM_ACCEL_A) ? "accel_A" : "accel_B";
    printf("[DPR] Reconfiguration Accel%u -> %s (%lu mots depuis 0x%lx)...\n",
           accel, rm_name, (unsigned long)bswords, (unsigned long)bs_pa);

    ipc->status = DPR_STATUS_BUSY;

    /* 1. Activer le découplage matériel (Isolation de la zone RP) */
    mmio_write32(GPIO_TRI, 0x00000000u);  /* tout en sortie (C_GPIO_WIDTH=32) */
    uint32_t mask = (accel == DPR_ACCEL_1) ? DECOUPLE_ACCEL1 : DECOUPLE_ACCEL2;
    uint32_t current_gpio = mmio_read32(GPIO_DATA);
    mmio_write32(GPIO_DATA, current_gpio | mask);
    printf("[DPR] Isolation Accel%u activée (GPIO=0x%08x)\n", accel, mmio_read32(GPIO_DATA));

    /* 2. Charger le bitstream via l'ICAP */
    uint64_t cycles = 0;
    uint32_t err = hwicap_load_bs(bs, bswords, &cycles);

    /* 3. Désactiver le découplage matériel */
    current_gpio = mmio_read32(GPIO_DATA);
    mmio_write32(GPIO_DATA, current_gpio & ~mask);
    printf("[DPR] Isolation Accel%u désactivée\n", accel);

    ipc->cycles_hi = (uint32_t)(cycles >> 32);
    ipc->cycles_lo = (uint32_t)(cycles & 0xFFFFFFFFu);

    if (err != DPR_ERR_NONE) {
        printf("[DPR] ERREUR (code %u) après %lu cycles\n",
               err, (unsigned long)cycles);
        ipc->error_code = err;
        ipc->status     = DPR_STATUS_ERROR;
    } else {
        printf("[DPR] Reconfig OK en %lu cycles (~%lu ms @100MHz)\n",
               (unsigned long)cycles,
               (unsigned long)(cycles / 100000));
        check_accel_state((int)accel);
        ipc->status = DPR_STATUS_DONE;
    }

    ipc->cmd = DPR_CMD_IDLE;
}

/* =========================================================================
 * Point d'entrée
 * ========================================================================= */

void main(void)
{
    if (!cpu_is_master()) {
        while (1) wfi();
    }

    printf("\n");
    printf("##############################################\n");
    printf("#   DPR Manager VM — RISC-V IOMMU Demo      #\n");
    printf("#   IPC @ 0x%08lx  HWICAP @ 0x%08lx  #\n",
           (unsigned long)DPR_IPC_BASE_VA,
           (unsigned long)HWICAP_BASE);
    printf("##############################################\n\n");

    hwicap_diag();

    printf("[DPR] Etat initial des accélérateurs : (RM default — lecture ignorée)\n");

    /* Initialisation de la région IPC */
    dpr_ipc_msg_t *ipc = (dpr_ipc_msg_t *)DPR_IPC_BASE_VA;
    ipc->cmd        = DPR_CMD_IDLE;
    ipc->status     = DPR_STATUS_IDLE;
    ipc->error_code = DPR_ERR_NONE;
    ipc->cycles_hi  = 0;
    ipc->cycles_lo  = 0;

    printf("[DPR] Prêt — en attente de commandes IPC...\n\n");

    /*
     * Boucle de service.
     * Utilise du polling actif : la VM est la seule à occuper son vCPU,
     * le partitionnement statique de BAO garantit l'isolation.
     * Pas de WFI nécessaire ici (ajout possible via IPC IRQ BAO).
     */
    while (1) {
        if (ipc->cmd != DPR_CMD_IDLE && ipc->status == DPR_STATUS_IDLE) {
            process_ipc_cmd(ipc);
        } else {
            /* Petit délai pour favoriser le scheduling */
            for (volatile int i = 0; i < 1000; i++);
            /* WFI : permet à BAO de scheduler les autres VMs (DPR Client...) */
            wfi();
        }
    }
}
