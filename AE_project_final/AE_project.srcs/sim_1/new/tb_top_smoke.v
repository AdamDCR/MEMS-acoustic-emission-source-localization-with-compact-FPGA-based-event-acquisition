`timescale 1ns / 1ps

module tb_top_smoke;
    reg  sys_clk_p = 1'b0;
    wire sys_clk_n = ~sys_clk_p;
    reg  reset_sys_clk = 1'b0;

    wire [3:0] EN;
    wire [3:0] INA;
    wire [3:0] INB;
    wire [3:0] INC;
    wire [3:0] LED_OUT;
    wire       SYS_OUT;
    reg  [3:0] KEY = 4'hF;
    reg  [7:0] BIN = 8'h00;

    reg        Inertia_SDX  = 1'b0;
    reg        Inertia_SCX  = 1'b0;
    reg        Inertia_INT1 = 1'b0;
    reg        Inertia_INT2 = 1'b0;
    reg        Inertia_OSCB = 1'b0;
    reg        Inertia_OSDO = 1'b0;
    wire       Inertia_SDO;
    wire       Inertia_CSB;
    tri1       Inertia_SCL;
    tri1       Inertia_SDA;
    tri1       TEM;
    tri1       H_SCL;
    tri1       H_SDA;

    wire       adc1_pdwn;
    wire       adc1_spi_sck;
    wire       adc1_spi_csn;
    tri        adc1_spi_dio;
    wire       adc1_sync;
    wire       adc1_clk_out_p;
    wire       adc1_clk_out_n;
    reg        adc1_fclk_p = 1'b0;
    wire       adc1_fclk_n = ~adc1_fclk_p;
    reg        adc1_dclk_p = 1'b0;
    wire       adc1_dclk_n = ~adc1_dclk_p;
    reg  [7:0] adc1_data_in_p = 8'h00;
    wire [7:0] adc1_data_in_n = ~adc1_data_in_p;

    wire       adc2_pdwn;
    wire       adc2_spi_sck;
    wire       adc2_spi_csn;
    tri        adc2_spi_dio;
    wire       adc2_sync;
    wire       adc2_clk_out_p;
    wire       adc2_clk_out_n;
    reg        adc2_fclk_p = 1'b0;
    wire       adc2_fclk_n = ~adc2_fclk_p;
    reg        adc2_dclk_p = 1'b0;
    wire       adc2_dclk_n = ~adc2_dclk_p;
    reg  [7:0] adc2_data_in_p = 8'h00;
    wire [7:0] adc2_data_in_n = ~adc2_data_in_p;

    reg        eth_rxc    = 1'b0;
    reg        eth_rx_ctl = 1'b0;
    reg  [3:0] eth_rxd    = 4'h0;
    wire       eth_txc;
    wire       eth_tx_ctl;
    wire [3:0] eth_txd;
    wire       eth_rst_n;

    wire [14:0] ddr3_addr;
    wire [2:0]  ddr3_ba;
    wire        ddr3_cas_n;
    wire [0:0]  ddr3_ck_n;
    wire [0:0]  ddr3_ck_p;
    wire [0:0]  ddr3_cke;
    wire        ddr3_ras_n;
    wire        ddr3_reset_n;
    wire        ddr3_we_n;
    tri  [31:0] ddr3_dq;
    tri  [3:0]  ddr3_dqs_n;
    tri  [3:0]  ddr3_dqs_p;
    wire [0:0]  ddr3_cs_n;
    wire [3:0]  ddr3_dm;
    wire [0:0]  ddr3_odt;

    always #2.5 sys_clk_p = ~sys_clk_p;
    always #4.0 eth_rxc = ~eth_rxc;
    always #1.785714 adc1_dclk_p = ~adc1_dclk_p;
    always #1.785714 adc2_dclk_p = ~adc2_dclk_p;

    top #(
        .SIM_AXI_MEM(1)
    ) dut (
        .sys_clk_p      (sys_clk_p),
        .sys_clk_n      (sys_clk_n),
        .reset_sys_clk  (reset_sys_clk),
        .EN             (EN),
        .INA            (INA),
        .INB            (INB),
        .INC            (INC),
        .LED_OUT        (LED_OUT),
        .SYS_OUT        (SYS_OUT),
        .KEY            (KEY),
        .BIN            (BIN),
        .Inertia_SDO    (Inertia_SDO),
        .Inertia_SDX    (Inertia_SDX),
        .Inertia_SCX    (Inertia_SCX),
        .Inertia_INT1   (Inertia_INT1),
        .Inertia_INT2   (Inertia_INT2),
        .Inertia_OSCB   (Inertia_OSCB),
        .Inertia_OSDO   (Inertia_OSDO),
        .Inertia_CSB    (Inertia_CSB),
        .Inertia_SCL    (Inertia_SCL),
        .Inertia_SDA    (Inertia_SDA),
        .TEM            (TEM),
        .H_SCL          (H_SCL),
        .H_SDA          (H_SDA),
        .adc1_pdwn      (adc1_pdwn),
        .adc1_spi_sck   (adc1_spi_sck),
        .adc1_spi_csn   (adc1_spi_csn),
        .adc1_spi_dio   (adc1_spi_dio),
        .adc1_sync      (adc1_sync),
        .adc1_clk_out_p (adc1_clk_out_p),
        .adc1_clk_out_n (adc1_clk_out_n),
        .adc1_fclk_p    (adc1_fclk_p),
        .adc1_fclk_n    (adc1_fclk_n),
        .adc1_dclk_p    (adc1_dclk_p),
        .adc1_dclk_n    (adc1_dclk_n),
        .adc1_data_in_p (adc1_data_in_p),
        .adc1_data_in_n (adc1_data_in_n),
        .adc2_pdwn      (adc2_pdwn),
        .adc2_spi_sck   (adc2_spi_sck),
        .adc2_spi_csn   (adc2_spi_csn),
        .adc2_spi_dio   (adc2_spi_dio),
        .adc2_sync      (adc2_sync),
        .adc2_clk_out_p (adc2_clk_out_p),
        .adc2_clk_out_n (adc2_clk_out_n),
        .adc2_fclk_p    (adc2_fclk_p),
        .adc2_fclk_n    (adc2_fclk_n),
        .adc2_dclk_p    (adc2_dclk_p),
        .adc2_dclk_n    (adc2_dclk_n),
        .adc2_data_in_p (adc2_data_in_p),
        .adc2_data_in_n (adc2_data_in_n),
        .eth_rxc        (eth_rxc),
        .eth_rx_ctl     (eth_rx_ctl),
        .eth_rxd        (eth_rxd),
        .eth_txc        (eth_txc),
        .eth_tx_ctl     (eth_tx_ctl),
        .eth_txd        (eth_txd),
        .eth_rst_n      (eth_rst_n),
        .ddr3_addr      (ddr3_addr),
        .ddr3_ba        (ddr3_ba),
        .ddr3_cas_n     (ddr3_cas_n),
        .ddr3_ck_n      (ddr3_ck_n),
        .ddr3_ck_p      (ddr3_ck_p),
        .ddr3_cke       (ddr3_cke),
        .ddr3_ras_n     (ddr3_ras_n),
        .ddr3_reset_n   (ddr3_reset_n),
        .ddr3_we_n      (ddr3_we_n),
        .ddr3_dq        (ddr3_dq),
        .ddr3_dqs_n     (ddr3_dqs_n),
        .ddr3_dqs_p     (ddr3_dqs_p),
        .ddr3_cs_n      (ddr3_cs_n),
        .ddr3_dm        (ddr3_dm),
        .ddr3_odt       (ddr3_odt)
    );

    initial begin
        repeat (20) @(posedge sys_clk_p);
        reset_sys_clk = 1'b1;
        repeat (2000) @(posedge sys_clk_p);
        $display("PASS: tb_top_smoke elaborated and ran with SIM_AXI_MEM");
        $finish;
    end
endmodule
