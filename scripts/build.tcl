# Load Quartus packages
package require ::quartus::project
package require ::quartus::flow

# Resolve project root as one level up from this script's location
set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize "$script_dir/.."]

set project_name "AudioFX"
set output_dir   "$root_dir/build_outputs"
set sof_name     "${project_name}.sof"

# 1. Ensure output directory exists
if {![file exists $output_dir]} {
    file mkdir $output_dir
    puts "Created directory: $output_dir"
}

# 2. Open the project only if not already open
if {[is_project_open]} {
    puts "Project already open — skipping project_open."
} else {
    puts "Opening project: $project_name"
    project_open "$root_dir/$project_name"
}

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
if {[file exists "$root_dir/$sof_name"]} {
    set source_sof "$root_dir/$sof_name"
} elseif {[file exists "$root_dir/output_files/$sof_name"]} {
    set source_sof "$root_dir/output_files/$sof_name"
}

if {$source_sof != ""} {
    puts "Copying $source_sof to $output_dir..."
    file copy -force $source_sof [file join $output_dir $sof_name]
} else {
    puts "Error: Could not find $sof_name to copy!"
}

# 5. Generate the JIC file
puts "--- GENERATING JIC FILE ---"
if {[catch {qexec "quartus_cpf -c \"$root_dir/generate_jic.cof\""} result]} {
    puts "JIC Generation failed: $result"
} else {
    puts "--- JIC GENERATION SUCCESSFUL ---"
}

puts "--- DONE ---"