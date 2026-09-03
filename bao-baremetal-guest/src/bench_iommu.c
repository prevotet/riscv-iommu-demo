/**
 * bench_iommu.c — Coût IOMMU (BARE vs 1LVL) pour comparaison ARMOR
 *
 * Scénarios :
 *   SC01-SPOOF  — MHA mode 1 (ID spoof), latence tentative
 *   SC06-LHAOK  — accès légitime LHA
 *   SC07-MHAOK  — accès légitime MHA (DDT[2] valide)
 *
 * Build : make BENCH_IOMMU=1
 */

#include <stdio.h>
#include <stdint.h>
#include <cpu.h>
#include <uart.h>

#define IOMMU_BASE_ADDR         (0x50010000ULL)
#define IOMMU_DDTP_OFF          (0x10ULL)
#define IOMMU_DDTP_ADDR         (IOMMU_BASE_ADDR + IOMMU_DDTP_OFF)
#define IOMMU_MODE_BARE         (0x01ULL)
#define IOMMU_MODE_1LVL         (0x02ULL)

#define DDT_BASE_ADDR           (0xAFFFF000ULL)
#define DDT_ENTRY_BYTES         (64)

#define LHA_BASE_ADDR           (0x50000000ULL)
#define LHA_CTRL_OFF            (0x00ULL)
#define LHA_STATUS_OFF          (0x08ULL)
#define LHA_BASE_ADDR_OFF       (0x10ULL)
#define LHA_SIZE_OFF            (0x18ULL)
#define LHA_CONFIG_OFF          (0x20ULL)

#define MHA_BASE_ADDR           (0x50001000ULL)
#define MHA_CTRL_OFF            (0x00ULL)
#define MHA_STATUS_OFF          (0x08ULL)
#define MHA_BASE_ADDR_OFF       (0x10ULL)
#define MHA_SIZE_OFF            (0x18ULL)
#define MHA_CONFIG_OFF          (0x20ULL)
#define MHA_ATTACK_MODE_OFF     (0x28ULL)

#define ST_BUSY                 (1ULL << 0)
#define ST_DONE                 (1ULL << 1)
#define ST_ERROR                (1ULL << 2)
#define ST_BLOCKED              (1ULL << 3)
#define ST_BANNED               (1ULL << 4)
#define ST_STORM                (1ULL << 5)
#define ST_OUTS                 (1ULL << 6)
#define ST_MSI                  (1ULL << 7)
#define ST_ANY_BLOCK            (ST_BLOCKED|ST_BANNED|ST_STORM|ST_OUTS|ST_MSI)

#define LEGIT_DST               (0x91000000ULL)
#define XFER_SIZE               (64)
#define LAT_CAP                 1024
#define NAME_LEN                32

typedef struct {
    const char *name;
    int N;
    uint64_t L_min, L_max, L_sum;
    uint64_t latencies[LAT_CAP];
    int n_lat;
    uint64_t ok_count, err_count;
} bench_result_t;

static inline uint64_t read_time(void) {
    uint64_t t;
    asm volatile("csrr %0, time" : "=r"(t));
    return t;
}

static inline void fence_rw(void) {
    asm volatile("fence rw, rw" ::: "memory");
}

static void wait_cycles(uint64_t n) {
    volatile uint64_t i;
    for (i = 0; i < n; i++)
        asm volatile("" ::: "memory");
}

static int wait_idle(volatile uint64_t *status) {
    uint32_t to = 2000000;
    while ((*status & ST_BUSY) && to > 0)
        to--;
    return (to > 0) ? 1 : 0;
}

static void name_append(char *dst, const char *tag, const char *suffix) {
    char *d = dst;
    const char *s;
    for (s = tag; *s; s++)
        *d++ = *s;
    for (s = suffix; *s; s++)
        *d++ = *s;
    *d = '\0';
}

static void set_iommu_mode(uint64_t mode) {
    volatile uint64_t *ddtp = (volatile uint64_t *)IOMMU_DDTP_ADDR;
    uint64_t ppn = DDT_BASE_ADDR >> 12;
    *ddtp = (ppn << 10) | mode;
    fence_rw();
}

