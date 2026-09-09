`timescale 1ns/1ps






module wrapper #(

    parameter IdWidth      = 4,
    parameter IdWidthSlv   = 6, // pour les interactions processeur-périphériques
    parameter AddrWidth    = 64,
    parameter UserWidth    = 1,
    parameter DevIDWidth   = 24, //taille du device ID
    parameter ProcIDWidth  = 20, // taille du process ID 
    //parameter SubIDWidth   = 24, // taille de l'identifiant dynamique du wrapper
    parameter DataWidth    = 64,
    parameter StrbWidth    = DataWidth / 8,


    parameter type aw_chan_extended_t  = logic,
    parameter type aw_chan_slv_t       = logic,
    parameter type aw_chan_t           = logic,
    parameter type w_chan_t            = logic,
    parameter type b_chan_t            = logic,
    parameter type b_chan_slv_t        = logic,
    parameter type ar_chan_extended_t  = logic,
    parameter type ar_chan_slv_t       = logic,
    parameter type ar_chan_t           = logic,
    parameter type r_chan_t            = logic,
    parameter type r_chan_slv_t        = logic,
    parameter type req_t               = logic,
    parameter type req_slv_t           = logic,
    parameter type resp_t              = logic,
    parameter type resp_slv_t          = logic,
    parameter type req_iommu_t           = logic


)(

    input  logic    clk_i,
    input  logic    rst_ni,




    // IP-Wrapper Interface (Slave)
    input   req_iommu_t   req_IP_wrapper_i,
    output  resp_slv_t    resp_IP_wrapper_o,  //change it to resp_t when integration of the iommu 
    
    

    // Wrapper-IOMMU Interface (Master)


    input   resp_slv_t    resp_wrapper_iommu_i, //change it to resp_t when integration of the iommu 
    output  req_iommu_t   req_wrapper_iommu_o,
    
    
    //CPU_Wrapper Interface   (Slave)

    input   req_slv_t       req_CPU_Wrapper__i,
    output  resp_slv_t      resp_CPU_Wrapper_o,

    // Verdicts remontes a l'IP surveillee, pour son registre STATUS :
    // {MSI, OUTS, STORM, BANNED, BLOCKED} = armor_status[7:3].
    // Signaux instantanes : c'est a l'IP de les memoriser si elle veut les
    // observer apres coup (accel_wrap le fait par transaction).
    output  logic [4:0]     armor_verdict_o




    
);

// =============================================================================
// Profil de bitstream : DEMO (defaut) vs BENCH (`+define+BENCH_PROFILE`)
//
//   DEMO  : blocages longs (~15 s @50 MHz), fenetre de flux large, seuil MSI bas
//           -> penalite visible a l'oeil pour la demo interactive (main.c)
//   BENCH : blocages courts (~2 ms), fenetre courte, seuil MSI haut
//           -> permet d'enchainer les iterations de bench_runner.c
//
// Les seuils de *detection* (MAX_FAILURES, MAX_REQ_PER_WINDOW, MAX_OUTSTANDING,
// MAX_RATIO_MSI_DMA) sont volontairement identiques dans les deux profils :
// seules les durees de reaction et le seuil MSI changent.
//
// Activation cote Vivado :
//   set_property verilog_define {BENCH_PROFILE} [current_fileset]
// =============================================================================
`ifdef BENCH_PROFILE
    localparam logic [31:0] BLOCK_DURATION_C     = 32'd100_000;  // ~2 ms @50 MHz
    localparam int unsigned FLOW_WINDOW_C        = 100;
    localparam int unsigned FLOW_BLOCK_CYCLES_C  = 4;
    localparam int unsigned OUTS_BLOCK_CYCLES_C  = 10;
    localparam int unsigned MAX_MSI_C            = 32;
`else // profil DEMO
    localparam logic [31:0] BLOCK_DURATION_C     = 32'd750_000_000;  // ~15 s @50 MHz
    localparam int unsigned FLOW_WINDOW_C        = 50_000;
    localparam int unsigned FLOW_BLOCK_CYCLES_C  = 750_000_000;
    localparam int unsigned OUTS_BLOCK_CYCLES_C  = 750_000_000;
    localparam int unsigned MAX_MSI_C            = 4;
`endif

resp_slv_t resp_delayed;

