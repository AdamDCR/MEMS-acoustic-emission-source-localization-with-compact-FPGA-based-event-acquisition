onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+system_clk_module -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.system_clk_module xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {system_clk_module.udo}

run -all

endsim

quit -force
