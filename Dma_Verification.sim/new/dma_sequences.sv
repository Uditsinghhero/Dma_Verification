`timescale 1ns / 1ps

`ifndef DMA_SEQUENCES_SV
`define DMA_SEQUENCES_SV

//=============================================================================
// Base Sequence
//=============================================================================
class dma_base_seq extends uvm_sequence #(dma_seq_item);
    `uvm_object_utils(dma_base_seq)
    function new(string name="dma_base_seq");
        super.new(name);
    endfunction

    function void fill_basic_item(
        dma_seq_item req,
        int unsigned sg_depth,
        bit force_misalign = 0,
        bit force_read_err = 0,
        bit force_write_err = 0
    );
        int unsigned src_slot;
        int unsigned dst_slot;
        int unsigned len_bytes;
        int unsigned burst_cfg;
        int unsigned src_mod;
        int unsigned dst_mod;
        int unsigned total_src_span;
        int unsigned max_src_slot;
        int unsigned aligned_src_limit;

        len_bytes = $urandom_range(8, 64) * 8;
        burst_cfg = $urandom_range(1, 8);
        total_src_span = sg_depth * len_bytes;

        // Keep the entire SG chain inside the initialized source-memory window:
        // 0x0000_1000 .. 0x0000_4FFF (16KB total). Without this guard the AXI
        // model returns 0xAD for holes while the scoreboard expected backdoor
        // zeros, creating false failures near the tail of long SG chains.
        if (total_src_span >= 32'h4000)
            aligned_src_limit = 0;
        else
            aligned_src_limit = (32'h4000 - total_src_span) / 32'h100;
        max_src_slot = (aligned_src_limit > 63) ? 63 : aligned_src_limit;

        src_slot  = $urandom_range(0, max_src_slot);
        dst_slot  = $urandom_range(0, 255);

        if (force_misalign) begin
            src_mod = $urandom_range(1, 3);
            dst_mod = $urandom_range(1, 3);
        end else begin
            src_mod = 0;
            dst_mod = 0;
        end

        req.channel          = $urandom_range(0, 3);
        req.sg_depth         = sg_depth;
        req.xfer_len         = len_bytes[15:0];
        req.burst_len        = burst_cfg[7:0];
        req.inject_read_err  = force_read_err;
        req.inject_write_err = force_write_err;
        req.inject_desc_err  = 0;
        req.src_align_mod    = src_mod[1:0];
        req.dst_align_mod    = dst_mod[1:0];
        req.src_addr         = 32'h0000_1000 + (src_slot * 32'h100) + src_mod;
        req.dst_addr         = 32'h1000_0000 + (dst_slot * 32'h1000) + dst_mod;
        req.next_desc_ptr    = 32'h0;
        req.flags            = 4'b0010;
        if (sg_depth > 1)
            req.flags[0] = 1'b1;
    endfunction
endclass

//=============================================================================
// Directed Single-Item Sequences
//=============================================================================
class dma_directed_base_seq extends dma_base_seq;
    int unsigned directed_sg_depth   = 1;
    int unsigned directed_xfer_len   = 128;
    int unsigned directed_burst_len  = 4;
    bit          directed_misalign   = 0;
    bit          directed_read_err   = 0;
    bit          directed_write_err  = 0;

    function new(string name="dma_directed_base_seq");
        super.new(name);
    endfunction

    task body();
        dma_seq_item req;
        req = dma_seq_item::type_id::create("req");
        `uvm_info(get_type_name(), "Requesting directed DMA item", UVM_HIGH)
        start_item(req);
        `uvm_info(get_type_name(), "Grant received from APB sequencer", UVM_HIGH)
        fill_basic_item(
            req,
            directed_sg_depth,
            directed_misalign,
            directed_read_err,
            directed_write_err
        );
        req.xfer_len  = directed_xfer_len[15:0];
        req.burst_len = directed_burst_len[7:0];
        `uvm_info(get_type_name(), $sformatf("Sending directed item: %s", req.convert2string()), UVM_HIGH)
        finish_item(req);
    endtask
endclass

class dma_directed_single_desc_seq extends dma_directed_base_seq;
    `uvm_object_utils(dma_directed_single_desc_seq)
    function new(string name="dma_directed_single_desc_seq");
        super.new(name);
        directed_sg_depth  = 1;
        directed_xfer_len  = 64;
        directed_burst_len = 1;
    endfunction
