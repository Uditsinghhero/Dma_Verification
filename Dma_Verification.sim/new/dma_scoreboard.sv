`timescale 1ns / 1ps

`ifndef DMA_SCOREBOARD_SV
`define DMA_SCOREBOARD_SV

`uvm_analysis_imp_decl(_apb)
`uvm_analysis_imp_decl(_axi)

//=============================================================================
// DMA Scoreboard
// FIX: report_phase used $sformatf with multiple separate format strings
//      passed as additional arguments - only the first string was used as
//      the format, the rest were silently ignored, producing a garbled/empty
//      summary. Fixed by building the summary string with concatenation.
//=============================================================================

class dma_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(dma_scoreboard)

    uvm_analysis_imp_apb #(dma_seq_item,     dma_scoreboard) apb_imp;
    uvm_analysis_imp_axi #(dma_mem_seq_item, dma_scoreboard) axi_imp;

    typedef struct {
        logic [31:0] dst_addr;
        logic [31:0] src_addr;
        logic [15:0] xfer_len;
        int unsigned sg_depth;
        int unsigned channel;
        logic [7:0]  burst_len;
        logic [7:0]  exp_data[];
        bit          completed;
        realtime     start_time;
        int unsigned expected_write_rsp;
        int unsigned seen_write_rsp;
    } transfer_t;

    transfer_t pending_q   [$];
    transfer_t completed_q [$];

    int unsigned txn_total;
    int unsigned txn_pass;
    int unsigned txn_fail;
    int unsigned txn_timeout;
    int unsigned byte_total;

    dma_axi_mem_driver mem_driver;
    int unsigned TIMEOUT_CYCLES = 10000;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        apb_imp = new("apb_imp", this);
        axi_imp = new("axi_imp", this);
    endfunction

    function void write_apb(dma_seq_item item);
        transfer_t txn;
        int unsigned burst_bytes;
        txn.dst_addr   = item.dst_addr;
        txn.src_addr   = item.src_addr;
        txn.xfer_len   = item.xfer_len;
        txn.sg_depth   = item.sg_depth;
        txn.channel    = item.channel;
        txn.burst_len  = item.burst_len;
        txn.completed  = 0;
        txn.start_time = $realtime;
        txn.seen_write_rsp = 0;

        burst_bytes = ((item.burst_len == 0) ? 1 : item.burst_len) * 8;
        txn.expected_write_rsp = item.sg_depth * ((item.xfer_len + burst_bytes - 1) / burst_bytes);

        txn.exp_data = new[item.xfer_len * item.sg_depth];
        for (int d = 0; d < item.sg_depth; d++)
            for (int b = 0; b < item.xfer_len; b++)
                txn.exp_data[d*item.xfer_len + b] =
                    mem_driver.backdoor_read(item.src_addr + d*item.xfer_len + b);

        pending_q.push_back(txn);
        txn_total++;
        `uvm_info("SB", $sformatf(
            "TRACKING: ch%0d dst=0x%08h len=%0d sg=%0d burst=%0d expected_write_rsp=%0d",
            txn.channel, txn.dst_addr, txn.xfer_len, txn.sg_depth,
            txn.burst_len, txn.expected_write_rsp), UVM_HIGH)
    endfunction

    function bit addr_hits_transfer(transfer_t txn, logic [31:0] addr);
        for (int d = 0; d < txn.sg_depth; d++) begin
            logic [31:0] seg_base;
            seg_base = txn.dst_addr + d * txn.xfer_len;
            if ((addr >= seg_base) && (addr < (seg_base + txn.xfer_len)))
                return 1;
        end
        return 0;
    endfunction

    function void write_axi(dma_mem_seq_item item);
        if (item.txn_type == dma_mem_seq_item::WRITE) begin
            foreach (pending_q[i]) begin
                if (!pending_q[i].completed &&
                    addr_hits_transfer(pending_q[i], item.addr)) begin
                    if (item.resp[0] != 2'b00) begin
                        `uvm_error("SB", $sformatf(
                            "WRITE ERROR: ch%0d addr=0x%08h resp=%0b",
                            item.channel_id, item.addr, item.resp[0]))
                        txn_fail++;
                        pending_q.delete(i);
                        return;
                    end
                    pending_q[i].seen_write_rsp++;
                    `uvm_info("SB", $sformatf(
                        "PROGRESS: ch%0d write_rsp=%0d/%0d addr=0x%08h",
                        pending_q[i].channel, pending_q[i].seen_write_rsp,
                        pending_q[i].expected_write_rsp, item.addr), UVM_FULL)
                    if (pending_q[i].seen_write_rsp >= pending_q[i].expected_write_rsp)
                        check_transfer(i);
                    return;
                end
            end
        end
    endfunction

    function void check_transfer(int idx);
        transfer_t  txn;
        int         mismatches;
        logic [7:0] actual;

        txn        = pending_q[idx];
        mismatches = 0;

        for (int d = 0; d < txn.sg_depth; d++) begin
            for (int b = 0; b < txn.xfer_len; b++) begin
                actual = mem_driver.backdoor_read(txn.dst_addr + d*txn.xfer_len + b);
                if (actual !== txn.exp_data[d*txn.xfer_len + b]) begin
                    mismatches++;
                    if (mismatches <= 8)
                        `uvm_error("SB", $sformatf(
                            "DATA MISMATCH ch%0d d=%0d b=%0d: exp=0x%02h got=0x%02h",
                            txn.channel, d, b,
                            txn.exp_data[d*txn.xfer_len+b], actual))
                end
            end
        end

        byte_total += txn.xfer_len * txn.sg_depth;

        if (mismatches == 0) begin
            `uvm_info("SB", $sformatf("PASS ch%0d: %0d bytes verified in %0t",
                txn.channel, txn.xfer_len * txn.sg_depth,
                $realtime - txn.start_time), UVM_HIGH)
            txn_pass++;
        end else begin
            `uvm_error("SB", $sformatf("FAIL ch%0d: %0d mismatches in %0d bytes",
                txn.channel, mismatches, txn.xfer_len * txn.sg_depth))
            txn_fail++;
        end

        txn.completed = 1;
        completed_q.push_back(txn);
        pending_q.delete(idx);
    endfunction

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        foreach (pending_q[i]) begin
            txn_timeout++;
            `uvm_error("SB", $sformatf(
                "TIMEOUT: ch%0d transfer never completed dst=0x%08h",
                pending_q[i].channel, pending_q[i].dst_addr))
        end
    endfunction

    // FIX: report_phase previously passed multiple strings to $sformatf as
    // additional positional arguments after the format string, which is wrong.
    // Only the first string was treated as the format; the rest were ignored.
    // Fixed by using a single format string with all values inline.
    function void report_phase(uvm_phase phase);
        string summary;
        summary = {
            "\n====== SCOREBOARD SUMMARY ======\n",
            $sformatf("  Total transactions : %0d\n", txn_total),
            $sformatf("  Passed             : %0d\n", txn_pass),
            $sformatf("  Failed             : %0d\n", txn_fail),
            $sformatf("  Timed out          : %0d\n", txn_timeout),
            $sformatf("  Total bytes checked: %0d\n", byte_total),
            "================================"
        };
        `uvm_info("SB", summary, UVM_NONE)

        if (txn_fail > 0 || txn_timeout > 0)
            `uvm_error("SB", "SIMULATION FAILED")
        else
            `uvm_info("SB", "ALL TRANSFERS VERIFIED - PASS", UVM_NONE)
    endfunction

endclass

`endif
