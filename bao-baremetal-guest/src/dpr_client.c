/**
 * dpr_client.c — VM cliente pour la démo DPR ping-pong
 *
 * Tourne sous BAO en VM1. N'a PAS accès à l'HWICAP ni aux accélérateurs.
 * Envoie des commandes de reconfiguration à la VM DPR Manager (VM0)
 * via la mémoire partagée BAO (dpr_ipc.h).
 *
 * Séquence ping-pong :
 *   Round  0 : accel1 → accel_A,  accel2 → accel_A
 *   Round  1 : accel1 → accel_B,  accel2 → accel_B
 *   Round  2 : accel1 → accel_A,  accel2 → accel_A
 *   ...
 *
 * Protocole (polling) :
 *   1. Écrire accel_id, rm_id, bs_words dans l'IPC
 *   2. Écrire cmd = DPR_CMD_RECONFIG
 *   3. Attendre status == DONE ou ERROR
 *   4. Remettre cmd = DPR_CMD_IDLE
 *
 * Contrainte BAO : ne pas overrider arch_init() — le PLIC est virtualisé
 * par BAO et plic_init() doit s'exécuter normalement en VS-mode.
 */

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <cpu.h>
#include <wfi.h>
#include <uart.h>

#include "dpr_ipc.h"

/* =========================================================================
 * Configuration du test
 * ========================================================================= */

#define NB_ROUNDS   8          /* nombre d'allers-retours A↔B par accélérateur */
#define POLL_DELAY  1000       /* délai entre deux sondages status (itérations) */
#define POLL_TIMEOUT 500000000 /* timeout polling (~5 s à 100 MHz)              */

/* =========================================================================
 * Helpers
 * ========================================================================= */

static inline uint64_t read_cycles(void)
{
    uint64_t c;
    asm volatile("rdcycle %0" : "=r"(c));
    return c;
}

static const char *rm_name(uint32_t rm)
{
    return (rm == DPR_RM_ACCEL_A) ? "accel_A" : "accel_B";
}

static const char *status_name(uint32_t s)
{
    switch (s) {
    case DPR_STATUS_IDLE:  return "IDLE";
    case DPR_STATUS_BUSY:  return "BUSY";
    case DPR_STATUS_DONE:  return "DONE";
    case DPR_STATUS_ERROR: return "ERROR";
    default:               return "???";
    }
}

/* =========================================================================
 * Envoi d'une commande IPC et attente du résultat
 * ========================================================================= */

/**
 * ipc_reconfig — Demande une reconfiguration et attend la réponse.
 *
 * @ipc      : pointeur vers la région IPC partagée
 * @accel    : DPR_ACCEL_1 ou DPR_ACCEL_2
 * @rm       : DPR_RM_ACCEL_A ou DPR_RM_ACCEL_B
 * @bswords  : taille du bitstream en mots 32 bits
 * @return   : DPR_STATUS_DONE ou DPR_STATUS_ERROR (ou -1 si timeout)
 */
static int ipc_reconfig(dpr_ipc_msg_t *ipc, uint32_t accel, uint32_t rm,
                        uint32_t bswords)
{
    /* S'assurer que le DPR Manager est libre */
    uint64_t t0 = read_cycles();
    while (ipc->status != DPR_STATUS_IDLE) {
        if ((read_cycles() - t0) > (uint64_t)POLL_TIMEOUT) {
            printf("[CLIENT] TIMEOUT en attendant IDLE\n");
            return -1;
        }
        for (volatile int i = 0; i < POLL_DELAY; i++);
    }

    /* Écriture de la commande */
    ipc->accel_id = accel;
    ipc->rm_id    = rm;
    ipc->bs_words = bswords;
    /* barrier : garantir que les champs sont visibles avant cmd */
    asm volatile("fence w, w" ::: "memory");
    ipc->cmd      = DPR_CMD_RECONFIG;

    /* Attente de la réponse */
    t0 = read_cycles();
    while (1) {
        uint32_t st = ipc->status;
        if (st == DPR_STATUS_DONE || st == DPR_STATUS_ERROR)
            return (int)st;
        if ((read_cycles() - t0) > (uint64_t)POLL_TIMEOUT) {
            printf("[CLIENT] TIMEOUT en attendant DONE/ERROR\n");
            return -1;
        }
        for (volatile int i = 0; i < POLL_DELAY; i++);
    }
}

/* =========================================================================
 * Test ping-pong principal
 * ========================================================================= */

