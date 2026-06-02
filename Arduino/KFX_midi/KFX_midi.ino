#include "MIDIUSB.h"
#include "KFX_midi.h"

/*******************/
// GLOBAL VARIABLES
/*******************/

int  currentBank = 0;          // currently selected bank (0..NUM_BANKS-1)

bool butRead[NUM_BANKS];       // current pressed state of each bank button
bool lastButRead[NUM_BANKS];   // previous pressed state (for edge detection)

int lastPotValueEx = -1;       // last expression-pedal reading sent

// Tap/mute button state
bool delayState = false;            // last raw state of the tap/mute button
unsigned long pressStartTime = 0;   // when the current hold started
bool holding = false;               // button currently held down
bool holdSignalSent = false;        // mute already toggled for this hold
bool isMute = false;                // mute currently active
bool unmuteReady = false;           // a tap-release will unmute

//-----------------------------------------
// MIDIUSB helper

void controlChange(byte channel, byte control, byte value) {
  midiEventPacket_t event = {0x0B, 0xB0 | channel, control, value};
  MidiUSB.sendMIDI(event);
  MidiUSB.flush();
}

//-----------------------------------------
void setup() {
  Serial.begin(9600);

  // Bank buttons: internal pull-ups, so a button just connects pin -> GND
  for (int i = 0; i < NUM_BANKS; i++) {
    pinMode(BUT_BIN[i], INPUT_PULLUP);
    butRead[i] = false;
    lastButRead[i] = false;
  }

  // Tap/mute button
  pinMode(BUT_TM, INPUT_PULLUP);

  // Start on bank 0
  currentBank = 0;
  controlChange(MIDI_CHANNEL, ccValues_KB[0], MIDI_HIGH);
}

//-----------------------------------------
void loop() {

  delay(DEBOUNCETIME); // simple debounce

  /************************/
  // BANK SELECT BUTTONS
  /************************/

  // Read buttons (active-low: pressed = LOW because of INPUT_PULLUP)
  for (int i = 0; i < NUM_BANKS; i++) {
    butRead[i] = (digitalRead(BUT_BIN[i]) == LOW);
  }

  // Act on the first button that was just pressed (rising edge)
  for (int i = 0; i < NUM_BANKS; i++) {
    if (butRead[i] && !lastButRead[i]) {

      currentBank = i;

      Serial.print("Bank ");
      Serial.print(i);
      Serial.println(" selected");

      // Tell the host which bank is active
      for (int j = 0; j < NUM_BANKS; j++) {
        controlChange(MIDI_CHANNEL, ccValues_KB[j], (j == i) ? MIDI_HIGH : MIDI_LOW);
      }
      break;
    }
  }

  // Save states for next loop's edge detection
  for (int i = 0; i < NUM_BANKS; i++) {
    lastButRead[i] = butRead[i];
  }

  /************************/
  // TAP / MUTE BUTTON
  /************************/

  // Tap = send delay-tap CC.  Hold ~1s = toggle mute on/off.
  bool tmState = digitalRead(BUT_TM); // LOW = pressed (INPUT_PULLUP)
  if (tmState != delayState) {

    if (tmState == LOW) {  // Button pressed
      // If already muted, a quick tap-and-release will unmute
      if (isMute && !holding) {
        unmuteReady = true;
      }

      Serial.println("Delay Tapped");
      controlChange(MIDI_CHANNEL, DEL_TAP_CC, MIDI_HIGH);
      delay(DELAY_TAP_LED_TIME);
      controlChange(MIDI_CHANNEL, DEL_TAP_CC, MIDI_LOW);

      // Start hold timer for this press
      pressStartTime = millis();
      holding = true;
      holdSignalSent = false;

    } else {  // Button released
      if (unmuteReady) {
        controlChange(MIDI_CHANNEL, MUTE_CC, MIDI_LOW);
        Serial.println("Unmuted");
        isMute = false;
        unmuteReady = false;
      }
      holding = false;
    }

    delayState = tmState;
  }

  // Hold check: if held long enough, toggle mute on
  if (!unmuteReady && holding && !holdSignalSent &&
      (millis() - pressStartTime >= MUTE_HOLD_TIME)) {
    controlChange(MIDI_CHANNEL, MUTE_CC, MIDI_HIGH);
    Serial.println("Mute triggered!");
    isMute = true;
    holdSignalSent = true;
    unmuteReady = false;
  }

  /************************/
  // EXPRESSION PEDAL
  /************************/

  // The pedal sends a different CC depending on the selected bank.
  int potValueEx = analogRead(POT_EX);
  int ccValueEx  = map(potValueEx, POT_EX_START_VAL, POT_EX_END_VAL, 0, 127);
  ccValueEx = constrain(ccValueEx, 0, 127);

  if (abs(potValueEx - lastPotValueEx) > POT_THRESHOLD) {
    controlChange(MIDI_CHANNEL, POT_CC_BANK[currentBank], ccValueEx);

    Serial.print("Pedal (bank ");
    Serial.print(currentBank);
    Serial.print(") -> CC ");
    Serial.print(POT_CC_BANK[currentBank]);
    Serial.print(" = ");
    Serial.println(ccValueEx);

    lastPotValueEx = potValueEx;
  }
}
