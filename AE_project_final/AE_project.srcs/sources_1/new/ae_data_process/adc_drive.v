`timescale 1ns / 1ps
`include "debug_cfg.vh"

module adc_drive #(
    parameter                           DEBUG_ILA                   = 0                    
)(
    input                               sys_clk                    ,
    input                               reset_n                    ,
    input                               spi_init_start             ,

    output reg                          adc_spi_sck                ,
    output reg                          adc_spi_csn                ,
    inout                               adc_spi_dio                ,

    output                              spi_init_done              ,
    output                              spi_init_error              
);

    localparam                          SYS_CLK_HZ                  = 200_000_000          ;
    localparam                          SPI_CLK_HZ                  = 20_000_000           ;
    localparam                          SPI_DIV                     = SYS_CLK_HZ / (2 * SPI_CLK_HZ);

    localparam                          WRITE                       = 1'b0                 ;
    localparam                          READ                        = 1'b1                 ;

    localparam                          STEP_MAX                    = 6'd32                ;

    localparam                          ST_IDLE                     = 2'd0                 ;
    localparam                          ST_LOW                      = 2'd1                 ;
    localparam                          ST_HIGH                     = 2'd2                 ;
    localparam                          ST_POST                     = 2'd3                 ;

    // 褰撳墠姝ラ瀵瑰簲鐨� SPI 鍦板潃銆佹暟鎹拰璇诲啓鏂瑰悜
    reg                  [  15: 0]      adc_spi_addr               ;
    reg                  [   7: 0]      adc_mem_reg                ;
    reg                                 spi_dio_ctrl               ;

    // SPI 椹卞姩鐘舵��
    reg                  [   1: 0]      cur_state                  ;
    reg                  [   1: 0]      next_state                 ;

    reg                  [   3: 0]      spi_clk_cnt                ;
    reg                  [   5: 0]      spi_addr_num               ;
    reg                  [   4: 0]      bit_idx                    ;

    // DIO 涓夋�佹帶鍒�
    reg                                 spi_dio_data_out           ;
    reg                                 spi_dio_ctrl_out           ;
    wire                                spi_dio_data_in            ;

    // SPI 璇诲洖鏁版嵁
    reg                  [   7: 0]      reg_data                   ;
    reg                  [   7: 0]      reg_data_out               ;

    // 鍒濆鍖栫粨鏋�
    reg                                 init_done                  ;
    reg                                 init_error                 ;

    // 璋冭瘯淇℃伅锛欳hip ID 寮傚父浠呭憡璀︼紝涓嶇疆鑷村懡閿欒
    reg                                 chip_id_warn               ;

    // 閿欒瀹氫綅淇℃伅
    reg                                 err_valid                  ;
    reg                  [   5: 0]      err_step                   ;
    reg                  [  15: 0]      err_addr                   ;
    reg                  [   7: 0]      err_expected               ;
    reg                  [   7: 0]      err_got                    ;

    // spi_init_start 鎷夐珮鍙Е鍙戜竴娆★紝鎷変綆鍚庨噸鏂版瑁�
    reg                                 start_armed                ;

    // 褰撳墠姝ラ鐨勬牎楠屾帶鍒�
    reg                                 step_verify_en             ;
    reg                                 step_verify_fatal          ;
    reg                  [   7: 0]      step_verify_expected       ;
    reg                  [   7: 0]      step_verify_mask           ;

    // 褰撳墠姝ラ鐨勫憡璀︽帶鍒�
    reg                                 step_warn_en               ;
    reg                  [   7: 0]      step_warn_expected         ;

    // 褰撳墠搴斿彂閫佺殑 SPI 浣�
    reg                                 cur_tx_bit                 ;

    wire                                spi_tick                   ;

    assign                              spi_init_done               = init_done            ;
    assign                              spi_init_error              = init_error           ;
    assign                              spi_tick                    = (spi_clk_cnt == SPI_DIV - 1);

    //--------------------------------------------------------------------------
    // 姝ラ琛細
    // 1. 鍓嶇疆璇诲彇 / 淇℃伅璇诲彇锛氫笉鐩存帴缃� init_error
    // 2. 鍐欏悗鍥炶姝ラ锛氭墠杩涜 fatal compare
    // 3. Chip ID锛氫粎鍛婅锛屼笉鑷村懡
    //--------------------------------------------------------------------------
    always @(*) begin
        adc_spi_addr          = 16'h0000;
        adc_mem_reg           = 8'h00;
        spi_dio_ctrl          = WRITE;

        step_verify_en        = 1'b0;
        step_verify_fatal     = 1'b0;
        step_verify_expected  = 8'h00;
        step_verify_mask      = 8'hFF;

        step_warn_en          = 1'b0;
        step_warn_expected    = 8'h00;

        case (spi_addr_num)
            6'd0  : begin end

            6'd1  : begin adc_spi_addr = 16'h0000; adc_mem_reg = 8'h3C; spi_dio_ctrl = WRITE; end
            6'd2  : begin adc_spi_addr = 16'h00FF; adc_mem_reg = 8'h01; spi_dio_ctrl = READ;  end
            6'd3  : begin adc_spi_addr = 16'h0014; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd4  : begin adc_spi_addr = 16'h0015; adc_mem_reg = 8'h01; spi_dio_ctrl = READ;  end
            6'd5  : begin adc_spi_addr = 16'h0000; adc_mem_reg = 8'h18; spi_dio_ctrl = WRITE; end

            // Chip ID锛氬彧鍛婅
            6'd6  : begin
                adc_spi_addr       = 16'h0001;
                adc_mem_reg        = 8'h92;
                spi_dio_ctrl       = READ;
                step_warn_en       = 1'b1;
                step_warn_expected = 8'h92;
            end

            6'd7  : begin adc_spi_addr = 16'h0002; adc_mem_reg = 8'h02; spi_dio_ctrl = READ;  end
            6'd8  : begin adc_spi_addr = 16'h0004; adc_mem_reg = 8'h0F; spi_dio_ctrl = READ;  end
            6'd9  : begin adc_spi_addr = 16'h0005; adc_mem_reg = 8'h3F; spi_dio_ctrl = READ;  end
            6'd10 : begin adc_spi_addr = 16'h000D; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd11 : begin adc_spi_addr = 16'h000D; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end

            6'd12 : begin adc_spi_addr = 16'h0014; adc_mem_reg = 8'h01; spi_dio_ctrl = WRITE; end
            6'd13 : begin adc_spi_addr = 16'h0015; adc_mem_reg = 8'h20; spi_dio_ctrl = WRITE; end

            // 鍐欏悗鍥炶鏍￠獙锛氳嚧鍛�
            6'd14 : begin
                adc_spi_addr          = 16'h0014;
                adc_mem_reg           = 8'h01;
                spi_dio_ctrl          = READ;
                step_verify_en        = 1'b1;
                step_verify_fatal     = 1'b1;
                step_verify_expected  = 8'h01;
                step_verify_mask      = 8'hFF;
            end

            6'd15 : begin
                adc_spi_addr          = 16'h0015;
                adc_mem_reg           = 8'h20;
                spi_dio_ctrl          = READ;
                step_verify_en        = 1'b1;
                step_verify_fatal     = 1'b1;
                step_verify_expected  = 8'h20;
                step_verify_mask      = 8'hFF;
            end

            6'd16 : begin adc_spi_addr = 16'h0021; adc_mem_reg = 8'h41; spi_dio_ctrl = READ;  end
            6'd17 : begin adc_spi_addr = 16'h0022; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd18 : begin adc_spi_addr = 16'h0100; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd19 : begin adc_spi_addr = 16'h0101; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd20 : begin adc_spi_addr = 16'h0102; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd21 : begin adc_spi_addr = 16'h0109; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end

            6'd22 : begin adc_spi_addr = 16'h0008; adc_mem_reg = 8'h20; spi_dio_ctrl = WRITE; end

            // 鍐欏悗鍥炶鏍￠獙锛氳嚧鍛�
            6'd23 : begin
                adc_spi_addr          = 16'h0008;
                adc_mem_reg           = 8'h20;
                spi_dio_ctrl          = READ;
                step_verify_en        = 1'b1;
                step_verify_fatal     = 1'b1;
                step_verify_expected  = 8'h20;
                step_verify_mask      = 8'hFF;
            end

            6'd24 : begin adc_spi_addr = 16'h000B; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd25 : begin adc_spi_addr = 16'h00FF; adc_mem_reg = 8'h01; spi_dio_ctrl = READ;  end
            6'd26 : begin adc_spi_addr = 16'h0000; adc_mem_reg = 8'h18; spi_dio_ctrl = READ;  end
            6'd27 : begin adc_spi_addr = 16'h000C; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd28 : begin adc_spi_addr = 16'h0010; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd29 : begin adc_spi_addr = 16'h0016; adc_mem_reg = 8'h03; spi_dio_ctrl = READ;  end
            6'd30 : begin adc_spi_addr = 16'h0018; adc_mem_reg = 8'h04; spi_dio_ctrl = READ;  end
            6'd31 : begin adc_spi_addr = 16'h0019; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end
            6'd32 : begin adc_spi_addr = 16'h001A; adc_mem_reg = 8'h00; spi_dio_ctrl = READ;  end

            default: begin end
        endcase
    end

    //--------------------------------------------------------------------------
    // SPI 甯ф牸寮忥細
    // [R/W][W1][W0][A12:A0][D7:D0]
    //--------------------------------------------------------------------------
    always @(*) begin
        case (bit_idx)
            5'd0  : cur_tx_bit = spi_dio_ctrl;
            5'd1  : cur_tx_bit = 1'b0;
            5'd2  : cur_tx_bit = 1'b0;
            5'd3  : cur_tx_bit = adc_spi_addr[12];
            5'd4  : cur_tx_bit = adc_spi_addr[11];
            5'd5  : cur_tx_bit = adc_spi_addr[10];
            5'd6  : cur_tx_bit = adc_spi_addr[9];
            5'd7  : cur_tx_bit = adc_spi_addr[8];
            5'd8  : cur_tx_bit = adc_spi_addr[7];
            5'd9  : cur_tx_bit = adc_spi_addr[6];
            5'd10 : cur_tx_bit = adc_spi_addr[5];
            5'd11 : cur_tx_bit = adc_spi_addr[4];
            5'd12 : cur_tx_bit = adc_spi_addr[3];
            5'd13 : cur_tx_bit = adc_spi_addr[2];
            5'd14 : cur_tx_bit = adc_spi_addr[1];
            5'd15 : cur_tx_bit = adc_spi_addr[0];
            5'd16 : cur_tx_bit = adc_mem_reg[7];
            5'd17 : cur_tx_bit = adc_mem_reg[6];
            5'd18 : cur_tx_bit = adc_mem_reg[5];
            5'd19 : cur_tx_bit = adc_mem_reg[4];
            5'd20 : cur_tx_bit = adc_mem_reg[3];
            5'd21 : cur_tx_bit = adc_mem_reg[2];
            5'd22 : cur_tx_bit = adc_mem_reg[1];
            5'd23 : cur_tx_bit = adc_mem_reg[0];
            default: cur_tx_bit = 1'b0;
        endcase
    end

    //--------------------------------------------------------------------------
    // 绗竴娈碉細鐘舵�佸瘎瀛樺櫒
    //--------------------------------------------------------------------------
    always @(posedge sys_clk) begin
        if (!reset_n) begin
            cur_state <= ST_IDLE;
        end else begin
            cur_state <= next_state;
        end
    end

    //--------------------------------------------------------------------------
    // 绗簩娈碉細娆℃�侀�昏緫
    //--------------------------------------------------------------------------
    always @(*) begin
        next_state = cur_state;
        case (cur_state)
            ST_IDLE: begin
                if (spi_init_start && start_armed) begin
                    next_state = ST_LOW;
                end
            end

            ST_LOW: begin
                if (spi_tick) begin
                    next_state = ST_HIGH;
                end
            end

            ST_HIGH: begin
                if (spi_tick) begin
                    if (bit_idx == 5'd23) next_state = ST_POST;
                    else                  next_state = ST_LOW;
                end
            end

            ST_POST: begin
                if (spi_tick) begin
                    if (spi_addr_num == STEP_MAX) next_state = ST_IDLE;
                    else                          next_state = ST_LOW;
                end
            end

            default: next_state = ST_IDLE;
        endcase
    end

    //--------------------------------------------------------------------------
    // 绗笁娈碉細鐘舵�佽緭鍑哄拰鏁版嵁閫氳矾
    //--------------------------------------------------------------------------
    always @(posedge sys_clk) begin
        if (!reset_n) begin
            adc_spi_sck         <= 1'b0;
            adc_spi_csn         <= 1'b1;
            spi_dio_data_out    <= 1'b0;
            spi_dio_ctrl_out    <= 1'b0;

            spi_clk_cnt         <= 4'd0;
            spi_addr_num        <= 6'd0;
            bit_idx             <= 5'd0;

            reg_data            <=8'd0;
            reg_data_out        <=8'd0;

            init_done           <= 1'b0;
            init_error          <= 1'b0;
            chip_id_warn        <= 1'b0;

            err_valid           <= 1'b0;
            err_step            <= 6'd0;
            err_addr            <= 16'd0;
            err_expected        <= 8'd0;
            err_got             <= 8'd0;

            start_armed         <= 1'b1;
        end else begin
            // start 淇″彿鎷変綆鍚庯紝鍏佽涓嬩竴杞垵濮嬪寲鍐嶆瑙﹀彂
            if (!spi_init_start && (cur_state == ST_IDLE)) begin
                start_armed <= 1'b1;
            end

            case (cur_state)
                ST_IDLE: begin
                    adc_spi_sck      <= 1'b0;
                    adc_spi_csn      <= 1'b1;
                    spi_dio_data_out <= 1'b0;
                    spi_dio_ctrl_out <= 1'b0;

                    spi_clk_cnt      <= 4'd0;
                    bit_idx          <= 5'd0;
                    reg_data         <=8'd0;

                    if (spi_init_start && start_armed) begin
                        start_armed   <= 1'b0;
                        spi_addr_num  <= 6'd1;

                        init_done     <= 1'b0;
                        init_error    <= 1'b0;
                        chip_id_warn  <= 1'b0;

                        err_valid     <= 1'b0;
                        err_step      <= 6'd0;
                        err_addr      <= 16'd0;
                        err_expected  <= 8'd0;
                        err_got       <= 8'd0;
                    end
                end

                ST_LOW: begin
                    if (spi_tick) begin
                        spi_clk_cnt <= 4'd0;

                        adc_spi_csn <= 1'b0;
                        adc_spi_sck <= 1'b0;

                        // 璇绘搷浣滅殑鏁版嵁闃舵閲婃斁 DIO锛屾�荤嚎鐢� ADC 椹卞姩
                        if ((spi_dio_ctrl == READ) && (bit_idx >= 5'd16)) begin
                            spi_dio_ctrl_out <= 1'b1;
                            spi_dio_data_out <= 1'b0;
                        end else begin
                            spi_dio_ctrl_out <= 1'b0;
                            spi_dio_data_out <= cur_tx_bit;
                        end
                    end else begin
                        spi_clk_cnt <= spi_clk_cnt + 1'b1;
                    end
                end

                ST_HIGH: begin
                    if (spi_tick) begin
                        spi_clk_cnt <= 4'd0;

                        adc_spi_csn <= 1'b0;
                        adc_spi_sck <= 1'b1;

                        // 璇绘搷浣滃湪楂樼數骞崇浉浣嶉噰鏍疯緭鍏ヤ綅
                        if ((spi_dio_ctrl == READ) && (bit_idx >= 5'd16)) begin
                            case (bit_idx)
                                5'd16 : reg_data[7] <= spi_dio_data_in;
                                5'd17 : reg_data[6] <= spi_dio_data_in;
                                5'd18 : reg_data[5] <= spi_dio_data_in;
                                5'd19 : reg_data[4] <= spi_dio_data_in;
                                5'd20 : reg_data[3] <= spi_dio_data_in;
                                5'd21 : reg_data[2] <= spi_dio_data_in;
                                5'd22 : reg_data[1] <= spi_dio_data_in;
                                5'd23 : reg_data[0] <= spi_dio_data_in;
                                default: ;
                            endcase
                        end

                        if (bit_idx != 5'd23) begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        spi_clk_cnt <= spi_clk_cnt + 1'b1;
                    end
                end

                ST_POST: begin
                    if (spi_tick) begin
                        spi_clk_cnt      <= 4'd0;
                        adc_spi_csn      <= 1'b1;
                        adc_spi_sck      <= 1'b0;
                        spi_dio_ctrl_out <= 1'b0;
                        spi_dio_data_out <= 1'b0;

                        reg_data_out     <=reg_data;

                        // 鍛婅绫绘鏌ワ細鍙褰曪紝涓嶈嚧鍛�
                        if ((spi_dio_ctrl == READ) && step_warn_en) begin
                            if (reg_data != step_warn_expected) begin
                                chip_id_warn <= 1'b1;
                            end
                        end

                        // 鑷村懡绫绘鏌ワ細鍙鐪熸鐨勫啓鍚庡洖璇绘楠ょ敓鏁�
                        if ((spi_dio_ctrl == READ) && step_verify_en) begin
                            if ((reg_data & step_verify_mask) != (step_verify_expected & step_verify_mask)) begin
                                if (step_verify_fatal) begin
                                    init_error <= 1'b1;
                                    if (!err_valid) begin
                                        err_valid    <= 1'b1;
                                        err_step     <= spi_addr_num;
                                        err_addr     <= adc_spi_addr;
                                        err_expected <= step_verify_expected;
                                        err_got      <= reg_data;
                                    end
                                end
                            end
                        end

                        // 褰撳墠姝ラ瀹屾垚锛岃繘鍏ヤ笅涓�姝ラ鎴栫粨鏉熷垵濮嬪寲
                        if (spi_addr_num == STEP_MAX) begin
                            init_done <= 1'b1;
                            bit_idx   <= 5'd0;
                        end else begin
                            spi_addr_num <= spi_addr_num + 1'b1;
                            bit_idx      <= 5'd0;
                            reg_data     <=8'd0;
                        end
                    end else begin
                        spi_clk_cnt <= spi_clk_cnt + 1'b1;
                    end
                end

                default: begin
                    adc_spi_sck <= 1'b0;
                    adc_spi_csn <= 1'b1;
                    spi_clk_cnt <= 4'd0;
                end
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // 鍗曠嚎鍙屽悜 DIO
    //--------------------------------------------------------------------------
    IOBUF #(
    .DRIVE                              (12                        ),
    .IBUF_LOW_PWR                       ("TRUE"                    ),
    .IOSTANDARD                         ("DEFAULT"                 ),
    .SLEW                               ("SLOW"                    ) 
    ) IOBUF_inst_1 (
    .O                                  (spi_dio_data_in           ),
    .IO                                 (adc_spi_dio               ),
    .I                                  (spi_dio_data_out          ),
    .T                                  (spi_dio_ctrl_out          ) 
    );

`ifdef DEBUG_ADC_SPI
generate
    if (DEBUG_ILA) begin : GEN_DEBUG_ILA_ADC_DRIVE
        ILA_ADC_DRIVE ila_adc_drive_ (
    .clk                                (sys_clk                   ),
    .probe0                             (init_error                ),// input wire [0:0]  probe0
    .probe1                             (adc_spi_sck               ),// input wire [0:0]  probe1
    .probe2                             (adc_spi_csn               ),// input wire [0:0]  probe2
    .probe3                             (spi_init_done             ),// input wire [0:0]  probe3
    .probe4                             (spi_addr_num              ),// input wire [5:0]  probe4
    .probe5                             (reg_data_out              ),// input wire [7:0]  probe5
    .probe6                             (adc_spi_addr[7:0]         ),// input wire [7:0]  probe6
    .probe7                             (adc_mem_reg               ) // input wire [7:0]  probe7
        );
    end
endgenerate
`endif

endmodule

