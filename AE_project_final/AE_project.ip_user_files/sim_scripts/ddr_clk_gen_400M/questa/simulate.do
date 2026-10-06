onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ddr_clk_gen_400M_opt

do {wave.do}

view wave
view structure
view signals

do {ddr_clk_gen_400M.udo}

run -all

quit -force
