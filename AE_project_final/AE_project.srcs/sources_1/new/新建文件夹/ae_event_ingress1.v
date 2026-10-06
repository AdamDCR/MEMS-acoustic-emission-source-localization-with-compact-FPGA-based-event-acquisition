`timescale 1ns / 1ps

module ae_event_ingress #(
    parameter integer FRAME_SAMPLES = 8192
)(
    input                               sys_clk,
    input                               reset_n,

    // ------------------------------------------------------------------------
    // 来自 ae_event_capture 的固定长度事件帧输出
    // ------------------------------------------------------------------------
    input                               cap_out_valid              ,
    input                               cap_out_sop                ,
    input                               cap_out_eop                ,
    input                [ 255: 0]      cap_out_data               ,
    input                [  15: 0]      cap_out_ch_mask            ,
    output wire                         cap_out_ready              ,

    // ------------------------------------------------------------------------
    // 当前事件相关元信息
    // ------------------------------------------------------------------------
    input                [  95: 0]      time_info                  ,
    input                [ 255: 0]      cap_out_meta               ,
    // ------------------------------------------------------------------------
    // 跨时钟数据 FIFO 的回压信号
    // ------------------------------------------------------------------------
    input                               data_fifo_prog_full,
    input                               meta_fifo_prog_full,

    // ------------------------------------------------------------------------
    // 写入 payload FIFO：仅传 256bit 数据
    // ------------------------------------------------------------------------
    output reg                          data_fifo_wr_en,
    output reg          [255:0]         data_fifo_din,

    // ------------------------------------------------------------------------
    // 写入 meta FIFO：每帧 1 条 256bit 元信息
    // ------------------------------------------------------------------------
    output reg                          meta_fifo_wr_en,
    output reg          [255:0]         meta_fifo_din,

    // ------------------------------------------------------------------------
    // 调试信息
    // ------------------------------------------------------------------------
    output reg          [31:0]          event_seq_dbg,
    output reg                          frame_len_error
);

    // ------------------------------------------------------------------------
    // 元信息格式定义
    // [255:224] event_seq
    // [223:208] threshold
    // [207:192] ch_mask
    // [191:160] trigger_sample_index
    // [159:128] payload_words
    // [127:32]  time_info
    // [31:0]    flags / reserved
    // ------------------------------------------------------------------------
    wire                 [  31: 0]      meta_trigger_sample_index  ;
    wire                 [  15: 0]      meta_ch_mask               ;
    wire                 [  15: 0]      meta_trig_mask             ;
    wire                 [  15: 0]      meta_threshold             ;
    wire                 [  15: 0]      meta_sample_rate_div       ;
    wire                 [  31: 0]      meta_flags                 ;

    assign                              meta_trigger_sample_index   = cap_out_meta[255:224];
    assign                              meta_ch_mask                =
        (cap_out_meta[191:176] != 16'd0) ? cap_out_meta[191:176] : cap_out_ch_mask;
    assign                              meta_trig_mask              =
        (cap_out_meta[175:160] != 16'd0) ? cap_out_meta[175:160] : meta_ch_mask;
    assign                              meta_threshold              = cap_out_meta[159:144];
    assign                              meta_sample_rate_div        = cap_out_meta[143:128];

    // 复用原有 32bit flags 字段
    assign meta_flags = {
        meta_trig_mask,
        meta_sample_rate_div
    };

    wire                                ingress_allow;

    reg                 [31:0]          event_seq;
    reg                 [31:0]          frame_word_cnt;
    reg                                 frame_active;

    assign ingress_allow = !data_fifo_prog_full && !meta_fifo_prog_full;
    assign cap_out_ready = ingress_allow;

    always @(posedge sys_clk) begin
        if (!reset_n) begin
            data_fifo_wr_en  <= 1'b0;
            data_fifo_din    <= 256'd0;
            meta_fifo_wr_en  <= 1'b0;
            meta_fifo_din    <= 256'd0;
            event_seq        <= 32'd0;
            event_seq_dbg    <= 32'd0;
            frame_word_cnt   <= 32'd0;
            frame_active     <= 1'b0;
            frame_len_error  <= 1'b0;
        end else begin
            data_fifo_wr_en <= 1'b0;
            meta_fifo_wr_en <= 1'b0;

            if (cap_out_valid && cap_out_ready) begin
                data_fifo_wr_en <= 1'b1;
                data_fifo_din   <= cap_out_data;

                if (cap_out_sop) begin
                    meta_fifo_wr_en <= 1'b1;
                    meta_fifo_din <= {
                        event_seq,
                        meta_threshold,
                        meta_ch_mask,
                        meta_trigger_sample_index,
                        FRAME_SAMPLES[31:0],
                        time_info,
                        meta_flags
                    };

                    frame_word_cnt <= 32'd1;
                    frame_active   <= 1'b1;
                    event_seq_dbg  <= event_seq;
                end else if (frame_active) begin
                    frame_word_cnt <= frame_word_cnt + 1'b1;
                end

                if (cap_out_eop) begin
                    // 固定帧长模式下，帧结束应与 FRAME_SAMPLES 严格对应
                    if ((frame_word_cnt + (cap_out_sop ? 32'd0 : 32'd1)) != FRAME_SAMPLES[31:0]) begin
                        frame_len_error <= 1'b1;
                    end
                    frame_active   <= 1'b0;
                    frame_word_cnt <= 32'd0;
                    event_seq      <= event_seq + 1'b1;
                end
            end
        end
    end

endmodule
