// ============================================================================
// sys_clk UDP config latch + adc_clk update
// ============================================================================
module ae_udp_cfg_sync #(
    parameter integer MAX_CH   = 16,
    parameter integer SAMPLE_W = 16
)(
    input                       sys_clk,
    input                       adc_clk,
    input                       reset_n,

    input                       ctrl_cfg_valid_pulse,
    input      [15:0]           sample_rate,
    input      [MAX_CH-1:0]     channel_en,
    input      [SAMPLE_W-1:0]   ctrl_ae_threshold,

    output reg [15:0]           sample_rate_adc,
    output reg [MAX_CH-1:0]     channel_en_adc,
    output reg [SAMPLE_W-1:0]   ae_threshold_adc,
    output wire                 cfg_update_adc_pulse
);

    reg [15:0]                  sample_rate_div_sys;
    reg [MAX_CH-1:0]            channel_en_sys;
    reg [SAMPLE_W-1:0]          trig_threshold_sys;
    reg                         cfg_toggle_sys;

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_rate_div_sys <= 16'd1;
            channel_en_sys      <= {MAX_CH{1'b1}};
            trig_threshold_sys  <= 16'd4000;
            cfg_toggle_sys      <= 1'b0;
        end
        else if (ctrl_cfg_valid_pulse) begin
            sample_rate_div_sys <= (sample_rate == 16'd0) ? 16'd1 : sample_rate;
            channel_en_sys      <= channel_en;
            trig_threshold_sys  <= ctrl_ae_threshold;
            cfg_toggle_sys      <= ~cfg_toggle_sys;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [2:0] cfg_toggle_adc_sync;
    reg                                cfg_toggle_adc_d;

    always @(posedge adc_clk or negedge reset_n) begin
        if (!reset_n) begin
            cfg_toggle_adc_sync <= 3'b000;
            cfg_toggle_adc_d    <= 1'b0;
        end
        else begin
            cfg_toggle_adc_sync <= {cfg_toggle_adc_sync[1:0], cfg_toggle_sys};
            cfg_toggle_adc_d    <= cfg_toggle_adc_sync[2];
        end
    end

    assign cfg_update_adc_pulse = cfg_toggle_adc_sync[2] ^ cfg_toggle_adc_d;

    always @(posedge adc_clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_rate_adc     <= 16'd1;
            channel_en_adc      <= {MAX_CH{1'b1}};
            ae_threshold_adc    <= 16'd4000;
        end
        else if (cfg_update_adc_pulse) begin
            // Multi-bit buses are held stable in sys_clk domain until the next
            // ctrl_cfg_valid_pulse. The toggle provides an update strobe.
            sample_rate_adc     <= sample_rate_div_sys;
            channel_en_adc      <= channel_en_sys;
            ae_threshold_adc    <= trig_threshold_sys;
        end
    end

endmodule
