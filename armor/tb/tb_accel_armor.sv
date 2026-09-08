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

    localparam logic [63:0] MAGIC_EXPECTED = 64'h41524D4F52000001;

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

    assign resp_out.aw_ready = dn_accept & ~b_pending;
    assign resp_out.w_ready  = dn_accept;
    assign resp_out.ar_ready = dn_accept & ~r_pending;

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
        $display(" tb_accel_armor -- SCENARIO %0d", scenario);
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

    task automatic campaign_step(input string       name,
                                 input logic  [2:0] mode,
                                 input logic        is_read,
                                 input logic  [4:0] expect_bits,
                                 input bit          expect_clean,
                                 input int unsigned iters);
        logic [63:0] st, fails;
        time         t0;
        int unsigned cycles, cycles_tot;
        int unsigned guard;
        int unsigned n_err;
        logic [4:0]  got, acc_bits;
        bit          ok;
        int unsigned k;
        begin
            // STICKY_CLR (CTRL bit 1) une seule fois, au debut du pas : sans
            // cela un verdict deborde sur le scenario suivant et on retrouve
            // les faux positifs en cascade des campagnes sur carte. A
            // l'interieur d'un pas au contraire, les bits doivent s'accumuler :
            // le bannissement demande MAX_FAILURES = 3 comparaisons d'ID
            // fautives, donc au moins trois transactions. Une seule ne peut pas
            // le declencher -- c'est pourquoi bench_runner.c lance N_ATK
            // iterations par scenario.
            csr_write(CSR_CTRL, 64'b011);   // ENFORCE=1, STICKY_CLR=1
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
            $display("  %-12s mode=%0d %-8s -> %5s | %2d iter | %6d cy moy | err %0d/%0d | fail_cnt=%0d | verdict=%b",
                     name, mode, is_read ? "lecture" : "ecriture",
                     ok ? "OK" : "ECHEC", iters, cycles_tot / iters,
                     n_err, iters, fails[7:0], got);
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
            campaign_step("SC06-LHAOK", 3'd0, 1'b1, 5'd0,            1'b1, 8);
            campaign_step("SC07-MHAOK", 3'd0, 1'b0, 5'd0,            1'b1, 8);

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

            campaign_step("SC01-SPOOF", 3'd1, 1'b0, BIT_BANNED[4:0], 1'b0, 8);
            // Diagnostic : le meme trafic legitime que SC07, rejoue juste
            // apres le spoof. Il DOIT ressortir banni -- c'est la mesure de la
            // contamination, pas un echec du detecteur. block_ip_o reste actif
            // BLOCK_DURATION_C = 100 000 cycles (~2 ms a 50 MHz) et aucun CSR
            // ne l'efface. Dans l'ordre de bench_runner.c (SC01, SC02, SC04,
            // SC06, SC07, SC08, SC03), tout ce qui demarre dans cette fenetre
            // herite du verdict.
            campaign_step("SC07-apres01", 3'd0, 1'b0, BIT_BANNED[4:0], 1'b0, 8);

            campaign_step("SC02-STORM", 3'd4, 1'b0, BIT_STORM[4:0],  1'b0, 8);
            campaign_step("SC04-MSI",   3'd6, 1'b0, BIT_MSI[4:0],    1'b0, 8);
            // SC03 en dernier : le mode 5 laisse des lectures sans reponse
            // derriere lui, et il contaminait les scenarios suivants.
            campaign_step("SC03-OUTS",  3'd5, 1'b1, BIT_OUTS[4:0],   1'b0, 8);

            $display("");
            $display("-------------------------------------------------------");
            $display(" CAMPAGNE : %0d OK, %0d ECHEC", n_pass, n_fail);
            if (cfg_timeout)
                $display(" un acces MMIO n'a pas abouti : resultats incomplets");
            $display("-------------------------------------------------------");
            $finish;
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
            $display("-------------------------------------------------------");
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
        #2ms;
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
