`timescale 1ns / 1ps

`ifndef DMA_VIRTUAL_SEQUENCER_SV
`define DMA_VIRTUAL_SEQUENCER_SV

//=============================================================================
// DMA Virtual Sequencer
// FIX: Removed dead `weight_align` field - it was declared here but never
//      read by anything. dma_sequences.sv references `weight_misalign`
//      (which IS present). Having the dead field caused confusion about
//      which weight controlled aligned vs misaligned stimulus.
//=============================================================================
class dma_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(dma_virtual_sequencer)

    dma_apb_sequencer     apb_seqr;
    dma_axi_mem_sequencer axi_seqr;
    virtual dma_irq_if    irq_vif;

    // Weights for adaptive stimulus (used by dma_adaptive_virtual_seq dist)
    int weight_sg_len_1  = 10;
    int weight_sg_len_16 = 10;
    int weight_misalign  = 10;  // was: weight_align (dead) + weight_misalign
    int weight_no_err    = 20;
    int weight_err       = 5;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual dma_irq_if)::get(this, "", "irq_vif", irq_vif))
            `uvm_fatal("CFG", "irq_vif not set")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            #10000ns;
            update_weights();
        end
    endtask

    function void update_weights();
        // Increase corner-case weights over time to drive coverage closure
        weight_sg_len_16 = weight_sg_len_16 + 5;
        weight_misalign  = weight_misalign  + 5;
        weight_err       = weight_err       + 2;
    endfunction

endclass

`endif
