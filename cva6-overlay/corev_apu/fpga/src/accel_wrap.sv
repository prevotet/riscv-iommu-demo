// ============================================================
//  accel_wrap.sv — Accelerateur DMA pilote par MMIO
//
//  Instancie deux fois par ariane_peripherals_xilinx.sv :
//    - LHA (Legitimate Hardware Accelerator) : STREAM_ID = 1, base 0x5000_0000
//    - MHA (Malicious  Hardware Accelerator) : STREAM_ID = 2, base 0x5000_1000
//
//  Historique : ce fichier etait un template dont le compute_core etait en
//  commentaire ; le seul maitre AXI reellement instancie etait un iDMA dont la
//  carte de registres (idma_reg64_frontend : SRC/DST/NUM_BYTES/CONF/STATUS/
//  NEXT_ID, lancement par LECTURE de NEXT_ID) n'avait rien a voir avec celle
//  que bao-baremetal-guest attend. Aucune campagne ne pouvait donc mesurer quoi
//  que ce soit. Cette version implemente la carte attendue par main.c et
//  bench_runner.c, et remplace l'iDMA par un generateur de trafic capable de
//  produire les stimuli d'attaque — un iDMA standard ne peut pas, par exemple,
//  usurper son stream_id, qui y est cable en dur.
//
//  Carte des registres (64 bits, index decode sur addr[7:3]) :
//    0x00  CTRL         W   bit0 = start (impulsion, auto-effacee)
//    0x08  STATUS       R   [0] BUSY [1] DONE [2] ERROR
//                           [3] BLOCKED [4] BANNED [5] STORM [6] OUTS [7] MSI
//                           (bits 3..7 = verdicts ARMOR, via armor_status_i)
//    0x10  BASE_ADDR    RW  adresse destination
//    0x18  SIZE         RW  taille du transfert en octets
//    0x20  CONFIG       RW  bit0 = 1 lecture / 0 ecriture ; bit1 = continu
//    0x28  ATTACK_MODE  RW  0..6, voir ci-dessous
//    0x30  BLOCKED_CNT  R   nombre de transactions avortees sur timeout
//    0x58  BTN_STATE    R   {btnc, btnr, btnl, btnd, btnu}
//
//  Modes d'attaque :
//    0 Normal              trafic legitime, stream_id = STREAM_ID
//    1 ID spoofing         emet stream_id = SPOOF_STREAM_ID (usurpe le LHA)
//    2 Adresse interdite   cible FORBIDDEN_ADDR au lieu de BASE_ADDR
//    3 Escalade privileges  positionne AxPROT en privilegie/securise
//    4 Tempete de requetes  STORM_REQS ecritures a la volee
//    5 Saturation outstanding OUTS_REQS lectures sans consommer les reponses
//    6 Tempete MSI          MSI_REQS ecritures vers l'adresse surveillee
//
//  NOTE sur les identifiants AXI : request_flow_monitor ne compte une requete
//  que si `handshake && (premiere_req || id_change)`. Les modes de flood font
//  donc varier aw_id/ar_id a chaque requete, sans quoi les moniteurs de flux et
//  d'outstanding ne verraient qu'une seule requete et ne se declencheraient
//  jamais.
// ============================================================

