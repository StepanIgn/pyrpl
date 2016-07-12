/*
###############################################################################
#    pyrpl - DSP servo controller for quantum optics with the RedPitaya
#    Copyright (C) 2014-2016  Leonhard Neuhaus  (neuhaus@spectro.jussieu.fr)
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
############################################################################### 
*/
//`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: LKB
// Engineer: Leonhard Neuhaus 
// 
// Create Date: 10.12.2015 13:03:05
// Design Name: 
// Module Name: red_pitaya_iir_block
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
// Design considerations
// Try: Filter coefficients are represented as 100 bit numbers in IQ module
// Upon a custom command, all coefficients are updated
// Data for multiplication are always 18 bit numbers 
// Must properly treat overflow conditions
// Arbitrary (max 16) sequential execution of parallel modules
// Choice over ZOH or averaging of input during the 16 sequences
// maximum specs: 16 biquad iir filters, each with 4 coefficients with 128 bits
//-> 128*4 = 512 * 16 = 8092 bits! for representing such a large number, we need already
// 12 address bits! where does this fit into the address space of the pid module?
//address: 0x20000 or 0x30000-> treated by iq module
//set address bit 16: goes into fgen module -> 0x2zzzz is free
//0x2n000 for IQ-module number n


//diret form:
//
//           sum_k^M ( b_k * z^-k )             b_0 + b_1/z
//   H(z) = ---------------------------  = ------------------------  
//           1 - sum_k^N ( a_k * z^-k)       1 - a_1/z - a_2/z^2
//              
//   can be transformed into a difference equation:
//   y[n] = a_1 * y_(n-1) + a_2 * y_(n-2) + b_0 * x(n) + b_1 * x(n-1)  
//
// we thus have to compute 4 products
//////////////////////////////////////////////////////////////////////////////////

module red_pitaya_iir_block
#(  parameter IIRBITS = 46,         // iir coefficients represented with IIRBITS bits
    parameter IIRSHIFT = 30,        // iir coefficients FIXED POINT at bit IIRSHIFT
    parameter IIRSTAGES = 8,        // maximum number of parallel biquads 
    parameter IIRSIGNALBITS = 36,   // internally represent calculated results with IIRSIGNALBITS bits (maybe overkill?)
    parameter SIGNALBITS = 14,      // in- and output signal bitwidth
    parameter SIGNALSHIFT = 0       // over-represent input by SIGNALSHIFT bits (e.g. once input averaging is implemented)
    )
    (
   // data
   input                 clk_i           ,  // clock
   input                 rstn_i          ,  // reset - active low
   input      [ 14-1: 0] dat_i           ,  // input data
   output reg [ 14-1: 0] dat_o           ,  // output data

   // communication with PS
   input      [ 16-1: 0] addr,
   input                 wen,
   input                 ren,
   output reg   		 ack,
   output reg [ 32-1: 0] rdata,
   input      [ 32-1: 0] wdata
);


reg [8-1:0]     loops;
reg     		on; 
reg     		shortcut;
reg     		copydata;
reg [32-1:0]    overflow;   // accumulated overflows
wire [7-1:0]    overflow_i; // instantaneous overflows
reg [32-1:0]    iir_coefficients [0:IIRSTAGES*4*2-1];

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      loops <= 8'd0;
      on <= 1'b0;
      shortcut <= 1'b0;
      copydata <= 1'b1;
   end
   else begin
      if (wen) begin
         if (addr==16'h100)   loops <= wdata[8-1:0];
         if (addr==16'h104)   {copydata,shortcut,on} <= wdata[3-1:0];
    
         if (addr[16-1]==1'b1)   iir_coefficients[addr[12-1:2]] <= wdata;
      end

	  casez (addr)
	     16'h100 : begin ack <= wen|ren; rdata <= {{32-8{1'b0}},loops}; end
	     16'h104 : begin ack <= wen|ren; rdata <= {{32-1{1'b0}},copydata,shortcut,on}; end
	     16'h108 : begin ack <= wen|ren; rdata <= overflow; end
		 
		 16'h200 : begin ack <= wen|ren; rdata <= IIRBITS; end
		 16'h204 : begin ack <= wen|ren; rdata <= IIRSHIFT; end
		 16'h208 : begin ack <= wen|ren; rdata <= IIRSTAGES; end
		 
		 // disable read-back of coefficients to save resources
		 // this makes a big difference since it will allow the implementation of 
		 // the coefficients ass RAM and not as registers
		 // 16'b1zzzzzzzzzzzzzzz: 	 begin ack <= wen|ren; rdata <= iir_coefficients[addr[12-1:2]]; end    

	     default: begin ack <= wen|ren;  rdata <=  32'h0; end 
	  endcase	     
   end
