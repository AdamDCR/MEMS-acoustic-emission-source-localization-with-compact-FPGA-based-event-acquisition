onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+ILA_AE_EVT -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.ILA_AE_EVT xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {ILA_AE_EVT.udo}

run -all

endsim

quit -force
