/* ASOS, module 3 : Supervision Unit.
 *
 * Evaluation de la menace et decision. A chaque evaluation :
 *   score <- score * gamma + somme des poids des evenements,  gamma = 230/256
 * (multiplication-accumulation entiere, sans division). Le score est classe
 * en TLC (neuf seuils, dix classes), la classe en etat, et l'etat donne la
 * politique voulue :
 *
 *   TLC >= 6  ACTIVE / LEARNING  reference
 *   TLC 5     SUSPICIOUS         seuil de flux 6
 *   TLC 4     SUSPICIOUS         seuil 4, transferts comptes, bornes serrees
 *   TLC 3     QUARANTINE         idem + Device ID revoque
 *   TLC <= 2  BANNED             idem, verrouille : la classe ne remonte plus
 *
 * Avec l'hysteresis, une politique resserree n'est relachee qu'au retour a
 * ACTIVE (TLC >= 8). La Supervision Unit decide ; l'Update Unit ecrit. */
#ifndef ASOS_SUPERVISION_UNIT_H
#define ASOS_SUPERVISION_UNIT_H

#include "asos_types.h"

#define ASOS_GAMMA_NUM  230u
#define ASOS_GAMMA_SH   8u

/* Poids d'un type d'evenement. */
unsigned asos_su_weight(asos_event_kind_t k);

/* Somme des poids d'un lot d'evenements. */
unsigned asos_su_batch_weight(const asos_batch_t *b);

/* Met a jour score, TLC et verrou BANNED ; rend la politique voulue, compte
 * tenu de l'hysteresis et de la politique en place (c->pol). */
unsigned asos_su_assess(asos_context_t *c, unsigned weight);

unsigned    asos_tlc(uint64_t score);
const char *asos_state(unsigned tlc);

#endif
