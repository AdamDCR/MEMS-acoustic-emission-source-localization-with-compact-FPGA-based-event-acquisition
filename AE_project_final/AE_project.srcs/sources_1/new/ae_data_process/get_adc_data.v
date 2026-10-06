`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/09/17 19:31:46
// Design Name: 
// Module Name: get_adc_data
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

`include "debug_cfg.vh"
module get_adc_data #(
    parameter                           DEBUG_ILA                   = 0                    
)(
    //绯荤粺淇″彿
    input                               sys_clk                    ,//  绯荤粺鏃堕挓
    input                               reset_n                    ,//  绯荤粺澶嶄綅
    // ADC鎺у埗淇″彿
    input                               adc_en                     ,//  ADC閲囬泦浣胯兘
    // ADC椹卞姩鏃堕挓
    input                               adc_clk                    ,//  ADC鏃堕挓淇″彿 40MHz 
    // ADC SPI閫氫俊鎺ュ彛
    output wire                         adc_pdwn                   ,//  ADC POWER-DOWN
    output wire                         adc_spi_sck                ,//  ADC SPI閫氫俊鏃堕挓淇″彿
    output wire                         adc_spi_csn                ,//  ADC SPI閫氫俊鐗囬�変俊鍙�
    inout                               adc_spi_dio                ,//  ADC SPI閫氫俊鏁版嵁杈撳叆杈撳嚭淇″彿
    output                              adc_clk_out_p              ,//  ADC 鏁版嵁鏃堕挓宸垎LVDS宸垎杈撳嚭
    output                              adc_clk_out_n              ,//  
    //杈撳叆ADC杩斿洖鐨勬暟鎹拰鏃堕挓
    input                               adc_fclk_p                 ,//  ADC 鏁版嵁杈撳叆甯ф椂閽烲VDS宸垎杈撳叆
    input                               adc_fclk_n                 ,//  
    input                               adc_dclk_p                 ,//  ADC 鏁版嵁杈撳叆鏃堕挓LVDS宸垎杈撳叆
    input                               adc_dclk_n                 ,//  
    input                [   7: 0]      adc_data_in_p              ,//  ADC 鏁版嵁淇″彿 LVDS宸垎杈撳叆
    input                [   7: 0]      adc_data_in_n              ,//  
    // 杈撳嚭ADC鏁版嵁鍜屾椂閽�
    output                              adc_div_clk                ,//  ADC 鏁版嵁鏃堕挓鍒嗛淇″彿
    output               [  13: 0]      adc_data0              ,//  ADC 鏁版嵁涓插苟杞崲鍚庤緭鍑� 閫氶亾0
    output               [  13: 0]      adc_data1              ,//  ADC 鏁版嵁涓插苟杞崲鍚庤緭鍑� 閫氶亾1
    output               [  13: 0]      adc_data2              ,//  ADC 鏁版嵁涓插苟杞崲鍚庤緭鍑� 閫氶亾2
    output               [  13: 0]      adc_data3              ,//  ADC 鏁版嵁涓插苟杞崲鍚庤緭鍑� 閫氶亾3
    output               [  13: 0]      adc_data4              ,//  ADC 鏁版嵁涓插苟杞崲鍚庤緭鍑� 閫氶亾4
    output               [  13: 0]      adc_data5              ,//  ADC 鏁版嵁涓插苟杞崲鍚庤緭鍑� 閫氶亾5
    output               [  13: 0]      adc_data6              ,//  ADC 鏁版嵁涓插苟杞崲鍚庤緭鍑� 閫氶亾6
    output               [  13: 0]      adc_data7              ,//  ADC 鏁版嵁涓插苟杞崲鍚庤緭鍑� 閫氶亾7
    output               [  13: 0]      adc_out_frame              ,
    output                              adc_data_vld                //  ADC 鏁版嵁杈撳嚭鏈夋晥淇″彿
);
    //parameter define
    parameter                           CLK_FRE                     = 200_000_000          ;       //  绯荤粺宸ヤ綔棰戠巼鍙傛暟锛歁Hz
    parameter                           ADC_SAMPLE_RATE             = 40                   ;       //  ADC绯荤粺閲囨牱棰戠巼锛歁Hz
    parameter                           FRAME_PATTERN               = 14'b11_1111_1000_0000;
    localparam                          IO_RST_RELEASE_US           = 50                   ;   // 鏈�鍚庢斁寮�IO/ISERDES澶嶄綅
    localparam                          CLK_RST_RELEASE_US          = 40                   ;   // 鍙�夛細鍏堟斁寮�鏃堕挓鐩稿叧澶嶄綅
    localparam                          STANDBY_WAIT_US             = 50                   ;   // 寤鸿鐣欎綑閲忥紱鎵嬪唽typ涓�35us
    
    localparam                          CLK_RST_CYCLES              = (CLK_FRE / 1_000_000) * CLK_RST_RELEASE_US;
    localparam                          IO_RST_CYCLES               = (CLK_FRE / 1_000_000) * IO_RST_RELEASE_US;
    
    reg                                 adc_pdwn_buf               ;

    wire                 [  13: 0]      data[7:0]                  ;
    assign                              adc_data0               = data[0]              ;
    assign                              adc_data1               = data[1]              ;
    assign                              adc_data2               = data[2]              ;
    assign                              adc_data3               = data[3]              ;
    assign                              adc_data4               = data[4]              ;
    assign                              adc_data5               = data[5]              ;
    assign                              adc_data6               = data[6]              ;
    assign                              adc_data7               = data[7]              ;

    reg                                 spi_init_start             ;
    wire                                spi_init_done              ;
    wire                                spi_init_error             ;
    wire                                spi_init_pass              ;
    assign                              spi_init_pass               = spi_init_done ;//&& !spi_init_error;
    reg                                 init_buf                   ;
    assign                              adc_pdwn                    = adc_pdwn_buf         ;
    wire                                adc_cfg_pass               ;
    assign                              adc_cfg_pass                = spi_init_done ;//&& !spi_init_error;
    wire                 [  13: 0]      frame                      ;

    assign                              adc_out_frame               = frame                ;