logic [DevIDWidth-1:0] Device_ID_o;                         //Extracted_ID
logic                  Device_ID_write_enable_o;
logic                  legit_hit;
logic                  block_ip_o; 
logic [DevIDWidth-1:0] fixed_ID_reg;                        // Fixed ID register
logic                  comparison_valid;
logic [7:0]            failure_count;
logic                  threat_detected;
logic                  storm_flag;
logic                  block_req_flow;
logic                  block_req_i;  // signal final pour le request_manager
logic                  req_fire_signal;
logic                  overflow_flag_outs;
logic                  block_req_outs;
logic [AddrWidth-1:0]  extracted_address;
logic                  address_valid;
logic                  is_write_req;
logic                  is_read_req;
logic [AddrWidth-1:0]  msi_address_config;    // Configuré par le CPU
logic                  is_msi_interrupt;
logic                  is_dma;
logic                  msi_comparison_valid;
logic                  msi_storm;
logic                  block_msi;


// Registres de configuration/statut ARMOR — declares ici car referencés
// des la gate ci-dessous ; leur logique est en fin de module.
localparam int unsigned CSR_IDX_W = 5;   // 32 registres de 8 octets
localparam logic [63:0] ARMOR_STICKY_MASK = 64'h0000_0000_0000_0FF8; // bits [11:3]

logic [63:0]            csr_id_cfg_q;
logic [63:0]            csr_msi_addr_q;
logic                   csr_enforce_q;
logic [63:0]            csr_sticky_q;
logic [31:0]            cnt_banned_q, cnt_storm_q, cnt_outs_q, cnt_msi_q;
logic [DevIDWidth-1:0]  dev_id_last_q;
logic                   csr_sticky_clr, csr_cnt_clr;

// Signaux effectifs, apres la gate ENFORCE (CTRL[0], cf. bloc CSR en fin de
// module). ENFORCE = 0 -> le wrapper laisse tout passer et se contente
// d'observer ; ENFORCE = 1 -> comportement ARMOR complet.
logic legit_hit_eff;
logic block_ip_eff;

assign block_req_i   = csr_enforce_q &
                       (block_ip_o | block_req_flow | block_req_outs | block_msi);

// request_manager bloque toute requete dont legit_hit est nul. Forcer
// legit_hit_eff a 1 quand ENFORCE = 0 est ce qui rend le wrapper reellement
// transparent — sans cela, un ID_CFG non configure fermerait le chemin.
assign legit_hit_eff = legit_hit | ~csr_enforce_q;
assign block_ip_eff  = block_ip_o &  csr_enforce_q;

// -----------------------------------------------------------------------------
//  Verdict d'identifiant rendu, et mauvais  (correctif du 2026-09-09)
//
//  `legit_hit` seul ne distingue pas « pas encore compare » de « compare et
//  refuse » : les deux valent 0. response_manager traitait donc les deux en mode
//  HOLD et tenait le maitre jusqu'a SON timeout (65536 cycles cote accel_wrap,
//  1,31 ms a 50 MHz). Comme ID_extractor ne relance une comparaison que sur un
//  FRONT de AxVALID et qu'une requete tenue n'en produit aucun, les
//  MAX_FAILURES = 3 fautes necessaires au bannissement ne pouvaient s'accumuler
//  qu'au rythme des timeouts du maitre : ~3,9 ms avant qu'ARMOR ne reagisse.
//
//  verdict_known_q porte la distinction manquante. Il se leve quand
//  comparison_valid rend le verdict de la requete presentee, et retombe des que
//  plus rien n'est presente, pour que la requete suivante reparte proprement de
//  son etat « pas encore compare ».
//
//  Note pour la mesure : ceci ne coute rien au trafic legitime. bad_id ne peut
//  se lever que si legit_hit vaut 0, et sur un flot au meme identifiant
//  legit_hit reste a 1 -- le chemin reste le passe-plat combinatoire.
logic verdict_known_q;
logic bad_id;

