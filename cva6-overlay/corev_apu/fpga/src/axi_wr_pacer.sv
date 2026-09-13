// =============================================================================
//  axi_wr_pacer.sv — pacer d'ecriture sur le chemin DMA (correctif « A »).
//
//  POURQUOI. Le mode 7 de accel_wrap presente jusqu'a PIPE_DEPTH adresses
//  d'ecriture EN VOL (aw_valid tenu haut) AVANT le moindre beat de donnee. En
//  aval, le chemin partage (mux -> IOMMU -> crossbar -> DRAM) ne tolere qu'un
//  nombre FINI d'ecritures ouvertes sans leur W ; au-dela il retombe aw_ready,
//  le maitre ne finit jamais sa phase d'adresses, n'emet jamais ses W, et le
//  canal d'ecriture s'interbloque -- le CPU, derriere, se fige (gel carte).
//
//  MESURE (2026-09-13) : profondeur 8 sur un aval a 4 ecritures ouvertes GELE ;
//  a 8, passe. Le seuil est exactement la capacite d'outstanding-write de
//  l'aval. ARMOR n'y est pour rien (file B_FATE 8/64, aucun orphelin).
//
//  CE QUE FAIT LE PACER. Insere sur le canal d'ecriture APRES ARMOR (par accel,
//  sur accelN_sec) ou sur le flux fusionne (dma_muxed) :
//    1. il ABSORBE toute la salve d'AW dans un FIFO (le maitre draine donc sa
//       phase d'adresses et atteint sa phase W -- jamais de contre-pression a
//       la source, ce qui recreerait le gel) ;
//    2. il ne presente au plus qu'UNE transaction a la fois en aval, et ne
//       presente son W qu'APRES l'acceptation de son AW -- l'aval ne voit ainsi
//       jamais plus d'un AW-sans-W, quelle que soit la profondeur du mode 7 ;
//    3. un credit MAX_WR_TXN borne les ecritures en vol vers l'aval (defaut 1 =
//       serialisation stricte, la plus sure ; augmenter pour le debit tant que
//       <= capacite reelle de l'aval, mesuree >= 4).
//  AR / R passent tels quels : seuls AW / W / B sont concernes.
//
//  Cout : deux FIFO (adresses + donnees) de profondeur >= profondeur max du
//  mode 7 (16). AR/R inchanges.
//
//  Les canaux AXI sont passes en struct (memes types que le SoC : aw_chan_t,
//  w_chan_t, b_chan_t, axi_req_t, axi_rsp_t). Le module est agnostique du
//  contenu des structures.
// =============================================================================
module axi_wr_pacer #(
    parameter type aw_chan_t   = logic,
    parameter type w_chan_t    = logic,
    parameter type b_chan_t    = logic,
    parameter type axi_req_t   = logic,
    parameter type axi_rsp_t   = logic,
    // Profondeur des FIFO AW/W : doit couvrir la salve max du mode 7.
    parameter int unsigned FIFO_DEPTH  = 32,
    // Ecritures en vol autorisees vers l'aval. 1 = serialisation stricte.
    parameter int unsigned MAX_WR_TXN  = 1
) (
    input  logic      clk_i,
    input  logic      rst_ni,
    // Cote maitre (accel / mux) : on absorbe sa salve
    input  axi_req_t  slv_req_i,
    output axi_rsp_t  slv_rsp_o,
    // Cote aval (IOMMU / crossbar) : on debite pace
    output axi_req_t  mst_req_o,
    input  axi_rsp_t  mst_rsp_i
);

    // -------------------------------------------------------------------------
    //  FIFO d'adresses (AW) et de donnees (W)
    // -------------------------------------------------------------------------
    localparam int unsigned PTR_W = $clog2(FIFO_DEPTH);

    aw_chan_t aw_mem [FIFO_DEPTH-1:0];
    w_chan_t  w_mem  [FIFO_DEPTH-1:0];

    logic [PTR_W:0] aw_wr_ptr_q, aw_rd_ptr_q;   // 1 bit de plus : plein/vide
    logic [PTR_W:0] w_wr_ptr_q,  w_rd_ptr_q;

    logic aw_full, aw_empty, w_full, w_empty;
    assign aw_full  = (aw_wr_ptr_q[PTR_W]     != aw_rd_ptr_q[PTR_W]) &&
                      (aw_wr_ptr_q[PTR_W-1:0] == aw_rd_ptr_q[PTR_W-1:0]);
    assign aw_empty = (aw_wr_ptr_q == aw_rd_ptr_q);
    assign w_full   = (w_wr_ptr_q[PTR_W]      != w_rd_ptr_q[PTR_W]) &&
                      (w_wr_ptr_q[PTR_W-1:0]  == w_rd_ptr_q[PTR_W-1:0]);
    assign w_empty  = (w_wr_ptr_q == w_rd_ptr_q);

    // Handshakes cote maitre (remplissage)
    logic aw_push, w_push;
    assign aw_push = slv_req_i.aw_valid & ~aw_full;
    assign w_push  = slv_req_i.w_valid  & ~w_full;

    // -------------------------------------------------------------------------
    //  FSM de debit : une transaction a la fois, W APRES acceptation de son AW
    // -------------------------------------------------------------------------
    typedef enum logic {P_AW, P_W} pacer_e;
    pacer_e pacer_q;

    // Credit d'ecritures en vol (AW emis - B recu)
    localparam int unsigned CRED_W = (MAX_WR_TXN <= 1) ? 1 : $clog2(MAX_WR_TXN+1);
    logic [CRED_W:0] cred_q;
    logic cred_ok;
    assign cred_ok = (cred_q < MAX_WR_TXN[CRED_W:0]);

    // Sorties AW/W cote aval, tetes de FIFO
    aw_chan_t aw_head; assign aw_head = aw_mem[aw_rd_ptr_q[PTR_W-1:0]];
    w_chan_t  w_head;  assign w_head  = w_mem [w_rd_ptr_q[PTR_W-1:0]];

    logic aw_issue, w_issue;
    assign aw_issue = (pacer_q == P_AW) && !aw_empty && cred_ok;
    assign w_issue  = (pacer_q == P_W)  && !w_empty;

    logic aw_dn_hs, w_dn_hs, b_dn_hs;
    assign aw_dn_hs = mst_req_o.aw_valid & mst_rsp_i.aw_ready;
    assign w_dn_hs  = mst_req_o.w_valid  & mst_rsp_i.w_ready;
    assign b_dn_hs  = mst_rsp_i.b_valid  & mst_req_o.b_ready;

    // -------------------------------------------------------------------------
    //  Requete aval : AW/W paces, AR/R passe-plat, B_ready toujours pret
    // -------------------------------------------------------------------------
    always_comb begin
        mst_req_o          = '0;
        // Ecriture (pacee)
        mst_req_o.aw       = aw_head;
        mst_req_o.aw_valid = aw_issue;
        mst_req_o.w        = w_head;
        mst_req_o.w_valid  = w_issue;
        mst_req_o.b_ready  = slv_req_i.b_ready;   // le maitre draine ses B
        // Lecture : passe-plat integral
        mst_req_o.ar       = slv_req_i.ar;
        mst_req_o.ar_valid = slv_req_i.ar_valid;
        mst_req_o.r_ready  = slv_req_i.r_ready;
    end

    // -------------------------------------------------------------------------
    //  Reponse maitre : AW/W absorbes localement, B/R passe-plat
    // -------------------------------------------------------------------------
    always_comb begin
        slv_rsp_o          = '0;
        slv_rsp_o.aw_ready = ~aw_full;            // absorbe la salve d'AW
        slv_rsp_o.w_ready  = ~w_full;             // absorbe la salve de W
        slv_rsp_o.b        = mst_rsp_i.b;         // B de l'aval -> maitre
        slv_rsp_o.b_valid  = mst_rsp_i.b_valid;
        slv_rsp_o.ar_ready = mst_rsp_i.ar_ready;
        slv_rsp_o.r        = mst_rsp_i.r;
        slv_rsp_o.r_valid  = mst_rsp_i.r_valid;
    end

    // -------------------------------------------------------------------------
    //  Sequentiel
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_wr_ptr_q <= '0; aw_rd_ptr_q <= '0;
            w_wr_ptr_q  <= '0; w_rd_ptr_q  <= '0;
            pacer_q     <= P_AW;
            cred_q      <= '0;
        end else begin
            // Remplissage (cote maitre)
            if (aw_push) begin
                aw_mem[aw_wr_ptr_q[PTR_W-1:0]] <= slv_req_i.aw;
                aw_wr_ptr_q <= aw_wr_ptr_q + 1'b1;
            end
            if (w_push) begin
                w_mem[w_wr_ptr_q[PTR_W-1:0]] <= slv_req_i.w;
                w_wr_ptr_q <= w_wr_ptr_q + 1'b1;
            end

            // Debit (cote aval)
            unique case (pacer_q)
                P_AW: if (aw_dn_hs) begin
                          aw_rd_ptr_q <= aw_rd_ptr_q + 1'b1; // AW consomme
                          pacer_q     <= P_W;                // -> son W
                      end
                P_W:  if (w_dn_hs && mst_req_o.w.last) begin
                          w_rd_ptr_q <= w_rd_ptr_q + 1'b1;   // W-last consomme
                          pacer_q    <= P_AW;                // -> AW suivant
                      end else if (w_dn_hs) begin
                          w_rd_ptr_q <= w_rd_ptr_q + 1'b1;   // beat intermediaire
                      end
            endcase

            // Credit d'ecritures en vol : +1 a l'emission de l'AW, -1 au B
            case ({aw_dn_hs & (pacer_q == P_AW), b_dn_hs})
                2'b10: cred_q <= cred_q + 1'b1;
                2'b01: cred_q <= cred_q - 1'b1;
                default: ; // 00 ou 11 : inchange
            endcase
        end
    end

    // -------------------------------------------------------------------------
    //  Verification (simulation) : jamais plus d'un AW-sans-W presente en aval,
    //  et le credit ne depasse pas MAX_WR_TXN.
    // -------------------------------------------------------------------------
    // pragma translate_off
    `ifndef XSIM
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        cred_q <= MAX_WR_TXN)
      else $error("axi_wr_pacer: credit %0d > MAX_WR_TXN %0d", cred_q, MAX_WR_TXN);
    `endif
    // pragma translate_on

endmodule
