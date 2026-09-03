/** 
 * Bao, a Lightweight Static Partitioning Hypervisor 
 *
 * Copyright (c) Bao Project (www.bao-project.org), 2019-
 *
 * Authors:
 *      Jose Martins <jose.martins@bao-project.org>
 *      Sandro Pinto <sandro.pinto@bao-project.org>
 *
 * Modified for TrustGW-SoC-Armor Project:
 *      - Replaced iDMA with MHA (Malicious Hardware Accelerator)
 *      - Added attack mode selection (5 modes)
 *      - Added LHA for legitimate access comparison
 *
 * Bao is free software; you can redistribute it and/or modify it under the
 * terms of the GNU General Public License version 2 as published by the Free
 * Software Foundation, with a special exception exempting guest code from such
 * license. See the COPYING file in the top-level directory for details. 
 *
 */

#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <cpu.h>
#include <wfi.h>
#include <spinlock.h>
#include <plat.h>
#include <irq.h>
#include <uart.h>
#include <timer.h>
// NOTE: On n'utilise plus <idma.h> - les boutons sont lus via BTN_STATE du MHA

#define TIMER_INTERVAL  (TIME_S(1))

// =============================================================================
// IOMMU registers
// =============================================================================
#define IOMMU_BASE_ADDR         (0x50010000ULL)
#define IOMMU_DDTP_OFF          (0x10ULL)
#define IOMMU_DDTP_ADDR         (IOMMU_BASE_ADDR + IOMMU_DDTP_OFF)
#define IOMMU_DDTP_MODE_MASK    (0x0FULL)
#define IOMMU_DDTP_MODE_OFF     (0x00ULL)
#define IOMMU_DDTP_MODE_BARE    (0x01ULL)
#define IOMMU_DDTP_MODE_1LVL    (0x02ULL)

// =============================================================================
// IOMMU DDT (Device Directory Table) - configuration en memoire
// =============================================================================
// En mode 1LVL, l'IOMMU consulte DDT[device_id] pour decider si un device
// peut acceder a la memoire. Chaque entree fait 64 octets :
//   offset 0x00 : tc      (Translation Control)  - bit0=V (Valid)
//   offset 0x08 : iohgatp (2nd stage PT, 0=bare passthrough)
//   offset 0x10 : ta      (Translation Attributes)
//   offset 0x18 : fsc     (1st stage context, 0=bare)
//   offset 0x20-0x3F : reserved / MSI config
//
// tc.V=1, tout le reste=0 -> device autorise, passthrough (pas de traduction)
// tc.V=0                  -> device bloque, l'IOMMU retourne SLVERR
// =============================================================================
#define DDT_BASE_ADDR           (0xAFFFF000ULL)  // Derniere page 4KB de la RAM guest
#define DDT_ENTRY_BYTES         (64)             // 64 octets par entree DDT

// =============================================================================
// MHA (Malicious Hardware Accelerator) registers - NOUVEAU !
// =============================================================================
#define MHA_BASE_ADDR           (0x50001000ULL)
#define MHA_CTRL_OFF            (0x00ULL)
#define MHA_STATUS_OFF          (0x08ULL)
#define MHA_BASE_ADDR_OFF       (0x10ULL)
#define MHA_SIZE_OFF            (0x18ULL)
#define MHA_CONFIG_OFF          (0x20ULL)
#define MHA_ATTACK_MODE_OFF     (0x28ULL)
#define MHA_BLOCKED_CNT_OFF     (0x30ULL)
#define MHA_BTN_STATE_OFF       (0x58ULL)

// BTN_STATE bits (lu depuis MHA_BASE + 0x58)
// Correspond au mapping dans mha_wrap.sv : {btnc, btnr, btnl, btnd, btnu}
#define BTN_BTNU_BIT            (0)     // bit 0 = btnu (UP)
#define BTN_BTND_BIT            (1)     // bit 1 = btnd (DOWN)
#define BTN_BTNL_BIT            (2)     // bit 2 = btnl (LEFT)
#define BTN_BTNR_BIT            (3)     // bit 3 = btnr (RIGHT)
#define BTN_BTNC_BIT            (4)     // bit 4 = btnc (CENTER)
#define BTN_ALL_MASK            (0x1FULL)

// MHA Status bits
#define MHA_STATUS_BUSY         (1ULL << 0)
#define MHA_STATUS_DONE         (1ULL << 1)
#define MHA_STATUS_ERROR        (1ULL << 2)
#define MHA_STATUS_BLOCKED      (1ULL << 3)
#define MHA_STATUS_BANNED       (1ULL << 4)  // Banni par ARMOR après 3 échecs consécutifs
#define MHA_STATUS_STORM        (1ULL << 5)  // Storm détecté (rate limiting actif)
#define MHA_STATUS_OUTS         (1ULL << 6)  // Outstanding overflow détecté (AR flood DoS)
#define MHA_STATUS_MSI          (1ULL << 7)  // MSI storm détecté (interrupt_monitor)

// =============================================================================
// LHA (Legitimate Hardware Accelerator) registers
// =============================================================================
#define LHA_BASE_ADDR           (0x50000000ULL)
#define LHA_CTRL_OFF            (0x00ULL)
#define LHA_STATUS_OFF          (0x08ULL)
#define LHA_BASE_ADDR_OFF       (0x10ULL)
#define LHA_SIZE_OFF            (0x18ULL)
#define LHA_CONFIG_OFF          (0x20ULL)

