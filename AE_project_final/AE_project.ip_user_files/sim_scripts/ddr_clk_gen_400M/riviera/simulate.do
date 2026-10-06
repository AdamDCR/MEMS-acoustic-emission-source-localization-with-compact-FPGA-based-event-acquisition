onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+ddr_clk_gen_400M -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.ddr_clk_gen_400M xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {ddr_clk_gen_400M.udo}

run -all

endsim

quit -force
