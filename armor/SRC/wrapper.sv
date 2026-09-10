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
// bits [11:3] + [14] bad_id. Les bits [12] legit_hit et [13] ENFORCE restent
// exclus : ce sont des echos d'etat, les rendre collants n'apprendrait rien.
localparam logic [63:0] ARMOR_STICKY_MASK = 64'h0000_0000_0000_4FF8;

logic [63:0]            csr_id_cfg_q;
logic [63:0]            csr_msi_addr_q;
logic                   csr_enforce_q;
logic                   csr_awfix_q;      // CTRL[3] : ne pas retirer un VALID
logic                   csr_wskid_q;      // CTRL[4] : etage W (skid buffer)
logic [63:0]            csr_sticky_q;
logic [31:0]            cnt_banned_q, cnt_storm_q, cnt_outs_q, cnt_msi_q;
logic [DevIDWidth-1:0]  dev_id_last_q;
logic                   csr_sticky_clr, csr_cnt_clr;

// Remontees d'observabilite des moniteurs (aucun effet fonctionnel).
logic [7:0]             outs_depth;      // profondeur outstanding courante
logic [7:0]             flow_req_cnt;    // requetes comptees dans la fenetre
logic [31:0]            flow_window_cnt; // position dans la fenetre

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

// -----------------------------------------------------------------------------
//  W DU EN AVAL — garde du correctif « W orphelin » (2026-09-09)
//
//  request_manager coupe aw_valid/ar_valid tant que le verdict n'est pas rendu,
//  mais laissait passer w_valid. Un aval qui tient w_ready haut -- c'est le cas
//  d'un crossbar qui bufferise, et de l'IOMMU en amont de lui -- avalait donc
//  les donnees d'une ecriture dont il ne recevrait jamais l'adresse. Le canal W
//  se retrouvait decale d'un beat DEFINITIVEMENT : le premier acces CPU
//  empruntant ce chemin ne revenait plus. C'est le gel de SC01 sur carte, et la
//  sonde du 2026-09-09 13:02 l'a isole -- une ecriture bloquee gele, une lecture
//  bloquee non, parce qu'une lecture n'a pas de canal W.
//
//  On ne peut pas couper w_valid inconditionnellement : c'est le Bug #16 de
//  l'implementation de reference, ou couper W tuait les transactions deja
//  acceptees en aval et l'interconnexion mourait apres chaque attaque. La
//  distinction est celle-ci :
//
//    - un AW deja admis en aval attend ses beats W : ils DOIVENT passer ;
//    - aucun AW en attente de donnees : tout W presente est un orphelin en
//      devenir, et c'est LUI qu'il faut couper.
//
//  w_owed_q compte les AW admis en aval dont le dernier beat W n'est pas encore
//  passe. La coupure de W n'est autorisee que lorsqu'il vaut zero, ce qui
//  preserve integralement le correctif du Bug #16.
logic [3:0] w_owed_q;
logic       dn_aw_hs, dn_w_last_hs;

assign dn_aw_hs     = req_wrapper_iommu_o.aw_valid & resp_wrapper_iommu_i.aw_ready;
assign dn_w_last_hs = req_wrapper_iommu_o.w_valid  & resp_wrapper_iommu_i.w_ready
                                                   & req_wrapper_iommu_o.w.last;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        w_owed_q <= '0;
    end else begin
        // Saturation a 15 : au-dela le compteur cesse de decrire l'aval, mais
        // il vaut mieux ne plus couper que couper a tort.
        case ({dn_aw_hs, dn_w_last_hs})
            2'b10:   if (w_owed_q != 4'hF) w_owed_q <= w_owed_q + 4'd1;
            2'b01:   if (w_owed_q != 4'h0) w_owed_q <= w_owed_q - 4'd1;
            default: w_owed_q <= w_owed_q;   // 00 et 11 : inchange
        endcase
    end
end

// -----------------------------------------------------------------------------
//  VALID PRESENTE ET NON ACQUITTE  (correctif derriere CTRL[3])
//
//  Echantillon REGISTRE du valid reellement sorti en aval. Pas de boucle
//  combinatoire : ces bascules sont lues au cycle SUIVANT pour interdire la
//  coupure, et le cas « presente et coupe dans le meme cycle » est impossible
//  par construction -- si la coupure est active, aucun valid n'est sorti.
//
//  A 0 (reset) CTRL[3] laisse le comportement historique, pour que le MEME
//  bitstream serve a mesurer la violation AXI4 et a verifier qu'elle disparait.
// -----------------------------------------------------------------------------
logic aw_pres_q, ar_pres_q;
logic no_cut_aw, no_cut_ar;
logic dn_ar_hs_pres;

assign dn_ar_hs_pres = req_wrapper_iommu_o.ar_valid & resp_wrapper_iommu_i.ar_ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        aw_pres_q <= 1'b0;
        ar_pres_q <= 1'b0;
    end else begin
        if (dn_aw_hs)                          aw_pres_q <= 1'b0;
        else if (req_wrapper_iommu_o.aw_valid) aw_pres_q <= 1'b1;

        if (dn_ar_hs_pres)                     ar_pres_q <= 1'b0;
        else if (req_wrapper_iommu_o.ar_valid) ar_pres_q <= 1'b1;
    end
end

assign no_cut_aw = csr_awfix_q & aw_pres_q;
assign no_cut_ar = csr_awfix_q & ar_pres_q;

//  w_pending : un AW est admis en aval et attend encore ses donnees. C'est la
//  seule condition dans laquelle un beat W a le droit de partir. Voir
//  request_manager pour le raisonnement complet.
logic w_pending;
assign w_pending = (w_owed_q != 4'h0);



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



//  Nets de l'etage W. `req_rm` est la sortie brute de request_manager ; le port
//  aval `req_wrapper_iommu_o` en est l'assemblage avec le canal W de l'etage.
req_iommu_t req_rm;
w_chan_t    wskid_w;
logic       wskid_valid, wskid_ready;

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
    .w_pending_i(w_pending),
    .no_cut_aw_i(no_cut_aw),
    .no_cut_ar_i(no_cut_ar),
    .req_wrapper_iommu_o(req_rm)

);

// -----------------------------------------------------------------------------
//  ETAGE W  (skid buffer, derriere CTRL[4])
//
//  Insere entre la sortie de request_manager et le port aval. La decision de
//  couper un beat W est desormais prise A LA CAPTURE : un beat qu'on n'a pas le
//  droit d'emettre n'entre pas dans l'etage et reste chez le maitre -- ce qui
//  est licite, un maitre peut attendre -- et un beat entre est presente en aval
//  puis TENU jusqu'a son w_ready, quoi que devienne `w_pending`. Le retrait de
//  VALID mesure le 2026-09-10 devient impossible par construction.
//
//  A CTRL[4] = 0 (reset) l'etage est transparent au fil pres : le meme bitstream
//  sert a mesurer la violation et a verifier sa disparition.
// -----------------------------------------------------------------------------
w_skid_buffer #(
    .w_chan_t(w_chan_t)
) i_w_skid (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .en_i      (csr_wskid_q),
    .w_i       (req_rm.w),
    .w_valid_i (req_rm.w_valid),
    .w_ready_o (wskid_ready),
    .w_o       (wskid_w),
    .w_valid_o (wskid_valid),
    .w_ready_i (resp_wrapper_iommu_i.w_ready)
);