end


/*
//coefficient management - update coefficients when requested by copydata high transition
reg signed [IIRBITS-1:0] b0_i [0:IIRSTAGES-1];
reg signed [IIRBITS-1:0] b1_i [0:IIRSTAGES-1];
reg signed [IIRBITS-1:0] a1_i [0:IIRSTAGES-1];
reg signed [IIRBITS-1:0] a2_i [0:IIRSTAGES-1];

integer i;
always @(posedge clk_i) begin
    if (copydata == 1'b1) begin
        for (i=0;i<IIRSTAGES;i=i+1) begin
            b0_i[i] <= {iir_coefficients[8*i+1],iir_coefficients[8*i+0]};//{iir_coefficients[16*i+3],iir_coefficients[16*i+2],iir_coefficients[16*i+1],iir_coefficients[16*i+0]};
            b1_i[i] <= {iir_coefficients[8*i+3],iir_coefficients[8*i+2]};//{iir_coefficients[16*i+7],iir_coefficients[16*i+6],iir_coefficients[16*i+5],iir_coefficients[16*i+4]};
            a1_i[i] <= {iir_coefficients[8*i+5],iir_coefficients[8*i+4]};//{iir_coefficients[16*i+11],iir_coefficients[16*i+10],iir_coefficients[16*i+9],iir_coefficients[16*i+8]};
            a2_i[i] <= {iir_coefficients[8*i+7],iir_coefficients[8*i+6]};//{iir_coefficients[16*i+15],iir_coefficients[16*i+14],iir_coefficients[16*i+13],iir_coefficients[16*i+12]};
        end
    end        
end
*/

// coefficient management more resource-friendly - only one memory for
// coefficients, update immediately -> requires reset after coefficient write
wire signed [IIRBITS-1:0] b0_i [0:IIRSTAGES-1];
wire signed [IIRBITS-1:0] b1_i [0:IIRSTAGES-1];
wire signed [IIRBITS-1:0] a1_i [0:IIRSTAGES-1];
wire signed [IIRBITS-1:0] a2_i [0:IIRSTAGES-1];

integer i; // for later use
genvar j;
generate for (j=0; j<IIRSTAGES; j=j+1) begin
    assign b0_i[j] = {iir_coefficients[8*j+1],iir_coefficients[8*j+0]};
    assign b1_i[j] = {iir_coefficients[8*j+3],iir_coefficients[8*j+2]};
    assign a1_i[j] = {iir_coefficients[8*j+5],iir_coefficients[8*j+4]};
    assign a2_i[j] = {iir_coefficients[8*j+7],iir_coefficients[8*j+6]};
    end
endgenerate

