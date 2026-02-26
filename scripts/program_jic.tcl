# Resolve project root as one level up from this script's location
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/.."]

set project_name "AudioFX"
set jic_file "$root_dir/build_outputs/${project_name}.jic"

# 1. Check the JIC file exists
if {![file exists $jic_file]} {
    error "ERROR: JIC file not found at $jic_file — run build.tcl first."
}

# 2. Program via quartus_pgm
# DE-SoC JTAG chain: @1 = HPS ARM core, @2 = Cyclone V FPGA
# JIC uses 'p' only — the flash loader is embedded in the JIC file itself
# bvp (blank-check, verify, program) fails because no loader is pre-loaded
puts "--- PROGRAMMING JIC FILE ---"
puts "Using: $jic_file"

catch {exec quartus_pgm -m jtag -o "p;$jic_file@2"} result

puts $result

if {[string match "*unsuccessful*" $result]} {
    error "ERROR: Programming failed."
}

puts "--- PROGRAMMING SUCCESSFUL ---"
puts "Board has been programmed with $jic_file"