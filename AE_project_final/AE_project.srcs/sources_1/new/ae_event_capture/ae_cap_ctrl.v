
// ============================================================================
// ADC-domain single-shot capture controller
// ============================================================================
module ae_cap_ctrl #(
    parameter integer MAX_CH        = 16,
    parameter integer FRAME_SAMPLES = 8192,
    parameter integer PRE_SAMPLES   = 4096,
    parameter integer RING_AW       = 14,
    parameter integer DESC_W        = 72
)(
    input                           adc_clk,
    input                           reset_n,
    input                           adc_path_ready,
    input                           cap_en,
    input                           sample_valid,
    input                           trigger_hit,
    input      [MAX_CH-1:0]         active_ch_mask,
    input                           ddr_write_done_pulse_adc,
    input                           upload_done_pulse_adc,
    input                           desc_fifo_full,

    output wire                     ring_wr_en,
    output wire [RING_AW-1:0]       ring_wr_addr,
    output wire                     desc_wr_en,
    output wire [DESC_W-1:0]        desc_din,
    output reg                      trig_pulse,
    output wire                     capture_busy,
    output wire                     event_wait_ddr,
    output wire                     event_wait_upload,
    output reg                      event_overflow,
    output reg  [31:0]              trigger_sample_index
);

    localparam [2:0] CAP_FILL        = 3'd0;
    localparam [2:0] CAP_ARMED       = 3'd1;
    localparam [2:0] CAP_POST        = 3'd2;
    localparam [2:0] CAP_WAIT_DDR    = 3'd3;
    localparam [2:0] CAP_WAIT_UPLOAD = 3'd4;

    localparam integer CNT_W = $clog2(FRAME_SAMPLES + 1);
    localparam [CNT_W-1:0] PRE_CNT = PRE_SAMPLES[CNT_W-1:0];
    localparam [CNT_W-1:0] POST_LEFT_INIT =
        (FRAME_SAMPLES - PRE_SAMPLES - 1);

    localparam integer DESC_USED_W = RING_AW + 32 + MAX_CH + 3;
    localparam integer DESC_PAD_W  = DESC_W - DESC_USED_W;

    reg [2:0]             state_cur;
    reg [2:0]             state_nxt;
    reg [RING_AW-1:0]     ring_wr_addr_r;
    reg [31:0]            sample_index_r;
    reg [CNT_W-1:0]       prefill_cnt_r;
    reg [CNT_W-1:0]       post_left_r;

    reg [RING_AW-1:0]     pending_frame_start_ptr_r;
    reg [31:0]            pending_frame_trig_idx_r;
    reg [MAX_CH-1:0]      pending_frame_ch_mask_r;

    wire                  capture_enable;
    wire                  in_sample_state;
    wire                  ring_wr_fire;
    wire                  prefill_done;
    wire                  trigger_fire;
    wire                  frame_done_fire;

    assign capture_enable = cap_en && adc_path_ready;
    assign in_sample_state = (state_cur == CAP_FILL) ||
                             (state_cur == CAP_ARMED) ||
                             (state_cur == CAP_POST);

    assign ring_wr_fire = capture_enable && sample_valid && in_sample_state;
    assign prefill_done = (prefill_cnt_r >= PRE_CNT);
    assign trigger_fire = (state_cur == CAP_ARMED) && ring_wr_fire && trigger_hit;

    assign frame_done_fire = (state_cur == CAP_POST) &&
                             ring_wr_fire &&
                             (post_left_r == {{(CNT_W-1){1'b0}}, 1'b1});

    assign ring_wr_en   = ring_wr_fire;
    assign ring_wr_addr = ring_wr_addr_r;

    // Descriptor:
    // [RING_AW-1:0]          start_ptr
    // [RING_AW +: 32]        trigger sample index
    // [RING_AW+32 +: MAX_CH] active channel mask
    // [RING_AW+32+MAX_CH +:3]frame code, fixed 0 for 8192
    assign desc_wr_en = frame_done_fire && !desc_fifo_full;
    assign desc_din   = {
        {DESC_PAD_W{1'b0}},
        3'd0,
        pending_frame_ch_mask_r,
        pending_frame_trig_idx_r,
        pending_frame_start_ptr_r
    };

    assign capture_busy      = (state_cur == CAP_POST);
    assign event_wait_ddr    = (state_cur == CAP_WAIT_DDR);
    assign event_wait_upload = (state_cur == CAP_WAIT_UPLOAD);

    always @(posedge adc_clk or negedge reset_n) begin
        if (!reset_n)
            state_cur <= CAP_FILL;
        else
            state_cur <= state_nxt;
    end

    always @(*) begin
        state_nxt = state_cur;

        if (!capture_enable) begin
            state_nxt = CAP_FILL;
        end
        else begin
            case (state_cur)
                CAP_FILL: begin
                    if (ring_wr_fire && prefill_done)
                        state_nxt = CAP_ARMED;
                end

                CAP_ARMED: begin
                    if (trigger_fire)
                        state_nxt = CAP_POST;
                end

                CAP_POST: begin
                    if (frame_done_fire)
                        state_nxt = CAP_WAIT_DDR;
                end

                CAP_WAIT_DDR: begin
                    if (ddr_write_done_pulse_adc)
                        state_nxt = CAP_WAIT_UPLOAD;
                end

                CAP_WAIT_UPLOAD: begin
                    if (upload_done_pulse_adc)
                        state_nxt = CAP_FILL;
                end

                default: begin
                    state_nxt = CAP_FILL;
                end
            endcase
        end
    end

    always @(posedge adc_clk or negedge reset_n) begin
        if (!reset_n) begin
            ring_wr_addr_r            <= {RING_AW{1'b0}};
            sample_index_r            <= 32'd0;
            prefill_cnt_r             <= {CNT_W{1'b0}};
            post_left_r               <= {CNT_W{1'b0}};
            pending_frame_start_ptr_r <= {RING_AW{1'b0}};
            pending_frame_trig_idx_r  <= 32'd0;
            pending_frame_ch_mask_r   <= {MAX_CH{1'b0}};
            trig_pulse                <= 1'b0;
            event_overflow            <= 1'b0;
            trigger_sample_index      <= 32'd0;
        end
        else begin
            trig_pulse <= 1'b0;

            if (!capture_enable) begin
                ring_wr_addr_r            <= {RING_AW{1'b0}};
                sample_index_r            <= 32'd0;
                prefill_cnt_r             <= {CNT_W{1'b0}};
                post_left_r               <= {CNT_W{1'b0}};
                pending_frame_start_ptr_r <= {RING_AW{1'b0}};
                pending_frame_trig_idx_r  <= 32'd0;
                pending_frame_ch_mask_r   <= {MAX_CH{1'b0}};
            end
            else if (state_cur == CAP_WAIT_UPLOAD) begin
                if (upload_done_pulse_adc) begin
                    prefill_cnt_r <= {CNT_W{1'b0}};
                    post_left_r   <= {CNT_W{1'b0}};
                end
            end
            else begin
                if (ring_wr_fire) begin
                    ring_wr_addr_r <= ring_wr_addr_r + 1'b1;
                    sample_index_r <= sample_index_r + 1'b1;

                    if (prefill_cnt_r < PRE_CNT)
                        prefill_cnt_r <= prefill_cnt_r + 1'b1;
                end

                if (trigger_fire) begin
                    trig_pulse                <= 1'b1;
                    trigger_sample_index      <= sample_index_r;
                    pending_frame_start_ptr_r <= ring_wr_addr_r - PRE_SAMPLES[RING_AW-1:0];
                    pending_frame_trig_idx_r  <= sample_index_r;
                    pending_frame_ch_mask_r   <= active_ch_mask;
                    post_left_r               <= POST_LEFT_INIT;
                end
                else if ((state_cur == CAP_POST) && ring_wr_fire && (post_left_r > 0)) begin
                    post_left_r <= post_left_r - 1'b1;
                end

                if (frame_done_fire && desc_fifo_full)
                    event_overflow <= 1'b1;
            end
        end
    end

endmodule
