// ============================================================================
// Copy controller: descriptor FIFO + live ring -> frame bank
// Handles live ring B-port read latency.
// ============================================================================
module ae_copy_ctrl #(
    parameter integer MAX_CH          = 16,
    parameter integer FRAME_SAMPLES   = 8192,
    parameter integer RING_AW         = 14,
    parameter integer FRAME_AW        = 13,
    parameter integer DESC_W          = 72,
    parameter integer RING_RD_LATENCY = 4
)(
    input                           sys_clk,
    input                           reset_n,
    input                           sys_path_ready,
    input                           desc_fifo_empty,
    input      [DESC_W-1:0]         desc_fifo_dout,
    input      [255:0]              ring_rd_data,
    input                           bank0_free,
    input                           bank1_free,

    output wire                     desc_rd_en,
    output wire                     ring_rd_en,
    output wire [RING_AW-1:0]       ring_rd_addr,
    output wire                     copy_busy,
    output wire                     copy_bank_sel,
    output wire                     bank_wr_en,
    output wire                     bank_wr_sel,
    output wire [FRAME_AW-1:0]      bank_wr_addr,
    output wire [255:0]             bank_wr_data,
    output reg                      bank_load_pulse,
    output reg                      bank_load_sel,
    output reg  [31:0]              bank_load_trig_idx,
    output reg  [MAX_CH-1:0]        bank_load_ch_mask
);

    localparam [1:0] CP_IDLE       = 2'd0;
    localparam [1:0] CP_FETCH_DESC = 2'd1;
    localparam [1:0] CP_COPY       = 2'd2;
    localparam [1:0] CP_DRAIN      = 2'd3;

    localparam integer DESC_TRIG_LSB = RING_AW;
    localparam integer DESC_MASK_LSB = RING_AW + 32;

    reg [1:0]                 state_cur;
    reg [1:0]                 state_nxt;

    reg                       copy_bank_sel_r;
    reg                       desc_loaded_r;
    reg [RING_RD_LATENCY-1:0] ring_valid_pipe_r;

    reg [RING_AW-1:0]         copy_start_ptr_r;
    reg [31:0]                copy_trig_idx_r;
    reg [MAX_CH-1:0]          copy_ch_mask_r;

    reg [FRAME_AW:0]          copy_issue_cnt_r;
    reg [FRAME_AW:0]          copy_write_cnt_r;

    wire                      free_bank_available;
    wire                      fetch_fire;
    wire                      ring_rd_fire;
    wire                      bank_wr_fire;
    wire                      copy_done_fire;
    wire                      ring_pipe_empty;

    wire [MAX_CH-1:0]         desc_ch_mask;
    wire [31:0]               desc_trig_idx;
    wire [RING_AW-1:0]        desc_start_ptr;

    assign desc_start_ptr = desc_fifo_dout[RING_AW-1:0];
    assign desc_trig_idx  = desc_fifo_dout[DESC_TRIG_LSB +: 32];
    assign desc_ch_mask   = desc_fifo_dout[DESC_MASK_LSB +: MAX_CH];

    assign free_bank_available = bank0_free || bank1_free;
    assign fetch_fire          = sys_path_ready && !desc_fifo_empty && free_bank_available;

    assign desc_rd_en          = (state_cur == CP_FETCH_DESC);

    assign ring_rd_fire        = (state_cur == CP_COPY) &&
                                 desc_loaded_r &&
                                 (copy_issue_cnt_r < FRAME_SAMPLES);
    assign ring_rd_en          = ring_rd_fire;
    assign ring_rd_addr        = copy_start_ptr_r + copy_issue_cnt_r[RING_AW-1:0];

    assign bank_wr_fire        = ring_valid_pipe_r[RING_RD_LATENCY-1];
    assign bank_wr_en          = bank_wr_fire;
    assign bank_wr_sel         = copy_bank_sel_r;
    assign bank_wr_addr        = copy_write_cnt_r[FRAME_AW-1:0];
    assign bank_wr_data        = ring_rd_data;

    assign copy_busy           = (state_cur != CP_IDLE);
    assign copy_bank_sel       = copy_bank_sel_r;
    assign ring_pipe_empty     = (ring_valid_pipe_r == {RING_RD_LATENCY{1'b0}});

    assign copy_done_fire      = bank_wr_fire &&
                                 (copy_write_cnt_r == FRAME_SAMPLES - 1);

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n)
            state_cur <= CP_IDLE;
        else
            state_cur <= state_nxt;
    end

    always @(*) begin
        state_nxt = state_cur;

        if (!sys_path_ready) begin
            state_nxt = CP_IDLE;
        end
        else begin
            case (state_cur)
                CP_IDLE: begin
                    if (fetch_fire)
                        state_nxt = CP_FETCH_DESC;
                end

                CP_FETCH_DESC: begin
                    state_nxt = CP_COPY;
                end

                CP_COPY: begin
                    if (desc_loaded_r && (copy_issue_cnt_r == FRAME_SAMPLES))
                        state_nxt = CP_DRAIN;
                end

                CP_DRAIN: begin
                    if (ring_pipe_empty && (copy_write_cnt_r == FRAME_SAMPLES))
                        state_nxt = CP_IDLE;
                end

                default: begin
                    state_nxt = CP_IDLE;
                end
            endcase
        end
    end

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            copy_bank_sel_r   <= 1'b0;
            desc_loaded_r     <= 1'b0;
            ring_valid_pipe_r <= {RING_RD_LATENCY{1'b0}};
            copy_start_ptr_r  <= {RING_AW{1'b0}};
            copy_trig_idx_r   <= 32'd0;
            copy_ch_mask_r    <= {MAX_CH{1'b0}};
            copy_issue_cnt_r  <= {(FRAME_AW + 1){1'b0}};
            copy_write_cnt_r  <= {(FRAME_AW + 1){1'b0}};
            bank_load_pulse   <= 1'b0;
            bank_load_sel     <= 1'b0;
            bank_load_trig_idx<= 32'd0;
            bank_load_ch_mask <= {MAX_CH{1'b0}};
        end
        else begin
            bank_load_pulse <= 1'b0;

            if (RING_RD_LATENCY == 1)
                ring_valid_pipe_r <= {ring_rd_fire};
            else
                ring_valid_pipe_r <= {ring_valid_pipe_r[RING_RD_LATENCY-2:0], ring_rd_fire};

            if (!sys_path_ready) begin
                desc_loaded_r     <= 1'b0;
                ring_valid_pipe_r <= {RING_RD_LATENCY{1'b0}};
                copy_issue_cnt_r  <= {(FRAME_AW + 1){1'b0}};
                copy_write_cnt_r  <= {(FRAME_AW + 1){1'b0}};
            end
            else begin
                if ((state_cur == CP_IDLE) && (state_nxt == CP_FETCH_DESC)) begin
                    copy_bank_sel_r   <= bank0_free ? 1'b0 : 1'b1;
                    desc_loaded_r     <= 1'b0;
                    ring_valid_pipe_r <= {RING_RD_LATENCY{1'b0}};
                    copy_issue_cnt_r  <= {(FRAME_AW + 1){1'b0}};
                    copy_write_cnt_r  <= {(FRAME_AW + 1){1'b0}};
                end

                if ((state_cur == CP_COPY) && !desc_loaded_r) begin
                    copy_start_ptr_r <= desc_start_ptr;
                    copy_trig_idx_r  <= desc_trig_idx;
                    copy_ch_mask_r   <= desc_ch_mask;
                    desc_loaded_r    <= 1'b1;
                end

                if (ring_rd_fire) begin
                    copy_issue_cnt_r <= copy_issue_cnt_r + 1'b1;
                end

                if (bank_wr_fire) begin
                    copy_write_cnt_r <= copy_write_cnt_r + 1'b1;
                end

                if (copy_done_fire) begin
                    bank_load_pulse    <= 1'b1;
                    bank_load_sel      <= copy_bank_sel_r;
                    bank_load_trig_idx <= copy_trig_idx_r;
                    bank_load_ch_mask  <= copy_ch_mask_r;
                end

                if ((state_cur == CP_DRAIN) && (state_nxt == CP_IDLE)) begin
                    desc_loaded_r <= 1'b0;
                end
            end
        end
    end

endmodule