static void setup_iommu_ddt(void) {
    volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
    int i;
    for (i = 0; i < 512; i++)
        ddt[i] = 0;
    ddt[(1 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;
    fence_rw();
}

static void ddt2_set_valid(int on) {
    volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
    ddt[(2 * DDT_ENTRY_BYTES) / 8] = on ? 0x1ULL : 0x0ULL;
    fence_rw();
}

static void sort_u64(uint64_t *a, int n) {
    int i, j;
    for (i = 1; i < n; i++) {
        uint64_t k = a[i];
        j = i - 1;
        while (j >= 0 && a[j] > k) { a[j + 1] = a[j]; j--; }
        a[j + 1] = k;
    }
}

static uint64_t pctl_int(bench_result_t *r, unsigned p_num) {
    unsigned idx;
    if (r->n_lat == 0) return 0;
    sort_u64(r->latencies, r->n_lat);
    idx = (p_num * (r->n_lat - 1)) / 100u;
    return r->latencies[idx];
}

static void init_result(bench_result_t *r, const char *name) {
    r->name = name;
    r->N = 0;
    r->L_min = (uint64_t)-1;
    r->L_max = 0;
    r->L_sum = 0;
    r->n_lat = 0;
    r->ok_count = 0;
    r->err_count = 0;
}

static void add_sample(bench_result_t *r, uint64_t lat, int ok) {
    r->N++;
    if (ok) r->ok_count++;
    else r->err_count++;
    if (lat == 0) return;
    if (lat < r->L_min) r->L_min = lat;
    if (lat > r->L_max) r->L_max = lat;
    r->L_sum += lat;
    if (r->n_lat < LAT_CAP) r->latencies[r->n_lat++] = lat;
}

static int fire_one(char accel, uint64_t mha_mode, uint64_t dst, uint64_t *out_lat) {
    volatile uint64_t *ctrl, *status, *base, *sz, *cfg, *amode;
    uint64_t t0, t1, st;
    uint32_t to;

    if (accel == 'M') {
        ctrl   = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_CTRL_OFF);
        status = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_STATUS_OFF);
        base   = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_BASE_ADDR_OFF);
        sz     = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_SIZE_OFF);
        cfg    = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_CONFIG_OFF);
        amode  = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_ATTACK_MODE_OFF);
        *amode = mha_mode;
    } else {
        ctrl   = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_CTRL_OFF);
        status = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_STATUS_OFF);
        base   = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_BASE_ADDR_OFF);
        sz     = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_SIZE_OFF);
        cfg    = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_CONFIG_OFF);
    }

    if (!wait_idle(status)) {
        wait_cycles(512);
        wait_idle(status);
    }

    *base = dst;
    *sz   = XFER_SIZE;
    *cfg  = 0;
    fence_rw();

    t0 = read_time();
    *ctrl = 1;
    to = 2000000;
    while ((*status & ST_BUSY) && to > 0)
        to--;
    t1 = read_time();
    *out_lat = t1 - t0;

    if (to == 0) return 0;
    st = *status;
    return (st & ST_DONE) ? 1 : 0;
}

static void run_benchmark(const char *name, uint64_t iommu_mode, int N,
                          char accel, uint64_t mha_mode, uint64_t dst,
                          bench_result_t *r)
{
    int i;

    init_result(r, name);
    set_iommu_mode(iommu_mode);

    printf("# === %s : N=%d accel=%c mha_mode=%lu iommu=%s\r\n",
           name, N, accel, (unsigned long)mha_mode,
           iommu_mode == IOMMU_MODE_BARE ? "BARE" : "1LVL");

    for (i = 0; i < N; i++) {
        uint64_t lat = 0;
        int ok = fire_one(accel, mha_mode, dst, &lat);
        add_sample(r, lat, ok);
        if (i > 0 && (i % 1000) == 0)
            printf("#   %s progress %d/%d\r\n", name, i, N);
    }

    printf("# %s done: ok=%lu err=%lu\r\n",
           name, (unsigned long)r->ok_count, (unsigned long)r->err_count);
}

