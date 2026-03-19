`timescale 1ns/1ps
`include "axi_types.sv"
import axi_types::*;

module wrapper_testbench1;

  // Paramètres
  localparam int IdWidth      = 4;
  localparam int IdWidthSlv   = 6;
  localparam int AddrWidth    = 64;
  localparam int UserWidth    = 1;
  localparam int DevIDWidth   = 24;
  localparam int ProcIDWidth  = 20;
  localparam int DataWidth    = 64;
  localparam int StrbWidth    = DataWidth / 8;
  localparam int N_REQUESTS   = 100; 


  // Clock & reset
  logic clk;
  logic rst_ni;

  // Interfaces
  axi_types::req_iommu_t  req_ip_to_wrapper;
  axi_types::resp_t       resp_ip_from_wrapper;

  axi_types::req_iommu_t  req_wrapper_to_iommu;
  axi_types::resp_t       resp_wrapper_iommu;

  axi_types::req_slv_t    req_cpu_to_wrapper;
  axi_types::resp_slv_t   resp_cpu_from_wrapper;

  // Clock generation
  always #5 clk = ~clk;

  // Tableau des IDs à envoyer
  //logic [DevIDWidth-1:0] request_ids[N_REQUESTS-1:0];
  //initial begin
  //  request_ids[1] = 24'h123456;
  //  request_ids[2] = 24'h123456;
  //  request_ids[3] = 24'h123456;
  //  request_ids[4] = 24'hCCCCCC;
  //end

  // DUT instantiation
  wrapper #(
    .IdWidth(IdWidth),
    .IdWidthSlv(IdWidthSlv),
    .AddrWidth(AddrWidth),
    .UserWidth(UserWidth),
    .DevIDWidth(DevIDWidth),
    .ProcIDWidth(ProcIDWidth),
    .DataWidth(DataWidth),
    .StrbWidth(StrbWidth)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst_ni),
    .req_IP_wrapper_i(req_ip_to_wrapper),
    .resp_IP_wrapper_o(resp_ip_from_wrapper),
    .req_wrapper_iommu_o(req_wrapper_to_iommu),
    .resp_wrapper_iommu_i(resp_wrapper_iommu),
    .req_CPU_Wrapper__i(req_cpu_to_wrapper),
    .resp_CPU_Wrapper_o(resp_cpu_from_wrapper)
  );

  // Initialisation de l'ID fixe
  initial dut.fixed_ID_reg = 24'h123456;

  // Instanciation du générateur de requêtes
  request_generator #(
    .NUM_REQS(N_REQUESTS),
    .DEV_ID_WIDTH(DevIDWidth)
  ) gen_req (
    .clk_i(clk),
    .rst_ni(rst_ni),
    .aw_ready_i(resp_ip_from_wrapper.aw_ready), // depuis le wrapper → IOMMU
    .w_ready_i(resp_ip_from_wrapper.w_ready),
    .b_valid_i(resp_ip_from_wrapper.b_valid),
    .req_o(req_ip_to_wrapper)

  );

  // Reset et initialisation
  initial begin
    clk = 0;
    rst_ni = 0;
    //req_wrapper_to_iommu = '0;
    resp_wrapper_iommu = '0;
    req_cpu_to_wrapper = '0;
    #20 rst_ni = 1;
  end

  // Séquence d'observation des requêtes et du blocage
  initial begin
    #50; // Attendre que la FSM commence

    for (int i = 0; i < N_REQUESTS; i++) begin
      // Attendre que la requête AW soit valide
      wait(req_wrapper_to_iommu.aw_valid);
      $display("Cycle %0t: Requête %0d AW transmise ! addr=0x%h, stream_id=0x%h", $time, i,
               req_wrapper_to_iommu.aw.addr, req_wrapper_to_iommu.aw.aw_stream_id_o);
      
      // IOMMU accepte AW
      resp_wrapper_iommu.aw_ready = 1;
      repeat (5) @(posedge clk);
      resp_wrapper_iommu.aw_ready = 0;

      // Attendre W valide
      wait(req_wrapper_to_iommu.w_valid);
      $display("Cycle %0t: Requête %0d W transmise ! w_data=0x%h", $time, i, req_wrapper_to_iommu.w.w_data);
      
      // IOMMU accepte W
      resp_wrapper_iommu.w_ready = 1;
      repeat (5) @(posedge clk);
      resp_wrapper_iommu.w_ready = 0;

      // Envoyer B response
      resp_wrapper_iommu.b.b_id   = req_wrapper_to_iommu.aw.id;
      resp_wrapper_iommu.b.b_resp = 2'b01; // EXOKAY exclusive access (juste pour se différencier de OKAY qui reste à 0)
      resp_wrapper_iommu.b_valid  = 1;
      // attendre le handshake b_valid && b_ready
      wait (resp_wrapper_iommu.b_valid && req_ip_to_wrapper.b_ready);
      repeat (5) @(posedge clk);

      // Attendre que IP accepte le B
      //wait(req_ip_to_wrapper.b_ready);
      resp_wrapper_iommu.b_valid = 0;
      $display("t=%0t: resp_ip_from_wrapper: aw_ready=%b w_ready=%b b_valid=%b | req_ip_to_wrapper.b_ready=%b",
         $time, resp_ip_from_wrapper.aw_ready, resp_ip_from_wrapper.w_ready, resp_ip_from_wrapper.b_valid, req_ip_to_wrapper.b_ready);


      // Vérifier blocage
      if (dut.block_ip_o)
        $display("Cycle %0t: ⚠️ Blocage actif après requête %0d", $time, i);
      else
        $display("Cycle %0t: Pas de blocage après requête %0d", $time, i);

      //// Petit délai avant la prochaine requête
      //@(posedge clk);

      // Attendre que la comparaison soit terminée avant d’envoyer la prochaine
        //wait(!dut.comparison_valid);
        repeat (20) @(posedge clk); // marge de sécurité
    end
  end

endmodule