// LHA Status bits (same as MHA)
#define LHA_STATUS_BUSY         (1ULL << 0)
#define LHA_STATUS_DONE         (1ULL << 1)
#define LHA_STATUS_ERROR        (1ULL << 2)

// Trafic de fond LHA en continu (mode "continuous" RTL, CONFIG bit1) pendant
// l'attaque MHA. LHA_BG_READ : 1 = lecture, 0 = ecriture.
#ifndef LHA_BG_READ
#define LHA_BG_READ             1
#endif
#define LHA_BG_CFG              (((LHA_BG_READ) ? 0x1ULL : 0x0ULL) | 0x2ULL)

// =============================================================================
// Attack parameters
// =============================================================================
#define ATTACK_TRANSFER_SIZE    (64)
#define ATTACK_LOOPS            (100)

#define ADDR_SRC_ATTACK         (0x81000000ULL)
#define ADDR_OPENSBI_ATTACK     (0x80002700ULL)
#define ADDR_BAO_ATTACK         (0x80200000ULL)
#define ADDR_GUEST_ZONE         (0x91000000ULL)  // Dans la zone guest (0x90000000-0xAFFFFFFF)

// Debounce counter 
#define DEBOUNCE_WINDOW         (1000)

// =============================================================================
// Attack mode names
// =============================================================================
static const char* attack_mode_names[] = {
    "Normal (ID=2 legitime)",
    "ID Spoofing (usurpe ID=1)",
    "Adresse interdite",
    "Escalade privileges",
    "DoS (tempete requetes)",
    "DoS Outstanding Overflow (AR flood)",
    "MSI Storm (writes vers adresse MSI)"
};

#define NUM_ATTACK_MODES 7

// =============================================================================
// Banner
// =============================================================================
#define BANNER\
    "\n"\
    "___________                    __    ________ __      __\n"\
    "\\__    ___/______ __ __  _____/  |_ /  _____/|  |    /  \\\n"\
    "  |    |  \\_  __ \\  |  \\/  ___\\   __/   \\  ___|  | /\\  \\ /\n"\
    "  |    |   |  | \\/  |  /\\___ \\ |  | \\    \\_\\  \\  |/  \\/  \\\n"\
    "  |____|   |__|  |____//____  >|__|  \\______  /____/\\__/\\_/\n"\
    "                            \\/              \\/\n"\
    "   _____                    _____                         \n"\
    "  /  ___|                  /  _  \\ ____   _____   ___________\n"\
    "  \\___ \\  /\\ /\\  ___ _____/  /_\\  \\_  __ \\/     \\ /  _ \\_  __ \\\n"\
    "  /    \\/  V  \\/___/_____/    |    \\  | \\/  Y Y  (  <_> )  | \\/\n"\
    " /____  /\\_/\\_/         \\____|__  /__|  |__|_|  /\\____/|__|\n"\
    "      \\/                        \\/            \\/\n"\
    "\n"\
    " TrustGW-SoC-Armor - MHA Attack Demo\n"\
    " ====================================\n"

spinlock_t print_lock = SPINLOCK_INITVAL;

// =============================================================================
// States - Extended with attack mode selection
// =============================================================================
typedef enum E_STATES
{
    S_TARGET_SEL = 0,       // SÃ©lection cible (OpenSBI/Bao)
    S_ATTACK_MODE_SEL,      // SÃ©lection mode d'attaque (NOUVEAU!)
    S_BFR_ATTACK,           // SÃ©lection IOMMU on/off
    S_ATTACK,               // Lancement attaque
    S_AFT_ATTACK            // RÃ©sultat
} E_STATES;

E_STATES next_state;

// Function prototypes
void state_target_selection(void);
void state_attack_mode_selection(void);
void state_before_attack(void);
void state_attack(void);
void state_after_attack(void);

void (*function_pointer[])(void) = {
    state_target_selection, 
    state_attack_mode_selection,   // NOUVEAU!
    state_before_attack, 
    state_attack, 
    state_after_attack
};

// =============================================================================
// Global variables
// =============================================================================
uint64_t fixed_dst = (uint64_t) ADDR_OPENSBI_ATTACK;
uint64_t dst = (uint64_t) ADDR_OPENSBI_ATTACK;
uint64_t src = (uint64_t) ADDR_SRC_ATTACK;
uint8_t attack_mode = 0;        // Mode d'attaque selectionne
uint8_t iommu_enabled = 1;      // IOMMU active par defaut
uint8_t use_lha = 0;            // 0 = MHA (attaque), 1 = LHA (legitime)
uint8_t target_is_guest = 0;    // 1 si cible = zone guest

// MHA registers pointers
volatile uint64_t *mha_ctrl        = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_CTRL_OFF);
volatile uint64_t *mha_status      = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_STATUS_OFF);
volatile uint64_t *mha_base_addr   = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_BASE_ADDR_OFF);
volatile uint64_t *mha_size        = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_SIZE_OFF);
volatile uint64_t *mha_config      = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_CONFIG_OFF);
volatile uint64_t *mha_attack_mode = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_ATTACK_MODE_OFF);
volatile uint64_t *mha_blocked_cnt = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_BLOCKED_CNT_OFF);
volatile uint64_t *mha_btn_state   = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_BTN_STATE_OFF);

