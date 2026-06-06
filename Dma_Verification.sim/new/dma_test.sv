`timescale 1ns / 1ps

`ifndef DMA_TEST_SV
`define DMA_TEST_SV

class dma_base_test extends uvm_test;
    `uvm_component_utils(dma_base_test)

    dma_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = dma_env::type_id::create("env", this);
    endfunction

    // Timeout budget:
    // Worst case per txn = 500us (sg_len=16)
    // 200 txns x 500us = 100ms + margin = 150ms
    function void end_of_elaboration_phase(uvm_phase phase);
        uvm_top.set_timeout(150ms);
    endfunction
endclass

class dma_adaptive_stress_test extends dma_base_test;
    `uvm_component_utils(dma_adaptive_stress_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        dma_adaptive_virtual_seq vseq;
        uvm_cmdline_processor    clp;
        string                   txn_arg;
        int                      num_txns_cfg;

        phase.raise_objection(this);

        vseq = dma_adaptive_virtual_seq::type_id::create("vseq");
        clp = uvm_cmdline_processor::get_inst();
        num_txns_cfg = 25;
        if (clp.get_arg_value("+DMA_NUM_TXNS=", txn_arg))
            num_txns_cfg = txn_arg.atoi();
        vseq.num_txns = num_txns_cfg;
        `uvm_info("TEST", $sformatf("Running %0d adaptive transactions", vseq.num_txns), UVM_LOW)
        vseq.start(env.vsqr);

        // Allow last transfer and IRQ to settle
        #10000ns;

        phase.drop_objection(this);
    endtask
endclass

class dma_directed_base_test extends dma_base_test;
    `uvm_component_utils(dma_directed_base_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_one_sequence(uvm_phase phase);
    endtask

    task wait_for_dma_idle();
        int unsigned cycles;
        bit          seen_busy;

        cycles    = 0;
        seen_busy = (env.vsqr.irq_vif.monitor_cb.dma_busy === 1'b1);

        while (cycles < 50000) begin
            @(env.vsqr.irq_vif.monitor_cb);

            if (env.vsqr.irq_vif.monitor_cb.dma_busy === 1'b1)
                seen_busy = 1'b1;

            if (seen_busy && env.vsqr.irq_vif.monitor_cb.dma_busy === 1'b0)
                return;

            cycles++;
        end

        `uvm_error("TEST", "Directed test timed out waiting for dma_busy to return idle")
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        run_one_sequence(phase);
        wait_for_dma_idle();
        #1000ns;
        phase.drop_objection(this);
    endtask
endclass

class dma_directed_single_desc_test extends dma_directed_base_test;
    `uvm_component_utils(dma_directed_single_desc_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_one_sequence(uvm_phase phase);
        dma_directed_single_desc_seq seq;
        seq = dma_directed_single_desc_seq::type_id::create("seq");
        `uvm_info("TEST", "Running directed aligned single-descriptor transfer", UVM_LOW)
        seq.start(env.apb_agent.sequencer);
    endtask
endclass

class dma_directed_multi_burst_test extends dma_directed_base_test;
    `uvm_component_utils(dma_directed_multi_burst_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_one_sequence(uvm_phase phase);
        dma_directed_multi_burst_seq seq;
        seq = dma_directed_multi_burst_seq::type_id::create("seq");
        `uvm_info("TEST", "Running directed aligned multi-burst single-descriptor transfer", UVM_LOW)
        seq.start(env.apb_agent.sequencer);
    endtask
endclass

class dma_directed_sg16_test extends dma_directed_base_test;
    `uvm_component_utils(dma_directed_sg16_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_one_sequence(uvm_phase phase);
        dma_directed_sg16_seq seq;
        seq = dma_directed_sg16_seq::type_id::create("seq");
        `uvm_info("TEST", "Running directed SG=16 aligned transfer", UVM_LOW)
        seq.start(env.apb_agent.sequencer);
    endtask
endclass

class dma_directed_misalign_test extends dma_directed_base_test;
    `uvm_component_utils(dma_directed_misalign_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_one_sequence(uvm_phase phase);
        dma_directed_misalign_seq seq;
        seq = dma_directed_misalign_seq::type_id::create("seq");
        `uvm_info("TEST", "Running directed misaligned transfer", UVM_LOW)
        seq.start(env.apb_agent.sequencer);
    endtask
endclass

class dma_directed_repro_fail_test extends dma_directed_base_test;
    `uvm_component_utils(dma_directed_repro_fail_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_one_sequence(uvm_phase phase);
        dma_directed_repro_fail_seq seq;
        seq = dma_directed_repro_fail_seq::type_id::create("seq");
        `uvm_info("TEST", "Running exact repro of the remaining adaptive stress failure", UVM_LOW)
        seq.start(env.apb_agent.sequencer);
    endtask
endclass

class dma_all_test extends dma_directed_base_test;
    `uvm_component_utils(dma_all_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        dma_directed_single_desc_seq seq1;
        dma_directed_multi_burst_seq seq2;
        dma_directed_sg16_seq seq3;
        dma_directed_misalign_seq seq4;
        dma_directed_repro_fail_seq seq5;
        dma_adaptive_virtual_seq vseq;
        uvm_cmdline_processor clp;
        string txn_arg;
        int num_txns_cfg;

        phase.raise_objection(this);

        `uvm_info("TEST", "Running all test cases to reach 100% coverage", UVM_LOW)

        seq1 = dma_directed_single_desc_seq::type_id::create("seq1");
        seq1.start(env.apb_agent.sequencer);
        wait_for_dma_idle();

        seq2 = dma_directed_multi_burst_seq::type_id::create("seq2");
        seq2.start(env.apb_agent.sequencer);
        wait_for_dma_idle();

        seq3 = dma_directed_sg16_seq::type_id::create("seq3");
        seq3.start(env.apb_agent.sequencer);
        wait_for_dma_idle();

        seq4 = dma_directed_misalign_seq::type_id::create("seq4");
        seq4.start(env.apb_agent.sequencer);
        wait_for_dma_idle();

        seq5 = dma_directed_repro_fail_seq::type_id::create("seq5");
        seq5.start(env.apb_agent.sequencer);
        wait_for_dma_idle();

        vseq = dma_adaptive_virtual_seq::type_id::create("vseq");
        clp = uvm_cmdline_processor::get_inst();
        num_txns_cfg = 25;
        if (clp.get_arg_value("+DMA_NUM_TXNS=", txn_arg))
            num_txns_cfg = txn_arg.atoi();
        vseq.num_txns = num_txns_cfg;
        `uvm_info("TEST", $sformatf("Running %0d adaptive transactions", vseq.num_txns), UVM_LOW)
        vseq.start(env.vsqr);

        #10000ns;
        phase.drop_objection(this);
    endtask
endclass

`endif
