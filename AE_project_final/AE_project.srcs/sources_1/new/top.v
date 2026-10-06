`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 公司：
// 工程师：
// 
// 创建时间：2025/09/06 16:00:59
// 设计名称：
// 模块名称：top
// 工程名称：
// 目标器件：
// 工具版本：
// 说明：FPGA 顶层模块，连接时钟、复位、ADC、以太网、DDR、传感器和调试链路。
// 
// 依赖：
// 
// 版本记录：
// 版本 0.01：创建文件
// 补充说明：
// 
//////////////////////////////////////////////////////////////////////////////////
`include "debug_cfg.vh"
 module top(
    input                               sys_clk_p                  ,
    input                               sys_clk_n                  ,
    input                               reset_sys_clk              ,

    output wire          [   3: 0]      EN                         ,
    output wire          [   3: 0]      INA                        ,
    output wire          [   3: 0]      INB                        ,
    output wire          [   3: 0]      INC                        ,
    // LED 接口
    output wire          [   3: 0]      LED_OUT                    ,// LED 输出
    output wire                         SYS_OUT                    ,// 系统状态输出
    // 按键输入
    input                [   3: 0]      KEY                        ,// 按键输入
    input                [   7: 0]      BIN                        ,// 扩展按键/拨码输入
    output wire                         Inertia_SDO                ,
    input                               Inertia_SDX                ,
    input                               Inertia_SCX                ,
    input                               Inertia_INT1               ,
    input                               Inertia_INT2               ,
    input                               Inertia_OSCB               ,
    input                               Inertia_OSDO               ,
    output                              Inertia_CSB                ,
    inout                               Inertia_SCL                ,
    inout                               Inertia_SDA                ,

    inout                               TEM                        ,

    inout                               H_SCL                      ,
    inout                               H_SDA                      ,

    // ADC1 接口
    output                              adc1_pdwn                  ,
    output                              adc1_spi_sck               ,
    output                              adc1_spi_csn               ,
    inout                               adc1_spi_dio               ,
    
    output                              adc1_sync                  ,
    output                              adc1_clk_out_p             ,
    output                              adc1_clk_out_n             ,
    input                               adc1_fclk_p                ,
    input                               adc1_fclk_n                ,
    input                               adc1_dclk_p                ,
    input                               adc1_dclk_n                ,
    input                [   7: 0]      adc1_data_in_p             ,
    input                [   7: 0]      adc1_data_in_n             ,

    // ADC2 接口
    output                              adc2_pdwn                  ,
    output                              adc2_spi_sck               ,
    output                              adc2_spi_csn               ,
    inout                               adc2_spi_dio               ,
    
    output                              adc2_sync                  ,
    output                              adc2_clk_out_p             ,
    output                              adc2_clk_out_n             ,
    input                               adc2_fclk_p                ,
    input                               adc2_fclk_n                ,
    input                               adc2_dclk_p                ,
    input                               adc2_dclk_n                ,
    input                [   7: 0]      adc2_data_in_p             ,
    input                [   7: 0]      adc2_data_in_n             ,
    
    // 以太网 RGMII 接口
    input                               eth_rxc                    ,// RGMII 接收时钟
    input                               eth_rx_ctl                 ,// RGMII 接收控制信号
    input                [   3: 0]      eth_rxd                    ,// RGMII 接收数据
    output                              eth_txc                    ,
    output                              eth_tx_ctl                 ,
    output               [   3: 0]      eth_txd                    ,// RGMII 发送数据
    output                              eth_rst_n                  ,
    // DDR3 存储器接口
    // ------------------------------------------------------------------------
    output               [  14: 0]      ddr3_addr                  ,
    output               [   2: 0]      ddr3_ba                    ,
    output                              ddr3_cas_n                 ,
    output               [   0: 0]      ddr3_ck_n                  ,
    output               [   0: 0]      ddr3_ck_p                  ,
    output               [   0: 0]      ddr3_cke                   ,
    output                              ddr3_ras_n                 ,
    output                              ddr3_reset_n               ,
    output                              ddr3_we_n                  ,
    inout                [  31: 0]      ddr3_dq                    ,
    inout                [   3: 0]      ddr3_dqs_n                 ,
    inout                [   3: 0]      ddr3_dqs_p                 ,
    output               [   0: 0]      ddr3_cs_n                  ,
    output               [   3: 0]      ddr3_dm                    ,
    output               [   0: 0]      ddr3_odt
);

//********************* 参数定义 *********************//
    parameter                           BOARD_MAC                   = 48'h12_34_56_78_9A_BC;       // 开发板 MAC 地址
    parameter                           BOARD_IP                    = {8'd192              ,8'd168,8'd100,8'd234} ;       // 开发板 IP 地址
    parameter                           DES_MAC                     = 48'hff_ff_ff_ff_ff_ff;       // PC 端目标 MAC 地址
    parameter                           DES_IP                      = {8'd192              ,8'd168,8'd100,8'd145} ;       // PC 端目标 IP 地址
    parameter                           IDELAY_VALUE                = 0                    ;       // RGMII 输入延时抽头值，每级约 78 ps
    parameter                           RGMII_TXC_DELAY_MODE        = 1                    ;       // 0: TXC 不延时；1: TXC 90 度相移，125MHz 下约 2ns

    parameter                           CLK_FRE                     = 200                  ;       // UART 使用的系统时钟频率，单位 MHz
    parameter                           BAUD_RATE                   = 115200               ;
    parameter                           SYSTEM_FREQ                 = 200                  ;
    parameter                           SIM_AXI_MEM                 = 0                    ;
    parameter                           SIM_SENSOR_STUB             = 0                    ;
    parameter                           SIM_ADC_PREPROCESS_STUB     = 0                    ;
    parameter integer                   AE_FRAME_SAMPLES            = 8192                 ;
    parameter integer                   AE_PRE_SAMPLES              = 2048                 ;
    parameter integer                   AE_POST_SAMPLES             = 6144                 ;
    parameter integer                   UDP_PKT_MAX_BYTES           = 1024                  ;
    parameter integer                   SENSOR_PKT_BYTES            = 64                    ;
    parameter integer                   EVENT_HDR_BYTES             = 128                   ;
    parameter integer                   TRANSPORT_HDR_BYTES         = 32                    ;
    parameter integer                   TX_INTER_PKT_GAP_CYCLES     = 12500                 ; // 发送时间间隔100 us @ 125 MHz
//********************* 内部时钟与复位信号 *********************//
    wire                                sys_clk                    ;// 系统时钟
    wire                                adc_clk                    ;// ADC 采样时钟，40 MHz
    wire                                eth_clk                    ;
    wire                                clk_125M                   ;
    wire                                ddr_sys_clk                ;

    wire                                ddr_sys_clk_i              ;
    wire                                ddr_clk_ref_i              ;
    wire                                ddr_sys_rst                ;
    wire                                ddr_clk_locked             ;

    // 时钟与复位相关信号
    wire                                clk_locked                 ;
    wire                                reset_n                    ;
    assign                              reset_n                    = reset_sys_clk & clk_locked ;
    assign                              ddr_sys_clk_i              = ddr_sys_clk              ;
    assign                              ddr_clk_ref_i              = sys_clk                  ;
    // MIG sys_rst is active-low (RST_ACT_LOW=1), so deassert with reset_n=1.
    assign                              ddr_sys_rst                 = (reset_n & clk_locked & ddr_clk_locked);
// -----------------------------------------------------------------------------
// 时钟管理模块
// 功能：由板上差分系统时钟产生系统主时钟、ADC 采样时钟、以太网辅助时钟
//       和稳定的 125 MHz GMII/RGMII 发送参考时钟。
// 输出：sys_clk 作为主要控制和 AE 处理时钟；adc_clk 供 ADC 采集链路使用；
//       clk_125M 供 RGMII TX 与 UDP/GMII 发送链路参考使用。
// -----------------------------------------------------------------------------
    ddr_clk_gen_400M ae_ddr_clk_400M_inst
   (
    // Clock out ports
    .ae_ddr_clk                         (ddr_sys_clk               ),// output ae_ddr_clk
    // Status and control signals
    .reset                              (~reset_n | ~clk_locked    ),// input reset
    .locked                             (ddr_clk_locked            ),// output locked
   // Clock in ports
    .sys_clk_200M                       (sys_clk                   ) // input sys_clk_200M
    );