always_comb begin
    req_wrapper_iommu_o = req_rm;
    if (csr_wskid_q) begin
        req_wrapper_iommu_o.w       = wskid_w;
        req_wrapper_iommu_o.w_valid = wskid_valid;
    end
end

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
    .w_pending_i(w_pending),
    .wskid_en_i(csr_wskid_q),
    .wskid_ready_i(wskid_ready),
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
    .req_fire(req_fire_signal),
    .req_cnt_o(flow_req_cnt),
    .window_cnt_o(flow_window_cnt)

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
    .block_req(block_req_outs),
    .outstanding_o(outs_depth)
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
//   0x10  CTRL         RW  b0 ENFORCE, b1 STICKY_CLR, b2 CNT_CLR,
//                          b4 W_SKID -- etage d'un emplacement sur le canal W.
//                          Correctif du retrait de VALID mesure le 2026-09-10 :
//                          la coupure est decidee A LA CAPTURE, un beat entre
//                          est tenu jusqu'a son ready, et le ready rendu au
//                          maitre est celui de l'etage. A 0 (reset) l'etage est
//                          transparent. Echo dans STATUS[16].
//
//                          b3 AW_HOLD_FIX -- TENTATIVE REFUTEE, gardee pour
//                          etre mesurable sur carte. A 0 (reset), donc sans
//                          effet par defaut. Echo dans STATUS[15].
//
//                          L'idee etait : interdire de retirer un VALID deja
//                          presente en aval, en differant la coupure. La
//                          simulation la refute -- les retraits d'AW passent de
//                          1 a 33 sur SC04-MSI et de 1 a 8 sur SC01-SPOOF, et
//                          un nouveau apparait sur du trafic legitime.
//
//                          POURQUOI. Pendant un blocage, response_manager
//                          fabrique aw_ready = 1 vers le maitre pour absorber sa
//                          requete. Maintenir en meme temps le aw_valid en aval
//                          sans qu'il y soit acquitte fait que le maitre
//                          considere son AW termine et RETIRE lui-meme son
//                          valid : le retrait revient, et plus souvent.
//
//                          Le vrai defaut n'est donc pas la coupure seule, c'est
//                          qu'ARMOR ABSORBE la requete cote maitre alors qu'elle
//                          est encore presentee en aval. Un correctif doit
//                          traiter les deux cotes ensemble : soit laisser l'AW
//                          deja presente s'accomplir en aval AVANT de fabriquer
//                          le ready, soit ne jamais presenter en aval un AW
//                          qu'on pourrait avoir a absorber -- ce qui demande un
//                          skid buffer, pas une inhibition.
//                          (b1/b2 sont des commandes a impulsion, auto-effacees)
//   0x18  STATUS       RO  verdicts instantanes
//   0x20  STICKY       RO  OU cumulatif de STATUS depuis le dernier STICKY_CLR
//   0x28  FAIL_CNT     RO  security_monitor.failure_count (8 bits)
//   0x30  CNT_BANNED   RO  nombre de bannissements (fronts montants)
//   0x38  CNT_STORM    RO  nombre d'episodes de storm de requetes
//   0x40  CNT_OUTS     RO  nombre d'episodes de saturation outstanding
//   0x48  CNT_MSI      RO  nombre d'episodes de storm MSI
//   0x50  DEV_ID_LAST  RO  dernier stream_id observe — sert a calibrer ID_CFG
//   0x58  MAGIC        RO  0x41524D4F52000006 ("ARMOR" + version)
//
// Bloc d'observabilite, ajoute le 2026-09-10 (d'ou MAGIC ...0002 : le logiciel
// distingue ainsi un bitstream qui porte ces registres d'un qui n'en a pas).
// Tout est en lecture seule et sans effet fonctionnel ; les accumulateurs sont
// remis a zero par CNT_CLR, comme les compteurs d'evenements.
//
//   0x60  DBG_UP       RO  poignees de main VIVANTES cote maitre surveille
//   0x68  DBG_DN       RO  poignees de main VIVANTES cote aval
//                          [0] aw_valid [1] aw_ready [2] w_valid [3] w_ready
//                          [4] w_last   [5] b_valid  [6] b_ready [7] ar_valid
//                          [8] ar_ready [9] r_valid [10] r_ready [11] r_last
//   0x70  DBG_STATE    RO  [3:0] w_owed [4] w_pending [5] verdict_known
//                          [6] comparison_valid [7] bad_id [8] legit_hit
//                          [9] legit_hit_eff [10] verdict_known_eff
//                          [12:11] FSM ecriture CSR [13] FSM lecture CSR
//                          [23:16] failure_count [31:24] outstanding
//                          [39:32] req_cnt fenetre [63:40] position fenetre
//   0x78  DBG_STALL_UP RO  plus longue attente d'un ready, cote maitre, par
//   0x80  DBG_STALL_DN RO  canal AW/W/B/AR/R : 5 champs de 12 bits, satures a
//                          4095. Saturé = coince ; moyen = contention.
//   0x88  CNT_CYC      RO  [31:0] cycles de blocage effectif
//                          [63:32] cycles passes en attente de verdict (HOLD)
//   0x90  CNT_REQ      RO  [31:0] transferts AW+AR presentes par le maitre
//                          [63:32] transferts AW+AR admis en aval
//                          leur difference = requetes reellement coupees
//   0x98  LAT_LAST     RO  [31:0] latence de detection de la derniere
//                          transaction, [63:32] latence de transaction
//   0xA0  LAT_DET_SUM  RO  somme des latences de detection
//   0xA8  LAT_TX_SUM   RO  somme des latences de transaction
//   0xB0  LAT_N        RO  [31:0] transactions mesurees
//                          [63:32] dont un verdict a ete observe
//   0xB8  LAT_MINMAX   RO  [15:0] det_min [31:16] det_max
//                          [47:32] tx_min [63:48] tx_max (satures a 65535)
//   0xC0  LAT_CUR      RO  [31:0] compteur de la transaction EN VOL,
//                          [32] mesure en cours, [33] verdict deja vu
//   0xC8  CYC_TOTAL    RO  cycles ecoules depuis le dernier CNT_CLR
//
// Version 3 (2026-09-10) : trois angles morts fermes, apres une campagne qui a
// gele avec sticky = 0, cyc_block = 0, cyc_hold = 0 et w_owed = 0 -- c'est-a-dire
// sans qu'aucun compteur existant ne voie quoi que ce soit.
//
//   0xD0  CNT_BADID    RO  [31:0] fronts de bad_id, [63:32] cycles a 1
//                          bad_id est le SEUL mecanisme gate par ENFORCE ; il
//                          n'avait ni bit de statut, ni bit collant, ni
//                          compteur. Il est aussi remonte dans STATUS[14] et
//                          rendu collant.
//   0xD8  CNT_WCH      RO  [31:0] AW admis en aval, [63:32] W-last admis
//                          comptes SEPAREMENT : `w_owed` est un solde dont le
//                          decrement garde absorbe un W-last excedentaire en
//                          silence. L'ecart se lit ici dans les deux sens.
//   0xE0  CNT_WANOM    RO  [31:0] beats FANTOMES, [63:32] W-last orphelins
//                          fantome = l'aval prend le beat alors que le maitre
//                          n'en est pas informe, donc le maitre le represente
//                          et l'aval en recoit deux. Trou reel de la branche
//                          HOLD de response_manager ; le banc le dit
//                          inatteignable par cet accelerateur, ce compteur
//                          verifie la meme chose sur la carte.
//   0xE8  DBG_WOWED    RO  [3:0] w_owed courant, [7:4] filigrane de maximum
//
// Version 4 (2026-09-10, apres le run SC03-first qui montre le gel specifique
// aux ECRITURES et non proportionnel a l'action d'ARMOR) :
//
//   0xF0  CNT_RETRACT  RO  VALID retire sans READY, 16 bits par canal :
//                          [15:0] AW aval, [31:16] AR aval, [47:32] W aval,
//                          [63:48] B ou R vers le maitre
//                          AXI4 interdit de retirer un VALID asserte. Ces
//                          compteurs sont les seuls a pouvoir le voir : aucun
//                          handshake ne s'accomplit, donc aucun autre ne bouge.
//   0xF8  DBG_RETRACT  RO  [31:0] cycle du PREMIER retrait (base CYC_TOTAL)
//                          [35:32] cause : b0 block_req, b1 !legit_hit,
//                                  b2 !verdict_known, b3 bad_id
//                          [39:36] canal : 1 AW, 2 AR, 3 W, 4 B/R
//                          [40] un retrait a ete vu
//                          La cause distingue « retrait pendant un blocage » de
//                          « retrait pendant l'attente de verdict » : deux
//                          correctifs differents.
//                          (w_owed_q fait 4 bits et sature a 15 ; le premier
//                          commentaire annoncait 8 bits par champ et le
//                          firmware l'a cru, d'ou un « w_owed=16 max=0 »
//                          impossible dans le log du 2026-09-10 12:36 :
//                          c'etait 0x10, soit max=1 et owed=0)
//
// Corrige aussi CNT_CYC[63:32] (cyc_hold), qui etait conditionne a la
// presentation d'une adresse et manquait donc tout HOLD entre pendant une phase
// W -- exactement le cas d'une rafale d'ecritures.
//
// Ces compteurs chronometrent au cycle, dans le wrapper : ils remplacent la
// mesure logicielle prise autour de `*ctrl = 1`, dont jusqu'a 48 % du chiffre
// etait le cout de la sonde elle-meme.
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
    // bad_id (2026-09-10). Il n'apparaissait NI ici, NI dans STICKY, NI dans
    // aucun compteur -- et c'est le seul mecanisme gate par ENFORCE : il
    // fabrique une terminaison SLVERR vers le maitre en forcant b_ready et
    // r_ready en aval. Un gel avec sticky=0 et cyc_block=0 etait donc
    // indiscernable d'un gel ou rien ne s'est passe. Il est desormais visible,
    // instantanement et de facon collante.
    armor_status[14]  = bad_id;
    armor_status[15]  = csr_awfix_q;   // echo du correctif AXI4
    armor_status[16]  = csr_wskid_q;   // echo de l'etage W
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
        csr_awfix_q    <= 1'b0;   // reset : comportement historique conserve
        csr_wskid_q    <= 1'b0;   // reset : etage W en derivation
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
                            csr_awfix_q    <= req_CPU_Wrapper__i.w.data[3];
                            csr_wskid_q    <= req_CPU_Wrapper__i.w.data[4];
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

