`timescale 1ns / 1ps

module ae_event_desc_table #(
    parameter integer DESC_COUNT = 1024
)(
    input                                   clk,
    input                                   reset_n,

    input                                   wr_en,
    input               [$clog2(DESC_COUNT)-1:0] wr_idx,
    input               [255:0]             wr_data,

    input                                   query_en,
    input               [31:0]              query_event_seq,
    output reg                              query_done,
    output reg                              query_found,
    output reg          [255:0]             query_desc
);

    localparam integer DESC_IDX_W = $clog2(DESC_COUNT);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_PRIME = 2'd1;
    localparam [1:0] ST_SCAN  = 2'd2;
    localparam [1:0] ST_DONE  = 2'd3;

    reg [1:0]                               state_cur;
    reg [1:0]                               state_nxt;

    reg [DESC_IDX_W-1:0]                    issue_idx;
    reg [DESC_IDX_W-1:0]                    scan_idx_d;
    reg [31:0]                              query_event_seq_latched;
    reg                                     scan_valid_d;
    reg                                     scan_last_d;
    reg [255:0]                             desc_rd_data;
    reg [DESC_COUNT-1:0]                    desc_valid_map;

    (* ram_style = "block" *)
    reg [255:0]                             desc_mem [0:DESC_COUNT-1];

    wire                                    desc_valid_hit;
    wire                                    desc_seq_hit;
    wire                                    scan_last_issue;

    integer                                 i;

    assign desc_valid_hit  = scan_valid_d && desc_valid_map[scan_idx_d];
    assign desc_seq_hit    = (desc_rd_data[254:223] == query_event_seq_latched);
    assign scan_last_issue = (issue_idx == DESC_COUNT - 1);

    // State register
    always @(posedge clk) begin
        if (!reset_n) begin
            state_cur <= ST_IDLE;
        end else begin
            state_cur <= state_nxt;
        end
    end

    // Next-state logic
    always @(*) begin
        state_nxt = state_cur;
        case (state_cur)
            ST_IDLE: begin
                if (query_en) begin
                    state_nxt = ST_PRIME;
                end
            end

            ST_PRIME: begin
                state_nxt = ST_SCAN;
            end

            ST_SCAN: begin
                if (desc_valid_hit && desc_seq_hit) begin
                    state_nxt = ST_DONE;
                end else if (scan_valid_d && scan_last_d) begin
                    state_nxt = ST_DONE;
                end else begin
                    state_nxt = ST_SCAN;
                end
            end

            ST_DONE: begin
                state_nxt = ST_IDLE;
            end

            default: begin
                state_nxt = ST_IDLE;
            end
        endcase
    end

    // BRAM-friendly data path:
    // - descriptor data is stored in block RAM
    // - valid bits are kept in a small resettable bitmap
    // - query scans one entry per cycle with synchronous RAM read latency
    always @(posedge clk) begin
        if (!reset_n) begin
            issue_idx               <= {DESC_IDX_W{1'b0}};
            scan_idx_d              <= {DESC_IDX_W{1'b0}};
            query_event_seq_latched <= 32'd0;
            query_done              <= 1'b0;
            query_found             <= 1'b0;
            query_desc              <= 256'd0;
            scan_valid_d            <= 1'b0;
            scan_last_d             <= 1'b0;
            desc_rd_data            <= 256'd0;

            for (i = 0; i < DESC_COUNT; i = i + 1) begin
                desc_valid_map[i] <= 1'b0;
            end
        end else begin
            query_done <= 1'b0;

            if (wr_en) begin
                desc_mem[wr_idx] <= wr_data;
                desc_valid_map[wr_idx] <= wr_data[255];
            end

            case (state_cur)
                ST_IDLE: begin
                    scan_valid_d <= 1'b0;
                    scan_last_d  <= 1'b0;
                    if (query_en) begin
                        issue_idx               <= {DESC_IDX_W{1'b0}};
                        query_event_seq_latched <= query_event_seq;
                        query_found             <= 1'b0;
                        query_desc              <= 256'd0;
                    end
                end

                ST_PRIME: begin
                    desc_rd_data <= desc_mem[issue_idx];
                    scan_idx_d   <= issue_idx;
                    scan_valid_d <= 1'b1;
                    scan_last_d  <= scan_last_issue;
                    if (!scan_last_issue) begin
                        issue_idx <= issue_idx + 1'b1;
                    end
                end

                ST_SCAN: begin
                    if (desc_valid_hit && desc_seq_hit) begin
                        query_found  <= 1'b1;
                        query_desc   <= desc_rd_data;
                        scan_valid_d <= 1'b0;
                        scan_last_d  <= 1'b0;
                    end else if (scan_valid_d && scan_last_d) begin
                        scan_valid_d <= 1'b0;
                        scan_last_d  <= 1'b0;
                    end else begin
                        desc_rd_data <= desc_mem[issue_idx];
                        scan_idx_d   <= issue_idx;
                        scan_valid_d <= 1'b1;
                        scan_last_d  <= scan_last_issue;
                        if (!scan_last_issue) begin
                            issue_idx <= issue_idx + 1'b1;
                        end
                    end
                end

                ST_DONE: begin
                    query_done  <= 1'b1;
                    scan_valid_d <= 1'b0;
                    scan_last_d  <= 1'b0;
                end

                default: begin
                end
            endcase
        end
    end

endmodule
