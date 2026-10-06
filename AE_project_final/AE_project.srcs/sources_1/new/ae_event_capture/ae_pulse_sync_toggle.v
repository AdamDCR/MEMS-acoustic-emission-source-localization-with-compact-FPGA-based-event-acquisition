
module ae_pulse_sync_toggle (
    input  src_clk,
    input  dst_clk,
    input  reset_n,
    input  src_pulse,
    output dst_pulse
);

    reg src_pulse_d;
    reg src_toggle;

    always @(posedge src_clk or negedge reset_n) begin
        if (!reset_n) begin
            src_pulse_d <= 1'b0;
            src_toggle  <= 1'b0;
        end
        else begin
            src_pulse_d <= src_pulse;
            if (src_pulse && !src_pulse_d)
                src_toggle <= ~src_toggle;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [2:0] dst_sync;
    reg dst_sync_d;

    always @(posedge dst_clk or negedge reset_n) begin
        if (!reset_n) begin
            dst_sync   <= 3'b000;
            dst_sync_d <= 1'b0;
        end
        else begin
            dst_sync   <= {dst_sync[1:0], src_toggle};
            dst_sync_d <= dst_sync[2];
        end
    end

    assign dst_pulse = dst_sync[2] ^ dst_sync_d;

endmodule