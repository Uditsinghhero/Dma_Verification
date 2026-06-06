`timescale 1ns / 1ps

`ifndef DMA_APB_DRIVER_SV
`define DMA_APB_DRIVER_SV

//=============================================================================
// APB Driver
//
// KEY FIXES IN THIS VERSION:
//
// FIX #1 (Bug #1 - PRIMARY HANG CAUSE):
//   write_desc_to_mem() now writes into dma_axi_mem_driver::mem[] directly
//   (the static shared memory that the AXI slave serves reads from).
//   Previously it wrote into a local mem[] that was completely invisible to
//   the AXI slave, so the DUT always fetched an all-zero descriptor, causing
//   bytes_left=0 and an infinite loop in ST_AR_DATA.
//
// FIX #2 (Bug #2 - modport visibility):
//   All pready/psel accesses now go through the clocking block (master_cb /
//   monitor_cb) instead of the raw signal. Accessing raw signals via a
//   modport-restricted virtual interface handle is rejected by xsim
//   [VRFC 10-3602].
//
// FIX #3 (Bug #6 - removed axi_vif from APB driver):
//   The APB driver no longer holds an axi_vif handle. It previously fetched
//   it from config_db but only used it for write_desc_to_mem (now removed).
//   This eliminates a confusing unused field and removes the risk of the
//   APB driver accidentally driving AXI slave signals.
//=============================================================================

class dma_apb_driver extends uvm_driver #(dma_seq_item);
    `uvm_component_utils(dma_apb_driver)

    virtual dma_apb_if.master_mp apb_vif;
    int unsigned apb_wait_timeout_cycles = 256;
    // NOTE: axi_vif removed - APB driver no longer owns descriptor memory.
    // Descriptor pre-loading is done directly into dma_axi_mem_driver::mem[]
    // which is the static shared memory served by the AXI slave.

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual dma_apb_if)::get(this, "", "apb_vif", apb_vif))
            `uvm_fatal("CFG", "apb_vif not set")
        // No axi_vif needed - desc writes go to dma_axi_mem_driver::mem[]
    endfunction

    task run_phase(uvm_phase phase);
        dma_seq_item item;

        // Initialize APB outputs to idle
        apb_vif.master_cb.psel    <= 0;
        apb_vif.master_cb.penable <= 0;
        apb_vif.master_cb.pwrite  <= 0;
        apb_vif.master_cb.paddr   <= 0;
        apb_vif.master_cb.pwdata  <= 0;

        // Wait for reset - explicit poll (iff guard unreliable in xsim)
        do begin
            @(posedge apb_vif.clk);
        end while (!apb_vif.rst_n);
        `uvm_info("APB_DRV", $sformatf("Reset released at %0t", $time), UVM_HIGH)

        // Extra settling cycles after reset deassertion
        repeat(2) @(posedge apb_vif.clk);
        `uvm_info("APB_DRV", $sformatf("Driver entering sequencer wait at %0t", $time), UVM_HIGH)

        forever begin
            seq_item_port.wait_for_sequences();
            `uvm_info("APB_DRV", $sformatf(
                "Sequencer reports item available at %0t", $time), UVM_HIGH)
            seq_item_port.get_next_item(item);
            `uvm_info("APB_DRV", $sformatf(
                "Accepted sequence item at %0t: %s", $time, item.convert2string()), UVM_HIGH)
            drive_item(item);
            seq_item_port.item_done();
        end
    endtask

    task drive_item(dma_seq_item item);
        logic [31:0] desc_addr;
        logic [31:0] next_addr;
        logic [3:0]  desc_flags;

        // Base descriptor address for this channel in the shared AXI memory
        desc_addr = 32'hC000_0000 + item.channel * 32'h1000;

        // Pass error injection config to AXI memory driver
        dma_axi_mem_driver::inject_read_err  = item.inject_read_err;
        dma_axi_mem_driver::inject_write_err = item.inject_write_err;

        // FIX #1: Write descriptor data directly into dma_axi_mem_driver::mem[]
        // This is the static memory that the AXI slave will serve back to the DUT
        // when it issues its AR descriptor fetch. Previously this was written to a
        // local mem[] that was completely disconnected from the AXI slave.
        for (int d = 0; d < item.sg_depth; d++) begin
            next_addr = (d == item.sg_depth - 1) ? 32'h0
                                                  : desc_addr + 32'h20 * (d + 1);
            desc_flags    = item.flags;
            desc_flags[0] = (d < item.sg_depth - 1);
            desc_flags[1] = (d == item.sg_depth - 1) ? item.flags[1] : 1'b0;
            write_desc_to_shared_mem(
                .addr     (desc_addr + 32'h20 * d),
                .src_addr (item.src_addr + d * item.xfer_len),
                .dst_addr (item.dst_addr + d * item.xfer_len),
                .xfer_len (item.xfer_len),
                .flags    (desc_flags),
                .next_ptr (next_addr)
            );
        end

        // Program DUT CSRs via APB:
        //   [ch_base + 0x04] = descriptor base address
        //   [ch_base + 0x10] = burst length
        //   [ch_base + 0x00] = control: ch_en[0]=1, ch_start[1]=1, ch_irq_en[3]=1
        //   [0x000]          = global enable
        `uvm_info("APB_DRV", $sformatf(
            "Programming channel %0d descriptor base 0x%08h", item.channel, desc_addr), UVM_HIGH)
        apb_write(32'h100 + item.channel * 32'h100 + 32'h04, desc_addr);
        `uvm_info("APB_DRV", $sformatf(
            "Programming channel %0d burst length %0d", item.channel, item.burst_len), UVM_HIGH)
        apb_write(32'h100 + item.channel * 32'h100 + 32'h10, {24'h0, item.burst_len});
        `uvm_info("APB_DRV", $sformatf(
            "Programming channel %0d control/start", item.channel), UVM_HIGH)
        apb_write(32'h100 + item.channel * 32'h100 + 32'h00, 32'h0B);
        `uvm_info("APB_DRV", "Enabling global DMA", UVM_HIGH)
        apb_write(32'h000, 32'h1);

        `uvm_info("APB_DRV", $sformatf("Started ch%0d: desc@0x%08h len=%0d sg=%0d",
            item.channel, desc_addr, item.xfer_len, item.sg_depth), UVM_HIGH)
    endtask

    //-------------------------------------------------------------------------
    // write_desc_to_shared_mem
    // Writes one 32-byte descriptor into dma_axi_mem_driver::mem[] so the
    // AXI slave will return the correct data when the DUT fetches it.
    //
    // Descriptor layout (byte offsets):
    //   [0 .. 3]   src_addr  (LE)
    //   [4 .. 7]   dst_addr  (LE)
    //   [8 .. 9]   xfer_len  (LE)
    //   [10]       flags[3:0]
    //   [11]       reserved
    //   [12..15]   next_ptr  (LE)
    //   [16..31]   reserved / padding
    //
    // AXI slave reads: arlen=1, arsize=3 (64-bit) → 2 beats of 8 bytes each
    //   Beat 0 (addr+0):  rdata[31:0]=src_addr, rdata[63:32]=dst_addr
    //   Beat 1 (addr+8):  rdata[15:0]=xfer_len, rdata[23:16]=flags,
    //                      rdata[63:32]=next_ptr
    // This layout must match what dma_engine ST_R_DESC latches.
    //-------------------------------------------------------------------------
    task write_desc_to_shared_mem(
        input logic [31:0] addr,
        input logic [31:0] src_addr,
        input logic [31:0] dst_addr,
        input logic [15:0] xfer_len,
        input logic [3:0]  flags,
        input logic [31:0] next_ptr
    );
        // Beat 0: src_addr [31:0] at bytes 0-3, dst_addr [63:32] at bytes 4-7
        for (int b = 0; b < 4; b++)
            dma_axi_mem_driver::mem[addr + b]     = src_addr[b*8 +: 8];
        for (int b = 0; b < 4; b++)
            dma_axi_mem_driver::mem[addr + 4 + b] = dst_addr[b*8 +: 8];

        // Beat 1: xfer_len at bytes 8-9, flags at byte 10, reserved at 11,
        //         next_ptr at bytes 12-15
        for (int b = 0; b < 2; b++)
            dma_axi_mem_driver::mem[addr + 8 + b] = xfer_len[b*8 +: 8];
        dma_axi_mem_driver::mem[addr + 10] = {4'h0, flags};
        dma_axi_mem_driver::mem[addr + 11] = 8'h0;
        for (int b = 0; b < 4; b++)
            dma_axi_mem_driver::mem[addr + 12 + b] = next_ptr[b*8 +: 8];

        // Clear padding (bytes 16-31) so AXI reads return clean data
        for (int b = 16; b < 32; b++)
            dma_axi_mem_driver::mem[addr + b] = 8'h0;
    endtask

    //-------------------------------------------------------------------------
    // apb_write - APB SETUP + ACCESS phase
    // FIX #2: pready read goes through master_cb (clocking block) not raw
    //         signal. Direct raw signal access via a modport handle is
    //         rejected by xsim [VRFC 10-3602].
    //-------------------------------------------------------------------------
    task apb_write(input logic [31:0] addr, input logic [31:0] data);
        int unsigned wait_cycles;

        // SETUP phase: assert psel, paddr, pwrite, pwdata
        @(apb_vif.master_cb);
        apb_vif.master_cb.paddr  <= addr[11:0];
        apb_vif.master_cb.pwdata <= data;
        apb_vif.master_cb.pwrite <= 1;
        apb_vif.master_cb.psel   <= 1;

        // ACCESS phase: assert penable one cycle later
        @(apb_vif.master_cb);
        apb_vif.master_cb.penable <= 1;

        // Wait for pready via clocking block (pready=1 combinatorially in DUT)
        @(apb_vif.master_cb);
        wait_cycles = 0;
        while (!apb_vif.master_cb.pready) begin
            @(apb_vif.master_cb);
            wait_cycles++;
            if (wait_cycles >= apb_wait_timeout_cycles) begin
                `uvm_fatal("APB_TIMEOUT", $sformatf(
                    "APB write timed out waiting for pready addr=0x%03h data=0x%08h",
                    addr[11:0], data))
            end
        end

        // Deassert APB signals
        apb_vif.master_cb.psel    <= 0;
        apb_vif.master_cb.penable <= 0;
        apb_vif.master_cb.pwrite  <= 0;
    endtask

    task apb_read(input logic [31:0] addr, output logic [31:0] data);
        int unsigned wait_cycles;

        @(apb_vif.master_cb);
        apb_vif.master_cb.paddr  <= addr[11:0];
        apb_vif.master_cb.pwrite <= 0;
        apb_vif.master_cb.psel   <= 1;

        @(apb_vif.master_cb);
        apb_vif.master_cb.penable <= 1;

        @(apb_vif.master_cb);
        wait_cycles = 0;
        while (!apb_vif.master_cb.pready) begin
            @(apb_vif.master_cb);
            wait_cycles++;
            if (wait_cycles >= apb_wait_timeout_cycles) begin
                `uvm_fatal("APB_TIMEOUT", $sformatf(
                    "APB read timed out waiting for pready addr=0x%03h",
                    addr[11:0]))
            end
        end

        data = apb_vif.master_cb.prdata;
        apb_vif.master_cb.psel    <= 0;
        apb_vif.master_cb.penable <= 0;
    endtask

endclass


//=============================================================================
// APB Monitor
// FIX #2: monitor uses monitor_cb to access psel/penable/pready
//         instead of raw signal access via modport handle.
//=============================================================================
class dma_apb_monitor extends uvm_monitor;
    `uvm_component_utils(dma_apb_monitor)

    virtual dma_apb_if.monitor_mp apb_vif;
    uvm_analysis_port #(dma_seq_item) ap;
    logic [31:0] shadow_desc_addr [4];
    logic [7:0]  shadow_burst_len [4];
    bit          shadow_ch_en     [4];
    bit          shadow_ch_start  [4];
    bit          shadow_global_en;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual dma_apb_if)::get(this, "", "apb_vif", apb_vif))
            `uvm_fatal("CFG", "apb_vif not set")
    endfunction

    function logic [7:0] read_shared_byte(logic [31:0] addr);
        return dma_axi_mem_driver::mem.exists(addr) ? dma_axi_mem_driver::mem[addr] : 8'h0;
    endfunction

    function logic [31:0] read_shared_word(logic [31:0] addr);
        logic [31:0] data;
        for (int b = 0; b < 4; b++)
            data[b*8 +: 8] = read_shared_byte(addr + b);
        return data;
    endfunction

    function logic [15:0] read_shared_halfword(logic [31:0] addr);
        logic [15:0] data;
        for (int b = 0; b < 2; b++)
            data[b*8 +: 8] = read_shared_byte(addr + b);
        return data;
    endfunction

    task emit_transfer(int ch);
        dma_seq_item  item;
        logic [31:0]  desc_addr;
        logic [31:0]  next_ptr;
        logic [3:0]   flags;
        logic [7:0]   flag_byte;
        int unsigned  sg_depth;

        if (!shadow_global_en || !shadow_ch_en[ch] || !shadow_ch_start[ch])
            return;

        desc_addr = shadow_desc_addr[ch];
        if (desc_addr == 32'h0) begin
            `uvm_warning("APB_MON", $sformatf(
                "Channel %0d start observed with null descriptor address", ch))
            return;
        end

        item = dma_seq_item::type_id::create($sformatf("apb_mon_item_ch%0d", ch));
        item.channel         = ch;
        item.burst_len       = (shadow_burst_len[ch] == 0) ? 1 : shadow_burst_len[ch];
        item.src_addr        = read_shared_word(desc_addr + 32'h00);
        item.dst_addr        = read_shared_word(desc_addr + 32'h04);
        item.xfer_len        = read_shared_halfword(desc_addr + 32'h08);
        flag_byte            = read_shared_byte(desc_addr + 32'h0A);
        flags                = flag_byte[3:0];
        item.flags           = flags;
        item.next_desc_ptr   = read_shared_word(desc_addr + 32'h0C);
        item.inject_read_err = dma_axi_mem_driver::inject_read_err;
        item.inject_write_err= dma_axi_mem_driver::inject_write_err;
        item.inject_desc_err = 0;
        item.src_align_mod   = item.src_addr[1:0];
        item.dst_align_mod   = item.dst_addr[1:0];

        sg_depth = 1;
        next_ptr = item.next_desc_ptr;
        while (flags[0] && (next_ptr != 32'h0) && (sg_depth < 16)) begin
            flag_byte = read_shared_byte(next_ptr + 32'h0A);
            flags     = flag_byte[3:0];
            next_ptr= read_shared_word(next_ptr + 32'h0C);
            sg_depth++;
        end
        item.sg_depth = sg_depth;

        ap.write(item);
        shadow_ch_start[ch] = 0;
        `uvm_info("APB_MON", $sformatf(
            "Observed DMA launch ch%0d desc=0x%08h len=%0d sg=%0d burst=%0d",
            item.channel, desc_addr, item.xfer_len, item.sg_depth, item.burst_len), UVM_HIGH)
    endtask

    task run_phase(uvm_phase phase);
        do begin
            @(posedge apb_vif.clk);
        end while (!apb_vif.rst_n);

        forever begin
            @(posedge apb_vif.clk);
            // FIX: use monitor_cb instead of raw signal on modport handle
            if (apb_vif.monitor_cb.psel &&
                apb_vif.monitor_cb.penable &&
                apb_vif.monitor_cb.pready) begin
                if (apb_vif.monitor_cb.pwrite) begin
                    if (apb_vif.monitor_cb.paddr == 12'h000) begin
                        shadow_global_en = apb_vif.monitor_cb.pwdata[0];
                        if (shadow_global_en) begin
                            for (int ch = 0; ch < 4; ch++)
                                if (shadow_ch_start[ch])
                                    emit_transfer(ch);
                        end
                    end else begin
                        for (int ch = 0; ch < 4; ch++) begin
                            if (apb_vif.monitor_cb.paddr == (12'h100 + ch*12'h100 + 12'h04)) begin
                                shadow_desc_addr[ch] = apb_vif.monitor_cb.pwdata;
                            end else if (apb_vif.monitor_cb.paddr == (12'h100 + ch*12'h100 + 12'h10)) begin
                                shadow_burst_len[ch] = apb_vif.monitor_cb.pwdata[7:0];
                            end else if (apb_vif.monitor_cb.paddr == (12'h100 + ch*12'h100 + 12'h00)) begin
                                shadow_ch_en[ch]    = apb_vif.monitor_cb.pwdata[0];
                                shadow_ch_start[ch] = apb_vif.monitor_cb.pwdata[1];
                                if (shadow_global_en && shadow_ch_start[ch])
                                    emit_transfer(ch);
                            end
                        end
                    end
                end
            end
        end
    endtask
endclass


//=============================================================================
// APB Sequencer
//=============================================================================
class dma_apb_sequencer extends uvm_sequencer #(dma_seq_item);
    `uvm_component_utils(dma_apb_sequencer)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass


//=============================================================================
// APB Agent
//=============================================================================
class dma_apb_agent extends uvm_agent;
    `uvm_component_utils(dma_apb_agent)

    dma_apb_driver    driver;
    dma_apb_monitor   monitor;
    dma_apb_sequencer sequencer;
    uvm_analysis_port #(dma_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        monitor = dma_apb_monitor::type_id::create("monitor", this);
        ap      = new("ap", this);
        if (get_is_active() == UVM_ACTIVE) begin
            driver    = dma_apb_driver::type_id::create("driver", this);
            sequencer = dma_apb_sequencer::type_id::create("sequencer", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        if (get_is_active() == UVM_ACTIVE)
            driver.seq_item_port.connect(sequencer.seq_item_export);
        monitor.ap.connect(ap);
    endfunction
endclass

`endif
