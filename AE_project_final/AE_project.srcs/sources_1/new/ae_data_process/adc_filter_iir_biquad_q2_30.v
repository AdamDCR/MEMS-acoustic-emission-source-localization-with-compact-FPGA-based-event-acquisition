`timescale 1ns / 1ps

module adc_filter_iir_biquad_q2_30 #(
    parameter signed [31:0] B0  = 32'sh40000000,
    parameter signed [31:0] B1  = 32'sh00000000,
    parameter signed [31:0] B2  = 32'sh00000000,
    parameter signed [31:0] FB1 = 32'sh00000000,
    parameter signed [31:0] FB2 = 32'sh00000000,
    parameter integer       STATE_FRAC = 18
)(
    input                               clk,
    input                               reset_n,
    input                               sample_valid,
    input      signed [31:0]            sample_in,

    output reg                          sample_out_valid,
    output reg signed [31:0]            sample_out
);

    localparam integer DATA_W    = 32;
    localparam integer COEF_W    = 32;
    localparam integer COEF_FRAC = 30;
    localparam integer STATE_GUARD = 8;
    localparam integer STATE_W   = DATA_W + STATE_FRAC + STATE_GUARD;
    localparam integer ACC_W     = STATE_W + COEF_W + 4;

    localparam signed [ACC_W-1:0] S32_MAX_EXT =
        {{(ACC_W-32){1'b0}}, 32'h7FFF_FFFF};
    localparam signed [ACC_W-1:0] S32_MIN_EXT =
        {{(ACC_W-32){1'b1}}, 32'h8000_0000};
    localparam signed [ACC_W-1:0] SSTATE_MAX_EXT =
        {{(ACC_W-STATE_W){1'b0}}, 1'b0, {(STATE_W-1){1'b1}}};
    localparam signed [ACC_W-1:0] SSTATE_MIN_EXT =
        {{(ACC_W-STATE_W){1'b1}}, 1'b1, {(STATE_W-1){1'b0}}};

    reg signed [STATE_W-1:0]             x1;
    reg signed [STATE_W-1:0]             x2;
    reg signed [STATE_W-1:0]             y1;
    reg signed [STATE_W-1:0]             y2;

    wire signed [STATE_W-1:0]            x0;
    wire signed [ACC_W-1:0]              x0_ext;
    wire signed [ACC_W-1:0]              x1_ext;
    wire signed [ACC_W-1:0]              x2_ext;
    wire signed [ACC_W-1:0]              y1_ext;
    wire signed [ACC_W-1:0]              y2_ext;
    wire signed [ACC_W-1:0]              b0_ext;
    wire signed [ACC_W-1:0]              b1_ext;
    wire signed [ACC_W-1:0]              b2_ext;
    wire signed [ACC_W-1:0]              fb1_ext;
    wire signed [ACC_W-1:0]              fb2_ext;
    wire signed [ACC_W-1:0]              p_b0;
    wire signed [ACC_W-1:0]              p_b1;
    wire signed [ACC_W-1:0]              p_b2;
    wire signed [ACC_W-1:0]              p_a1;
    wire signed [ACC_W-1:0]              p_a2;
    wire signed [ACC_W-1:0]              acc;
    wire signed [ACC_W-1:0]              acc_scaled;
    wire signed [STATE_W-1:0]            y_next;

    assign x0         = $signed({{(STATE_W-DATA_W){sample_in[DATA_W-1]}}, sample_in}) <<< STATE_FRAC;
    assign x0_ext     = {{(ACC_W-STATE_W){x0[STATE_W-1]}}, x0};
    assign x1_ext     = {{(ACC_W-STATE_W){x1[STATE_W-1]}}, x1};
    assign x2_ext     = {{(ACC_W-STATE_W){x2[STATE_W-1]}}, x2};
    assign y1_ext     = {{(ACC_W-STATE_W){y1[STATE_W-1]}}, y1};
    assign y2_ext     = {{(ACC_W-STATE_W){y2[STATE_W-1]}}, y2};
    assign b0_ext     = {{(ACC_W-COEF_W){B0[COEF_W-1]}}, B0};
    assign b1_ext     = {{(ACC_W-COEF_W){B1[COEF_W-1]}}, B1};
    assign b2_ext     = {{(ACC_W-COEF_W){B2[COEF_W-1]}}, B2};
    assign fb1_ext    = {{(ACC_W-COEF_W){FB1[COEF_W-1]}}, FB1};
    assign fb2_ext    = {{(ACC_W-COEF_W){FB2[COEF_W-1]}}, FB2};

    assign p_b0       = x0_ext  * b0_ext;
    assign p_b1       = x1_ext  * b1_ext;
    assign p_b2       = x2_ext  * b2_ext;
    assign p_a1       = y1_ext  * fb1_ext;
    assign p_a2       = y2_ext  * fb2_ext;

    assign acc        = p_b0 + p_b1 + p_b2 + p_a1 + p_a2;
    assign acc_scaled = acc >>> COEF_FRAC;
    assign y_next     = sat_acc_to_state(acc_scaled);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            x1               <= {STATE_W{1'b0}};
            x2               <= {STATE_W{1'b0}};
            y1               <= {STATE_W{1'b0}};
            y2               <= {STATE_W{1'b0}};
            sample_out       <= 32'sd0;
            sample_out_valid <= 1'b0;
        end
        else begin
            sample_out_valid <= 1'b0;

            if (sample_valid) begin
                x2               <= x1;
                x1               <= x0;
                y2               <= y1;
                y1               <= y_next;
                sample_out       <= sat_state_to_s32(y_next);
                sample_out_valid <= 1'b1;
            end
        end
    end

    function signed [STATE_W-1:0] sat_acc_to_state;
        input signed [ACC_W-1:0] din;
        begin
            if (din > SSTATE_MAX_EXT)
                sat_acc_to_state = {1'b0, {(STATE_W-1){1'b1}}};
            else if (din < SSTATE_MIN_EXT)
                sat_acc_to_state = {1'b1, {(STATE_W-1){1'b0}}};
            else
                sat_acc_to_state = din[STATE_W-1:0];
        end
    endfunction

    function signed [DATA_W-1:0] sat_state_to_s32;
        input signed [STATE_W-1:0] din;
        reg signed [ACC_W-1:0] shifted;
        begin
            shifted = $signed({{(ACC_W-STATE_W){din[STATE_W-1]}}, din}) >>> STATE_FRAC;
            sat_state_to_s32 = sat_acc_to_s32(shifted);
        end
    endfunction

    function signed [DATA_W-1:0] sat_acc_to_s32;
        input signed [ACC_W-1:0] din;
        begin
            if (din > S32_MAX_EXT)
                sat_acc_to_s32 = 32'sh7FFF_FFFF;
            else if (din < S32_MIN_EXT)
                sat_acc_to_s32 = 32'sh8000_0000;
            else
                sat_acc_to_s32 = din[DATA_W-1:0];
        end
    endfunction

endmodule
