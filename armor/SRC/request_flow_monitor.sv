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


    // Outputs
    output logic        storm_flag,
    output logic        block_req,
    output logic        req_fire        // signal injected in proceeding modules 
);
    // Detect VALID rising edges of AW or AR
    logic aw_prev,      ar_prev;
    logic aw_edge,      ar_edge;
    logic aw_handshake, ar_handshake;
    logic aw_id_prev,   ar_id_prev;
    logic aw_id_changed, ar_id_changed;
    logic aw_first_req, ar_first_req;  // Pour gérer la première transaction

    assign aw_handshake = req_IP_wrapper_i.aw_valid && resp_wrapper_iommu_i.aw_ready;
    assign ar_handshake = req_IP_wrapper_i.ar_valid && resp_wrapper_iommu_i.ar_ready;
    

    // Edge detectors
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_prev <= 1'b0;
            ar_prev <= 1'b0;
            aw_first_req  <= 1'b1;
            ar_first_req  <= 1'b1;
        end else begin
            //aw_prev <= req_IP_wrapper_i.aw_valid;
            //ar_prev <= req_IP_wrapper_i.ar_valid;
            //aw_id_prev <= req_IP_wrapper_i.aw.id;  // sauvegardé lors du handshake
            //ar_id_prev <= req_IP_wrapper_i.ar.id;
            if (aw_handshake) begin
                aw_id_prev   <= req_IP_wrapper_i.aw.id;
                aw_first_req <= 1'b0;
            end
            if (ar_handshake) begin
                ar_id_prev   <= req_IP_wrapper_i.ar.ar_id;
                ar_first_req <= 1'b0;
            end
        end
    end

    //assign aw_edge = req_IP_wrapper_i.aw_valid & ~aw_prev;
    //assign ar_edge = req_IP_wrapper_i.ar_valid & ~ar_prev;
    assign aw_id_changed = (req_IP_wrapper_i.aw.id != aw_id_prev);
    assign ar_id_changed = (req_IP_wrapper_i.ar.ar_id != ar_id_prev);



    // A request is fired on a rising edge of AW or AR
    //assign req_fire = aw_edge | ar_edge;
 // Une requête est comptée si : handshake ET (première req OU changement d'ID)
    assign req_fire = (aw_handshake && (aw_first_req || aw_id_changed)) || (ar_handshake && (ar_first_req || ar_id_changed));


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
