onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+adc_dclk_in -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.adc_dclk_in xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {adc_dclk_in.udo}

run -all

endsim

quit -force
