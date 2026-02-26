# Load Quartus packages
package require ::quartus::project
package require ::quartus::flow

set project_name "AudioFX"
set output_dir "build_outputs"
set sof_name "${project_name}.sof"

# 1. Ensure output directory exists
if {![file exists $output_dir]} {
    file mkdir $output_dir
    puts "Created directory: $output_dir"
}

# 2. Open the project
project_open $project_name

# 3. Run the Full Compilation
puts "--- STARTING COMPILATION ---"
if {[catch {execute_flow -compile} result]} {
    puts "Compilation failed: $result"
    project_close
    exit 1
}

# 4. Copy the SOF file to the build directory
# We check both the root and the default 'output_files' folder 
# just in case your .qsf settings changed.
set source_sof ""
if {[file exists $sof_name]} {
    set source_sof $sof_name
} elseif {[file exists "output_files/$sof_name"]} {
    set source_sof "output_files/$sof_name"
}

if {$source_sof != ""} {
    puts "Copying $source_sof to $output_dir..."
    file copy -force $source_sof [file join $output_dir $sof_name]
} else {
    puts "Error: Could not find $sof_name to copy!"
}

# 5. Generate the JIC file
puts "--- GENERATING JIC FILE ---"
if {[catch {qexec "quartus_cpf -c generate_jic.cof"} result]} {
    puts "JIC Generation failed: $result"
} else {
    puts "--- JIC GENERATION SUCCESSFUL ---"
}

puts "--- DONE ---"
project_close