// =============================================================================
//  OBSERVABILITE MATERIELLE  (2026-09-10)
//
//  Deux besoins, un seul bloc.
//
//  1. MESURER. Toutes les latences publiees jusqu'ici sont prises par le
//     logiciel, autour de `*ctrl = 1`, avec une lecture de compteur de part et
//     d'autre. Le cout de la sonde elle-meme (~650 ticks par lecture de `time`
//     sous Bao, ~1300 cycles coeur) representait jusqu'a 48 % du chiffre
//     publie : la mesure etait bornee par l'instrument, pas par le materiel.
//     Les compteurs ci-dessous chronometrent DANS le wrapper, au cycle, sans
//     instrument dans la boucle. C'est la mesure qu'on peut opposer a une autre
//     implementation.
//
//  2. DEBOGUER LE GEL. Le gel de SC02-STORM se produit sur un store CPU qui
//     n'emprunte meme pas ARMOR : pour qu'il reste en l'air, il faut que le
//     canal d'ecriture du crossbar partage soit coince par le chemin DMA. Le
//     banc de simulation ne modelise pas ce crossbar et a valide du vide quatre
//     fois de suite. Il faut donc lire l'etat sur la carte. Les registres
//     DBG_UP / DBG_DN donnent les poignees de main VIVANTES des deux cotes de
//     la coupure, DBG_STALL_* dit quel canal ne recoit pas son ready et depuis
//     combien de cycles, LAT_CUR dit depuis combien de temps une transaction
//     est en vol. Un blocage se lit alors, au lieu de se deviner.
//
//  Tout ce bloc est en LECTURE SEULE et ne pilote aucun signal fonctionnel :
//  aucun risque de changer un verdict en instrumentant. Les accumulateurs
//  suivent CNT_CLR, comme les compteurs d'evenements existants.
// =============================================================================

// -----------------------------------------------------------------------------
//  Poignees de main vivantes, de part et d'autre de la coupure
//
//  Meme disposition de bits des deux cotes, pour un seul decodeur logiciel :
//    [0] aw_valid [1] aw_ready [2] w_valid [3] w_ready [4] w_last
//    [5] b_valid  [6] b_ready  [7] ar_valid [8] ar_ready
//    [9] r_valid [10] r_ready [11] r_last
//
//  « up » = cote maitre surveille (l'accelerateur), « dn » = cote aval (IOMMU
//  puis crossbar). Comparer les deux revele exactement ce que la detection
//  actuelle confond : `request_flow_monitor` apparie le valid du maitre avec le
//  ready de l'aval, si bien qu'un handshake « brut » reste vrai alors qu'ARMOR
//  coupe et que rien ne circule.
// -----------------------------------------------------------------------------
logic [11:0] dbg_up, dbg_dn;