system_clk_module system_clk_module_inst
(
    // 时钟输出端口
    .sys_clk                            (sys_clk                   ),// 系统时钟
    .adc_clk                            (adc_clk                   ),// ADC 采样时钟，40 MHz
    .eth_clk                            (eth_clk                   ),// 以太网辅助时钟
    .clk_125M                           (clk_125M                  ),// RGMII/GMII 发送参考时钟，125 MHz
   // 时钟输入端口
    .resetn                             (reset_sys_clk             ),// 复位输入，低有效
    .locked                             (clk_locked                ),// 时钟锁定信号

    .clk_in1_p                          (sys_clk_p                 ),// 差分系统时钟正端输入
    .clk_in1_n                          (sys_clk_n                 ) // 差分系统时钟负端输入
);
//********************* UART 通信逻辑 *********************//
    localparam                          IDLE                        = 0                    ;
    localparam                          SEND                        = 1                    ;       // 发送 HELLO ALINX\r\n
    localparam                          WAIT                        = 2                    ;       // 等待 1 秒并发送 UART 接收数据

    reg                  [   7: 0]      tx_str                     ;
    reg                  [   7: 0]      uart_tx_data               ;// UART 待发送数据
    reg                                 uart_tx_data_valid         ;// UART 发送数据有效
    wire                                uart_tx_data_ready         ;// UART 发送就绪信号
    reg                  [   7: 0]      tx_cnt                     ;
    wire                 [   7: 0]      uart_rx_data               ;// UART 接收数据
    wire                                uart_rx_data_valid         ;// UART 接收数据有效
    wire                                uart_rx_data_ready         ;// UART 接收就绪信号
    reg                  [  31: 0]      wait_cnt                   ;
    reg                  [   3: 0]      state                      ;

// 以太网通信信号
// 以太网通信参数
    wire                                gmii_rx_clk                ;// GMII 接收时钟
    wire                                gmii_rx_dv                 ;// GMII 接收数据有效信号
    wire                 [   7: 0]      gmii_rxd                   ;// GMII 接收数据
    wire                                gmii_tx_clk                ;// GMII 发送时钟
    wire                                gmii_tx_en                 ;// GMII 发送数据使能信号
    wire                 [   7: 0]      gmii_txd                   ;// GMII 发送数据

    wire                                udp_gmii_tx_en             ;// UDP GMII 输出数据有效信号
    wire                 [   7: 0]      udp_gmii_txd               ;// UDP GMII 输出数据
    wire                 [  15: 0]      tx_byte_num                ;// UDP 发送有效字节数，单位 byte

    wire                                udp_tx_done                ;// UDP 发送完成信号
    wire                 [   7: 0]      udp_tx_data                ;// UDP 待发送数据
    wire                                udp_tx_start_en            ;// UDP 发送开始使能信号
    wire                 [  31: 0]      udp_event_tx_dbg_status    ;


    wire                 [  15: 0]      pulse_gap                  ;// 脉冲间隔，单位 us
    localparam                          UDP_IDLE                    = 1                    ;
    localparam                          UDP_SEND                    = 2                    ;
    localparam                          UDP_WAIT                    = 3                    ;
    reg                  [   3: 0]      udp_cur_state              ;
    reg                  [   3: 0]      udp_next_state             ;
    reg                  [  32: 0]      udp_wait_cnt               ;
    wire                                udp_tx_data_valid          ;
    wire                                udp_tx_req                 ;
    wire                 [   7: 0]      udp_rx_data                ;
    wire                                udp_rx_data_valid          ;
    reg                                 udp_sw_en                  ;// 状态跳转标志信号
    reg                  [   7: 0]      udp_tx_string              ;
    reg                  [  31: 0]      udp_tx_string_cnt          ;
// -----------------------------------------------------------------------------
// 以太网 PHY 复位模块
// 功能：在 eth_clk 时钟域内根据系统复位生成外部 PHY 的复位信号 eth_rst_n。
// 说明：这里只产生 PHY 复位，不改变已经验证过的以太网接收数据链路。
// -----------------------------------------------------------------------------
eth_reset u_eth_reset(
    .clk                                (eth_clk                   ),
    .key1                               (reset_n                   ),
    .rst_n                              (eth_rst_n                 ) 
);

// -----------------------------------------------------------------------------
// GMII/RGMII 接口转换模块
// 功能：将 UDP/MAC 侧 8 bit GMII 数据接口转换为外部 PHY 侧 4 bit RGMII DDR 接口。
// TX：使用稳定的 clk_125M 作为发送参考时钟，输出 eth_txc/eth_tx_ctl/eth_txd。
// RX：保持外部 RGMII 接收数据到 GMII 接收总线的路径，用于后级 UDP 控制包解析。
// -----------------------------------------------------------------------------
gmii_to_rgmii #(
    .IDELAY_VALUE                       (IDELAY_VALUE              ),
    .TXC_DELAY_MODE                     (RGMII_TXC_DELAY_MODE      ) 
) u_gmii_to_rgmii(
    .idelay_clk                         (eth_clk                   ),

    .gmii_tx_ref_clk                    (clk_125M                  ),
    .gmii_rx_clk                        (gmii_rx_clk               ),
    .gmii_rx_dv                         (gmii_rx_dv                ),
    .gmii_rxd                           (gmii_rxd                  ),
    .gmii_tx_clk                        (gmii_tx_clk               ),
    .gmii_tx_en                         (gmii_tx_en                ),
    .gmii_txd                           (gmii_txd                  ),
    .rgmii_rxc                          (eth_rxc                   ),
    .rgmii_rx_ctl                       (eth_rx_ctl                ),
    .rgmii_rxd                          (eth_rxd                   ),
    .rgmii_txc                          (eth_txc                   ),
    .rgmii_tx_ctl                       (eth_tx_ctl                ),
    .rgmii_txd                          (eth_txd                   ) 
);

    wire                 [  15: 0]      rec_byte_num               ;// 接收数据字节数
    wire                                rec_pkt_done               ;// 接收单包完成信号

// -----------------------------------------------------------------------------
// UDP/IP 发送接收模块
// 功能：完成以太网帧、IP、UDP 的收发封装与解析。
// RX 输出：rec_pkt_done/udp_rx_data_valid/udp_rx_data/rec_byte_num 送入 udp_rec_decode，
//          用于解析 PC 下发的 USND 控制包。
// TX 输入：udp_event_sensor_tx 产生的 AEUP/传感器回传字节流，经 tx_req 逐字节取数后发出。
// -----------------------------------------------------------------------------
udp #(
    .BOARD_MAC                          (BOARD_MAC                 ),
    .BOARD_IP                           (BOARD_IP                  ),
    .DES_MAC                            (DES_MAC                   ),
    .DES_IP                             (DES_IP                    ) 
)
u_udp(
    .rst_n                              (reset_n                   ),
    .clk_125M                           (clk_125M                  ),

    .gmii_rx_clk                        (gmii_rx_clk               ),
    .gmii_rx_dv                         (gmii_rx_dv                ),
    .gmii_rxd                           (gmii_rxd                  ),
    .gmii_tx_clk                        (gmii_tx_clk               ),
    .gmii_tx_en                         (gmii_tx_en                ),
    .gmii_txd                           (gmii_txd                  ),

    .rec_pkt_done                       (rec_pkt_done              ),// 接收单包完成信号
    .rec_en                             (udp_rx_data_valid         ),// UDP 接收数据有效信号
    .rec_data                           (udp_rx_data               ),// UDP 接收数据
    .rec_byte_num                       (rec_byte_num              ),// 接收数据字节数

    .tx_start_en                        (udp_tx_start_en           ),// UDP 发送开始
    .tx_data                            (udp_tx_data               ),// UDP 待发送数据
    .tx_byte_num                        (tx_byte_num               ),// UDP 发送有效字节数，单位 byte
    .des_mac                            (DES_MAC                   ),
    .des_ip                             (DES_IP                    ),
    .tx_done                            (udp_tx_done               ),// UDP 发送完成信号
    .tx_req                             (udp_tx_req                ) // UDP 读数据请求，高电平请求下一个 payload 字节
);

    wire                 [  15: 0]      sample_rate                ;
    wire                 [  15: 0]      channel_en                 ;
    wire                                ctrl_time_set_valid        ;
    wire                 [  15: 0]      ctrl_set_year              ;
    wire                 [   3: 0]      ctrl_set_month             ;
    wire                 [   4: 0]      ctrl_set_day               ;
    wire                 [   4: 0]      ctrl_set_hour              ;
    wire                 [   5: 0]      ctrl_set_minute            ;
    wire                 [   5: 0]      ctrl_set_second            ;
    wire                 [  15: 0]      ctrl_ae_threshold          ;
    wire                                ctrl_pulse_tx_enable       ;
    wire                                ctrl_adc_rx_enable         ;
    wire                                ctrl_req_upload_pulse      ;
    wire                                ctrl_cfg_valid_pulse       ;
    wire                                data_transceive_en         ;
    wire                                pulse_en                   ;

    assign                              data_transceive_en          = 1'b0                 ;
    assign                              pulse_en                    = ctrl_pulse_tx_enable ;

