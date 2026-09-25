/* Tests unitaires hote des parties d'ASOS que les journaux de carte n'exercent
 * pas : controle du working set, calibration des bornes, verification de mise
 * a jour, suppression du contexte. */
#include <stdio.h>
#include <string.h>
#include "asos.h"

#define NREGS (0x120 / 8)
static int fails;

#define CHECK(cond) do { if (!(cond)) { \
    printf("ECHEC %s:%d : %s\n", __FILE__, __LINE__, #cond); fails++; } } while (0)

static void regs_init(uint64_t *r, uint64_t ctrl, uint64_t cfgp, uint64_t id) {
    memset(r, 0, NREGS * sizeof(uint64_t));
    ARMOR_REG(r, ARMOR_CTRL_OFF)       = ctrl;
    ARMOR_REG(r, ARMOR_CFG_PARAMS_OFF) = cfgp;
    ARMOR_REG(r, ARMOR_ID_CFG_OFF)     = id;
}

static void test_decode(void) {
    asos_batch_t b;
    asos_ep_decode(2, ARMOR_ALERT_STORM | ARMOR_ALERT_BLOCKED | (1ULL << 14), 7, &b);
    CHECK(b.n == 2);
    CHECK(asos_su_batch_weight(&b) == 45);
    CHECK(b.ev[0].slot == 2 && b.ev[0].timestamp == 7);
    asos_ep_decode(1, 0, 0, &b);
    CHECK(b.n == 0);
}

static void test_wset(void) {
    uint64_t r[NREGS];
    asos_context_t c;
    regs_init(r, 0x331, 0, 2);
    asos_sc_opts_t o = { .enforce = 1, .wset_valid = 1, .wset = { 0x80000000u, 0x8000FFFFu } };
    asos_sc_create(&c, 2, r, 2, &o);
    asos_batch_t b;

    ARMOR_REG(r, ARMOR_ADDR_SPAN_OFF) = 0xFFFFFFFFULL;              /* rien vu */
    asos_step(&c, 0, &b, 0);
    CHECK(b.span_read && b.n == 0);

    ARMOR_REG(r, ARMOR_ADDR_SPAN_OFF) = (0x8000F000ULL << 32) | 0x80000000ULL;
    asos_step(&c, 0, &b, 0);
    CHECK(b.n == 0);

    ARMOR_REG(r, ARMOR_ADDR_SPAN_OFF) = (0x80100000ULL << 32) | 0x80000000ULL;
    asos_step(&c, 0, &b, 0);
    CHECK(b.n == 1 && b.ev[0].kind == ASOS_EV_OUT_OF_SET);

    /* Sans working set declare, ADDR_SPAN n'est pas lu. */
    asos_sc_create(&c, 2, r, 2, 0);
    asos_step(&c, 0, &b, 0);
    CHECK(!b.span_read && b.n == 0);
}

static void test_calibrate(void) {
    uint64_t r[NREGS];
    asos_context_t c;

    CHECK(asos_sc_bound(1, 2, 2, 16) == 3);
    CHECK(asos_sc_bound(0, 0, 2, 16) == 2);      /* plancher */
    CHECK(asos_sc_bound(30, 2, 2, 16) == 16);    /* jamais au-dessus de la reference */

    regs_init(r, 0x331, 0, 2);                   /* champs a zero = synthese 8 / 16 */
    asos_sc_create(&c, 2, r, 2, 0);
    CHECK(asos_sc_calibrate(&c, 1, 1, 2, 0) == 1);
    CHECK(ARMOR_CTRL_THRESH_GET(c.ctrl_ref) == 3);
    CHECK(ARMOR_CFGP_OUTS_GET(c.cfgp_ref) == 3);
    CHECK((c.ctrl_ref & 0xFFFFULL) == 0x331);    /* le reste de CTRL est garde */

    asos_sc_create(&c, 2, r, 2, 0);
    CHECK(asos_sc_calibrate(&c, 1, 1, 2, ARMOR_ALERT_OUTS) == 0);   /* refus */
    CHECK(c.ctrl_ref == 0x331 && c.cfgp_ref == 0);
}

static void test_update(void) {
    uint64_t r[NREGS];
    asos_context_t c;
    regs_init(r, 0x331, 0, 2);
    asos_sc_create(&c, 2, r, 2, 0);

    CHECK(asos_uu_verify(&c));
    asos_uu_apply(&c, ASOS_POL_REVOKED);
    CHECK(ARMOR_REG(r, ARMOR_ID_CFG_OFF) == ASOS_ID_REVOKED);
    CHECK(ARMOR_REG(r, ARMOR_CFG_PARAMS_OFF) == ASOS_CFGP_TIGHT);
    CHECK(ARMOR_REG(r, ARMOR_CTRL_OFF) & ARMOR_CTRL_RFMCNT);
    CHECK(asos_uu_verify(&c));
    ARMOR_REG(r, ARMOR_ID_CFG_OFF) = 2;          /* ecriture perdue */
    CHECK(!asos_uu_verify(&c));
    asos_uu_apply(&c, ASOS_POL_REFERENCE);
    CHECK(ARMOR_REG(r, ARMOR_CTRL_OFF) == 0x331 && ARMOR_REG(r, ARMOR_ID_CFG_OFF) == 2);
    CHECK(c.changes == 2);
}

static void test_banned_and_delete(void) {
    uint64_t r[NREGS];
    asos_context_t c;
    regs_init(r, 0x331, 0, 2);
    asos_sc_create(&c, 2, r, 2, 0);

    int acted;
    ARMOR_REG(r, ARMOR_STICKY_OFF) = ARMOR_ALERT_BANNED | ARMOR_ALERT_BLOCKED | ARMOR_ALERT_OUTS;
    asos_step(&c, 0, 0, &acted);                 /* 95 : TLC-2, BANNED */
    CHECK(acted && c.banned && c.pol == ASOS_POL_BANNED);
    ARMOR_REG(r, ARMOR_STICKY_OFF) = 0;
    for (int i = 0; i < 100; i++) asos_step(&c, 0, 0, &acted);
    CHECK(c.tlc <= 2 && c.pol == ASOS_POL_BANNED);  /* verrouille */

    asos_sc_delete(&c);
    CHECK(!c.in_use && !c.banned && c.tlc == 10 && c.score == 0);
}

int main(void) {
    test_decode();
    test_wset();
    test_calibrate();
    test_update();
    test_banned_and_delete();
    printf(fails ? "%d echec(s)\n" : "tests unitaires : OK\n", fails);
    return fails != 0;
}
