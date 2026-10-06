`timescale 1ns / 1ps

(* use_dsp = "no" *)
module hp_iir_shift_1ch #(
    parameter integer SAMPLE_W   = 16,
    parameter integer STATE_W    = 40,
    parameter integer STATE_FRAC = 16,
    parameter integer K          = 10
)(
    input  wire                         clk,
    input  wire                         reset_n,
    input  wire                         in_valid,
    input  wire signed [SAMPLE_W-1:0]   x_in,
    output reg                          out_valid,
    output reg  signed [SAMPLE_W-1:0]   y_out
);

    localparam integer EXT_W = STATE_W - SAMPLE_W - STATE_FRAC;

    reg signed [SAMPLE_W-1:0] x_z1;
    reg signed [STATE_W-1:0]  y_z1;

    wire signed [STATE_W-1:0] x_ext;
    wire signed [STATE_W-1:0] x_z1_ext;
    wire signed [STATE_W-1:0] diff;
    wire signed [STATE_W-1:0] leak;
    wire signed [STATE_W-1:0] y_next;

    assign x_ext = $signed({
        {EXT_W{x_in[SAMPLE_W-1]}},
        x_in,
        {STATE_FRAC{1'b0}}
    });

    assign x_z1_ext = $signed({
        {EXT_W{x_z1[SAMPLE_W-1]}},
        x_z1,
        {STATE_FRAC{1'b0}}
    });

    assign diff   = x_ext - x_z1_ext;
    assign leak   = y_z1 >>> K;
    assign y_next = diff + y_z1 - leak;

    function signed [SAMPLE_W-1:0] sat_state_to_sample;
        input signed [STATE_W-1:0] din;
        reg signed [STATE_W-1:0] shifted;
        begin
            shifted = din >>> STATE_FRAC;

            if (shifted > $signed({1'b0, {(SAMPLE_W-1){1'b1}}}))
                sat_state_to_sample = {1'b0, {(SAMPLE_W-1){1'b1}}};
            else if (shifted < $signed({1'b1, {(SAMPLE_W-1){1'b0}}}))
                sat_state_to_sample = {1'b1, {(SAMPLE_W-1){1'b0}}};
            else
                sat_state_to_sample = shifted[SAMPLE_W-1:0];
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            x_z1      <= {SAMPLE_W{1'b0}};
            y_z1      <= {STATE_W{1'b0}};
            y_out     <= {SAMPLE_W{1'b0}};
            out_valid <= 1'b0;
        end else begin
            out_valid <= 1'b0;

            if (in_valid) begin
                x_z1      <= x_in;
                y_z1      <= y_next;
                y_out     <= sat_state_to_sample(y_next);
                out_valid <= 1'b1;
            end
        end
    end

endmodule