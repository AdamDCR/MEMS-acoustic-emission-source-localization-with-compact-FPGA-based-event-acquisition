`timescale 1ns / 1ps

module ae_ddr_axi_reader #(
    parameter integer AXI_ADDR_W = 30
)(
    input                               ui_clk,
    input                               ui_rst_n,

    input                               rd_req,
    input               [31:0]          rd_event_seq,
    output reg                          rd_busy,
    output reg                          rd_found,

    // ------------------------------------------------------------------------
    // 描述符查询接口
    // ------------------------------------------------------------------------
    output wire                         query_en,
    output reg          [31:0]          query_event_seq,
    input                               query_done,
    input                               query_found,
    input               [255:0]         query_desc,

    // ------------------------------------------------------------------------
    // 读出流接口
    // ------------------------------------------------------------------------
    output reg                          rd_valid,
    input                               rd_ready,
    output reg                          rd_sop,
    output reg                          rd_eop,
    output reg          [255:0]         rd_data,

    // ------------------------------------------------------------------------
    // AXI 读地址通道
    // ------------------------------------------------------------------------
    output wire         [3:0]           s_axi_arid,
    output wire         [29:0]          s_axi_araddr,
    output wire         [7:0]           s_axi_arlen,
    output wire         [2:0]           s_axi_arsize,
    output wire         [1:0]           s_axi_arburst,
    output wire         [0:0]           s_axi_arlock,
    output wire         [3:0]           s_axi_arcache,
    output wire         [2:0]           s_axi_arprot,
    output wire         [3:0]           s_axi_arqos,
    output wire                         s_axi_arvalid,
    input                               s_axi_arready,

    // ------------------------------------------------------------------------
    // AXI 读数据通道
    // ------------------------------------------------------------------------
    input               [3:0]           s_axi_rid,
    input               [255:0]         s_axi_rdata,
    input               [1:0]           s_axi_rresp,
    input                               s_axi_rlast,
    input                               s_axi_rvalid,
    output wire                         s_axi_rready
);

    localparam integer MAX_BURST_BEATS = 128;
    localparam integer AXI_BYTES_PER_BEAT = 32;

    localparam [2:0] ST_IDLE       = 3'd0;
    localparam [2:0] ST_QUERY_REQ  = 3'd1;
    localparam [2:0] ST_QUERY_WAIT = 3'd2;
    localparam [2:0] ST_AR_REQ     = 3'd3;
    localparam [2:0] ST_RDATA      = 3'd4;
    localparam [2:0] ST_DONE       = 3'd5;

    reg [2:0]                           state_cur;
    reg [2:0]                           state_nxt;

    reg [255:0]                         query_desc_latched;
    reg [AXI_ADDR_W-1:0]                cur_addr;
    reg [31:0]                          words_remaining;
    reg [31:0]                          burst_words_total;
    reg [31:0]                          burst_words_rcvd;
    reg [31:0]                          total_words_sent;

    wire [31:0]                         next_burst_words;
    wire                                ar_handshake;
    wire                                r_accept;
    wire                                last_frame_word;
    wire                                last_burst_word;
    wire [31:0]                         axi_arlen_words_minus1;

    assign query_en         = (state_cur == ST_QUERY_REQ);

    assign s_axi_arid       = 4'd0;
    assign s_axi_araddr     = cur_addr;
    assign axi_arlen_words_minus1 = next_burst_words - 32'd1;
    assign s_axi_arlen      = axi_arlen_words_minus1[7:0];
    assign s_axi_arsize     = 3'b101;
    assign s_axi_arburst    = 2'b01;
    assign s_axi_arlock     = 1'b0;
    assign s_axi_arcache    = 4'b0011;
    assign s_axi_arprot     = 3'b000;
    assign s_axi_arqos      = 4'd0;
    assign s_axi_arvalid    = (state_cur == ST_AR_REQ);

    assign s_axi_rready     = (state_cur == ST_RDATA) && (!rd_valid || rd_ready);

    assign ar_handshake     = (state_cur == ST_AR_REQ) && s_axi_arready;
    assign r_accept         = (state_cur == ST_RDATA) && s_axi_rvalid && s_axi_rready;
    assign last_frame_word  = (words_remaining == 1);
    assign last_burst_word  = (burst_words_rcvd == burst_words_total - 1'b1);

    function [31:0] min3_32;
        input [31:0] a;
        input [31:0] b;
        input [31:0] c;
        begin
            min3_32 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
        end
    endfunction

    function [31:0] beats_to_4kb_boundary;
        input [AXI_ADDR_W-1:0] byte_addr;
        reg   [11:0]           offset_4kb;
        begin
            offset_4kb = byte_addr[11:0];
            beats_to_4kb_boundary = (32'd4096 - offset_4kb) >> 5;
        end
    endfunction

    assign next_burst_words = min3_32(words_remaining,
                                      MAX_BURST_BEATS,
                                      beats_to_4kb_boundary(cur_addr));

    // ------------------------------------------------------------------------
    // 第一段：状态寄存器
    // ------------------------------------------------------------------------
    always @(posedge ui_clk or negedge ui_rst_n) begin
        if (!ui_rst_n) begin
            state_cur <= ST_IDLE;
        end else begin
            state_cur <= state_nxt;
        end
    end

    // ------------------------------------------------------------------------
    // 第二段：状态转移
    // ------------------------------------------------------------------------
    always @(*) begin
        state_nxt = state_cur;
        case (state_cur)
            ST_IDLE: begin
                if (rd_req) begin
                    state_nxt = ST_QUERY_REQ;
                end
            end

            ST_QUERY_REQ: begin
                state_nxt = ST_QUERY_WAIT;
            end

            ST_QUERY_WAIT: begin
                if (query_done) begin
                    if (query_found) begin
                        state_nxt = ST_AR_REQ;
                    end else begin
                        state_nxt = ST_DONE;
                    end
                end
            end

            ST_AR_REQ: begin
                if (s_axi_arready) begin
                    state_nxt = ST_RDATA;
                end
            end

            ST_RDATA: begin
                if (r_accept && last_burst_word && s_axi_rlast) begin
                    if (last_frame_word) begin
                        state_nxt = ST_DONE;
                    end else begin
                        state_nxt = ST_AR_REQ;
                    end
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

    // ------------------------------------------------------------------------
    // 第三段：状态输出与数据通路
    // ------------------------------------------------------------------------
    always @(posedge ui_clk or negedge ui_rst_n) begin
        if (!ui_rst_n) begin
            rd_busy            <= 1'b0;
            rd_found           <= 1'b0;
            rd_valid           <= 1'b0;
            rd_sop             <= 1'b0;
            rd_eop             <= 1'b0;
            rd_data            <= 256'd0;

            query_event_seq    <= 32'd0;

            query_desc_latched <= 256'd0;
            cur_addr           <= {AXI_ADDR_W{1'b0}};
            words_remaining    <= 32'd0;
            burst_words_total  <= 32'd0;
            burst_words_rcvd   <= 32'd0;
            total_words_sent   <= 32'd0;
        end else begin
            // 下游已经消费时，默认清空当前输出拍
            if (rd_valid && rd_ready) begin
                rd_valid <= 1'b0;
                rd_sop   <= 1'b0;
                rd_eop   <= 1'b0;
            end

            case (state_cur)
                ST_IDLE: begin
                    rd_busy <= 1'b0;
                    if (rd_req) begin
                        rd_busy  <= 1'b1;
                        rd_found <= 1'b0;
                        query_event_seq <= rd_event_seq;
                    end
                end

                ST_QUERY_REQ: begin
                end

                ST_QUERY_WAIT: begin
                    if (query_done) begin
                        rd_found <= query_found;
                        if (query_found) begin
                            query_desc_latched <= query_desc;
                            cur_addr           <= query_desc[222:193];
                            words_remaining    <= query_desc[192:161];
                            total_words_sent   <= 32'd0;
                        end
                    end
                end

                ST_AR_REQ: begin
                    burst_words_total <= next_burst_words;
                    burst_words_rcvd  <= 32'd0;
                end

                ST_RDATA: begin
                    if (r_accept) begin
                        rd_valid <= 1'b1;
                        rd_data  <= s_axi_rdata;
                        rd_sop   <= (total_words_sent == 0);
                        rd_eop   <= last_frame_word;

                        total_words_sent  <= total_words_sent + 1'b1;
                        words_remaining   <= words_remaining - 1'b1;
                        burst_words_rcvd  <= burst_words_rcvd + 1'b1;
                        cur_addr          <= cur_addr + AXI_BYTES_PER_BEAT;
                    end
                end

                ST_DONE: begin
                    rd_busy <= 1'b0;
                end

                default: begin
                end
            endcase
        end
    end

endmodule
