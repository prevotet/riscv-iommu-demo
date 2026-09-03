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
    output  resp_slv_t      resp_CPU_Wrapper_o




    
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


assign block_req_i = block_ip_o | block_req_flow| block_req_outs| block_msi;



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



request_manager #(
    .req_iommu_t(req_iommu_t)
)request_manager_module(
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .legit_hit(legit_hit),
    .req_IP_wrapper_i(req_IP_wrapper_i),
    .block_req_i(block_req_i),      // signal combiné
    .req_wrapper_iommu_o(req_wrapper_iommu_o)

);

response_manager #(
    .resp_slv_t(resp_slv_t)
) response_manager_module (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .block_req_i(block_req_i),
    .block_ip_i(block_ip_o),
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
    .storm_flag(storm_flag),
    .block_req(block_req_flow),
    .req_fire(req_fire_signal) 

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
    .block_req(block_req_outs)
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


endmodule