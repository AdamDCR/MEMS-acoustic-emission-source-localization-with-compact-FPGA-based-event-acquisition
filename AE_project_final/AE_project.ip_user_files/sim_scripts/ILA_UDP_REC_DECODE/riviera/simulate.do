onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+ILA_UDP_REC_DECODE -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.ILA_UDP_REC_DECODE xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {ILA_UDP_REC_DECODE.udo}

run -all

endsim

quit -force