static void run_pingpong(dpr_ipc_msg_t *ipc)
{
    printf("[CLIENT] Début du test ping-pong (%d rounds)\n\n", NB_ROUNDS);

    uint32_t errors = 0;

    for (int round = 0; round < NB_ROUNDS; round++) {
        uint32_t rm = (round % 2 == 0) ? DPR_RM_ACCEL_A : DPR_RM_ACCEL_B;

        printf("[CLIENT] ── Round %d : → %s ──────────────────────\n",
               round, rm_name(rm));

        /* ---- Reconfiguration accel1 ---- */
        uint64_t t0 = read_cycles();
        int ret1 = ipc_reconfig(ipc, DPR_ACCEL_1, rm, DPR_BS_ACCEL1_WORDS);
        uint64_t dt1 = read_cycles() - t0;

        uint32_t cycles_hi1 = ipc->cycles_hi;
        uint32_t cycles_lo1 = ipc->cycles_lo;
        uint32_t err1 = ipc->error_code;
        ipc->cmd = DPR_CMD_IDLE;
        ipc->status = DPR_STATUS_IDLE;

        if (ret1 == DPR_STATUS_DONE) {
            uint64_t hw_cycles = ((uint64_t)cycles_hi1 << 32) | cycles_lo1;
            printf("[CLIENT]   Accel1 OK  — HW: %lu cy (~%lu ms)  IPC: %lu cy\n",
                   (unsigned long)hw_cycles,
                   (unsigned long)(hw_cycles / 100000),
                   (unsigned long)dt1);
        } else {
            printf("[CLIENT]   Accel1 ERREUR — status=%s err=%u\n",
                   status_name((uint32_t)ret1), err1);
            errors++;
        }

        /* Petite pause entre les deux accélérateurs */
        for (volatile int i = 0; i < 100000; i++);

        /* ---- Reconfiguration accel2 ---- */
        t0 = read_cycles();
        int ret2 = ipc_reconfig(ipc, DPR_ACCEL_2, rm, DPR_BS_ACCEL2_WORDS);
        uint64_t dt2 = read_cycles() - t0;

        uint32_t cycles_hi2 = ipc->cycles_hi;
        uint32_t cycles_lo2 = ipc->cycles_lo;
        uint32_t err2 = ipc->error_code;
        ipc->cmd = DPR_CMD_IDLE;
        ipc->status = DPR_STATUS_IDLE;

        if (ret2 == DPR_STATUS_DONE) {
            uint64_t hw_cycles = ((uint64_t)cycles_hi2 << 32) | cycles_lo2;
            printf("[CLIENT]   Accel2 OK  — HW: %lu cy (~%lu ms)  IPC: %lu cy\n",
                   (unsigned long)hw_cycles,
                   (unsigned long)(hw_cycles / 100000),
                   (unsigned long)dt2);
        } else {
            printf("[CLIENT]   Accel2 ERREUR — status=%s err=%u\n",
                   status_name((uint32_t)ret2), err2);
            errors++;
        }

        printf("\n");
    }

    /* ---- Bilan ---- */
    if (errors == 0) {
        printf("[CLIENT] ══════════════════════════════════════════\n");
        printf("[CLIENT]  TEST PING-PONG OK — %d rounds, 0 erreur\n", NB_ROUNDS);
        printf("[CLIENT] ══════════════════════════════════════════\n");
    } else {
        printf("[CLIENT] ══════════════════════════════════════════\n");
        printf("[CLIENT]  TEST PING-PONG ECHEC — %u erreur(s)\n", errors);
        printf("[CLIENT] ══════════════════════════════════════════\n");
    }
}

/* =========================================================================
 * Requête d'état initial (QUERY)
 * ========================================================================= */

static void query_state(dpr_ipc_msg_t *ipc)
{
    ipc->cmd = DPR_CMD_QUERY;
    asm volatile("fence w, w" ::: "memory");

    uint64_t t0 = read_cycles();
    while (ipc->status != DPR_STATUS_DONE) {
        if ((read_cycles() - t0) > (uint64_t)POLL_TIMEOUT) {
            printf("[CLIENT] TIMEOUT QUERY\n");
            return;
        }
        for (volatile int i = 0; i < POLL_DELAY; i++);
    }
    ipc->cmd    = DPR_CMD_IDLE;
    ipc->status = DPR_STATUS_IDLE;
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
    printf("#   DPR Client VM — RISC-V IOMMU Demo       #\n");
    printf("#   IPC @ 0x%08lx                      #\n",
           (unsigned long)DPR_IPC_BASE_VA);
    printf("##############################################\n\n");

    dpr_ipc_msg_t *ipc = (dpr_ipc_msg_t *)DPR_IPC_BASE_VA;

    /* Attendre que le DPR Manager soit prêt (status = IDLE) */
    printf("[CLIENT] Attente du DPR Manager...\n");
    uint64_t t0 = read_cycles();
    while (ipc->status != DPR_STATUS_IDLE) {
        if ((read_cycles() - t0) > (uint64_t)POLL_TIMEOUT) {
            printf("[CLIENT] TIMEOUT — DPR Manager ne répond pas !\n");
            printf("[CLIENT] status=0x%08x cmd=0x%08x\n",
                   ipc->status, ipc->cmd);
            while (1) wfi();
        }
        for (volatile int i = 0; i < POLL_DELAY; i++);
    }
    printf("[CLIENT] DPR Manager prêt.\n\n");

    /* Lire l'état initial des accélérateurs */
    printf("[CLIENT] État initial (QUERY) :\n");
    query_state(ipc);
    printf("\n");

    /* Test ping-pong */
    run_pingpong(ipc);

    printf("\n[CLIENT] Terminé. En attente (WFI).\n");
    while (1) wfi();
}
