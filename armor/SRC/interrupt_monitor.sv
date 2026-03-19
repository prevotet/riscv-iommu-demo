`timescale 1ns/1ps

module interrupt_monitor #(
    parameter int unsigned WINDOW_CYCLES      = 1024,
    parameter int unsigned MAX_MSI_PER_WINDOW = 32,
    parameter int unsigned MAX_RATIO_MSI_DMA  = 2
)(
    input  logic clk_i,
    input  logic rst_ni,

    // From msi_detector
    input  logic comparison_valid,
    input  logic is_msi_interrupt,
    input  logic is_dma,

    // Outputs
    output logic msi_storm,
    output logic block_msi
);

    // One-cycle events
    logic msi_fire;
    logic dma_fire;

    assign msi_fire = comparison_valid && is_msi_interrupt;
    assign dma_fire = comparison_valid && is_dma;

    logic [$clog2(WINDOW_CYCLES):0]      window_cnt;
    logic [$clog2(MAX_MSI_PER_WINDOW):0] msi_cnt;
    logic [$clog2(MAX_MSI_PER_WINDOW):0] dma_cnt;

    // Sliding time window
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            window_cnt <= '0;
        else if (window_cnt == WINDOW_CYCLES-1)
            window_cnt <= '0;
        else
            window_cnt <= window_cnt + 1;
    end

    // Count MSI and DMA events
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            msi_cnt <= '0;
            dma_cnt <= '0;
        end
        else if (window_cnt == WINDOW_CYCLES-1) begin
            msi_cnt <= '0;
            dma_cnt <= '0;
        end
        else begin
            if (msi_fire) msi_cnt <= msi_cnt + 1;
            if (dma_fire) dma_cnt <= dma_cnt + 1;
        end
    end

    // Storm detection (paper logic)
    assign msi_storm =
        (msi_cnt >= MAX_MSI_PER_WINDOW) ||
        ((dma_cnt != 0) && (msi_cnt >= MAX_RATIO_MSI_DMA * dma_cnt));

    assign block_msi = msi_storm;

endmodule