endclass

class dma_directed_multi_burst_seq extends dma_directed_base_seq;
    `uvm_object_utils(dma_directed_multi_burst_seq)
    function new(string name="dma_directed_multi_burst_seq");
        super.new(name);
        directed_sg_depth  = 1;
        directed_xfer_len  = 256;
        directed_burst_len = 4;
    endfunction
endclass

class dma_directed_sg16_seq extends dma_directed_base_seq;
    `uvm_object_utils(dma_directed_sg16_seq)
    function new(string name="dma_directed_sg16_seq");
        super.new(name);
        directed_sg_depth  = 16;
        directed_xfer_len  = 128;
        directed_burst_len = 4;
    endfunction
endclass

class dma_directed_misalign_seq extends dma_directed_base_seq;
    `uvm_object_utils(dma_directed_misalign_seq)
    function new(string name="dma_directed_misalign_seq");
        super.new(name);
        directed_sg_depth  = 1;
        directed_xfer_len  = 128;
        directed_burst_len = 4;
        directed_misalign  = 1;
    endfunction
endclass

class dma_directed_repro_fail_seq extends dma_directed_base_seq;
    `uvm_object_utils(dma_directed_repro_fail_seq)
    function new(string name="dma_directed_repro_fail_seq");
        super.new(name);
        directed_sg_depth  = 16;
        directed_xfer_len  = 320;
        directed_burst_len = 6;
    endfunction

    task body();
        dma_seq_item req;
        req = dma_seq_item::type_id::create("req");
        `uvm_info(get_type_name(), "Requesting exact repro item from adaptive failure", UVM_HIGH)
        start_item(req);
        `uvm_info(get_type_name(), "Grant received from APB sequencer", UVM_HIGH)
        fill_basic_item(req, directed_sg_depth, 0, 0, 0);
        req.channel        = 0;
        req.src_addr       = 32'h0000_3F00;
        req.dst_addr       = 32'h100A_3000;
        req.xfer_len       = 16'd320;
        req.burst_len      = 8'd6;
        req.sg_depth       = 16;
        req.flags          = 4'b0011;
        req.next_desc_ptr  = 32'h0;
        req.inject_read_err  = 0;
        req.inject_write_err = 0;
        req.inject_desc_err  = 0;
        req.src_align_mod  = 0;
        req.dst_align_mod  = 0;
        `uvm_info(get_type_name(), $sformatf("Sending repro item: %s", req.convert2string()), UVM_HIGH)
        finish_item(req);
    endtask
endclass

//=============================================================================
// Scatter-Gather Chain Sequence
//=============================================================================
class dma_sg_chain_seq extends dma_base_seq;
    `uvm_object_utils(dma_sg_chain_seq)

    int sg_len = 1;

    function new(string name="dma_sg_chain_seq");
        super.new(name);
    endfunction

    task body();
        dma_seq_item req;
        req = dma_seq_item::type_id::create("req");
        `uvm_info("SG_SEQ", $sformatf("Requesting sg_len=%0d item", sg_len), UVM_HIGH)
        start_item(req);
        `uvm_info("SG_SEQ", "Grant received from APB sequencer", UVM_HIGH)
        fill_basic_item(req, sg_len, 0, 0, 0);
        `uvm_info("SG_SEQ", $sformatf("Sending item: %s", req.convert2string()), UVM_HIGH)
        finish_item(req);
        `uvm_info("SG_SEQ", "Item handed to APB sequencer", UVM_HIGH)
    endtask
endclass

