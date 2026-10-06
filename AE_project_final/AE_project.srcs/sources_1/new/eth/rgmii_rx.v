//****************************************Copyright (c)***********************************//
// 原子哥在线教学平台：www.yuanzige.com
// 技术支持：www.openedv.com
// 淘宝店铺：http://openedv.taobao.com
// 关注微信公众平台微信号："正点原子"，免费获取ZYNQ & FPGA & STM32 & LINUX资料。
// 版权所有，盗版必究。
// Copyright(C) 正点原子 2018-2028
// All rights reserved
//----------------------------------------------------------------------------------------
// File name:           rgmii_rx
// Last modified Date:  2020/2/13 9:20:14
// Last Version:        V1.0
// Descriptions:        RGMII接收模块（去BUFIO版本）
//----------------------------------------------------------------------------------------
//****************************************************************************************//

module rgmii_rx(
    input                               idelay_clk                 ,// 200MHz时钟，IDELAY时钟

    // 以太网RGMII接口
    input                               rgmii_rxc                  ,// RGMII接收时钟
    input                               rgmii_rx_ctl               ,// RGMII接收数据控制信号
    input                [   3: 0]      rgmii_rxd                  ,// RGMII接收数据

    // 以太网GMII接口
    output                              gmii_rx_clk                ,// GMII接收时钟
    output                              gmii_rx_dv                 ,// GMII接收数据有效信号
    output               [   7: 0]      gmii_rxd                    // GMII接收数据
);

// parameter define
    parameter                           IDELAY_VALUE                = 0                    ;

// wire define
    wire                                rgmii_rxc_ibuf             ;// 输入缓冲后的RGMII接收时钟
    wire                                rgmii_rxc_bufg             ;// 全局时钟缓存后的RGMII接收时钟
    wire                 [   3: 0]      rgmii_rxd_delay            ;// rgmii_rxd输入延时
    wire                                rgmii_rx_ctl_delay         ;// rgmii_rx_ctl输入延时
    wire                 [   1: 0]      gmii_rxdv_t                ;// 两位GMII接收有效信号

//*****************************************************
//**                    main code
//*****************************************************

    assign                              gmii_rx_clk                 = rgmii_rxc_bufg       ;
    assign                              gmii_rx_dv                  = gmii_rxdv_t[0] & gmii_rxdv_t[1];

// 显式输入缓冲
IBUF eth_rxc_IBUF_inst (
    .I                                  (rgmii_rxc                 ),
    .O                                  (rgmii_rxc_ibuf            ) 
);

// 全局时钟缓存
BUFG BUFG_inst (
    .I                                  (rgmii_rxc_ibuf            ),
    .O                                  (rgmii_rxc_bufg            ) 
);

// 输入延时控制
(* IODELAY_GROUP = "rgmii_rx_delay" *)
IDELAYCTRL IDELAYCTRL_inst (
    .RDY                                (                          ),// 1-bit output: Ready output
    .REFCLK                             (idelay_clk                ),// 1-bit input : Reference clock input
    .RST                                (1'b0                      ) // 1-bit input : Active high reset input
);

// rgmii_rx_ctl输入延时与双沿采样
(* IODELAY_GROUP = "rgmii_rx_delay" *)
IDELAYE2 #(
    .IDELAY_TYPE                        ("FIXED"                   ),// FIXED, VARIABLE, VAR_LOAD, VAR_LOAD_PIPE
    .IDELAY_VALUE                       (IDELAY_VALUE              ),
    .REFCLK_FREQUENCY                   (200.0                     ) 
) u_delay_rx_ctrl (
    .CNTVALUEOUT                        (                          ),
    .DATAOUT                            (rgmii_rx_ctl_delay        ),
    .C                                  (1'b0                      ),
    .CE                                 (1'b0                      ),
    .CINVCTRL                           (1'b0                      ),
    .CNTVALUEIN                         (5'b0                      ),
    .DATAIN                             (1'b0                      ),
    .IDATAIN                            (rgmii_rx_ctl              ),
    .INC                                (1'b0                      ),
    .LD                                 (1'b0                      ),
    .LDPIPEEN                           (1'b0                      ),
    .REGRST                             (1'b0                      ) 
);

// 输入双沿采样寄存器
IDDR #(
    .DDR_CLK_EDGE                       ("SAME_EDGE_PIPELINED"     ),
    .INIT_Q1                            (1'b0                      ),
    .INIT_Q2                            (1'b0                      ),
    .SRTYPE                             ("SYNC"                    ) 
) u_iddr_rx_ctl (
    .Q1                                 (gmii_rxdv_t[0]            ),
    .Q2                                 (gmii_rxdv_t[1]            ),
    .C                                  (rgmii_rxc_bufg            ),
    .CE                                 (1'b1                      ),
    .D                                  (rgmii_rx_ctl_delay        ),
    .R                                  (1'b0                      ),
    .S                                  (1'b0                      ) 
);

// rgmii_rxd输入延时与双沿采样
genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : rxdata_bus
        // 输入延时
        (* IODELAY_GROUP = "rgmii_rx_delay" *)
        IDELAYE2 #(
    .IDELAY_TYPE                        ("FIXED"                   ),
    .IDELAY_VALUE                       (IDELAY_VALUE              ),
    .REFCLK_FREQUENCY                   (200.0                     ) 
        ) u_delay_rxd (
    .CNTVALUEOUT                        (                          ),
    .DATAOUT                            (rgmii_rxd_delay[i]        ),
    .C                                  (1'b0                      ),
    .CE                                 (1'b0                      ),
    .CINVCTRL                           (1'b0                      ),
    .CNTVALUEIN                         (5'b0                      ),
    .DATAIN                             (1'b0                      ),
    .IDATAIN                            (rgmii_rxd[i]              ),
    .INC                                (1'b0                      ),
    .LD                                 (1'b0                      ),
    .LDPIPEEN                           (1'b0                      ),
    .REGRST                             (1'b0                      ) 
        );

        // 输入双沿采样寄存器
        IDDR #(
    .DDR_CLK_EDGE                       ("SAME_EDGE_PIPELINED"     ),
    .INIT_Q1                            (1'b0                      ),
    .INIT_Q2                            (1'b0                      ),
    .SRTYPE                             ("SYNC"                    ) 
        ) u_iddr_rxd (
    .Q1                                 (gmii_rxd[i]               ),
    .Q2                                 (gmii_rxd[4+i]             ),
    .C                                  (rgmii_rxc_bufg            ),
    .CE                                 (1'b1                      ),
    .D                                  (rgmii_rxd_delay[i]        ),
    .R                                  (1'b0                      ),
    .S                                  (1'b0                      ) 
        );
    end
endgenerate

endmodule