//  La validite suit le PIPELINE, pas les canaux AXI. Premiere version de ce
//  correctif : verdict_known_q etait efface des que ni aw_valid ni ar_valid
//  n'etaient presentes. Le banc a montre l'erreur -- une fois l'AW absorbe, le
//  maitre passe en phase W, plus rien n'est "presente", le verdict s'effaçait au
//  milieu de la transaction et response_manager repassait en HOLD : w_ready
//  disparaissait et l'accelerateur calait jusqu'a son timeout, exactement le
//  comportement qu'on voulait supprimer.
//
//  On se cale donc sur les deux evenements du pipeline d'identifiant :
//    - Device_ID_write_enable_o : une nouvelle comparaison DEMARRE -> inconnu ;
//    - comparison_valid         : elle REND son verdict            -> connu.
//  Le verdict reste alors valable pour toute la duree de la transaction, et
//  jusqu'a la requete suivante.
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        verdict_known_q <= 1'b0;
    end else if (Device_ID_write_enable_o) begin
        verdict_known_q <= 1'b0;
    end else if (comparison_valid) begin
        verdict_known_q <= 1'b1;
    end
end

// comparison_valid est inclus pour ne pas perdre un cycle : au cycle ou il
// pulse, ids_match_reg porte deja le verdict frais (meme always_ff dans
// id_comparator).
assign bad_id = csr_enforce_q & (comparison_valid | verdict_known_q) & ~legit_hit;

// -----------------------------------------------------------------------------
//  Verdict CONNU — condition d'admission en aval (correctif du gel, 2026-09-09)
//
//  `legit_hit` est un NIVEAU : il reste à la valeur de la comparaison précédente
//  pendant les 2 cycles où la comparaison en cours n'a pas encore rendu. Une
//  requête d'attaque qui suit un flot légitime traversait donc, et l'IOMMU
//  l'acceptait. Quand le verdict tombait, response_manager terminait la
//  transaction côté maître par un SLVERR et l'accélérateur n'envoyait JAMAIS ses
//  beats W : il restait en aval une écriture acceptée attendant ses données pour
//  toujours. L'IOMMU rentrant dans le XBAR pour atteindre la DRAM, le canal W du
//  crossbar se coinçait et le premier accès CPU empruntant ce chemin ne revenait
//  pas -- le gel observé sur SC01 puis, une fois SC01 déplacé, sur SC02.
//
//  On n'admet donc plus rien en aval tant que le verdict de la requête PRÉSENTÉE
//  n'est pas rendu. Cela ferme aussi la fenêtre de contournement : jusqu'ici, une
//  requête usurpée arrivant juste après un flot légitime passait.
//
//  ENFORCE = 0 -> toujours « connu », le wrapper reste un passe-plat intégral.
logic verdict_known_eff;
assign verdict_known_eff = ~csr_enforce_q | comparison_valid | verdict_known_q;



ID_extractor#(

    .DevIDWidth(DevIDWidth),
    .req_iommu_t(req_iommu_t)


)Dev_ID_extractor(
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_i(req_IP_wrapper_i),
    .Device_ID_o(Device_ID_o),
    .Device_ID_write_enable_o(Device_ID_write_enable_o)
);
address_extractor #(
        .AddrWidth(AddrWidth),
        .req_iommu_t(req_iommu_t)
    ) addr_extractor_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_i(req_IP_wrapper_i),
        .Address_o(extracted_address),
        .Address_write_enable_o(address_valid),
        .is_write_o(is_write_req),
        .is_read_o(is_read_req)
    );
    msi_detector #(
        .AddrWidth(AddrWidth)
    ) msi_detect_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .msi_address_config(msi_address_config),
        .extracted_address(extracted_address),
        .compare_enable(address_valid),
        .is_write_req(is_write_req),
        .is_msi_interrupt(is_msi_interrupt),
        .is_dma(is_dma),
        .comparison_valid(msi_comparison_valid)
    );
id_comparator #(
    .DevIDWidth(DevIDWidth)  // même largeur que Device_ID_o et fixed_ID_reg
) comparator_inst (
    .clk_i(clk_i),                               // horloge du wrapper
    .rst_ni(rst_ni),                             // reset du wrapper
    .fixed_id(fixed_ID_reg),                     // ID fixe stocké par le processeur
    .dynamic_id(Device_ID_o),                    // ID capturé par l'ID_extractor
    .compare_enable(Device_ID_write_enable_o),  // déclenche la comparaison
    .legit_hit(legit_hit),                       // résultat de la comparaison
    .comparison_valid(comparison_valid)         // signal de validité
);