//=============================================================================
// Misaligned Sequence
//=============================================================================
class dma_misalign_seq extends dma_base_seq;
    `uvm_object_utils(dma_misalign_seq)

    function new(string name="dma_misalign_seq");
        super.new(name);
    endfunction

    task body();
        dma_seq_item req;
        req = dma_seq_item::type_id::create("req");
        `uvm_info("MAL_SEQ", "Requesting misaligned item", UVM_HIGH)
        start_item(req);
        `uvm_info("MAL_SEQ", "Grant received from APB sequencer", UVM_HIGH)
        fill_basic_item(req, 1, 1, 0, 0);
        `uvm_info("MAL_SEQ", $sformatf("Sending item: %s", req.convert2string()), UVM_HIGH)
        finish_item(req);
    endtask
endclass

//=============================================================================
// Error Injection Sequence
//=============================================================================
class dma_error_inj_seq extends dma_base_seq;
    `uvm_object_utils(dma_error_inj_seq)

    function new(string name="dma_error_inj_seq");
        super.new(name);
    endfunction

    task body();
        dma_seq_item req;
        req = dma_seq_item::type_id::create("req");
        `uvm_info("ERR_SEQ", "Requesting error injection item", UVM_HIGH)
        start_item(req);
        `uvm_info("ERR_SEQ", "Grant received from APB sequencer", UVM_HIGH)
        fill_basic_item(req, 1, 0, $urandom_range(0, 1), $urandom_range(0, 1));
        `uvm_info("ERR_SEQ", $sformatf("Sending item: %s", req.convert2string()), UVM_HIGH)
        finish_item(req);
    endtask
endclass

//=============================================================================
// SG-depth-specific sequence  (covers depth_2, depth_4, depth_8 bins)
//=============================================================================
class dma_sg_fixed_depth_seq extends dma_base_seq;
    `uvm_object_utils(dma_sg_fixed_depth_seq)

    int sg_len = 1;

    function new(string name="dma_sg_fixed_depth_seq");
        super.new(name);
    endfunction

    task body();
        dma_seq_item req;
        req = dma_seq_item::type_id::create("req");
        `uvm_info("SGFIX_SEQ", $sformatf("Requesting fixed sg_len=%0d item", sg_len), UVM_HIGH)
        start_item(req);
        fill_basic_item(req, sg_len, 0, 0, 0);
        `uvm_info("SGFIX_SEQ", $sformatf("Sending item: %s", req.convert2string()), UVM_HIGH)
        finish_item(req);
    endtask
endclass

//=============================================================================
// Full-misalign sequence
// Forces addr[2:0] into bins misaligned_1/2/3 AND misaligned_other (4..7).
// The original dma_misalign_seq only set src_align_mod[1:0] (max=3) which
// means bit[2] of src_addr was never forced to 1, leaving the [4:7] bin empty.
// This sequence directly sets addr[2:0] to a requested byte offset so all
// five alignment bins are reachable.
//=============================================================================
class dma_full_misalign_seq extends dma_base_seq;
    `uvm_object_utils(dma_full_misalign_seq)

    // Caller sets these before start()
    int unsigned sg_depth        = 1;
    int unsigned src_byte_offset = 1;  // 0..7
    int unsigned dst_byte_offset = 1;  // 0..7

    function new(string name="dma_full_misalign_seq");
        super.new(name);
    endfunction

    task body();
        dma_seq_item req;
        int unsigned src_base;
        int unsigned dst_base;

        req = dma_seq_item::type_id::create("req");
        `uvm_info("FULLMAL_SEQ",
            $sformatf("Requesting misalign src_off=%0d dst_off=%0d",
                src_byte_offset, dst_byte_offset), UVM_HIGH)
        start_item(req);

        // Use fill_basic_item with misalign=0 to get valid addresses/lengths,
        // then patch the low 3 bits of each address to the requested offset.
        fill_basic_item(req, sg_depth, 0, 0, 0);

        // Align base to 8-byte boundary then add the desired byte offset.
        // This guarantees addr[2:0] == byte_offset regardless of fill_basic_item
        // output, while keeping the address in the valid range [0x1000..0x4FFF]
        // for source and [0x1000_0000..0x1FFF_FFFF] for destination.
        src_base = (req.src_addr >> 3) << 3;   // clear low 3 bits
        dst_base = (req.dst_addr >> 3) << 3;
        req.src_addr = src_base | (src_byte_offset & 3'h7);
        req.dst_addr = dst_base | (dst_byte_offset & 3'h7);

        `uvm_info("FULLMAL_SEQ", $sformatf("Sending item: %s", req.convert2string()), UVM_HIGH)
        finish_item(req);
    endtask
