onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+ILA_DATA_DOWNSAMPLE -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.ILA_DATA_DOWNSAMPLE xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {ILA_DATA_DOWNSAMPLE.udo}

run -all

endsim

quit -force