always_comb begin
    dbg_up      = 12'h0;
    dbg_up[0]   = req_IP_wrapper_i.aw_valid;
    dbg_up[1]   = resp_IP_wrapper_o.aw_ready;
    dbg_up[2]   = req_IP_wrapper_i.w_valid;
    dbg_up[3]   = resp_IP_wrapper_o.w_ready;
    dbg_up[4]   = req_IP_wrapper_i.w.last;
    dbg_up[5]   = resp_IP_wrapper_o.b_valid;
    dbg_up[6]   = req_IP_wrapper_i.b_ready;
    dbg_up[7]   = req_IP_wrapper_i.ar_valid;
    dbg_up[8]   = resp_IP_wrapper_o.ar_ready;
    dbg_up[9]   = resp_IP_wrapper_o.r_valid;
    dbg_up[10]  = req_IP_wrapper_i.r_ready;
    dbg_up[11]  = resp_IP_wrapper_o.r.last;

    dbg_dn      = 12'h0;
    dbg_dn[0]   = req_wrapper_iommu_o.aw_valid;
    dbg_dn[1]   = resp_wrapper_iommu_i.aw_ready;
    dbg_dn[2]   = req_wrapper_iommu_o.w_valid;
    dbg_dn[3]   = resp_wrapper_iommu_i.w_ready;
    dbg_dn[4]   = req_wrapper_iommu_o.w.last;
    dbg_dn[5]   = resp_wrapper_iommu_i.b_valid;
    dbg_dn[6]   = req_wrapper_iommu_o.b_ready;
    dbg_dn[7]   = req_wrapper_iommu_o.ar_valid;
    dbg_dn[8]   = resp_wrapper_iommu_i.ar_ready;
    dbg_dn[9]   = resp_wrapper_iommu_i.r_valid;
    dbg_dn[10]  = req_wrapper_iommu_o.r_ready;
    dbg_dn[11]  = resp_wrapper_iommu_i.r.last;
end

// -----------------------------------------------------------------------------
//  Transferts reels, et non fronts de handshake
//
//  A distinguer de `req_fire` du request_flow_monitor, qui compte des FRONTS :
//  en AXI, valid et ready tenus hauts, c'est un transfert PAR CYCLE, et les 24
//  lectures du mode outstanding ne comptaient que pour une. Ces deux compteurs
//  comptent les transferts, chacun de SON cote de la coupure. Leur difference
//  est le nombre de requetes qu'ARMOR a effectivement coupees -- la seule
//  mesure directe de son action, jusqu'ici deduite des verdicts.
// -----------------------------------------------------------------------------
logic up_aw_hs, up_ar_hs, up_b_hs, up_r_last_hs, dn_ar_hs;

assign up_aw_hs     = req_IP_wrapper_i.aw_valid & resp_IP_wrapper_o.aw_ready;
assign up_ar_hs     = req_IP_wrapper_i.ar_valid & resp_IP_wrapper_o.ar_ready;
assign up_b_hs      = resp_IP_wrapper_o.b_valid & req_IP_wrapper_i.b_ready;
assign up_r_last_hs = resp_IP_wrapper_o.r_valid & req_IP_wrapper_i.r_ready
                                                & resp_IP_wrapper_o.r.last;
assign dn_ar_hs     = req_wrapper_iommu_o.ar_valid & resp_wrapper_iommu_i.ar_ready;

// -----------------------------------------------------------------------------
//  Chronometre materiel d'une transaction
//
//  Definitions calquees sur celles de bench_runner.c, pour que les deux mesures
//  soient comparables -- et pour que l'ecart entre elles chiffre le cout de la
//  sonde logicielle :
//
//    depart   : front de presentation d'une requete par le maitre
//               (aw_valid | ar_valid), si aucune mesure n'est en cours ;
//    detection: premier cycle ou un verdict quelconque apparait ;
//    fin      : terminaison de la transaction VERS LE MAITRE (B, ou R avec
//               last) -- ce qui couvre aussi bien une transaction qui aboutit
//               qu'une que response_manager termine en SLVERR.
//
//  Trois approximations assumees, a garder en tete avant de publier :
//    - `tx` est lu au cycle de la fin, donc peut etre court d'un cycle ;
//    - un verdict qui apparait dans le meme cycle que le depart n'est pas vu
//      comme detection (la mesure n'est pas encore armee) : `det` vaut alors
//      `tx`, exactement comme le fait le logiciel quand il ne voit aucun bit ;
//    - une fin et un depart dans le meme cycle perdent le depart. Le bench
//      espace ses transactions, ca ne se produit pas sur ces scenarios.
//
//  LAT_CUR expose le compteur EN VOL : une transaction coincee s'y lit comme un
//  chiffre qui monte, la ou tout le reste reste muet.
// -----------------------------------------------------------------------------
logic        lat_verdict, lat_end, lat_start;
logic        req_presented, req_presented_q;

assign lat_verdict   = block_req_i | bad_id | block_ip_o
                     | block_req_flow | block_req_outs | block_msi;
assign lat_end       = up_b_hs | up_r_last_hs;
assign req_presented = req_IP_wrapper_i.aw_valid | req_IP_wrapper_i.ar_valid;

logic [31:0] lat_cnt_q;
logic        lat_busy_q, lat_evt_q;
logic [31:0] lat_det_q;
logic [31:0] lat_det_last_q, lat_tx_last_q;
logic [63:0] lat_det_sum_q,  lat_tx_sum_q;
logic [31:0] lat_n_q,        lat_n_blk_q;
logic [15:0] lat_det_min_q,  lat_det_max_q, lat_tx_min_q, lat_tx_max_q;

logic [31:0] lat_det_val;
logic [15:0] lat_det_sat, lat_tx_sat;

//  Le depart doit se rearmer sur une rafale. `req_presented` seul ne suffit
//  pas : pendant une tempete, le maitre tient aw_valid haut en permanence, il
//  n'y a donc plus AUCUN front et on n'aurait mesure que la premiere
//  transaction du scenario -- exactement les scenarios ou la mesure importe.
//  On part donc au premier des deux evenements : la presentation d'une requete
//  (front, qui inclut l'attente de verdict, pendant laquelle aucun handshake
//  n'a lieu) ou un transfert d'adresse reellement accepte cote maitre.
assign lat_start   = ~lat_busy_q & ( (req_presented & ~req_presented_q)
                                   | up_aw_hs | up_ar_hs );
