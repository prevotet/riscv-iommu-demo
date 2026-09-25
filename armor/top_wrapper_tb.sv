

`include "axi_types.sv"
import axi_types::*;

`timescale 1ns/1ps

module wrapper_testbench;

  // Paramètres de test
  localparam int IdWidth      = 4;
  localparam int IdWidthSlv   = 6;
  localparam int AddrWidth    = 64;
  localparam int UserWidth    = 1;
  localparam int DevIDWidth   = 24;
  localparam int ProcIDWidth  = 20;
  localparam int DataWidth    = 64;
  localparam int StrbWidth    = DataWidth / 8;

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
  initial begin
    dut.fixed_ID_reg = 24'h123456;  // Pas besoin de force
end


  // Initialisation
  initial begin
    clk = 0;
    rst_ni = 0;
    req_ip_to_wrapper = '0;
    resp_wrapper_iommu = '0;
    req_cpu_to_wrapper = '0;

    #20 rst_ni = 1;

    // Attendre un peu
    #10;

    // 🟢 Envoi d'une requête AW valide
    req_ip_to_wrapper.aw_valid             = 1;
    req_ip_to_wrapper.aw.addr              = 64'hDEADBEEF;
    req_ip_to_wrapper.aw.id                = 4'hA;
    req_ip_to_wrapper.aw.len               = 8'd0;
    req_ip_to_wrapper.aw.size              = 3'b010;
    req_ip_to_wrapper.aw.burst             = 2'b01;
    req_ip_to_wrapper.aw.lock              = 0;
    req_ip_to_wrapper.aw.cache             = 4'b0011;
    req_ip_to_wrapper.aw.prot              = 3'b000;
    req_ip_to_wrapper.aw.qos               = 4'b0000;
    req_ip_to_wrapper.aw.region            = 4'b0000;
    req_ip_to_wrapper.aw.atop              = 6'b000000;
    req_ip_to_wrapper.aw.user              = 1'b0;
    req_ip_to_wrapper.aw.aw_stream_id_o = 24'h123456; 
    req_ip_to_wrapper.aw.aw_ss_id_valid_o  = 1'b1;      // Mark substream ID as valid

    

    req_ip_to_wrapper.w_valid              = 1;
    req_ip_to_wrapper.w.w_data             = 64'hCAFEBABECAFEBABE;
    req_ip_to_wrapper.w.w_strb             = 8'hFF;
    req_ip_to_wrapper.w.w_last             = 1;
    req_ip_to_wrapper.w.w_user             = 0;
      
    req_ip_to_wrapper.b_ready              = 1;
      
    // Pas besoin de AR pour ce test     
    req_ip_to_wrapper.ar_valid             = 0;
    req_ip_to_wrapper.r_ready              = 0;

    // Attente pour propagation
    #20;
    
    @(posedge clk);  // 🔹 attendre le front d’horloge pour que la valeur soit capturée

    // Observation
    $display("Device_ID_o                  = 0x%h", dut.Device_ID_o);
    $display("fixed_ID_reg                 = 0x%h", dut.fixed_ID_reg);
    $display("req_wrapper_to_iommu.aw.addr      = 0x%h", req_wrapper_to_iommu.aw.addr);
    $display("req_wrapper_to_iommu.aw_valid     = %0b", req_wrapper_to_iommu.aw_valid);
    $display("req_wrapper_to_iommu.w.w_data     = 0x%h", req_wrapper_to_iommu.w.w_data);
    $display("req_wrapper_to_iommu.w_valid      = %0b", req_wrapper_to_iommu.w_valid);


    // Boucle pour observer la requête sur plusieurs cycles


  for (int i = 0; i < 5; i++) begin
    @(posedge clk);
    if (req_wrapper_to_iommu.aw_valid)
        $display("Cycle %0d: Requête transmise ! aw.addr=0x%h", i, req_wrapper_to_iommu.aw.addr);
    else
        $display("Cycle %0d: Requête pas encore transmise", i);
  end



  // Boucle pour observer le blocage sur plusieurs cycles
for (int i = 0; i < 10; i++) begin
  @(posedge clk);
  if (dut.block_ip_o)
      $display("Cycle %0d: ⚠️ Blocage actif !", i);
  else
      $display("Cycle %0d: Pas de blocage", i);
end


end

    // Vérification (tu peux faire mieux avec assertions)
    //if (req_wrapper_to_iommu.aw_valid && req_wrapper_to_iommu.aw.addr == 64'hDEADBEEF)
    //  $display("Requête transmise correctement !");
    //else
    //  $display(" Problème de transmission.");
//
    //#50 $finish;
  //end

  // Forçage du legit_hit dans le DUT
  // Cela suppose que la variable interne "legit_hit" est exposée ou forçable
  initial begin
    force dut.block_ip_o = 0;
  end

  initial begin
    // Initialize IOMMU response signals
    resp_wrapper_iommu = '0;
  
    // Wait until DUT drives a valid request
    @(posedge clk);
    wait(req_wrapper_to_iommu.aw_valid); 
  
    // Emulate IOMMU ready to accept AW
    resp_wrapper_iommu.aw_ready = 1;
    @(posedge clk);
    resp_wrapper_iommu.aw_ready = 0;
  
    // Wait for W data
    wait(req_wrapper_to_iommu.w_valid);
    resp_wrapper_iommu.w_ready = 1;
    @(posedge clk);
    resp_wrapper_iommu.w_ready = 0;
  
    // After data is accepted, send a B response
    resp_wrapper_iommu.b.b_id   = req_wrapper_to_iommu.aw.id;
    resp_wrapper_iommu.b.b_resp = 2'b00; // OKAY response
    resp_wrapper_iommu.b_valid  = 1;
  
    @(posedge clk);
    wait(req_ip_to_wrapper.b_ready); // Wait for wrapper to accept response
    resp_wrapper_iommu.b_valid = 0;
  
    // For Read Transactions (optional)
    // Similar logic but handle AR and R channels
  end

endmodule