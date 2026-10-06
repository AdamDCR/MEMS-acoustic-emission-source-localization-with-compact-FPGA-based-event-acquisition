// ============================================================================
// ADC sample downsampler
//
// sample_rate_div:
//   1  -> 40 MHz
//   2  -> 20 MHz
//   4  -> 10 MHz
//   8  -> 5  MHz
//   ...
//   80 -> 500 kHz
//
// 设计原则：
// 1. 只对 sample_valid_in 计数，不对空拍计数；
// 2. 输出 sample_valid_out / sample_data_out / trigger_data_out 全部寄存；
// 3. enable 关闭或配置更新时清零抽取相位；
// 4. 配置更新后第一个有效样本立即输出，后续每 div 个样本输出一次；
// 5. sample_rate_div 限制在 1~MAX_DIV。
// ============================================================================

`include "debug_cfg.vh"

module ae_adc_data_downsampler #(
    parameter integer DATA_W  = 256,
    parameter integer MAX_DIV = 80      // 40 MHz / 80 = 500 kHz
)(
    input                   clk,
    input                   reset_n,

    input                   enable,
    input                   cfg_update_pulse,
    input      [15:0]       sample_rate_div,

    input                   sample_valid_in,
    input      [DATA_W-1:0] sample_data_in,
    input      [DATA_W-1:0] trigger_data_in,

    output reg              sample_valid_out,
    output reg [DATA_W-1:0] sample_data_out,
    output reg [DATA_W-1:0] trigger_data_out
);

    // ------------------------------------------------------------------------
    // divisor sanitize
    // ------------------------------------------------------------------------
    function [15:0] sanitize_divisor;
        input [15:0] div_in;
        begin
            if (div_in <= 16'd1) begin
                sanitize_divisor = 16'd1;
            end else if (div_in > MAX_DIV[15:0]) begin
                sanitize_divisor = MAX_DIV[15:0];
            end else begin
                sanitize_divisor = div_in;
            end
        end
    endfunction

    wire [15:0] divisor_eff;
    assign divisor_eff = sanitize_divisor(sample_rate_div);

    reg [15:0] divisor_active;

    // down_cnt 表示距离下一次输出还需要丢弃多少个有效输入样本。
    // down_cnt = 0 时，当前 sample_valid_in 会被输出；
    // 输出后，如果 div=N，则 down_cnt 装载 N-1。
    reg [15:0] down_cnt;

    wire reconfig_active;
    assign reconfig_active =
        cfg_update_pulse ||
        (divisor_active != divisor_eff);

    // ------------------------------------------------------------------------
    // main logic
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            divisor_active  <= 16'd1;
            down_cnt        <= 16'd0;

            sample_valid_out <= 1'b0;
            sample_data_out  <= {DATA_W{1'b0}};
            trigger_data_out <= {DATA_W{1'b0}};
        end else begin
            // 默认输出无效，只在抽取命中时拉高 1 拍
            sample_valid_out <= 1'b0;

            if (!enable) begin
                divisor_active <= divisor_eff;
                down_cnt       <= 16'd0;
            end else if (reconfig_active) begin
                divisor_active <= divisor_eff;
                down_cnt       <= 16'd0;
            end else if (sample_valid_in) begin
                if (divisor_active <= 16'd1) begin
                    // div = 1，输入每个有效样本都输出
                    sample_valid_out <= 1'b1;
                    sample_data_out  <= sample_data_in;
                    trigger_data_out <= trigger_data_in;
                    down_cnt         <= 16'd0;
                end else if (down_cnt == 16'd0) begin
                    // 当前样本命中抽取相位，输出并重新装载计数器
                    sample_valid_out <= 1'b1;
                    sample_data_out  <= sample_data_in;
                    trigger_data_out <= trigger_data_in;
                    down_cnt         <= divisor_active - 16'd1;
                end else begin
                    // 当前有效样本被丢弃
                    down_cnt <= down_cnt - 16'd1;
                end
            end
        end
    end

    `ifdef DEBUG_ILA_DATA_DOWNSAMPLE
    ILA_DATA_DOWNSAMPLE ILA_DATA_DOWNSAMPLE_inst1 (
    .clk                                (clk                       ),

    .probe0                             (enable                    ),
    .probe1                             (cfg_update_pulse          ),
    .probe2                             (sample_rate_div           ),
    .probe3                             (sample_valid_in           ),
    .probe4                             (sample_data_in            ),
    .probe5                             (trigger_data_in           ),
    .probe6                             (sample_valid_out          ),
    .probe7                             (sample_data_out           ),
    .probe8                             (trigger_data_out          ) 
    );
    `endif

endmodule