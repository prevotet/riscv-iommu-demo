/* ASOS, module 2 : Security Context Creation.
 *
 * Cree le contexte de securite d'un slot quand un accelerateur y est deploye :
 * Device ID autorise, bornes de reference, working set de la tache, score nul
 * et TLC-10. Le supprime au retrait, pour que l'accelerateur suivant parte
 * d'un etat vierge. Calcule aussi les bornes derivees du trafic legitime
 * observe (calibration) ; leur ecriture dans le wrapper revient a l'Update
 * Unit. */
#ifndef ASOS_SECURITY_CONTEXT_H
#define ASOS_SECURITY_CONTEXT_H

#include "asos_types.h"

typedef struct {
    int         hyst;        /* 1 : hysteresis                          */
    int         enforce;     /* 0 : evaluer sans ecrire (bras temoin)    */
    int         wset_valid;
    asos_wset_t wset;
} asos_sc_opts_t;

/* Les bornes de reference sont celles que porte le wrapper a la creation. */
void asos_sc_create(asos_context_t *c, unsigned slot, volatile uint64_t *w,
                    uint64_t id_own, const asos_sc_opts_t *o);

void asos_sc_delete(asos_context_t *c);

/* Borne derivee d'un pic observe : pic + marge, jamais sous `floor`, jamais
 * au-dessus de `ref` -- une calibration ne relache pas la synthese. */
unsigned asos_sc_bound(unsigned peak, unsigned margin, unsigned floor, unsigned ref);

/* Remplace les bornes de reference du contexte (seuil de flux, borne d'en-vol)
 * par celles derivees des pics `peak_req` et `peak_outs`. Rend 0 et ne touche a
 * rien si `sticky` n'est pas vide : un verdict tombe pendant l'apprentissage
 * a ecrete les pics. */
int asos_sc_calibrate(asos_context_t *c, unsigned peak_req, unsigned peak_outs,
                      unsigned margin, uint64_t sticky);

#define ASOS_SC_CAL_FLOOR  2u   /* sous 2, la borne bloquerait tout */

#endif
