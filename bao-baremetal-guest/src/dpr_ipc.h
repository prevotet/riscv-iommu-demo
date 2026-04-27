/**
 * dpr_ipc.h — Protocole de communication inter-VM pour la DPR
 *
 * Mémoire partagée BAO entre DPR Manager (VM0) et Linux (VM1).
 * Layout de la région partagée (64 KB à 0xF0000000 dans chaque VM) :
 *
 *   offset 0x00 : dpr_ipc_msg_t  (commande Linux → DPR Manager)
 *
 * Protocole (polling) :
 *   Linux : écrire accel_id + rm_id + bs_words, puis cmd = DPR_CMD_RECONFIG
 *   DPR Mgr : détecte cmd != IDLE → status = BUSY → exécute → status = DONE/ERROR
 *   Linux : lit status jusqu'à DONE ou ERROR, remet cmd = IDLE
 *
 * Layout DDR des bitstreams (ping-pong complet A↔B) :
 *
 *   Accel | RM     | Adresse DDR | Taille max
 *   ------|--------|-------------|----------
 *   1     | accel_A| 0x81000000  | 3 Mo
 *   1     | accel_B| 0x81300000  | 3 Mo
 *   2     | accel_A| 0x81600000  | 5 Mo
 *   2     | accel_B| 0x81B00000  | 5 Mo
 *                                fin : 0x82000000 < Linux @ 0x82400000
 */

#ifndef DPR_IPC_H
#define DPR_IPC_H

#include <stdint.h>

/* ---- Layout mémoire partagée ----------------------------------------- */

typedef struct {
    volatile uint32_t cmd;        /* DPR_CMD_* : écrit par Linux             */
    volatile uint32_t accel_id;   /* DPR_ACCEL_* : accélérateur cible        */
    volatile uint32_t rm_id;      /* DPR_RM_* : module reconfigurable cible  */
    volatile uint32_t bs_words;   /* taille du bitstream en mots 32 bits      */
    volatile uint32_t status;     /* DPR_STATUS_* : écrit par DPR Manager    */
    volatile uint32_t error_code; /* code d'erreur si status == ERROR         */
    volatile uint32_t cycles_hi;  /* durée reconfig : bits 63..32 de rdcycle  */
    volatile uint32_t cycles_lo;  /* durée reconfig : bits 31..0  de rdcycle  */
} dpr_ipc_msg_t;

/* ---- Commandes (cmd) -------------------------------------------------- */
#define DPR_CMD_IDLE      0u   /* pas de commande en attente                  */
#define DPR_CMD_RECONFIG  1u   /* reconfigurer accel_id avec rm_id            */
#define DPR_CMD_QUERY     2u   /* lire l'état courant des accéls (status → DONE) */

/* ---- Identifiants accélérateurs (accel_id) ----------------------------- */
#define DPR_ACCEL_1  1u        /* accel1 @ 0x50000000                         */
#define DPR_ACCEL_2  2u        /* accel2 @ 0x50001000                         */

/* ---- Identifiants RM (rm_id) ------------------------------------------ */
#define DPR_RM_ACCEL_A  0u     /* reconfigurer vers accel_A (ID 0xDEAD...AAAAAA) */
#define DPR_RM_ACCEL_B  1u     /* reconfigurer vers accel_B (ID 0xDEAD...BBBBBB) */

/* ---- Codes de statut (status) ----------------------------------------- */
#define DPR_STATUS_IDLE   0u
#define DPR_STATUS_BUSY   1u
#define DPR_STATUS_DONE   2u
#define DPR_STATUS_ERROR  3u

/* ---- Codes d'erreur (error_code) -------------------------------------- */
#define DPR_ERR_NONE      0u
#define DPR_ERR_BAD_ACCEL 1u   /* accel_id inconnu (pas 1 ni 2)              */
#define DPR_ERR_BAD_RM    2u   /* rm_id inconnu (pas A ni B)                 */
#define DPR_ERR_BS_SIZE   3u   /* bs_words == 0                              */
#define DPR_ERR_HWICAP_WFV 4u  /* timeout FIFO WFV                           */
#define DPR_ERR_HWICAP_CR  5u  /* timeout CR_WRITE                           */

/* ---- Adresse IPC (identique dans DPR Manager et Linux) ---------------- */
#define DPR_IPC_BASE_VA  0xF0000000ULL

/* ---- Tailles des bitstreams (en mots 32 bits) — à vérifier avec ls -la *.bin / 4 */
#define DPR_BS_ACCEL1_WORDS  57231u    /* partial_accel_{A,B}_accel1.bin */
#define DPR_BS_ACCEL2_WORDS  95829u   /* partial_accel_{A,B}_accel2.bin */

/* ---- Adresses DDR des bitstreams (4 slots, ping-pong A↔B) ------------ */
/*
 * Slot accel1→A : 3 Mo  (534 818 mots × 4 = ~2.04 Mo, slot 3 Mo)
 * Slot accel1→B : 3 Mo
 * Slot accel2→A : 5 Mo  (1 030 202 mots × 4 = ~3.93 Mo, slot 5 Mo)
 * Slot accel2→B : 5 Mo
 */
#define DPR_BS_ACCEL1_A_PA  0x81000000ULL   /* partial_accel_A_accel1.bin   */
#define DPR_BS_ACCEL1_B_PA  0x81300000ULL   /* partial_accel_B_accel1.bin   */
#define DPR_BS_ACCEL2_A_PA  0x81600000ULL   /* partial_accel_A_accel2.bin   */
#define DPR_BS_ACCEL2_B_PA  0x81B00000ULL   /* partial_accel_B_accel2.bin   */

#endif /* DPR_IPC_H */