request_manager #(
    .req_iommu_t(req_iommu_t)
)request_manager_module(
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .legit_hit(legit_hit_eff),
    .req_IP_wrapper_i(req_IP_wrapper_i),
    .block_req_i(block_req_i),      // signal combiné
    .bad_id_i(bad_id),
    .verdict_known_i(verdict_known_eff),
    .req_wrapper_iommu_o(req_wrapper_iommu_o)

);

response_manager #(
    .resp_slv_t(resp_slv_t)
) response_manager_module (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .block_req_i(block_req_i),
    .block_ip_i(block_ip_eff),
    .bad_id_i(bad_id),
    .verdict_known_i(verdict_known_eff),
    .legit_hit(legit_hit_eff),
    .resp_wrapper_iommu_i(resp_wrapper_iommu_i),
    .resp_IP_wrapper_o(resp_IP_wrapper_o)
);
security_monitor #(
    .MAX_FAILURES(3),
    .BLOCK_DURATION(BLOCK_DURATION_C)
) sec_mon (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .legit_hit(legit_hit),               // connecté au comparator
    .comparison_valid(comparison_valid), // signal du comparator
    .block_ip_o(block_ip_o),             // utilisé par response_manager
    .failure_count(failure_count),
    .threat_detected(threat_detected)
);

request_flow_monitor #(
    .WINDOW_CYCLES(FLOW_WINDOW_C),
    .MAX_REQ_PER_WINDOW(8),
    .BLOCK_CYCLES(FLOW_BLOCK_CYCLES_C),
    .req_iommu_t(req_iommu_t),
    .resp_slv_t(resp_slv_t)

) req_flow_mon_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_IP_wrapper_i(req_IP_wrapper_i),
    .resp_wrapper_iommu_i(resp_wrapper_iommu_i),
    .legit_hit_i(legit_hit_eff),
    .storm_flag(storm_flag),
    .block_req(block_req_flow),
    .req_fire(req_fire_signal) 

);

outs_req_monitor #(
    .MAX_OUTSTANDING(16),
    .BLOCK_CYCLES(OUTS_BLOCK_CYCLES_C),
    .resp_slv_t(resp_slv_t),
    .req_iommu_t(req_iommu_t)
) outs_monitor_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_fire(req_fire_signal),              // Réutilisation
    .resp_wrapper_iommu_i(resp_wrapper_iommu_i),
    .req_IP_wrapper_i(req_IP_wrapper_i),
    .overflow_flag(overflow_flag_outs),
    .block_req(block_req_outs)
);
interrupt_monitor #(
    .WINDOW_CYCLES(1024),
    .MAX_MSI_PER_WINDOW(MAX_MSI_C),
    .MAX_RATIO_MSI_DMA(2)
) int_monitor_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .comparison_valid(msi_comparison_valid),
    .is_msi_interrupt(is_msi_interrupt),
    .is_dma(is_dma),
    .msi_storm(msi_storm),
    .block_msi(block_msi)
);

response_delayer #(
    .MAX_DELAY(16),
    .resp_slv_t(resp_slv_t)
) resp_delay_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .resp_in_i(resp_wrapper_iommu_i),    // Réponses de l'IOMMU
    .resp_out_o(resp_delayed)             // Réponses retardées
);