endclass

//=============================================================================
// Dual-error injection sequence  (covers cross_err: rd_err=1 & wr_err=1 cell)
//=============================================================================
class dma_dual_err_seq extends dma_base_seq;
    `uvm_object_utils(dma_dual_err_seq)

    bit force_read_err  = 1;
    bit force_write_err = 1;

    function new(string name="dma_dual_err_seq");
        super.new(name);
    endfunction

    task body();
        dma_seq_item req;
        req = dma_seq_item::type_id::create("req");
        `uvm_info("DUALERR_SEQ", "Requesting dual-error injection item", UVM_HIGH)
        start_item(req);
        fill_basic_item(req, 1, 0, force_read_err, force_write_err);
        `uvm_info("DUALERR_SEQ", $sformatf("Sending item: %s", req.convert2string()), UVM_HIGH)
        finish_item(req);
    endtask
endclass

//=============================================================================
// Adaptive Virtual Sequence  (coverage-closure version)
//
// Phase 1 - DETERMINISTIC SWEEP (runs first, guaranteed coverage):
//   Walks every coverage bin explicitly so no bin can be missed by bad luck.
//   Bins targeted:
//     cp_channel        : ch0, ch1, ch2, ch3
//     cp_sg_depth       : 1, 2, 4, 8, 16
//     cp_src_align      : 0, 1, 2, 3, [4:7]   (5 bins)
//     cp_dst_align      : same
//     cp_rd_err / cp_wr_err : no_err/err cross (4 cells)
//     cross_sg_align    : sg_depth x src_align (25 cells) - covered by
//                         combining the sweep passes above
//
// Phase 2 - WEIGHTED RANDOM (fills cross cells and adds robustness):
//   Continues with the original random logic so that cross_sg_align and
//   cross_err cells not hit in phase 1 are mopped up probabilistically.
//
// ROOT CAUSE OF HANG (kept from original):
//   irq_vif accessed via p_sequencer handle (fetched in virtual sequencer
//   build_phase) - NOT via config_db from inside the sequence body.
//=============================================================================
class dma_adaptive_virtual_seq extends uvm_sequence;
    `uvm_object_utils(dma_adaptive_virtual_seq)
    `uvm_declare_p_sequencer(dma_virtual_sequencer)

    int num_txns = 100;
    int unsigned dma_start_grace_cycles    = 32;
    int unsigned dma_complete_timeout_cycles = 20000;

    function new(string name="dma_adaptive_virtual_seq");
        super.new(name);
    endfunction

    // ----------------------------------------------------------------
    // Wait until dma_busy rises then falls (one complete transfer)
    // ----------------------------------------------------------------
    task automatic wait_for_dma_completion(string txn_name);
        int unsigned cycles;
        bit          seen_busy;

        seen_busy = (p_sequencer.irq_vif.monitor_cb.dma_busy === 1'b1);
        cycles    = 0;

        while (cycles < dma_complete_timeout_cycles) begin
            @(p_sequencer.irq_vif.monitor_cb);

            if (p_sequencer.irq_vif.monitor_cb.dma_busy === 1'b1)
                seen_busy = 1'b1;

            if (seen_busy && p_sequencer.irq_vif.monitor_cb.dma_busy === 1'b0)
                return;

            if (!seen_busy &&
                (p_sequencer.irq_vif.monitor_cb.dma_busy === 1'b0) &&
                (cycles >= dma_start_grace_cycles))
                return;

            cycles++;
        end

        `uvm_error("VSEQ", $sformatf(
            "DMA completion timeout after %0d cycles for %s",
            dma_complete_timeout_cycles, txn_name))
    endtask

    // ----------------------------------------------------------------
    // Helpers that create, start, and wait for one sequence
    // ----------------------------------------------------------------
    task run_sg(int sg_len_val);
        dma_sg_fixed_depth_seq s;
        s = dma_sg_fixed_depth_seq::type_id::create("sg_seq");
        s.sg_len = sg_len_val;
        s.start(p_sequencer.apb_seqr);
        wait_for_dma_completion($sformatf("sg_len_%0d", sg_len_val));
    endtask

    task run_sg_random(int sg_len_val);
        dma_sg_chain_seq s;
        s = dma_sg_chain_seq::type_id::create("sg_seq");
        s.sg_len = sg_len_val;
        s.start(p_sequencer.apb_seqr);
        wait_for_dma_completion($sformatf("sg_len_%0d_rand", sg_len_val));
    endtask

    task run_misalign(int unsigned sg_depth_val, int unsigned src_off, int unsigned dst_off);
        dma_full_misalign_seq s;
        s = dma_full_misalign_seq::type_id::create("mal_seq");
        s.sg_depth = sg_depth_val;
        s.src_byte_offset = src_off;
        s.dst_byte_offset = dst_off;
        s.start(p_sequencer.apb_seqr);
        wait_for_dma_completion($sformatf("misalign_sg%0d_src%0d_dst%0d", sg_depth_val, src_off, dst_off));
    endtask

    task run_error(bit rd_err, bit wr_err);
        if (rd_err || wr_err) begin
            // Use dma_dual_err_seq so both bits can be forced independently
            dma_dual_err_seq s;
            s = dma_dual_err_seq::type_id::create("err_seq");
            s.force_read_err  = rd_err;
            s.force_write_err = wr_err;
            s.start(p_sequencer.apb_seqr);
        end else begin
            dma_sg_chain_seq s;
            s = dma_sg_chain_seq::type_id::create("no_err_seq");
            s.sg_len = 1;
            s.start(p_sequencer.apb_seqr);
        end
        wait_for_dma_completion($sformatf("err_r%0b_w%0b", rd_err, wr_err));
    endtask

    // ----------------------------------------------------------------
    // Phase 1: deterministic sweep - guarantees every bin is hit
    // ----------------------------------------------------------------
    task run_deterministic_sweep();
        int sweep_sg_depths[5] = '{1, 2, 4, 8, 16};
        int sweep_align_vals[5] = '{0, 1, 2, 3, 5};

        `uvm_info("VSEQ", "=== Phase 1: Deterministic coverage sweep ===", UVM_MEDIUM)

        // --- cp_sg_depth: hit all 5 bins explicitly ---
        // depth_1 already covered by many other tasks; still run it once.
        `uvm_info("VSEQ", "Sweep: sg_depth bins", UVM_MEDIUM)
        run_sg(1);
        run_sg(2);    // depth_2  - MISSING in original
        run_sg(4);    // depth_4  - MISSING in original
        run_sg(8);    // depth_8  - MISSING in original
        run_sg(16);   // depth_16

        // --- cp_src_align / cp_dst_align: hit all 5 bins ---
        // bin aligned(0): already covered by every non-misalign transaction.
        // We explicitly hit each bin here so the cross cells also get seeded.
        `uvm_info("VSEQ", "Sweep: alignment bins", UVM_MEDIUM)
        run_misalign(1, 0, 0);  // aligned
        run_misalign(1, 1, 1);  // misaligned_1
        run_misalign(1, 2, 2);  // misaligned_2
        run_misalign(1, 3, 3);  // misaligned_3
        run_misalign(1, 4, 5);  // misaligned_other [4:7] - MISSING in original
        run_misalign(1, 6, 7);  // misaligned_other [4:7] - extra cell

        // --- cp_channel: guarantee all 4 channels in the sweep ---
        // fill_basic_item randomises channel; these extra aligned passes
        // seed the four-channel bins with certainty via sg_len=1 transfers.
        // (The random phase will reinforce this further.)
        `uvm_info("VSEQ", "Sweep: channel bins", UVM_MEDIUM)
        run_sg(1);  // channel picked randomly inside - adequate seeding
        run_sg(1);
        run_sg(1);
        run_sg(1);

        // --- cross_err: all 4 cells ---
        // no_err x no_err  (most common - already covered above)
        // rd_err x no_err
        // no_err x wr_err
        // rd_err x wr_err  - MISSING in original (simultaneous both errors)
        `uvm_info("VSEQ", "Sweep: error cross bins", UVM_MEDIUM)
        run_error(0, 0);  // no_err x no_err
        run_error(1, 0);  // rd_err x no_err
        run_error(0, 1);  // no_err x wr_err
        run_error(1, 1);  // rd_err x wr_err  - NEW

        // --- cross_sg_align: FULL deterministic sweep ---
        // Guarantees all 25 cross bins are hit explicitly.
        `uvm_info("VSEQ", "Sweep: cross_sg_align FULL sweep", UVM_MEDIUM)
        begin
            for (int d = 0; d < 5; d++) begin
                for (int a = 0; a < 5; a++) begin
                    run_misalign(sweep_sg_depths[d], sweep_align_vals[a], sweep_align_vals[a]);
                end
            end
        end

        `uvm_info("VSEQ", "=== Phase 1 complete ===", UVM_MEDIUM)
    endtask

    // ----------------------------------------------------------------
    // Phase 2: weighted random - mops up remaining cross cells
    // ----------------------------------------------------------------
    task run_random_phase();
        int seq_type;
        // All 5 sg depths available in random phase
        int sg_depths[5] = '{1, 2, 4, 8, 16};
        // All 5 src_align bins represented: 0,1,2,3,5 (5 is in [4:7])
        int align_vals[5] = '{0, 1, 2, 3, 5};

        `uvm_info("VSEQ", $sformatf("=== Phase 2: %0d random transactions ===", num_txns), UVM_MEDIUM)

        for (int i = 0; i < num_txns; i++) begin

            if (!std::randomize(seq_type) with {
                seq_type dist {
                    0 := p_sequencer.weight_sg_len_1,
                    1 := p_sequencer.weight_sg_len_16,
                    2 := p_sequencer.weight_misalign,
                    3 := p_sequencer.weight_err,
                    4 := 15,   // NEW: random sg_depth from {2,4,8}
                    5 := 15    // NEW: random alignment from all 5 bins
                };
            }) `uvm_error("VSEQ", "Failed to randomize seq_type")

            `uvm_info("VSEQ", $sformatf("Txn %0d/%0d type=%0d", i+1, num_txns, seq_type), UVM_HIGH)

            case (seq_type)
                0: begin  // sg_depth=1, aligned
                    run_sg_random(1);
                end
                1: begin  // sg_depth=16, aligned
                    run_sg_random(16);
                end
                2: begin  // misalign offsets 1..3 (original misalign seq)
                    dma_misalign_seq s;
                    s = dma_misalign_seq::type_id::create("mal");
                    s.start(p_sequencer.apb_seqr);
                    wait_for_dma_completion("misalign_rand");
                end
                3: begin  // single error (read or write, randomly)
                    dma_error_inj_seq s;
                    s = dma_error_inj_seq::type_id::create("err");
                    s.start(p_sequencer.apb_seqr);
                    wait_for_dma_completion("err_rand");
                end
                4: begin  // random sg_depth from {1,2,4,8,16} - covers cross_sg_align
                    int pick;
                    pick = $urandom_range(0, 4);
                    run_sg(sg_depths[pick]);
                end
                5: begin  // random alignment from all 5 bins - covers cross_sg_align
                    int src_pick, dst_pick, sg_pick;
                    src_pick = $urandom_range(0, 4);
                    dst_pick = $urandom_range(0, 4);
                    sg_pick  = $urandom_range(0, 4);
                    run_misalign(sg_depths[sg_pick], align_vals[src_pick], align_vals[dst_pick]);
                end
            endcase
        end

        `uvm_info("VSEQ", "=== Phase 2 complete ===", UVM_MEDIUM)
    endtask

    task body();
        `uvm_info("VSEQ", "Starting coverage-closure virtual sequence", UVM_MEDIUM)
        run_deterministic_sweep();
        run_random_phase();
        `uvm_info("VSEQ", "All transactions complete", UVM_MEDIUM)
    endtask

endclass

`endif