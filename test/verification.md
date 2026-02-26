
# HaH Processor Verification Plan

This document outlines the planned verification strategy for the pedalboard. It is split into controller and FX sections, System. All of the testing files are in the `./testing` folder

----

## Controller
This is for the controller and display units of the design that adjust the various parameter values.

### Verification Levels
| Level | Scope          | Testing Environment           |
| ----- | -------------- | ----------------------------- |
| Unit  | controller.sv, display.sv, sevseg_display.sv | SystemVerilog .sv Testbenches |
| System  | Full FPGA Design | Actual FPGA  |

#### Unit Tests
These tests should test the functionality of incrementing and decrementing various parameters and ensures that the correct parameter is adjusted and have the proper LED display output.

##### TODO:
- `tb_controller.sv`
    - as of right now, it just covers very basic cases, need to eleaborate.
- `tb_display`
    - need to create, should validate output for various parameter values.
- `tb_sevseg_display`
    - need to create, should validate the HEX output for various input values.

#### System Tests
These tests should test the functionality of incrementing and decrementing various parameters and ensures that the correct parameter is adjusted and have the proper LED display output on the FPGA. This will be done manually and the following test cases should pass

##### Test Cases
Display Checks:
- Test all possible permutations of the switches and ensure that the HEX displays match
- Test vrest button and ensure that the parameters are reset
Parameter Checks
- Test vairous parameters and then hold down KEY[3] and ensure that the LEDR amount bar goes down to just 1 LEDR
- Test vairous parameters and then hold down KEY[2] and ensure that the LEDR amount bar goes up to all LEDRs

----

## FX
This is for the audio FX modules that perform DSP

### Verification Levels
| Level | Scope          | Testing Environment           |
| ----- | -------------- | ----------------------------- |
| Unit  | fx_*.sv files  | .sv Testbenches |
| Model-based  | fx_*.sv files | .sv Testbenches + Python |

#### Unit Tests
These tests should test the functionality of various FX to the extent that a pure verilog testbench can do

##### TODO:
- `tb_fx_chorus.sv`
    - need to create. Should validate that audio_in creates a sample audio_out after a predefined amount of samples. Also need to check envelope functionality.
- `tb_fx_compressor.sv`
    - as of right now, it just covers very basic cases, need to eleaborate. Tests to ensure that a signal above a threshold gets reduced by some amount after a predefined amount of samples.
- `tb_fx_delay.sv`
    - need to create. Should validate that audio_in creates a sample audio_out after a predefined amount of samples and repeats with lower gain a set amount of times.
- `tb_fx_distortion.sv`
    - need to create. Should validate that the amplitude of audio_in is changed according to the tanh(x) non-linearlity.
- `tb_fx_eq.sv`
    - need to create. Should validate that audio_in and audio_out is the same if all gain is 1.
- `tb_fx_gain.sv`
    - need to create. Should validate that the amplitude of audio_in is moduled by the fx_gain value correctly.
- `fx_gate.sv` 
    - need to create. Should validate that audio_in is blocked if its amplitude is low enough, Also need to check envelope functionality.
- `fx_reverb.sv` 
    - need to create. Should validate that audio_in creates a sample audio_out after a predefined amount of samples.

#### Model-based Tests
These tests should take the output of an FX from an .sv testbench and feed it into a golden reference model written in python to validate its output

##### TODO:
- Create template for .sv audio_out dumper and script environment to validate FX modules

- `tb_fx_chorus.py`
    - need to create reference model
- `tb_fx_compressor.py`
    - need to create reference model
- `tb_fx_delay.py`
    - need to create reference model
- `tb_fx_distortion.py`
    - need to create reference model
- `tb_fx_eq.py`
    - need to create reference model
- `tb_fx_gain.py`
    - need to create reference model
- `fx_gate.py` 
    - need to create reference model
- `fx_reverb.py` 
    - need to create reference model

----

## System
These tests are for the entire system

### Verification Levels
| Level | Scope          | Testing Environment |
| Simulation | Full FPGA Design | .sv Testbenches |
| System  | Full FPGA Design | Actual FPGA  |

#### Simulation Tests
This should simulate the top level design and ensure basic functionality of as many components as it can

##### TODO:
- figure out how much of the IP can actually simulate and how to simulate them
- make `tb_top.sv`

#### System Tests
This should test the functionality of the pedal board on the actual FPGA

##### TODO:
- Plan out how to test IP integrations, especially the audio codec

##### Tests:
These can be validated by listening to the output or using something like the "Signal Tap Logic Analyzer" on Quartus

- Knob stress test: 
    - Pass in a sine wave and rest rapidly switching parameters and listen for clicks and pops
- Clipping Test:
    - pass in a very high aimplitude signal and validate that there is as little buzzing as possible (except for distortion)
- Noise floor test:
    - pass in no sound and ensure that there is no static buzz
