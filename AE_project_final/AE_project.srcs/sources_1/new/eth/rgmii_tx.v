//****************************************Copyright (c)***********************************//
//原子哥在线教学平台：www.yuanzige.com
//技术支持：www.openedv.com
//淘宝店铺：http://openedv.taobao.com 
//关注微信公众平台微信号："正点原子"，免费获取ZYNQ & FPGA & STM32 & LINUX资料。
//版权所有，盗版必究。
//Copyright(C) 正点原子 2018-2028
//All rights reserved                                  
//----------------------------------------------------------------------------------------
// File name:           rgmii_tx
// Last modified Date:  2020/2/13 9:20:14
// Last Version:        V1.0
// Descriptions:        RGMII发送模块
//----------------------------------------------------------------------------------------
// Created by:          正点原子
// Created date:        2020/2/13 9:20:14
// Version:             V1.0
// Descriptions:        The original version
//
//----------------------------------------------------------------------------------------
//****************************************************************************************//

module rgmii_tx #(
    parameter integer TXC_DELAY_MODE = 1
)(
    input              idelay_clk  , // kept for interface compatibility; TXC delay uses MMCM phase shift
    //GMII发送端口
    input              gmii_tx_clk , //GMII发送时钟    
    input              gmii_tx_en  , //GMII输出数据有效信号
    input       [7:0]  gmii_txd    , //GMII输出数据        
    
    //RGMII发送端口
    output             rgmii_txc   , //RGMII发送数据时钟    
    output             rgmii_tx_ctl, //RGMII输出数据有效信号
    output      [3:0]  rgmii_txd     //RGMII输出数据     
    );

//*****************************************************
//**                    main code
//*****************************************************

wire rgmii_txc_clk;

generate
    if (TXC_DELAY_MODE == 1) begin : txc_phase90
        wire txc_mmcm_clk;
        wire txc_mmcm_fb;
        wire txc_mmcm_fb_buf;
        wire txc_mmcm_locked;

        MMCME2_BASE #(
            .BANDWIDTH          ("OPTIMIZED"),
            .CLKFBOUT_MULT_F    (8.000),
            .CLKFBOUT_PHASE     (0.000),
            .CLKIN1_PERIOD      (8.000),
            .CLKOUT0_DIVIDE_F   (8.000),
            .CLKOUT0_DUTY_CYCLE (0.500),
            .CLKOUT0_PHASE      (90.000),
            .DIVCLK_DIVIDE      (1),
            .STARTUP_WAIT       ("FALSE")
        ) txc_mmcm_inst (
            .CLKFBOUT           (txc_mmcm_fb),
            .CLKFBOUTB          (),
            .CLKOUT0            (txc_mmcm_clk),
            .CLKOUT0B           (),
            .CLKOUT1            (),
            .CLKOUT1B           (),
            .CLKOUT2            (),
            .CLKOUT2B           (),
            .CLKOUT3            (),
            .CLKOUT3B           (),
            .CLKOUT4            (),
            .CLKOUT5            (),
            .CLKOUT6            (),
            .LOCKED             (txc_mmcm_locked),
            .CLKFBIN            (txc_mmcm_fb_buf),
            .CLKIN1             (gmii_tx_clk),
            .PWRDWN             (1'b0),
            .RST                (1'b0)
        );

        BUFG txc_fb_buf_inst (
            .O                  (txc_mmcm_fb_buf),
            .I                  (txc_mmcm_fb)
        );

        BUFG txc_clk_buf_inst (
            .O                  (rgmii_txc_clk),
            .I                  (txc_mmcm_clk)
        );
    end else begin : txc_no_delay
        assign rgmii_txc_clk = gmii_tx_clk;
    end
endgenerate

// RGMII v2.0 TXC is delayed relative to TXD/TX_CTL by using a 90-degree
// phase shifted 125 MHz clock. At 125 MHz this is 2.0 ns.
ODDR #(
    .DDR_CLK_EDGE  ("SAME_EDGE"),
    .INIT          (1'b0),
    .SRTYPE        ("SYNC")
) ODDR_txc_inst (
    .Q             (rgmii_txc),
    .C             (rgmii_txc_clk),
    .CE            (1'b1),
    .D1            (1'b1),
    .D2            (1'b0),
    .R             (1'b0),
    .S             (1'b0)
);

//输出双沿采样寄存器 (rgmii_tx_ctl)
ODDR #(
    .DDR_CLK_EDGE  ("SAME_EDGE"),  // "OPPOSITE_EDGE" or "SAME_EDGE" 
    .INIT          (1'b0),         // Initial value of Q: 1'b0 or 1'b1
    .SRTYPE        ("SYNC")        // Set/Reset type: "SYNC" or "ASYNC" 
) ODDR_inst (
    .Q             (rgmii_tx_ctl), // 1-bit DDR output
    .C             (gmii_tx_clk),  // 1-bit clock input
    .CE            (1'b1),         // 1-bit clock enable input
    .D1            (gmii_tx_en),   // 1-bit data input (positive edge)
    .D2            (gmii_tx_en),   // 1-bit data input (negative edge)
    .R             (1'b0),         // 1-bit reset
    .S             (1'b0)          // 1-bit set
); 

genvar i;
generate for (i=0; i<4; i=i+1)
    begin : txdata_bus
        //输出双沿采样寄存器 (rgmii_txd)
        ODDR #(
            .DDR_CLK_EDGE  ("SAME_EDGE"),  // "OPPOSITE_EDGE" or "SAME_EDGE" 
            .INIT          (1'b0),         // Initial value of Q: 1'b0 or 1'b1
            .SRTYPE        ("SYNC")        // Set/Reset type: "SYNC" or "ASYNC" 
        ) ODDR_inst (
            .Q             (rgmii_txd[i]), // 1-bit DDR output
            .C             (gmii_tx_clk),  // 1-bit clock input
            .CE            (1'b1),         // 1-bit clock enable input
            .D1            (gmii_txd[i]),  // 1-bit data input (positive edge)
            .D2            (gmii_txd[4+i]),// 1-bit data input (negative edge)
            .R             (1'b0),         // 1-bit reset
            .S             (1'b0)          // 1-bit set
        );        
    end
endgenerate

endmodule
