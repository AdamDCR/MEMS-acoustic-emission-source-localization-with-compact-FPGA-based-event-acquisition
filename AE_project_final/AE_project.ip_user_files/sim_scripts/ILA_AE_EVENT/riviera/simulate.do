onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+ILA_AE_EVENT -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.ILA_AE_EVENT xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {ILA_AE_EVENT.udo}

run -all

endsim

quit -force