// ADC鏃堕挓宸垎淇″彿杞崲涓哄樊鍒嗚緭鍑� 鎻愪緵缁橝DC锛屾椂閽熼鐜囦负fs MHz
OBUFDS #(
    .IOSTANDARD                         ("DEFAULT"                 ),// Specify the output I/O standard
    .SLEW                               ("FAST"                    ) // Specify the output slew rate
) OBUFDS_inst1 (
    .O                                  (adc_clk_out_p             ),// Diff_p output (connect directly to top-level port)
    .OB                                 (adc_clk_out_n             ),// Diff_n output (connect directly to top-level port)
    .I                                  (adc_clk                   ) // Buffer input   fs MHz
);


// ADC浣胯兘淇″彿鍚屾鍒扮郴缁熸椂閽熷煙锛屾帶鍒禨PI鍒濆鍖栧拰ADC鏁版嵁閲囬泦
    always @(posedge sys_clk or negedge reset_n)
        begin
            if(!reset_n)
                begin
                    spi_init_start <= 1'b0;
                    init_buf       <= 1'b0;
                    adc_pdwn_buf   <= 1'b1;
                end
            else if(init_buf)
                begin
                    spi_init_start <= 1'b0;
                    if(adc_en)
                        begin
                            adc_pdwn_buf   <= 1'b0;
                        end
                    else
                        begin
                            adc_pdwn_buf   <= 1'b1;
                        end
                end
            else if(!spi_init_done)
                begin
                    // 鍒濆鍖栬繕娌¤窇瀹岋細缁х画鍒濆鍖栵紝ADC淇濇寔寰呮満
                    spi_init_start <= 1'b1;
                    adc_pdwn_buf   <= 1'b1;
                end
            else if(spi_init_pass)
                begin   
                    // 鍒濆鍖栬窇瀹屼笖鎴愬姛锛氬厑璁歌繘鍏ユ甯稿緟鏈�/杩愯鎺у埗
                    spi_init_start <= 1'b0;
                    init_buf       <= 1'b1;
                end
            else
                begin
                    // 鍒濆鍖栬窇瀹屼絾澶辫触锛氫繚鎸佸緟鏈猴紝涓嶈繘鍏ラ噰鏍�
                    init_buf       <= 1'b0              ;
                    spi_init_start <= 1'b0              ;
                    adc_pdwn_buf   <= 1'b1              ;
                end
        end

// ###########  ADC SPI椹卞姩鎺у埗 ############//
adc_drive #(
    .DEBUG_ILA                          ( DEBUG_ILA                ) 
) adc_drive_inst(
    .sys_clk                            (sys_clk                   ),
    .reset_n                            (reset_n                   ),
    .spi_init_start                     (spi_init_start            ),
    .adc_spi_sck                        (adc_spi_sck               ),
    .adc_spi_csn                        (adc_spi_csn               ),
    .adc_spi_dio                        (adc_spi_dio               ),
    .spi_init_done                      (spi_init_done             ),
    .spi_init_error                     (spi_init_error            ) 
);