// LHA registers pointers
volatile uint64_t *lha_ctrl        = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_CTRL_OFF);
volatile uint64_t *lha_status      = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_STATUS_OFF);
volatile uint64_t *lha_base_addr   = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_BASE_ADDR_OFF);
volatile uint64_t *lha_size        = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_SIZE_OFF);
volatile uint64_t *lha_config      = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_CONFIG_OFF);

// =============================================================================
// Utility functions
// =============================================================================

static inline void fence_i() {
    asm volatile("fence.i" ::: "memory");
}

void uart_rx_handler(unsigned id){
    (void) id;
    printf("cpu%d: %s\n", get_cpuid(), __func__);
    uart_clear_rxirq();
}

void ipi_handler(unsigned id){
    (void) id;
    printf("cpu%d: %s\n", get_cpuid(), __func__);
    irq_send_ipi(1ull << (get_cpuid() + 1));
}

void timer_handler(unsigned id){
    (void) id;
    timer_set(TIMER_INTERVAL);
    irq_send_ipi(1ull << (get_cpuid() + 1));
}

/**
 * Initialise la DDT en memoire et configure DDTP pour le mode 1LVL.
 * Doit etre appele UNE FOIS au boot, avant tout transfert DMA.
 *
 *   DDT[0] = invalide  (pas de device 0)
 *   DDT[1] = VALIDE     (LHA, device_id=1 -> passthrough)
 *   DDT[2] = INVALIDE   (MHA, device_id=2 -> fault/SLVERR)
 */
