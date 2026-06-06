`timescale 1ns / 1ps

`ifndef DMA_UVM_PKG_SV
`define DMA_UVM_PKG_SV

package dma_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Sequence item (no dependencies)
    `include "dma_seq_item.sv"

    // AXI mem agent MUST come before APB agent because dma_apb_agent.sv
    // references dma_axi_mem_driver::mem[] (the static shared descriptor
    // memory). Forward references to static class members are not permitted
    // in SystemVerilog - the class must be fully declared first.
    `include "dma_axi_mem_agent.sv"
    `include "dma_apb_agent.sv"

    // Scoreboard
    `include "dma_scoreboard.sv"

    // Coverage
    `include "dma_coverage.sv"

    // Sequences & Virtual Sequencer
    `include "dma_virtual_sequencer.sv"
    `include "dma_sequences.sv"

    // Environment
    `include "dma_env.sv"

    // Tests
    `include "dma_test.sv"

endpackage

`endif