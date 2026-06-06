`timescale 1ns / 1ps

`ifndef DMA_ENV_SV
`define DMA_ENV_SV

class dma_env extends uvm_env;
    `uvm_component_utils(dma_env)

    dma_apb_agent          apb_agent;
    dma_axi_mem_agent      mem_agent;
    dma_scoreboard         scoreboard;
    dma_coverage           coverage;
    dma_virtual_sequencer  vsqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Both agents must be ACTIVE:
        //   apb_agent  -> drives CSR writes (psel/penable/pwrite/pwdata)
        //   mem_agent  -> drives the AXI slave (arready, rvalid, awready,
        //                 wready, bvalid).  Without UVM_ACTIVE the driver
        //                 is never constructed, arready stays 0 forever,
        //                 and the DUT FSM stalls on its first descriptor
        //                 fetch -> simulation hangs after "Txn 1/200".
        uvm_config_db #(uvm_active_passive_enum)::set(
            this, "apb_agent", "is_active", UVM_ACTIVE);
        uvm_config_db #(uvm_active_passive_enum)::set(
            this, "mem_agent", "is_active", UVM_ACTIVE);

        apb_agent  = dma_apb_agent::type_id::create("apb_agent", this);
        mem_agent  = dma_axi_mem_agent::type_id::create("mem_agent", this);
        scoreboard = dma_scoreboard::type_id::create("scoreboard", this);
        coverage   = dma_coverage::type_id::create("coverage", this);
        vsqr       = dma_virtual_sequencer::type_id::create("vsqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Connect agents to scoreboard
        apb_agent.ap.connect(scoreboard.apb_imp);
        mem_agent.ap.connect(scoreboard.axi_imp);

        // Pass mem_driver reference to scoreboard for backdoor reads
        // (safe now because mem_agent is UVM_ACTIVE so driver exists)
        scoreboard.mem_driver = mem_agent.driver;

        // Connect APB agent to coverage
        apb_agent.ap.connect(coverage.analysis_export);

        // Connect virtual sequencer to actual sequencers
        vsqr.apb_seqr = apb_agent.sequencer;
        vsqr.axi_seqr = mem_agent.sequencer;
    endfunction
endclass

`endif