static void setup_iommu_ddt(void)
{
    volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;

    // Effacer toute la page DDT (4KB = 512 qwords)
    for (int i = 0; i < 512; i++)
        ddt[i] = 0;

    // DDT[1] (LHA) : tc.V=1, iohgatp=0 (bare), fsc=0 (bare)
    // -> toutes les transactions passent sans traduction
    ddt[(1 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;   // tc : bit0 = V = 1

    // DDT[2] (MHA) : tc.V=0 (deja 0)
    // -> l'IOMMU retourne un fault (SLVERR) pour chaque requete

    // Barriere memoire : s'assurer que les ecritures DDT
    // sont visibles avant que l'IOMMU ne les lise
    asm volatile("fence rw, rw" ::: "memory");

    // Ecrire DDTP : PPN de la DDT + mode 1LVL
    // Format DDTP : [63:10] = PPN, [9:4] = reserved, [3:0] = mode
    uint64_t ppn = DDT_BASE_ADDR >> 12;
    volatile uint64_t *ddtp = (volatile uint64_t *)IOMMU_DDTP_ADDR;
    *ddtp = (ppn << 10) | IOMMU_DDTP_MODE_1LVL;

    asm volatile("fence rw, rw" ::: "memory");
}

/**
 * Change le mode de l'IOMMU tout en preservant le PPN de la DDT.
 *   BARE (1) = passthrough, tout passe (IOMMU "desactive")
 *   1LVL (2) = consultation DDT  (IOMMU "active")
 */
static void set_iommu_mode(uint64_t mode)
{
    uint64_t ppn = DDT_BASE_ADDR >> 12;
    volatile uint64_t *ddtp = (volatile uint64_t *)IOMMU_DDTP_ADDR;
    *ddtp = (ppn << 10) | mode;
    asm volatile("fence rw, rw" ::: "memory");
}

/**
 *  Guarantee that all PBs are released (debounce)
 *  NOTE: BTN_STATE est read-only, pas besoin de clear
 */
static void check_released_pb(void)
{
    do {
        for (int j = 0; j < DEBOUNCE_WINDOW; j++);
    } while (((*mha_btn_state) & BTN_ALL_MASK) != 0);
}

/**
 * Wait for MHA to complete
 */
static void mha_wait_done(void)
{
    uint32_t timeout = 1000000;
    while ((*mha_status & MHA_STATUS_BUSY) && timeout > 0) {
        timeout--;
    }
}

/**
 * Wait for LHA to complete
 */
static void lha_wait_done(void)
{
    uint32_t timeout = 1000000;
    while ((*lha_status & LHA_STATUS_BUSY) && timeout > 0) {
        timeout--;
    }
}

/********************************* STATES ************************************/

/**
 *  State 1: Target selection
 *  Poll left, right and center push buttons
 *  Configure destination address according to the selected target
 */
void state_target_selection(void)
{
    uint64_t intf = 0;

    printf("\r\n");
    printf("============================================\r\n");
    printf("   STEP 1: SELECT TARGET\r\n");
    printf("============================================\r\n");
    printf("\r\n");
    printf("   [L] - Firmware attack (OpenSBI @ 0x%08x)\r\n", (uint32_t)ADDR_OPENSBI_ATTACK);
    printf("   [R] - Hypervisor attack (Bao @ 0x%08x)\r\n", (uint32_t)ADDR_BAO_ATTACK);
    printf("   [C] - Guest zone (@ 0x%08x) - Compare LHA vs MHA\r\n", (uint32_t)ADDR_GUEST_ZONE);
    printf("\r\n");

    do {
        wfi();
        intf = *mha_btn_state & ((1ULL << BTN_BTNL_BIT) | 
                            (1ULL << BTN_BTNR_BIT) |
                            (1ULL << BTN_BTNC_BIT));
    } while(!intf);

    check_released_pb();

    if(intf & (1ULL << BTN_BTNR_BIT))
    {
        fixed_dst = (uint64_t) ADDR_BAO_ATTACK;
        target_is_guest = 0;
        use_lha = 0;
        printf("\r\n>>> Target: BAO HYPERVISOR (MHA attack)\r\n");
        next_state = S_ATTACK_MODE_SEL;
    }
    else if(intf & (1ULL << BTN_BTNC_BIT))
    {
        fixed_dst = (uint64_t) ADDR_GUEST_ZONE;
        target_is_guest = 1;
        printf("\r\n>>> Target: GUEST ZONE - Choose accelerator\r\n");
        printf("\r\n");
        printf("   [U] - MHA (Malicious, ID=2) - Should be BLOCKED\r\n");
        printf("   [D] - LHA (Legitimate, ID=1) - Should PASS\r\n");
        printf("\r\n");
        
        // Wait for accelerator selection
        do {
            wfi();
            intf = *mha_btn_state & ((1ULL << BTN_BTNU_BIT) | 
                                (1ULL << BTN_BTND_BIT));
        } while(!intf);
        
        check_released_pb();
        
        if(intf & (1ULL << BTN_BTND_BIT))
        {
            use_lha = 1;
            printf(">>> Using LHA (Legitimate, ID=1)\r\n");
        }
        else
        {
            use_lha = 0;
            printf(">>> Using MHA (Malicious, ID=2)\r\n");
        }
        
        // Skip attack mode selection for LHA (no attack modes)
        if(use_lha)
        {
            attack_mode = 0;  // Normal mode for LHA
            next_state = S_BFR_ATTACK;
        }
        else
        {
            next_state = S_ATTACK_MODE_SEL;
        }
    }
    else 
    {
        fixed_dst = (uint64_t) ADDR_OPENSBI_ATTACK;
        target_is_guest = 0;
        use_lha = 0;
        printf("\r\n>>> Target: OPENSBI FIRMWARE (MHA attack)\r\n");
        next_state = S_ATTACK_MODE_SEL;
    }
}

/**
 *  State 2: Attack mode selection (NOUVEAU!)
 *  Use U/D to cycle through modes, C to confirm
 */
void state_attack_mode_selection(void)
{
    uint64_t intf = 0;

    printf("\r\n");
    printf("============================================\r\n");
    printf("   STEP 2: SELECT ATTACK MODE\r\n");
    printf("============================================\r\n");
    printf("\r\n");
    printf("   Available modes:\r\n");
    printf("   0 = Normal (uses real ID=2)\r\n");
    printf("   1 = ID Spoofing (impersonates LHA ID=1)\r\n");
    printf("   2 = Forbidden address access\r\n");
    printf("   3 = Privilege escalation\r\n");
    printf("   4 = DoS (request storm, 8 req/ms threshold)\r\n");
    printf("   5 = DoS Outstanding Overflow (AR flood, 16 outstanding threshold)\r\n");
    printf("   6 = MSI Storm (writes vers adresse MSI, 4 MSI/1024 cycles threshold)\r\n");
    printf("\r\n");
    printf("   [U] - Next mode\r\n");
    printf("   [D] - Previous mode\r\n");
    printf("   [C] - Confirm selection\r\n");
    printf("\r\n");
    printf("   Current mode: %d - %s\r\n", attack_mode, attack_mode_names[attack_mode]);

    while(1)
    {
        do {
            wfi();
            intf = *mha_btn_state & ((1ULL << BTN_BTNU_BIT) | 
                                (1ULL << BTN_BTND_BIT) |
                                (1ULL << BTN_BTNC_BIT));
        } while(!intf);

        check_released_pb();

        if(intf & (1ULL << BTN_BTNC_BIT))
        {
            // Confirm selection
            break;
        }
        else if(intf & (1ULL << BTN_BTNU_BIT))
        {
            // Next mode
            attack_mode = (attack_mode + 1) % NUM_ATTACK_MODES;
        }
        else if(intf & (1ULL << BTN_BTND_BIT))
        {
            // Previous mode
            attack_mode = (attack_mode + NUM_ATTACK_MODES - 1) % NUM_ATTACK_MODES;
        }

        printf("\r   Current mode: %d - %s                    \r\n", 
               attack_mode, attack_mode_names[attack_mode]);
    }

    printf("\r\n>>> Attack mode: %d - %s\r\n", attack_mode, attack_mode_names[attack_mode]);

    next_state = S_BFR_ATTACK;
}

/**
 *  State 3: IOMMU protection selection
 */
void state_before_attack(void)
{
    uint64_t intf = 0;

    printf("\r\n");
    printf("============================================\r\n");
    printf("   STEP 3: SELECT PROTECTION\r\n");
    printf("============================================\r\n");
    printf("\r\n");
    printf("   [U] - With IOMMU (protection ON)\r\n");
    printf("   [D] - Without IOMMU (protection OFF)\r\n");
    printf("\r\n");

    do {
        wfi();
        intf = *mha_btn_state & ((1ULL << BTN_BTNU_BIT) | 
                            (1ULL << BTN_BTND_BIT));
    } while(!intf);

    check_released_pb();

    if(intf & (1ULL << BTN_BTND_BIT))
    {
        set_iommu_mode(IOMMU_DDTP_MODE_BARE);
        iommu_enabled = 0;
        printf("\r\n>>> IOMMU DISABLED - System is VULNERABLE!\r\n");
    }
    else
    {
        set_iommu_mode(IOMMU_DDTP_MODE_1LVL);
        iommu_enabled = 1;
        printf("\r\n>>> IOMMU ENABLED - System is PROTECTED\r\n");
    }

    check_released_pb();
    next_state = S_ATTACK;
}

/**
 *  State 4: Launch attack using MHA or access using LHA
 */
void state_attack(void)
{
    uint64_t intf = 0;
    
    printf("\r\n");
    printf("============================================\r\n");
    if(use_lha) {
        printf("   STEP 4: LAUNCH LHA ACCESS (LEGITIMATE)\r\n");
    } else {
        printf("   STEP 4: LAUNCH MHA ATTACK\r\n");
    }
    printf("============================================\r\n");
    printf("\r\n");
    printf("   Target: 0x%08x\r\n", (uint32_t)fixed_dst);
    if(use_lha) {
        printf("   Accelerator: LHA (ID=1, Legitimate)\r\n");
    } else {
        printf("   Accelerator: MHA (ID=2, Malicious)\r\n");
        printf("   Mode: %d - %s\r\n", attack_mode, attack_mode_names[attack_mode]);
    }
    printf("   IOMMU: %s\r\n", iommu_enabled ? "ENABLED" : "DISABLED");
    printf("\r\n");
    printf("   [C] - %s\r\n", use_lha ? "ACCESS!" : "ATTACK!");

    do {
        wfi();
        intf = *mha_btn_state & (1ULL << BTN_BTNC_BIT);
    } while(!intf);

    check_released_pb();

    if(use_lha) {
        printf("\r\n>>> LHA ACCESSING...\r\n\r\n");
    } else {
        printf("\r\n>>> MHA ATTACKING...\r\n\r\n");
    }

    dst = fixed_dst;

    if(use_lha) {
        // ============ LHA (Legitimate) Access ============
        *lha_size = ATTACK_TRANSFER_SIZE;
        *lha_config = 0;  // Write mode

        for (int i = 0; i < ATTACK_LOOPS; i++)
        {
            fence_i();
            
            // Set target address
            *lha_base_addr = dst;
            
            // Launch transfer
            *lha_ctrl = 1;

            // Wait for completion
            lha_wait_done();

            // Check status
            uint64_t status = *lha_status;
            
            printf("[%3d/%d] 0x%08x -> ", i+1, ATTACK_LOOPS, (uint32_t)dst);
            
            if(status & LHA_STATUS_ERROR) {
                printf("ERROR/BLOCKED\r\n");
            } else if(status & LHA_STATUS_DONE) {
                printf("SUCCESS (legitimate access)\r\n");
            } else if(status & LHA_STATUS_BUSY) {
                printf("STUCK (request blocked)\r\n");
            } else {
                printf("UNKNOWN (status=0x%02x)\r\n", (uint32_t)status);
            }

            // Next address
            dst = dst + ATTACK_TRANSFER_SIZE;
        }
    } else {
        // ============ MHA (Malicious) Attack ============
        // Trafic de fond : LHA en continu (hardware) pendant l'attaque MHA.
        // Un seul start, l'accelerateur boucle tout seul et sature le bus.
        *lha_base_addr = ADDR_GUEST_ZONE;
        *lha_size      = ATTACK_TRANSFER_SIZE;
        *lha_config    = LHA_BG_CFG;   // bit0=read/write + bit1=continuous
        fence_i();
        *lha_ctrl      = 1;
        printf(">>> LHA background CONTINU actif (%s) pendant l'attaque\r\n",
               LHA_BG_READ ? "READ" : "WRITE");

        *mha_attack_mode = attack_mode;
        *mha_size = ATTACK_TRANSFER_SIZE;
        *mha_config = 0;  // Write mode (destructive attack)

        // Compteur software d'échecs pour différencier l'affichage :
        //   - les 3 premiers échecs en spoofing (mode 1) -> "BLOCKED (spoof N/3)"
        //   - à partir du 4ème -> "BANNED (15s penalty)"
        // Le sticky bit hardware MHA_STATUS_BANNED reste latché dès qu'il
        // monte une fois ; on ne peut donc pas s'en servir pour distinguer
        // les premières tentatives. On compte côté software.
        int spoof_fail_cnt = 0;
        const int ARMOR_BAN_THRESHOLD = 3;

        for (int i = 0; i < ATTACK_LOOPS; i++)
        {
            fence_i();
            
            // Set target address
            *mha_base_addr = dst;
            
            // Launch attack
            *mha_ctrl = 1;

            // Wait for completion
            mha_wait_done();

            // Check status
            uint64_t status = *mha_status;
            
            printf("[%3d/%d] 0x%08x -> ", i+1, ATTACK_LOOPS, (uint32_t)dst);
            
            if(status & MHA_STATUS_MSI) {
                printf("BLOCKED by ARMOR (MSI storm >4 MSI/1024c - 15s penalty)\r\n");
            } else if(status & MHA_STATUS_STORM) {
                printf("RATE LIMITED by ARMOR (15 sec penalty - ALL MHA requests rejected)\r\n");
            } else if(status & MHA_STATUS_OUTS) {
                printf("BLOCKED by ARMOR (outstanding overflow >16 - 15s penalty)\r\n");
            } else if(status & MHA_STATUS_BANNED) {
                
                if(attack_mode == 1) {
                    
                    spoof_fail_cnt++;
                    if(spoof_fail_cnt < ARMOR_BAN_THRESHOLD) {
                        printf("BLOCKED by ARMOR wrapper (spoof detected %d/%d)\r\n",
                               spoof_fail_cnt, ARMOR_BAN_THRESHOLD);
                    } else if(spoof_fail_cnt == ARMOR_BAN_THRESHOLD) {
                        printf("BANNED by ARMOR (15s penalty - 3 spoof failures reached)\r\n");
                    } else {
                        printf("BANNED by ARMOR (15s penalty active)\r\n");
                    }
                } else {
                    // Mode normal/autre : la pénalité 15s d'une attaque précédente
                    // est encore active, ARMOR rejette TOUTES les requêtes MHA.
                    printf("BANNED by ARMOR (15s penalty active - ALL MHA requests rejected)\r\n");
                }
            } else if(status & MHA_STATUS_BLOCKED) {
                if(attack_mode == 1) {
                    // Spoofing pré-ban : BANNED pas encore latché, on compte.
                    spoof_fail_cnt++;
                    printf("BLOCKED by ARMOR wrapper (spoof detected %d/%d)\r\n",
                           spoof_fail_cnt, ARMOR_BAN_THRESHOLD);
                } else {
                    printf("BLOCKED by IOMMU\r\n");
                }
            } else if(status & MHA_STATUS_ERROR) {
                printf("ERROR\r\n");
            } else if(status & MHA_STATUS_DONE) {
                printf("SUCCESS (attack passed!)\r\n");
            } else if(status & MHA_STATUS_BUSY) {
                // Storm attack peut bloquer les requetes, MHA reste BUSY
                printf("STUCK (rate limiter active)\r\n");
            } else {
                printf("UNKNOWN (status=0x%02x)\r\n", (uint32_t)status);
            }

            // Next address
            dst = dst + ATTACK_TRANSFER_SIZE;
        }

        // Diagnostic : a ce stade le LHA doit ENCORE tourner (mode continu)
        // -> BUSY=1. S'il est a 0, le bit continuous n'a pas pris (bitstream).
        {
            uint64_t lst = *lha_status;
            printf(">>> LHA encore actif ? status=0x%02x (BUSY=%d) -> %s\r\n",
                   (uint32_t)lst, (int)((lst & LHA_STATUS_BUSY) ? 1 : 0),
                   (lst & LHA_STATUS_BUSY) ? "CONTINU OK"
                                           : "1 seul transfert (continu KO)");
        }

        // Arret du trafic de fond LHA (clear bit continuous)
        *lha_config = 0;
        fence_i();
    }

    printf("\r\n");

    for(int i = 0; i < 500000; i++);

    next_state = S_AFT_ATTACK;
}

/**
 *  State 5: Show result
 *  Uses status directly (captures IOMMU's AXI response: SLVERR/DECERR)
 */
void state_after_attack(void)
{
    uint64_t intf = 0;
    uint64_t status;
    
    if(use_lha) {
        status = *lha_status;
    } else {
        status = *mha_status;
    }

    printf("\r\n");
    printf("============================================\r\n");
    printf("   RESULT\r\n");
    printf("============================================\r\n");
    printf("\r\n");

    if(use_lha) {
        // ============ LHA (Legitimate) Result ============
        // Toutes les conditions sont basées sur le STATUS HARDWARE réel
        if(status & LHA_STATUS_ERROR) {
            // Hardware dit ERROR=1 → accès bloqué
            printf("   +--------------------------------------+\r\n");
            printf("   |     LHA ACCESS BLOCKED !             |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: ERROR=1          |\r\n");
            printf("   |   IOMMU blocked legitimate device   |\r\n");
            printf("   |   Check IOMMU page table config!    |\r\n");
            printf("   |                                      |\r\n");
            printf("   |        CONFIG ERROR !                |\r\n");
            printf("   +--------------------------------------+\r\n");
        } else if(status & LHA_STATUS_DONE) {
            // Hardware dit DONE=1, ERROR=0 → succès réel
            printf("   +--------------------------------------+\r\n");
            printf("   |     LHA ACCESS SUCCEEDED !           |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: DONE=1, ERROR=0  |\r\n");
            printf("   |   Legitimate device (ID=1) can      |\r\n");
            printf("   |   access the guest memory zone.     |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   IOMMU allows authorized access    |\r\n");
            printf("   |          EXPECTED BEHAVIOR           |\r\n");
            printf("   +--------------------------------------+\r\n");
        } else if(status & LHA_STATUS_BUSY) {
            // LHA encore BUSY (bloqué par rate limiter ou autre)
            printf("   +--------------------------------------+\r\n");
            printf("   |     LHA STUCK (BUSY) !               |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: BUSY=1           |\r\n");
            printf("   |   LHA cannot complete transfer      |\r\n");
            printf("   |   Check wrapper rate limiter        |\r\n");
            printf("   +--------------------------------------+\r\n");
        } else {
            // État inattendu
            printf("   +--------------------------------------+\r\n");
            printf("   |     LHA UNEXPECTED STATE !           |\r\n");
            printf("   |   Status: 0x%02x                      |\r\n", (uint32_t)status);
            printf("   +--------------------------------------+\r\n");
        }
        printf("\r\n");
        printf("   LHA Status: 0x%02x (ERROR=%d, DONE=%d, BUSY=%d)\r\n", 
               (uint32_t)status,
               (status & LHA_STATUS_ERROR) ? 1 : 0,
               (status & LHA_STATUS_DONE) ? 1 : 0,
               (status & LHA_STATUS_BUSY) ? 1 : 0);
    } else {
        // ============ MHA (Malicious) Result ============
        // Toutes les conditions sont basées sur le STATUS HARDWARE réel
        if(status & MHA_STATUS_MSI)
        {
            // Mode 6 : MSI storm détecté par ARMOR (interrupt_monitor)
            printf("   +--------------------------------------+\r\n");
            printf("   |     MHA BLOCKED - MSI STORM !       |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: MSI=1            |\r\n");
            printf("   |   >4 MSI writes / 1024 cycles       |\r\n");
            printf("   |   ARMOR interrupt_monitor triggered |\r\n");
            printf("   |   >> BLOCKED FOR 15 SECONDS <<      |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   ARMOR ANTI-MSI-STORM: OK           |\r\n");
            printf("   +--------------------------------------+\r\n");
        }
        else if(status & MHA_STATUS_OUTS)
        {
            // Mode 5 : DoS Outstanding Overflow détecté par ARMOR
            printf("   +--------------------------------------+\r\n");
            printf("   |  MHA BLOCKED - OUTSTANDING OVERFLOW |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: OUTS=1           |\r\n");
            printf("   |   AR flood (>16 outstanding)        |\r\n");
            printf("   |   ARMOR outs_req_monitor triggered  |\r\n");
            printf("   |   >> BLOCKED FOR 15 SECONDS <<      |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   ARMOR ANTI-OVERFLOW: OK            |\r\n");
            printf("   +--------------------------------------+\r\n");
        }
        else if(status & MHA_STATUS_STORM)
        {
            // Storm détecté - rate limiting actif
            printf("   +--------------------------------------+\r\n");
            printf("   |   MHA RATE LIMITED (DoS STORM) !    |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   >> BLOCKED FOR 15 SECONDS <<      |\r\n");
            printf("   |   Even NORMAL requests rejected      |\r\n");
            printf("   |   during the punishment window.      |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: STORM=1          |\r\n");
            printf("   |   Too many requests in short time!  |\r\n");
            printf("   |   ARMOR detected DoS attack pattern |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Max 8 requests per millisecond    |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   ARMOR ANTI-DoS: OK                 |\r\n");
            printf("   +--------------------------------------+\r\n");
        }
        else if(status & MHA_STATUS_BANNED)
        {
            // MHA banni après 3 échecs consécutifs - blocage 15 secondes
            printf("   +--------------------------------------+\r\n");
            printf("   |    MHA BANNED BY ARMOR (15 sec) !   |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: BANNED=1         |\r\n");
            printf("   |   After 3 consecutive spoof fails,  |\r\n");
            printf("   |   ALL MHA requests blocked 15 sec.  |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Even normal mode blocked until    |\r\n");
            printf("   |   penalty timer expires!            |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   ARMOR PENALTY MECHANISM: OK        |\r\n");
            printf("   +--------------------------------------+\r\n");
        }
        else if(status & MHA_STATUS_BLOCKED)
        {
            if(attack_mode == 1) {
                // Mode spoofing : c'est le wrapper ARMOR qui bloque
                printf("   +--------------------------------------+\r\n");
                printf("   |   MHA BLOCKED BY ARMOR WRAPPER !    |\r\n");
                printf("   |                                      |\r\n");
                printf("   |   Hardware status: BLOCKED=1        |\r\n");
                printf("   |   Wrapper detected ID spoofing      |\r\n");
                printf("   |   (device sent ID=1, expected ID=2) |\r\n");
                printf("   |                                      |\r\n");
                printf("   |   ARMOR anti-spoofing: OK            |\r\n");
                printf("   +--------------------------------------+\r\n");
            } else {
                // Mode normal : c'est l'IOMMU qui bloque
                printf("   +--------------------------------------+\r\n");
                printf("   |     MHA ATTACK BLOCKED BY IOMMU !   |\r\n");
                printf("   |                                      |\r\n");
                printf("   |   Hardware status: BLOCKED=1        |\r\n");
                printf("   |   IOMMU returned AXI error response |\r\n");
                printf("   |   (SLVERR/DECERR = access denied)   |\r\n");
                printf("   |                                      |\r\n");
                printf("   |   Malicious device (ID=2) BLOCKED   |\r\n");
                printf("   |          SECURITY: OK                |\r\n");
                printf("   +--------------------------------------+\r\n");
            }
        }
        else if((status & MHA_STATUS_DONE) && !(status & MHA_STATUS_ERROR))
        {
            // Cas 2: Transfert terminé SANS erreur (bit DONE=1, ERROR=0, BLOCKED=0)
            // C'est le hardware qui dit que ça a réussi!
            printf("   +--------------------------------------+\r\n");
            printf("   |      MHA ATTACK SUCCEEDED !          |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: DONE=1, ERROR=0  |\r\n");
            printf("   |   DMA transfer completed normally   |\r\n");
            printf("   |   Attack reached protected memory!  |\r\n");
            printf("   |                                      |\r\n");
            if(!iommu_enabled) {
                printf("   |   (IOMMU was disabled)              |\r\n");
            } else {
                printf("   |   (IOMMU config may be wrong!)      |\r\n");
            }
            printf("   |      SECURITY: COMPROMISED !!!       |\r\n");
            printf("   +--------------------------------------+\r\n");
        }
        else if(status & MHA_STATUS_ERROR)
        {
            // Cas 3: Erreur hardware (pas forcément IOMMU)
            printf("   +--------------------------------------+\r\n");
            printf("   |      MHA ERROR (not IOMMU block)     |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: ERROR=1          |\r\n");
            printf("   |   Transfer failed (bus error?)      |\r\n");
            printf("   +--------------------------------------+\r\n");
        }
        else if(status & MHA_STATUS_BUSY)
        {
            // Cas 4: MHA encore BUSY (storm attack peut bloquer)
            printf("   +--------------------------------------+\r\n");
            printf("   |    MHA STUCK (Storm Rate Limit) !   |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Hardware status: BUSY=1           |\r\n");
            printf("   |   >> BLOCKED FOR 15 SECONDS <<      |\r\n");
            printf("   |   MHA cannot complete transfers     |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   ARMOR ANTI-DoS: OK                 |\r\n");
            printf("   +--------------------------------------+\r\n");
        }
        else
        {
            // Cas 5: État inattendu
            printf("   +--------------------------------------+\r\n");
            printf("   |      UNEXPECTED STATE !              |\r\n");
            printf("   |                                      |\r\n");
            printf("   |   Status: 0x%02x                      |\r\n", (uint32_t)status);
            printf("   |   Check hardware/software sync      |\r\n");
            printf("   +--------------------------------------+\r\n");
        }
        printf("\r\n");
        printf("   MHA Status: 0x%02x (MSI=%d, OUTS=%d, STORM=%d, BANNED=%d, BLOCKED=%d, ERROR=%d, DONE=%d, BUSY=%d)\r\n", 
               (uint32_t)status,
               (status & MHA_STATUS_MSI)     ? 1 : 0,
               (status & MHA_STATUS_OUTS)    ? 1 : 0,
               (status & MHA_STATUS_STORM)   ? 1 : 0,
               (status & MHA_STATUS_BANNED)  ? 1 : 0,
               (status & MHA_STATUS_BLOCKED) ? 1 : 0,
               (status & MHA_STATUS_ERROR)   ? 1 : 0,
               (status & MHA_STATUS_DONE)    ? 1 : 0,
               (status & MHA_STATUS_BUSY)    ? 1 : 0);
    }
    
    printf("\r\n");
    printf("   [C] - Try Again\r\n");

    do {
        wfi();
        intf = *mha_btn_state & ((1ULL << BTN_BTNC_BIT));
    } while(!intf);

    check_released_pb();
    
    next_state = S_TARGET_SEL;
}

/********************************** FSM **************************************/

void encode_fsm(void)
{
    static E_STATES state = S_TARGET_SEL;
    
    function_pointer[state]();
    state = next_state;
}

/*********************************** MAIN ************************************/

void main(void){

    static volatile bool master_done = false;

    if(cpu_is_master()){

        spin_lock(&print_lock);
        printf(BANNER);
        spin_unlock(&print_lock);

        irq_set_handler(UART_IRQ_ID, uart_rx_handler);
        irq_set_handler(TIMER_IRQ_ID, timer_handler);
        irq_set_handler(IPI_IRQ_ID, ipi_handler);
        uart_enable_rxirq();
        timer_set(TIMER_INTERVAL);
        irq_enable(TIMER_IRQ_ID);
        master_done = true;
    }
    irq_enable(UART_IRQ_ID);
    irq_set_prio(UART_IRQ_ID, IRQ_MAX_PRIO);
    irq_enable(IPI_IRQ_ID);

    // BTN_STATE est read-only - pas besoin de clear
    // Il reflète l'état temps réel des boutons

    // Initialiser la DDT de l'IOMMU (DDT[1]=LHA autorise, DDT[2]=MHA bloque)
    // puis activer le mode 1LVL. Doit etre fait AVANT tout transfert DMA.
    setup_iommu_ddt();
    printf("IOMMU DDT initialized (DDT @ 0x%08x, LHA=allow, MHA=block)\r\n",
           (uint32_t)DDT_BASE_ADDR);

    // Main FSM loop
    while(1)
        encode_fsm();
}
