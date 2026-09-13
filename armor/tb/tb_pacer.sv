// =============================================================================
//  tb_pacer.sv — validation du correctif A (axi_wr_pacer), AXI propre, sans
//  IOMMU (le banc riscv_iommu isole a un B a X -- select-B du demux non
//  initialise hors SoC -- qui empeche d'y valider du vrai RTL de contre-pression).
//
//  Chaine : maitre mode 7 (N AW en vol PUIS N W) -> [pacer si +PACER] -> aval a
//  outstanding-write BORNE (MAXOPEN), exactement le modele qui reproduit le gel.
//
//  Attendu :
//    sans PACER : N > MAXOPEN -> WEDGE (le gel).
//    avec PACER : tout N passe (le pacer ne presente jamais > MAX_WR_TXN
//                 ecriture en vol a l'aval, quelle que soit la profondeur).
//
//    xsim ... -testplusarg N=<n> -testplusarg MAXOPEN=<k> [+define+PACER]
// =============================================================================
`timescale 1ns/1ps
module tb_pacer;
    import ariane_axi_soc::*;

    int unsigned N = 8, MAXOPEN = 4, WLAT = 6, TIMEOUT = 3000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    req_t  m_req,  d_req;    // maitre ; aval (apres pacer)
    resp_t m_rsp,  d_rsp;

    // -------------------------------------------------------------------------
    //  Correctif A : pacer entre maitre et aval (ou liaison directe)
    // -------------------------------------------------------------------------
`ifdef PACER
    axi_wr_pacer #(
        .aw_chan_t(aw_chan_t), .w_chan_t(w_chan_t), .b_chan_t(b_chan_t),
        .axi_req_t(req_t), .axi_rsp_t(resp_t), .FIFO_DEPTH(32), .MAX_WR_TXN(1)
    ) i_pacer (
        .clk_i(clk), .rst_ni(rst_n),
        .slv_req_i(m_req), .slv_rsp_o(m_rsp),
        .mst_req_o(d_req), .mst_rsp_i(d_rsp)
    );
`else
    assign d_req = m_req;
    assign m_rsp = d_rsp;
`endif

    // -------------------------------------------------------------------------
    //  Maitre mode 7 : N AW (adresse fixe, id=i) tenus, PUIS N W (len=0)
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] { M_IDLE, M_PAW, M_PW, M_DONE } mst_e;
    mst_e mst; int unsigned aw_idx, w_idx; logic go;

    always_comb begin
        m_req            = '0;
        m_req.aw.addr    = 64'h9100_0000;
        m_req.aw.id      = aw_idx[ariane_soc::IdWidth-1:0];
        m_req.aw.size    = 3'b011;
        m_req.aw.burst   = axi_pkg::BURST_INCR;
        m_req.aw_valid   = (mst == M_PAW);
        m_req.w.data     = 64'hD00D_0000 + w_idx;
        m_req.w.strb     = 8'hFF;
        m_req.w.last     = 1'b1;
        m_req.w_valid    = (mst == M_PW);
        m_req.b_ready    = 1'b1;
    end

    int unsigned m_b_acc;   // B recus par le maitre = ecritures terminees
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mst<=M_IDLE; aw_idx<=0; w_idx<=0; m_b_acc<=0;
        end else begin
            case (mst)
                M_IDLE: if (go) mst<=M_PAW;
                M_PAW:  if (m_req.aw_valid & m_rsp.aw_ready) begin
                            if (aw_idx+1==N) begin aw_idx<=0; mst<=M_PW; end
                            else aw_idx<=aw_idx+1;
                        end
                M_PW:   if (m_req.w_valid & m_rsp.w_ready) begin
                            if (w_idx+1==N) mst<=M_DONE; else w_idx<=w_idx+1;
                        end
                default: ;
            endcase
            if (m_rsp.b_valid & m_req.b_ready) m_b_acc <= m_b_acc + 1;
        end
    end

    // -------------------------------------------------------------------------
    //  Aval a outstanding-write BORNE (MAXOPEN AW-sans-W), B apres WLAT
    // -------------------------------------------------------------------------
    int unsigned d_open;            // AW acceptes, W-last pas encore recu
    logic [ariane_soc::IdWidth-1:0] bq_id[$];
    int unsigned bhead; logic b_v_q; logic [ariane_soc::IdWidth-1:0] b_id_q;

    always_comb begin
        d_rsp          = '0;
        d_rsp.aw_ready = (d_open < MAXOPEN);
        d_rsp.w_ready  = (d_open > 0);
        d_rsp.b_valid  = b_v_q;
        d_rsp.b.id     = b_id_q;
        d_rsp.b.resp   = axi_pkg::RESP_OKAY;
    end

    logic [ariane_soc::IdWidth-1:0] open_id[$];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_open<=0; open_id.delete(); bq_id.delete(); bhead<=0; b_v_q<=0; b_id_q<='0;
        end else begin
            if (d_req.aw_valid & d_rsp.aw_ready) begin
                open_id.push_back(d_req.aw.id); d_open<=d_open+1;
            end
            if (d_req.w_valid & d_rsp.w_ready & d_req.w.last) begin
                automatic logic [ariane_soc::IdWidth-1:0] wid = open_id.pop_front();
                d_open<=d_open-1; bq_id.push_back(wid);
            end
            if (!b_v_q && bq_id.size()!=0 && bhead!=0) bhead<=bhead-1;
            if (!b_v_q && bq_id.size()!=0 && bhead==0) begin b_v_q<=1; b_id_q<=bq_id[0]; end
            if (b_v_q && d_req.b_ready) begin
                void'(bq_id.pop_front()); b_v_q<=0; bhead<=WLAT;
            end
        end
    end

    // -------------------------------------------------------------------------
    //  Sequence + verdict
    // -------------------------------------------------------------------------
    int unsigned cyc, last_prog, prev;
    initial begin
        void'($value$plusargs("N=%d",N)); void'($value$plusargs("MAXOPEN=%d",MAXOPEN));
        void'($value$plusargs("WLAT=%d",WLAT));
        go=0; rst_n=0; repeat(8) @(posedge clk); rst_n=1; repeat(3) @(posedge clk);
`ifdef PACER
        $display("### tb_pacer N=%0d MAXOPEN=%0d : AVEC pacer (correctif A)", N, MAXOPEN);
`else
        $display("### tb_pacer N=%0d MAXOPEN=%0d : SANS pacer", N, MAXOPEN);
`endif
        go=1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cyc<=0; last_prog<=0; prev<=0; end
        else begin
            cyc<=cyc+1;
            if (m_b_acc != prev) begin prev<=m_b_acc; last_prog<=cyc; end
            if (mst==M_DONE && m_b_acc==N) begin
                $display("### OK    N=%0d MAXOPEN=%0d : %0d ecritures terminees (cyc=%0d)", N, MAXOPEN, N, cyc);
                $finish;
            end
            if (mst!=M_IDLE && (cyc-last_prog)>TIMEOUT) begin
                $display("### WEDGE N=%0d MAXOPEN=%0d : gel (m_b=%0d/%0d, d_open=%0d, cyc=%0d)",
                         N, MAXOPEN, m_b_acc, N, d_open, cyc);
                $finish;
            end
        end
    end
endmodule
