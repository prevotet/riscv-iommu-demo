/* ASOS, module 1 : Event Processing.
 *
 * Point d'entree d'ASOS. Lit le registre d'alerte d'un wrapper, l'acquitte, et
 * traduit chaque alerte levee en un evenement normalise (slot, type, instant).
 * Les alertes restent verrouillees dans STICKY jusqu'a la lecture : aucune
 * n'est perdue entre deux lectures, mais les repetitions d'une meme alerte ne
 * sont pas distinguees (le wrapper les compte a part). */
#ifndef ASOS_EVENT_PROCESSING_H
#define ASOS_EVENT_PROCESSING_H

#include "asos_types.h"

/* Lit et vide STICKY ; lit ADDR_SPAN si le contexte declare un working set.
 * `now` est l'horodatage porte par les evenements (compteur `cycle`). */
void asos_ep_read(const asos_context_t *c, uint64_t now, asos_batch_t *b);

/* Traduit un mot STICKY en evenements, sans acces materiel. */
void asos_ep_decode(unsigned slot, uint64_t sticky, uint64_t now, asos_batch_t *b);

const char *asos_ep_name(asos_event_kind_t k);

#endif
