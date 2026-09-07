module request_flow_monitor #(
    parameter WINDOW_CYCLES = 1024,
    parameter MAX_REQ_PER_WINDOW = 64,
    parameter BLOCK_CYCLES = 20,
    parameter type req_iommu_t = logic,
    parameter type resp_slv_t = logic

)(
    input  logic        clk_i,
    input  logic        rst_ni,

    // Incoming request 
    input req_iommu_t   req_IP_wrapper_i,
    input resp_slv_t    resp_wrapper_iommu_i,

    // Garde de legitimite. Quand un device_id est banni, request_manager masque
    // aw/ar vers l'IOMMU. Mais l'IP continue d'asserter aw_valid/ar_valid et
    // l'IOMMU, au repos, maintient aw_ready/ar_ready hauts : le handshake brut
    // est alors vrai a chaque cycle alors qu'aucune requete ne circule. Le
    // compteur d'outstanding, qui reutilise req_fire, explose en 16 cycles et
    // declenche un faux OUTS sur chaque tentative de spoof. On exige donc
    // legit_hit_i pour ne compter que les requetes reellement emises.
    input  logic        legit_hit_i,

    // Outputs
    output logic        storm_flag,
    output logic        block_req,
    output logic        req_fire        // signal injected in proceeding modules 
);
    // =========================================================================
    //  Comptage : UN front montant de handshake = UNE requete.
    //
    //  La version precedente comptait « handshake ET (premiere requete OU
    //  changement d'ID) », avec aw_id_prev/ar_id_prev declares sur 1 bit alors
    //  que aw.id/ar.id en font plusieurs. La sauvegarde tronquait donc l'ID au
    //  bit 0 et la comparaison etait quasi toujours vraie : req_fire montait a
    //  chaque cycle de handshake, le seuil etait franchi par une seule lecture
    //  legitime et tout le trafic sain etait marque storm.
    //
    //  Le comptage par identifiant est de toute facon inadapte a ces
    //  scenarios : l'attaque storm emet ses ecritures avec un id constant (la
    //  boucle RESP -> ADDR de l'accelerateur ne repasse pas par IDLE), donc un
    //  comptage par-ID ne verrait qu'une requete et manquerait l'attaque ; et
    //  la detection d'outstanding repose sur plusieurs requetes vues sur un
    //  ar_valid maintenu, qu'un comptage par-ID sous-compterait.
    //
    //  Le front montant du handshake compte une fois par transfert AXI reel,
    //  independamment de l'ID : le storm mono-ID reste detecte et une lecture
    //  legitime ne compte qu'une fois.
    // =========================================================================
    logic aw_prev,      ar_prev;
    logic aw_edge,      ar_edge;
    logic aw_handshake, ar_handshake;

    assign aw_handshake = req_IP_wrapper_i.aw_valid && resp_wrapper_iommu_i.aw_ready && legit_hit_i;
    assign ar_handshake = req_IP_wrapper_i.ar_valid && resp_wrapper_iommu_i.ar_ready && legit_hit_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_prev <= 1'b0;
            ar_prev <= 1'b0;
        end else begin
            aw_prev <= aw_handshake;
            ar_prev <= ar_handshake;
        end
    end

    assign aw_edge  = aw_handshake & ~aw_prev;
    assign ar_edge  = ar_handshake & ~ar_prev;
    assign req_fire = aw_edge | ar_edge;


    logic [$clog2(WINDOW_CYCLES):0] window_cnt;
    logic [$clog2(MAX_REQ_PER_WINDOW):0] req_cnt;

    // Sliding window counter
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            window_cnt <= 0;
        end else if(window_cnt == WINDOW_CYCLES-1) begin
            window_cnt <= 0;
        end else begin
            window_cnt <= window_cnt + 1;
        end
    end

    // Count requests in the window

    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            req_cnt <= 0;
        end else if(window_cnt == WINDOW_CYCLES-1) begin
            req_cnt <= 0; // new window
        end else if(req_fire) begin // && req_ready
            req_cnt <= req_cnt + 1;
        end
    end

    assign storm_flag = (req_cnt >= MAX_REQ_PER_WINDOW);
    
    
    // Blocage temporaire

    logic [$clog2(BLOCK_CYCLES):0] block_cnt;
    logic blocking;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            block_cnt <= 0;
            blocking  <= 1'b0;
        end else begin
            if(storm_flag && !blocking) begin
                blocking  <= 1'b1;  // démarrage du blocage
                block_cnt <= 0;
            end else if(blocking) begin
                if(block_cnt == BLOCK_CYCLES-1) begin
                    blocking  <= 1'b0; // fin du blocage
                    block_cnt <= 0;
                end else begin
                    block_cnt <= block_cnt + 1;
                end
            end
        end
    end

    assign block_req = blocking;

endmodule