// ###########  ADC 杈撳叆鏁版嵁涓插苟杞崲 ############//
    reg                                 clk_reset                =1'b1;
    reg                                 io_reset                 =1'b1;
    reg                  [  31: 0]      reset_cnt                  ;

    always @(posedge sys_clk or negedge reset_n)
        begin
            if(!reset_n)
                begin
                    reset_cnt <= 32'd0;
                end
            else if (adc_pdwn_buf)
                begin
                    // PDWN=1 鏃讹紝ADC浠嶅浜巗tandby锛岀瓑寰呰鏁版竻闆�
                    reset_cnt <= 32'd0;
                end
            else if(reset_cnt < IO_RST_CYCLES)
                begin
                    // PDWN閲婃斁鍚庡紑濮嬫寜寰璁℃暟
                    reset_cnt <= reset_cnt + 1'b1;
                end
            else
                begin
                    reset_cnt <= reset_cnt;
                end
        end

    always @(posedge sys_clk or negedge reset_n) begin
        if(!reset_n) begin
            clk_reset <= 1'b1;
            io_reset  <= 1'b1;
        end
        else if(adc_pdwn_buf) begin
            clk_reset <= 1'b1;
            io_reset  <= 1'b1;
        end
        else begin
            if(reset_cnt >= CLK_RST_CYCLES)
                clk_reset <= 1'b0;
            if(reset_cnt >= IO_RST_CYCLES)
                io_reset  <= 1'b0;
            end
        end

    // ADC杈撳叆鏃堕挓鍒嗛锛屽垎棰戝悗鏃堕挓浣滀负ADC鏁版嵁涓插苟杞崲鏃堕挓
    wire                                adc_dclk_in                ;
    wire                                div_clk                    ;
    reg                                 bitslip                    ;
    assign                              adc_div_clk                 = div_clk              ;
    wire                                clk_in_buf                 ;
    // ADC杈撳叆鏃堕挓宸垎淇″彿杞崲涓哄崟绔緭鍏ワ紝鎻愪緵缁橫MCM杩涜鏃堕挓鍒嗛
    adc_dclk_in adc_dclk_in_inst
    (
        // Clock out ports
        .adc_dclk_in                        (adc_dclk_in               ),// output adc_dclk_in  280MHz
        .adc_divclk                         (div_clk                   ),// output adc_divclk   40MHz
        // Clock in ports
        .clk_in1_p                          (adc_dclk_p                ),// input clk_in1_p
        .clk_in1_n                          (adc_dclk_n                ) 
    );                                                              // input clk_in1_n
    // ADC杈撳叆鏃堕挓鍜屾暟鎹甀O澶嶄綅浠庣郴缁熸椂閽熷煙锛坰ys_clk锛夊悓姝ュ埌ADC鏃堕挓鍩燂紙div_clk锛夛紝淇濊瘉鏃堕挓鍜孖O鍚屾椂绋冲畾锛岄伩鍏岻SERDES閿佹
    reg                                 io_reset1,io_reset2        ;
    always @(posedge div_clk or negedge reset_n)
        begin
            if(!reset_n)
                begin
                    io_reset1 <= 1'b1;
                    io_reset2 <= 1'b1;
                end
                else            begin
                    io_reset1 <= io_reset;
                    io_reset2 <= io_reset1;
                end
        end

// ADC鏁版嵁涓插苟杞崲锛屼娇鐢�8涓狪SERDES杩涜鏁版嵁涓插苟杞崲锛�1涓狪SERDES杩涜甯ф椂閽熶覆骞惰浆鎹�
genvar i;
generate
    for(i=0;i<8;i=i+1)
        begin:data_iserdes0
        iserdes u_iserdes_data(
        .clk                                (adc_dclk_in               ),
        .div_clk                            (div_clk                   ),
        .io_reset                           (io_reset2                 ),
        .bitslip                            (bitslip                   ),
        .data_i_p                           (adc_data_in_p[i]          ),
        .data_i_n                           (adc_data_in_n[i]          ),
        .data_o                             (data[i]                   ) 
    );
    end
endgenerate
    // ADC1 杈撳叆鏁版嵁甯ф椂閽熶覆骞惰浆鎹�
