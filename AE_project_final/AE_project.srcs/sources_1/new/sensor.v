`timescale 1ns/1ps

// ============================================================
// sensor.v
// 功能：
//   1) 封装 DS18B20 / AHT20 / LSM6DS3TR 三个传感器子模块
//   2) 简化顶层模块代码
//   3) 对外统一输出传感器数据
//
// 说明：
//   - DS18B20 : TEM (1-Wire, inout)
//   - AHT20   : H_SCL / H_SDA (I2C, inout)
//   - LSM6DS3TR: Inertia_SCL / Inertia_SDA (I2C, inout)
//   - Inertia_CSB 由本模块输出高电平，强制 LSM6DS3TR 工作在 I2C 模式
//
// 注意：
//   - 本版默认 LSM6DS3TR 的 SA0/SDO 地址脚为低，即 7-bit 地址 0x6A
//   - 如果你的板子上 SA0 实际为高，请把 LSM6_SA0_HIGH 改为 1'b1
// ============================================================
module sensor #(
    parameter integer CLK_FREQ_HZ   = 200_000_000,
    parameter integer I2C_FREQ_HZ   = 100_000,
    parameter                           LSM6_SA0_HIGH               = 1'b0                 
)(
    input  wire                         clk                        ,
    input  wire                         rst_n                      ,

    // ---------------- LSM6DS3TR ----------------
    output wire                         Inertia_SDO                ,
    input  wire                         Inertia_SDX                ,
    input  wire                         Inertia_SCX                ,
    input  wire                         Inertia_INT1               ,
    input  wire                         Inertia_INT2               ,
    input  wire                         Inertia_OSCB               ,
    input  wire                         Inertia_OSDO               ,
    output wire                         Inertia_CSB                ,
    input  wire                         Inertia_SCL_i              ,
    output wire                         Inertia_SCL_oe             ,
    input  wire                         Inertia_SDA_i              ,
    output wire                         Inertia_SDA_oe             ,

    // ---------------- DS18B20 ------------------
    inout  wire                         TEM                        ,

    // ---------------- AHT20 --------------------
    input  wire                         H_SCL_i                    ,
    output wire                         H_SCL_oe                   ,
    input  wire                         H_SDA_i                    ,
    output wire                         H_SDA_oe                   ,

    // ---------------- outputs ------------------
    output wire                         ds18b20_valid              ,
    output wire                         ds18b20_present            ,
    output wire  signed  [  15: 0]      ds18b20_temp_raw_x16       ,
    output wire  signed  [  15: 0]      ds18b20_temp_centi         ,

    output wire                         aht20_valid                ,
    output wire          [  15: 0]      aht20_humi_centi           ,
    output wire  signed  [  15: 0]      aht20_temp_centi           ,

    output wire                         lsm6_valid                 ,
    output wire                         lsm6_ok                    ,
    output wire  signed  [  15: 0]      lsm6_gx_raw                ,
    output wire  signed  [  15: 0]      lsm6_gy_raw                ,
    output wire  signed  [  15: 0]      lsm6_gz_raw                 
);

    // ========================================================
    // 未使用的 LSM6 辅助引脚
    // 当前版本只使用 I2C 模式下的 SCL/SDA、INT1/INT2 可选输入
    // 其余口先保留，便于后续扩展 SPI / sensor hub 模式
    // ========================================================
    wire                                _unused_ok                 ;
    assign _unused_ok = &{
        1'b0,
        Inertia_SDX,
        Inertia_SCX,
        Inertia_OSCB,
        Inertia_OSDO
    };

    // SDO/SA0 is the LSM6DS3TR I2C address strap in I2C mode. The PCB routes it
    // to the FPGA, so drive it to the address selected by LSM6_SA0_HIGH.
    assign Inertia_SDO = LSM6_SA0_HIGH ? 1'b1 : 1'b0;

    wire                                ds18b20_valid_pulse        ;
    wire                                aht20_valid_pulse          ;
    wire                                lsm6_valid_pulse           ;
    reg                                 ds18b20_valid_seen         ;
    reg                                 aht20_valid_seen           ;
    reg                                 lsm6_valid_seen            ;

    assign ds18b20_valid = ds18b20_valid_seen;
    assign aht20_valid   = aht20_valid_seen;
    assign lsm6_valid    = lsm6_valid_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ds18b20_valid_seen <= 1'b0;
            aht20_valid_seen   <= 1'b0;
            lsm6_valid_seen    <= 1'b0;
        end else begin
            if (ds18b20_valid_pulse && ds18b20_present)
                ds18b20_valid_seen <= 1'b1;
            if (aht20_valid_pulse)
                aht20_valid_seen <= 1'b1;
            if (lsm6_valid_pulse && lsm6_ok)
                lsm6_valid_seen <= 1'b1;
        end
    end

    // ========================================================
    // DS18B20
    // ========================================================
    ds18b20_driver #(
    .CLK_FREQ_HZ                        (CLK_FREQ_HZ               ) 
    ) u_ds18b20 (
    .clk                                (clk                       ),
    .rst_n                              (rst_n                     ),
    .dq                                 (TEM                       ),
    .data_valid                         (ds18b20_valid_pulse       ),
    .sensor_present                     (ds18b20_present           ),
    .temp_raw_x16                       (ds18b20_temp_raw_x16      ),
    .temp_centi_deg                     (ds18b20_temp_centi        ) 
    );

    // ========================================================
    // AHT20
    // ========================================================
    aht20_driver #(
    .CLK_FREQ_HZ                        (CLK_FREQ_HZ               ),
    .I2C_FREQ_HZ                        (I2C_FREQ_HZ               ) 
    ) u_aht20 (
    .clk                                (clk                       ),
    .rst_n                              (rst_n                     ),
    .scl_i                              (H_SCL_i                   ),
    .sda_i                              (H_SDA_i                   ),
    .scl_oe                             (H_SCL_oe                  ),
    .sda_oe                             (H_SDA_oe                  ),
    .data_valid                         (aht20_valid_pulse         ),
    .humidity_centi                     (aht20_humi_centi          ),
    .temperature_centi                  (aht20_temp_centi          ) 
    );

    // ========================================================
    // LSM6DS3TR
    // 说明：
    //   - 本版使用 I2C 模式
    //   - Inertia_CSB 由子模块输出高电平
    //   - SA0 地址通过参数决定
    // ========================================================
    lsm6ds3tr_driver #(
    .CLK_FREQ_HZ                        (CLK_FREQ_HZ               ),
    .I2C_FREQ_HZ                        (I2C_FREQ_HZ               ),
    .SA0_HIGH                           (LSM6_SA0_HIGH             ) 
    ) u_lsm6ds3tr (
    .clk                                (clk                       ),
    .rst_n                              (rst_n                     ),
    .scl_i                              (Inertia_SCL_i             ),
    .sda_i                              (Inertia_SDA_i             ),
    .scl_oe                             (Inertia_SCL_oe            ),
    .sda_oe                             (Inertia_SDA_oe            ),
    .csb                                (Inertia_CSB               ),
    .int1                               (Inertia_INT1              ),
    .int2                               (Inertia_INT2              ),
    .data_valid                         (lsm6_valid_pulse          ),
    .sensor_ok                          (lsm6_ok                   ),
    .gyro_x_raw                         (lsm6_gx_raw               ),
    .gyro_y_raw                         (lsm6_gy_raw               ),
    .gyro_z_raw                         (lsm6_gz_raw               ) 
    );

endmodule