// -----------------------------------------------------------------------------
// UDP 控制包解码模块
// 功能：解析 PC 通过 UDP 下发的 USND 控制包，输出采样率、通道使能、
//       采样时长、脉冲间隔、时间同步字段、AE 阈值和上传请求脉冲。
// 时钟域：sys_clk。输入数据来自 UDP RX，输出控制信号驱动 ADC、AE 捕获和上传链路。
// -----------------------------------------------------------------------------
udp_rec_decode udp_rec_decode_inst(
    .reset_n                            (reset_n                   ),
    .gmii_rx_clk                        (gmii_rx_clk               ),
    .sys_clk                            (sys_clk                   ),
    .clk_125M                           (clk_125M                  ),
    .rec_en                             (udp_rx_data_valid         ),
    .rec_data                           (udp_rx_data               ),// UDP 接收数据
    .sample_rate                        (sample_rate               ),// 采样率分频系数，以 40 MHz 满采样率为基准
    .channel_en                         (channel_en                ),// ADC 采样通道使能
    .pulse_gap                          (pulse_gap                 ),// 脉冲间隔，单位 us

    .rec_pkt_done                       (rec_pkt_done              ),
    .rec_byte_num                       (rec_byte_num              ),

    .EN                                 (EN                        ),
    .INA                                (INA                       ),
    .INB                                (INB                       ),
    .INC                                (INC                       ),
    .ctrl_time_set_valid                (ctrl_time_set_valid       ),
    .ctrl_set_year                      (ctrl_set_year             ),
    .ctrl_set_month                     (ctrl_set_month            ),
    .ctrl_set_day                       (ctrl_set_day              ),
    .ctrl_set_hour                      (ctrl_set_hour             ),
    .ctrl_set_minute                    (ctrl_set_minute           ),
    .ctrl_set_second                    (ctrl_set_second           ),
    .ctrl_ae_threshold                  (ctrl_ae_threshold         ),
    .ctrl_pulse_tx_enable               (ctrl_pulse_tx_enable      ),
    .ctrl_adc_rx_enable                 (ctrl_adc_rx_enable        ),
    .ctrl_req_upload_pulse              (ctrl_req_upload_pulse     ),
    .ctrl_cfg_valid_pulse               (ctrl_cfg_valid_pulse      )
);

// -----------------------------------------------------------------------------
// ADC preprocess path.
// SIM_ADC_PREPROCESS_STUB is used by system-level simulation only; default
// hardware elaboration keeps the verified adc_data_preprocess implementation.
// -----------------------------------------------------------------------------

wire                                ae_cap_en;
wire                                ae_sample_valid;
wire                 [255:0]        ae_sample_data;
wire                 [255:0]        ae_trigger_sample_data;
wire                 [15:0]         ae_active_ch_mask;
wire                 [15:0]         ae_trig_mask;
wire                                ae_sync_ready;
wire                                ae_sync_error;

wire                                adc_preprocess_raw_ready;
wire                                adc_preprocess_filter_valid;
wire                                adc_preprocess_filter_backpressure;

