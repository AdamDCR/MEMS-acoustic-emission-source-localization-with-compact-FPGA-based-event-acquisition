module adc_filter_fir_500k_lp_wrap #(
    parameter integer FIR_OUT_SHIFT = 16
)(
    input                               clk,
    input                               reset_n,
    input                               sample_valid,
    input      signed [15:0]            sample_in,

    output                              sample_out_valid,
    output     signed [15:0]            sample_out,
    output reg                          filter_backpressure
);

    wire                                s_axis_data_tready;
    wire                                m_axis_data_tvalid;
    wire        [31:0]                  m_axis_data_tdata;

    fir_500k_lp u_fir_500k_lp (
        .aresetn                        (reset_n),
        .aclk                           (clk),
        .aclken                         (1'b1),
        .s_axis_data_tvalid             (sample_valid),
        .s_axis_data_tready             (s_axis_data_tready),
        .s_axis_data_tdata              (sample_in),
        .m_axis_data_tvalid             (m_axis_data_tvalid),
        .m_axis_data_tdata              (m_axis_data_tdata)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            filter_backpressure <= 1'b0;
        else if (sample_valid && !s_axis_data_tready)
            filter_backpressure <= 1'b1;
    end

    wire signed [31:0]                  fir_out_s32;
    wire signed [31:0]                  fir_out_scaled;

    assign fir_out_s32    = m_axis_data_tdata;
    assign fir_out_scaled = fir_out_s32 >>> FIR_OUT_SHIFT;

    assign sample_out_valid = m_axis_data_tvalid;
    assign sample_out       = sat32_to_s16(fir_out_scaled);

    function signed [15:0] sat32_to_s16;
        input signed [31:0] din;
        begin
            if (din > 32'sd32767)
                sat32_to_s16 = 16'sh7FFF;
            else if (din < -32'sd32768)
                sat32_to_s16 = 16'sh8000;
            else
                sat32_to_s16 = din[15:0];
        end
    endfunction

endmodule
