`timescale 1ns / 1ps

`ifndef DMA_AXI_MEM_AGENT_SV
`define DMA_AXI_MEM_AGENT_SV

//=============================================================================
// AXI Memory Sequence Item (captured transactions)
//=============================================================================
class dma_mem_seq_item extends uvm_sequence_item;
    `uvm_object_utils(dma_mem_seq_item)

    typedef enum logic [1:0] {READ, WRITE} txn_type_e;
    txn_type_e  txn_type;

    logic [31:0] addr;
    logic [7:0]  len;
    logic [2:0]  size;
    logic [63:0] data [];
    logic [1:0]  resp [];
    bit          is_desc_fetch;
    int unsigned channel_id;

    function new(string name = "dma_mem_seq_item");
        super.new(name);
    endfunction

    function string convert2string();
        string s = $sformatf("AXI_%s addr=0x%08h len=%0d sz=%0d ch=%0d desc=%0b",
            txn_type.name(), addr, len, size, channel_id, is_desc_fetch);
        foreach (data[i])
            s = {s, $sformatf(" d[%0d]=0x%016h", i, data[i])};
        return s;
    endfunction
endclass


//=============================================================================
// AXI Memory Driver (Slave)
//
// FIX: Replaced all @(clocking_block iff signal) guards with explicit
// poll loops.  xsim does not reliably evaluate clocking-block iff guards
// on signals that are driven combinatorially or already asserted when the
// process reaches the wait -- the simulator can miss the condition and
// block forever.  Polling every clock edge is always safe.
//=============================================================================
class dma_axi_mem_driver extends uvm_driver #(dma_seq_item);
    `uvm_component_utils(dma_axi_mem_driver)

    virtual dma_axi_if.slave_mp axi_vif;

    static logic [7:0] mem [logic[31:0]];

    int unsigned rd_ready_delay_max = 0;
    int unsigned wr_ready_delay_max = 0;
    static bit   inject_read_err    = 0;
    static bit   inject_write_err   = 0;
    logic [31:0] err_addr_mask      = 32'hFFFF_F000;
    int unsigned axi_wait_timeout_cycles = 4096;

    uvm_analysis_port #(dma_mem_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual dma_axi_if)::get(this, "", "axi_vif", axi_vif))
            `uvm_fatal("CFG", "axi_vif not set")
    endfunction

    task run_phase(uvm_phase phase);
        init_memory();
        fork
            handle_reads();
            handle_writes();
        join
    endtask

    task init_memory();
        for (int i = 0; i < 32'h4000; i++)
            mem[32'h0000_1000 + i] = i[7:0];
        for (int i = 0; i < 32'h1000; i++)
            mem[32'hC000_0000 + i] = 8'h0;
    endtask

    // Poll helper: wait until signal is 1, checking every slave_cb edge
    task wait_for_high_ar();
        int unsigned wait_cycles;
        wait_cycles = 0;
        while (!axi_vif.arvalid) begin
            @(axi_vif.slave_cb);
            wait_cycles++;
            if (wait_cycles >= axi_wait_timeout_cycles)
                `uvm_fatal("AXI_TIMEOUT", "Timed out waiting for arvalid")
        end
    endtask
    task wait_for_high_r();
        int unsigned wait_cycles;
        wait_cycles = 0;
        while (!axi_vif.rready) begin
            @(axi_vif.slave_cb);
            wait_cycles++;
            if (wait_cycles >= axi_wait_timeout_cycles)
                `uvm_fatal("AXI_TIMEOUT", "Timed out waiting for rready")
        end
    endtask
    task wait_for_high_aw();
        int unsigned wait_cycles;
        wait_cycles = 0;
        while (!axi_vif.awvalid) begin
            @(axi_vif.slave_cb);
            wait_cycles++;
            if (wait_cycles >= axi_wait_timeout_cycles)
                `uvm_fatal("AXI_TIMEOUT", "Timed out waiting for awvalid")
        end
    endtask
    task wait_for_high_w();
        int unsigned wait_cycles;
        wait_cycles = 0;
        while (!axi_vif.wvalid) begin
            @(axi_vif.slave_cb);
            wait_cycles++;
            if (wait_cycles >= axi_wait_timeout_cycles)
                `uvm_fatal("AXI_TIMEOUT", "Timed out waiting for wvalid")
        end
    endtask
    task wait_for_high_bready();
        int unsigned wait_cycles;
        wait_cycles = 0;
        while (!axi_vif.bready) begin
            @(axi_vif.slave_cb);
            wait_cycles++;
            if (wait_cycles >= axi_wait_timeout_cycles)
                `uvm_fatal("AXI_TIMEOUT", "Timed out waiting for bready")
        end
    endtask

    task handle_reads();
        logic [31:0] addr;
        logic [7:0]  len;
        logic [2:0]  size;
        logic [3:0]  id;
        int          delay;
        logic [63:0] rdata;
        logic [1:0]  rresp;

        axi_vif.slave_cb.arready <= 0;
        axi_vif.slave_cb.rvalid  <= 0;
        axi_vif.slave_cb.rid     <= 0;
        axi_vif.slave_cb.rdata   <= 0;
        axi_vif.slave_cb.rresp   <= 0;
        axi_vif.slave_cb.rlast   <= 0;
        do begin @(posedge axi_vif.clk); end while (!axi_vif.rst_n);

        forever begin
            // Optional backpressure before accepting AR
            delay = $urandom_range(0, rd_ready_delay_max);
            repeat(delay) @(axi_vif.slave_cb);

            axi_vif.slave_cb.arready <= 1;
            // FIX: explicit poll instead of iff guard
            wait_for_high_ar();
            @(axi_vif.slave_cb);         // sample on the handshake edge
            addr = axi_vif.araddr;
            len  = axi_vif.arlen;
            size = axi_vif.arsize;
            id   = axi_vif.arid;
            axi_vif.slave_cb.arready <= 0;

            for (int beat = 0; beat <= len; beat++) begin
                delay = $urandom_range(0, rd_ready_delay_max);
                repeat(delay) @(axi_vif.slave_cb);

                rdata = read_mem(addr + beat * (1 << size), size);

                if (inject_read_err &&
                    ((addr & err_addr_mask) == (32'hBAD0_0000 & err_addr_mask)))
                    rresp = 2'b10;
                else
                    rresp = 2'b00;

                axi_vif.slave_cb.rvalid <= 1;
                axi_vif.slave_cb.rid    <= id;
                axi_vif.slave_cb.rdata  <= rdata;
                axi_vif.slave_cb.rresp  <= rresp;
                axi_vif.slave_cb.rlast  <= (beat == len);
                // FIX: explicit poll instead of iff guard
                wait_for_high_r();
                @(axi_vif.slave_cb);     // consume the handshake cycle
                axi_vif.slave_cb.rvalid <= 0;
                axi_vif.slave_cb.rlast  <= 0;
            end
        end
    endtask

    task handle_writes();
        logic [31:0]   addr;
        logic [7:0]    len;
        logic [3:0]    id;
        logic [63:0]   wdata;
        logic [7:0]    wstrb;
        logic [1:0]    bresp;
        int            delay;

        axi_vif.slave_cb.awready <= 0;
        axi_vif.slave_cb.wready  <= 0;
        axi_vif.slave_cb.bvalid  <= 0;
        axi_vif.slave_cb.bresp   <= 0;
        axi_vif.slave_cb.bid     <= 0;
        do begin @(posedge axi_vif.clk); end while (!axi_vif.rst_n);

        forever begin
            delay = $urandom_range(0, wr_ready_delay_max);
            repeat(delay) @(axi_vif.slave_cb);

            axi_vif.slave_cb.awready <= 1;
            // FIX: explicit poll instead of iff guard
            wait_for_high_aw();
            @(axi_vif.slave_cb);         // sample on the handshake edge
            addr = axi_vif.awaddr;
            len  = axi_vif.awlen;
            id   = axi_vif.awid;
            axi_vif.slave_cb.awready <= 0;

            bresp = 2'b00;
            for (int beat = 0; beat <= len; beat++) begin
                delay = $urandom_range(0, wr_ready_delay_max);
                repeat(delay) @(axi_vif.slave_cb);
                axi_vif.slave_cb.wready <= 1;
                // FIX: explicit poll instead of iff guard
                wait_for_high_w();
                @(axi_vif.slave_cb);     // sample on the handshake edge
                wdata = axi_vif.wdata;
                wstrb = axi_vif.wstrb;
                axi_vif.slave_cb.wready <= 0;

                if (inject_write_err && beat == 0 &&
                    ((addr & err_addr_mask) == (32'hBAD1_0000 & err_addr_mask)))
                    bresp = 2'b10;
                else
                    write_mem(addr + beat * 8, wdata, wstrb);
            end

            @(axi_vif.slave_cb);
            axi_vif.slave_cb.bvalid <= 1;
            axi_vif.slave_cb.bid    <= id;
            axi_vif.slave_cb.bresp  <= bresp;
            // FIX: explicit poll instead of iff guard
            wait_for_high_bready();
            @(axi_vif.slave_cb);
            axi_vif.slave_cb.bvalid <= 0;
        end
    endtask

    function logic [63:0] read_mem(logic [31:0] addr, logic [2:0] size);
        logic [63:0] data = '0;
        int bytes = 1 << size;
        for (int b = 0; b < bytes; b++)
            data[b*8+:8] = mem.exists(addr+b) ? mem[addr+b] : 8'hAD;
        return data;
    endfunction

    function void write_mem(logic [31:0] addr, logic [63:0] data, logic [7:0] strb);
        for (int b = 0; b < 8; b++)
            if (strb[b]) mem[addr+b] = data[b*8+:8];
    endfunction

    function logic [7:0] backdoor_read(logic [31:0] addr);
        // Match the live AXI read path so the scoreboard sees the same fill
        // pattern the DUT would observe for uninitialized memory holes.
        return mem.exists(addr) ? mem[addr] : 8'hAD;
    endfunction

endclass


//=============================================================================
// AXI Bus Monitor
//=============================================================================
class dma_axi_mem_monitor extends uvm_monitor;
    `uvm_component_utils(dma_axi_mem_monitor)

    virtual dma_axi_if.monitor_mp axi_vif;
    uvm_analysis_port #(dma_mem_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual dma_axi_if)::get(this, "", "axi_vif", axi_vif))
            `uvm_fatal("CFG", "axi_vif not set")
    endfunction

    task run_phase(uvm_phase phase);
        fork
            monitor_reads();
            monitor_writes();
        join
    endtask

    task monitor_reads();
        dma_mem_seq_item item;
        logic [31:0] addr;
        logic [7:0]  len;
        logic [3:0]  id;

        do begin @(posedge axi_vif.clk); end while (!axi_vif.rst_n);
        forever begin
            // Monitor only: iff guards are acceptable here (no deadlock risk
            // since monitor never drives anything, just samples)
            @(axi_vif.monitor_cb iff (axi_vif.monitor_cb.arvalid === 1'b1 &&
                                      axi_vif.monitor_cb.arready === 1'b1));
            addr = axi_vif.monitor_cb.araddr;
            len  = axi_vif.monitor_cb.arlen;
            id   = axi_vif.monitor_cb.arid;

            item = dma_mem_seq_item::type_id::create("rd_item");
            item.txn_type     = dma_mem_seq_item::READ;
            item.addr         = addr;
            item.len          = len;
            item.size         = axi_vif.monitor_cb.arsize;
            item.is_desc_fetch= (id[3:2] == 2'b00);
            item.channel_id   = id[1:0];
            item.data         = new[len+1];
            item.resp         = new[len+1];

            for (int beat = 0; beat <= len; beat++) begin
                @(axi_vif.monitor_cb iff (axi_vif.monitor_cb.rvalid === 1'b1 &&
                                          axi_vif.monitor_cb.rready === 1'b1));
                item.data[beat] = axi_vif.monitor_cb.rdata;
                item.resp[beat] = axi_vif.monitor_cb.rresp;
            end

            ap.write(item);
            `uvm_info("AXI_MON", item.convert2string(), UVM_HIGH)
        end
    endtask

    task monitor_writes();
        dma_mem_seq_item item;
        logic [31:0] addr;
        logic [7:0]  len;
        logic [3:0]  id;

        do begin @(posedge axi_vif.clk); end while (!axi_vif.rst_n);
        forever begin
            @(axi_vif.monitor_cb iff (axi_vif.monitor_cb.awvalid === 1'b1 &&
                                      axi_vif.monitor_cb.awready === 1'b1));
            addr = axi_vif.monitor_cb.awaddr;
            len  = axi_vif.monitor_cb.awlen;
            id   = axi_vif.monitor_cb.awid;

            item = dma_mem_seq_item::type_id::create("wr_item");
            item.txn_type   = dma_mem_seq_item::WRITE;
            item.addr       = addr;
            item.len        = len;
            item.size       = axi_vif.monitor_cb.awsize;
            item.channel_id = id[1:0];
            item.data       = new[len+1];
            item.resp       = new[1];

            for (int beat = 0; beat <= len; beat++) begin
                @(axi_vif.monitor_cb iff (axi_vif.monitor_cb.wvalid === 1'b1 &&
                                          axi_vif.monitor_cb.wready === 1'b1));
                item.data[beat] = axi_vif.monitor_cb.wdata;
            end

            @(axi_vif.monitor_cb iff (axi_vif.monitor_cb.bvalid === 1'b1 &&
                                      axi_vif.monitor_cb.bready === 1'b1));
            item.resp[0] = axi_vif.monitor_cb.bresp;

            ap.write(item);
        end
    endtask

endclass


//=============================================================================
// AXI Memory Sequencer + Agent
//=============================================================================
class dma_axi_mem_sequencer extends uvm_sequencer #(dma_seq_item);
    `uvm_component_utils(dma_axi_mem_sequencer)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass

class dma_axi_mem_agent extends uvm_agent;
    `uvm_component_utils(dma_axi_mem_agent)

    dma_axi_mem_driver    driver;
    dma_axi_mem_monitor   monitor;
    dma_axi_mem_sequencer sequencer;
    uvm_analysis_port #(dma_mem_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        monitor   = dma_axi_mem_monitor::type_id::create("monitor", this);
        ap        = new("ap", this);
        if (get_is_active() == UVM_ACTIVE) begin
            driver    = dma_axi_mem_driver::type_id::create("driver", this);
            sequencer = dma_axi_mem_sequencer::type_id::create("sequencer", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        monitor.ap.connect(ap);
    endfunction
endclass

`endif
