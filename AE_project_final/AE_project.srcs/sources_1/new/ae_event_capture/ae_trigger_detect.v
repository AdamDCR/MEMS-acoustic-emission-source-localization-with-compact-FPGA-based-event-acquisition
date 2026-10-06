
// ============================================================================
// Trigger detector
// ============================================================================
module ae_trigger_detect #(
    parameter integer MAX_CH   = 16,
    parameter integer SAMPLE_W = 16
)(
    input      [MAX_CH*SAMPLE_W-1:0]  sample_data,
    input      [MAX_CH-1:0]           active_ch_mask,
    input      [MAX_CH-1:0]           trig_mask,
    input      [SAMPLE_W-1:0]         trig_threshold,
    output reg                        trigger_hit
);

    integer k;

    function [SAMPLE_W-1:0] abs_tc;
        input [SAMPLE_W-1:0] din;
        begin
            if (din[SAMPLE_W-1])
                abs_tc = ~din + 1'b1;
            else
                abs_tc = din;
        end
    endfunction

    always @(*) begin
        trigger_hit = 1'b0;

        for (k = 0; k < MAX_CH; k = k + 1) begin
            if (active_ch_mask[k] &&
                trig_mask[k] &&
                (abs_tc(sample_data[k*SAMPLE_W +: SAMPLE_W]) >= trig_threshold)) begin
                trigger_hit = 1'b1;
            end
        end
    end

endmodule