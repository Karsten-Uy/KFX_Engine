//-----------------------
// KFX MIDI controller config
//
// Hardware: 4 bank-select buttons + 1 tap/mute button + 1 expression pedal.
// The expression pedal sends a DIFFERENT MIDI CC depending on which
// bank is currently selected (see POT_CC_BANK below).
// The tap/mute button: a TAP sends a delay-tap CC; HOLDING it ~1s toggles mute.
//
// See MIDI assignments here:
// - https://studiocode.dev/resources/midi-cc/
//-----------------------

// MIDI
const byte MIDI_CHANNEL = 0;
const byte MIDI_HIGH    = 127;
const byte MIDI_LOW     = 0;

// Number of banks / bank buttons
const int NUM_BANKS = 4;

// CC sent when a bank is selected (one per bank)
const byte ccValues_KB[NUM_BANKS] = { 80, 81, 82, 83 };

// Expression-pedal CC, one per bank.
// When bank i is active, the pedal's value is sent on POT_CC_BANK[i].
const byte POT_CC_BANK[NUM_BANKS] = { 4, 66, 67, 68 };

// Tap/mute button CCs
const byte DEL_TAP_CC = 96;    // sent on each tap
const byte MUTE_CC    = 120;   // sent when mute toggles on/off

//-----------------------
// Pin assignments  (change these to match your wiring)
//-----------------------

// Bank buttons: INPUT_PULLUP, wired button -> GND, pressed reads LOW
const int BUT_BIN[NUM_BANKS] = { 9, 8, 7, 6 };

// Tap/mute button: INPUT_PULLUP, wired button -> GND, pressed reads LOW
const int BUT_TM = 5;

// Expression pedal (analog)
const int POT_EX = A0;

//-----------------------
// Calibration / timing
//-----------------------

// Expression pedal range (raw analogRead values at heel / toe)
const int POT_EX_START_VAL = 5;
const int POT_EX_END_VAL   = 630;

const int DEBOUNCE_TIME            = 10;
const int TAP_PULSE_TIME           = 5;
const int POT_HYSTERSIS            = 2;
const int DELAY_TAP_LED_TIME       = 5;     // how long the tap CC is held high
const int MUTE_HOLD_TIME           = 1000;  // hold this long to toggle mute (ms), 
                                             // should match DEBOUNCE_CNT_MAX in lab_pkg.sv