iserdes u_iserdes_frame(
    .clk                                (adc_dclk_in               ),
    .div_clk                            (div_clk                   ),
    .io_reset                           (io_reset2                 ),
    .bitslip                            (bitslip                   ),
    .data_i_p                           (adc_fclk_p                ),
    .data_i_n                           (adc_fclk_n                ),
    .data_o                             (frame                     ) 
);



    // ADC浣胯兘淇″彿鍚屾浠庣郴缁熸椂閽熷煙锛坰ys_clk锛夊悓姝ュ埌ADC鏃堕挓鍩燂紙div_clk锛�
    reg                                 adc_pdwn_buf1,adc_pdwn_buf2  ;
    always @(posedge div_clk or negedge reset_n)
        begin
            if(!reset_n)
                begin
                    adc_pdwn_buf1 <= 1'b1;
                    adc_pdwn_buf2 <= 1'b1;
                end
            else
                begin
                    adc_pdwn_buf1 <= adc_pdwn_buf;
                    adc_pdwn_buf2 <= adc_pdwn_buf1;
                end
        end
    // -----------------------------------------------------------------------------
    // adc_cfg_pass 从 sys_clk 域同步到 div_clk 域。
    // 不能直接用 sys_clk 域 adc_cfg_pass 和 div_clk 域 frame 状态组合产生 adc_data_vld。
    // -----------------------------------------------------------------------------
    reg adc_cfg_pass_dclk_m;
    reg adc_cfg_pass_dclk_s;

    always @(posedge div_clk or negedge reset_n) begin
        if (!reset_n) begin
            adc_cfg_pass_dclk_m <= 1'b0;
            adc_cfg_pass_dclk_s <= 1'b0;
        end else begin
            adc_cfg_pass_dclk_m <= adc_cfg_pass;
            adc_cfg_pass_dclk_s <= adc_cfg_pass_dclk_m;
        end
    end
// -----------------------------------------------------------------------------
// AD9257 frame alignment monitor
//
// AD9257 FCO 经 ISERDES 解串后，正确帧格式应为 FRAME_PATTERN = 14'h3F80。
// 旧逻辑的问题是：只要匹配一次就进入 ST_DONE，之后不再检查 frame。
// 新逻辑：
//   1. 搜索阶段：连续多次 frame == 3F80 才认为锁定；
//   2. 锁定阶段：每个 div_clk 周期持续检查 frame；
//   3. 当前 frame != 3F80 时 adc_data_vld 立即拉低；
//   4. 连续错误达到阈值后重新 bitslip。
// -----------------------------------------------------------------------------

localparam [3:0] ST_IDLE      = 4'd0;
localparam [3:0] ST_WAIT      = 4'd1;
localparam [3:0] ST_CHECK     = 4'd2;
localparam [3:0] ST_BITSLIP   = 4'd3;
localparam [3:0] ST_LOCKED    = 4'd4;

// bitslip 后等待 ISERDES 输出稳定的 div_clk 周期数。
// 原来你等 10 个周期，这里继续保留 10。
localparam [3:0] BITSLIP_WAIT_CYCLES = 4'd10;

// 搜索阶段，连续多少次 frame == 3F80 后才认为锁定。
// 建议 4 次，避免偶发误匹配。
localparam [3:0] FRAME_LOCK_GOOD_TH = 4'd4;

// 锁定后，连续多少次 frame != 3F80 后重新 bitslip。
// 如果你希望一错就重新对齐，可以改成 4'd1。
// 推荐先用 2，允许单拍毛刺，但当前拍 vld 仍会立即拉低。
localparam [3:0] FRAME_UNLOCK_BAD_TH = 4'd2;

// 14-bit 解串理论上 bitslip 14 次可遍历所有相位。
// 这里给 20 次余量，超过后置 frame_align_fail，但仍继续尝试重新对齐。
localparam [4:0] BITSLIP_MAX_TRY = 5'd20;

reg [3:0] frame_check_state;
reg [3:0] state_wait_cnt;
reg [3:0] frame_good_cnt;
reg [3:0] frame_bad_cnt;
reg [4:0] bitslip_try_cnt;

reg       frame_locked;
reg       frame_align_fail;

wire      frame_match_now;

assign frame_match_now = (frame == FRAME_PATTERN);