// =============================================================================
// Interface CSR CPU   (sec_wrapper #1 -> 0x5000_2000, #2 -> 0x5000_3000)
//
// Avant cette version, req_CPU_Wrapper__i / resp_CPU_Wrapper_o etaient declares
// dans la liste de ports mais jamais references dans le corps du module. Vivado
// signalait 30 nets sans driver ; les deux consequences fonctionnelles etaient :
//
//   - fixed_ID_reg et msi_address_config restaient constants a 0. Comme
//     id_comparator applique la garde `(fixed_id == dynamic_id) && (fixed_id != '0)`,
//     legit_hit valait 0 en permanence, et request_manager bloque toute requete
//     dont legit_hit est nul : le chemin accel -> IOMMU etait ferme en toutes
//     circonstances, independamment des moniteurs.
//
//   - aucun verdict (block_ip_o, storm_flag, block_req_outs, block_msi, ...) ne
//     sortait du module : aucune observabilite logicielle.
//
// Carte des registres — 64 bits, index decode sur addr[7:3] (32 registres,
// alias tous les 256 octets dans la fenetre de 4 KiB) :
//
//   0x00  ID_CFG       RW  identifiant legitime attendu = STREAM_ID de l'accel
//                          (1 pour sec_wrapper #1, 2 pour #2, cf. accel_wrap.sv)
//   0x08  MSI_ADDR     RW  adresse MSI surveillee par msi_detector
//   0x10  CTRL         RW  b0 ENFORCE, b1 STICKY_CLR, b2 CNT_CLR
//                          (b1/b2 sont des commandes a impulsion, auto-effacees)
//   0x18  STATUS       RO  verdicts instantanes
//   0x20  STICKY       RO  OU cumulatif de STATUS depuis le dernier STICKY_CLR
//   0x28  FAIL_CNT     RO  security_monitor.failure_count (8 bits)
//   0x30  CNT_BANNED   RO  nombre de bannissements (fronts montants)
//   0x38  CNT_STORM    RO  nombre d'episodes de storm de requetes
//   0x40  CNT_OUTS     RO  nombre d'episodes de saturation outstanding
//   0x48  CNT_MSI      RO  nombre d'episodes de storm MSI
//   0x50  DEV_ID_LAST  RO  dernier stream_id observe — sert a calibrer ID_CFG
//   0x58  MAGIC        RO  0x41524D4F52000001 ("ARMOR" + version)
//
// STATUS et STICKY reprennent volontairement les positions de bits deja
// utilisees cote logiciel (bench_runner.c / main.c), pour que classify() et
// armor_blocked() fonctionnent sans modification :
//
//   [3] BLOCKED  blocage effectif (apres gate ENFORCE)
//   [4] BANNED   block_ip_o          — brut, moniteur, non gate
//   [5] STORM    block_req_flow      — brut
//   [6] OUTS     block_req_outs      — brut
//   [7] MSI      block_msi           — brut
//   [8] threat_detected   [9] storm_flag   [10] outs_overflow   [11] msi_storm
//   [12] legit_hit        [13] ENFORCE (echo de CTRL[0])
//
// ENFORCE (CTRL[0], valeur de reset 0) ne conditionne QUE le blocage. Les
// moniteurs tournent en permanence, donc STATUS, STICKY et les compteurs
// restent valides meme a 0. A 0 le wrapper est transparent : c'est la baseline
// "sans ARMOR" obtenue dans le MEME bitstream, sans resynthese.
// =============================================================================

// Les deux nets jusqu'ici sans driver sont desormais pilotes par les CSR.
assign fixed_ID_reg       = csr_id_cfg_q[DevIDWidth-1:0];
assign msi_address_config = csr_msi_addr_q[AddrWidth-1:0];

// -----------------------------------------------------------------------------
// Vecteur de statut
// -----------------------------------------------------------------------------
logic [63:0] armor_status;

always_comb begin
    armor_status      = 64'h0;
    armor_status[3]   = block_req_i;          // blocage effectif (gate incluse)
    armor_status[4]   = block_ip_o;           // verdicts bruts des moniteurs :
    armor_status[5]   = block_req_flow;       //   visibles meme si ENFORCE = 0,
    armor_status[6]   = block_req_outs;       //   ce qui permet de mesurer la
    armor_status[7]   = block_msi;            //   detection sans subir le blocage
    armor_status[8]   = threat_detected;
    armor_status[9]   = storm_flag;
    armor_status[10]  = overflow_flag_outs;
    armor_status[11]  = msi_storm;
    armor_status[12]  = legit_hit;
    armor_status[13]  = csr_enforce_q;
end

