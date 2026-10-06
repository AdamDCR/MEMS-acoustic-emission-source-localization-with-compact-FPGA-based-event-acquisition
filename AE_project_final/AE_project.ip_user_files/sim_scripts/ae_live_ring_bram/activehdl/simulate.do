onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+ae_live_ring_bram -L xpm -L blk_mem_gen_v8_4_4 -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.ae_live_ring_bram xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {ae_live_ring_bram.udo}

run -all

endsim

quit -force
