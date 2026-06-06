`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/02/2026 12:00:15 PM
// Design Name: 
// Module Name: dma_interfaces
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


//=============================================================================
// DMA AXI4 Interface
//=============================================================================

`ifndef DMA_AXI_IF_SV
`define DMA_AXI_IF_SV

interface dma_axi_if #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 32,
    parameter ID_WIDTH   = 4
)(
    input logic clk,
    input logic rst_n
);
    // Write Address Channel
    logic [ID_WIDTH-1:0]   awid;
    logic [ADDR_WIDTH-1:0] awaddr;
    logic [7:0]            awlen;
    logic [2:0]            awsize;
    logic [1:0]            awburst;
    logic                  awvalid;
    logic                  awready;

    // Write Data Channel
    logic [DATA_WIDTH-1:0]   wdata;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic                    wlast;
    logic                    wvalid;
    logic                    wready;

    // Write Response Channel
    logic [ID_WIDTH-1:0]   bid;
    logic [1:0]            bresp;
    logic                  bvalid;
    logic                  bready;

    // Read Address Channel
    logic [ID_WIDTH-1:0]   arid;
    logic [ADDR_WIDTH-1:0] araddr;
    logic [7:0]            arlen;
    logic [2:0]            arsize;
    logic [1:0]            arburst;
    logic                  arvalid;
    logic                  arready;

    // Read Data Channel
    logic [ID_WIDTH-1:0]   rid;
    logic [DATA_WIDTH-1:0] rdata;
    logic [1:0]            rresp;
    logic                  rlast;
    logic                  rvalid;
    logic                  rready;

    // Master clocking block (driven by master/DUT)
    clocking master_cb @(posedge clk);
        default input #1step output #1;
        output awid, awaddr, awlen, awsize, awburst, awvalid;
        input  awready;
        output wdata, wstrb, wlast, wvalid;
        input  wready;
        input  bid, bresp, bvalid;
        output bready;
        output arid, araddr, arlen, arsize, arburst, arvalid;
        input  arready;
        input  rid, rdata, rresp, rlast, rvalid;
        output rready;
    endclocking

    // Slave clocking block (driven by memory slave agent)
    clocking slave_cb @(posedge clk);
        default input #0 output #1;
        input  awid, awaddr, awlen, awsize, awburst, awvalid;
        output awready;
        input  wdata, wstrb, wlast, wvalid;
        output wready;
        output bid, bresp, bvalid;
        input  bready;
        input  arid, araddr, arlen, arsize, arburst, arvalid;
        output arready;
        output rid, rdata, rresp, rlast, rvalid;
        input  rready;
    endclocking

    // Monitor clocking block
    clocking monitor_cb @(posedge clk);
        default input #0;
        input awid, awaddr, awlen, awsize, awburst, awvalid, awready;
        input wdata, wstrb, wlast, wvalid, wready;
        input bid, bresp, bvalid, bready;
        input arid, araddr, arlen, arsize, arburst, arvalid, arready;
        input rid, rdata, rresp, rlast, rvalid, rready;
    endclocking

    // Modports
    modport master_mp (
        clocking master_cb,
        input clk, rst_n
    );
    modport slave_mp  (
        clocking slave_cb,
        input clk, rst_n,
        input awid, awaddr, awlen, awsize, awburst, awvalid,
        input wdata, wstrb, wlast, wvalid,
        input bready,
        input arid, araddr, arlen, arsize, arburst, arvalid,
        input rready,
        output awready, wready, bid, bresp, bvalid, arready, rid, rdata, rresp, rlast, rvalid
    );
    modport monitor_mp(
        clocking monitor_cb,
        input clk, rst_n
    );

    //--------------------------------------------------
    // Assertions
    //--------------------------------------------------
    // AXI handshake stability: once valid, must stay until ready
    property p_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (awvalid && !awready) |=> awvalid;
    endproperty
    assert property (p_awvalid_stable) else
        $error("AXI: awvalid deasserted before awready");

    property p_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (arvalid && !arready) |=> arvalid;
    endproperty
    assert property (p_arvalid_stable) else
        $error("AXI: arvalid deasserted before arready");

    property p_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (wvalid && !wready) |=> wvalid;
    endproperty
    assert property (p_wvalid_stable) else
        $error("AXI: wvalid deasserted before wready");

    // No X on valid signals
    property p_no_x_awvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(awvalid);
    endproperty
    assert property (p_no_x_awvalid) else
        $error("AXI: X on awvalid");

endinterface : dma_axi_if


//=============================================================================
// DMA APB Interface (CSR access)
//=============================================================================
interface dma_apb_if (
    input logic clk,
    input logic rst_n
);
    logic [11:0] paddr;
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;

    clocking master_cb @(posedge clk);
        default input #1step output #1;
        output paddr, psel, penable, pwrite, pwdata;
        input  prdata, pready, pslverr;
    endclocking

    clocking monitor_cb @(posedge clk);
        default input #0;
        input paddr, psel, penable, pwrite, pwdata, prdata, pready, pslverr;
    endclocking

    modport master_mp (clocking master_cb, input clk, rst_n);
    modport monitor_mp(clocking monitor_cb,input clk, rst_n);

endinterface : dma_apb_if


//=============================================================================
// DMA Interrupt/Status Interface
//=============================================================================
interface dma_irq_if #(parameter NUM_CHANNELS = 4)(
    input logic clk,
    input logic rst_n
);
    logic [NUM_CHANNELS-1:0] irq;
    logic [NUM_CHANNELS-1:0] ch_active;
    logic                    dma_busy;

    clocking monitor_cb @(posedge clk);
        default input #0;
        input irq, ch_active, dma_busy;
    endclocking
endinterface : dma_irq_if

`endif