// -----------------------------------------------------------------------------
// 帧对齐状态机
// -----------------------------------------------------------------------------
always @(posedge div_clk or negedge reset_n) begin
    if (!reset_n) begin
        frame_check_state <= ST_IDLE;
        state_wait_cnt    <= 4'd0;
        frame_good_cnt    <= 4'd0;
        frame_bad_cnt     <= 4'd0;
        bitslip_try_cnt   <= 5'd0;
        frame_locked      <= 1'b0;
        frame_align_fail  <= 1'b0;
        bitslip           <= 1'b0;
    end else if (io_reset2 || adc_pdwn_buf2 || !adc_cfg_pass_dclk_s) begin
        frame_check_state <= ST_IDLE;
        state_wait_cnt    <= 4'd0;
        frame_good_cnt    <= 4'd0;
        frame_bad_cnt     <= 4'd0;
        bitslip_try_cnt   <= 5'd0;
        frame_locked      <= 1'b0;
        frame_align_fail  <= 1'b0;
        bitslip           <= 1'b0;
    end else begin
        // 默认 bitslip 为 0，只在 ST_BITSLIP 状态拉高一个 div_clk 周期。
        bitslip <= 1'b0;

        case (frame_check_state)

            ST_IDLE: begin
                frame_locked      <= 1'b0;
                frame_good_cnt    <= 4'd0;
                frame_bad_cnt     <= 4'd0;
                state_wait_cnt    <= 4'd0;
                bitslip_try_cnt   <= 5'd0;
                frame_align_fail  <= 1'b0;
                frame_check_state <= ST_WAIT;
            end

            ST_WAIT: begin
                if (state_wait_cnt >= BITSLIP_WAIT_CYCLES) begin
                    state_wait_cnt    <= 4'd0;
                    frame_check_state <= ST_CHECK;
                end else begin
                    state_wait_cnt <= state_wait_cnt + 1'b1;
                end
            end

            ST_CHECK: begin
                if (frame_match_now) begin
                    bitslip_try_cnt <= 5'd0;
                    frame_bad_cnt   <= 4'd0;

                    if (frame_good_cnt >= (FRAME_LOCK_GOOD_TH - 1'b1)) begin
                        frame_locked      <= 1'b1;
                        frame_good_cnt    <= 4'd0;
                        frame_bad_cnt     <= 4'd0;
                        frame_align_fail  <= 1'b0;
                        frame_check_state <= ST_LOCKED;
                    end else begin
                        frame_good_cnt    <= frame_good_cnt + 1'b1;
                        frame_check_state <= ST_WAIT;
                    end
                end else begin
                    frame_good_cnt <= 4'd0;
                    frame_locked   <= 1'b0;

                    if (bitslip_try_cnt >= BITSLIP_MAX_TRY) begin
                        // 置位失败标志，但不彻底停住，继续重新尝试 bitslip。
                        frame_align_fail  <= 1'b1;
                        bitslip_try_cnt   <= 5'd0;
                        frame_check_state <= ST_BITSLIP;
                    end else begin
                        bitslip_try_cnt   <= bitslip_try_cnt + 1'b1;
                        frame_check_state <= ST_BITSLIP;
                    end
                end
            end

            ST_BITSLIP: begin
                bitslip           <= 1'b1;
                state_wait_cnt    <= 4'd0;
                frame_check_state <= ST_WAIT;
            end

            ST_LOCKED: begin
                if (frame_match_now) begin
                    frame_locked  <= 1'b1;
                    frame_bad_cnt <= 4'd0;
                end else begin
                    // 当前 frame 错误时，立即撤销 frame_locked。
                    // adc_data_vld 本周期也会因为 frame_match_now=0 立即拉低。
                    frame_locked <= 1'b0;

                    if (frame_bad_cnt >= (FRAME_UNLOCK_BAD_TH - 1'b1)) begin
                        frame_bad_cnt     <= 4'd0;
                        frame_good_cnt    <= 4'd0;
                        state_wait_cnt    <= 4'd0;
                        bitslip_try_cnt   <= 5'd0;
                        frame_check_state <= ST_BITSLIP;
                    end else begin
                        frame_bad_cnt <= frame_bad_cnt + 1'b1;
                    end
                end
            end

            default: begin
                frame_check_state <= ST_IDLE;
            end

        endcase
    end
end

// -----------------------------------------------------------------------------
// adc_data_vld 生成
//
// 关键点：
// 1. 必须处于 frame_locked；
// 2. 当前 frame 必须仍然等于 3F80；
// 3. ADC 配置完成信号已经同步到 div_clk；
// 4. ADC 不能处于 powerdown。
// -----------------------------------------------------------------------------
assign adc_data_vld =
                    frame_locked &&
                    frame_match_now &&
                    adc_cfg_pass_dclk_s &&
                    !adc_pdwn_buf2;

endmodule