assign lat_det_val = lat_evt_q ? lat_det_q : lat_cnt_q;
assign lat_det_sat = (lat_det_val > 32'd65535) ? 16'hFFFF : lat_det_val[15:0];
assign lat_tx_sat  = (lat_cnt_q   > 32'd65535) ? 16'hFFFF : lat_cnt_q[15:0];

// -----------------------------------------------------------------------------
//  Compteurs de temps et de trafic
// -----------------------------------------------------------------------------
logic [31:0] cnt_cyc_block_q, cnt_cyc_hold_q;
logic [31:0] cnt_req_up_q,    cnt_req_dn_q;
logic [63:0] cyc_total_q;

//  HOLD : la fenetre pendant laquelle response_manager tient le maitre sans
//  encore rien decider.
//
//  CORRECTIF DU 2026-09-10. La version precedente conditionnait le comptage a
//  `req_presented` (aw_valid | ar_valid). Or le commentaire du correctif de
//  verdict_known_q dit exactement pourquoi c'est faux : « une fois l'AW absorbe,
//  le maitre passe en phase W, plus rien n'est presente ». Un HOLD entre pendant
//  une phase W -- le cas qui compte pour une rafale d'ecritures -- etait donc
//  invisible, et c'est ce qui a fait lire `cyc_hold = 0` sur la campagne SC02
//  qui gele. Le compteur avait le meme angle mort que le defaut qu'il devait
//  eclairer.
//
//  On garde une garde d'activite, sinon on compterait le repos : apres reset et
//  sous ENFORCE = 1, verdict_known_q vaut 0 et le compteur saturerait sans qu'un
//  seul maitre attende. Mais cette garde couvre maintenant les trois facons
//  d'attendre : presenter une adresse, pousser des donnees, ou attendre une
//  reponse.
logic master_active, hold_mode;

assign master_active = req_presented
                     | req_IP_wrapper_i.w_valid
                     | lat_busy_q;

assign hold_mode = master_active & ~block_req_i & ~block_ip_eff & ~bad_id
                 & (~legit_hit_eff | ~verdict_known_eff);

logic [1:0] req_up_inc, req_dn_inc;
assign req_up_inc = {1'b0, up_aw_hs} + {1'b0, up_ar_hs};
assign req_dn_inc = {1'b0, dn_aw_hs} + {1'b0, dn_ar_hs};

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        req_presented_q <= 1'b0;
        lat_cnt_q       <= 32'h0;
        lat_busy_q      <= 1'b0;
        lat_evt_q       <= 1'b0;
        lat_det_q       <= 32'h0;
        lat_det_last_q  <= 32'h0;
        lat_tx_last_q   <= 32'h0;
        lat_det_sum_q   <= 64'h0;
        lat_tx_sum_q    <= 64'h0;
        lat_n_q         <= 32'h0;
        lat_n_blk_q     <= 32'h0;
        lat_det_min_q   <= 16'hFFFF;
        lat_tx_min_q    <= 16'hFFFF;
        lat_det_max_q   <= 16'h0;
        lat_tx_max_q    <= 16'h0;
        cnt_cyc_block_q <= 32'h0;
        cnt_cyc_hold_q  <= 32'h0;
        cnt_req_up_q    <= 32'h0;
        cnt_req_dn_q    <= 32'h0;
        cyc_total_q     <= 64'h0;
    end else begin
        req_presented_q <= req_presented;

        if (csr_cnt_clr) begin
            // Remise a zero solidaire des compteurs d'evenements : un scenario
            // de bench appelle CNT_CLR au demarrage, ses chiffres sont donc a
            // lui seul.
            lat_cnt_q       <= 32'h0;
            lat_busy_q      <= 1'b0;
            lat_evt_q       <= 1'b0;
            lat_det_q       <= 32'h0;
            lat_det_last_q  <= 32'h0;
            lat_tx_last_q   <= 32'h0;
            lat_det_sum_q   <= 64'h0;
            lat_tx_sum_q    <= 64'h0;
            lat_n_q         <= 32'h0;
            lat_n_blk_q     <= 32'h0;
            lat_det_min_q   <= 16'hFFFF;
            lat_tx_min_q    <= 16'hFFFF;
            lat_det_max_q   <= 16'h0;
            lat_tx_max_q    <= 16'h0;
            cnt_cyc_block_q <= 32'h0;
            cnt_cyc_hold_q  <= 32'h0;
            cnt_req_up_q    <= 32'h0;
            cnt_req_dn_q    <= 32'h0;
            cyc_total_q     <= 64'h0;
        end else begin
            cyc_total_q <= cyc_total_q + 64'd1;

            if (block_req_i && cnt_cyc_block_q != 32'hFFFF_FFFF)
                cnt_cyc_block_q <= cnt_cyc_block_q + 32'd1;
            if (hold_mode   && cnt_cyc_hold_q  != 32'hFFFF_FFFF)
                cnt_cyc_hold_q  <= cnt_cyc_hold_q + 32'd1;

            cnt_req_up_q <= cnt_req_up_q + {30'h0, req_up_inc};
            cnt_req_dn_q <= cnt_req_dn_q + {30'h0, req_dn_inc};

            if (lat_busy_q) begin
                if (lat_cnt_q != 32'hFFFF_FFFF) lat_cnt_q <= lat_cnt_q + 32'd1;

                if (!lat_evt_q && lat_verdict) begin
                    lat_evt_q <= 1'b1;
                    lat_det_q <= lat_cnt_q;
                end

                if (lat_end) begin
                    lat_busy_q     <= 1'b0;
                    lat_det_last_q <= lat_det_val;
                    lat_tx_last_q  <= lat_cnt_q;
                    lat_det_sum_q  <= lat_det_sum_q + {32'h0, lat_det_val};
                    lat_tx_sum_q   <= lat_tx_sum_q  + {32'h0, lat_cnt_q};
                    lat_n_q        <= lat_n_q + 32'd1;
                    if (lat_evt_q) lat_n_blk_q <= lat_n_blk_q + 32'd1;
                    if (lat_det_sat < lat_det_min_q) lat_det_min_q <= lat_det_sat;
                    if (lat_det_sat > lat_det_max_q) lat_det_max_q <= lat_det_sat;
                    if (lat_tx_sat  < lat_tx_min_q)  lat_tx_min_q  <= lat_tx_sat;
                    if (lat_tx_sat  > lat_tx_max_q)  lat_tx_max_q  <= lat_tx_sat;
                end
            end else if (lat_start) begin
                lat_busy_q <= 1'b1;
                lat_cnt_q  <= 32'h0;
                lat_det_q  <= 32'h0;
                //  Le verdict est echantillonne DES le cycle de depart.
                //  Sans cela il ne l'etait qu'a partir du cycle suivant, et le
                //  cas le plus interessant y echappait entierement : quand la
                //  fenetre de blocage est deja ouverte, response_manager
                //  termine la requete en SLVERR dans le cycle meme, si bien que
                //  la transaction etait finie avant d'avoir ete regardee. La
                //  simulation le montrait sans ambiguite -- n_verdict = 0 sur
                //  SC02-STORM et SC01-SPOOF, alors que 67 et 8 requetes
                //  respectivement avaient ete coupees.
                //
                //  Une detection a 0 cycle n'est pas une absence de mesure :
                //  c'est le cas ou ARMOR n'a rien eu a decider, son verdict
                //  etait deja rendu. C'est cette valeur-la qui soutient
                //  l'argument « une transaction bloquee coute moins cher
                //  qu'une qui aboutit ».
                lat_evt_q  <= lat_verdict;
            end
        end
    end
end

// -----------------------------------------------------------------------------
//  LE CANAL W, ET CE QUI LUI ARRIVE VRAIMENT  (2026-09-10)
//
//  Trois compteurs qui ferment trois angles morts nommes par la campagne du
//  2026-09-10, tous a l'endroit ou vit la signature du gel (sticky = 0,
//  cyc_block = 0, cyc_hold = 0, w_owed = 0).
//
//  1. bad_id. Compte en fronts ET en cycles. C'est le seul mecanisme gate par
//     ENFORCE, et il ne laissait aucune trace : ni bit de statut, ni bit
//     collant, ni compteur. `block_req_i` l'exclut, et `hold_mode` l'excluait
//     aussi. Un evenement bad_id etait litteralement indiscernable de rien.
//
//  2. Les deux cotes du canal W en aval, comptes SEPAREMENT. `w_owed_q` est un
//     solde, et son decrement est garde a zero : un W-last excedentaire y est
//     absorbe en silence. Compter les AW et les W-last separement rend le
//     desalignement lisible DANS LES DEUX SENS -- un AW sans donnees comme un
//     beat de trop. `cnt_w_orphan_q` isole directement le second cas.
//
//  3. Le BEAT FANTOME : l'aval prend le beat (w_valid & w_ready en aval) alors
//     que le maitre n'en est pas informe (w_ready retire cote maitre). Le maitre
//     croit son beat refuse et le represente ; l'aval en recoit deux, et le
//     canal W est decale pour toujours.
//
//     C'est un trou reel de la branche HOLD de response_manager, qui sort '0
//     sur tout -- donc w_ready = 0 -- alors que request_manager ne coupe
//     w_valid que si `!w_pending`. La branche passe-plat traite ce piege
//     explicitement ; la branche HOLD ne le traite pas.
//
//     Le banc dit ce trou INATTEIGNABLE par cet accelerateur : sa FSM est
//     sequentielle (G_AW -> G_W -> G_NEXT), donc `aw_owed max = 1` et jamais
//     deux ecritures ne se chevauchent. Mais le banc ne modelise ni la latence
//     de l'IOMMU, ni le crossbar, et il a deja valide du vide quatre fois. Ce
//     compteur est la version SUR CARTE du meme test : s'il bouge, le trou est
//     atteignable en vrai et on a la cause racine.
// -----------------------------------------------------------------------------
logic [31:0] cnt_badid_rise_q, cnt_badid_cy_q;
logic [31:0] cnt_aw_dn_q,      cnt_wlast_dn_q;
logic [31:0] cnt_w_ghost_q,    cnt_w_orphan_q;
logic [3:0]  w_owed_max_q;
logic        bad_id_d_q;

logic dn_w_ghost, dn_w_orphan;

//  Le beat part en aval et y est pris, mais le maitre ne recoit pas son ready.
assign dn_w_ghost  = req_wrapper_iommu_o.w_valid
                   & resp_wrapper_iommu_i.w_ready
                   & ~resp_IP_wrapper_o.w_ready;

//  Un W-last accepte en aval alors qu'aucun AW n'y attend de donnees, et
//  qu'aucun n'arrive dans le meme cycle : le solde ne peut pas le montrer.
assign dn_w_orphan = dn_w_last_hs & (w_owed_q == 4'h0) & ~dn_aw_hs;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        cnt_badid_rise_q <= 32'h0;
        cnt_badid_cy_q   <= 32'h0;
        cnt_aw_dn_q      <= 32'h0;
        cnt_wlast_dn_q   <= 32'h0;
        cnt_w_ghost_q    <= 32'h0;
        cnt_w_orphan_q   <= 32'h0;
        w_owed_max_q     <= 4'h0;
        bad_id_d_q       <= 1'b0;
    end else if (csr_cnt_clr) begin
        cnt_badid_rise_q <= 32'h0;
        cnt_badid_cy_q   <= 32'h0;
        cnt_aw_dn_q      <= 32'h0;
        cnt_wlast_dn_q   <= 32'h0;
        cnt_w_ghost_q    <= 32'h0;
        cnt_w_orphan_q   <= 32'h0;
        w_owed_max_q     <= 4'h0;
        bad_id_d_q       <= bad_id;
    end else begin
        bad_id_d_q <= bad_id;

        if (bad_id) begin
            if (cnt_badid_cy_q != 32'hFFFF_FFFF)
                cnt_badid_cy_q <= cnt_badid_cy_q + 32'd1;
            if (!bad_id_d_q)
                cnt_badid_rise_q <= cnt_badid_rise_q + 32'd1;
        end

        if (dn_aw_hs)     cnt_aw_dn_q    <= cnt_aw_dn_q    + 32'd1;
        if (dn_w_last_hs) cnt_wlast_dn_q <= cnt_wlast_dn_q + 32'd1;
        if (dn_w_ghost)   cnt_w_ghost_q  <= cnt_w_ghost_q  + 32'd1;
        if (dn_w_orphan)  cnt_w_orphan_q <= cnt_w_orphan_q + 32'd1;

        if (w_owed_q > w_owed_max_q) w_owed_max_q <= w_owed_q;
    end
end

// -----------------------------------------------------------------------------
//  VALID RETIRE SANS READY  (2026-09-10, apres le run SC03-first)
//
//  Le seul mecanisme qui reste compatible avec tout ce qui a ete mesure, et le
//  seul qu'aucun compteur existant ne puisse voir.
//
//  Ce que le run du 2026-09-10 13:07 etablit : SC03 (lectures) coupe 612
//  requetes et bloque 3251 cycles sans geler, SC02 (ecritures) gele apres 16
//  coupures et 78 cycles, et SC07 (100 ecritures legitimes, zero coupure) passe.
//  Le declencheur n'est donc ni l'ecriture seule, ni la quantite de blocage :
//  c'est UNE COUPURE SUR LE CHEMIN D'ECRITURE. Et a la frontiere d'ARMOR le
//  canal W est equilibre a chaque iteration, gel inclus.
//
//  L'explication : request_manager coupe `aw_valid` de facon COMBINATOIRE des
//  que block_req_i, !legit_hit ou !verdict_known monte. Si le maitre avait deja
//  aw_valid haut en attente de son aw_ready, ARMOR le RETIRE. AXI4 l'interdit --
//  un VALID asserte doit etre tenu jusqu'au READY -- et un IOMMU qui a commence
//  une traduction sur ce VALID peut en garder un etat partiel. Aucun de mes
//  compteurs ne bouge, puisqu'aucun handshake ne s'accomplit.
//
//  response_manager fait la meme chose dans l'autre sens : son mode HOLD sort
//  '0 sur tout, ce qui retire b_valid et r_valid vers le maitre. Meme famille de
//  violation, comptee aussi.
//
//  Definition : au cycle precedent VALID etait haut sans handshake, et VALID est
//  retombe. Comptage sature a 65535, un champ de 16 bits par canal.
//
//  Le premier retrait est HORODATE et sa CAUSE est capturee : c'est ce qui
//  distinguera « ARMOR retire un VALID pendant un blocage » de « pendant
//  l'attente de verdict », deux correctifs differents.
// -----------------------------------------------------------------------------
logic dn_aw_v_q, dn_ar_v_q, dn_w_v_q, up_b_v_q, up_r_v_q;
logic dn_aw_r_q, dn_ar_r_q, dn_w_r_q, up_b_r_q, up_r_r_q;

logic retract_aw, retract_ar, retract_w, retract_br;

//  « VALID etait haut, READY ne l'etait pas, et VALID est retombe. »
assign retract_aw = dn_aw_v_q & ~dn_aw_r_q & ~req_wrapper_iommu_o.aw_valid;
assign retract_ar = dn_ar_v_q & ~dn_ar_r_q & ~req_wrapper_iommu_o.ar_valid;
assign retract_w  = dn_w_v_q  & ~dn_w_r_q  & ~req_wrapper_iommu_o.w_valid;
assign retract_br = (up_b_v_q & ~up_b_r_q & ~resp_IP_wrapper_o.b_valid)
                  | (up_r_v_q & ~up_r_r_q & ~resp_IP_wrapper_o.r_valid);

logic [15:0] cnt_retr_aw_q, cnt_retr_ar_q, cnt_retr_w_q, cnt_retr_br_q;
logic [31:0] retr_first_cyc_q;
logic [3:0]  retr_first_cause_q;   // {bad_id, ~vk, ~legit, block_req}
logic [3:0]  retr_first_chan_q;    // 1 AW, 2 AR, 3 W, 4 B/R
logic        retr_seen_q;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        dn_aw_v_q <= 1'b0; dn_ar_v_q <= 1'b0; dn_w_v_q <= 1'b0;
        up_b_v_q  <= 1'b0; up_r_v_q  <= 1'b0;
        dn_aw_r_q <= 1'b0; dn_ar_r_q <= 1'b0; dn_w_r_q <= 1'b0;
        up_b_r_q  <= 1'b0; up_r_r_q  <= 1'b0;
        cnt_retr_aw_q      <= 16'h0;
        cnt_retr_ar_q      <= 16'h0;
        cnt_retr_w_q       <= 16'h0;
        cnt_retr_br_q      <= 16'h0;
        retr_first_cyc_q   <= 32'h0;
        retr_first_cause_q <= 4'h0;
        retr_first_chan_q  <= 4'h0;
        retr_seen_q        <= 1'b0;
    end else begin
        //  Memoire d'un cycle des deux cotes de chaque handshake surveille.
        dn_aw_v_q <= req_wrapper_iommu_o.aw_valid;
        dn_ar_v_q <= req_wrapper_iommu_o.ar_valid;
        dn_w_v_q  <= req_wrapper_iommu_o.w_valid;
        up_b_v_q  <= resp_IP_wrapper_o.b_valid;
        up_r_v_q  <= resp_IP_wrapper_o.r_valid;
        dn_aw_r_q <= resp_wrapper_iommu_i.aw_ready;
        dn_ar_r_q <= resp_wrapper_iommu_i.ar_ready;
        dn_w_r_q  <= resp_wrapper_iommu_i.w_ready;
        up_b_r_q  <= req_IP_wrapper_i.b_ready;
        up_r_r_q  <= req_IP_wrapper_i.r_ready;

        if (csr_cnt_clr) begin
            cnt_retr_aw_q      <= 16'h0;
            cnt_retr_ar_q      <= 16'h0;
            cnt_retr_w_q       <= 16'h0;
            cnt_retr_br_q      <= 16'h0;
            retr_first_cyc_q   <= 32'h0;
            retr_first_cause_q <= 4'h0;
            retr_first_chan_q  <= 4'h0;
            retr_seen_q        <= 1'b0;
        end else begin
            if (retract_aw && cnt_retr_aw_q != 16'hFFFF)
                cnt_retr_aw_q <= cnt_retr_aw_q + 16'd1;
            if (retract_ar && cnt_retr_ar_q != 16'hFFFF)
                cnt_retr_ar_q <= cnt_retr_ar_q + 16'd1;
            if (retract_w  && cnt_retr_w_q  != 16'hFFFF)
                cnt_retr_w_q  <= cnt_retr_w_q  + 16'd1;
            if (retract_br && cnt_retr_br_q != 16'hFFFF)
                cnt_retr_br_q <= cnt_retr_br_q + 16'd1;

            //  Premier retrait : on garde l'instant, la cause et le canal.
            //  L'ordre de priorite ne sert qu'a nommer UN canal quand plusieurs
            //  retombent ensemble ; les compteurs, eux, les comptent tous.
            if (!retr_seen_q && (retract_aw | retract_ar | retract_w | retract_br)) begin
                retr_seen_q        <= 1'b1;
                retr_first_cyc_q   <= cyc_total_q[31:0];
                retr_first_cause_q <= {bad_id, ~verdict_known_eff,
                                       ~legit_hit_eff, block_req_i};
                retr_first_chan_q  <= retract_aw ? 4'd1 :
                                      retract_ar ? 4'd2 :
                                      retract_w  ? 4'd3 : 4'd4;
            end
        end
    end
end

// -----------------------------------------------------------------------------
//  Canal qui n'obtient pas son ready, et depuis combien de cycles
//
//  Cinq canaux par cote, dans l'ordre AW, W, B, AR, R. On garde la plus longue
//  attente observee, saturee a 4095 cycles : une valeur saturee dit « coince »,
//  une valeur moyenne dit « contention ». C'est ce qui manquait pour nommer le
//  canal responsable d'un gel sans sonde externe, et ce qui chiffre le cout
//  d'attente que subit l'accelerateur legitime pendant qu'ARMOR delibere.
// -----------------------------------------------------------------------------
localparam int unsigned N_STALL = 5;

logic [N_STALL-1:0] stall_up, stall_dn;

assign stall_up = { resp_IP_wrapper_o.r_valid    & ~req_IP_wrapper_i.r_ready,
                    req_IP_wrapper_i.ar_valid    & ~resp_IP_wrapper_o.ar_ready,
                    resp_IP_wrapper_o.b_valid    & ~req_IP_wrapper_i.b_ready,
                    req_IP_wrapper_i.w_valid     & ~resp_IP_wrapper_o.w_ready,
                    req_IP_wrapper_i.aw_valid    & ~resp_IP_wrapper_o.aw_ready };

assign stall_dn = { resp_wrapper_iommu_i.r_valid & ~req_wrapper_iommu_o.r_ready,
                    req_wrapper_iommu_o.ar_valid & ~resp_wrapper_iommu_i.ar_ready,
                    resp_wrapper_iommu_i.b_valid & ~req_wrapper_iommu_o.b_ready,
                    req_wrapper_iommu_o.w_valid  & ~resp_wrapper_iommu_i.w_ready,
                    req_wrapper_iommu_o.aw_valid & ~resp_wrapper_iommu_i.aw_ready };

logic [11:0] stall_up_cur_q [N_STALL];
logic [11:0] stall_up_max_q [N_STALL];
logic [11:0] stall_dn_cur_q [N_STALL];
logic [11:0] stall_dn_max_q [N_STALL];

//  On compare la valeur INCREMENTEE au maximum, pas la valeur courante. Avec la
//  valeur courante, une attente d'un seul cycle laissait le maximum a zero --
//  c'est-a-dire invisible, alors que c'est le cas le plus frequent. La longueur
//  d'une attente est le nombre de cycles pendant lesquels `valid & ~ready` est
//  vrai, donc le compteur doit refleter le cycle en cours.
logic [11:0] stall_up_nxt [N_STALL];
logic [11:0] stall_dn_nxt [N_STALL];

always_comb begin
    for (int unsigned i = 0; i < N_STALL; i++) begin
        stall_up_nxt[i] = (stall_up_cur_q[i] == 12'hFFF) ? 12'hFFF
                                                         : stall_up_cur_q[i] + 12'd1;
        stall_dn_nxt[i] = (stall_dn_cur_q[i] == 12'hFFF) ? 12'hFFF
                                                         : stall_dn_cur_q[i] + 12'd1;
    end
end

//  La remise a zero par CNT_CLR est SYNCHRONE et doit donc etre une branche
//  distincte du reset asynchrone : `if (!rst_ni || csr_cnt_clr)` melange les
//  deux dans la meme condition, ce qui n'est pas une forme reconnue d'inference
//  de bascule et laisse la synthese libre de traiter CNT_CLR comme un signal de
//  reset asynchrone.
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        for (int unsigned i = 0; i < N_STALL; i++) begin
            stall_up_cur_q[i] <= 12'h0;
            stall_up_max_q[i] <= 12'h0;
            stall_dn_cur_q[i] <= 12'h0;
            stall_dn_max_q[i] <= 12'h0;
        end
    end else if (csr_cnt_clr) begin
        for (int unsigned i = 0; i < N_STALL; i++) begin
            stall_up_cur_q[i] <= 12'h0;
            stall_up_max_q[i] <= 12'h0;
            stall_dn_cur_q[i] <= 12'h0;
            stall_dn_max_q[i] <= 12'h0;
        end
    end else begin
        for (int unsigned i = 0; i < N_STALL; i++) begin
            if (stall_up[i]) begin
                stall_up_cur_q[i] <= stall_up_nxt[i];
                if (stall_up_nxt[i] > stall_up_max_q[i])
                    stall_up_max_q[i] <= stall_up_nxt[i];
            end else begin
                stall_up_cur_q[i] <= 12'h0;
            end

            if (stall_dn[i]) begin
                stall_dn_cur_q[i] <= stall_dn_nxt[i];
                if (stall_dn_nxt[i] > stall_dn_max_q[i])
                    stall_dn_max_q[i] <= stall_dn_nxt[i];
            end else begin
                stall_dn_cur_q[i] <= 12'h0;
            end
        end
    end
end

// -----------------------------------------------------------------------------
//  Mots de lecture assembles
// -----------------------------------------------------------------------------
logic [63:0] armor_dbg_state, armor_dbg_stall_up, armor_dbg_stall_dn;

//  Les etats de FSM passent par une variable de bits explicite : une assignation
//  directe d'un enum vers une tranche est legale mais son elargissement depend
//  de l'outil, et cette carte de registres est un contrat avec le logiciel.
logic [1:0]  w_state_bits;
logic        r_state_bits;
assign w_state_bits = w_state_q;   // extension implicite depuis l'enum
assign r_state_bits = r_state_q;

always_comb begin
    armor_dbg_state        = 64'h0;
    armor_dbg_state[3:0]   = w_owed_q;
    armor_dbg_state[4]     = w_pending;
    armor_dbg_state[5]     = verdict_known_q;
    armor_dbg_state[6]     = comparison_valid;
    armor_dbg_state[7]     = bad_id;
    armor_dbg_state[8]     = legit_hit;
    armor_dbg_state[9]     = legit_hit_eff;
    armor_dbg_state[10]    = verdict_known_eff;
    armor_dbg_state[12:11] = w_state_bits;   // FSM du port de config CPU
    armor_dbg_state[13]    = r_state_bits;
    armor_dbg_state[23:16] = failure_count;
    armor_dbg_state[31:24] = outs_depth;
    armor_dbg_state[39:32] = flow_req_cnt;
    armor_dbg_state[63:40] = flow_window_cnt[23:0];

    armor_dbg_stall_up        = 64'h0;
    armor_dbg_stall_up[11:0]  = stall_up_max_q[0];   // AW
    armor_dbg_stall_up[23:12] = stall_up_max_q[1];   // W
    armor_dbg_stall_up[35:24] = stall_up_max_q[2];   // B
    armor_dbg_stall_up[47:36] = stall_up_max_q[3];   // AR
    armor_dbg_stall_up[59:48] = stall_up_max_q[4];   // R

    armor_dbg_stall_dn        = 64'h0;
    armor_dbg_stall_dn[11:0]  = stall_dn_max_q[0];
    armor_dbg_stall_dn[23:12] = stall_dn_max_q[1];
    armor_dbg_stall_dn[35:24] = stall_dn_max_q[2];
    armor_dbg_stall_dn[47:36] = stall_dn_max_q[3];
    armor_dbg_stall_dn[59:48] = stall_dn_max_q[4];
end

// Multiplexeur de lecture
always_comb begin
    case (r_idx_q)
        5'd0:    csr_rdata = csr_id_cfg_q;
        5'd1:    csr_rdata = csr_msi_addr_q;
        5'd2:    csr_rdata = {59'h0, csr_wskid_q, csr_awfix_q, 2'b00, csr_enforce_q};
        5'd3:    csr_rdata = armor_status;
        5'd4:    csr_rdata = csr_sticky_q;
        5'd5:    csr_rdata = {56'h0, failure_count};
        5'd6:    csr_rdata = {32'h0, cnt_banned_q};
        5'd7:    csr_rdata = {32'h0, cnt_storm_q};
        5'd8:    csr_rdata = {32'h0, cnt_outs_q};
        5'd9:    csr_rdata = {32'h0, cnt_msi_q};
        5'd10:   csr_rdata = {{(64-DevIDWidth){1'b0}}, dev_id_last_q};
        5'd11:   csr_rdata = 64'h41524D4F52000006;
        // Observabilite (version 2 du MAGIC). Voir la carte des registres.
        5'd12:   csr_rdata = {52'h0, dbg_up};
        5'd13:   csr_rdata = {52'h0, dbg_dn};
        5'd14:   csr_rdata = armor_dbg_state;
        5'd15:   csr_rdata = armor_dbg_stall_up;
        5'd16:   csr_rdata = armor_dbg_stall_dn;
        5'd17:   csr_rdata = {cnt_cyc_hold_q, cnt_cyc_block_q};
        5'd18:   csr_rdata = {cnt_req_dn_q,   cnt_req_up_q};
        5'd19:   csr_rdata = {lat_tx_last_q,  lat_det_last_q};
        5'd20:   csr_rdata = lat_det_sum_q;
        5'd21:   csr_rdata = lat_tx_sum_q;
        5'd22:   csr_rdata = {lat_n_blk_q,    lat_n_q};
        5'd23:   csr_rdata = {lat_tx_max_q, lat_tx_min_q,
                              lat_det_max_q, lat_det_min_q};
        5'd24:   csr_rdata = {30'h0, lat_evt_q, lat_busy_q, lat_cnt_q};
        5'd25:   csr_rdata = cyc_total_q;
        // Fermeture des trois angles morts du 2026-09-10 (MAGIC ...0003).
        5'd26:   csr_rdata = {cnt_badid_cy_q,  cnt_badid_rise_q};
        5'd27:   csr_rdata = {cnt_wlast_dn_q,  cnt_aw_dn_q};
        5'd28:   csr_rdata = {cnt_w_orphan_q,  cnt_w_ghost_q};
        5'd29:   csr_rdata = {56'h0, w_owed_max_q, w_owed_q};
        // VALID retire sans READY : violation AXI4, invisible aux compteurs de
        // handshake puisqu'aucun handshake ne s'accomplit.
        5'd30:   csr_rdata = {cnt_retr_br_q, cnt_retr_w_q,
                              cnt_retr_ar_q, cnt_retr_aw_q};
        5'd31:   csr_rdata = {23'h0, retr_seen_q, retr_first_chan_q,
                              retr_first_cause_q, retr_first_cyc_q};
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