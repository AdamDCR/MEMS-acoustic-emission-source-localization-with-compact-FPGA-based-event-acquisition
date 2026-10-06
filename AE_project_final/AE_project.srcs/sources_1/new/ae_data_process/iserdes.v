`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// UTF-8
// Create Date: 2024/07/06 18:34:49
// Design Name: 
// Module Name: iserdes
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


module iserdes
(
    input                               clk                        ,    //  70MHz
    input                               div_clk                    ,    //  10MHz

    input                               io_reset                   ,
    input                               bitslip                    ,

    input                               data_i_p                   ,
    input                               data_i_n                   ,
    output               [  13: 0]      data_o                      
);

    wire                                data_i                      ;
    wire                                io_reset_sync               ;

IBUFDS #(
    .DIFF_TERM                          ("FALSE"                   ),
    .IOSTANDARD                         ("DEFAULT"                 ) 
)ibufds_inst(
    .I                                  (data_i_p                  ),
    .IB                                 (data_i_n                  ),
    .O                                  (data_i                    ) 
);

xpm_cdc_sync_rst #(
    .DEST_SYNC_FF                       (4                         ),// DECIMAL; range: 2-10
    .INIT                               (1                         ),
    .INIT_SYNC_FF                       (0                         ),// DECIMAL; 0=disable simulation init values, 1=enable simulation init values
    .SIM_ASSERT_CHK                     (0                         ) // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
)
xpm_cdc_sync_rst_inst (
    .dest_rst                           (io_reset_sync             ),// 1-bit output: src_rst synchronized to the destination clock domain. This output
    .dest_clk                           (div_clk                   ),// 1-bit input: Destination clock.
    .src_rst                            (io_reset                  ) // 1-bit input: Source reset signal.
);

    wire                                icascade1                   ;
    wire                                icascade2                   ;

ISERDESE2 #(
    .DATA_RATE                          ("DDR"                     ),
    .DATA_WIDTH                         (14                        ),
    .INTERFACE_TYPE                     ("NETWORKING"              ),
    .DYN_CLKDIV_INV_EN                  ("FALSE"                   ),
    .DYN_CLK_INV_EN                     ("FALSE"                   ),
    .NUM_CE                             (2                         ),
    .OFB_USED                           ("FALSE"                   ),
    .IOBDELAY                           ("NONE"                    ),
    .IS_CLKB_INVERTED                   (1'b1                      ),
    .SERDES_MODE                        ("MASTER"                  ) 
)iserdese2_master (
    .Q1                                 (data_o[0]                 ),
    .Q2                                 (data_o[1]                 ),
    .Q3                                 (data_o[2]                 ),
    .Q4                                 (data_o[3]                 ),
    .Q5                                 (data_o[4]                 ),
    .Q6                                 (data_o[5]                 ),
    .Q7                                 (data_o[6]                 ),
    .Q8                                 (data_o[7]                 ),
    .SHIFTOUT1                          (icascade1                 ),// Cascade connections to Slave ISERDES
    .SHIFTOUT2                          (icascade2                 ),// Cascade connections to Slave ISERDES
    .BITSLIP                            (bitslip                   ),// 1-bit Invoke Bitslip. This can be used with any DATA_WIDTH, cascaded or not.
    .CE1                                (1'b1                      ),// 1-bit Clock enable input
    .CE2                                (1'b1                      ),// 1-bit Clock enable input
    .CLK                                (clk                       ),// Fast source synchronous clock driven by BUFIO
    .CLKB                               (clk                       ),// Use dedicated inversion inside ISERDES
    .CLKDIV                             (div_clk                   ),// Slow clock from BUFR.
    .CLKDIVP                            (1'b0                      ),
    .D                                  (data_i                    ),// 1-bit Input signal from IOB 
    .DDLY                               (1'b0                      ),// 1-bit Input from Input Delay component 
    .RST                                (io_reset_sync             ),// 1-bit Asynchronous reset only.
    .SHIFTIN1                           (1'b0                      ),
    .SHIFTIN2                           (1'b0                      ),
    .DYNCLKDIVSEL                       (1'b0                      ),
    .DYNCLKSEL                          (1'b0                      ),
    .OFB                                (1'b0                      ),
    .OCLK                               (1'b0                      ),
    .OCLKB                              (1'b0                      ),
    .O                                  (                          ) 
);

(* DONT_TOUCH = "true" *) ISERDESE2 #(
    .DATA_RATE                          ("DDR"                     ),
    .DATA_WIDTH                         (14                        ),
    .INTERFACE_TYPE                     ("NETWORKING"              ),
    .DYN_CLKDIV_INV_EN                  ("FALSE"                   ),
    .DYN_CLK_INV_EN                     ("FALSE"                   ),
    .NUM_CE                             (2                         ),
    .OFB_USED                           ("FALSE"                   ),
    .IOBDELAY                           ("NONE"                    ),
    .IS_CLKB_INVERTED                   (1'b1                      ),
    .SERDES_MODE                        ("SLAVE"                   ) 
)iserdese2_slave (
    .Q1                                 (                          ),
    .Q2                                 (                          ),
    .Q3                                 (data_o[8]                 ),
    .Q4                                 (data_o[9]                 ),
    .Q5                                 (data_o[10]                ),
    .Q6                                 (data_o[11]                ),
    .Q7                                 (data_o[12]                ),
    .Q8                                 (data_o[13]                ),
    .SHIFTOUT1                          (                          ),
    .SHIFTOUT2                          (                          ),
    .SHIFTIN1                           (icascade1                 ),// Cascade connection with Master ISERDES
    .SHIFTIN2                           (icascade2                 ),// Cascade connection with Master ISERDES
    .BITSLIP                            (bitslip                   ),// 1-bit Invoke Bitslip. This can be used with any DATA_WIDTH, cascaded or not.\
    .CE1                                (1'b1                      ),// 1-bit Clock enable input
    .CE2                                (1'b1                      ),// 1-bit Clock enable input 
    .CLK                                (clk                       ),// Fast source synchronous serdes clock
    .CLKB                               (clk                       ),// Use dedicated inversion inside ISERDES
    .CLKDIV                             (div_clk                   ),// Slow clock from BUFR.
    .CLKDIVP                            (1'b0                      ),
    .D                                  (1'b0                      ),// Slave ISERDES. No need to connect D, DDLY
    .DDLY                               (1'b0                      ),
    .RST                                (io_reset_sync             ),// 1-bit Asynchronous reset only.
    .DYNCLKDIVSEL                       (1'b0                      ),
    .DYNCLKSEL                          (1'b0                      ),
    .OFB                                (1'b0                      ),
    .OCLK                               (1'b0                      ),
    .OCLKB                              (1'b0                      ),
    .O                                  (                          ) 
);

endmodule