// -----------------------------------------------------------------------------
// Sticky, compteurs d'evenements, dernier device ID observe
// -----------------------------------------------------------------------------
logic ban_d, storm_d, outs_d, msi_d;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        ban_d         <= 1'b0;
        storm_d       <= 1'b0;
        outs_d        <= 1'b0;
        msi_d         <= 1'b0;
        csr_sticky_q  <= 64'h0;
        cnt_banned_q  <= 32'h0;
        cnt_storm_q   <= 32'h0;
        cnt_outs_q    <= 32'h0;
        cnt_msi_q     <= 32'h0;
        dev_id_last_q <= '0;
    end else begin
        ban_d   <= block_ip_o;
        storm_d <= block_req_flow;
        outs_d  <= block_req_outs;
        msi_d   <= block_msi;

        if (Device_ID_write_enable_o) dev_id_last_q <= Device_ID_o;

        // Les verdicts de flux ne durent que quelques cycles (BLOCK_CYCLES = 4
        // et 10 en profil BENCH) : une lecture logicielle de STATUS les rate
        // presque toujours. STICKY et les compteurs sont la seule mesure fiable.
        // Seuls les bits d'evenement sont cumules. Les bits [12] legit_hit et
        // [13] ENFORCE sont des echos d'etat : les rendre collants n'aurait
        // aucun sens (ils resteraient a 1 des la premiere requete legitime).
        if (csr_sticky_clr) csr_sticky_q <= 64'h0;
        else                csr_sticky_q <= csr_sticky_q | (armor_status & ARMOR_STICKY_MASK);

        if (csr_cnt_clr) begin
            cnt_banned_q <= 32'h0;
            cnt_storm_q  <= 32'h0;
            cnt_outs_q   <= 32'h0;
            cnt_msi_q    <= 32'h0;
        end else begin
            if (block_ip_o     && !ban_d)   cnt_banned_q <= cnt_banned_q + 1;
            if (block_req_flow && !storm_d) cnt_storm_q  <= cnt_storm_q  + 1;
            if (block_req_outs && !outs_d)  cnt_outs_q   <= cnt_outs_q   + 1;
            if (block_msi      && !msi_d)   cnt_msi_q    <= cnt_msi_q    + 1;
        end
    end
end

// -----------------------------------------------------------------------------
// Esclave AXI4 de configuration
//
// Portee volontairement minimale : un seul acces en vol par sens, rafales INCR
// gerees en incrementant l'index de registre a chaque beat. Le port n'accepte
// pas de W avant son AW — c'est licite en AXI4, le maitre maintient simplement
// w_valid jusqu'a ce que l'AW soit passe.
// -----------------------------------------------------------------------------
typedef enum logic [1:0] { ARMOR_W_IDLE, ARMOR_W_DATA, ARMOR_W_RESP } armor_w_state_e;
typedef enum logic       { ARMOR_R_IDLE, ARMOR_R_DATA }               armor_r_state_e;

armor_w_state_e         w_state_q;
armor_r_state_e         r_state_q;
// On ne latche que les champs reellement utilises (id pour la reponse, len
// pour le dernier beat) : latcher le canal entier laisserait des bascules
// mortes que la synthese retire en emettant du bruit dans le log.
logic [IdWidthSlv-1:0]  aw_id_q, ar_id_q;
logic [7:0]             ar_len_q;
logic [CSR_IDX_W-1:0]   w_idx_q, r_idx_q;
logic [7:0]             r_beat_q;
logic [63:0]            csr_rdata;

// Canal ecriture
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        w_state_q      <= ARMOR_W_IDLE;
        aw_id_q        <= '0;
        w_idx_q        <= '0;
        csr_id_cfg_q   <= 64'h0;
        csr_msi_addr_q <= 64'h0;
        csr_enforce_q  <= 1'b0;   // reset : wrapper transparent
        csr_sticky_clr <= 1'b0;
        csr_cnt_clr    <= 1'b0;
    end else begin
        csr_sticky_clr <= 1'b0;   // commandes a impulsion d'un cycle
        csr_cnt_clr    <= 1'b0;

        case (w_state_q)
            ARMOR_W_IDLE: begin
                if (req_CPU_Wrapper__i.aw_valid) begin
                    aw_id_q   <= req_CPU_Wrapper__i.aw.id;
                    w_idx_q   <= req_CPU_Wrapper__i.aw.addr[7:3];
                    w_state_q <= ARMOR_W_DATA;
                end
            end

            ARMOR_W_DATA: begin
                if (req_CPU_Wrapper__i.w_valid) begin
                    case (w_idx_q)
                        5'd0: csr_id_cfg_q   <= req_CPU_Wrapper__i.w.data;
                        5'd1: csr_msi_addr_q <= req_CPU_Wrapper__i.w.data;
                        5'd2: begin
                            csr_enforce_q  <= req_CPU_Wrapper__i.w.data[0];
                            csr_sticky_clr <= req_CPU_Wrapper__i.w.data[1];
                            csr_cnt_clr    <= req_CPU_Wrapper__i.w.data[2];
                        end
                        default: ; // registres en lecture seule
                    endcase
                    w_idx_q <= w_idx_q + 1'b1;
                    if (req_CPU_Wrapper__i.w.last) w_state_q <= ARMOR_W_RESP;
                end
            end

            ARMOR_W_RESP: begin
                if (req_CPU_Wrapper__i.b_ready) w_state_q <= ARMOR_W_IDLE;
            end

            default: w_state_q <= ARMOR_W_IDLE;
        endcase
    end
