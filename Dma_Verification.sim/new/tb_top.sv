`timescale 1ns / 1ps

module tb_top;

    import uvm_pkg::*;
    import dma_uvm_pkg::*;

    // Change this string to run a specific directed test without relying on
    // Vivado/XSim command-line plusarg forwarding.
string selected_test = "dma_all_test";

    // Clock and Reset
    logic clk;
    logic rst_n;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    initial begin
        rst_n = 0;
        #20 rst_n = 1;
    end

    // Interfaces
    dma_axi_if axi_if(.clk(clk), .rst_n(rst_n));
    dma_apb_if apb_if(.clk(clk), .rst_n(rst_n));
    dma_irq_if irq_if(.clk(clk), .rst_n(rst_n));

    // DUT Instantiation
    dma_engine dut (
        .clk(clk),
        .rst_n(rst_n),

        // APB
        .paddr(apb_if.paddr),
        .psel(apb_if.psel),
        .penable(apb_if.penable),
        .pwrite(apb_if.pwrite),
        .pwdata(apb_if.pwdata),
        .prdata(apb_if.prdata),
        .pready(apb_if.pready),
        .pslverr(apb_if.pslverr),

        // AXI
        .awid(axi_if.awid),
        .awaddr(axi_if.awaddr),
        .awlen(axi_if.awlen),
        .awsize(axi_if.awsize),
        .awburst(axi_if.awburst),
        .awvalid(axi_if.awvalid),
        .awready(axi_if.awready),
        .wdata(axi_if.wdata),
        .wstrb(axi_if.wstrb),
        .wlast(axi_if.wlast),
        .wvalid(axi_if.wvalid),
        .wready(axi_if.wready),
        .bid(axi_if.bid),
        .bresp(axi_if.bresp),
        .bvalid(axi_if.bvalid),
        .bready(axi_if.bready),
        .arid(axi_if.arid),
        .araddr(axi_if.araddr),
        .arlen(axi_if.arlen),
        .arsize(axi_if.arsize),
        .arburst(axi_if.arburst),
        .arvalid(axi_if.arvalid),
        .arready(axi_if.arready),
        .rid(axi_if.rid),
        .rdata(axi_if.rdata),
        .rresp(axi_if.rresp),
        .rlast(axi_if.rlast),
        .rvalid(axi_if.rvalid),
        .rready(axi_if.rready),

        // Interrupts
        .irq(irq_if.irq),
        .ch_active(irq_if.ch_active),
        .dma_busy(irq_if.dma_busy)
    );

    initial begin
        // Set interfaces in config_db
        uvm_config_db#(virtual dma_axi_if)::set(null, "*", "axi_vif", axi_if);
        uvm_config_db#(virtual dma_apb_if)::set(null, "*", "apb_vif", apb_if);
        uvm_config_db#(virtual dma_irq_if)::set(null, "*", "irq_vif", irq_if);

        // Run the test
        $display("TB_TOP: Running UVM test '%s'", selected_test);
        run_test(selected_test);
    end

    // Dump waveforms
    initial begin
        if ($test$plusargs("DMA_DUMP_VCD")) begin
            $dumpfile("dma_dump.vcd");
            $dumpvars(0, tb_top);
        end
    end

endmodule
