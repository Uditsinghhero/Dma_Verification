`timescale 1ns / 1ps

`ifndef DMA_COVERAGE_SV
`define DMA_COVERAGE_SV

class dma_coverage extends uvm_subscriber #(dma_seq_item);
    `uvm_component_utils(dma_coverage)

    dma_seq_item cov_item;

    // Covergroups
    covergroup cg_dma_trans;
        option.per_instance = 1;

        // Channel usage
        cp_channel: coverpoint cov_item.channel {
            bins ch0 = {0};
            bins ch1 = {1};
            bins ch2 = {2};
            bins ch3 = {3};
        }

        // Scatter-gather chain length
        cp_sg_depth: coverpoint cov_item.sg_depth {
            bins depth_1 = {1};
            bins depth_2 = {2};
            bins depth_4 = {4};
            bins depth_8 = {8};
            bins depth_16 = {16};
        }

        // Alignment of source and destination
        cp_src_align: coverpoint cov_item.src_addr[2:0] {
            bins aligned = {0};
            bins misaligned_1 = {1};
            bins misaligned_2 = {2};
            bins misaligned_3 = {3};
            bins misaligned_other = {[4:7]};
        }

        cp_dst_align: coverpoint cov_item.dst_addr[2:0] {
            bins aligned = {0};
            bins misaligned_1 = {1};
            bins misaligned_2 = {2};
            bins misaligned_3 = {3};
            bins misaligned_other = {[4:7]};
        }

        // Error injection
        cp_rd_err: coverpoint cov_item.inject_read_err {
            bins no_err = {0};
            bins err = {1};
        }

        cp_wr_err: coverpoint cov_item.inject_write_err {
            bins no_err = {0};
            bins err = {1};
        }

        // Cross products
        cross_sg_align: cross cp_sg_depth, cp_src_align;
        cross_err: cross cp_rd_err, cp_wr_err;

    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_dma_trans = new();
    endfunction

    function void write(dma_seq_item t);
        cov_item = t;
        cg_dma_trans.sample();
    endfunction

endclass

`endif
