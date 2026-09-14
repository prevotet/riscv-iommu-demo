module outs_req_monitor #(
    parameter MAX_OUTSTANDING = 16,
    parameter BLOCK_CYCLES = 10,
    parameter type resp_slv_t = logic,
    parameter type req_iommu_t = logic

)(
    input  logic        clk_i,
    input  logic        rst_ni,

    // Signal réutilisé du request_flow_monitor
    input  logic        req_fire,
    //  Seuil d'en-vol a l'execution. ZERO = MAX_OUTSTANDING (synthese).
    input  logic [7:0]  max_outs_i,

    // Response interface (depuis IOMMU)
    input  resp_slv_t   resp_wrapper_iommu_i,
    input  req_iommu_t  req_IP_wrapper_i,


    // Outputs
    output logic        overflow_flag,
    output logic        block_req,

    // Observabilite pure (aucun effet fonctionnel) : profondeur courante du
    // compteur d'outstanding, remontee aux CSR du wrapper. Sans elle, le seul
    // temoin de la saturation etait `overflow_flag`, un booleen -- impossible de
    // savoir si l'on frole le seuil ou si l'on en est loin, ce qui est
    // exactement la question posee par SC03.
    output logic [7:0]  outstanding_o
);

    // Détection des handshakes de réponses
    logic b_handshake, r_handshake;
    logic resp_complete;

    assign b_handshake  = resp_wrapper_iommu_i.b_valid && req_IP_wrapper_i.b_ready;
    assign r_handshake  = resp_wrapper_iommu_i.r_valid && req_IP_wrapper_i.r_ready && resp_wrapper_iommu_i.r.last;
    assign resp_complete = b_handshake | r_handshake;

    // Compteur de requêtes outstanding
    //  8 bits fixes : le seuil est reglable, le compteur doit porter la plus
    //  grande valeur demandable et non celle de la synthese.
    logic [7:0] outstanding;
    logic [7:0] max_outs_eff;
    assign max_outs_eff = (max_outs_i == 8'h0) ? 8'(MAX_OUTSTANDING) : max_outs_i;

    // Mécanisme de blocage temporaire (déclaré avant le compteur : la fin de
    // blocage purge l'outstanding).
    logic [$clog2(BLOCK_CYCLES):0] block_cnt;
    logic blocking;
    logic blocking_done;

    assign blocking_done = blocking && (block_cnt == BLOCK_CYCLES-1);

    // Purge si le bus est inactif. Le scénario d'attaque outstanding inonde des
    // AR avec r_ready à 0 : ces lectures ne se complètent jamais, le compteur
    // reste saturé et le verdict OUTS colle à tout le trafic qui suit — le
    // trafic MHA légitime héritait ainsi d'un faux positif. Après 255 cycles
    // sans aucune requête ni réponse, on considère le bus au repos et on purge.
    logic [7:0] idle_cnt;
    logic       idle_purge;

    assign idle_purge = (idle_cnt == 8'hFF) && (outstanding != 0);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            outstanding <= 0;
            idle_cnt    <= 0;
        end else if (blocking_done || idle_purge) begin
            outstanding <= 0;
            idle_cnt    <= 0;
        end else begin
            if (!req_fire && !resp_complete)
                idle_cnt <= idle_cnt + 1'b1;
            else
                idle_cnt <= 0;

            case ({req_fire, resp_complete})
                2'b10:   outstanding <= outstanding + 1;                        // nouvelle requête
                2'b01:   outstanding <= (outstanding == 0) ? 0 : outstanding - 1; // réponse reçue
                default: outstanding <= outstanding;                            // 00 ou 11
            endcase
        end
    end

    // Détection de l'overflow
    assign overflow_flag = (outstanding >= max_outs_eff);

    // Extension zero implicite vers 8 bits : `outstanding` est un vecteur non
    // signe de $clog2(MAX+1)+1 bits, soit 6 pour MAX_OUTSTANDING = 16.
    assign outstanding_o = outstanding;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            block_cnt <= 0;
            blocking  <= 1'b0;
        end else begin
            // Meme correctif que request_flow_monitor (2026-09-09) : overflow_flag
            // est un NIVEAU, et se rearmer sur `overflow_flag && !blocking`
            // faisait clignoter le blocage -- BLOCK_CYCLES hauts, un bas, en
            // boucle. En profil BENCH BLOCK_CYCLES vaut 10 : le creux d'un cycle
            // suffit a laisser filer un beat W sans son AW. On tient donc le
            // blocage tant que la saturation dure.
            if (overflow_flag) begin
                blocking  <= 1'b1;
                block_cnt <= 0;
            end else if (blocking) begin
                if (block_cnt == BLOCK_CYCLES-1) begin
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
