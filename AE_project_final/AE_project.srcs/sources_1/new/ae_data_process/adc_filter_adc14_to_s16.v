`timescale 1ns / 1ps

module adc_filter_adc14_to_s16 #(
    // 现在你的 AD9257 已经配置为 signed two's complement 输出，
    // 所以默认必须为 0。
    parameter integer INPUT_IS_OFFSET_BINARY = 0
)(
    input  wire        [13:0] din,
    output wire signed [15:0] dout
);

    wire signed [13:0] din_tc;

    assign din_tc =
        (INPUT_IS_OFFSET_BINARY != 0) ?
        $signed({~din[13], din[12:0]}) :
        $signed(din);

    assign dout = {{2{din_tc[13]}}, din_tc};

endmodule