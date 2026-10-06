module adc_filter_8ch #(
    parameter integer INPUT_IS_OFFSET_BINARY = 0,
    parameter integer FIR_OUT_SHIFT          = 16
)(
    input                               clk,
    input                               reset_n,
    input                               data_vld,
    input      [13:0]                   data0,
    input      [13:0]                   data1,
    input      [13:0]                   data2,
    input      [13:0]                   data3,
    input      [13:0]                   data4,
    input      [13:0]                   data5,
    input      [13:0]                   data6,
    input      [13:0]                   data7,

    output                              filter_vld,
    output     signed [15:0]            filter_data0,
    output     signed [15:0]            filter_data1,
    output     signed [15:0]            filter_data2,
    output     signed [15:0]            filter_data3,
    output     signed [15:0]            filter_data4,
    output     signed [15:0]            filter_data5,
    output     signed [15:0]            filter_data6,
    output     signed [15:0]            filter_data7,
    output                              filter_backpressure
);

    wire [8*14-1:0]                     data_pack;
    wire [8*16-1:0]                     filter_pack;
    wire [7:0]                          valid_vec;
    wire [7:0]                          backpressure_vec;

    assign data_pack = {
        data7, data6, data5, data4,
        data3, data2, data1, data0
    };

    genvar ch;
    generate
        for (ch = 0; ch < 8; ch = ch + 1) begin : g_filter_ch
            adc_filter_channel #(
                .INPUT_IS_OFFSET_BINARY (INPUT_IS_OFFSET_BINARY),
                .FIR_OUT_SHIFT          (FIR_OUT_SHIFT)
            ) u_adc_filter_channel (
                .clk                    (clk),
                .reset_n                (reset_n),
                .sample_valid           (data_vld),
                .sample_in              (data_pack[ch*14 +: 14]),
                .sample_out_valid       (valid_vec[ch]),
                .sample_out             (filter_pack[ch*16 +: 16]),
                .filter_backpressure    (backpressure_vec[ch])
            );
        end
    endgenerate

    // All eight channels receive the same valid and identical FIR IP latency.
    // They should assert output valid together. AND avoids downstream partial
    // 8-channel groups if any IP instance behaves unexpectedly.
    assign filter_vld          = &valid_vec;
    assign filter_backpressure = |backpressure_vec;

    assign filter_data0 = filter_pack[0*16 +: 16];
    assign filter_data1 = filter_pack[1*16 +: 16];
    assign filter_data2 = filter_pack[2*16 +: 16];
    assign filter_data3 = filter_pack[3*16 +: 16];
    assign filter_data4 = filter_pack[4*16 +: 16];
    assign filter_data5 = filter_pack[5*16 +: 16];
    assign filter_data6 = filter_pack[6*16 +: 16];
    assign filter_data7 = filter_pack[7*16 +: 16];

endmodule
