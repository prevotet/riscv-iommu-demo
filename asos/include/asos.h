/* ASOS : supervision des wrappers ARMOR.
 *
 * Quatre modules, dans l'ordre ou un evenement les traverse :
 *   1. Event Processing          event_processing/   lire, acquitter, normaliser
 *   2. Security Context Creation security_context/   creer, calibrer, supprimer
 *   3. Supervision Unit          supervision_unit/   score, TLC, politique voulue
 *   4. Update Unit               update_unit/        ecrire la politique, verifier
 *
 * asos_step() enchaine 1, 3 et 4 pour un slot ; le module 2 est appele au
 * deploiement et au retrait d'un accelerateur. Rien n'est alloue ni imprime. */
#ifndef ASOS_H
#define ASOS_H

#include "asos_types.h"
#include "armor_regs.h"
#include "event_processing.h"
#include "security_context.h"
#include "supervision_unit.h"
#include "update_unit.h"

/* Une evaluation d'un slot. Rend le mot STICKY lu ; *acted vaut 1 si la
 * politique a change et a ete ecrite. `b` peut etre nul. */
uint64_t asos_step(asos_context_t *c, uint64_t now, asos_batch_t *b, int *acted);

#endif
