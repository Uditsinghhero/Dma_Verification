`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/02/2026 12:01:18 PM
// Design Name: 
// Module Name: dma_seq_item
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
// DMA Sequence Item
// Represents one DMA descriptor-chain programming transaction
//=============================================================================

`ifndef DMA_SEQ_ITEM_SV
`define DMA_SEQ_ITEM_SV

class dma_seq_item extends uvm_sequence_item;
    `uvm_object_utils(dma_seq_item)

    //--------------------------------------------------
    // Descriptor fields (matches HW descriptor layout)
    //--------------------------------------------------
    rand logic [31:0]  src_addr;       // source address
    rand logic [31:0]  dst_addr;       // destination address
    rand logic [15:0]  xfer_len;       // transfer length in bytes
    rand logic [3:0]   flags;          // [0]=sg_valid [1]=irq [2]=src_fixed [3]=dst_fixed
    rand logic [31:0]  next_desc_ptr;  // next descriptor (scatter-gather)

    // Channel selection
    rand int unsigned  channel;        // 0..3

    // Transfer type
    rand logic [7:0]   burst_len;      // AXI burst length (1..16)

    // Scatter-gather chain
    rand int unsigned  sg_depth;       // number of descriptors in chain (1..16)

    // Error injection
    rand bit           inject_read_err;
    rand bit           inject_write_err;
    rand bit           inject_desc_err;  // corrupt descriptor fetch response

    // Alignment control (overrides randomization)
    rand logic [1:0]   src_align_mod;   // misalignment byte offset 0..3
    rand logic [1:0]   dst_align_mod;

    // Expected data (for scoreboard)
    logic [7:0]        exp_data[];

    //--------------------------------------------------
    // Constraints
    //--------------------------------------------------
    // Channel
    constraint c_channel {
        channel inside {[0:3]};
    }

    // Transfer length: 1..4096 bytes, never zero
    constraint c_xfer_len {
        xfer_len inside {[1:4096]};
        xfer_len > 0;
    }

    // Address alignment: 64-bit (8-byte) word-aligned by default
    constraint c_addr_aligned {
        (src_align_mod == 2'h0) -> (src_addr[2:0] == 3'h0);
        (dst_align_mod == 2'h0) -> (dst_addr[2:0] == 3'h0);
    }

    // Apply alignment modifiers
    constraint c_addr_misalign {
        src_addr[1:0] == src_align_mod;
        dst_addr[1:0] == dst_align_mod;
    }

    // Keep addresses in valid range, avoid 0 page
    constraint c_addr_range {
        src_addr inside {[32'h0000_1000 : 32'h0FFF_FFFF]};
        dst_addr inside {[32'h1000_0000 : 32'h1FFF_FFFF]};
        // No overlap between src and dst regions
    }

    // Burst length
    constraint c_burst_len {
        burst_len inside {[1:16]};
    }

    // SG chain depth
    constraint c_sg_depth {
        sg_depth inside {[1:16]};
    }

    // SG flag consistent with depth
    constraint c_sg_flag {
        (sg_depth > 1) -> (flags[0] == 1'b1);
        (sg_depth == 1) -> (flags[0] == 1'b0);
    }

    // Default: no errors
    constraint c_no_err_default {
        soft inject_read_err  == 1'b0;
        soft inject_write_err == 1'b0;
        soft inject_desc_err  == 1'b0;
    }

    // Alignment defaults to aligned
    constraint c_align_default {
        soft src_align_mod == 2'h0;
        soft dst_align_mod == 2'h0;
    }

    //--------------------------------------------------
    // Named constraint modes (selectively disabled)
    //--------------------------------------------------

    // Soft constraint: irq on complete for monitoring
    constraint c_irq_en {
        flags[1] == 1'b1;  // always request completion IRQ
    }

    // Prevent src and dst overlap
    constraint c_no_overlap {
        dst_addr > (src_addr + xfer_len + 32'hFF) ||
        src_addr > (dst_addr + xfer_len + 32'hFF);
    }

    function new(string name = "dma_seq_item");
        super.new(name);
    endfunction

    function void do_copy(uvm_object rhs);
        dma_seq_item rhs_;
        super.do_copy(rhs);
        if (!$cast(rhs_, rhs))
            `uvm_fatal("CAST", "do_copy cast failed")
        src_addr        = rhs_.src_addr;
        dst_addr        = rhs_.dst_addr;
        xfer_len        = rhs_.xfer_len;
        flags           = rhs_.flags;
        next_desc_ptr   = rhs_.next_desc_ptr;
        channel         = rhs_.channel;
        burst_len       = rhs_.burst_len;
        sg_depth        = rhs_.sg_depth;
        inject_read_err = rhs_.inject_read_err;
        inject_write_err= rhs_.inject_write_err;
        inject_desc_err = rhs_.inject_desc_err;
        src_align_mod   = rhs_.src_align_mod;
        dst_align_mod   = rhs_.dst_align_mod;
    endfunction

    function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        dma_seq_item rhs_;
        if (!$cast(rhs_, rhs)) return 0;
        return (super.do_compare(rhs, comparer) &&
                src_addr == rhs_.src_addr &&
                dst_addr == rhs_.dst_addr &&
                xfer_len == rhs_.xfer_len &&
                flags    == rhs_.flags    &&
                channel  == rhs_.channel);
    endfunction

    function string convert2string();
        return $sformatf(
            "DMA_ITEM: ch=%0d src=0x%08h dst=0x%08h len=%0d flags=0x%h sg_depth=%0d err=[r%0b,w%0b,d%0b]",
            channel, src_addr, dst_addr, xfer_len, flags, sg_depth,
            inject_read_err, inject_write_err, inject_desc_err);
    endfunction

endclass

`endif
