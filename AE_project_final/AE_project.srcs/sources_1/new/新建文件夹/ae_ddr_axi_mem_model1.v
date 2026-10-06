`timescale 1ns / 1ps

module ae_ddr_axi_mem_model #(
    parameter integer AXI_ADDR_W = 30,
    parameter integer AXI_DATA_W = 256,
    parameter integer MEM_WORDS  = 65536
)(
    input                               ui_clk,
    input                               ui_rst_n,

    input               [3:0]           s_axi_awid,
    input               [AXI_ADDR_W-1:0]s_axi_awaddr,
    input               [7:0]           s_axi_awlen,
    input               [2:0]           s_axi_awsize,
    input               [1:0]           s_axi_awburst,
    input                               s_axi_awvalid,
    output wire                         s_axi_awready,

    input               [AXI_DATA_W-1:0]s_axi_wdata,
    input               [AXI_DATA_W/8-1:0]s_axi_wstrb,
    input                               s_axi_wlast,
    input                               s_axi_wvalid,
    output wire                         s_axi_wready,

    output reg          [3:0]           s_axi_bid,
    output reg          [1:0]           s_axi_bresp,
    output reg                          s_axi_bvalid,
    input                               s_axi_bready,

    input               [3:0]           s_axi_arid,
    input               [AXI_ADDR_W-1:0]s_axi_araddr,
    input               [7:0]           s_axi_arlen,
    input               [2:0]           s_axi_arsize,
    input               [1:0]           s_axi_arburst,
    input                               s_axi_arvalid,
    output wire                         s_axi_arready,

    output reg          [3:0]           s_axi_rid,
    output reg          [AXI_DATA_W-1:0]s_axi_rdata,
    output reg          [1:0]           s_axi_rresp,
    output reg                          s_axi_rlast,
    output reg                          s_axi_rvalid,
    input                               s_axi_rready
);

    localparam integer AXI_BYTES_PER_BEAT = AXI_DATA_W / 8;
    localparam integer ADDR_LSB           = $clog2(AXI_BYTES_PER_BEAT);
    localparam integer MEM_AW             = $clog2(MEM_WORDS);
    localparam [AXI_ADDR_W-1:0] AXI_BYTES_PER_BEAT_AW = AXI_BYTES_PER_BEAT;

    reg [AXI_DATA_W-1:0]                  mem [0:MEM_WORDS-1];

    reg                                   wr_active;
    reg [AXI_ADDR_W-1:0]                  wr_addr;
    reg [8:0]                             wr_beats_left;

    reg                                   rd_active;
    reg [AXI_ADDR_W-1:0]                  rd_addr;
    reg [8:0]                             rd_beats_left;

    wire [MEM_AW-1:0]                     wr_mem_idx;
    wire [MEM_AW-1:0]                     rd_mem_idx;
    reg  [AXI_DATA_W-1:0]                 wr_merge_data;

    integer                               byte_i;

    assign wr_mem_idx    = wr_addr[ADDR_LSB +: MEM_AW];
    assign rd_mem_idx    = rd_addr[ADDR_LSB +: MEM_AW];

    assign s_axi_awready = ui_rst_n && !wr_active && !s_axi_bvalid;
    assign s_axi_wready  = ui_rst_n && wr_active;
    assign s_axi_arready = ui_rst_n && !rd_active && !s_axi_rvalid;

    always @(posedge ui_clk) begin
        if (!ui_rst_n) begin
            wr_active     <= 1'b0;
            wr_addr       <= {AXI_ADDR_W{1'b0}};
            wr_beats_left <= 9'd0;
            s_axi_bid     <= 4'd0;
            s_axi_bresp   <= 2'b00;
            s_axi_bvalid  <= 1'b0;
        end else begin
            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            if (s_axi_awvalid && s_axi_awready) begin
                wr_active     <= 1'b1;
                wr_addr       <= s_axi_awaddr;
                wr_beats_left <= {1'b0, s_axi_awlen} + 9'd1;
                s_axi_bid     <= s_axi_awid;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                wr_merge_data = mem[wr_mem_idx];
                for (byte_i = 0; byte_i < AXI_BYTES_PER_BEAT; byte_i = byte_i + 1) begin
                    if (s_axi_wstrb[byte_i]) begin
                        wr_merge_data[byte_i*8 +: 8] = s_axi_wdata[byte_i*8 +: 8];
                    end
                end
                mem[wr_mem_idx] <= wr_merge_data;

                wr_addr <= wr_addr + AXI_BYTES_PER_BEAT_AW;
                if (s_axi_wlast || (wr_beats_left == 9'd1)) begin
                    wr_active     <= 1'b0;
                    wr_beats_left <= 9'd0;
                    s_axi_bresp   <= 2'b00;
                    s_axi_bvalid  <= 1'b1;
                end else begin
                    wr_beats_left <= wr_beats_left - 9'd1;
                end
            end
        end
    end

    always @(posedge ui_clk) begin
        if (!ui_rst_n) begin
            rd_active     <= 1'b0;
            rd_addr       <= {AXI_ADDR_W{1'b0}};
            rd_beats_left <= 9'd0;
            s_axi_rid     <= 4'd0;
            s_axi_rdata   <= {AXI_DATA_W{1'b0}};
            s_axi_rresp   <= 2'b00;
            s_axi_rlast   <= 1'b0;
            s_axi_rvalid  <= 1'b0;
        end else begin
            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
                s_axi_rlast  <= 1'b0;
            end

            if (s_axi_arvalid && s_axi_arready) begin
                rd_active     <= 1'b1;
                rd_addr       <= s_axi_araddr;
                rd_beats_left <= {1'b0, s_axi_arlen} + 9'd1;
                s_axi_rid     <= s_axi_arid;
            end else if (rd_active && (!s_axi_rvalid || s_axi_rready)) begin
                s_axi_rdata  <= mem[rd_mem_idx];
                s_axi_rresp  <= 2'b00;
                s_axi_rlast  <= (rd_beats_left == 9'd1);
                s_axi_rvalid <= 1'b1;
                rd_addr      <= rd_addr + AXI_BYTES_PER_BEAT_AW;

                if (rd_beats_left == 9'd1) begin
                    rd_active     <= 1'b0;
                    rd_beats_left <= 9'd0;
                end else begin
                    rd_beats_left <= rd_beats_left - 9'd1;
                end
            end
        end
    end

    wire _unused_aw = &{1'b0, s_axi_awsize, s_axi_awburst};
    wire _unused_ar = &{1'b0, s_axi_arsize, s_axi_arburst};

endmodule
