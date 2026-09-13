// =============================================================================
//  tb_iommu_pipe.sv — banc de CONFIRMATION du gel mode 7 (SC09) au niveau SoC.
//
//  HYPOTHESE A CONFIRMER (voir la memoire sc09_wedge_mode7) :
//    Le mode 7 presente N adresses d'ecriture EN VOL (aw_valid tenu haut) AVANT
//    la moindre donnee. L'IOMMU serialise les AW (FSM mono-requete IDLE ->
//    traduction -> forward -> IDLE) et forwarde chaque AW traduit vers l'aval
//    (comp IF -> crossbar -> DRAM). L'aval ne tient qu'un nombre FINI d'AW-sans-W
//    ouverts ; au-dela il retombe aw_ready. La retro-pression remonte
//    comp.aw_ready -> dev_tr_resp.aw_ready -> le maitre. Si N depasse cette
//    capacite, le maitre ne finit jamais sa phase d'adresses, n'emet jamais ses
//    W, les ecritures ouvertes ne recoivent jamais leur donnee : INTERBLOCAGE du
//    canal d'ecriture. Sur carte, le CPU (fetch/pile en DRAM, derriere ces
//    ecritures) se fige a son tour -> UART muet.
//
//  Ce que armor/tb NE modelise PAS et que ce banc ajoute : le VRAI riscv_iommu
//  (sa serialisation) et un aval a outstanding BORNE. C'est le chainon manquant.
//
//  IOMMU en mode Bare (ddtp.iommu_mode = 1) : une ecriture non traduite complete
//  immediatement (rv_iommu_tw_sv39x4_pc.sv, branche Bare : trans_valid_o=1,
//  adresse passee telle quelle) -- aucune DDT ni page-table a construire, mais la
//  FSM serialisante et le forwarding sont EXACTEMENT ceux du chemin traduit.
//
//  Balayage : xsim tb_iommu_snap -testplusarg N=<prof> -testplusarg MAXOPEN=<k>
//    -testplusarg WLAT=<lat>.  run_iommu_sim.sh joue N in {2,4,8,16}.
//
//  Verdict :
//    OK     : les N ecritures se terminent (B recu pour chacune).
//    WEDGE  : plus aucun handshake pendant TIMEOUT cycles -> gel reproduit.
// =============================================================================
`timescale 1ns/1ps

`include "register_interface/typedef.svh"
`include "register_interface/assign.svh"

module tb_iommu_pipe;

    import ariane_axi_soc::*;
    import ariane_soc::*;

    // -------------------------------------------------------------------------
    //  Parametres de scenario (surchargeables par -testplusarg)
    // -------------------------------------------------------------------------
    int unsigned N        = 8;    // profondeur d'adresses en vol (mode 7)
    int unsigned MAXOPEN  = 4;    // AW-sans-W que l'aval (DRAM/xbar) tolere
    int unsigned WLAT     = 8;    // latence d'ecriture aval (cycles apres w_last)
    int unsigned TIMEOUT  = 2000; // cycles sans progres => WEDGE

    localparam ADDR_W = 64;
    localparam DATA_W = 64;
    localparam logic [63:0] WR_ADDR = 64'h9100_0000;  // LEGIT_DST, non-MSI
    localparam logic [11:0] DDTP_OFF = 12'h010;

    // Types reg pour le port de programmation (comme ariane_peripherals)
    `REG_BUS_TYPEDEF_ALL(iommu_reg, ariane_axi_soc::addr_t,
                         ariane_axi_soc::data_t, ariane_axi_soc::strb_t)

    // -------------------------------------------------------------------------
    //  Horloge / reset
    // -------------------------------------------------------------------------
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                 // 100 MHz sim (l'echelle importe peu)

    // -------------------------------------------------------------------------
    //  Signaux DUT
    // -------------------------------------------------------------------------
    req_mmu_t   tr_req;    resp_t      tr_rsp;    // TR IF   (maitre = accel)
    req_t       comp_req;  resp_t      comp_rsp;  // comp IF (aval = DRAM)
    req_t       ds_req;    resp_t      ds_rsp;    // ds IF   (walks : inactif en Bare)
    req_slv_t   prog_req;  resp_slv_t  prog_rsp;  // prog IF (config)
    logic [ariane_soc::IOMMUNumWires-1:0] wsi;

    // -------------------------------------------------------------------------
    //  DUT : le VRAI riscv_iommu, memes parametres que le SoC
    // -------------------------------------------------------------------------
    riscv_iommu #(
        .IOTLB_ENTRIES   ( 8                        ),
        .DDTC_ENTRIES    ( 4                        ),
        .PDTC_ENTRIES    ( 4                        ),
        .MRIFC_ENTRIES   ( 4                        ),
        .InclPC          ( 1'b0                     ),
        .InclBC          ( 1'b1                     ),
        .InclDBG         ( 1'b0                     ),
        .MSITrans        ( rv_iommu::MSI_FLAT_MRIF  ),
        .IGS             ( rv_iommu::BOTH           ),
        .N_INT_VEC       ( ariane_soc::IOMMUNumWires),
        .N_IOHPMCTR      ( 8                        ),
        .ADDR_WIDTH      ( ADDR_W                   ),
        .DATA_WIDTH      ( DATA_W                   ),
        .ID_WIDTH        ( ariane_soc::IdWidth      ),
        .ID_SLV_WIDTH    ( ariane_soc::IdWidthSlave ),
        .USER_WIDTH      ( 1                        ),
        .aw_chan_t       ( aw_chan_t                ),
        .w_chan_t        ( w_chan_t                 ),
        .b_chan_t        ( b_chan_t                 ),
        .ar_chan_t       ( ar_chan_t                ),
        .r_chan_t        ( r_chan_t                 ),
        .axi_req_t       ( req_t                    ),
        .axi_rsp_t       ( resp_t                   ),
        .axi_req_slv_t   ( req_slv_t                ),
        .axi_rsp_slv_t   ( resp_slv_t               ),
        .axi_req_iommu_t ( req_mmu_t                ),
        .reg_req_t       ( iommu_reg_req_t          ),
        .reg_rsp_t       ( iommu_reg_rsp_t          )
    ) dut (
        .clk_i           ( clk      ),
        .rst_ni          ( rst_n    ),
        .dev_tr_req_i    ( tr_req   ),
        .dev_tr_resp_o   ( tr_rsp   ),
        .dev_comp_resp_i ( comp_rsp ),
        .dev_comp_req_o  ( comp_req ),
        .ds_resp_i       ( ds_rsp   ),
        .ds_req_o        ( ds_req   ),
        .prog_req_i      ( prog_req ),
        .prog_resp_o     ( prog_rsp ),
        .wsi_wires_o     ( wsi      )
    );

    // -------------------------------------------------------------------------
    //  ds IF : aucun page-table walk en Bare — on ne bloque jamais, rien a servir
    // -------------------------------------------------------------------------
    always_comb begin
        ds_rsp          = '0;
        ds_rsp.aw_ready = 1'b1;
        ds_rsp.w_ready  = 1'b1;
        ds_rsp.ar_ready = 1'b1;
        // b_valid / r_valid restent a 0 : l'IOMMU n'emet aucune requete ds
    end

    // -------------------------------------------------------------------------
    //  Compteurs d'observation
    // -------------------------------------------------------------------------
    int unsigned tr_aw_acc;    // AW du maitre acquittes par l'IOMMU
    int unsigned tr_w_acc;     // W du maitre acquittes par l'IOMMU
    int unsigned comp_aw_acc;  // AW forwardes acceptes par l'aval
    int unsigned comp_b_done;  // B rendus par l'aval (indicatif)
    int unsigned tr_b_acc;     // B RECUS PAR LE MAITRE = vraie complétion d'ecriture
    int unsigned comp_open;    // AW ouverts en aval SANS leur W (le nerf du gel)

    // -------------------------------------------------------------------------
    //  AVAL comportemental (comp IF) : DRAM/xbar a outstanding-AW-sans-W BORNE.
    //
    //    - accepte AW tant que comp_open < MAXOPEN, sinon retombe aw_ready ;
    //    - accepte W en continu, apparie au plus ancien AW ouvert (meme adresse,
    //      ordre AXI) ; a w_last, l'ecriture quitte l'etat "ouvert" et une B est
    //      programmee WLAT cycles plus tard.
    //  C'est precisement la ressource finie que le banc armor/tb ne modelise pas.
    // -------------------------------------------------------------------------
    //  File d'AW ouverts (id) et file de B en attente (id) : accedees UNIQUEMENT
    //  en procedural (always_ff). Les sorties B sont REGISTREES (b_valid_q,
    //  b_id_q) -- sinon xsim n'est pas sensible a l'element de tete d'une queue
    //  dans un always_comb et n'emet jamais la B (bug initial du banc).
    logic [ariane_soc::IdWidth-1:0] open_id[$];  // AW acceptes, attendent W-last
    logic [ariane_soc::IdWidth-1:0] bq_id[$];    // W-last recu, attendent leur B
    int unsigned bhead_tmr;                      // latence restante de la B de tete
    logic                           b_valid_q;
    logic [ariane_soc::IdWidth-1:0] b_id_q;

    // aw_ready / w_ready : combinatoire sur des ENTIERS (sensibilite fiable).
    always_comb begin
        comp_rsp          = '0;
        comp_rsp.aw_ready = (comp_open < MAXOPEN);   // l'aval borne ses AW-sans-W
        comp_rsp.w_ready  = (comp_open > 0);         // une ecriture ouverte a nourrir
        comp_rsp.b_valid  = b_valid_q;               // B registree
        comp_rsp.b.id     = b_id_q;
        comp_rsp.b.resp   = axi_pkg::RESP_OKAY;
        comp_rsp.r_valid  = 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            comp_aw_acc <= 0; comp_b_done <= 0; comp_open <= 0;
            open_id.delete(); bq_id.delete(); bhead_tmr <= 0;
            b_valid_q <= 1'b0; b_id_q <= '0;
        end else begin
            // AW forwarde accepte : ouvre une ecriture (borne par MAXOPEN)
            if (comp_req.aw_valid && (comp_open < MAXOPEN)) begin
                open_id.push_back(comp_req.aw.id);
                comp_open   <= comp_open + 1;
                comp_aw_acc <= comp_aw_acc + 1;
            end
            // W-last : l'ecriture la plus ancienne se termine, sa B est armee
            if (comp_req.w_valid && (comp_open > 0) && comp_req.w.last) begin
                automatic logic [ariane_soc::IdWidth-1:0] wid = open_id.pop_front();
                comp_open <= comp_open - 1;
                bq_id.push_back(wid);
                if (bq_id.size() == 0 && !b_valid_q) bhead_tmr <= WLAT; // 1re en file
            end
            // Latence de la B de tete
            if (!b_valid_q && bq_id.size() != 0 && bhead_tmr != 0)
                bhead_tmr <= bhead_tmr - 1;
            // Presentation de la B de tete quand sa latence est ecoulee
            if (!b_valid_q && bq_id.size() != 0 && bhead_tmr == 0) begin
                b_valid_q <= 1'b1;
                b_id_q    <= bq_id[0];
            end
            // B acquittee par le maitre
            if (b_valid_q && tr_rsp.b_valid && tr_req.b_ready) begin
                void'(bq_id.pop_front());
                comp_b_done <= comp_b_done + 1;
                b_valid_q   <= 1'b0;
                bhead_tmr   <= WLAT;   // arme la latence de la B suivante
            end
        end
    end

    // -------------------------------------------------------------------------
    //  MAITRE = modele fidele de la FSM mode 7 de accel_wrap :
    //    G_PAW : emet N AW (adresse fixe, id = i, aw_valid tenu haut), un/cycle
    //            tant que l'aval acquitte -- NE PASSE aux donnees qu'apres les N.
    //    G_PW  : emet ensuite les N beats W (w_last a chaque, len=0).
    //  Si aw_ready retombe et ne revient pas, le maitre reste bloque en G_PAW :
    //  c'est l'interblocage a reproduire.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] { M_IDLE, M_PAW, M_PW, M_DONE } mstate_e;
    mstate_e mst;
    int unsigned aw_idx, w_idx;
    logic start_storm;

    // Champs AW constants
    always_comb begin
        tr_req            = '0;
        tr_req.aw.addr    = WR_ADDR;
        tr_req.aw.len     = 8'd0;               // 1 beat par adresse
        tr_req.aw.size    = 3'b011;             // 8 octets
        tr_req.aw.burst   = axi_pkg::BURST_INCR;
        tr_req.aw.prot    = 3'b000;             // ecriture non traduite => Bare OK
        tr_req.aw.id      = aw_idx[ariane_soc::IdWidth-1:0];
        tr_req.b_ready    = 1'b1;
        tr_req.aw_valid   = (mst == M_PAW);
        tr_req.w.data     = 64'hDEAD_BEEF_0000_0000 + w_idx;
        tr_req.w.strb     = 8'hFF;
        tr_req.w.last     = 1'b1;               // len=0 => chaque beat est last
        tr_req.w_valid    = (mst == M_PW);
    end

    // -------------------------------------------------------------------------
    //  Programmation du port config : DDTP.iommu_mode = Bare (1)
    // -------------------------------------------------------------------------
    task automatic prog_write64(input logic [11:0] off, input logic [63:0] val);
        @(posedge clk);
        prog_req.aw.addr  <= {52'd0, off};
        prog_req.aw.id    <= '0;
        prog_req.aw.len   <= 8'd0;
        prog_req.aw.size  <= 3'b011;
        prog_req.aw.burst <= axi_pkg::BURST_INCR;
        prog_req.aw_valid <= 1'b1;
        do @(posedge clk); while (!prog_rsp.aw_ready);
        prog_req.aw_valid <= 1'b0;
        prog_req.w.data   <= val;
        prog_req.w.strb   <= 8'hFF;
        prog_req.w.last   <= 1'b1;
        prog_req.w_valid  <= 1'b1;
        do @(posedge clk); while (!prog_rsp.w_ready);
        prog_req.w_valid  <= 1'b0;
        prog_req.b_ready  <= 1'b1;
        do @(posedge clk); while (!prog_rsp.b_valid);
        prog_req.b_ready  <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    //  Watchdog de progres : tout handshake (cote maitre ou aval) reamorce.
    // -------------------------------------------------------------------------
    int unsigned last_progress, cyc;
    int unsigned prev_sum;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tr_aw_acc <= 0; tr_w_acc <= 0; tr_b_acc <= 0;
        end else begin
            if (tr_req.aw_valid && tr_rsp.aw_ready) tr_aw_acc <= tr_aw_acc + 1;
            if (tr_req.w_valid  && tr_rsp.w_ready ) tr_w_acc  <= tr_w_acc  + 1;
            if (tr_rsp.b_valid  && tr_req.b_ready ) tr_b_acc  <= tr_b_acc  + 1;
        end
    end

    // -------------------------------------------------------------------------
    //  Sequence maitre + arbitrage du verdict
    // -------------------------------------------------------------------------
    initial begin
        if ($value$plusargs("N=%d",       N));
        if ($value$plusargs("MAXOPEN=%d", MAXOPEN));
        if ($value$plusargs("WLAT=%d",    WLAT));
        if ($value$plusargs("TIMEOUT=%d", TIMEOUT));

        start_storm = 0;
        prog_req = '0;
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("### tb_iommu_pipe : N=%0d MAXOPEN=%0d WLAT=%0d", N, MAXOPEN, WLAT);
        prog_write64(DDTP_OFF, 64'h1);      // ddtp.iommu_mode = Bare
        repeat (5) @(posedge clk);
        $display("### DDTP programme (Bare). Lancement de la tempete mode 7.");

        start_storm = 1;   // l'always_ff fait passer M_IDLE -> M_PAW
    end

    // avance de la FSM maitre
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mst <= M_IDLE; aw_idx <= 0; w_idx <= 0;
        end else begin
            case (mst)
                M_IDLE: if (start_storm) mst <= M_PAW;
                M_PAW: begin
                    if (tr_req.aw_valid && tr_rsp.aw_ready) begin
                        if (aw_idx + 1 == N) begin aw_idx <= 0; mst <= M_PW; end
                        else                       aw_idx <= aw_idx + 1;
                    end
                end
                M_PW: begin
                    if (tr_req.w_valid && tr_rsp.w_ready) begin
                        if (w_idx + 1 == N) begin w_idx <= w_idx + 1; mst <= M_DONE; end
                        else                       w_idx <= w_idx + 1;
                    end
                end
                default: ;
            endcase
        end
    end

    // watchdog
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 0; last_progress <= 0; prev_sum <= 0;
        end else begin
            cyc <= cyc + 1;
            if ((tr_aw_acc + tr_w_acc + comp_aw_acc + tr_b_acc) != prev_sum) begin
                prev_sum      <= tr_aw_acc + tr_w_acc + comp_aw_acc + tr_b_acc;
                last_progress <= cyc;
            end

            // succes : les N ecritures ont recu leur B
            if (mst == M_DONE && tr_b_acc == N) begin
                $display("### OK  N=%0d MAXOPEN=%0d : les %0d ecritures se sont terminees (cyc=%0d)",
                         N, MAXOPEN, N, cyc);
                $display("###     tr_aw=%0d tr_w=%0d comp_aw=%0d tr_b=%0d comp_open=%0d",
                         tr_aw_acc, tr_w_acc, comp_aw_acc, tr_b_acc, comp_open);
                $finish;
            end

            // gel : plus aucun progres depuis TIMEOUT cycles
            if (rst_n && mst != M_IDLE && (cyc - last_progress) > TIMEOUT) begin
                $display("### WEDGE  N=%0d MAXOPEN=%0d : gel (aucun progres depuis %0d cyc, cyc=%0d)",
                         N, MAXOPEN, TIMEOUT, cyc);
                $display("###     etat maitre=%0d aw_idx=%0d w_idx=%0d", mst, aw_idx, w_idx);
                $display("###     tr_aw=%0d tr_w=%0d comp_aw=%0d tr_b=%0d comp_open=%0d aw_ready(tr)=%0b",
                         tr_aw_acc, tr_w_acc, comp_aw_acc, tr_b_acc, comp_open, tr_rsp.aw_ready);
                $display("###     B-path: comp.b_valid_q=%0b comp_req.b_ready=%0b tr_rsp.b_valid=%0b tr_req.b_ready=%0b bq=%0d",
                         b_valid_q, comp_req.b_ready, tr_rsp.b_valid, tr_req.b_ready, bq_id.size());
                $display("###     DIAGNOSTIC : le maitre est reste en phase AW (mst=1) sans jamais");
                $display("###     atteindre la phase W -> ecritures ouvertes sans donnee -> canal bloque.");
                $finish;
            end
        end
    end

endmodule
