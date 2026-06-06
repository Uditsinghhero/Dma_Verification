`timescale 1ns / 1ps

module dma_engine #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 32,
    parameter ID_WIDTH   = 4,
    parameter NUM_CHANNELS = 4
)(
    input  logic clk,
    input  logic rst_n,

    // APB Slave Interface (CSRs)
    input  logic [11:0] paddr,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    // AXI Master Interface
    output logic [ID_WIDTH-1:0]   awid,
    output logic [ADDR_WIDTH-1:0] awaddr,
    output logic [7:0]            awlen,
    output logic [2:0]            awsize,
    output logic [1:0]            awburst,
    output logic                  awvalid,
    input  logic                  awready,

    output logic [DATA_WIDTH-1:0]   wdata,
    output logic [DATA_WIDTH/8-1:0] wstrb,
    output logic                    wlast,
    output logic                    wvalid,
    input  logic                    wready,

    input  logic [ID_WIDTH-1:0]   bid,
    input  logic [1:0]            bresp,
    input  logic                  bvalid,
    output logic                  bready,

    output logic [ID_WIDTH-1:0]   arid,
    output logic [ADDR_WIDTH-1:0] araddr,
    output logic [7:0]            arlen,
    output logic [2:0]            arsize,
    output logic [1:0]            arburst,
    output logic                  arvalid,
    input  logic                  arready,

    input  logic [ID_WIDTH-1:0]   rid,
    input  logic [DATA_WIDTH-1:0] rdata,
    input  logic [1:0]            rresp,
    input  logic                  rlast,
    input  logic                  rvalid,
    output logic                  rready,

    // Interrupts
    output logic [NUM_CHANNELS-1:0] irq,
    output logic [NUM_CHANNELS-1:0] ch_active,
    output logic                    dma_busy
);

    //---------------------------------------------------------
    // CSR Registers
    //---------------------------------------------------------
    logic        global_en;
    logic        ch_en      [NUM_CHANNELS];
    logic        ch_start   [NUM_CHANNELS];
    logic        ch_irq_en  [NUM_CHANNELS];
    logic [31:0] ch_desc_addr [NUM_CHANNELS];
    logic [7:0]  ch_burst_len [NUM_CHANNELS];
    logic        ch_done    [NUM_CHANNELS];
    logic        ch_error   [NUM_CHANNELS];

    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            global_en <= 0;
            for (int i = 0; i < NUM_CHANNELS; i++) begin
                ch_en[i]        <= 0;
                ch_start[i]     <= 0;
                ch_irq_en[i]    <= 0;
                ch_desc_addr[i] <= 0;
                ch_burst_len[i] <= 1;
            end
        end else begin
            // Clear start bits automatically when channel completes
            for (int i = 0; i < NUM_CHANNELS; i++) begin
                if (ch_done[i]) ch_start[i] <= 1'b0;
            end

            if (psel && penable && pwrite) begin
                if (paddr == 12'h000) begin
                    global_en <= pwdata[0];
                end else begin
                    for (int i = 0; i < NUM_CHANNELS; i++) begin
                        if (paddr == 12'h100 + i*12'h100 + 12'h00) begin
                            ch_en[i]     <= pwdata[0];
                            ch_start[i]  <= pwdata[1];
                            ch_irq_en[i] <= pwdata[3];
                        end else if (paddr == 12'h100 + i*12'h100 + 12'h04) begin
                            ch_desc_addr[i] <= pwdata;
                        end else if (paddr == 12'h100 + i*12'h100 + 12'h10) begin
                            ch_burst_len[i] <= pwdata[7:0];
                        end
                    end
                end
            end
        end
    end

    always_comb begin
        prdata = 32'h0;
        if (psel && !pwrite) begin
            if (paddr == 12'h000) begin
                prdata = {31'h0, global_en};
            end else begin
                for (int i = 0; i < NUM_CHANNELS; i++) begin
                    if (paddr == 12'h100 + i*12'h100 + 12'h00)
                        prdata = {ch_error[i], 26'h0, ch_done[i], ch_irq_en[i],
                                  1'b0, ch_start[i], ch_en[i]};
                    else if (paddr == 12'h100 + i*12'h100 + 12'h04)
                        prdata = ch_desc_addr[i];
                    else if (paddr == 12'h100 + i*12'h100 + 12'h10)
                        prdata = {24'h0, ch_burst_len[i]};
                end
            end
        end
    end

    //---------------------------------------------------------
    // Main DMA FSM
    //---------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_AR_DESC,
        ST_R_DESC,
        ST_AR_DATA,
        ST_R_DATA,
        ST_AW_DATA,
        ST_W_DATA,
        ST_B_DATA,
        ST_NEXT_DESC,
        ST_DONE
    } state_t;

    state_t state;
    logic [1:0] curr_ch;

    // Descriptor fields latched from AXI reads
    logic [31:0] desc_src;
    logic [31:0] desc_dst;
    logic [15:0] desc_len;
    logic [3:0]  desc_flags;
    logic [31:0] desc_next;

    // Execution tracking
    logic [15:0] bytes_left;
    logic [31:0] curr_src;
    logic [31:0] curr_dst;

    // Burst buffer (max 16 beats of 64-bit = 128 bytes)
    logic [63:0] burst_buf  [16];
    logic [7:0]  burst_strb [16];
    logic [4:0]  burst_count;
    logic [4:0]  buf_rd_idx;
    logic [4:0]  buf_wr_idx;

    // AXI static attributes
    assign awburst = 2'b01; // INCR
    assign awsize  = 3'b011; // 8 bytes
    assign arburst = 2'b01;
    assign arsize  = 3'b011;

    // Round-robin channel arbitration
    logic [1:0] next_ch;
    logic       start_any;
    always_comb begin
        start_any = 0;
        next_ch   = curr_ch;
        if (global_en) begin
            for (int i = 1; i <= NUM_CHANNELS; i++) begin
                if (ch_start[(curr_ch + i) % NUM_CHANNELS]) begin
                    start_any = 1;
                    next_ch   = (curr_ch + i) % NUM_CHANNELS;
                    break;
                end
            end
        end
    end

    //=========================================================
    // FSM
    //
    // FIX SUMMARY for this version:
    //
    // FIX A (Bug #4 + original registered-valid fix):
    //   ST_AR_DESC / ST_AR_DATA: arvalid is asserted unconditionally on
    //   every cycle of the state. Handshake exit is gated on arvalid being
    //   ALREADY asserted (from previous cycle) when arready arrives. This
    //   correctly handles the one-cycle pipeline delay on registered outputs.
    //
    // FIX B (Bug #5 - ST_R_DESC curr_src/curr_dst wrong source):
    //   On rlast, curr_src and curr_dst are now loaded from desc_src and
    //   desc_dst (which were correctly latched from beat 0), NOT from
    //   rlast-beat rdata which contains desc_len/flags/next_ptr fields.
    //
    // FIX C (Bug #4 - ST_AR_DATA bytes_left==0 infinite loop):
    //   Removed the broken "reinit" branch in ST_AR_DATA. If bytes_left==0
    //   when entering ST_AR_DATA it means the descriptor had zero-length,
    //   which should go to ST_NEXT_DESC to check for SG chain continuation.
    //   The reinit was incorrect: it re-loaded bytes_left<=desc_len which
    //   was also 0, creating an infinite loop that hangs the simulation.
    //=========================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            curr_ch     <= 0;
            arvalid     <= 0;
            rready      <= 0;
            awvalid     <= 0;
            wvalid      <= 0;
            bready      <= 0;
            wdata       <= 0;
            wstrb       <= 0;
            wlast       <= 0;
            awaddr      <= 0;
            awlen       <= 0;
            awid        <= 0;
            araddr      <= 0;
            arlen       <= 0;
            arid        <= 0;
            buf_wr_idx  <= 0;
            buf_rd_idx  <= 0;
            burst_count <= 0;
            dma_busy    <= 0;
            bytes_left  <= 0;
            curr_src    <= 0;
            curr_dst    <= 0;
            desc_src    <= 0;
            desc_dst    <= 0;
            desc_len    <= 0;
            desc_flags  <= 0;
            desc_next   <= 0;
            for (int i = 0; i < NUM_CHANNELS; i++) begin
                ch_done[i]  <= 0;
                ch_error[i] <= 0;
                irq[i]      <= 0;
            end
        end else begin
            // Auto-clear arvalid/awvalid after successful handshake
            if (arvalid && arready) arvalid <= 0;
            if (awvalid && awready) awvalid <= 0;

            // Clear IRQ/done on new channel start
            for (int i = 0; i < NUM_CHANNELS; i++) begin
                if (ch_start[i]) begin
                    irq[i]     <= 0;
                    ch_done[i] <= 0;
                end
            end

            case (state)
                //-----------------------------------------------------
                ST_IDLE: begin
                    dma_busy <= 0;
                    if (start_any) begin
                        curr_ch  <= next_ch;
                        state    <= ST_AR_DESC;
                        dma_busy <= 1;
                    end
                end

                //-----------------------------------------------------
                // Assert arvalid unconditionally each cycle of this state.
                // Only exit when arvalid was ALREADY 1 (previous cycle) and
                // arready arrives - ensuring the slave saw a stable valid.
                ST_AR_DESC: begin
                    arvalid <= 1;
                    araddr  <= ch_desc_addr[curr_ch];
                    arlen   <= 8'h01; // 2-beat burst: beat0=src/dst, beat1=len/flags/next
                    arid    <= {2'b00, curr_ch};
                    if (arvalid && arready) begin
                        state      <= ST_R_DESC;
                        rready     <= 1;
                        buf_wr_idx <= 0;
                    end
                end

                //-----------------------------------------------------
                // FIX B: On rlast, load curr_src/curr_dst from desc_src/
                // desc_dst (latched from beat 0) not from rlast rdata.
                // rlast rdata contains desc_len[15:0], desc_flags[23:16],
                // desc_next[63:32] - NOT src/dst addresses.
                ST_R_DESC: begin
                    if (rvalid && rready) begin
                        if (buf_wr_idx == 0) begin
                            // Beat 0: rdata[31:0]=src_addr, rdata[63:32]=dst_addr
                            desc_src <= rdata[31:0];
                            desc_dst <= rdata[63:32];
                        end else begin
                            // Beat 1 (rlast): rdata[15:0]=len, rdata[23:16]=flags,
                            //                 rdata[63:32]=next_ptr
                            desc_len   <= rdata[15:0];
                            desc_flags <= rdata[23:16];
                            desc_next  <= rdata[63:32];
                        end
                        buf_wr_idx <= buf_wr_idx + 1;

                        if (rlast) begin
                            rready     <= 0;
                            // FIX B: curr_src/curr_dst come from beat-0 latches
                            curr_src   <= desc_src;   // set from beat 0 above
                            curr_dst   <= desc_dst;   // set from beat 0 above
                            bytes_left <= rdata[15:0]; // desc_len from beat 1
                            state      <= ST_AR_DATA;
                        end
                    end
                end

                //-----------------------------------------------------
                // FIX C: Removed the bytes_left==0 "reinit" branch.
                // If bytes_left is 0 here, the descriptor had zero transfer
                // length - go directly to ST_NEXT_DESC to handle SG chain.
                // The old reinit code (bytes_left<=desc_len when desc_len=0)
                // created an infinite loop because bytes_left never became
                // non-zero, keeping the FSM stuck here forever.
                ST_AR_DATA: begin
                    if (bytes_left == 0) begin
                        // Zero-length descriptor: skip to SG chain check
                        state <= ST_NEXT_DESC;
                    end else begin
                        arvalid <= 1;
                        araddr  <= curr_src;
                        arid    <= {2'b01, curr_ch};
                        if (bytes_left > ({8'h0, ch_burst_len[curr_ch]} * 8)) begin
                            arlen       <= ch_burst_len[curr_ch] - 1;
                            burst_count <= ch_burst_len[curr_ch];
                        end else begin
                            arlen       <= (bytes_left - 1) / 8;
                            burst_count <= (bytes_left - 1) / 8 + 1;
                        end
                        // Exit only after arvalid was already high last cycle
                        if (arvalid && arready) begin
                            state      <= ST_R_DATA;
                            rready     <= 1;
                            buf_wr_idx <= 0;
                        end
                    end
                end

                //-----------------------------------------------------
                ST_R_DATA: begin
                    if (rvalid && rready) begin
                        burst_buf[buf_wr_idx]  <= rdata;
                        burst_strb[buf_wr_idx] <= 8'hFF;
                        if (rresp != 2'b00) ch_error[curr_ch] <= 1;
                        buf_wr_idx <= buf_wr_idx + 1;
                        if (rlast) begin
                            rready <= 0;
                            state  <= ST_AW_DATA;
                        end
                    end
                end

                //-----------------------------------------------------
                ST_AW_DATA: begin
                    awvalid <= 1;
                    awaddr  <= curr_dst;
                    awlen   <= burst_count - 1;
                    awid    <= {2'b10, curr_ch};
                    if (awvalid && awready) begin
                        state      <= ST_W_DATA;
                        buf_rd_idx <= 0;
                        // Preload the first W beat before asserting wvalid so
                        // the slave never samples stale data from a prior burst.
                        wdata      <= burst_buf[0];
                        wstrb      <= burst_strb[0];
                        wlast      <= (burst_count == 1);
                        wvalid     <= 1;
                    end
                end

                //-----------------------------------------------------
                ST_W_DATA: begin
                    if (wvalid && wready) begin
                        if (buf_rd_idx == burst_count - 1) begin
                            wvalid <= 0;
                            wlast  <= 0;
                            bready <= 1;
                            state  <= ST_B_DATA;
                        end else begin
                            buf_rd_idx <= buf_rd_idx + 1;
                            wdata      <= burst_buf[buf_rd_idx + 1];
                            wstrb      <= burst_strb[buf_rd_idx + 1];
                            wlast      <= (buf_rd_idx + 1 == burst_count - 1);
                        end
                    end
                end

                //-----------------------------------------------------
                ST_B_DATA: begin
                    if (bvalid && bready) begin
                        bready <= 0;
                        if (bresp != 2'b00) ch_error[curr_ch] <= 1;
                        curr_src <= curr_src + burst_count * 8;
                        curr_dst <= curr_dst + burst_count * 8;
                        if (bytes_left <= burst_count * 8) begin
                            bytes_left <= 0;
                            state      <= ST_NEXT_DESC;
                        end else begin
                            bytes_left <= bytes_left - burst_count * 8;
                            state      <= ST_AR_DATA;
                        end
                    end
                end

                //-----------------------------------------------------
                ST_NEXT_DESC: begin
                    if (desc_flags[0] == 1'b1) begin
                        // SG chain continues: follow next_ptr
                        ch_desc_addr[curr_ch] <= desc_next;
                        state <= ST_AR_DESC;
                    end else begin
                        state <= ST_DONE;
                    end
                end

                //-----------------------------------------------------
                ST_DONE: begin
                    ch_done[curr_ch] <= 1;
                    if (desc_flags[1] || ch_irq_en[curr_ch])
                        irq[curr_ch] <= 1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // Channel active status (combinatorial)
    always_comb begin
        for (int i = 0; i < NUM_CHANNELS; i++)
            ch_active[i] = (curr_ch == i[1:0] && state != ST_IDLE);
    end

endmodule