static void dump_result(bench_result_t *r) {
    uint64_t avg;
    if (r->N == 0) {
        printf("RESULT,%s,0,0,0,0,0,0,0,0,0,0\r\n", r->name);
        return;
    }
    avg = r->L_sum / r->N;
    printf("RESULT,%s,%d,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\r\n",
           r->name, r->N,
           (unsigned long)r->L_min, (unsigned long)avg,
           (unsigned long)pctl_int(r, 25), (unsigned long)pctl_int(r, 50),
           (unsigned long)pctl_int(r, 75), (unsigned long)pctl_int(r, 99),
           (unsigned long)r->L_max,
           (unsigned long)r->ok_count, (unsigned long)r->err_count);
}

static void print_overhead(const char *tag,
                           const bench_result_t *bare,
                           const bench_result_t *lvl)
{
    uint64_t bare_avg, lvl_avg;
    int64_t oh;
    unsigned pct10;

    if (bare->N == 0 || lvl->N == 0) return;
    bare_avg = bare->L_sum / bare->N;
    lvl_avg  = lvl->L_sum / lvl->N;
    oh = (int64_t)lvl_avg - (int64_t)bare_avg;
    pct10 = 0;
    if (bare_avg > 0 && oh > 0)
        pct10 = (unsigned)((oh * 1000) / (int64_t)bare_avg);
    printf("# OVERHEAD %s: %ld cy (%u.%u %%)\r\n",
           tag, (long)oh, pct10 / 10, pct10 % 10);
}

static void run_pair(const char *tag, int N, char accel, uint64_t mha_mode,
                     int ddt2_on, bench_result_t *bare, bench_result_t *lvl)
{
    char name_bare[NAME_LEN];
    char name_1lvl[NAME_LEN];

    if (ddt2_on)
        ddt2_set_valid(1);

    name_append(name_bare, tag, "-BARE");
    name_append(name_1lvl, tag, "-1LVL");
    run_benchmark(name_bare, IOMMU_MODE_BARE, N, accel, mha_mode, LEGIT_DST, bare);
    run_benchmark(name_1lvl, IOMMU_MODE_1LVL, N, accel, mha_mode, LEGIT_DST, lvl);

    if (ddt2_on)
        ddt2_set_valid(0);

    dump_result(bare);
    dump_result(lvl);
    print_overhead(tag, bare, lvl);
}

void main(void) {
    int N_atk, N_ok;
    static bench_result_t r_bare, r_1lvl;

    uart_init();
    printf("\r\n\r\n####### IOMMU Benchmark (SC01, SC06, SC07) #######\r\n");
    printf("# SC01 = coût IOMMU sur tentative spoof ; SC06/07 = légitime\r\n");
    printf("# CSV: RESULT,name,N,Lmin,Lavg,Lp25,Lp50,Lp75,Lp99,Lmax,ok,err\r\n");

    setup_iommu_ddt();
    printf("# DDT @ 0x%08x (DDT[1]=LHA valid)\r\n", (unsigned)DDT_BASE_ADDR);

#ifdef BENCH_QUICK
    N_atk = 50;
    N_ok  = 100;
    printf("# BENCH_QUICK: N_atk=%d N_ok=%d\r\n", N_atk, N_ok);
#else
    N_atk = 1000;
    N_ok  = 10000;
    printf("# Full: N_atk=%d N_ok=%d\r\n", N_atk, N_ok);
#endif

    printf("\r\n=== SC01-SPOOF ===\r\n");
    run_pair("SC01-SPOOF", N_atk, 'M', 1, 1, &r_bare, &r_1lvl);

    printf("\r\n=== SC06-LHAOK ===\r\n");
    run_pair("SC06-LHAOK", N_ok, 'L', 0, 0, &r_bare, &r_1lvl);

    printf("\r\n=== SC07-MHAOK ===\r\n");
    run_pair("SC07-MHAOK", N_ok, 'M', 0, 1, &r_bare, &r_1lvl);

    printf("\r\n# Benchmark complete\r\n");
}

void arch_init(void) {}
