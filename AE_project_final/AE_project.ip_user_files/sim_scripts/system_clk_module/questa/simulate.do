onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib system_clk_module_opt

do {wave.do}

view wave
view structure
view signals

do {system_clk_module.udo}

run -all

quit -force
