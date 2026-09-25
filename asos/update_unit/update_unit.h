/* ASOS, module 4 : Update Unit.
 *
 * Traduit une politique en valeurs de registres et les ecrit dans le wrapper :
 * CFG_PARAMS (bornes), ID_CFG (Device ID), puis CTRL (seuil de flux, mode de
 * comptage). Relit ensuite ce qu'elle a ecrit, pour signaler la fin de la mise
 * a jour. */
#ifndef ASOS_UPDATE_UNIT_H
#define ASOS_UPDATE_UNIT_H

#include "asos_types.h"

#define ASOS_CFGP_TIGHT   0x02080032ULL   /* echecs 2, en-vol 8, fenetre 50 */
#define ASOS_ID_REVOKED   0xFFFFFFFFULL

typedef struct {
    uint64_t cfgp, id, ctrl;
} asos_regs_t;

/* Valeurs de registres d'une politique, sans acces materiel. */
void asos_uu_values(const asos_context_t *c, unsigned pol, asos_regs_t *r);

/* Ecrit la politique, la note dans le contexte. */
void asos_uu_apply(asos_context_t *c, unsigned pol);

/* Relit les trois registres : 1 si le wrapper porte la politique en place. */
int asos_uu_verify(const asos_context_t *c);

const char *asos_uu_policy_name(unsigned pol);

#endif
