onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+ILA_ADC_DRIVE -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.ILA_ADC_DRIVE xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {ILA_ADC_DRIVE.udo}

run -all

endsim

quit -force
