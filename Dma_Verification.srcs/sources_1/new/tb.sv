`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/28/2026 11:44:45 PM
// Design Name: 
// Module Name: tb
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


module tb;

    reg clk;

    always #10 clk = ~clk;

    ms_if tif(clk);

    top dut(tif);

    initial begin

        clk = 0;

        tif.rstn = 0;

        repeat (2) @(posedge clk);

        tif.rstn = 1;

        repeat (20) @(posedge clk);

        $finish;

    end

endmodule