adc_data_preprocess #(
    .ADC1_DEBUG_ILA                     (`ADC1_DEBUG_ILA_EN        ),
    .ADC2_DEBUG_ILA                     (`ADC2_DEBUG_ILA_EN        ),
    .ILA_ADC1_FILTERED_DATA_EN          (`ILA_ADC1_FILTERED_DATA_EN),
    .ILA_ADC2_FILTERED_DATA_EN          (`ILA_ADC2_FILTERED_DATA_EN),
    .INPUT_IS_OFFSET_BINARY             (0                         ),
    .FIR_OUT_SHIFT                      (15                        ),
    .STARTUP_WAIT_CYCLES                (16                        ),
    .PRELOAD_CYCLES                     (4                         ) 
) adc_data_preprocess_inst (
    .sys_clk                            (sys_clk                   ),
    .reset_n                            (reset_n                   ),
    .adc_clk                            (adc_clk                   ),
    .adc_en                             (ctrl_adc_rx_enable        ),

    .active_ch_mask_cfg                 (16'hFFFF                  ),
    .trig_ch_mask_cfg                   (16'hFFFF                  ),

    .adc1_pdwn                          (adc1_pdwn                 ),
    .adc1_spi_sck                       (adc1_spi_sck              ),
    .adc1_spi_csn                       (adc1_spi_csn              ),
    .adc1_spi_dio                       (adc1_spi_dio              ),
    .adc1_sync                          (adc1_sync                 ),
    .adc1_clk_out_p                     (adc1_clk_out_p            ),
    .adc1_clk_out_n                     (adc1_clk_out_n            ),
    .adc1_fclk_p                        (adc1_fclk_p               ),
    .adc1_fclk_n                        (adc1_fclk_n               ),
    .adc1_dclk_p                        (adc1_dclk_p               ),
    .adc1_dclk_n                        (adc1_dclk_n               ),
    .adc1_data_in_p                     (adc1_data_in_p            ),
    .adc1_data_in_n                     (adc1_data_in_n            ),

    .adc2_pdwn                          (adc2_pdwn                 ),
    .adc2_spi_sck                       (adc2_spi_sck              ),
    .adc2_spi_csn                       (adc2_spi_csn              ),
    .adc2_spi_dio                       (adc2_spi_dio              ),
    .adc2_sync                          (adc2_sync                 ),
    .adc2_clk_out_p                     (adc2_clk_out_p            ),
    .adc2_clk_out_n                     (adc2_clk_out_n            ),
    .adc2_fclk_p                        (adc2_fclk_p               ),
    .adc2_fclk_n                        (adc2_fclk_n               ),
    .adc2_dclk_p                        (adc2_dclk_p               ),
    .adc2_dclk_n                        (adc2_dclk_n               ),
    .adc2_data_in_p                     (adc2_data_in_p            ),
    .adc2_data_in_n                     (adc2_data_in_n            ),

    .cap_en_out                         (ae_cap_en                 ),
    .sample_valid                       (ae_sample_valid           ),
    .sample_data                        (ae_sample_data            ),
    .trigger_sample_data                (ae_trigger_sample_data    ),
    .active_ch_mask                     (ae_active_ch_mask         ),
    .trig_mask                          (ae_trig_mask              ),
    .sync_ready                         (ae_sync_ready             ),
    .sync_error                         (ae_sync_error             ),

    .adc_raw_ready                      (adc_preprocess_raw_ready  ),
    .filter_valid                       (adc_preprocess_filter_valid),
    .filter_backpressure                (adc_preprocess_filter_backpressure) 
);

// -----------------------------------------------------------------------------
// AE 事件捕获输出信号
// 功能：承接 ae_event_capture 产生的事件流、触发状态和调试状态。
// 这些信号后续进入 DDR 缓存、UDP 回传链路和 ILA 调试链路。
// -----------------------------------------------------------------------------
    wire                                ae_out_valid               ;
    wire                                ae_out_sop                 ;
    wire                                ae_out_eop                 ;
    wire                 [ 255: 0]      ae_out_data                ;
    wire                 [  15: 0]      ae_out_ch_mask             ;
    wire                                ae_axis_tvalid             ;
    wire                                ae_axis_tready             ;
    wire                 [ 255: 0]      ae_axis_tdata              ;
    wire                 [  31: 0]      ae_axis_tkeep              ;
    wire                                ae_axis_tlast              ;
    wire                 [  63: 0]      ae_axis_tuser              ;

    wire                                ae_trig_pulse              ;
    wire                                ae_trig_pulse_sys          ;
    reg                                 ae_trig_toggle_adc         ;
    reg                                 ae_trig_toggle_sys_meta    ;
    reg                                 ae_trig_toggle_sys_sync    ;
    reg                                 ae_trig_toggle_sys_sync_d  ;
    wire                                ae_capture_busy            ;
    wire                                ae_event_wait_ddr          ;
    wire                                ae_event_wait_upload       ;
    wire                                ae_stream_busy             ;
    wire                                ae_event_overflow          ;
    wire                                ae_event_ddr_done_pulse    ;
    wire                 [   1: 0]      ae_bank_free_dbg           ;
    wire                 [  31: 0]      ae_trigger_sample_index    ;
    wire                                ae_out_ready               ;
    wire                                ae_ddr_ui_clk              ;
    wire                                udp_tx_done_sys_pulse      ;
    wire                                udp_upload_done_pulse      ;
    wire                                udp_upload_done_event_pulse  ;
    wire                 [  31: 0]      udp_upload_done_event_seq  ;
    wire                                udp_upload_done_event_ok   ;
    wire                                ae_upload_done_event_match  ;

    // 失败是否也释放 AE 捕获。
    // 1：DDR read fail / timeout 后发送错误回包，也释放下一帧捕获。
    // 0：失败后不释放，等待 PC 重试。
    localparam                          RELEASE_ON_UPLOAD_FAIL      = 1'b1                 ;

    wire                                ae_upload_event_finish_match  ;
    wire                                ae_upload_event_ok_match   ;
    wire                                ae_upload_event_fail_match  ;
    wire                                ae_upload_release_match    ;

    reg                                 ae_upload_fail_sticky      ;
    reg                  [  31: 0]      ae_upload_fail_seq         ;
// -----------------------------------------------------------------------------
// 上传请求由 udp_rec_decode 解码后触发，并送入后级 AE 回传链路。
// -----------------------------------------------------------------------------
    wire                 [  15: 0]      ae_trig_threshold          ;
    assign                              ae_trig_threshold           = ctrl_ae_threshold    ;
    wire                 [  31: 0]      ae_committed_event_seq     ;
    wire                                ae_committed_event_pulse   ;
    wire                                ddr_commit_done_pulse      ;
    assign                              ddr_commit_done_pulse       = ae_committed_event_pulse;

assign ae_upload_event_finish_match =
    udp_upload_done_event_pulse &&
    (udp_upload_done_event_seq == ae_committed_event_seq);

assign ae_upload_event_ok_match =
    ae_upload_event_finish_match &&
    udp_upload_done_event_ok;

assign ae_upload_event_fail_match =
    ae_upload_event_finish_match &&
    !udp_upload_done_event_ok;

assign ae_upload_release_match =
    ae_upload_event_ok_match ||
    (RELEASE_ON_UPLOAD_FAIL && ae_upload_event_fail_match);

// 保留这个旧名字，方便原有 ILA 或调试逻辑继续观察“成功完成”。
assign ae_upload_done_event_match = ae_upload_event_ok_match;
// -----------------------------------------------------------------------------
// AE 事件捕获模块
// 功能：在 sys_clk 时钟域内根据采样有效信号、通道掩码和阈值检测 AE 触发；
//       触发后缓存事件窗口，生成 256 bit 事件流、SOP/EOP、通道掩码和事件状态。
// 输出：ae_out_* 事件流送入 DDR 事件缓存；调试信号用于 ILA 观察捕获状态。
// -----------------------------------------------------------------------------
ae_event_capture #(
    .FRAME_SAMPLES                      (AE_FRAME_SAMPLES         ),
    .PRE_SAMPLES                        (AE_PRE_SAMPLES           )
) ae_event_capture_inst (
    .adc_clk                            (adc_clk                   ),
    .sys_clk                            (sys_clk                   ),
    .rd_clk                             (sys_clk                   ),
    .reset_n                            (reset_n                   ),

    .cap_en_out                         (ae_cap_en                 ),
    .sample_valid                       (ae_sample_valid           ),
    .sample_data                        (ae_sample_data            ),
    .trigger_sample_data                (ae_trigger_sample_data    ),
    .active_ch_mask                     (ae_active_ch_mask         ),
    .trig_mask                          (ae_trig_mask              ),
    .sync_ready                         (ae_sync_ready             ),
    .sync_error                         (ae_sync_error             ),

    .ctrl_cfg_valid_pulse               (ctrl_cfg_valid_pulse      ),
    .sample_rate                        (sample_rate               ),
    .channel_en                         (channel_en                ),
    .ctrl_ae_threshold                  (ctrl_ae_threshold         ),

    .upload_done_pulse                  (ae_upload_release_match   ),
    .ddr_commit_done_pulse              (ddr_commit_done_pulse     ),

    .m_axis_tvalid                      (ae_axis_tvalid            ),
    .m_axis_tready                      (ae_axis_tready            ),
    .m_axis_tdata                       (ae_axis_tdata             ),
    .m_axis_tkeep                       (ae_axis_tkeep             ),
    .m_axis_tlast                       (ae_axis_tlast             ),
    .m_axis_tuser                       (ae_axis_tuser             ),

    .trig_pulse                         (ae_trig_pulse             ),
    .capture_busy                       (ae_capture_busy           ),
    .event_wait_ddr                     (ae_event_wait_ddr         ),
    .event_wait_upload                  (ae_event_wait_upload      ),
    .stream_busy                        (ae_stream_busy            ),
    .event_overflow                     (ae_event_overflow         ),
    .event_ddr_done_pulse               (ae_event_ddr_done_pulse   ),
    .bank_free_dbg                      (ae_bank_free_dbg          ),
    .trigger_sample_index               (ae_trigger_sample_index   ),
    .ds_sample_valid_dbg                (                          ),
    .active_ch_mask_dbg                 (                          ),
    .sample_rate_div_dbg                (                          ),
    .trig_threshold_dbg                 (                          )
);

// -----------------------------------------------------------------------------
// AE trigger pulse CDC: adc_clk -> sys_clk.
// -----------------------------------------------------------------------------
always @(posedge adc_clk or negedge reset_n) begin
    if (!reset_n) begin
        ae_trig_toggle_adc <= 1'b0;
    end else if (ae_trig_pulse) begin
        ae_trig_toggle_adc <= ~ae_trig_toggle_adc;
    end
end

always @(posedge sys_clk or negedge reset_n) begin
    if (!reset_n) begin
        ae_trig_toggle_sys_meta   <= 1'b0;
        ae_trig_toggle_sys_sync   <= 1'b0;
        ae_trig_toggle_sys_sync_d <= 1'b0;
    end else begin
        ae_trig_toggle_sys_meta   <= ae_trig_toggle_adc;
        ae_trig_toggle_sys_sync   <= ae_trig_toggle_sys_meta;
        ae_trig_toggle_sys_sync_d <= ae_trig_toggle_sys_sync;
    end
end

assign ae_trig_pulse_sys = ae_trig_toggle_sys_sync ^ ae_trig_toggle_sys_sync_d;

// -----------------------------------------------------------------------------
// DDR 事件缓存与读回链路公共信号
// 功能：整理 AE 事件头使用的 96 bit time_info、DDR 读回请求状态和调试总线。
// current_time_tag 当前由事件时间管理模块生成，后续可替换为 RTC/NTP 或外部同步源。
    wire                 [  63: 0]      ae_current_time_tag        ;
    wire                 [  63: 0]      ae_event_time_tag          ;
    wire                                ae_event_time_valid        ;
    wire                 [  95: 0]      ae_current_time_info       ;

    reg                  [  63: 0]      event_time_tag_latched     ;
    reg                  [  95: 0]      event_time_info_latched    ;
    reg                  [  15: 0]      event_sample_rate_latched  ;
    reg                  [  15: 0]      event_channel_en_latched   ;
    reg                  [  15: 0]      event_ae_threshold_latched  ;

// 年份
    function [95:0] pack_ae_time_info;
        input [63:0] tag;
        reg [15:0] year;
        reg [7:0]  month;
        reg [7:0]  day;
        reg [7:0]  hour;
        reg [7:0]  minute;
        reg [7:0]  second;
        reg [31:0] seq_in_sec;
    begin
        year       = tag[63:48];
        month      = {4'd0, tag[47:44]};
        day        = {3'd0, tag[43:39]};
        hour       = {3'd0, tag[38:34]};
        minute     = {2'd0, tag[33:28]};
        second     = {2'd0, tag[27:22]};
        seq_in_sec = {10'd0, tag[21:0]};

        pack_ae_time_info = {
            year,
            month,
            day,
            hour,
            minute,
            second,
            seq_in_sec,
            1'b1,
            7'd0
        };
    end
    endfunction

    assign ae_current_time_info = pack_ae_time_info(ae_current_time_tag);

// -----------------------------------------------------------------------------
// DDR 事件缓存：写入 AE 事件并按请求读回。
// -----------------------------------------------------------------------------

// 读回请求与状态信号。
    wire                                ae_rd_req                  ;
    wire                 [  31: 0]      ae_rd_event_seq            ;
    wire                                ae_rd_ready                ;
    wire                                ae_rd_busy                 ;
    wire                                ae_rd_found                ;
    wire                                ae_rd_valid                ;
    wire                                ae_rd_sop                  ;
    wire                                ae_rd_eop                  ;
    wire                 [ 255: 0]      ae_rd_data                 ;

// 仿真或板级调试时，可通过 testbench force 相关信号。

wire                                ae_ddr_init_calib_complete ;
wire                                ae_ddr_ui_clk_sync_rst     ;
wire                                ae_ddr_mmcm_locked         ;
wire                 [  31: 0]      ae_ingress_event_seq_dbg   ;
wire                                ae_ingress_frame_len_error ;

wire                 [ 127: 0]      ae_ddr_dbg_bus             ;
wire                 [  31: 0]      ae_ddr_dbg_seq             ;
wire                 [ 127: 0]      ae_ddr_ila_probe8          ;
wire                                ae_ddr_dbg_desc_wr_en      ;
wire                                ae_ddr_dbg_desc_query_done ;
wire                                ae_ddr_dbg_desc_query_found;
reg                                 ae_event_available         ;
reg                                 ae_event_available_d       ;
reg                                 debug_auto_upload_req_pulse;
wire                                upload_req_pulse_eff       ;

assign ae_ddr_ila_probe8 = ae_rd_valid ? ae_rd_data[127:0] : ae_ddr_dbg_bus;

    `ifdef DEBUG_AUTO_UPLOAD_EN
        assign upload_req_pulse_eff = ctrl_req_upload_pulse | debug_auto_upload_req_pulse;
    `else
        assign upload_req_pulse_eff = ctrl_req_upload_pulse;
    `endif

// -----------------------------------------------------------------------------
// 事件时间管理模块
// 功能：维护 AE 事件使用的日历时间和秒内事件计数，支持控制包时间同步。
// 输出：ae_time_info 作为 96 bit 时间信息写入事件头，ae_current_time_tag 供回传头使用。
// -----------------------------------------------------------------------------
event_time_keeper #(
    .CLK_FREQ_HZ                       (200_000_000              )
) event_time_keeper_inst (
    .sys_clk                            (sys_clk                   ),
    .reset_n                            (reset_n                   ),

    // 时间同步字段来自 udp_rec_decode 解析出的控制包，收到有效脉冲后更新内部时间。
    .time_set_valid                     (ctrl_time_set_valid       ),
    .set_year                           (ctrl_set_year             ),
    .set_month                          (ctrl_set_month            ),
    .set_day                            (ctrl_set_day              ),
    .set_hour                           (ctrl_set_hour             ),
    .set_minute                         (ctrl_set_minute           ),
    .set_second                         (ctrl_set_second           ),

    // AE 触发时推进秒内事件计数，用于事件序号和回传时间标签。
    .event_fire                         (ae_trig_pulse_sys         ),

    .current_time_tag                   (ae_current_time_tag       ),
    .event_time_tag                     (ae_event_time_tag         ),
    .event_time_valid                   (ae_event_time_valid       ) 
);

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            event_time_tag_latched     <= 64'd0;
            event_time_info_latched    <= 96'd0;
            event_sample_rate_latched  <= 16'd1;
            event_channel_en_latched   <= 16'hFFFF;
            event_ae_threshold_latched <= 16'd4000;
        end else begin
            // 触发脉冲到 sys_clk 域后，先锁存当前配置。
            // 时间这里先用 current_time_tag 兜底，随后 event_time_valid 到来时再覆盖为 event_time_keeper 输出。
            if (ae_trig_pulse_sys) begin
                event_time_tag_latched     <= ae_current_time_tag;
                event_time_info_latched    <= pack_ae_time_info(ae_current_time_tag);
                event_sample_rate_latched  <= (sample_rate == 16'd0) ? 16'd1 : sample_rate;
                event_channel_en_latched   <= channel_en;
                event_ae_threshold_latched <= ctrl_ae_threshold;
            end

            // event_time_keeper 对 event_fire 正式打拍后的事件时间，优先级更高。
            if (ae_event_time_valid) begin
                event_time_tag_latched  <= ae_event_time_tag;
                event_time_info_latched <= pack_ae_time_info(ae_event_time_tag);
            end
        end
    end
// -----------------------------------------------------------------------------
// AE DDR 事件缓存模块
// 功能：接收 ae_event_capture 输出的事件流，将完整 AE 事件写入 DDR3；
//       建立事件描述符后，通过 committed_event_seq/pulse 告知上传链路事件已提交。
// 读回：udp_event_sensor_tx 根据 ae_rd_event_seq 请求读回事件头和 payload，组包回传。
// 调试：ddr_dbg_* 输出给 DDR UI ILA，用于定位写描述符、查描述符和读回状态。
// -----------------------------------------------------------------------------
ae_ddr_axis_event_buffer #(
    .FRAME_SAMPLES                      (AE_FRAME_SAMPLES          ),
    .PRE_SAMPLES                        (AE_PRE_SAMPLES            ),
    .POST_SAMPLES                       (AE_POST_SAMPLES           ),
    .HEADER_WORDS                       (4                         ),
    .DESC_COUNT                         (1024                      ),
    .EVENT_BASE_ADDR                    (30'h0000_0000             ),
    .SIM_AXI_MEM                        (SIM_AXI_MEM               ) 
) ae_ddr_axis_event_buffer_inst (
    .sys_clk                            (sys_clk                   ),
    .reset_n                            (reset_n                   ),

    .s_axis_tvalid                      (ae_axis_tvalid            ),
    .s_axis_tready                      (ae_axis_tready            ),
    .s_axis_tdata                       (ae_axis_tdata             ),
    .s_axis_tlast                       (ae_axis_tlast             ),
    .s_axis_tuser                       (ae_axis_tuser             ),

    .cfg_ae_threshold                   (event_ae_threshold_latched),
    .cfg_sample_rate_div                (event_sample_rate_latched ),
    .cfg_trig_mask                      (event_channel_en_latched  ),
    .time_info                          (event_time_info_latched   ),

    .rd_req                             (ae_rd_req                 ),
    .rd_event_seq                       (ae_rd_event_seq           ),
    .rd_busy                            (ae_rd_busy                ),
    .rd_found                           (ae_rd_found               ),
    .rd_valid                           (ae_rd_valid               ),
    .rd_ready                           (ae_rd_ready               ),
    .rd_sop                             (ae_rd_sop                 ),
    .rd_eop                             (ae_rd_eop                 ),
    .rd_data                            (ae_rd_data                ),

    .ddr3_addr                          (ddr3_addr                 ),
    .ddr3_ba                            (ddr3_ba                   ),
    .ddr3_cas_n                         (ddr3_cas_n                ),
    .ddr3_ck_n                          (ddr3_ck_n                 ),
    .ddr3_ck_p                          (ddr3_ck_p                 ),
    .ddr3_cke                           (ddr3_cke                  ),
    .ddr3_ras_n                         (ddr3_ras_n                ),
    .ddr3_reset_n                       (ddr3_reset_n              ),
    .ddr3_we_n                          (ddr3_we_n                 ),
    .ddr3_dq                            (ddr3_dq                   ),
    .ddr3_dqs_n                         (ddr3_dqs_n                ),
    .ddr3_dqs_p                         (ddr3_dqs_p                ),
    .ddr3_cs_n                          (ddr3_cs_n                 ),
    .ddr3_dm                            (ddr3_dm                   ),
    .ddr3_odt                           (ddr3_odt                  ),

    .sys_clk_i                          (ddr_sys_clk_i             ),
    .clk_ref_i                          (ddr_clk_ref_i             ),
    .sys_rst                            (ddr_sys_rst               ),

    .init_calib_complete                (ae_ddr_init_calib_complete),
    .ui_clk                             (ae_ddr_ui_clk             ),
    .ui_clk_sync_rst                    (ae_ddr_ui_clk_sync_rst    ),
    .mmcm_locked                        (ae_ddr_mmcm_locked        ),

    .ingress_event_seq_dbg              (ae_ingress_event_seq_dbg  ),
    .ingress_frame_len_error            (ae_ingress_frame_len_error),
    .committed_event_seq                (ae_committed_event_seq    ),
    .committed_event_pulse              (ae_committed_event_pulse  ),
    .ddr_dbg_bus                        (ae_ddr_dbg_bus            ),
    .ddr_dbg_seq                        (ae_ddr_dbg_seq            ),
    .ddr_dbg_desc_wr_en                 (ae_ddr_dbg_desc_wr_en     ),
    .ddr_dbg_desc_query_done            (ae_ddr_dbg_desc_query_done),
    .ddr_dbg_desc_query_found           (ae_ddr_dbg_desc_query_found) 
);

    // =====================================================
    // 传感器数据输出
    // 功能：汇总 DS18B20、AHT20 和 LSM6DS3TR 的实时状态，
    //       这些数据会被 udp_event_sensor_tx 填入 AEUP 的 SNSR 区域。
    // =====================================================
    wire                                ds18b20_valid              ;
    wire                                ds18b20_present            ;
    wire    signed       [  15: 0]      ds18b20_temp_raw_x16       ;
    wire    signed       [  15: 0]      ds18b20_temp_centi         ;
    wire                                aht20_valid                ;
    wire                 [  15: 0]      aht20_humi_centi           ;
    wire    signed       [  15: 0]      aht20_temp_centi           ;

    wire                                lsm6_valid                 ;
    wire                                lsm6_ok                    ;
    wire    signed       [  15: 0]      lsm6_gx_raw                ;
    wire    signed       [  15: 0]      lsm6_gy_raw                ;
    wire    signed       [  15: 0]      lsm6_gz_raw                ;
    reg                                 event_ds18b20_valid_latched  ;
    reg                                 event_ds18b20_present_latched  ;
    reg     signed       [  15: 0]      event_ds18b20_temp_raw_x16_latched  ;
    reg     signed       [  15: 0]      event_ds18b20_temp_centi_latched  ;

    reg                                 event_aht20_valid_latched  ;
    reg                  [  15: 0]      event_aht20_humi_centi_latched  ;
    reg     signed       [  15: 0]      event_aht20_temp_centi_latched  ;

    reg                                 event_lsm6_valid_latched   ;
    reg                                 event_lsm6_ok_latched      ;
    reg     signed       [  15: 0]      event_lsm6_gx_raw_latched  ;
    reg     signed       [  15: 0]      event_lsm6_gy_raw_latched  ;
    reg     signed       [  15: 0]      event_lsm6_gz_raw_latched  ;
    wire                                inertia_scl_i              ;
    wire                                inertia_scl_oe             ;
    wire                                inertia_sda_i              ;
    wire                                inertia_sda_oe             ;
    wire                                h_scl_i                    ;
    wire                                h_scl_oe                   ;
    wire                                h_sda_i                    ;
    wire                                h_sda_oe                   ;
    // 给顶层 IOBUF 的输入侧保留一个内部观察负载，避免实现阶段把它们视为无负载输入缓冲。
    (* keep = "true" *) wire [3:0]      sensor_iobuf_mon           ;

    // -----------------------------------------------------------------------------
    // 传感器 I2C 顶层三态缓冲
    // 功能：将惯性传感器和 AHT20 的 SCL/SDA 三态控制显式放在顶层 IOBUF。
    // 说明：sensor 模块只输出 oe 与内部输入信号，真实双向管脚由这里连接。
    // -----------------------------------------------------------------------------
    IOBUF u_iobuf_inertia_scl (
        .I                              (1'b0                      ),
        .T                              (~inertia_scl_oe           ),
        .O                              (inertia_scl_i             ),
        .IO                             (Inertia_SCL               )
    );

    IOBUF u_iobuf_inertia_sda (
        .I                              (1'b0                      ),
        .T                              (~inertia_sda_oe           ),
        .O                              (inertia_sda_i             ),
        .IO                             (Inertia_SDA               )
    );

    IOBUF u_iobuf_h_scl (
        .I                              (1'b0                      ),
        .T                              (~h_scl_oe                 ),
        .O                              (h_scl_i                   ),
        .IO                             (H_SCL                     )
    );

    IOBUF u_iobuf_h_sda (
        .I                              (1'b0                      ),
        .T                              (~h_sda_oe                 ),
        .O                              (h_sda_i                   ),
        .IO                             (H_SDA                     )
    );

    assign sensor_iobuf_mon = {
        inertia_scl_i,
        inertia_sda_i,
        h_scl_i,
        h_sda_i
    };

    // =====================================================
    // 传感器模块实例化
    // 功能：驱动 DS18B20 温度传感器、AHT20 温湿度传感器和 LSM6DS3TR 惯性传感器。
    // 输出：valid/温度/湿度/陀螺仪原始值会随每个 AEUP 包一起回传。
    // =====================================================
generate
    if (SIM_SENSOR_STUB != 0) begin : gen_sensor_stub
        assign Inertia_SDO            = 1'b0;
        assign Inertia_CSB            = 1'b1;
        assign inertia_scl_oe         = 1'b0;
        assign inertia_sda_oe         = 1'b0;
        assign h_scl_oe               = 1'b0;
        assign h_sda_oe               = 1'b0;
        assign ds18b20_valid          = 1'b1;
        assign ds18b20_present        = 1'b1;
        assign ds18b20_temp_raw_x16   = 16'sd400;
        assign ds18b20_temp_centi     = 16'sd2500;
        assign aht20_valid            = 1'b1;
        assign aht20_humi_centi       = 16'd4567;
        assign aht20_temp_centi       = 16'sd2512;
        assign lsm6_valid             = 1'b1;
        assign lsm6_ok                = 1'b1;
        assign lsm6_gx_raw            = 16'sd10;
        assign lsm6_gy_raw            = -16'sd20;
        assign lsm6_gz_raw            = 16'sd1024;
    end else begin : gen_sensor_real
    sensor #(
    .CLK_FREQ_HZ                        (200_000_000               ),
    .I2C_FREQ_HZ                        (100_000                   ),
    .LSM6_SA0_HIGH                      (1'b0                      ) // 板级 SDO/SA0 接地时填 1'b0，若上拉则填 1'b1
    ) sensor_inst (
    .clk                                (sys_clk                   ),
    .rst_n                              (reset_n                   ),

    .Inertia_SDO                        (Inertia_SDO               ),
    .Inertia_SDX                        (Inertia_SDX               ),
    .Inertia_SCX                        (Inertia_SCX               ),
    .Inertia_INT1                       (Inertia_INT1              ),
    .Inertia_INT2                       (Inertia_INT2              ),
    .Inertia_OSCB                       (Inertia_OSCB              ),
    .Inertia_OSDO                       (Inertia_OSDO              ),
    .Inertia_CSB                        (Inertia_CSB               ),
    .Inertia_SCL_i                      (inertia_scl_i             ),
    .Inertia_SCL_oe                     (inertia_scl_oe            ),
    .Inertia_SDA_i                      (inertia_sda_i             ),
    .Inertia_SDA_oe                     (inertia_sda_oe            ),

    .TEM                                (TEM                       ),

    .H_SCL_i                            (h_scl_i                   ),
    .H_SCL_oe                           (h_scl_oe                  ),
    .H_SDA_i                            (h_sda_i                   ),
    .H_SDA_oe                           (h_sda_oe                  ),

    .ds18b20_valid                      (ds18b20_valid             ),
    .ds18b20_present                    (ds18b20_present           ),
    .ds18b20_temp_raw_x16               (ds18b20_temp_raw_x16      ),
    .ds18b20_temp_centi                 (ds18b20_temp_centi        ),

    .aht20_valid                        (aht20_valid               ),
    .aht20_humi_centi                   (aht20_humi_centi          ),
    .aht20_temp_centi                   (aht20_temp_centi          ),

    .lsm6_valid                         (lsm6_valid                ),
    .lsm6_ok                            (lsm6_ok                   ),
    .lsm6_gx_raw                        (lsm6_gx_raw               ),
    .lsm6_gy_raw                        (lsm6_gy_raw               ),
    .lsm6_gz_raw                        (lsm6_gz_raw               ) 
    );
    end
endgenerate

always @(posedge sys_clk or negedge reset_n) begin
    if (!reset_n) begin
        event_ds18b20_valid_latched        <= 1'b0;
        event_ds18b20_present_latched      <= 1'b0;
        event_ds18b20_temp_raw_x16_latched <= 16'sd0;
        event_ds18b20_temp_centi_latched   <= 16'sd0;

        event_aht20_valid_latched          <= 1'b0;
        event_aht20_humi_centi_latched     <= 16'd0;
        event_aht20_temp_centi_latched     <= 16'sd0;

        event_lsm6_valid_latched           <= 1'b0;
        event_lsm6_ok_latched              <= 1'b0;
        event_lsm6_gx_raw_latched          <= 16'sd0;
        event_lsm6_gy_raw_latched          <= 16'sd0;
        event_lsm6_gz_raw_latched          <= 16'sd0;
    end else if (ae_trig_pulse_sys) begin
        event_ds18b20_valid_latched        <= ds18b20_valid;
        event_ds18b20_present_latched      <= ds18b20_present;
        event_ds18b20_temp_raw_x16_latched <= ds18b20_temp_raw_x16;
        event_ds18b20_temp_centi_latched   <= ds18b20_temp_centi;

        event_aht20_valid_latched          <= aht20_valid;
        event_aht20_humi_centi_latched     <= aht20_humi_centi;
        event_aht20_temp_centi_latched     <= aht20_temp_centi;

        event_lsm6_valid_latched           <= lsm6_valid;
        event_lsm6_ok_latched              <= lsm6_ok;
        event_lsm6_gx_raw_latched          <= lsm6_gx_raw;
        event_lsm6_gy_raw_latched          <= lsm6_gy_raw;
        event_lsm6_gz_raw_latched          <= lsm6_gz_raw;
    end
end
wire [63:0] upload_time_tag;
wire [15:0] upload_sample_rate;
wire [15:0] upload_channel_en;
wire [15:0] upload_ae_threshold;

wire        upload_ds18b20_valid;
wire        upload_ds18b20_present;
wire signed [15:0] upload_ds18b20_temp_raw_x16;
wire signed [15:0] upload_ds18b20_temp_centi;

wire        upload_aht20_valid;
wire [15:0] upload_aht20_humi_centi;
wire signed [15:0] upload_aht20_temp_centi;

wire        upload_lsm6_valid;
wire        upload_lsm6_ok;
wire signed [15:0] upload_lsm6_gx_raw;
wire signed [15:0] upload_lsm6_gy_raw;
wire signed [15:0] upload_lsm6_gz_raw;

assign upload_time_tag =
    ae_event_available ? event_time_tag_latched : ae_current_time_tag;

assign upload_sample_rate =
    ae_event_available ? event_sample_rate_latched : sample_rate;

assign upload_channel_en =
    ae_event_available ? event_channel_en_latched : channel_en;

assign upload_ae_threshold =
    ae_event_available ? event_ae_threshold_latched : ctrl_ae_threshold;

assign upload_ds18b20_valid =
    ae_event_available ? event_ds18b20_valid_latched : ds18b20_valid;

assign upload_ds18b20_present =
    ae_event_available ? event_ds18b20_present_latched : ds18b20_present;

assign upload_ds18b20_temp_raw_x16 =
    ae_event_available ? event_ds18b20_temp_raw_x16_latched : ds18b20_temp_raw_x16;

assign upload_ds18b20_temp_centi =
    ae_event_available ? event_ds18b20_temp_centi_latched : ds18b20_temp_centi;

assign upload_aht20_valid =
    ae_event_available ? event_aht20_valid_latched : aht20_valid;

assign upload_aht20_humi_centi =
    ae_event_available ? event_aht20_humi_centi_latched : aht20_humi_centi;

assign upload_aht20_temp_centi =
    ae_event_available ? event_aht20_temp_centi_latched : aht20_temp_centi;

assign upload_lsm6_valid =
    ae_event_available ? event_lsm6_valid_latched : lsm6_valid;

assign upload_lsm6_ok =
    ae_event_available ? event_lsm6_ok_latched : lsm6_ok;

assign upload_lsm6_gx_raw =
    ae_event_available ? event_lsm6_gx_raw_latched : lsm6_gx_raw;

assign upload_lsm6_gy_raw =
    ae_event_available ? event_lsm6_gy_raw_latched : lsm6_gy_raw;

assign upload_lsm6_gz_raw =
    ae_event_available ? event_lsm6_gz_raw_latched : lsm6_gz_raw;
    // -----------------------------------------------------------------------------
    // AEUP/传感器 UDP 回传组包模块
    // 功能：响应上传请求，优先从 DDR 读回已提交 AE 事件并打包为 AEUP 多包；
    //       若当前没有可读 AE 事件，则发送仅含传感器状态和空事件头的回传包。
    // 时钟域：sys_clk 处理请求与元信息，ae_ddr_ui_clk 读 DDR，gmii_tx_clk 对齐 UDP TX 取数。
    // 输出：tx_start_en/tx_data/tx_byte_num/tx_dbg_status 直接驱动 UDP 发送侧。
    // -----------------------------------------------------------------------------
    udp_event_sensor_tx  #(
    .UDP_PKT_MAX_BYTES                  (UDP_PKT_MAX_BYTES         ),
    .SENSOR_PKT_BYTES                   (SENSOR_PKT_BYTES          ),
    .EVENT_HDR_BYTES                    (EVENT_HDR_BYTES           ),
    .TRANSPORT_HDR_BYTES                (TRANSPORT_HDR_BYTES       ),
    .TX_INTER_PKT_GAP_CYCLES            (TX_INTER_PKT_GAP_CYCLES   ) 
    )udp_event_sensor_tx_inst(
    .reset_n                            (reset_n                   ),
    .sys_clk                            (sys_clk                   ),
    .gmii_tx_clk                        (gmii_tx_clk               ),
    .ae_ddr_ui_clk                      (ae_ddr_ui_clk             ),

    .upload_req_pulse                   (upload_req_pulse_eff       ),
    .event_available                    (ae_event_available        ),
    .latest_event_seq                   (ae_committed_event_seq    ),

    .current_time_tag                   (upload_time_tag           ),
    .sample_rate                        (upload_sample_rate        ),
    .channel_en                         (upload_channel_en         ),
    .ae_threshold                       (upload_ae_threshold       ),

    .ds18b20_valid                      (upload_ds18b20_valid      ),
    .ds18b20_present                    (upload_ds18b20_present    ),
    .ds18b20_temp_raw_x16               (upload_ds18b20_temp_raw_x16),
    .ds18b20_temp_centi                 (upload_ds18b20_temp_centi ),
    .aht20_valid                        (upload_aht20_valid        ),
    .aht20_humi_centi                   (upload_aht20_humi_centi   ),
    .aht20_temp_centi                   (upload_aht20_temp_centi   ),
    .lsm6_valid                         (upload_lsm6_valid         ),
    .lsm6_ok                            (upload_lsm6_ok            ),
    .lsm6_gx_raw                        (upload_lsm6_gx_raw        ),
    .lsm6_gy_raw                        (upload_lsm6_gy_raw        ),
    .lsm6_gz_raw                        (upload_lsm6_gz_raw        ),

    .ae_rd_req                          (ae_rd_req                 ),
    .ae_rd_event_seq                    (ae_rd_event_seq           ),
    .ae_rd_busy                         (ae_rd_busy                ),
    .ae_rd_found                        (ae_rd_found               ),
    .ae_rd_valid                        (ae_rd_valid               ),
    .ae_rd_ready                        (ae_rd_ready               ),
    .ae_rd_sop                          (ae_rd_sop                 ),
    .ae_rd_eop                          (ae_rd_eop                 ),
    .ae_rd_data                         (ae_rd_data                ),

    .tx_req                             (udp_tx_req                ),
    .tx_done                            (udp_tx_done               ),
    .upload_done_pulse                  (udp_upload_done_pulse     ),
    .upload_done_event_pulse            (udp_upload_done_event_pulse),
    .upload_done_event_seq              (udp_upload_done_event_seq ),
    .upload_done_event_ok               (udp_upload_done_event_ok  ),
    .tx_start_en                        (udp_tx_start_en           ),
    .tx_data                            (udp_tx_data               ),
    .tx_byte_num                        (tx_byte_num               ),
    .tx_dbg_status                      (udp_event_tx_dbg_status   )
    );


//********************* LED 输出逻辑 *********************//
    // LED低电平点亮：LED0下发成功，LED1回传完成，LED2 AE事件，LED3 ADC双有效闪烁。
    reg                  [  31: 0]      sys_time                   ;
    reg                                 sys_led                    ;
    localparam          [  31: 0]       LED_100MS_CYCLES           = 32'd20_000_000;
    localparam          [  31: 0]       LED_1S_CYCLES              = 32'd200_000_000;
    localparam          [  31: 0]       LED_2S_CYCLES              = 32'd400_000_000;
    reg                  [  31: 0]      led_eth_rx_cnt             ;
    reg                  [  31: 0]      led_eth_tx_cnt             ;
    reg                  [  31: 0]      led_ae_evt_cnt             ;
    reg                  [  31: 0]      led_adc_blink_cnt          ;
    reg                                 led_adc_blink              ;
    (* ASYNC_REG = "TRUE" *) reg        udp_tx_done_meta           ;
    (* ASYNC_REG = "TRUE" *) reg        udp_tx_done_sync           ;
    reg                                 udp_tx_done_sync_d         ;
    assign                              udp_tx_done_sys_pulse       = udp_tx_done_sync & ~udp_tx_done_sync_d;

    // -----------------------------------------------------------------------------
    // AE 事件可上传状态寄存器
    // 时钟域：sys_clk。
    // 功能：DDR 描述符提交完成后置位 ae_event_available；UDP 完成一次回传后清零。
    //       DEBUG_AUTO_UPLOAD_EN 打开时，检测可用标志上升沿并自动产生一次上传请求。
    // -----------------------------------------------------------------------------
    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            ae_event_available          <= 1'b0;
            ae_event_available_d        <= 1'b0;
            debug_auto_upload_req_pulse <= 1'b0;
        end else begin
            ae_event_available_d        <= ae_event_available;
            debug_auto_upload_req_pulse <= ae_event_available & ~ae_event_available_d;

            if (ae_committed_event_pulse) begin
                ae_event_available <= 1'b1;
            end else if (ae_upload_release_match) begin
                ae_event_available <= 1'b0;
            end
        end
    end

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            ae_upload_fail_sticky <= 1'b0;
            ae_upload_fail_seq    <= 32'd0;
        end else if (ae_upload_event_fail_match) begin
            ae_upload_fail_sticky <= 1'b1;
            ae_upload_fail_seq    <= udp_upload_done_event_seq;
        end
    end
//********************* LED 输出逻辑 *********************//
// LED 低电平点亮。
//
// LED_OUT[0]：发现一次 AE 事件，闪烁一次。
// LED_OUT[1]：接收到上位机一次有效控制/请求信号，闪烁一次。
// LED_OUT[2]：ADC 工作使能且同步正常时持续闪烁。
// LED_OUT[3]：一次真实 AE UDP 事件上传成功完成，闪烁一次。
//
// 说明：
// 1. 事件类 LED 使用计数器拉长显示，否则单拍脉冲肉眼不可见；
// 2. UDP 上传完成不能用 udp_upload_done_pulse，它语义太宽泛；
//    应使用 udp_upload_done_event_pulse && udp_upload_done_event_ok；
// 3. ADC 工作指示使用 ctrl_adc_rx_enable && ae_sync_ready && !ae_sync_error，
//    表示 ADC 已被上位机使能，并且 ADC 预处理链路同步正常。
// -----------------------------------------------------------------------------

localparam [31:0] LED_ADC_BLINK_CYCLES  = 32'd50_000_000;   // sys_clk=200MHz，250ms翻转一次

reg  [31:0] led_pc_cmd_cnt;
reg  [31:0] led_udp_evt_done_cnt;

// -----------------------------------------------------------------------------
// LED 触发源定义
// -----------------------------------------------------------------------------

// 发现一次 AE 事件：使用 ae_trig_pulse_sys。
// 如果你希望 LED 表示“事件已经写入 DDR”，可以改成 ae_committed_event_pulse。
// 但“发现一次 AE 事件”更推荐用 ae_trig_pulse_sys。
wire led_ae_event_pulse;

assign led_ae_event_pulse = ae_trig_pulse_sys;


// 接收到上位机发送的一次有效信号。
// 这里用 udp_rec_decode 解码后的有效控制脉冲组合，而不是原始 rec_pkt_done。
// 这样可以避免无效 UDP 包也触发 LED。
wire led_pc_cmd_pulse;

assign led_pc_cmd_pulse =
    ctrl_cfg_valid_pulse  |
    ctrl_req_upload_pulse |
    ctrl_time_set_valid;


// ADC 工作使能。
// 如果你只想看“上位机是否使能 ADC”，可以改成 ctrl_adc_rx_enable。
// 这里更精准一些：ADC 被使能，并且同步 ready，且没有 sync error。
wire led_adc_work_active;

assign led_adc_work_active =
    ctrl_adc_rx_enable &&
    ae_sync_ready &&
    !ae_sync_error;


// 一次真实 AE UDP 事件上传成功完成。
// 不使用 udp_upload_done_pulse，因为它可能只是普通回传流程完成。
// 不使用 udp_tx_done，因为它只是某个 UDP 包发送完成。
// 这里使用严格事件完成信号。
wire led_udp_event_upload_done_pulse;

assign led_udp_event_upload_done_pulse =
    udp_upload_done_event_pulse &&
    udp_upload_done_event_ok;

// -----------------------------------------------------------------------------
// LED 显示计数器与系统心跳
// -----------------------------------------------------------------------------
always @(posedge sys_clk or negedge reset_n) begin
    if (!reset_n) begin
        sys_time                <= 32'd0;
        sys_led                 <= 1'b0;

        led_ae_evt_cnt          <= 32'd0;
        led_pc_cmd_cnt          <= 32'd0;
        led_udp_evt_done_cnt    <= 32'd0;

        led_adc_blink_cnt       <= 32'd0;
        led_adc_blink           <= 1'b1;   // LED 低有效，复位后默认灭
    end else begin
        // ---------------------------------------------------------------------
        // SYS_OUT 心跳：1s 翻转一次
        // ---------------------------------------------------------------------
        if (sys_time >= 32'd199_999_999) begin
            sys_time <= 32'd0;
            sys_led  <= ~sys_led;
        end else begin
            sys_time <= sys_time + 1'b1;
        end

        // ---------------------------------------------------------------------
        // LED0：AE 事件发现，闪烁 2s
        // ---------------------------------------------------------------------
        if (led_ae_event_pulse) begin
            led_ae_evt_cnt <= LED_2S_CYCLES;
        end else if (led_ae_evt_cnt != 32'd0) begin
            led_ae_evt_cnt <= led_ae_evt_cnt - 1'b1;
        end

        // ---------------------------------------------------------------------
        // LED1：收到一次上位机有效控制/请求信号，闪烁 1s
        // ---------------------------------------------------------------------
        if (led_pc_cmd_pulse) begin
            led_pc_cmd_cnt <= LED_1S_CYCLES;
        end else if (led_pc_cmd_cnt != 32'd0) begin
            led_pc_cmd_cnt <= led_pc_cmd_cnt - 1'b1;
        end

        // ---------------------------------------------------------------------
        // LED3：一次真实 AE UDP 事件上传成功完成，闪烁 1s
        // ---------------------------------------------------------------------
        if (led_udp_event_upload_done_pulse) begin
            led_udp_evt_done_cnt <= LED_1S_CYCLES;
        end else if (led_udp_evt_done_cnt != 32'd0) begin
            led_udp_evt_done_cnt <= led_udp_evt_done_cnt - 1'b1;
        end

        // ---------------------------------------------------------------------
        // LED2：ADC 工作使能且同步正常时持续闪烁
        // ---------------------------------------------------------------------
        if (led_adc_work_active) begin
            if (led_adc_blink_cnt >= LED_ADC_BLINK_CYCLES - 1'b1) begin
                led_adc_blink_cnt <= 32'd0;
                led_adc_blink     <= ~led_adc_blink;
            end else begin
                led_adc_blink_cnt <= led_adc_blink_cnt + 1'b1;
            end
        end else begin
            led_adc_blink_cnt <= 32'd0;
            led_adc_blink     <= 1'b1;    // LED 灭
        end
    end
end


//// -----------------------------------------------------------------------------
//// LED 输出，低电平点亮
//// -----------------------------------------------------------------------------
assign LED_OUT[0] = (led_ae_evt_cnt       != 32'd0) ? 1'b0 : 1'b1;
assign LED_OUT[1] = (led_pc_cmd_cnt       != 32'd0) ? 1'b0 : 1'b1;
assign LED_OUT[2] = led_adc_work_active ? led_adc_blink : 1'b1;
assign LED_OUT[3] = (led_udp_evt_done_cnt != 32'd0) ? 1'b0 : 1'b1;

assign SYS_OUT = sys_led;


endmodule
