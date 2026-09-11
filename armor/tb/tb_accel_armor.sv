// =============================================================================
//  tb_accel_armor -- banc xsim : accel_wrap + wrapper (ARMOR) + aval mort
//
//  But : reproduire en simulation le gel constate sur carte, ou le CPU se fige
//  sur un acces MMIO des que le DMA cale (cf. campagne du 2026-09-07 : aucun
//  verdict DONE, gel avant la premiere ligne CSV avec -DBENCH_SC06_FIRST).
//
//  Le point cle est que le chemin CSR NE TRAVERSE PAS ARMOR : le CPU attaque
//  accel_wrap.axi_cfg via le XBAR, et le port CSR du wrapper directement.
//  ARMOR est sur le chemin DMA. Un gel du CPU sur un acces MMIO met donc en
//  cause un des deux ports de configuration, pas le filtrage. Le banc inclut
//  les deux et un aval bloque, pour repondre a :
//
//      le CPU peut-il encore lire les registres pendant que le DMA est cale ?
//
//  Les deux FSM de accel_wrap (cw_state_q / cr_state_q) et celles du wrapper
//  (w_state_q / r_state_q) sont individuellement conformes au protocole AXI,
//  mais aucune n'a de timeout ni d'echappatoire : un seul handshake perdu
//  verrouille le port, et avec lui le CPU.
//
//  Topologie :
//
//      TB (maitre AXI) --cfg--> accel_wrap --dma--> wrapper --out--> aval
//      TB (maitre AXI) --csr----------------------> wrapper           |
//                                                          jamais de B/R
//
//  Trois scenarios, choisis par +SCENARIO=<n> :
//    0  aval sain          -- controle : la transaction doit aboutir (DONE)
//    1  aval qui accepte AW/AR mais ne renvoie jamais B ni R  (le cas carte)
//    2  aval qui n'accepte meme pas AW/AR
//
//  Dans les scenarios 1 et 2, le TB continue de lire STATUS et MAGIC pendant
//  que le DMA est cale : si ces lectures cessent d'aboutir, le verrouillage du
//  port de configuration est demontre, et c'est le premier defaut a corriger --
//  sans quoi ajouter des registres d'observabilite ne sert a rien, on ne
//  pourra pas les lire.
// =============================================================================

`timescale 1ns/1ps

module tb_accel_armor;

    // -------------------------------------------------------------------------
    //  Parametres -- identiques a l'instanciation de ariane_peripherals_xilinx
    // -------------------------------------------------------------------------
    localparam int unsigned AxiAddrWidth = 64;
    localparam int unsigned AxiDataWidth = 64;
    localparam int unsigned AxiUserWidth = 1;
    localparam int unsigned IdWidthDma   = ariane_soc::IdWidth - 1;   // 3
    localparam int unsigned IdWidthSlv   = ariane_soc::IdWidthSlave;  // 6

    // TIMEOUT_CYCLES de l'accelerateur reduit de 65536 a 2000 : la simulation
    // doit voir le timeout sans durer une eternite.
    localparam int unsigned AccelTimeout = 2000;

    // Carte des registres de accel_wrap (index sur addr[7:3])
    localparam logic [63:0] ACC_CTRL   = 64'h00;
    localparam logic [63:0] ACC_STATUS = 64'h08;
    localparam logic [63:0] ACC_BASE   = 64'h10;
    localparam logic [63:0] ACC_SIZE   = 64'h18;
    localparam logic [63:0] ACC_CONF   = 64'h20;
    localparam logic [63:0] ACC_MODE   = 64'h28;
    localparam logic [63:0] ACC_BLKCNT = 64'h30;
    localparam logic [63:0] ACC_MSIADR = 64'h38;

    // Carte des registres CSR du wrapper
    localparam logic [63:0] CSR_ID_CFG = 64'h00;
    localparam logic [63:0] CSR_MSIADR = 64'h08;
    localparam logic [63:0] CSR_CTRL   = 64'h10;
    localparam logic [63:0] CSR_STATUS = 64'h18;
    localparam logic [63:0] CSR_STICKY  = 64'h20;
    localparam logic [63:0] CSR_FAILCNT = 64'h28;
    localparam logic [63:0] CSR_MAGIC  = 64'h58;

    // Bloc d'observabilite (MAGIC v2) — voir armor/SRC/wrapper.sv
    localparam logic [63:0] CSR_DBG_UP    = 64'h60;
    localparam logic [63:0] CSR_DBG_DN    = 64'h68;
    localparam logic [63:0] CSR_DBG_STATE = 64'h70;
    localparam logic [63:0] CSR_STALL_UP  = 64'h78;
    localparam logic [63:0] CSR_STALL_DN  = 64'h80;
    localparam logic [63:0] CSR_CNT_CYC   = 64'h88;
    localparam logic [63:0] CSR_CNT_REQ   = 64'h90;
    localparam logic [63:0] CSR_LAT_LAST  = 64'h98;
    localparam logic [63:0] CSR_LAT_DSUM  = 64'hA0;
    localparam logic [63:0] CSR_LAT_TSUM  = 64'hA8;
    localparam logic [63:0] CSR_LAT_N     = 64'hB0;
    localparam logic [63:0] CSR_LAT_MM    = 64'hB8;
    localparam logic [63:0] CSR_LAT_CUR   = 64'hC0;
    localparam logic [63:0] CSR_CYC_TOTAL = 64'hC8;
    // Version 3 : les trois angles morts fermes
    localparam logic [63:0] CSR_CNT_BADID = 64'hD0;
    localparam logic [63:0] CSR_CNT_WCH   = 64'hD8;
    localparam logic [63:0] CSR_CNT_WANOM = 64'hE0;
    localparam logic [63:0] CSR_DBG_WOWED = 64'hE8;
    // Version 4 : violation AXI4 -- VALID retire sans READY
    localparam logic [63:0] CSR_CNT_RETR  = 64'hF0;
    localparam logic [63:0] CSR_DBG_RETR  = 64'hF8;

    //  Options de CTRL activees par la ligne de commande (voir run_sim.sh).
    //  Un seul endroit les compose : les `ifdef imbriques de la version
    //  precedente devenaient illisibles des la troisieme option, et surtout
    //  ils rendaient impossible de les combiner deux a deux -- or c'est
    //  exactement ce qu'il faut faire ici, CTRL[6] ne devant jamais etre teste
    //  sans CTRL[5].
    localparam logic [63:0] CTRL_OPTS = 64'h0
