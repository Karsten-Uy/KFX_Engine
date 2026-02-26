# Resolve project root as one level up from this script's location
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/.."]

set project_name "AudioFX"
set sof_file "$root_dir/build_outputs/${project_name}.sof"

# 1. Check the SOF file exists
if {![file exists $sof_file]} {
    error "ERROR: SOF file not found at $sof_file — run build.tcl first."
}

# 2. Program via quartus_pgm
# DE-SoC JTAG chain: @1 = HPS ARM core, @2 = Cyclone V FPGA
puts "--- PROGRAMMING SOF FILE ---"
puts "Using: $sof_file"

catch {exec quartus_pgm -m jtag -o "p;$sof_file@2"} result

puts $result

if {[string match "*unsuccessful*" $result]} {
    error "ERROR: Programming failed."
}

puts "--- PROGRAMMING SUCCESSFUL ---"
puts "NOTE: This is volatile — the design will be lost on power cycle."
puts "      Run program_jic.tcl to program flash memory instead."