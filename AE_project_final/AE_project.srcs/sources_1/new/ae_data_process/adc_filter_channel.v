`timescale 1ns / 1ps

module adc_filter_channel #(
    parameter integer INPUT_IS_OFFSET_BINARY = 0,
    parameter integer FIR_OUT_SHIFT          = 16,

    // 是否启用 FIR 后 post DC blocker
    parameter integer POST_DC_BLOCK_EN       = 1,

    // post DC blocker 参数。
    // Fs = 40 MHz 时，近似截止频率 fc ≈ Fs / (2*pi*2^K)
    // K=14: 约 388 Hz
    // K=16: 约 97 Hz
    // K=17: 约 48 Hz
    // K=18: 约 24 Hz
    parameter integer POST_DC_K              = 16,
    parameter integer POST_DC_STATE_W        = 40,
    parameter integer POST_DC_STATE_FRAC     = 16,

    // 屏蔽 IIR / FIR / DC blocker 启动瞬态
    parameter integer FILTER_WARMUP_SAMPLES  = 16384
)(
    input                               clk,
    input                               reset_n,
    input                               sample_valid,
    input      [13:0]                   sample_in,

    output                              sample_out_valid,
    output signed [15:0]                sample_out,
    output                              filter_backpressure
);

    // -------------------------------------------------------------------------
    // Reset filter state when the ADC valid stream stops.
    // 注意：
    // 如果 sample_valid 是连续采样流中的“每拍有效”，这个写法可以。
    // 如果 sample_valid 是间歇脉冲，中间会有低电平空拍，则这个复位逻辑会反复清滤波器。
    // 那种情况下需要改成由 adc_data_vld / adc_enable 这类持续信号控制。
    // -------------------------------------------------------------------------
    reg local_reset_n;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            local_reset_n <= 1'b0;
        end else begin
            local_reset_n <= sample_valid;
        end
    end

    wire chain_reset_n;
    assign chain_reset_n = reset_n & local_reset_n;


    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    wire signed [15:0] sample_s16;
    wire               sample_s16_valid;

    wire signed [15:0] hp_data;
    wire               hp_valid;

    wire signed [15:0] fir_data;
    wire               fir_valid;

    wire signed [15:0] dc_data;
    wire               dc_valid;


    // sample_s16 是组合转换结果，因此 valid 直接跟随输入 valid。
    assign sample_s16_valid = sample_valid;


    // -------------------------------------------------------------------------
    // 14-bit ADC signed data -> signed 16-bit
    //
    // 你已经确认 ADC 返回的是有符号整数，所以正常应保持：
    // INPUT_IS_OFFSET_BINARY = 0
    // 即只做符号扩展，不翻转符号位。
    // -------------------------------------------------------------------------
    adc_filter_adc14_to_s16 #(
        .INPUT_IS_OFFSET_BINARY(INPUT_IS_OFFSET_BINARY)
    ) u_adc_filter_adc14_to_s16 (
        .din  (sample_in),
        .dout (sample_s16)
    );


    // -------------------------------------------------------------------------
    // Main IIR high-pass filter
    //
    // 这里建议你使用无乘法器版本的 adc_filter_iir_hp4_10k_40m，
    // 内部实例化 hp_iir_shift_4th_1ch。
    // -------------------------------------------------------------------------
    adc_filter_iir_hp4_10k_40m u_adc_filter_iir_hp4_10k_40m (
        .clk              (clk),
        .reset_n          (chain_reset_n),
        .sample_valid     (sample_s16_valid),
        .sample_in        (sample_s16),
        .sample_out_valid (hp_valid),
        .sample_out       (hp_data)
    );


    // -------------------------------------------------------------------------
    // FIR low-pass filter
    //
    // 注意：
    // FIR Compiler IP 里面必须配置 Input Data Type = Signed。
    // 否则 hp_data 中的负数会被当作 unsigned 大正数，导致明显直流偏置。
    // -------------------------------------------------------------------------
    adc_filter_fir_500k_lp_wrap #(
        .FIR_OUT_SHIFT(FIR_OUT_SHIFT)
    ) u_adc_filter_fir_500k_lp_wrap (
        .clk                 (clk),
        .reset_n             (chain_reset_n),
        .sample_valid        (hp_valid),
        .sample_in           (hp_data),
        .sample_out_valid    (fir_valid),
        .sample_out          (fir_data),
        .filter_backpressure (filter_backpressure)
    );


    // -------------------------------------------------------------------------
    // Post DC blocker
    //
    // 位置：FIR 后、最终输出前。
    //
    // 作用：
    // 1. 清除 FIR 后残留的极低频基线偏置；
    // 2. 不使用乘法器；
    // 3. POST_DC_K 建议先用 16。
    // -------------------------------------------------------------------------
    generate
        if (POST_DC_BLOCK_EN != 0) begin : g_post_dc_block

            hp_iir_shift_1ch #(
                .SAMPLE_W   (16),
                .STATE_W    (POST_DC_STATE_W),
                .STATE_FRAC (POST_DC_STATE_FRAC),
                .K          (POST_DC_K)
            ) u_post_dc_block (
                .clk        (clk),
                .reset_n    (chain_reset_n),
                .in_valid   (fir_valid),
                .x_in       (fir_data),
                .out_valid  (dc_valid),
                .y_out      (dc_data)
            );

        end else begin : g_no_post_dc_block

            assign dc_valid = fir_valid;
            assign dc_data  = fir_data;

        end
    endgenerate


    // -------------------------------------------------------------------------
    // Warm-up gate
    //
    // 现在 warm-up 应该统计 dc_valid，而不是 fir_valid。
    // 因为最终输出已经变成 post DC blocker 的输出。
    // -------------------------------------------------------------------------
    localparam integer WARMUP_CNT_W =
        (FILTER_WARMUP_SAMPLES <= 1) ? 1 : $clog2(FILTER_WARMUP_SAMPLES + 1);

    reg [WARMUP_CNT_W-1:0] warmup_cnt;
    reg                    warmup_done;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            warmup_cnt  <= {WARMUP_CNT_W{1'b0}};
            warmup_done <= 1'b0;
        end else if (!chain_reset_n) begin
            warmup_cnt  <= {WARMUP_CNT_W{1'b0}};
            warmup_done <= 1'b0;
        end else if (dc_valid && !warmup_done) begin
            if (warmup_cnt >= FILTER_WARMUP_SAMPLES - 1) begin
                warmup_done <= 1'b1;
            end else begin
                warmup_cnt <= warmup_cnt + 1'b1;
            end
        end
    end


    // -------------------------------------------------------------------------
    // Final output
    // -------------------------------------------------------------------------
    assign sample_out_valid = dc_valid && warmup_done;
    assign sample_out       = warmup_done ? dc_data : 16'sd0;

endmodule