`ifdef WSKID
        | (64'h1 << 4)
`endif
`ifdef FRESH
        | (64'h1 << 5)
`endif
`ifdef TXBLOCK
        | (64'h1 << 6)
`endif
`ifdef WCAP
        | (64'h1 << 7)
`endif
`ifdef RHOLD
        | (64'h1 << 8)
`endif
        ;

    int unsigned obs_fail = 0;   // defauts trouves dans le bloc d'observabilite

    //  Valeurs des compteurs du banc au moment du CNT_CLR d'un pas de campagne,
    //  pour confronter les compteurs materiels aux deltas du banc.
    int unsigned obs_ref_badid, obs_ref_badcy;
    int unsigned obs_ref_ghost, obs_ref_orph, obs_ref_awdn;

    localparam logic [63:0] MAGIC_EXPECTED = 64'h41524D4F52000009;   // version 9 : + maintien des reponses presentees

    localparam logic [63:0] LEGIT_DST = 64'h0000_0000_9100_0000;

    // Adresse surveillee par msi_detector. Doit differer de LEGIT_DST : la
    // pointer sur la destination legitime faisait compter tout le trafic normal
    // comme MSI (defaut corrige en 8f4a25d).
    localparam logic [63:0] MSI_WATCH = 64'h0000_0000_9200_0000;

    localparam logic [23:0] ACCEL_SID = 24'd2;

    // Bits de verdict, tels que armor_sticky_q les presente dans STATUS[7:3].
    localparam int BIT_BLOCKED = 0;
    localparam int BIT_BANNED  = 1;
    localparam int BIT_STORM   = 2;
    localparam int BIT_OUTS    = 3;
    localparam int BIT_MSI     = 4;

    // -------------------------------------------------------------------------
    //  Horloge et reset
    // -------------------------------------------------------------------------
    logic clk_i  = 1'b0;
    logic rst_ni = 1'b0;

    always #5ns clk_i = ~clk_i;   // 100 MHz

    // -------------------------------------------------------------------------
    //  Knobs de l'aval, pilotes par le scenario
    // -------------------------------------------------------------------------
    int    scenario   = 1;
    logic  dn_accept  = 1'b1;   // l'aval accepte AW / W / AR
    logic  dn_respond = 1'b1;   // l'aval renvoie B / R

    //  Latence d'ACCEPTATION de l'aval : nombre de cycles pendant lesquels
    //  aw_valid / ar_valid doivent rester presentes avant que ready ne monte.
    //
    //  Ce knob n'est pas cosmetique, c'est ce qui separait le banc de la carte.
    //  A 0 (aval instantanement pret), une requete usurpee passe le handshake
    //  dans la fenetre de 2 cycles ou legit_hit est encore PERIME a 1, la faute
    //  se compte, trois fautes bannissent, et SC01 se termine proprement : c'est
    //  ce que le banc mesurait, et ce n'est pas ce que fait la carte. Le vrai
    //  IOMMU met bien plus de 2 cycles a repondre (marche de la DDT), la fenetre
    //  se referme avant le handshake, request_manager coupe aw_valid, et le mode
    //  HOLD de response_manager ne rend jamais la main -- le gel du 2026-09-08.
    //
    //  Mettre dn_lat > 2 reproduit donc la carte. C'est la configuration de
    //  reference pour tout ce qui touche au filtrage d'identifiant.
    int unsigned dn_lat = 0;

    // -------------------------------------------------------------------------
    //  Bus
    // -------------------------------------------------------------------------
    AXI_BUS #(
        .AXI_ADDR_WIDTH ( AxiAddrWidth ),
        .AXI_DATA_WIDTH ( AxiDataWidth ),
        .AXI_ID_WIDTH   ( IdWidthSlv   ),
        .AXI_USER_WIDTH ( AxiUserWidth )
    ) cfg ();

    AXI_BUS_MMU #(
        .AXI_ADDR_WIDTH ( AxiAddrWidth ),
        .AXI_DATA_WIDTH ( AxiDataWidth ),
        .AXI_ID_WIDTH   ( IdWidthDma   ),
        .AXI_USER_WIDTH ( AxiUserWidth )
    ) accel_dma ();

    logic [4:0] armor_verdict;

    // -------------------------------------------------------------------------
    //  DUT 1 : accelerateur
    // -------------------------------------------------------------------------
    accel_wrap #(
        .AXI_ADDR_WIDTH   ( AxiAddrWidth ),
        .AXI_DATA_WIDTH   ( AxiDataWidth ),
        .AXI_ID_WIDTH     ( IdWidthDma   ),
        .AXI_USER_WIDTH   ( AxiUserWidth ),
        .AXI_SLV_ID_WIDTH ( IdWidthSlv   ),
        // STREAM_ID = 2 : on joue l'accelerateur MHA, celui sur lequel la
        // campagne lance toutes les attaques. Ce choix n'est pas cosmetique --
        // SPOOF_STREAM_ID vaut 24'd1 par defaut et n'est surcharge nulle part,
        // donc le mode 1 n'usurpe reellement un identifiant que depuis un
        // accelerateur dont le STREAM_ID differe de 1.
        .STREAM_ID        ( 24'd2        ),
        .TIMEOUT_CYCLES   ( AccelTimeout )
    ) i_accel (
        .clk_i, .rst_ni,
        .testmode_i     ( 1'b0          ),
        .axi_cfg        ( cfg           ),
        .axi_dma        ( accel_dma     ),
        .armor_status_i ( armor_verdict ),
        .btnu_i         ( 1'b0          ),
        .btnd_i         ( 1'b0          ),
        .btnl_i         ( 1'b0          ),
        .btnr_i         ( 1'b0          ),
        .btnc_i         ( 1'b0          )
    );

    // -------------------------------------------------------------------------
    //  Glue interface -> structs, recopiee de ariane_peripherals_xilinx.sv
    //  (bloc accel1_dma <-> req_accel1_in / resp_accel1_in). C'est du
    //  boilerplate : le recopier plutot que le retaper.
    // -------------------------------------------------------------------------
    ariane_axi_soc::req_mmu_t  req_in;
    ariane_axi_soc::resp_slv_t resp_in;
    ariane_axi_soc::req_mmu_t  req_out;
    ariane_axi_soc::req_slv_t  req_csr;
    ariane_axi_soc::resp_slv_t resp_csr;

    // -------------------------------------------------------------------------
    //  Type de la reponse aval -- LE defaut historique.
    //
    //  wrapper.resp_wrapper_iommu_i est declare resp_slv_t (88 bits, ids sur 6
    //  bits). ariane_peripherals_xilinx.sv y raccordait un resp_t (84 bits, ids
    //  sur 4 bits) : SystemVerilog complete alors par des zeros du cote MSB, ce
    //  qui decale tous les champs.
    //
    //      aw_ready, ar_ready, w_ready, b_valid  ->  cables a 0
    //      b.id     <- {aw_ready, ar_ready, w_ready, b_valid, b.id[3:2]}
    //      r_valid  <- b.resp[0]        (0 pour OKAY comme pour SLVERR)
    //      r.data   <- r.data decale de 4 bits
    //
    //  ARMOR ne voit donc JAMAIS le moindre ready ni le moindre valid venant de
    //  l'aval, et l'accelerateur en amont non plus : aucune transaction ne peut
    //  aboutir, en lecture comme en ecriture. C'est l'explication du "zero
    //  verdict DONE" de toutes les campagnes.
    //
    //  Compiler avec -d BUG_RESP_T pour rejouer le defaut (BUG=1 ./run_sim.sh).
    // -------------------------------------------------------------------------
`ifdef BUG_RESP_T
    ariane_axi_soc::resp_t     resp_out;
`else
    ariane_axi_soc::resp_slv_t resp_out;
`endif

    assign req_in.aw_valid            = accel_dma.aw_valid;
    assign req_in.aw.id               = accel_dma.aw_id;
    assign req_in.aw.addr             = accel_dma.aw_addr;
    assign req_in.aw.len              = accel_dma.aw_len;
    assign req_in.aw.size             = accel_dma.aw_size;
    assign req_in.aw.burst            = accel_dma.aw_burst;
    assign req_in.aw.lock             = accel_dma.aw_lock;
    assign req_in.aw.cache            = accel_dma.aw_cache;
    assign req_in.aw.prot             = accel_dma.aw_prot;
    assign req_in.aw.qos              = accel_dma.aw_qos;
    assign req_in.aw.region           = accel_dma.aw_region;
    assign req_in.aw.atop             = accel_dma.aw_atop;
    assign req_in.aw.user             = accel_dma.aw_user;
    assign req_in.aw.stream_id        = accel_dma.aw_stream_id;
    assign req_in.aw.ss_id_valid      = accel_dma.aw_ss_id_valid;
    assign req_in.aw.substream_id     = accel_dma.aw_substream_id;
    assign req_in.ar_valid            = accel_dma.ar_valid;
    assign req_in.ar.id               = accel_dma.ar_id;
    assign req_in.ar.addr             = accel_dma.ar_addr;
    assign req_in.ar.len              = accel_dma.ar_len;
    assign req_in.ar.size             = accel_dma.ar_size;
    assign req_in.ar.burst            = accel_dma.ar_burst;
    assign req_in.ar.lock             = accel_dma.ar_lock;
    assign req_in.ar.cache            = accel_dma.ar_cache;
    assign req_in.ar.prot             = accel_dma.ar_prot;
    assign req_in.ar.qos              = accel_dma.ar_qos;
    assign req_in.ar.region           = accel_dma.ar_region;
    assign req_in.ar.user             = accel_dma.ar_user;
    assign req_in.ar.stream_id        = accel_dma.ar_stream_id;
    assign req_in.ar.ss_id_valid      = accel_dma.ar_ss_id_valid;
    assign req_in.ar.substream_id     = accel_dma.ar_substream_id;
    assign req_in.w_valid             = accel_dma.w_valid;
    assign req_in.w.data              = accel_dma.w_data;
    assign req_in.w.strb              = accel_dma.w_strb;
    assign req_in.w.last              = accel_dma.w_last;
    assign req_in.w.user              = accel_dma.w_user;
    assign req_in.b_ready             = accel_dma.b_ready;
    assign req_in.r_ready             = accel_dma.r_ready;

    assign accel_dma.aw_ready = resp_in.aw_ready;
    assign accel_dma.w_ready  = resp_in.w_ready;
    assign accel_dma.b_valid  = resp_in.b_valid;
    assign accel_dma.b_id     = resp_in.b.id[IdWidthDma-1:0];
    assign accel_dma.b_resp   = resp_in.b.resp;
    assign accel_dma.b_user   = resp_in.b.user;
    assign accel_dma.ar_ready = resp_in.ar_ready;
    assign accel_dma.r_valid  = resp_in.r_valid;
    assign accel_dma.r_id     = resp_in.r.id[IdWidthDma-1:0];
    assign accel_dma.r_data   = resp_in.r.data;
    assign accel_dma.r_resp   = resp_in.r.resp;
    assign accel_dma.r_last   = resp_in.r.last;
    assign accel_dma.r_user   = resp_in.r.user;

    // -------------------------------------------------------------------------
    //  DUT 2 : wrapper ARMOR
    // -------------------------------------------------------------------------
    wrapper #(
        .IdWidth            ( IdWidthDma                    ),
        .IdWidthSlv         ( IdWidthSlv                    ),
        .AddrWidth          ( AxiAddrWidth                  ),
        .UserWidth          ( AxiUserWidth                  ),
        .DevIDWidth         ( 24                            ),
        .ProcIDWidth        ( 20                            ),
        .DataWidth          ( AxiDataWidth                  ),
        .StrbWidth          ( AxiDataWidth / 8              ),
        .aw_chan_extended_t ( ariane_axi_soc::aw_chan_mmu_t ),
        .aw_chan_slv_t      ( ariane_axi_soc::aw_chan_slv_t ),
        .aw_chan_t          ( ariane_axi_soc::aw_chan_t     ),
        .w_chan_t           ( ariane_axi_soc::w_chan_t      ),
        .b_chan_t           ( ariane_axi_soc::b_chan_t      ),
        .b_chan_slv_t       ( ariane_axi_soc::b_chan_slv_t  ),
        .ar_chan_extended_t ( ariane_axi_soc::ar_chan_mmu_t ),
        .ar_chan_slv_t      ( ariane_axi_soc::ar_chan_slv_t ),
        .ar_chan_t          ( ariane_axi_soc::ar_chan_t     ),
        .r_chan_t           ( ariane_axi_soc::r_chan_t      ),
        .r_chan_slv_t       ( ariane_axi_soc::r_chan_slv_t  ),
        .req_t              ( ariane_axi_soc::req_t         ),
        .req_slv_t          ( ariane_axi_soc::req_slv_t     ),
        .resp_t             ( ariane_axi_soc::resp_t        ),
        .resp_slv_t         ( ariane_axi_soc::resp_slv_t    ),
        .req_iommu_t        ( ariane_axi_soc::req_mmu_t     )
    ) i_sec_wrap (
        .clk_i, .rst_ni,
        .req_IP_wrapper_i     ( req_in        ),
        .resp_IP_wrapper_o    ( resp_in       ),
        .resp_wrapper_iommu_i ( resp_out      ),
        .req_wrapper_iommu_o  ( req_out       ),
        .req_CPU_Wrapper__i   ( req_csr       ),
        .resp_CPU_Wrapper_o   ( resp_csr      ),
        .armor_verdict_o      ( armor_verdict )
    );

    // -------------------------------------------------------------------------
    //  Aval comportemental (tient la place de l'IOMMU + DDR)
    //
    //  Ne modelise pas la latence de l'IOMMU : seul importe ici de savoir qui
    //  cale quand l'aval ne repond pas. Les compteurs servent au rapport final.
    // -------------------------------------------------------------------------
    int unsigned aw_seen, w_seen, ar_seen, b_sent, r_sent;

    logic                            b_pending;
    logic [ariane_soc::IdWidth-1:0]  b_id_q;
    logic                            r_pending;
    logic [ariane_soc::IdWidth-1:0]  r_id_q;
    logic [7:0]                      r_left_q;

    //  Compteurs de presentation : ils repartent de zero des que le wrapper
    //  retire le valid, donc une requete coupee par ARMOR ne progresse jamais
    //  vers l'acceptation -- exactement comme l'IOMMU qui ne voit rien.
    logic [15:0] aw_wait_q, ar_wait_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_wait_q <= 16'd0;
            ar_wait_q <= 16'd0;
        end else begin
            aw_wait_q <= req_out.aw_valid ? (aw_wait_q + 16'd1) : 16'd0;
            ar_wait_q <= req_out.ar_valid ? (ar_wait_q + 16'd1) : 16'd0;
        end
    end

    // -------------------------------------------------------------------------
    //  DN_WGATE : l'aval ne prend un beat W que si un AW l'y attend.
    //
    //  CINQUIEME ANGLE MORT (2026-09-11). L'aval historique tient w_ready haut
    //  en permanence. Sur carte, ni l'IOMMU ni le crossbar ne font cela : un W
    //  n'est route qu'une fois son AW decode. Un beat W presente sans adresse
    //  y reste donc PRESENTE, indefiniment -- c'est l'etat releve sur les trois
    //  runs W_SKID=1 (`W V- last`, w_owed=0), et le banc ne pouvait pas le
    //  produire : il l'avalait aussitot comme un orphelin.
    //
    //  A 0 (defaut), comportement historique, pour rester comparable aux
    //  campagnes deja faites. Mettre DN_WGATE=1 pour reproduire la carte.
    // -------------------------------------------------------------------------
    logic        dn_wgate = 1'b0;
    int unsigned dn_w_owed;

    //  DN_WLAT : latence d'acceptation d'un beat W en aval, en cycles.
    //
    //  C'est l'ingredient qui manquait VRAIMENT. Premiere simulation avec
    //  l'etage W (WSKID=1 FRESH=1 DN_LAT=4, aval historique) : zero orphelin.
    //  L'aval prenant le beat au cycle suivant, le dernier beat quitte l'etage
    //  bien avant que l'accelerateur ne passe a l'adresse suivante, w_owed est
    //  retombe quand le W suivant arrive, et le filtre le coupe. Sur carte,
    //  ARMORSTALL mesure 40 a 45 cycles d'attente sur le canal W en aval : le
    //  beat reste dans l'etage pendant que l'ecriture suivante est coupee et
    //  que son W se presente. Mettre DN_WLAT=40 pour reproduire la carte.
    int unsigned dn_wlat = 0;
    logic [15:0] w_wait_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dn_w_owed <= 0;
            w_wait_q  <= 16'd0;
        end else begin
            automatic int unsigned nxt = dn_w_owed;
            if (req_out.aw_valid && resp_out.aw_ready)                  nxt = nxt + 1;
            if (req_out.w_valid && resp_out.w_ready && req_out.w.last
                && nxt > 0)                                             nxt = nxt - 1;
            dn_w_owed <= nxt;

            //  Repart de zero a chaque beat pris : chaque beat paie sa latence.
            w_wait_q <= (req_out.w_valid && !resp_out.w_ready) ? (w_wait_q + 16'd1)
                                                               : 16'd0;
        end
    end

    assign resp_out.aw_ready = dn_accept & ~b_pending & (aw_wait_q >= dn_lat);
    assign resp_out.w_ready  = dn_accept & (~dn_wgate | (dn_w_owed != 0))
                             & (w_wait_q >= dn_wlat);
    assign resp_out.ar_ready = dn_accept & ~r_pending & (ar_wait_q >= dn_lat);

    assign resp_out.b_valid  = b_pending & dn_respond;
    assign resp_out.b.id     = b_id_q;
    assign resp_out.b.resp   = axi_pkg::RESP_OKAY;
    assign resp_out.b.user   = '0;

    assign resp_out.r_valid  = r_pending & dn_respond;
    assign resp_out.r.id     = r_id_q;
    assign resp_out.r.data   = 64'hCAFE_BABE_DEAD_BEEF;
    assign resp_out.r.resp   = axi_pkg::RESP_OKAY;
    assign resp_out.r.last   = (r_left_q == 8'd0);
    assign resp_out.r.user   = '0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_seen <= 0; w_seen <= 0; ar_seen <= 0; b_sent <= 0; r_sent <= 0;
            b_pending <= 1'b0; b_id_q <= '0;
            r_pending <= 1'b0; r_id_q <= '0; r_left_q <= 8'd0;
        end else begin
            // Ecriture : on ne prepare le B qu'apres avoir vu le dernier beat W,
            // comme le ferait un esclave reel.
            if (req_out.aw_valid && resp_out.aw_ready) begin
                aw_seen <= aw_seen + 1;
                b_id_q  <= req_out.aw.id;
            end
            if (req_out.w_valid && resp_out.w_ready) begin
                w_seen <= w_seen + 1;
                if (req_out.w.last) b_pending <= 1'b1;
            end
            if (resp_out.b_valid && req_out.b_ready) begin
                b_pending <= 1'b0;
                b_sent    <= b_sent + 1;
            end

            // Lecture
            if (req_out.ar_valid && resp_out.ar_ready) begin
                ar_seen   <= ar_seen + 1;
                r_id_q    <= req_out.ar.id;
                r_left_q  <= req_out.ar.len;
                r_pending <= 1'b1;
            end
            if (resp_out.r_valid && req_out.r_ready) begin
                r_sent <= r_sent + 1;
                if (r_left_q == 8'd0) r_pending <= 1'b0;
                else                  r_left_q  <= r_left_q - 8'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    //  Mesure directe du surcout d'ARMOR sur le chemin requete.
    //
    //  Delai entre le moment ou l'accelerateur presente AW/AR et celui ou le
    //  wrapper le presente a l'aval. request_manager est un always_comb
    //  passe-plat, mais il coupe aw_valid/ar_valid tant que !legit_hit : le
    //  cout reel est donc le temps de montee de legit_hit, pas une profondeur
    //  de pipeline fixe.
    //
    //  Point cle : legit_hit est un NIVEAU (ids_match_reg dans id_comparator),
    //  pas une impulsion. Sur un flot de paquets au meme identifiant legitime,
    //  il reste haut et le surcout retombe a zero des la deuxieme transaction.
    // -------------------------------------------------------------------------
    int unsigned aw_delay, ar_delay;
    int unsigned n_aw_meas, n_ar_meas;

    always @(posedge clk_i) begin
        if (rst_ni) begin
            if (accel_dma.aw_valid && !req_out.aw_valid) aw_delay <= aw_delay + 1;
            if (accel_dma.ar_valid && !req_out.ar_valid) ar_delay <= ar_delay + 1;
            if (accel_dma.aw_valid && req_out.aw_valid && resp_out.aw_ready)
                n_aw_meas <= n_aw_meas + 1;
            if (accel_dma.ar_valid && req_out.ar_valid && resp_out.ar_ready)
                n_ar_meas <= n_ar_meas + 1;
        end
    end

    task automatic delay_reset();
        begin
            aw_delay = 0; ar_delay = 0; n_aw_meas = 0; n_ar_meas = 0;
        end
    endtask

    task automatic delay_report(input string what);
        begin
            $display("  %-22s AW retenus %0d cy / %0d transactions, AR retenus %0d cy / %0d",
                     what, aw_delay, n_aw_meas, ar_delay, n_ar_meas);
        end
    endtask

    // -------------------------------------------------------------------------
    //  Maitre AXI sur le port de configuration de l'accelerateur (interface)
    //
    //  Chaque tache est bornee par un garde-fou : sans lui, un handshake perdu
    //  fige la simulation exactement comme il fige le CPU -- ce qu'on veut
    //  constater et nommer, pas subir.
    // -------------------------------------------------------------------------
    localparam int unsigned MMIO_GUARD = 500;   // cycles

    logic cfg_timeout;   // leve des qu'un acces MMIO n'aboutit pas

    task automatic cfg_reset();
        cfg.aw_id     <= '0;  cfg.aw_addr  <= '0;  cfg.aw_len    <= 8'd0;
        cfg.aw_size   <= 3'd3; cfg.aw_burst <= axi_pkg::BURST_INCR;
        cfg.aw_lock   <= 1'b0; cfg.aw_cache <= '0;  cfg.aw_prot   <= '0;
        cfg.aw_qos    <= '0;  cfg.aw_region<= '0;  cfg.aw_atop   <= '0;
        cfg.aw_user   <= '0;  cfg.aw_valid <= 1'b0;
        cfg.w_data    <= '0;  cfg.w_strb   <= '1;  cfg.w_last    <= 1'b1;
        cfg.w_user    <= '0;  cfg.w_valid  <= 1'b0;
        cfg.b_ready   <= 1'b0;
        cfg.ar_id     <= '0;  cfg.ar_addr  <= '0;  cfg.ar_len    <= 8'd0;
        cfg.ar_size   <= 3'd3; cfg.ar_burst <= axi_pkg::BURST_INCR;
        cfg.ar_lock   <= 1'b0; cfg.ar_cache <= '0;  cfg.ar_prot   <= '0;
        cfg.ar_qos    <= '0;  cfg.ar_region<= '0;  cfg.ar_user   <= '0;
        cfg.ar_valid  <= 1'b0;
        cfg.r_ready   <= 1'b0;
    endtask

    // Attend `sig` haut au front montant, au plus MMIO_GUARD cycles.
    // `ok` retombe si le garde-fou expire -- c'est la signature du gel.
    task automatic wait_hs(ref logic sig, input string what, output bit ok);
        int unsigned n;
        begin
            n  = 0;
            ok = 1'b1;
            while (!sig) begin
                @(posedge clk_i);
                n = n + 1;
                if (n > MMIO_GUARD) begin
                    $display("[%0t] *** GEL MMIO : %s toujours bas apres %0d cycles",
                             $time, what, MMIO_GUARD);
                    ok = 1'b0;
                    return;
                end
            end
        end
    endtask

    task automatic acc_write(input logic [63:0] addr, input logic [63:0] data);
        bit ok;
        begin
            @(posedge clk_i);
            cfg.aw_addr  <= addr;
            cfg.aw_id    <= 6'h1;
            cfg.aw_valid <= 1'b1;
            wait_hs(cfg.aw_ready, $sformatf("acc_write AW @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            @(posedge clk_i);
            cfg.aw_valid <= 1'b0;
            cfg.w_data   <= data;
            cfg.w_last   <= 1'b1;
            cfg.w_valid  <= 1'b1;
            wait_hs(cfg.w_ready, $sformatf("acc_write W @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            @(posedge clk_i);
            cfg.w_valid  <= 1'b0;
            cfg.b_ready  <= 1'b1;
            wait_hs(cfg.b_valid, $sformatf("acc_write B @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            @(posedge clk_i);
            cfg.b_ready  <= 1'b0;
        end
    endtask

    task automatic acc_read(input logic [63:0] addr, output logic [63:0] data);
        bit ok;
        begin
            data = 64'hX;
            @(posedge clk_i);
            cfg.ar_addr  <= addr;
            cfg.ar_id    <= 6'h1;
            cfg.ar_len   <= 8'd0;
            cfg.ar_valid <= 1'b1;
            wait_hs(cfg.ar_ready, $sformatf("acc_read AR @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            @(posedge clk_i);
            cfg.ar_valid <= 1'b0;
            cfg.r_ready  <= 1'b1;
            wait_hs(cfg.r_valid, $sformatf("acc_read R @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            data = cfg.r_data;
            @(posedge clk_i);
            cfg.r_ready  <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    //  Maitre AXI sur le port CSR du wrapper (structs, pas d'interface)
    // -------------------------------------------------------------------------
    task automatic csr_reset();
        req_csr <= '0;
        req_csr.aw.size  <= 3'd3;
        req_csr.aw.burst <= axi_pkg::BURST_INCR;
        req_csr.ar.size  <= 3'd3;
        req_csr.ar.burst <= axi_pkg::BURST_INCR;
        req_csr.w.strb   <= '1;
        req_csr.w.last   <= 1'b1;
    endtask

    task automatic csr_write(input logic [63:0] addr, input logic [63:0] data);
        bit ok;
        begin
            @(posedge clk_i);
            req_csr.aw.addr  <= addr;
            req_csr.aw.id    <= 6'h2;
            req_csr.aw_valid <= 1'b1;
            wait_hs(resp_csr.aw_ready, $sformatf("csr_write AW @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            @(posedge clk_i);
            req_csr.aw_valid <= 1'b0;
            req_csr.w.data   <= data;
            req_csr.w.last   <= 1'b1;
            req_csr.w_valid  <= 1'b1;
            wait_hs(resp_csr.w_ready, $sformatf("csr_write W @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            @(posedge clk_i);
            req_csr.w_valid <= 1'b0;
            req_csr.b_ready <= 1'b1;
            wait_hs(resp_csr.b_valid, $sformatf("csr_write B @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            @(posedge clk_i);
            req_csr.b_ready <= 1'b0;
        end
    endtask

    task automatic csr_read(input logic [63:0] addr, output logic [63:0] data);
        bit ok;
        begin
            data = 64'hX;
            @(posedge clk_i);
            req_csr.ar.addr  <= addr;
            req_csr.ar.id    <= 6'h2;
            req_csr.ar.len   <= 8'd0;
            req_csr.ar_valid <= 1'b1;
            wait_hs(resp_csr.ar_ready, $sformatf("csr_read AR @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            @(posedge clk_i);
            req_csr.ar_valid <= 1'b0;
            req_csr.r_ready  <= 1'b1;
            wait_hs(resp_csr.r_valid, $sformatf("csr_read R @0x%02h", addr), ok);
            if (!ok) begin cfg_timeout <= 1'b1; return; end
            data = resp_csr.r.data;
            @(posedge clk_i);
            req_csr.r_ready <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    //  Observation des etats internes (noms tels quels dans le RTL)
    // -------------------------------------------------------------------------
    function automatic string accel_state_str();
        return $sformatf("cw=%0d cr=%0d busy=%0b done=%0b err=%0b",
                         i_accel.cw_state_q, i_accel.cr_state_q,
                         i_accel.busy_q, i_accel.done_q, i_accel.error_q);
    endfunction

    function automatic string wrapper_state_str();
        return $sformatf("w=%0d r=%0d", i_sec_wrap.w_state_q, i_sec_wrap.r_state_q);
    endfunction

    // -------------------------------------------------------------------------
    //  Scenario
    // -------------------------------------------------------------------------
    logic [63:0] rd;
    logic [63:0] status;
    int unsigned poll;
    bit          saw_done;
    bit          saw_busy;
    bit          saw_error;

    initial begin
        if (!$value$plusargs("SCENARIO=%d", scenario)) scenario = 1;
        // +DN_LAT=<n> : latence d'acceptation de l'aval, en cycles. Defaut 0
        // (aval instantane, comportement historique du banc). Mettre > 2 pour
        // reproduire un IOMMU reel -- voir le commentaire de dn_lat.
        if (!$value$plusargs("DN_LAT=%d", dn_lat)) dn_lat = 0;
        // +DN_WGATE : l'aval ne prend un W que si un AW l'y attend (carte).
        dn_wgate = $test$plusargs("DN_WGATE") ? 1'b1 : 1'b0;
        // +DN_WLAT=<n> : latence d'acceptation d'un beat W (carte : 40 a 45).
        if (!$value$plusargs("DN_WLAT=%d", dn_wlat)) dn_wlat = 0;
        $display(" aval W : %s, latence %0d cycle(s)", dn_wgate
                 ? "conditionne a un AW (DN_WGATE, comme la carte)"
                 : "w_ready toujours haut (historique -- avale un W sans adresse)",
                 dn_wlat);

        case (scenario)
            0: begin dn_accept = 1'b1; dn_respond = 1'b1; end
            1: begin dn_accept = 1'b1; dn_respond = 1'b0; end
            2: begin dn_accept = 1'b0; dn_respond = 1'b0; end
            3: begin dn_accept = 1'b1; dn_respond = 1'b1; end   // campagne
            default: begin
                $display("SCENARIO=%0d inconnu (0, 1, 2 ou 3)", scenario);
                $finish;
            end
        endcase

        $display("=======================================================");
        $display(" tb_accel_armor -- SCENARIO %0d  (dn_lat = %0d cycles)",
                 scenario, dn_lat);
        $display("   aval : accepte AW/AR = %0b, renvoie B/R = %0b",
                 dn_accept, dn_respond);
        $display("   accel TIMEOUT_CYCLES = %0d, garde-fou MMIO = %0d cycles",
                 AccelTimeout, MMIO_GUARD);
        $display("=======================================================");

        cfg_timeout = 1'b0;
        saw_done    = 1'b0;
        saw_busy    = 1'b0;
        saw_error   = 1'b0;
        cfg_reset();
        csr_reset();

        repeat (10) @(posedge clk_i);
        rst_ni = 1'b1;
        repeat (10) @(posedge clk_i);

        // ---------------------------------------------------------------------
        //  1. Le CPU lit MAGIC avant tout trafic. Si meme ceci echoue, le
        //     probleme n'est pas dans le DMA.
        // ---------------------------------------------------------------------
        csr_read(CSR_MAGIC, rd);
        if (cfg_timeout) begin
            $display("[%0t] ECHEC : MAGIC illisible sur un bus vierge", $time);
            report_and_finish();
        end
        $display("[%0t] MAGIC = 0x%016h (%s)", $time, rd,
                 (rd == MAGIC_EXPECTED) ? "OK" : "INATTENDU");

        if (scenario == 3) run_campaign();   // ne revient pas

        // ID_CFG = STREAM_ID de l'accelerateur, sinon le comparateur d'ID voit
        // un spoof sur du trafic parfaitement legitime.
        csr_write(CSR_ID_CFG, {40'h0, ACCEL_SID});
        // ENFORCE = 0 : on veut mesurer le datapath, pas le filtrage. ARMOR a
        // deja ete mis hors de cause (run -DARMOR_ENFORCE=0 sur carte).
        csr_write(CSR_CTRL, 64'd0);

        // ---------------------------------------------------------------------
        //  2. Programmation de l'accelerateur, puis start
        // ---------------------------------------------------------------------
        acc_write(ACC_BASE, LEGIT_DST);
        acc_write(ACC_SIZE, 64'd64);
        acc_write(ACC_CONF, 64'd1);      // cfg=1 -> lecture (cf. bench_runner.c)
        acc_write(ACC_MODE, 64'd0);      // trafic legitime
        if (cfg_timeout) begin
            $display("[%0t] ECHEC : programmation impossible avant meme le start",
                     $time);
            report_and_finish();
        end

        $display("[%0t] avant start : %s", $time, accel_state_str());
        acc_write(ACC_CTRL, 64'd1);
        if (cfg_timeout) begin
            $display("[%0t] ECHEC : l'ecriture de CTRL n'a pas abouti", $time);
            report_and_finish();
        end
        $display("[%0t] start emis : %s", $time, accel_state_str());

        // ---------------------------------------------------------------------
        //  3. Polling de STATUS pendant que le DMA tourne (ou cale).
        //     C'est LA question du banc : le port de config repond-il encore ?
        // ---------------------------------------------------------------------
        for (poll = 0; poll < 40; poll++) begin
            acc_read(ACC_STATUS, status);
            if (cfg_timeout) begin
                $display("[%0t] *** LE PORT DE CONFIG S'EST VERROUILLE au polling %0d",
                         $time, poll);
                $display("      accel   : %s", accel_state_str());
                $display("      wrapper : %s", wrapper_state_str());
                $display("      aval    : aw=%0d w=%0d ar=%0d b=%0d r=%0d",
                         aw_seen, w_seen, ar_seen, b_sent, r_sent);
                report_and_finish();
            end

            if (status[0]) saw_busy = 1'b1;
            if (status[1]) saw_done  = 1'b1;
            if (status[2]) saw_error = 1'b1;

            $display("[%0t] poll %0d : STATUS=0x%016h busy=%0b done=%0b err=%0b armor=0x%02h | aval aw=%0d w=%0d ar=%0d b=%0d r=%0d",
                     $time, poll, status, status[0], status[1], status[2],
                     status[7:3], aw_seen, w_seen, ar_seen, b_sent, r_sent);

            if (status[1] || status[2]) break;   // DONE ou ERROR : termine
            repeat (100) @(posedge clk_i);
        end

        // ---------------------------------------------------------------------
        //  4. Le CPU relit MAGIC apres coup : le port CSR du wrapper a-t-il
        //     survecu au blocage du DMA ?
        // ---------------------------------------------------------------------
        csr_read(CSR_MAGIC, rd);
        if (cfg_timeout)
            $display("[%0t] *** LE PORT CSR DU WRAPPER S'EST VERROUILLE", $time);
        else
            $display("[%0t] MAGIC relu = 0x%016h (%s)", $time, rd,
                     (rd == MAGIC_EXPECTED) ? "OK" : "INATTENDU");

        csr_read(CSR_STATUS, rd);
        if (!cfg_timeout) $display("[%0t] ARMOR STATUS = 0x%016h", $time, rd);

        check_observability();

        report_and_finish();
    end

    // -------------------------------------------------------------------------
    //  Campagne (scenario 3) : un pas par scenario de bench_runner.c
    //
    //  Chaque pas remet les bits collants a zero, programme l'accelerateur,
    //  lance, puis attend la retombee de busy_q. La latence est mesuree sur ce
    //  signal interne plutot que par sondage MMIO : le sondage a une granularite
    //  de 100 cycles, sans rapport avec ce qu'on veut comparer aux ~1450 cycles
    //  de l'implementation de reference.
    // -------------------------------------------------------------------------
    int unsigned n_pass, n_fail;
    int unsigned last_cycles;
    int unsigned cy_off_r, cy_on_r, cy_off_w, cy_on_w;

    // -------------------------------------------------------------------------
    //  Moniteur du DÉSÉQUILIBRE AW / W en aval — la condition du gel sur carte.
    //
    //  Un AW accepté par l'aval engage le maître à fournir ses beats W. Si ARMOR
    //  termine la transaction côté maître par un SLVERR après coup, ces W ne
    //  viennent jamais : il reste en aval une écriture acceptée qui attend ses
    //  données pour toujours, et le canal d'écriture du crossbar se coince.
    //  C'est le mécanisme proposé pour le gel de SC01 puis SC02 sur carte.
    //
    //  aw_owed compte les AW acceptés en aval dont le dernier W n'est pas encore
    //  passé. Il doit revenir à zéro à la fin de chaque scénario.
    // -------------------------------------------------------------------------
    int unsigned aw_owed, aw_owed_max;

    // -------------------------------------------------------------------------
    //  Moniteur du W ORPHELIN — le MIROIR de aw_owed, et l'angle mort du banc.
    //
    //  aw_owed surveille « AW accepte, W jamais fourni ». Le defaut symetrique
    //  n'etait pas observe : un beat W accepte en aval alors qu'AUCUN AW ne l'a
    //  precede. request_manager coupe aw_valid tant que le verdict n'est pas
    //  rendu, mais ne coupe PAS w_valid ; un aval qui tient w_ready haut (c'est
    //  le cas ici, resp_out.w_ready = dn_accept, comme un crossbar reel qui
    //  bufferise) avale donc les donnees d'une ecriture dont il ne verra jamais
    //  l'adresse. Le canal W du crossbar est des lors decale d'un beat pour
    //  toujours : le premier acces CPU empruntant ce chemin ne revient pas.
    //
    //  w_excess_tot les compte. L'ecart sur un pas de campagne doit rester nul :
    //  toute valeur non nulle est la signature du gel observe sur carte.
    // -------------------------------------------------------------------------
    //  Sondes hierarchiques sur les signaux internes du wrapper, pour que la
    //  detection de beat fantome dise DANS QUEL MODE response_manager se
    //  trouvait -- c'est ce qui distingue le HOLD du blocage.
    wire i_wrapper_block_ip   = i_sec_wrap.block_ip_eff;
    wire i_wrapper_block_req  = i_sec_wrap.block_req_i;
    wire i_wrapper_bad_id     = i_sec_wrap.bad_id;
    wire i_wrapper_legit      = i_sec_wrap.legit_hit_eff;
    wire i_wrapper_vk         = i_sec_wrap.verdict_known_eff;
    wire i_wrapper_w_pending  = i_sec_wrap.w_pending;

    int unsigned w_excess_tot;
    int unsigned w_ghost_tot;    // beats W pris en aval sans que le maitre le sache
    time         w_ghost_first;

    //  bad_id n'apparait NI dans armor_status, NI dans STICKY, NI dans
    //  cyc_block (qui compte block_req_i, lequel l'exclut), NI dans cyc_hold
    //  (qui l'exclut explicitement). C'est le seul mecanisme gate par ENFORCE
    //  qui ne laisse aucune trace lisible par le logiciel. On le compte ici.
    int unsigned bad_id_cy;      // cycles ou bad_id est haut
    int unsigned bad_id_rise;    // fronts montants
    logic        bad_id_d;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_owed       <= 0;
            aw_owed_max   <= 0;
            w_excess_tot  <= 0;
            w_ghost_tot   <= 0;
            w_ghost_first <= 0;
            bad_id_cy     <= 0;
            bad_id_rise   <= 0;
            bad_id_d      <= 1'b0;
        end else begin
            automatic int unsigned nxt = aw_owed;
            automatic bit aw_hs = req_out.aw_valid && resp_out.aw_ready;
            automatic bit w_hs  = req_out.w_valid  && resp_out.w_ready;
            if (aw_hs)                                              nxt = nxt + 1;
            if (w_hs && req_out.w.last && nxt > 0)                  nxt = nxt - 1;
            aw_owed <= nxt;
            if (nxt > aw_owed_max) aw_owed_max <= nxt;

            // Un beat W accepte alors qu'aucun AW n'est en attente de donnees
            // (et qu'aucun n'arrive dans le meme cycle) est un orphelin.
            if (w_hs && aw_owed == 0 && !aw_hs)
                w_excess_tot <= w_excess_tot + 1;

            // -----------------------------------------------------------------
            //  BEAT W FANTOME  (hypothese du gel, 2026-09-10)
            //
            //  L'aval PREND le beat (w_valid & w_ready cote aval) alors que le
            //  maitre n'en est PAS informe (w_ready retire cote maitre). Le
            //  maitre croit son beat refuse et le represente : l'aval en recoit
            //  deux. Le canal W est decale d'un beat, definitivement.
            //
            //  D'ou ca vient. En mode HOLD, response_manager sort '0 sur TOUT,
            //  donc w_ready = 0 vers le maitre. Mais request_manager ne coupe
            //  w_valid que si `!w_pending` : avec un AW deja admis en aval,
            //  w_valid TRAVERSE pendant que w_ready est retire. La branche
            //  passe-plat de response_manager traite ce piege explicitement
            //  (« le laisser traverser ferait croire au maitre que son beat est
            //  parti alors qu'on vient de le retenir ») -- la branche HOLD a le
            //  trou symetrique.
            //
            //  Pourquoi ce compteur et pas w_excess_tot : un beat DUPLIQUE n'est
            //  pas un orphelin. Il a bien son AW ; il est juste compte deux fois
            //  en aval. aw_owed etant garde a zero, il l'absorbe en silence --
            //  c'est ce qui rend le defaut invisible aux compteurs materiels.
            //
            //  Ce compteur DOIT rester a zero. Toute valeur non nulle prouve le
            //  mecanisme.
            // -----------------------------------------------------------------
            bad_id_d <= i_wrapper_bad_id;
            if (i_wrapper_bad_id) begin
                bad_id_cy <= bad_id_cy + 1;
                if (!bad_id_d) bad_id_rise <= bad_id_rise + 1;
            end

            //  Sans objet sous l'etage W : handshakes aval et maitre y sont
            //  decouples par construction (voir dn_w_ghost dans wrapper.sv).
            //  L'appariement adresse/donnee est le controle qui fait foi.
            if (w_hs && !resp_in.w_ready && !i_sec_wrap.csr_wskid_q) begin
                w_ghost_tot <= w_ghost_tot + 1;
                if (w_ghost_tot == 0) begin
                    w_ghost_first <= $time;
                    $display("[%0t] *** BEAT W FANTOME : l'aval prend le beat, le maitre ne le sait pas",
                             $time);
                    $display("           block_ip=%0b block_req=%0b bad_id=%0b legit=%0b vk=%0b w_pending=%0b",
                             i_wrapper_block_ip, i_wrapper_block_req,
                             i_wrapper_bad_id, i_wrapper_legit, i_wrapper_vk,
                             i_wrapper_w_pending);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    //  APPARIEMENT ADRESSE / DONNEES EN AVAL  (2026-09-11)
    //
    //  Tous les compteurs precedents verifient un EQUILIBRE : autant de W-last
    //  que d'AW en aval, pas de beat sans adresse, pas de beat duplique. Aucun
    //  ne verifie qu'un beat arrive avec SA PROPRE adresse. Or c'est ce que
    //  l'etage W semble casser sur carte : un beat d'une ecriture COUPEE reste
    //  presente en aval, part avec l'AW legitime suivant, et le vrai beat de
    //  celui-ci se fait coincer a son tour. Le solde AW/W-last reste juste --
    //  tout est decale d'un cran, rien n'est en trop.
    //
    //  Ce controle n'a besoin d'aucun CSR, donc ne perturbe pas la campagne
    //  (contrairement a OBS_CHECK). Il repose sur deux faits de accel_wrap :
    //    - le maitre emet ses beats W juste APRES l'acquittement de son AW
    //      (G_AW -> G_W), donc un beat appartient au dernier AW acquitte ;
    //    - wdata_q s'incremente a chaque beat acquitte : chaque beat a une
    //      valeur unique, et le k-ieme beat d'une adresse vaut premier + k.
    //
    //  Chaque AW admis en aval est rattache a l'AW du maitre dont il provient ;
    //  chaque beat pris en aval doit alors porter la valeur que le maitre a
    //  emise pour l'AW admis le plus ancien. Toute autre valeur est un decalage.
    // -------------------------------------------------------------------------
    localparam int SB_N = 65536;
    logic [63:0] sb_first [SB_N];   // valeur du premier beat emis pour l'AW n
    bit          sb_seen  [SB_N];   // le maitre a emis au moins un beat pour n
    bit          sb_adm   [SB_N];   // l'AW n a ete admis en aval
    int          sb_dn_q  [$];      // AW admis en aval, dans l'ordre, par index maitre
    int unsigned sb_up_n;           // AW acquittes au maitre
    int          sb_cur_up = -1;    // AW dont le maitre emet les beats
    int unsigned sb_up_beat, sb_dn_beat;

    int unsigned pair_ok;           // beats pris en aval avec la bonne donnee
    int unsigned pair_bad;          // beats pris en aval avec la donnee d'une autre ecriture
    int unsigned pair_noaw;         // beats pris en aval sans aucun AW admis
    int unsigned pair_nodata;       // beats pris pour un AW dont le maitre n'a rien emis
    int unsigned pair_aw_orphan;    // AW admis en aval sans adresse du maitre
    int unsigned pair_dup;          // AW du maitre admis deux fois en aval
    bit          pair_shown;

    always @(posedge clk_i) begin
        if (rst_ni) begin
            automatic bit up_aw = req_in.aw_valid  && resp_in.aw_ready;
            automatic bit dn_aw = req_out.aw_valid && resp_out.aw_ready;
            automatic bit up_w  = req_in.w_valid   && resp_in.w_ready;
            automatic bit dn_w  = req_out.w_valid  && resp_out.w_ready;
            automatic int idx;

            //  1. Admission en aval : de quelle adresse du maitre s'agit-il ?
            //     Acquittee dans ce cycle ou encore presentee -> la courante ;
            //     acquittee plus tot (ready fabrique) puis admise en differe ->
            //     la precedente.
            if (dn_aw) begin
                if (up_aw || req_in.aw_valid) idx = sb_up_n;
                else if (sb_up_n > 0)         idx = sb_up_n - 1;
                else                          idx = -1;
                if (idx >= SB_N) idx = -1;
                if (idx < 0) begin
                    pair_aw_orphan++;
                end else begin
                    if (sb_adm[idx]) pair_dup++;
                    sb_adm[idx] = 1'b1;
                end
                sb_dn_q.push_back(idx);
            end

            //  2. Cote maitre : l'AW acquitte, puis ses beats, dans cet ordre.
            //     Traite AVANT l'aval : sans etage W, un beat traverse dans le
            //     meme cycle.
            if (up_aw) begin
                sb_cur_up  = sb_up_n;
                sb_up_n++;
                sb_up_beat = 0;
            end
            if (up_w && sb_cur_up >= 0 && sb_cur_up < SB_N) begin
                if (sb_up_beat == 0) begin
                    sb_first[sb_cur_up] = req_in.w.data;
                    sb_seen[sb_cur_up]  = 1'b1;
                end
                sb_up_beat = req_in.w.last ? 0 : sb_up_beat + 1;
            end

            //  3. Cote aval : le beat doit etre celui de l'AW admis le plus ancien.
            if (dn_w) begin
                automatic logic [63:0] exp_d = '0;
                automatic string       why   = "";
                if (sb_dn_q.size() == 0) begin
                    pair_noaw++;
                    why = "beat pris en aval alors qu'aucun AW n'y est admis";
                end else begin
                    idx = sb_dn_q[0];
                    if (idx < 0) begin
                        pair_bad++;
                        why = "beat d'un AW admis sans adresse du maitre";
                    end else if (!sb_seen[idx]) begin
                        pair_nodata++;
                        why = $sformatf("le maitre n'a emis aucun beat pour l'AW %0d", idx);
                    end else begin
                        exp_d = sb_first[idx] + sb_dn_beat;
                        if (req_out.w.data == exp_d) begin
                            pair_ok++;
                        end else begin
                            pair_bad++;
                            why = $sformatf("AW %0d attendait 0x%0h, recoit 0x%0h (ecart %0d beat(s))",
                                            idx, exp_d, req_out.w.data,
                                            $signed(req_out.w.data - exp_d));
                        end
                    end
                    sb_dn_beat = req_out.w.last ? 0 : sb_dn_beat + 1;
                    if (req_out.w.last) void'(sb_dn_q.pop_front());
                end

                if (why != "" && !pair_shown) begin
                    pair_shown = 1'b1;
                    $display("[%0t] *** APPARIEMENT W ROMPU : %s", $time, why);
                    $display("           aval : AW admis en file=%0d | wrapper : w_owed=%0d w_pending=%0b etage_plein=%0b block_req=%0b vk=%0b",
                             sb_dn_q.size(), i_sec_wrap.w_owed_q, i_sec_wrap.w_pending,
                             i_sec_wrap.i_w_skid.full_q, i_sec_wrap.block_req_i,
                             i_sec_wrap.verdict_known_eff);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    //  REPONSES PERDUES  (2026-09-11)
    //
    //  Une reponse B/R prise EN AVAL alors que le maitre ne voyait AUCUN valid :
    //  elle a ete consommee par le ready du maitre, transmis a l'aval, sans que le
    //  maitre la recoive. C'est ce que produisait la branche d'attente de
    //  response_manager, qui masquait les reponses de l'aval sans masquer le
    //  ready.
    //
    //  Le drainage anti-wedge (block_req ou bad_id : b_ready/r_ready forces a 1
    //  vers l'aval) avale des reponses A DESSEIN ; il est exclu du compte.
    // -------------------------------------------------------------------------
    int unsigned resp_lost_b, resp_lost_r;
    bit          resp_lost_shown;

    always @(posedge clk_i) begin
        if (rst_ni) begin
            automatic bit drain = i_sec_wrap.block_req_i || i_sec_wrap.bad_id;
            automatic bit lb = resp_out.b_valid && req_out.b_ready && !resp_in.b_valid && !drain;
            automatic bit lr = resp_out.r_valid && req_out.r_ready && !resp_in.r_valid && !drain;
            if (lb) resp_lost_b++;
            if (lr) resp_lost_r++;
            if ((lb || lr) && !resp_lost_shown) begin
                resp_lost_shown = 1'b1;
                $display("[%0t] *** REPONSE PERDUE : %s pris en aval, le maitre n'a vu aucun valid | legit=%0b vk=%0b block_ip=%0b",
                         $time, lb ? "B" : "R", i_sec_wrap.legit_hit_eff,
                         i_sec_wrap.verdict_known_eff, i_sec_wrap.block_ip_eff);
            end
        end
    end

    // -------------------------------------------------------------------------
    //  INSTRUMENTATION SC02 — la forme reelle de block_req en profil BENCH.
    //
    //  FLOW_BLOCK_CYCLES_C vaut 4 en BENCH contre 750_000_000 en DEMO. Or
    //  request_flow_monitor ne redemarre son blocage que sur `storm_flag &&
    //  !blocking`, et storm_flag est un NIVEAU tenu jusqu'a la fin de la fenetre
    //  (req_cnt ne retombe qu'a window_cnt == WINDOW_CYCLES-1, soit 100 cycles).
    //  block_req ne dure donc pas 4 cycles : il OSCILLE, 4 cycles haut / 1 cycle
    //  bas, pendant tout le reste de la fenetre.
    //
    //  Ce hachage est le regime que ni le RTL ni le banc n'ont examine. Pendant
    //  un creux, aw_valid repasse en aval et l'aval peut admettre un AW ; au
    //  cycle suivant block_req remonte, response_manager fabrique un SLVERR vers
    //  le maitre, celui-ci considere son ecriture finie et n'enverra jamais ses
    //  beats W -- il reste en aval un AW admis qui attend ses donnees pour
    //  toujours. C'est le mecanisme aw_owed, jamais observe jusqu'ici parce
    //  qu'on ne le mesurait qu'en FIN de scenario, une fois le mal fait et le
    //  compteur eventuellement revenu a zero.
    // -------------------------------------------------------------------------
    logic blk_q;
    int unsigned blk_rise, blk_hi_cy, blk_lo_cy;
    int unsigned danger_cy;      // block_req haut ALORS QU'un AW est du en aval
    int unsigned aw_adm_while_storm;  // AW admis pendant une fenetre de storm

    wire blk_now   = tb_accel_armor.i_sec_wrap.block_req_i;
    wire storm_now = tb_accel_armor.i_sec_wrap.storm_flag;

    // --- Instrumentation SC03 : pourquoi le bit OUTS ne se leve-t-il pas ? ---
    wire outs_ovf_now = tb_accel_armor.i_sec_wrap.overflow_flag_outs;
    wire outs_blk_now = tb_accel_armor.i_sec_wrap.block_req_outs;
    wire req_fire_now = tb_accel_armor.i_sec_wrap.req_fire_signal;
    wire [31:0] outs_cnt_now = tb_accel_armor.i_sec_wrap.outs_monitor_inst.outstanding;

    logic outs_ovf_q, outs_blk_q;
    int unsigned outs_max, ovf_rise, oblk_rise, fire_cnt, respc_cnt;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            outs_ovf_q <= 0; outs_blk_q <= 0;
            outs_max <= 0; ovf_rise <= 0; oblk_rise <= 0;
            fire_cnt <= 0; respc_cnt <= 0;
        end else begin
            outs_ovf_q <= outs_ovf_now;  outs_blk_q <= outs_blk_now;
            if (outs_cnt_now > outs_max)            outs_max  <= outs_cnt_now;
            if (outs_ovf_now && !outs_ovf_q)        ovf_rise  <= ovf_rise + 1;
            if (outs_blk_now && !outs_blk_q)        oblk_rise <= oblk_rise + 1;
            if (req_fire_now)                       fire_cnt  <= fire_cnt + 1;
            if (tb_accel_armor.i_sec_wrap.outs_monitor_inst.resp_complete)
                                                    respc_cnt <= respc_cnt + 1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            blk_q <= 1'b0; blk_rise <= 0; blk_hi_cy <= 0; blk_lo_cy <= 0;
            danger_cy <= 0; aw_adm_while_storm <= 0;
        end else begin
            blk_q <= blk_now;
            if (blk_now && !blk_q) blk_rise  <= blk_rise + 1;
            if (blk_now)           blk_hi_cy <= blk_hi_cy + 1;
            if (!blk_now && storm_now) blk_lo_cy <= blk_lo_cy + 1;  // creux
            if (blk_now && aw_owed != 0) danger_cy <= danger_cy + 1;
            if (storm_now && req_out.aw_valid && resp_out.aw_ready)
                aw_adm_while_storm <= aw_adm_while_storm + 1;
        end
    end

    //  Rapport d'appariement par pas : ecarts depuis le rapport precedent.
    //
    //  Imprime AUSSI quand tout est juste, avec le nombre de beats verifies. Le
    //  banc a deja valide du vide quatre fois : un controle muet quand il n'y a
    //  rien a signaler ne se distingue pas d'un controle qui ne voit rien passer.
    int unsigned pair_ok_0, pair_bad_0, pair_noaw_0, pair_nodata_0, pair_orph_0, pair_dup_0;
    int unsigned lost_b_0, lost_r_0;

    task automatic pair_step_report(input string name);
        int unsigned d_ok, d_bad, d_noaw, d_nodata, d_orph, d_dup;
        begin
            d_ok     = pair_ok        - pair_ok_0;
            d_bad    = pair_bad       - pair_bad_0;
            d_noaw   = pair_noaw      - pair_noaw_0;
            d_nodata = pair_nodata    - pair_nodata_0;
            d_orph   = pair_aw_orphan - pair_orph_0;
            d_dup    = pair_dup       - pair_dup_0;

            if (d_bad != 0 || d_noaw != 0 || d_nodata != 0 || d_orph != 0 || d_dup != 0)
                $display("  %-12s  !! APPARIEMENT W : %0d beat(s) avec la donnee d'une AUTRE ecriture, %0d sans AW, %0d pour un AW sans donnee | AW sans adresse maitre %0d, admis deux fois %0d | %0d correct(s)",
                         name, d_bad, d_noaw, d_nodata, d_orph, d_dup, d_ok);
            else if (d_ok != 0)
                $display("  %-12s  appariement W : %0d beat(s) verifie(s), tous avec leur adresse",
                         name, d_ok);

            //  Reponses perdues : meme logique d'ecart depuis le rapport
            //  precedent, pour savoir QUEL pas les produit.
            if (resp_lost_b != lost_b_0 || resp_lost_r != lost_r_0)
                $display("  %-12s  !! REPONSES PERDUES : B=%0d R=%0d (prises en aval, jamais vues du maitre)",
                         name, resp_lost_b - lost_b_0, resp_lost_r - lost_r_0);
            lost_b_0 = resp_lost_b;
            lost_r_0 = resp_lost_r;

            pair_ok_0     = pair_ok;
            pair_bad_0    = pair_bad;
            pair_noaw_0   = pair_noaw;
            pair_nodata_0 = pair_nodata;
            pair_orph_0   = pair_aw_orphan;
            pair_dup_0    = pair_dup;
        end
    endtask

    task automatic campaign_step(input string       name,
                                 input logic  [2:0] mode,
                                 input logic        is_read,
                                 input logic  [4:0] expect_bits,
                                 input bit          expect_clean,
                                 input int unsigned iters,
                                 input logic        enforce);
        logic [63:0] st, fails;
        time         t0;
        int unsigned cycles, cycles_tot;
        int unsigned guard;
        int unsigned n_err;
        logic [4:0]  got, acc_bits;
        bit          ok;
        int unsigned k;
        int unsigned w_excess_0;
        int unsigned w_ghost_0;
        int unsigned bad_id_rise_0, bad_id_cy_0;
        int unsigned aw_seen_0;
        int unsigned blk_rise_0, blk_hi_0, blk_lo_0, danger_0, aw_adm_0;
        int unsigned outs_max_0, ovf_0, oblk_0, fire_0, respc_0;
        begin
            w_excess_0 = w_excess_tot;
            w_ghost_0  = w_ghost_tot;
            bad_id_rise_0 = bad_id_rise;
            bad_id_cy_0   = bad_id_cy;
            aw_seen_0     = aw_seen;
            obs_ref_badid = bad_id_rise;
            obs_ref_badcy = bad_id_cy;
            obs_ref_ghost = w_ghost_tot;
            obs_ref_orph  = w_excess_tot;
            obs_ref_awdn  = aw_seen;
            blk_rise_0 = blk_rise;  blk_hi_0 = blk_hi_cy;  blk_lo_0 = blk_lo_cy;
            danger_0   = danger_cy; aw_adm_0 = aw_adm_while_storm;
            outs_max_0 = outs_max; ovf_0 = ovf_rise; oblk_0 = oblk_rise;
            fire_0 = fire_cnt; respc_0 = respc_cnt;
            // STICKY_CLR (CTRL bit 1) une seule fois, au debut du pas : sans
            // cela un verdict deborde sur le scenario suivant et on retrouve
            // les faux positifs en cascade des campagnes sur carte. A
            // l'interieur d'un pas au contraire, les bits doivent s'accumuler :
            // le bannissement demande MAX_FAILURES = 3 comparaisons d'ID
            // fautives, donc au moins trois transactions. Une seule ne peut pas
            // le declencher -- c'est pourquoi bench_runner.c lance N_ATK
            // iterations par scenario.
            //  CNT_CLR en plus de STICKY_CLR, comme armor_wrap_clear() cote
            //  firmware : sans lui les compteurs materiels s'additionnent d'un
            //  pas sur l'autre et la ligne HW ci-dessous ne serait pas
            //  attribuable au scenario.
            //  AWFIX (CTRL[3]) : active le correctif AXI4, pour que le meme
            //  banc mesure la violation puis verifie sa disparition.
            csr_write(CSR_CTRL, CTRL_OPTS | {61'h0, 1'b1, 1'b1, enforce});
            if (cfg_timeout) return;

            acc_write(ACC_BASE,   LEGIT_DST);
            acc_write(ACC_SIZE,   64'd64);
            acc_write(ACC_CONF,   is_read ? 64'd1 : 64'd0);
            acc_write(ACC_MODE,   {61'h0, mode});
            acc_write(ACC_MSIADR, MSI_WATCH);
            if (cfg_timeout) return;

            cycles_tot = 0;
            n_err      = 0;
            acc_bits   = 5'b0;

            for (k = 0; k < iters; k++) begin
                t0 = $time;
                acc_write(ACC_CTRL, 64'd1);
                if (cfg_timeout) return;

                // Attente de fin sur le signal interne, bornee. Le sondage MMIO
                // a une granularite de 100 cycles, sans rapport avec les
                // ~1450 cycles de l'implementation de reference.
                guard = 0;
                while (i_accel.busy_q && guard < 4*AccelTimeout) begin
                    @(posedge clk_i);
                    guard = guard + 1;
                end
                cycles = ($time - t0) / 10;   // periode 10 ns
                cycles_tot += cycles;

                acc_read(ACC_STATUS, st);
                if (cfg_timeout) return;
                acc_bits |= st[7:3];
                if (st[2]) n_err++;
            end

            got = acc_bits;
            csr_read(CSR_FAILCNT, fails);
            if (cfg_timeout) return;

            ok = expect_clean ? (got == 5'b0) : (got[expect_bits] === 1'b1);
            if (ok) n_pass++; else n_fail++;

            // "err" et non "timeout" : error_q se leve aussi sur le SLVERR
            // fabrique par ARMOR, qui revient en quelques cycles.
            if (aw_owed != 0)
                $display("  %-12s  !! AW SANS W EN AVAL : %0d en attente (max %0d) -- condition du gel carte",
                         name, aw_owed, aw_owed_max);
            $display("  %-12s  OUTS : outstanding max=%0d (seuil 16) | overflow fronts=%0d | block_outs fronts=%0d | req_fire=%0d | resp_complete=%0d",
                     name, outs_max, ovf_rise - ovf_0, oblk_rise - oblk_0,
                     fire_cnt - fire_0, respc_cnt - respc_0);
            if (blk_rise != blk_rise_0)
                $display("  %-12s  BLOCK_REQ : %0d fronts, %0d cy hauts, %0d creux sous storm | AW admis pendant storm : %0d | cycles block+AW_du : %0d | aw_owed=%0d (max %0d)",
                         name, blk_rise - blk_rise_0, blk_hi_cy - blk_hi_0,
                         blk_lo_cy - blk_lo_0, aw_adm_while_storm - aw_adm_0,
                         danger_cy - danger_0, aw_owed, aw_owed_max);
            if (w_excess_tot != w_excess_0)
                $display("  %-12s  !! W ORPHELIN EN AVAL : %0d beat(s) avale(s) sans AW -- canal W decale",
                         name, w_excess_tot - w_excess_0);
            if (w_ghost_tot != w_ghost_0)
                $display("  %-12s  !! BEAT W FANTOME : %0d beat(s) pris en aval sans que le maitre le sache -- canal W decale",
                         name, w_ghost_tot - w_ghost_0);
            pair_step_report(name);
            if (bad_id_rise != bad_id_rise_0)
                $display("  %-12s  bad_id : %0d front(s), %0d cycle(s) hauts -- INVISIBLE au logiciel",
                         name, bad_id_rise - bad_id_rise_0, bad_id_cy - bad_id_cy_0);

            $display("  %-12s mode=%0d %-8s -> %5s | %2d iter | %6d cy moy | err %0d/%0d | fail_cnt=%0d | verdict=%b",
                     name, mode, is_read ? "lecture" : "ecriture",
                     ok ? "OK" : "ECHEC", iters, cycles_tot / iters,
                     n_err, iters, fails[7:0], got);
            obs_line(name);

            //  Controle croise PAR PAS. CNT_CLR est fait au debut du pas, donc
            //  les compteurs materiels sont deja relatifs a ce pas ; on les
            //  confronte aux deltas des compteurs du banc, qui observent les
            //  memes evenements sans passer par le RTL teste.
            //
            //  C'est ici que ces controles ont un sens et pas dans les
            //  scenarios 0 a 2 : ceux-la sont des lectures, sans aucun trafic
            //  sur le canal W, et toutes les egalites y sont vraies a zero.
`ifdef OBS_CHECK
            obs_step_check(name);
`endif

            last_cycles = cycles_tot / iters;
        end
    endtask

    // -------------------------------------------------------------------------
    //  SC08 low-and-slow.
    //
    //  L'idee du scenario : rester SOUS le seuil du detecteur de flux
    //  (MAX_REQ_PER_WINDOW = 8) en espacant les salves de plus d'une fenetre
    //  (FLOW_WINDOW_C = 100 cycles en profil BENCH), pour montrer qu'un
    //  attaquant patient passe au travers. Le resultat attendu est donc une
    //  EVASION, pas une detection : c'est une limite connue des detecteurs a
    //  fenetre glissante, et elle est publiable telle quelle.
    //
    //  Le banc joue deux variantes, parce que ce que fait bench_runner.c ne
    //  correspond pas a ce que son commentaire annonce -- voir le README.
    // -------------------------------------------------------------------------
    task automatic campaign_sc08(input string       name,
                                 input logic  [2:0] mode,
                                 input int unsigned salvos,
                                 input int unsigned burst,
                                 input int unsigned gap_cy,
                                 input bit          expect_evasion);
        logic [63:0] st;
        int unsigned sv, k, guard;
        int unsigned n_passed, n_blocked;
        logic [4:0]  acc_bits;
        bit          ok;
        begin
            csr_write(CSR_CTRL, 64'b011);   // ENFORCE=1, STICKY_CLR=1
            if (cfg_timeout) return;

            acc_write(ACC_BASE,   LEGIT_DST);
            acc_write(ACC_SIZE,   64'd64);
            acc_write(ACC_CONF,   64'd0);      // ecriture
            acc_write(ACC_MODE,   {61'h0, mode});
            acc_write(ACC_MSIADR, MSI_WATCH);
            if (cfg_timeout) return;

            n_passed = 0; n_blocked = 0; acc_bits = 5'b0;

            for (sv = 0; sv < salvos; sv++) begin
                for (k = 0; k < burst; k++) begin
                    acc_write(ACC_CTRL, 64'd1);
                    if (cfg_timeout) return;
                    guard = 0;
                    while (i_accel.busy_q && guard < 4*AccelTimeout) begin
                        @(posedge clk_i);
                        guard = guard + 1;
                    end
                    acc_read(ACC_STATUS, st);
                    if (cfg_timeout) return;
                    acc_bits |= st[7:3];
                    if (st[BIT_BLOCKED+3] || st[BIT_STORM+3]) n_blocked++;
                    else                                       n_passed++;
                end
                repeat (gap_cy) @(posedge clk_i);
            end

            ok = expect_evasion ? (n_blocked == 0) : (n_blocked > 0);
            $display("  %-12s mode=%0d %2d salves x %0d, gap %0d cy -> %5s | passe %0d, bloque %0d | verdict=%b",
                     name, mode, salvos, burst, gap_cy,
                     ok ? "OK" : "ECHEC", n_passed, n_blocked, acc_bits);
            //  SC08 en mode 4 est une tempete d'ecritures : exactement le regime
            //  qui decale le canal W. Sans ce rapport ses anomalies seraient
            //  imputees au pas suivant, SC02.
            pair_step_report(name);
            if (ok) n_pass++; else n_fail++;
        end
    endtask

    task automatic run_campaign();
        begin
            n_pass = 0; n_fail = 0;

            csr_write(CSR_ID_CFG, {40'h0, ACCEL_SID});
            csr_write(CSR_MSIADR, MSI_WATCH);
            csr_write(CSR_CTRL,   64'd1);          // ENFORCE = 1
            if (cfg_timeout) begin
                $display("ECHEC : CSR du wrapper inaccessibles");
                report_and_finish();
            end

            $display("");
            $display("  ID_CFG=%0d  MSI_WATCH=0x%08h  ENFORCE=1  aval sain",
                     ACCEL_SID, MSI_WATCH[31:0]);
            $display("  verdict = {MSI, OUTS, STORM, BANNED, BLOCKED}");
            $display("");

            // Trafic legitime d'abord : c'est la mesure des faux positifs, et
            // elle doit etre faite sur un wrapper vierge de tout verdict.
            //
            // Nommes par leur sens et non SC06/SC07 : le banc n'instancie qu'un
            // accelerateur (le MHA), il ne peut donc pas distinguer le baseline
            // LHA du baseline MHA. Les deux sens sont couverts parce qu'ils
            // exercent des chemins de reponse differents -- R pour la lecture,
            // B pour l'ecriture -- et c'est le retour du B qui manquait avant le
            // correctif de largeur.
            // -----------------------------------------------------------
            //  Coût d'insertion d'ARMOR sur un paquet valide.
            //
            //  ENFORCE=0 rend le wrapper transparent : legit_hit_eff vaut 1 en
            //  permanence, donc request_manager ne coupe plus aw_valid/ar_valid
            //  et le chemin est purement combinatoire. ENFORCE=1 attend que
            //  legit_hit monte, ce qui prend la profondeur du pipeline d'ID.
            //  La différence des deux est le surcoût, mesuré et non déduit.
            // -----------------------------------------------------------
            delay_reset();
            campaign_step("LEGIT-lect/off", 3'd0, 1'b1, 5'd0, 1'b1, 8, 1'b0);
            delay_report("ENFORCE=0 lecture");
            delay_reset();
            cy_off_r = last_cycles;
            campaign_step("LEGIT-ecr/off",  3'd0, 1'b0, 5'd0, 1'b1, 8, 1'b0);
            cy_off_w = last_cycles;

            delay_reset();
            campaign_step("LEGIT-lect", 3'd0, 1'b1, 5'd0,            1'b1, 8, 1'b1);
            delay_report("ENFORCE=1 lecture");
            delay_reset();
            cy_on_r = last_cycles;
            campaign_step("LEGIT-ecr",  3'd0, 1'b0, 5'd0,            1'b1, 8, 1'b1);
            cy_on_w = last_cycles;

            $display("");
            $display("  SURCOUT ARMOR sur paquet valide (ENFORCE 1 - ENFORCE 0) :");
            $display("     lecture  : %0d - %0d = %0d cycles",
                     cy_on_r, cy_off_r, cy_on_r - cy_off_r);
            $display("     ecriture : %0d - %0d = %0d cycles",
                     cy_on_w, cy_off_w, cy_on_w - cy_off_w);
            $display("");

            // ---------------------------------------------------------------
            //  SC08 AVANT tout spoof. Le bannissement de SC01 dure
            //  BLOCK_DURATION_C = 100 000 cycles (~2 ms a 50 MHz) et aucun CSR
            //  ne l'efface : STICKY_CLR ne vide que le registre collant,
            //  CNT_CLR que les compteurs. Mesurer SC08 apres SC01 revient a le
            //  mesurer sur un device banni, et tout y parait bloque.
            //
            //  12 salves au lieu des 100 de bench_runner.c : le mecanisme se
            //  voit en quelques salves.
            // ---------------------------------------------------------------
            // Mode 4 : ce que run_sc08() faisait avant. Le mode 4 est le mode
            // tempete, STORM_REQS = 16 requetes PAR appel, donc les 7 du
            // LAS_BURST font 7 x 16 = 112 requetes par salve, tres au-dessus du
            // seuil de 8. Detection -- l'inverse de ce que le scenario annonce
            // mesurer. Garde ici comme non-regression.
            campaign_sc08("SC08-mode4", 3'd4, 12, 7, 200, 1'b0);
            // Mode 0 : ce que run_sc08() fait desormais, et ce que son
            // commentaire decrivait depuis le debut -- 7 requetes par salve,
            // espacees de plus d'une fenetre. Evasion attendue.
            campaign_sc08("SC08-mode0",  3'd0, 12, 7, 200, 1'b1);
            $display("");

            // ORDRE ALIGNE SUR bench_runner.c (correctif 2026-09-09).
            //
            // Le banc jouait SC01-SPOOF EN PREMIER. C'etait un angle mort de la
            // meme famille que DN_LAT=0 : SC01 bannit le MHA pour
            // BLOCK_DURATION_C, et request_flow_monitor ne compte ses handshakes
            // que si legit_hit_i est vrai (cf. sa garde de legitimite). Un MHA
            // banni ne produit donc plus AUCUN comptage, storm_flag ne monte
            // jamais, et SC02-STORM etait valide sans avoir jamais declenche le
            // moindre blocage de flux -- exactement ce que l'instrumentation
            // block_req a rendu visible (zero front sur SC02).
            //
            // Le firmware, lui, joue SC02 AVANT SC01 (commit f2f999a, « run SC01
            // last »), donc sur un MHA vierge : storm_flag monte reellement et
            // block_req se met a hacher, 4 cycles hauts / 1 creux, pendant tout
            // le reste de la fenetre de 100 cycles. C'est ce regime-la qui gele
            // la carte, et que le banc ne voyait pas.
            campaign_step("SC02-STORM", 3'd4, 1'b0, BIT_STORM[4:0],  1'b0, 8, 1'b1);
            campaign_step("SC04-MSI",   3'd6, 1'b0, BIT_MSI[4:0],    1'b0, 8, 1'b1);
            campaign_step("SC03-OUTS",  3'd5, 1'b1, BIT_OUTS[4:0],   1'b0, 8, 1'b1);
            // SC01 en dernier, comme le firmware : son bannissement contamine
            // tout ce qui demarre dans les ~2 ms qui suivent.
            campaign_step("SC01-SPOOF", 3'd1, 1'b0, BIT_BANNED[4:0], 1'b0, 8, 1'b1);
            // Diagnostic : le meme trafic legitime que LEGIT-ecr, rejoue juste
            // apres le spoof. Il DOIT ressortir banni -- c'est la mesure de la
            // contamination, pas un echec du detecteur.
            campaign_step("LEGIT-apres01", 3'd0, 1'b0, BIT_BANNED[4:0], 1'b0, 8, 1'b1);

            //  Les invariantes generales du bloc d'observabilite valent aussi
            //  sous ENFORCE = 1 : c'est le seul endroit ou elles sont
            //  confrontees a du trafic reellement bloque.
            check_observability();

            $display("");
            $display("-------------------------------------------------------");
            $display(" CAMPAGNE : %0d OK, %0d ECHEC", n_pass, n_fail);
            $display(" OBSERVABILITE : %0d defaut(s)", obs_fail);
            $display(" W orphelin / W fantome : %0d / %0d", w_excess_tot, w_ghost_tot);
            $display(" APPARIEMENT W : %0d correct(s) | %0d avec la donnee d'une autre ecriture, %0d sans AW, %0d pour un AW sans donnee | AW sans adresse maitre %0d, admis deux fois %0d",
                     pair_ok, pair_bad, pair_noaw, pair_nodata, pair_aw_orphan, pair_dup);
            if (pair_bad != 0 || pair_noaw != 0 || pair_nodata != 0)
                $display(" *** CANAL W DECALE : des beats sont partis en aval avec l'adresse d'une autre ecriture");
            $display(" REPONSES PERDUES (prises en aval, jamais vues du maitre, hors drainage) : B=%0d R=%0d",
                     resp_lost_b, resp_lost_r);
            $display(" bad_id : %0d fronts, %0d cycles hauts (invisible au logiciel)",
                     bad_id_rise, bad_id_cy);
            if (w_ghost_tot != 0)
                $display(" *** MECANISME DU GEL REPRODUIT : %0d beat(s) W duplique(s), premier a %0t",
                         w_ghost_tot, w_ghost_first);
            if (cfg_timeout)
                $display(" un acces MMIO n'a pas abouti : resultats incomplets");
            $display("-------------------------------------------------------");
            $finish;
        end
    endtask

    // -------------------------------------------------------------------------
    //  VERIFICATION DU BLOC D'OBSERVABILITE  (2026-09-10)
    //
    //  Un compteur de debogage faux est pire que pas de compteur : il fait
    //  accuser le mauvais coupable. Chaque grandeur est donc confrontee a une
    //  verite que le banc connait PAR AILLEURS -- les compteurs de l'aval
    //  comportemental, qui comptent les memes handshakes sans passer par le RTL
    //  teste -- ou a une invariante que la logique ne peut pas violer.
    //
    //  Les trois scenarios du banc couvrent chacun une des trois nouveautes :
    //    scenario 0 (aval sain)        -> le chronometre boucle et se desarme ;
    //    scenario 1 (accepte, ne repond pas) -> LAT_CUR doit montrer une
    //                                    transaction EN VOL qui ne finit pas,
    //                                    c'est la signature de gel annoncee ;
    //    scenario 2 (n'accepte rien)   -> DBG_STALL_DN doit nommer le canal
    //                                    d'adresse qui n'obtient pas son ready.
    // -------------------------------------------------------------------------
    //  Une ligne compacte par pas de campagne : ce que le MATERIEL a mesure,
    //  a cote de ce que le banc a mesure par $time. L'ecart entre les deux
    //  colonnes de cycles est la meme grandeur que l'ecart Lp50/Lhw qu'on
    //  cherche a chiffrer sur carte -- a ceci pres qu'ici il n'y a pas de sonde
    //  logicielle, seulement la granularite de la boucle d'attente.
    //
    //  Rappel de ce que compte le materiel : UNE TRANSACTION AXI, du front de
    //  presentation a la reponse rendue au maitre. Le banc, lui, compte UNE
    //  ITERATION de l'accelerateur, qui en contient plusieurs sur les modes de
    //  rafale. n depasse donc `iters` sur les tempetes -- et ce n'est pas une
    //  anomalie.
    //  Confronte les compteurs materiels du pas aux deltas du banc. Toute
    //  inegalite est un defaut d'instrumentation, pas un defaut d'ARMOR : elle
    //  doit etre reglee avant qu'on accorde le moindre credit a ces chiffres sur
    //  carte.
    task automatic obs_step_check(input string name);
        logic [63:0] bad, wch, wan, wow;
        begin
            if (cfg_timeout) return;
            csr_read(CSR_CNT_BADID, bad);
            csr_read(CSR_CNT_WCH,   wch);
            csr_read(CSR_CNT_WANOM, wan);
            csr_read(CSR_DBG_WOWED, wow);

            obs_check(bad[31:0]  == (bad_id_rise  - obs_ref_badid),
                      $sformatf("%s : fronts bad_id, materiel %0d, banc %0d",
                                name, bad[31:0], bad_id_rise - obs_ref_badid));
            //  Les CYCLES ne peuvent pas etre compares a l'egalite : quand
            //  bad_id est encore haut -- le bannissement de SC01 dure
            //  BLOCK_DURATION -- le compteur tourne toujours, et le materiel
            //  est lu par CSR AVANT que le banc ne soit echantillonne. Le
            //  premier controle ecrit ici comparait donc deux instants
            //  differents d'une valeur mouvante, et signalait un ecart de 13
            //  cycles comme un defaut de compteur.
            //
            //  La relation vraie est monotone et bornee : le materiel, lu plus
            //  tot, doit etre INFERIEUR OU EGAL au banc, et l'ecart ne peut pas
            //  depasser le cout des lectures CSR intercalees.
            obs_check(bad[63:32] <= (bad_id_cy - obs_ref_badcy),
                      $sformatf("%s : cycles bad_id, materiel %0d > banc %0d -- impossible",
                                name, bad[63:32], bad_id_cy - obs_ref_badcy));
            obs_check((bad_id_cy - obs_ref_badcy) - bad[63:32] <= 128,
                      $sformatf("%s : cycles bad_id, ecart %0d cycles entre materiel (%0d) et banc (%0d) -- trop grand pour un decalage de lecture",
                                name, (bad_id_cy - obs_ref_badcy) - bad[63:32],
                                bad[63:32], bad_id_cy - obs_ref_badcy));
            obs_check(wch[31:0]  == (aw_seen      - obs_ref_awdn),
                      $sformatf("%s : AW aval, materiel %0d, aval comportemental %0d",
                                name, wch[31:0], aw_seen - obs_ref_awdn));
            obs_check(wan[31:0]  == (w_ghost_tot  - obs_ref_ghost),
                      $sformatf("%s : beats fantomes, materiel %0d, banc %0d",
                                name, wan[31:0], w_ghost_tot - obs_ref_ghost));
            obs_check(wan[63:32] == (w_excess_tot - obs_ref_orph),
                      $sformatf("%s : W orphelins, materiel %0d, banc %0d",
                                name, wan[63:32], w_excess_tot - obs_ref_orph));
        end
    endtask

    task automatic obs_line(input string name);
        logic [63:0] cyc, req, ln, ll, mm, sd, cur, bad, wan, rtr, rtd;
        begin
            if (cfg_timeout) return;
            csr_read(CSR_CNT_CYC,  cyc);
            csr_read(CSR_CNT_REQ,  req);
            csr_read(CSR_LAT_N,    ln);
            csr_read(CSR_LAT_LAST, ll);
            csr_read(CSR_LAT_MM,   mm);
            csr_read(CSR_STALL_DN, sd);
            csr_read(CSR_LAT_CUR,  cur);
            csr_read(CSR_CNT_BADID, bad);
            csr_read(CSR_CNT_WANOM, wan);
            csr_read(CSR_CNT_RETR,  rtr);
            csr_read(CSR_DBG_RETR,  rtd);
            $display("  %-12s  HW : n=%0d/%0d verdict | det[min,max]=[%0d,%0d] tx[min,max]=[%0d,%0d] | req up=%0d dn=%0d coupees=%0d | block=%0d cy hold=%0d cy | attente dn aw=%0d ar=%0d | en vol=%0b(%0d cy)",
                     name, ln[31:0], ln[63:32],
                     mm[15:0], mm[31:16], mm[47:32], mm[63:48],
                     req[31:0], req[63:32], req[31:0] - req[63:32],
                     cyc[31:0], cyc[63:32],
                     sd[11:0], sd[47:36],
                     cur[32], cur[31:0]);

            //  bad_id et les anomalies du canal W, par pas. Silencieux quand
            //  tout est a zero : on ne veut voir ces lignes que si quelque
            //  chose bouge.
            //  VALID retire sans READY : l'hypothese du 2026-09-10. Imprime
            //  des qu'un seul retrait est vu -- c'est LE chiffre cherche.
            if (rtr != 0)
                $display("  %-12s  *** VALID RETIRE SANS READY : aw=%0d ar=%0d w=%0d b/r=%0d | 1er a %0d cy, cause=%b (b0 block, b1 !legit, b2 !vk, b3 bad_id), canal=%0d",
                         name, rtr[15:0], rtr[31:16], rtr[47:32], rtr[63:48],
                         rtd[31:0], rtd[35:32], rtd[39:36]);

            if (bad[31:0] != 0 || wan != 0)
                $display("  %-12s  W/ID : bad_id %0d fronts %0d cy | fantomes=%0d orphelins=%0d",
                         name, bad[31:0], bad[63:32], wan[31:0], wan[63:32]);

            //  Incoherence INTERNE a l'instrumentation : le materiel a compte
            //  des cycles de blocage, donc un verdict a bien ete haut, mais
            //  aucune transaction mesuree ne l'a horodate. C'etait le cas avant
            //  que lat_evt_q ne soit echantillonne des le cycle de depart :
            //  n_verdict restait a zero sur SC02-STORM et SC01-SPOOF. Ce
            //  controle existe pour que ce defaut ne revienne pas sans bruit.
            //
            //  A ne pas confondre avec « ARMOR n'a rien detecte » : si
            //  cyc_block vaut zero, il n'y avait rien a horodater (c'est le cas
            //  de SC03-OUTS, dont l'echec est ailleurs).
            if (cyc[31:0] != 0)
                obs_check(ln[63:32] != 0,
                          $sformatf("%s : %0d cycles de blocage comptes mais n_verdict=0",
                                    name, cyc[31:0]));
        end
    endtask

    task automatic obs_check(input bit cond, input string what);
        begin
            if (!cond) begin
                obs_fail++;
                $display("   OBS ECHEC : %s", what);
            end
        end
    endtask

    task automatic check_observability();
        logic [63:0] up, dn, dst, su, sd, cyc, req, ll, mm, cur, tot, tot2;
        logic [63:0] ln, dsum, tsum;
        int unsigned req_up, req_dn, cyc_blk, cyc_hold, n, n_blk;
        begin
            if (cfg_timeout) begin
                $display("   observabilite : port CSR verrouille, non lisible");
                return;
            end

            csr_read(CSR_DBG_UP,    up);
            csr_read(CSR_DBG_DN,    dn);
            csr_read(CSR_DBG_STATE, dst);
            csr_read(CSR_STALL_UP,  su);
            csr_read(CSR_STALL_DN,  sd);
            csr_read(CSR_CNT_CYC,   cyc);
            csr_read(CSR_CNT_REQ,   req);
            csr_read(CSR_LAT_LAST,  ll);
            csr_read(CSR_LAT_DSUM,  dsum);
            csr_read(CSR_LAT_TSUM,  tsum);
            csr_read(CSR_LAT_N,     ln);
            csr_read(CSR_LAT_MM,    mm);
            csr_read(CSR_LAT_CUR,   cur);
            csr_read(CSR_CYC_TOTAL, tot);

            req_up   = req[31:0];
            req_dn   = req[63:32];
            cyc_blk  = cyc[31:0];
            cyc_hold = cyc[63:32];
            n        = ln[31:0];
            n_blk    = ln[63:32];

            $display("-------------------------------------------------------");
            $display(" OBSERVABILITE (MAGIC v2)");
            $display("   DBG_UP=0x%03h  DBG_DN=0x%03h", up[11:0], dn[11:0]);
            $display("   etat : w_owed=%0d w_pending=%0b vk=%0b cvalid=%0b bad_id=%0b legit=%0b",
                     dst[3:0], dst[4], dst[5], dst[6], dst[7], dst[8]);
            $display("   etat : fail=%0d outs=%0d req_cnt=%0d fenetre=%0d fsm_w=%0d fsm_r=%0d",
                     dst[23:16], dst[31:24], dst[39:32], dst[63:40], dst[12:11], dst[13]);
            $display("   attentes up : aw=%0d w=%0d b=%0d ar=%0d r=%0d",
                     su[11:0], su[23:12], su[35:24], su[47:36], su[59:48]);
            $display("   attentes dn : aw=%0d w=%0d b=%0d ar=%0d r=%0d",
                     sd[11:0], sd[23:12], sd[35:24], sd[47:36], sd[59:48]);
            $display("   trafic : req_up=%0d req_dn=%0d (coupees=%0d)",
                     req_up, req_dn, req_up - req_dn);
            $display("   temps  : cyc_block=%0d cyc_hold=%0d cyc_total=%0d",
                     cyc_blk, cyc_hold, tot[31:0]);
            $display("   latence: n=%0d n_verdict=%0d det_last=%0d tx_last=%0d",
                     n, n_blk, ll[31:0], ll[63:32]);
            $display("   latence: det_sum=%0d tx_sum=%0d det[min,max]=[%0d,%0d] tx[min,max]=[%0d,%0d]",
                     dsum, tsum, mm[15:0], mm[31:16], mm[47:32], mm[63:48]);
            $display("   en vol : busy=%0b cycles=%0d verdict_vu=%0b",
                     cur[32], cur[31:0], cur[33]);

            // --- invariantes vraies dans TOUS les scenarios -------------------
            //  Le compteur aval doit reproduire EXACTEMENT ce que l'aval
            //  comportemental a accepte. C'est le controle croise le plus fort
            //  du bloc : deux comptages independants du meme handshake.
            //  Reserve aux scenarios a une seule transaction : dans la
            //  campagne, les compteurs de l'aval sont cumules sur tous les pas
            //  alors que req_dn a ete remis a zero au dernier CNT_CLR. La
            //  comparaison n'y aurait aucun sens.
            if (scenario != 3)
                obs_check(req_dn == (aw_seen + ar_seen),
                          $sformatf("req_dn=%0d mais l'aval a accepte %0d adresses (aw=%0d ar=%0d)",
                                    req_dn, aw_seen + ar_seen, aw_seen, ar_seen));

            //  On ne peut pas admettre en aval plus que le maitre n'a presente.
            obs_check(req_up >= req_dn,
                      $sformatf("req_up=%0d < req_dn=%0d : impossible", req_up, req_dn));

            //  n compte les transactions bouclees, n_blk celles ou un verdict a
            //  ete vu : la seconde est un sous-ensemble de la premiere.
            obs_check(n_blk <= n,
                      $sformatf("n_verdict=%0d > n=%0d", n_blk, n));

            //  Les sommes doivent etre coherentes avec le nombre d'echantillons.
            obs_check(!(n == 0 && (dsum != 0 || tsum != 0)),
                      "n=0 mais les sommes de latence ne sont pas nulles");
            obs_check(dsum <= tsum,
                      $sformatf("det_sum=%0d > tx_sum=%0d : la detection ne peut pas suivre la fin", dsum, tsum));

            //  Le compteur de cycles doit avancer. Une lecture plus tard doit
            //  donner strictement plus : sinon il est gele (mauvais reset, ou
            //  CNT_CLR interprete comme un reset asynchrone permanent).
            repeat (20) @(posedge clk_i);
            csr_read(CSR_CYC_TOTAL, tot2);
            obs_check(tot2 > tot,
                      $sformatf("cyc_total ne progresse pas (%0d puis %0d)", tot, tot2));

            // --- version 3 : les nouveaux compteurs, confrontes au banc -------
            //
            //  Le banc compte EXACTEMENT les memes evenements, de son cote et
            //  sans passer par le RTL teste. Ces cinq egalites sont donc le
            //  controle le plus fort qu'on puisse leur appliquer -- et elles
            //  disqualifient d'avance l'excuse « le compteur devait etre faux »
            //  si l'un d'eux bouge sur carte.
            //
            //  Reserve aux scenarios a transaction unique : dans la campagne,
            //  CNT_CLR est fait a chaque pas alors que les compteurs du banc
            //  courent depuis le reset -- et surtout, les lectures CSR
            //  supplementaires y perturberaient SC03 et SC04 (cf. OBS_CHECK
            //  dans run_sim.sh).
            if (scenario != 3) begin
                logic [63:0] bad, wch, wan, wow;
                csr_read(CSR_CNT_BADID, bad);
                csr_read(CSR_CNT_WCH,   wch);
                csr_read(CSR_CNT_WANOM, wan);
                csr_read(CSR_DBG_WOWED, wow);

                $display("   bad_id : %0d fronts, %0d cycles   (banc : %0d / %0d)",
                         bad[31:0], bad[63:32], bad_id_rise, bad_id_cy);
                $display("   canal W aval : AW=%0d W-last=%0d ecart=%0d",
                         wch[31:0], wch[63:32],
                         $signed(wch[31:0] - wch[63:32]));
                $display("   anomalies W : fantomes=%0d orphelins=%0d   (banc : %0d / %0d)",
                         wan[31:0], wan[63:32], w_ghost_tot, w_excess_tot);
                $display("   w_owed : courant=%0d max=%0d   (banc max : %0d)",
                         wow[7:0], wow[15:8], aw_owed_max);

                obs_check(bad[31:0]  == bad_id_rise,
                          $sformatf("fronts bad_id : materiel %0d, banc %0d",
                                    bad[31:0], bad_id_rise));
                obs_check(bad[63:32] == bad_id_cy,
                          $sformatf("cycles bad_id : materiel %0d, banc %0d",
                                    bad[63:32], bad_id_cy));
                obs_check(wch[31:0]  == aw_seen,
                          $sformatf("AW aval : materiel %0d, aval comportemental %0d",
                                    wch[31:0], aw_seen));
                obs_check(wan[31:0]  == w_ghost_tot,
                          $sformatf("beats fantomes : materiel %0d, banc %0d",
                                    wan[31:0], w_ghost_tot));
                obs_check(wan[63:32] == w_excess_tot,
                          $sformatf("W orphelins : materiel %0d, banc %0d",
                                    wan[63:32], w_excess_tot));
                obs_check(wow[15:8]  == aw_owed_max,
                          $sformatf("filigrane w_owed : materiel %0d, banc %0d",
                                    wow[15:8], aw_owed_max));
            end

            // --- invariantes propres a chaque scenario ------------------------
            if (scenario == 0) begin
                obs_check(n >= 1, "aval sain : aucune transaction chronometree");
                obs_check(cur[32] == 1'b0,
                          "aval sain : une transaction est restee en vol");
                obs_check(cyc_blk == 0,
                          $sformatf("aval sain et trafic legitime : %0d cycles de blocage", cyc_blk));
                obs_check(ll[63:32] > 0, "aval sain : tx_last nul");
            end

            if (scenario == 1) begin
                //  L'aval accepte l'adresse et ne repond jamais : la mesure
                //  reste ouverte. C'est precisement l'etat que LAT_CUR existe
                //  pour rendre lisible sur carte.
                obs_check(cur[32] == 1'b1,
                          "aval muet : aucune transaction signalee en vol");
                obs_check(cur[31:0] > 100,
                          $sformatf("aval muet : le compteur en vol n'a que %0d cycles", cur[31:0]));
            end

            if (scenario == 2) begin
                //  L'aval n'accepte rien : le canal d'adresse presente son valid
                //  sans jamais recevoir son ready.
                obs_check((sd[11:0] > 100) || (sd[47:36] > 100),
                          $sformatf("aval bouche : attente dn aw=%0d ar=%0d, trop faible",
                                    sd[11:0], sd[47:36]));
                obs_check(req_dn == 0,
                          $sformatf("aval bouche : req_dn=%0d alors que rien n'est accepte", req_dn));
            end

            // --- CNT_CLR doit vraiment effacer, et seulement quand on le dit --
            //  Test en dernier : il detruit les compteurs. Il verifie surtout que
            //  la remise a zero est bien SYNCHRONE -- si CNT_CLR etait pris pour
            //  un reset asynchrone, le compteur libre resterait a zero apres.
            csr_write(CSR_CTRL, 64'b100);          // CNT_CLR seul, ENFORCE = 0
            csr_read(CSR_CNT_REQ,   req);
            csr_read(CSR_LAT_N,     ln);
            csr_read(CSR_STALL_DN,  sd);
            obs_check(req == 0, $sformatf("CNT_CLR n'a pas efface CNT_REQ (0x%016h)", req));
            obs_check(ln  == 0, $sformatf("CNT_CLR n'a pas efface LAT_N (0x%016h)", ln));
            obs_check(sd  == 0, $sformatf("CNT_CLR n'a pas efface DBG_STALL_DN (0x%016h)", sd));

            repeat (20) @(posedge clk_i);
            csr_read(CSR_CYC_TOTAL, tot2);
            obs_check(tot2 > 0, "cyc_total reste a zero apres CNT_CLR : remise a zero non synchrone");

            $display("   -> observabilite : %0d defaut(s)", obs_fail);
            $display("-------------------------------------------------------");
        end
    endtask

    task automatic report_and_finish();
        begin
            $display("-------------------------------------------------------");
            $display(" RESULTAT scenario %0d", scenario);
            $display("   busy vu           : %0b", saw_busy);
            $display("   done vu           : %0b", saw_done);
            $display("   error vu          : %0b", saw_error);
            $display("   requetes aval par transaction : ar=%0d (attendu 1)", ar_seen);
            $display("   gel MMIO          : %0b", cfg_timeout);
            $display("   aval : aw=%0d w=%0d ar=%0d b=%0d r=%0d",
                     aw_seen, w_seen, ar_seen, b_sent, r_sent);
            $display("   accel   : %s", accel_state_str());
            $display("   wrapper : %s", wrapper_state_str());
            $display("   observabilite     : %0d defaut(s)", obs_fail);
            $display("   W orphelin / W fantome : %0d / %0d", w_excess_tot, w_ghost_tot);
            if (w_ghost_tot != 0)
                $display(" *** MECANISME DU GEL PROUVE : %0d beat(s) W duplique(s), premier a %0t",
                         w_ghost_tot, w_ghost_first);
            $display("-------------------------------------------------------");
            if (obs_fail != 0)
                $display(" ATTENTION : le bloc d'observabilite ment sur %0d point(s) -- ne pas synthetiser.", obs_fail);
            if (scenario == 0) begin
                // done ET error ensemble = timeout de l'accelerateur, pas une
                // transaction aboutie : c'est exactement ce que les campagnes
                // sur carte rapportaient comme verdict 'E'.
                if (saw_done && !saw_error && !cfg_timeout)
                    $display(" VERDICT : datapath sain avec un aval ideal.");
                else if (saw_error)
                    $display(" VERDICT : timeout (done+error) malgre un aval ideal -- le defaut est en amont de l'IOMMU.");
                else
                    $display(" VERDICT : rien n'aboutit avec un aval ideal.");
            end else begin
                if (cfg_timeout)
                    $display(" VERDICT : un aval qui ne repond pas verrouille un port de config. Gel CPU reproduit.");
                else
                    $display(" VERDICT : le DMA cale mais les ports de config repondent -- le gel carte a une autre cause.");
            end
            $finish;
        end
    endtask

    // -------------------------------------------------------------------------
    //  Garde-fou global : la simulation ne doit jamais tourner indefiniment.
    // -------------------------------------------------------------------------
    initial begin
        //  +GUARD_MS=<n> (defaut 2). Avec DN_WLAT=40, chaque beat W coute ~40
        //  cycles et SC08 mode 4 depasse a lui seul 60 000 cycles : 2 ms
        //  (200 000 cycles) ne suffisent plus a la campagne entiere, et un
        //  arret par garde-fou se lirait comme un gel.
        int unsigned guard_ms;
        if (!$value$plusargs("GUARD_MS=%d", guard_ms)) guard_ms = 2;
        #(guard_ms * 1ms);
        $display("[%0t] *** GARDE-FOU GLOBAL : la simulation ne se termine pas", $time);
        $display("      accel   : %s", accel_state_str());
        $display("      wrapper : %s", wrapper_state_str());
        $finish;
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $dumpfile("tb_accel_armor.vcd");
            $dumpvars(0, tb_accel_armor);
        end
    end

endmodule