module accel_wrap #(
    parameter int unsigned AXI_ADDR_WIDTH   = 64,
    parameter int unsigned AXI_DATA_WIDTH   = 64,
    parameter int unsigned AXI_ID_WIDTH     = 3,    // IdWidth-1 = 3b (le mux ajoute 1 bit)
    parameter int unsigned AXI_USER_WIDTH   = 1,
    parameter int unsigned AXI_SLV_ID_WIDTH = 6,    // IdWidthSlave
    // Identifiant IOMMU de ce device (unique par accelerateur)
    parameter logic [23:0] STREAM_ID        = 24'd1,
    // Identifiant usurpe en mode 1 (typiquement celui du LHA)
    parameter logic [23:0] SPOOF_STREAM_ID  = 24'd1,
    // Adresse visee en mode 2 (zone OpenSBI, hors fenetre guest)
    parameter logic [63:0] FORBIDDEN_ADDR   = 64'h0000_0000_8000_0000,
    // Nombre de requetes emises par les modes de flood
    parameter int unsigned STORM_REQS       = 16,
    parameter int unsigned OUTS_REQS        = 24,
    parameter int unsigned MSI_REQS         = 48,
    // Garde-fou : une requete bloquee par ARMOR ne recoit jamais son ready
    parameter int unsigned TIMEOUT_CYCLES   = 32'd65536
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic testmode_i,
    input  logic btnu_i,
    input  logic btnd_i,
    input  logic btnl_i,
    input  logic btnr_i,
    input  logic btnc_i,

    // Verdicts ARMOR remontes par le sec_wrapper place en aval
    // (bit 0 -> STATUS[3] BLOCKED, ... bit 4 -> STATUS[7] MSI)
    input  logic [4:0] armor_status_i,

    // Interface de configuration MMIO (esclave AXI, depuis le XBAR)
    AXI_BUS.Slave  axi_cfg,

    // Interface DMA maitre (vers sec_wrapper -> axi_mux -> IOMMU)
    AXI_BUS_MMU.Master axi_dma
);

    localparam int unsigned STRB_WIDTH = AXI_DATA_WIDTH / 8;
    localparam logic [2:0]  AXI_SIZE_8B = 3'd3;   // 2^3 = 8 octets par beat

    // =========================================================================
    //  Registres
    // =========================================================================
    logic [63:0] reg_base_q;      // 0x10 BASE_ADDR
    logic [63:0] reg_size_q;      // 0x18 SIZE
    logic [63:0] reg_conf_q;      // 0x20 CONFIG
    logic [63:0] reg_mode_q;      // 0x28 ATTACK_MODE
    logic [31:0] reg_blkcnt_q;    // 0x30 BLOCKED_CNT

    logic        start_pulse;     // impulsion issue de l'ecriture de CTRL
    logic        busy_q, done_q, error_q;

    logic [4:0]  btn_state;
    assign btn_state = {btnc_i, btnr_i, btnl_i, btnd_i, btnu_i};

    // Les verdicts ARMOR ne durent que quelques cycles (BLOCK_CYCLES = 4 et 10
    // en profil BENCH) : une lecture logicielle de STATUS apres la transaction
    // les raterait systematiquement. On les memorise donc ici pour la duree
    // d'une transaction, remise a zero a chaque start.
    logic [4:0] armor_sticky_q;

    logic [63:0] status_word;
    always_comb begin
        status_word     = 64'h0;
        status_word[0]  = busy_q;
        status_word[1]  = done_q;
        status_word[2]  = error_q;
        status_word[7:3]= armor_sticky_q;
    end

    // =========================================================================
    //  Esclave AXI4 de configuration
    //
    //  Meme structure minimale que le CSR du sec_wrapper : un acces en vol par
    //  sens, rafales INCR gerees en incrementant l'index de registre. On
    //  n'accepte pas de W avant son AW, ce qui est licite en AXI4.
    // =========================================================================
    typedef enum logic [1:0] { CFG_W_IDLE, CFG_W_DATA, CFG_W_RESP } cfg_w_state_e;
    typedef enum logic       { CFG_R_IDLE, CFG_R_DATA }             cfg_r_state_e;

    cfg_w_state_e                 cw_state_q;
    cfg_r_state_e                 cr_state_q;
    logic [AXI_SLV_ID_WIDTH-1:0]  cw_id_q, cr_id_q;
    logic [7:0]                   cr_len_q, cr_beat_q;
    logic [4:0]                   cw_idx_q, cr_idx_q;
    logic [63:0]                  cfg_rdata;

    always_comb begin
        case (cr_idx_q)
            5'd0:    cfg_rdata = 64'h0;                    // CTRL : write-only
            5'd1:    cfg_rdata = status_word;              // STATUS
            5'd2:    cfg_rdata = reg_base_q;               // BASE_ADDR
            5'd3:    cfg_rdata = reg_size_q;               // SIZE
            5'd4:    cfg_rdata = reg_conf_q;               // CONFIG
            5'd5:    cfg_rdata = reg_mode_q;               // ATTACK_MODE
            5'd6:    cfg_rdata = {32'h0, reg_blkcnt_q};    // BLOCKED_CNT
            5'd11:   cfg_rdata = {59'h0, btn_state};       // BTN_STATE (0x58)
            default: cfg_rdata = 64'h0;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cw_state_q  <= CFG_W_IDLE;
            cw_id_q     <= '0;
            cw_idx_q    <= '0;
            reg_base_q  <= 64'h0;
            reg_size_q  <= 64'h0;
            reg_conf_q  <= 64'h0;
            reg_mode_q  <= 64'h0;
            start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;

            case (cw_state_q)
                CFG_W_IDLE: begin
                    if (axi_cfg.aw_valid) begin
                        cw_id_q    <= axi_cfg.aw_id;
                        cw_idx_q   <= axi_cfg.aw_addr[7:3];
                        cw_state_q <= CFG_W_DATA;
                    end
                end

                CFG_W_DATA: begin
                    if (axi_cfg.w_valid) begin
                        case (cw_idx_q)
                            5'd0: start_pulse <= axi_cfg.w_data[0];
                            5'd2: reg_base_q  <= axi_cfg.w_data;
                            5'd3: reg_size_q  <= axi_cfg.w_data;
                            5'd4: reg_conf_q  <= axi_cfg.w_data;
                            5'd5: reg_mode_q  <= axi_cfg.w_data;
                            default: ; // lecture seule
                        endcase
                        cw_idx_q <= cw_idx_q + 1'b1;
                        if (axi_cfg.w_last) cw_state_q <= CFG_W_RESP;
                    end
                end

                CFG_W_RESP: begin
                    if (axi_cfg.b_ready) cw_state_q <= CFG_W_IDLE;
                end

                default: cw_state_q <= CFG_W_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cr_state_q <= CFG_R_IDLE;
            cr_id_q    <= '0;
            cr_len_q   <= 8'h0;
            cr_idx_q   <= '0;
            cr_beat_q  <= 8'h0;
        end else begin
            case (cr_state_q)
                CFG_R_IDLE: begin
                    if (axi_cfg.ar_valid) begin
                        cr_id_q    <= axi_cfg.ar_id;
                        cr_len_q   <= axi_cfg.ar_len;
                        cr_idx_q   <= axi_cfg.ar_addr[7:3];
                        cr_beat_q  <= 8'h0;
                        cr_state_q <= CFG_R_DATA;
                    end
                end

                CFG_R_DATA: begin
                    if (axi_cfg.r_ready) begin
                        if (cr_beat_q == cr_len_q) begin
                            cr_state_q <= CFG_R_IDLE;
                        end else begin
                            cr_idx_q  <= cr_idx_q  + 1'b1;
                            cr_beat_q <= cr_beat_q + 8'h1;
                        end
                    end
                end

                default: cr_state_q <= CFG_R_IDLE;
            endcase
        end
    end

    assign axi_cfg.aw_ready = (cw_state_q == CFG_W_IDLE);
    assign axi_cfg.w_ready  = (cw_state_q == CFG_W_DATA);
    assign axi_cfg.b_valid  = (cw_state_q == CFG_W_RESP);
    assign axi_cfg.b_id     = cw_id_q;
    assign axi_cfg.b_resp   = 2'b00;
    assign axi_cfg.b_user   = '0;

    assign axi_cfg.ar_ready = (cr_state_q == CFG_R_IDLE);
    assign axi_cfg.r_valid  = (cr_state_q == CFG_R_DATA);
    assign axi_cfg.r_id     = cr_id_q;
    assign axi_cfg.r_data   = cfg_rdata;
    assign axi_cfg.r_resp   = 2'b00;
    assign axi_cfg.r_last   = (cr_beat_q == cr_len_q);
    assign axi_cfg.r_user   = '0;

    // =========================================================================
    //  Parametres derives du mode d'attaque
    // =========================================================================
    logic [7:0]  n_req;        // nombre de requetes pour un start
    logic        vary_id;      // faire varier l'ID AXI entre requetes
    logic [23:0] sid_eff;      // stream_id emis
    logic [63:0] addr_eff;     // adresse ciblee
    logic [2:0]  prot_eff;     // AxPROT
    logic        is_write;     // sens du transfert
    logic        hold_r;       // ne pas consommer les reponses R pendant l'emission
    logic [7:0]  burst_len;    // len AXI (nombre de beats - 1)

    // SIZE est en octets ; un beat fait 8 octets. On borne a 256 beats.
    logic [7:0] len_from_size;
    always_comb begin
        if (reg_size_q <= 64'd8)        len_from_size = 8'd0;
        else if (reg_size_q >= 64'd2048) len_from_size = 8'd255;
        else                             len_from_size = reg_size_q[10:3] - 8'd1;
    end

    always_comb begin
        // Valeurs par defaut = mode 0 (normal)
        n_req     = 8'd1;
        vary_id   = 1'b0;
        sid_eff   = STREAM_ID;
        addr_eff  = reg_base_q;
        prot_eff  = 3'b000;
        is_write  = ~reg_conf_q[0];      // CONFIG bit0 : 1 = lecture, 0 = ecriture
        hold_r    = 1'b0;
        burst_len = len_from_size;

        case (reg_mode_q[2:0])
            3'd1: begin // usurpation d'identifiant
                sid_eff   = SPOOF_STREAM_ID;
            end
            3'd2: begin // adresse interdite
                addr_eff  = FORBIDDEN_ADDR;
            end
            3'd3: begin // escalade de privileges : privilegie + securise + instruction
                prot_eff  = 3'b111;
            end
            3'd4: begin // tempete de requetes
                n_req     = STORM_REQS[7:0];
                vary_id   = 1'b1;
                is_write  = 1'b1;
                burst_len = 8'd0;
            end
            3'd5: begin // saturation du compteur d'outstanding
                n_req     = OUTS_REQS[7:0];
                vary_id   = 1'b1;
                is_write  = 1'b0;
                hold_r    = 1'b1;
                burst_len = 8'd0;
            end
            3'd6: begin // tempete MSI : ecritures repetees vers l'adresse surveillee
                n_req     = MSI_REQS[7:0];
                vary_id   = 1'b1;
                is_write  = 1'b1;
                burst_len = 8'd0;
            end
            default: ; // 0 et valeurs hors plage : trafic normal
        endcase
    end

    // =========================================================================
    //  Generateur de trafic
    //
    //  Phase d'emission : n_req requetes, puis phase de drainage des reponses.
    //  Un timeout borne l'attente : quand ARMOR bloque, request_manager retire
    //  aw_valid/ar_valid en aval et le ready n'arrive jamais.
    // =========================================================================
    typedef enum logic [2:0] {
        G_IDLE, G_AW, G_W, G_AR, G_NEXT, G_DRAIN, G_FINISH
    } gen_state_e;

    gen_state_e  g_state_q;
    logic [7:0]  req_idx_q;      // requete en cours
    logic [7:0]  beat_q;         // beat W en cours
    logic [7:0]  b_cnt_q, r_cnt_q;
    logic [31:0] timeout_q;
    logic        timeout_hit;
    logic [63:0] wdata_q;

    logic [AXI_ID_WIDTH-1:0] cur_id;
    assign cur_id = vary_id ? req_idx_q[AXI_ID_WIDTH-1:0] : '0;

    logic issuing;
    assign issuing = (g_state_q == G_AW) || (g_state_q == G_W) ||
                     (g_state_q == G_AR) || (g_state_q == G_NEXT);

    assign timeout_hit = (timeout_q >= TIMEOUT_CYCLES);

    // Canal AW
    assign axi_dma.aw_valid       = (g_state_q == G_AW);
    assign axi_dma.aw_id          = cur_id;
    assign axi_dma.aw_addr        = addr_eff;
    assign axi_dma.aw_len         = burst_len;
    assign axi_dma.aw_size        = AXI_SIZE_8B;
    assign axi_dma.aw_burst       = 2'b01;   // INCR
    assign axi_dma.aw_lock        = 1'b0;
    assign axi_dma.aw_cache       = 4'b0000;
    assign axi_dma.aw_prot        = prot_eff;
    assign axi_dma.aw_qos         = 4'b0000;
    assign axi_dma.aw_region      = 4'b0000;
    assign axi_dma.aw_atop        = 6'b000000;
    assign axi_dma.aw_user        = '0;
    assign axi_dma.aw_stream_id   = sid_eff;
    assign axi_dma.aw_ss_id_valid = 1'b0;
    assign axi_dma.aw_substream_id= 20'd0;

    // Canal W
    assign axi_dma.w_valid = (g_state_q == G_W);
    assign axi_dma.w_data  = wdata_q;
    assign axi_dma.w_strb  = {STRB_WIDTH{1'b1}};
    assign axi_dma.w_last  = (beat_q == burst_len);
    assign axi_dma.w_user  = '0;

    // Canal B — toujours pret a encaisser les reponses d'ecriture
    assign axi_dma.b_ready = 1'b1;

    // Canal AR
    assign axi_dma.ar_valid       = (g_state_q == G_AR);
    assign axi_dma.ar_id          = cur_id;
    assign axi_dma.ar_addr        = addr_eff;
    assign axi_dma.ar_len         = burst_len;
    assign axi_dma.ar_size        = AXI_SIZE_8B;
    assign axi_dma.ar_burst       = 2'b01;   // INCR
    assign axi_dma.ar_lock        = 1'b0;
    assign axi_dma.ar_cache       = 4'b0000;
    assign axi_dma.ar_prot        = prot_eff;
    assign axi_dma.ar_qos         = 4'b0000;
    assign axi_dma.ar_region      = 4'b0000;
    assign axi_dma.ar_user        = '0;
    assign axi_dma.ar_stream_id   = sid_eff;
    assign axi_dma.ar_ss_id_valid = 1'b0;
    assign axi_dma.ar_substream_id= 20'd0;

    // Canal R — en mode 5 on retient volontairement r_ready pendant l'emission
    // pour laisser grimper le compteur d'outstanding du sec_wrapper.
    assign axi_dma.r_ready = !(hold_r && issuing);

    logic b_fire, r_fire;
    assign b_fire = axi_dma.b_valid && axi_dma.b_ready;
    assign r_fire = axi_dma.r_valid && axi_dma.r_ready && axi_dma.r_last;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            g_state_q    <= G_IDLE;
            req_idx_q    <= 8'h0;
            beat_q       <= 8'h0;
            b_cnt_q      <= 8'h0;
            r_cnt_q      <= 8'h0;
            timeout_q    <= 32'h0;
            wdata_q      <= 64'h0;
            armor_sticky_q <= 5'h0;
            busy_q       <= 1'b0;
            done_q       <= 1'b0;
            error_q      <= 1'b0;
            reg_blkcnt_q <= 32'h0;
        end else begin
            // Memorisation des verdicts ARMOR pendant toute la transaction
            if (g_state_q != G_IDLE) armor_sticky_q <= armor_sticky_q | armor_status_i;

            // Comptage des reponses, valable dans tous les etats
            if (b_fire) b_cnt_q <= b_cnt_q + 8'h1;
            if (r_fire) r_cnt_q <= r_cnt_q + 8'h1;

            // Detection d'erreur sur les reponses
            if (b_fire && axi_dma.b_resp != 2'b00) error_q <= 1'b1;
            if (r_fire && axi_dma.r_resp != 2'b00) error_q <= 1'b1;

            if (g_state_q != G_IDLE && g_state_q != G_FINISH)
                timeout_q <= timeout_q + 32'h1;

            case (g_state_q)
                G_IDLE: begin
                    if (start_pulse) begin
                        busy_q    <= 1'b1;
                        done_q    <= 1'b0;
                        error_q   <= 1'b0;
                        armor_sticky_q <= 5'h0;
                        req_idx_q <= 8'h0;
                        beat_q    <= 8'h0;
                        b_cnt_q   <= 8'h0;
                        r_cnt_q   <= 8'h0;
                        timeout_q <= 32'h0;
                        g_state_q <= (~reg_conf_q[0]) ? G_AW : G_AR;
                    end
                end

                G_AW: begin
                    if (axi_dma.aw_ready) begin
                        beat_q    <= 8'h0;
                        g_state_q <= G_W;
                    end else if (timeout_hit) begin
                        error_q      <= 1'b1;
                        reg_blkcnt_q <= reg_blkcnt_q + 32'h1;
                        g_state_q    <= G_FINISH;
                    end
                end

                G_W: begin
                    if (axi_dma.w_ready) begin
                        wdata_q <= wdata_q + 64'h1;
                        if (beat_q == burst_len) begin
                            g_state_q <= G_NEXT;
                        end else begin
                            beat_q <= beat_q + 8'h1;
                        end
                    end else if (timeout_hit) begin
                        error_q      <= 1'b1;
                        reg_blkcnt_q <= reg_blkcnt_q + 32'h1;
                        g_state_q    <= G_FINISH;
                    end
                end

                G_AR: begin
                    if (axi_dma.ar_ready) begin
                        g_state_q <= G_NEXT;
                    end else if (timeout_hit) begin
                        error_q      <= 1'b1;
                        reg_blkcnt_q <= reg_blkcnt_q + 32'h1;
                        g_state_q    <= G_FINISH;
                    end
                end

                G_NEXT: begin
                    if (req_idx_q + 8'h1 >= n_req) begin
                        g_state_q <= G_DRAIN;
                    end else begin
                        req_idx_q <= req_idx_q + 8'h1;
                        g_state_q <= is_write ? G_AW : G_AR;
                    end
                end

                G_DRAIN: begin
                    // On attend autant de reponses que de requetes emises.
                    if (is_write) begin
                        if (b_cnt_q >= n_req) g_state_q <= G_FINISH;
                    end else begin
                        if (r_cnt_q >= n_req) g_state_q <= G_FINISH;
                    end
                    if (timeout_hit) begin
                        error_q      <= 1'b1;
                        reg_blkcnt_q <= reg_blkcnt_q + 32'h1;
                        g_state_q    <= G_FINISH;
                    end
                end

                G_FINISH: begin
                    // Mode continu (CONFIG bit1) : on relance tant que le bit
                    // reste arme. lha_bg_stop() l'efface pour arreter le fond.
                    if (reg_conf_q[1]) begin
                        req_idx_q <= 8'h0;
                        beat_q    <= 8'h0;
                        b_cnt_q   <= 8'h0;
                        r_cnt_q   <= 8'h0;
                        timeout_q <= 32'h0;
                        g_state_q <= is_write ? G_AW : G_AR;
                    end else begin
                        busy_q    <= 1'b0;
                        done_q    <= 1'b1;
                        g_state_q <= G_IDLE;
                    end
                end

                default: g_state_q <= G_IDLE;
            endcase
        end
    end

endmodule