end

// Canal lecture
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        r_state_q <= ARMOR_R_IDLE;
        ar_id_q   <= '0;
        ar_len_q  <= 8'h0;
        r_idx_q   <= '0;
        r_beat_q  <= 8'h0;
    end else begin
        case (r_state_q)
            ARMOR_R_IDLE: begin
                if (req_CPU_Wrapper__i.ar_valid) begin
                    ar_id_q   <= req_CPU_Wrapper__i.ar.id;
                    ar_len_q  <= req_CPU_Wrapper__i.ar.len;
                    r_idx_q   <= req_CPU_Wrapper__i.ar.addr[7:3];
                    r_beat_q  <= 8'h0;
                    r_state_q <= ARMOR_R_DATA;
                end
            end

            ARMOR_R_DATA: begin
                if (req_CPU_Wrapper__i.r_ready) begin
                    if (r_beat_q == ar_len_q) begin
                        r_state_q <= ARMOR_R_IDLE;
                    end else begin
                        r_idx_q  <= r_idx_q  + 1'b1;
                        r_beat_q <= r_beat_q + 8'h1;
                    end
                end
            end

            default: r_state_q <= ARMOR_R_IDLE;
        endcase
    end
end

// Multiplexeur de lecture
always_comb begin
    case (r_idx_q)
        5'd0:    csr_rdata = csr_id_cfg_q;
        5'd1:    csr_rdata = csr_msi_addr_q;
        5'd2:    csr_rdata = {63'h0, csr_enforce_q};
        5'd3:    csr_rdata = armor_status;
        5'd4:    csr_rdata = csr_sticky_q;
        5'd5:    csr_rdata = {56'h0, failure_count};
        5'd6:    csr_rdata = {32'h0, cnt_banned_q};
        5'd7:    csr_rdata = {32'h0, cnt_storm_q};
        5'd8:    csr_rdata = {32'h0, cnt_outs_q};
        5'd9:    csr_rdata = {32'h0, cnt_msi_q};
        5'd10:   csr_rdata = {{(64-DevIDWidth){1'b0}}, dev_id_last_q};
        5'd11:   csr_rdata = 64'h41524D4F52000001;
        default: csr_rdata = 64'h0;
    endcase
end

assign armor_verdict_o = armor_status[7:3];

// Reponse AXI
always_comb begin
    resp_CPU_Wrapper_o          = '0;

    resp_CPU_Wrapper_o.aw_ready = (w_state_q == ARMOR_W_IDLE);
    resp_CPU_Wrapper_o.w_ready  = (w_state_q == ARMOR_W_DATA);
    resp_CPU_Wrapper_o.b_valid  = (w_state_q == ARMOR_W_RESP);
    resp_CPU_Wrapper_o.b.id     = aw_id_q;
    resp_CPU_Wrapper_o.b.resp   = 2'b00;   // OKAY
    resp_CPU_Wrapper_o.b.user   = '0;

    resp_CPU_Wrapper_o.ar_ready = (r_state_q == ARMOR_R_IDLE);
    resp_CPU_Wrapper_o.r_valid  = (r_state_q == ARMOR_R_DATA);
    resp_CPU_Wrapper_o.r.id     = ar_id_q;
    resp_CPU_Wrapper_o.r.data   = csr_rdata;
    resp_CPU_Wrapper_o.r.resp   = 2'b00;   // OKAY
    resp_CPU_Wrapper_o.r.last   = (r_beat_q == ar_len_q);
    resp_CPU_Wrapper_o.r.user   = '0;
end


endmodule