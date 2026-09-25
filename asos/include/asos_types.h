/* Types partages par les quatre modules d'ASOS. */
#ifndef ASOS_TYPES_H
#define ASOS_TYPES_H

#include <stdint.h>

/* Barriere d'ordre des acces aux registres. Redefinissable a la compilation
 * (le test hote la remplace par une barriere de compilateur). */
#ifndef ASOS_FENCE
#if defined(__riscv)
#define ASOS_FENCE() __asm__ volatile("fence rw, rw" ::: "memory")
#else
#define ASOS_FENCE() __asm__ volatile("" ::: "memory")
#endif
#endif

/* Evenements normalises par l'Event Processing. */
typedef enum {
    ASOS_EV_SPOOF,        /* usurpation d'identite tranchee (bit BANNED)    */
    ASOS_EV_OUTS,         /* borne d'en-vol franchie                        */
    ASOS_EV_BLOCKED,      /* blocage effectif, leve par tout verdict        */
    ASOS_EV_STORM,        /* borne de flux franchie                         */
    ASOS_EV_MSI,          /* rafale d'interruptions                         */
    ASOS_EV_OUT_OF_SET,   /* etendue d'adresses hors du working set declare */
    ASOS_EV_COUNT
} asos_event_kind_t;

typedef struct {
    unsigned          slot;
    asos_event_kind_t kind;
    uint64_t          timestamp;   /* cycle de la lecture du registre d'alerte */
} asos_event_t;

/* Ce qu'une lecture d'un wrapper produit. */
typedef struct {
    uint64_t     sticky;           /* mot STICKY brut, tel que lu            */
    uint32_t     amin, amax;       /* etendue d'adresses, si lue             */
    int          span_read;        /* 1 si ADDR_SPAN a ete lu                */
    unsigned     n;
    asos_event_t ev[ASOS_EV_COUNT];
} asos_batch_t;

/* Politiques, de la plus souple a la plus stricte. La valeur est la TLC
 * a partir de laquelle la politique s'applique. */
enum {
    ASOS_POL_REFERENCE = 6,   /* bornes de reference                       */
    ASOS_POL_THROTTLE  = 5,   /* seuil de flux 6                           */
    ASOS_POL_TIGHT     = 4,   /* seuil 4, transferts comptes, bornes serrees */
    ASOS_POL_REVOKED   = 3,   /* idem + Device ID revoque                  */
    ASOS_POL_BANNED    = 2,   /* idem, verrouille                          */
};

/* Working set declare pour la tache d'un slot : [lo, hi], adresses IOVA. */
typedef struct {
    uint32_t lo, hi;
} asos_wset_t;

/* Contexte de securite d'un slot, cree par la Security Context Creation. */
typedef struct {
    int                in_use;
    unsigned           slot;
    volatile uint64_t *w;          /* base des registres du wrapper          */
    uint64_t           id_own;     /* Device ID autorise                     */
    uint64_t           ctrl_ref;   /* CTRL de reference, sans impulsions     */
    uint64_t           cfgp_ref;   /* CFG_PARAMS de reference                */
    asos_wset_t        wset;
    int                wset_valid; /* 0 : pas de controle d'etendue          */
    int                hyst;       /* 1 : ne relacher qu'au retour a ACTIVE  */
    int                enforce;    /* 0 : evaluer sans rien ecrire           */

    /* Etat tenu par la Supervision Unit */
    uint64_t           score, score_max;
    unsigned           tlc;        /* 10 (sur) a 1 ; verrouillee une fois BANNED */
    int                banned;

    /* Etat tenu par l'Update Unit */
    unsigned           pol;        /* politique en place                     */
    unsigned           changes;    /* changements de politique appliques     */
} asos_context_t;

#endif
