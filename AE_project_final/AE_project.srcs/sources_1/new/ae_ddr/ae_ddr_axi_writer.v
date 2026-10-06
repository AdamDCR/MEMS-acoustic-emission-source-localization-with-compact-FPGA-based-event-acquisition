`timescale 1ns / 1ps

module ae_ddr_axi_writer #(
    parameter integer FRAME_SAMPLES    = 8192,
    parameter integer PRE_SAMPLES      = 4096,
    parameter integer POST_SAMPLES     = 4096,
    parameter integer HEADER_WORDS     = 4,
    parameter integer AXI_ADDR_W       = 30,
    parameter integer AXI_DATA_W       = 256,
    parameter integer DESC_COUNT       = 1024,
    parameter [AXI_ADDR_W-1:0] EVENT_BASE_ADDR  = 30'h0000_0000,
    parameter integer EVENT_SLOT_BYTES = 69632
)(
    input                                   ui_clk,
    input                                   ui_rst_n,
    input                                   init_calib_complete,

    // ------------------------------------------------------------------------
    // 元信息 FIFO：每帧 1 条
    // ------------------------------------------------------------------------
    input                                   meta_fifo_empty,
    output wire                             meta_fifo_rd_en,
    input               [255:0]             meta_fifo_dout,

    // ------------------------------------------------------------------------
    // 数据 FIFO：payload 连续数据
    // ------------------------------------------------------------------------
    input                                   data_fifo_empty,
    output wire                             data_fifo_rd_en,
    input               [255:0]             data_fifo_dout,

    // ------------------------------------------------------------------------
    // 描述符表写接口
    // ------------------------------------------------------------------------
    output reg                              desc_wr_en,
    output reg          [$clog2(DESC_COUNT)-1:0] desc_wr_idx,
    output reg          [255:0]             desc_wr_data,

    // ------------------------------------------------------------------------
    // AXI 写地址通道
    // ------------------------------------------------------------------------
    output wire         [3:0]               s_axi_awid,
    output wire         [29:0]              s_axi_awaddr,
    output wire         [7:0]               s_axi_awlen,
    output wire         [2:0]               s_axi_awsize,
    output wire         [1:0]               s_axi_awburst,
    output wire         [0:0]               s_axi_awlock,
    output wire         [3:0]               s_axi_awcache,
    output wire         [2:0]               s_axi_awprot,
    output wire         [3:0]               s_axi_awqos,
    output wire                             s_axi_awvalid,
    input                                   s_axi_awready,

    // ------------------------------------------------------------------------
    // AXI 写数据通道
    // ------------------------------------------------------------------------
    output wire         [255:0]             s_axi_wdata,
    output wire         [31:0]              s_axi_wstrb,
    output wire                             s_axi_wlast,
    output wire                             s_axi_wvalid,
    input                                   s_axi_wready,

    // ------------------------------------------------------------------------
    // AXI 写响应通道
    // ------------------------------------------------------------------------
    input               [3:0]               s_axi_bid,
    input               [1:0]               s_axi_bresp,
    input                                   s_axi_bvalid,
    output wire                             s_axi_bready
);

    localparam integer AXI_BYTES_PER_BEAT = AXI_DATA_W / 8;
    localparam integer FRAME_WORDS        = FRAME_SAMPLES + HEADER_WORDS;
    localparam integer MAX_BURST_BEATS    = 128;
    localparam integer SLOT_IDX_W         = $clog2(DESC_COUNT);
    localparam [AXI_ADDR_W-1:0] EVENT_SLOT_BYTES_AW = EVENT_SLOT_BYTES[AXI_ADDR_W-1:0];

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_META_POP = 3'd1;
    localparam [2:0] ST_AW_REQ   = 3'd2;
    localparam [2:0] ST_WDATA    = 3'd3;
    localparam [2:0] ST_BRESP    = 3'd4;
    localparam [2:0] ST_DESC_WR  = 3'd5;

    reg [2:0]                           state_cur;
    reg [2:0]                           state_nxt;

    reg [255:0]                         meta_info_latched;
    reg [31:0]                          words_remaining;
    reg [31:0]                          burst_words_total;
    reg [31:0]                          burst_words_sent;
    reg [31:0]                          header_word_idx;
    reg [31:0]                          payload_word_idx;
    reg [AXI_ADDR_W-1:0]                frame_base_addr;
    reg [AXI_ADDR_W-1:0]                cur_addr;
    reg [31:0]                          wr_slot_idx;

    wire [31:0]                         meta_event_seq;
    wire [15:0]                         meta_threshold;
    wire [15:0]                         meta_ch_mask;
    wire [31:0]                         meta_trigger_sample_index;
    wire [31:0]                         meta_payload_words;
    wire [95:0]                         meta_time_info;

    wire [255:0]                        hdr0;
    wire [255:0]                        hdr1;
    wire [255:0]                        hdr2;
    wire [255:0]                        hdr3;

    wire [255:0]                        header_word_sel;
    wire                                sending_header;
    wire                                sending_payload;
    wire [255:0]                        tx_word_data;
    wire                                tx_word_valid;
    wire                                w_handshake;
    wire                                burst_last_beat;
    wire [31:0]                         next_burst_words;
    wire [31:0]                         axi_awlen_words_minus1;

    assign meta_event_seq            = meta_info_latched[255:224];
    assign meta_threshold            = meta_info_latched[223:208];
    assign meta_ch_mask              = meta_info_latched[207:192];
    assign meta_trigger_sample_index = meta_info_latched[191:160];
    assign meta_payload_words        = meta_info_latched[159:128];
    assign meta_time_info            = meta_info_latched[127:32];

    ae_event_header_gen #(
    .HEADER_WORDS                       (HEADER_WORDS              ),
    .FRAME_SAMPLES                      (FRAME_SAMPLES             ),
    .PRE_SAMPLES                        (PRE_SAMPLES               ),
    .POST_SAMPLES                       (POST_SAMPLES              ) 
    ) u_ae_event_header_gen (
    .meta_info                          (meta_info_latched         ),
    .ddr_base_addr                      (frame_base_addr           ),
    .slot_index                         (wr_slot_idx               ),
    .slot_bytes                         (EVENT_SLOT_BYTES[31:0]    ),
    .hdr0                               (hdr0                      ),
    .hdr1                               (hdr1                      ),
    .hdr2                               (hdr2                      ),
    .hdr3                               (hdr3                      ) 
    );

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
    assign axi_awlen_words_minus1 = next_burst_words - 32'd1;

    assign sending_header = (header_word_idx < HEADER_WORDS);
    assign sending_payload = !sending_header;

    assign header_word_sel = (header_word_idx == 0) ? hdr0 :
                             (header_word_idx == 1) ? hdr1 :
                             (header_word_idx == 2) ? hdr2 :
                                                      hdr3;

    assign tx_word_data  = sending_header ? header_word_sel : data_fifo_dout;
    assign tx_word_valid = (state_cur == ST_WDATA) &&
                           (sending_header || !data_fifo_empty);

    assign burst_last_beat = (burst_words_sent == burst_words_total - 1'b1);
    assign w_handshake     = tx_word_valid && s_axi_wready;

    assign meta_fifo_rd_en = (state_cur == ST_META_POP);
    assign data_fifo_rd_en = w_handshake && sending_payload;

    assign s_axi_awid      = 4'd0;
    assign s_axi_awaddr    = cur_addr;
    assign s_axi_awlen     = axi_awlen_words_minus1[7:0];
    assign s_axi_awsize    = 3'b101;   // 32 Byte / beat
    assign s_axi_awburst   = 2'b01;    // INCR
    assign s_axi_awlock    = 1'b0;
    assign s_axi_awcache   = 4'b0011;
    assign s_axi_awprot    = 3'b000;
    assign s_axi_awqos     = 4'd0;
    assign s_axi_awvalid   = (state_cur == ST_AW_REQ);

    assign s_axi_wdata     = tx_word_data;
    assign s_axi_wstrb     = 32'hFFFF_FFFF;
    assign s_axi_wlast     = tx_word_valid && burst_last_beat;
    assign s_axi_wvalid    = tx_word_valid;

    assign s_axi_bready    = (state_cur == ST_BRESP);

    // ------------------------------------------------------------------------
    // 第一段：状态寄存器
    // ------------------------------------------------------------------------
    always @(posedge ui_clk) begin
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
                if (init_calib_complete && !meta_fifo_empty) begin
                    state_nxt = ST_META_POP;
                end
            end

            ST_META_POP: begin
                state_nxt = ST_AW_REQ;
            end

            ST_AW_REQ: begin
                if (s_axi_awready) begin
                    state_nxt = ST_WDATA;
                end
            end

            ST_WDATA: begin
                if (w_handshake && burst_last_beat) begin
                    state_nxt = ST_BRESP;
                end
            end

            ST_BRESP: begin
                if (s_axi_bvalid) begin
                    if (words_remaining == 0) begin
                        state_nxt = ST_DESC_WR;
                    end else begin
                        state_nxt = ST_AW_REQ;
                    end
                end
            end

            ST_DESC_WR: begin
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
    always @(posedge ui_clk) begin
        if (!ui_rst_n) begin
            desc_wr_en        <= 1'b0;
            desc_wr_idx       <= {SLOT_IDX_W{1'b0}};
            desc_wr_data      <= 256'd0;

            meta_info_latched <= 256'd0;
            words_remaining   <= 32'd0;
            burst_words_total <= 32'd0;
            burst_words_sent  <= 32'd0;
            header_word_idx   <= 32'd0;
            payload_word_idx  <= 32'd0;
            frame_base_addr   <= {AXI_ADDR_W{1'b0}};
            cur_addr          <= {AXI_ADDR_W{1'b0}};
            wr_slot_idx       <= 32'd0;
        end else begin
            desc_wr_en <= 1'b0;

            case (state_cur)
                ST_IDLE: begin
                    burst_words_sent <= 32'd0;
                end

                ST_META_POP: begin
                    meta_info_latched <= meta_fifo_dout;
                    frame_base_addr   <= EVENT_BASE_ADDR + (wr_slot_idx * EVENT_SLOT_BYTES_AW);
                    cur_addr          <= EVENT_BASE_ADDR + (wr_slot_idx * EVENT_SLOT_BYTES_AW);
                    words_remaining   <= HEADER_WORDS + meta_fifo_dout[159:128];
                    burst_words_total <= HEADER_WORDS + meta_fifo_dout[159:128];
                    header_word_idx   <= 32'd0;
                    payload_word_idx  <= 32'd0;
                end

                ST_AW_REQ: begin
                    burst_words_total <= next_burst_words;
                    burst_words_sent  <= 32'd0;
                end

                ST_WDATA: begin
                    if (w_handshake) begin
                        burst_words_sent <= burst_words_sent + 1'b1;
                        words_remaining  <= words_remaining - 1'b1;
                        cur_addr         <= cur_addr + AXI_BYTES_PER_BEAT;

                        if (sending_header) begin
                            header_word_idx <= header_word_idx + 1'b1;
                        end else begin
                            payload_word_idx <= payload_word_idx + 1'b1;
                        end
                    end
                end

                ST_BRESP: begin
                end

                ST_DESC_WR: begin
                    desc_wr_en   <= 1'b1;
                    desc_wr_idx  <= wr_slot_idx[SLOT_IDX_W-1:0];
                    desc_wr_data <= {
                        1'b1,
                        meta_event_seq,
                        frame_base_addr,
                        (HEADER_WORDS + meta_payload_words),
                        meta_threshold,
                        meta_ch_mask,
                        meta_trigger_sample_index,
                        meta_time_info,
                        1'b0
                    };

                    if (wr_slot_idx == DESC_COUNT - 1) begin
                        wr_slot_idx <= 32'd0;
                    end else begin
                        wr_slot_idx <= wr_slot_idx + 1'b1;
                    end
                end

                default: begin
                end
            endcase
        end
    end

endmodule