// loop management - let stage0 repeatedly run from loops-1 to 0
// stage_n contains the number stage0 with n cycles of delay
reg [8-1:0] stage0;
reg [8-1:0] stage1;
reg [8-1:0] stage2;
reg [8-1:0] stage3;
reg [8-1:0] stage4;
reg [8-1:0] stage5;
always @(posedge clk_i) begin
    if (on==1'b0) begin
        overflow <= 32'h00000000;
        stage0 <= loops;
        stage1 <= 8'h00;
        stage2 <= 8'h00;
        stage3 <= 8'h00;
        stage4 <= 8'h00;
        stage5 <= 8'h00;
    end
    else begin
        overflow <= overflow | overflow_i;
        if (stage0 == 8'h00)
            stage0 <= loops - 8'h01;
        else
            stage0 <= stage0 - 8'h01; 
    end
    stage1 <= stage0;
    stage2 <= stage1;
    stage3 <= stage2;
    stage4 <= stage3;
    stage5 <= stage4;
end

//actual signal treatment
reg signed [IIRBITS-1:0] a1;
reg signed [IIRBITS-1:0] a2;
reg signed [IIRBITS-1:0] b0;
reg signed [IIRBITS-1:0] b1;

wire signed [IIRSIGNALBITS-1:0] x0;
assign x0 = {{IIRSIGNALBITS-SIGNALSHIFT-SIGNALBITS+1{dat_i[SIGNALBITS-1]}},dat_i[SIGNALBITS-2:0],{SIGNALSHIFT{1'b0}}};

reg signed [IIRSIGNALBITS-1:0] y0;
reg signed [IIRSIGNALBITS-1:0] y1a;
reg signed [IIRSIGNALBITS-1:0] y2a;
reg signed [IIRSIGNALBITS-1:0] y1b;

reg signed [IIRSIGNALBITS-1:0] y1_i [0:IIRSTAGES-1];
reg signed [IIRSIGNALBITS-1:0] y2_i [0:IIRSTAGES-1];
reg signed [IIRSIGNALBITS-1:0] z1_i [0:IIRSTAGES-1];

wire signed [IIRSIGNALBITS-1:0] p_ay1_full;
wire signed [IIRSIGNALBITS-1:0] p_ay2_full;

red_pitaya_product_sat #( .BITS_IN1(IIRSIGNALBITS), .BITS_IN2(IIRBITS), .SHIFT(IIRSHIFT), .BITS_OUT(IIRSIGNALBITS))
 p_ay1_module (
  .factor1_i(y1a),
  .factor2_i(a1),
  .product_o(p_ay1_full),
  .overflow (overflow_i[0])
  );
red_pitaya_product_sat #( .BITS_IN1(IIRSIGNALBITS), .BITS_IN2(IIRBITS), .SHIFT(IIRSHIFT), .BITS_OUT(IIRSIGNALBITS))
   p_ay2_module (
    .factor1_i(y2a),
    .factor2_i(a2),
    .product_o(p_ay2_full),
    .overflow (overflow_i[1])
    );
reg signed [IIRSIGNALBITS-1:0] p_ay1;
reg signed [IIRSIGNALBITS-1:0] p_ay2;

wire signed [IIRSIGNALBITS+2-1:0] y0_sum;
assign y0_sum = x0 + p_ay1 + p_ay2;
wire signed [IIRSIGNALBITS-1:0] y0_full;
red_pitaya_saturate #( .BITS_IN (IIRSIGNALBITS+2), .SHIFT(0), .BITS_OUT(IIRSIGNALBITS))
   s_y0_module (
   .input_i(y0_sum),
   .output_o(y0_full),
   .overflow (overflow_i[2])
    );

wire signed [IIRSIGNALBITS-1:0] p_by0_full;
wire signed [IIRSIGNALBITS-1:0] p_by1_full;
red_pitaya_product_sat #( .BITS_IN1(IIRSIGNALBITS), .BITS_IN2(IIRBITS), .SHIFT(IIRSHIFT), .BITS_OUT(IIRSIGNALBITS))
 p_by0_module (
  .factor1_i(y0),
  .factor2_i(b0),
  .product_o(p_by0_full),
  .overflow (overflow_i[3])
   );
red_pitaya_product_sat #( .BITS_IN1(IIRSIGNALBITS), .BITS_IN2(IIRBITS), .SHIFT(IIRSHIFT), .BITS_OUT(IIRSIGNALBITS))
   p_by1_module (
    .factor1_i(y1b),
    .factor2_i(b1),
    .product_o(p_by1_full),
    .overflow (overflow_i[4])
     );
reg signed [IIRSIGNALBITS-1:0] p_by0;
reg signed [IIRSIGNALBITS-1:0] p_by1;

wire signed [IIRSIGNALBITS+2-1:0] z0_sum;
assign z0_sum = p_by0 + p_by1;
wire signed [IIRSIGNALBITS-1:0] z0_full;
red_pitaya_saturate #( 
    .BITS_IN (IIRSIGNALBITS+2), 
    .SHIFT(0), 
    .BITS_OUT(IIRSIGNALBITS)
    )
   s_z0_module (
   .input_i(z0_sum),
   .output_o(z0_full),
   .overflow (overflow_i[5])
   );   
reg signed [IIRSIGNALBITS-1:0] z0;
reg signed [IIRSIGNALBITS-1:0] z1;

reg signed [IIRSIGNALBITS+4-1:0] dat_o_sum;
always @(*) begin
   dat_o_sum = z1_i[0];
   for (i=1;i<IIRSTAGES;i=i+1)
       dat_o_sum = dat_o_sum + z1_i[i];
end

wire [SIGNALBITS-1:0] dat_o_full;
red_pitaya_saturate #( .BITS_IN (IIRSIGNALBITS+4), .SHIFT(SIGNALSHIFT), .BITS_OUT(SIGNALBITS))
   s_dat_o_module (
   .input_i(dat_o_sum),
   .output_o(dat_o_full),
   .overflow (overflow_i[6])
   );   
reg signed [SIGNALBITS-1:0] signal_o;

always @(posedge clk_i) begin
    if (on==1'b0) begin
            for (i=0;i<IIRSTAGES;i=i+1) begin
                y1_i[i] <= {IIRSIGNALBITS{1'b0}};
                y2_i[i] <= {IIRSIGNALBITS{1'b0}};
                z1_i[i] <= {IIRSIGNALBITS{1'b0}};
            end
        y0  <= {IIRSIGNALBITS{1'b0}};
        y1a <= {IIRSIGNALBITS{1'b0}};
        y2a <= {IIRSIGNALBITS{1'b0}};
        y1b <= {IIRSIGNALBITS{1'b0}};
        z1 <= {IIRSIGNALBITS{1'b0}};
        z0 <= {IIRSIGNALBITS{1'b0}};

        a1 <= {IIRBITS{1'b0}};
        a2 <= {IIRBITS{1'b0}};
        b0 <= {IIRBITS{1'b0}};
        b1 <= {IIRBITS{1'b0}};
        
        p_ay1 <= {IIRSIGNALBITS{1'b0}};
        p_ay2 <= {IIRSIGNALBITS{1'b0}};
        p_by0 <= {IIRSIGNALBITS{1'b0}};
        p_by1 <= {IIRSIGNALBITS{1'b0}};
        
        signal_o <= {SIGNALBITS{1'b0}};
        
        end
    else begin
        // the computation will stretch over several cycles. while each computation is performed once per cycle, we will 
        // follow the signal of one particular biquad element as its signals go through the different phases of computation
        // over subsequent cycles
        
        //cycle n 
        if (stage0<IIRSTAGES) begin
            y1a <= y1_i[stage0];
            a1 <= a1_i[stage0];
            y2a <= y2_i[stage0];
            a2 <= a2_i[stage0];
        end
        //cycle n+1
        if (stage1<IIRSTAGES) begin
            p_ay1 <= p_ay1_full;
            p_ay2 <= p_ay2_full;
            y2_i[stage1] <= y1a; //update y2 memory
        end
        //cycle n+2
        if (stage2<IIRSTAGES) begin
            y0 <= y0_full;//no saturation here, because y0 is two bits longer than other signals
            b0 <= b0_i[stage2];
            y1b <= y1_i[stage2];
            b1 <= b1_i[stage2];
            y1_i[stage2] <= y0_full; //update y1 memory
        end
        //cycle n+3
        if (stage3<IIRSTAGES) begin
            p_by0 <= p_by0_full;
            p_by1 <= p_by1_full;
            z1 <= z1_i[stage3];
        end
        //cycle n+4
        if (stage4<IIRSTAGES) begin
            z0 <= z0_full;
            z1_i[stage4] <= z0_full;
        end
        //cycle n+5
        //z1_i[stage5] <= z0;
        signal_o <= dat_o_full;
    end
    dat_o <= (shortcut==1'b1) ? dat_i : signal_o;
end

endmodule
