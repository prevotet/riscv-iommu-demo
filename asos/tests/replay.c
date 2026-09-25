/* Rejoue sur l'hote une trajectoire relevee sur carte : les mots STICKY lus
 * par le firmware sont presentes a ASOS a travers de faux registres, et ASOS
 * imprime ce qu'il en tire, pour comparaison avec le journal (replay_logs.py).
 *
 * Entree, une commande par ligne :
 *   H <ctrl_ref> <cfgp_ref> <hyst> <enforce>   nouveau journal : recree les slots
 *   S <sticky2> <sticky1>                      un pas
 * Sortie, une ligne par pas :
 *   <score2> <tlc2> <action2|-> <ctrl2> <cfgp2> <id2> <score1> <tlc1> */
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "asos.h"

#define NREGS (0x120 / 8)

static uint64_t regs[2][NREGS];
static asos_context_t ctx[2];

static void init(uint64_t ctrl_ref, uint64_t cfgp_ref, int hyst, int enforce) {
    for (int s = 0; s < 2; s++) {
        memset(regs[s], 0, sizeof(regs[s]));
        ARMOR_REG(regs[s], ARMOR_CTRL_OFF)       = ctrl_ref;
        ARMOR_REG(regs[s], ARMOR_CFG_PARAMS_OFF) = cfgp_ref;
        ARMOR_REG(regs[s], ARMOR_ID_CFG_OFF)     = (uint64_t)(s + 1);
        asos_sc_opts_t o = { .hyst = hyst, .enforce = enforce };
        asos_sc_create(&ctx[s], (unsigned)(s + 1), regs[s], (uint64_t)(s + 1), &o);
    }
}

int main(void) {
    char line[256];
    while (fgets(line, sizeof(line), stdin)) {
        if (line[0] == 'H') {
            uint64_t c, f; int h, e;
            if (sscanf(line + 1, "%" SCNx64 " %" SCNx64 " %d %d", &c, &f, &h, &e) == 4)
                init(c, f, h, e);
        } else if (line[0] == 'S') {
            uint64_t k[2];
            if (sscanf(line + 1, "%" SCNx64 " %" SCNx64, &k[1], &k[0]) != 2) continue;
            int acted[2];
            for (int s = 1; s >= 0; s--) {          /* slot 2 d'abord, comme le banc */
                ARMOR_REG(regs[s], ARMOR_STICKY_OFF) = k[s];
                asos_step(&ctx[s], 0, 0, &acted[s]);
            }
            printf("%" PRIu64 " %u %s 0x%" PRIx64 " 0x%" PRIx64 " 0x%" PRIx64 " %" PRIu64 " %u\n",
                   ctx[1].score, ctx[1].tlc,
                   acted[1] ? asos_uu_policy_name(ctx[1].pol) : "-",
                   (uint64_t)(ARMOR_REG(regs[1], ARMOR_CTRL_OFF) & ~ARMOR_CTRL_PULSES),
                   ARMOR_REG(regs[1], ARMOR_CFG_PARAMS_OFF),
                   ARMOR_REG(regs[1], ARMOR_ID_CFG_OFF),
                   ctx[0].score, ctx[0].tlc);
        }
    }
    return 0;
}
