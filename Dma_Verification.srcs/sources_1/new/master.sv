`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/28/2026 11:44:45 PM
// Design Name: 
// Module Name: master
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

interface ms_if(input clk);

    logic sready;
    logic rstn;
    logic [1:0] addr;
    logic [7:0] data;

    modport slave (
        input addr, data, rstn, clk,
        output sready
    );

    modport master (
        output addr, data,
        input clk, sready, rstn
    );

endinterface

module master(ms_if.master mif);

    always @(posedge mif.clk) begin

        if (!mif.rstn) begin
            mif.addr <= 0;
            mif.data <= 0;

        end else begin

            if (mif.sready) begin
                mif.addr <= mif.addr + 1;
                mif.data <= (mif.addr * 4);

            end else begin
                mif.addr <= mif.addr;
                mif.data <= mif.data;
            end

        end
    end

endmodule