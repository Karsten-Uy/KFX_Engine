/*
 * ButtonTest.ino
 *
 * Simple circuit-test sketch for the HaH board (ATmega32U4 / Leonardo / Pro Micro).
 * Scans digital pins 2-9 and all analog pins, printing each one's state to the
 * Serial Monitor. Open Tools > Serial Monitor at 9600 baud to watch.
 *
 * Digital pins 2-9 use INPUT_PULLUP, so to test a button just wire it between
 * the pin and GND -- no external resistor needed. Pressed reads LOW.
 * Analog pins are read raw (0..1023).
 */

// --- Digital pins to test (2 through 9) ---
const int digitalPins[] = {2, 3, 4, 5, 6, 7, 8, 9};
const int NUM_DIGITAL = sizeof(digitalPins) / sizeof(digitalPins[0]);

// --- Analog pins to test ---
const int analogPins[] = {A0, A1, A2, A3, A4, A5};
const char* analogNames[] = {"A0", "A1", "A2", "A3", "A4", "A5"};
const int NUM_ANALOG = sizeof(analogPins) / sizeof(analogPins[0]);

void setup() {
  Serial.begin(9600);
  while (!Serial) {
    ; // wait for the Serial Monitor to open (needed on 32U4 boards)
  }

  // Digital pins use internal pull-ups: button wired pin->GND, pressed = LOW
  for (int i = 0; i < NUM_DIGITAL; i++) {
    pinMode(digitalPins[i], INPUT_PULLUP);
  }

  for (int i = 0; i < NUM_ANALOG; i++) {
    pinMode(analogPins[i], INPUT);
  }

  Serial.println("Input test ready.");
  Serial.println("Digital pins 2-9: INPUT_PULLUP -> pressed = LOW (wire button pin->GND).");
  Serial.println("Analog pins A0-A5: raw 0..1023.");
  Serial.println();
}

void loop() {
  // --- Digital pins 2-9 ---
  Serial.print("DIGITAL  ");
  for (int i = 0; i < NUM_DIGITAL; i++) {
    int raw = digitalRead(digitalPins[i]);
    bool pressed = (raw == LOW); // active-low with pull-up

    Serial.print("D");
    Serial.print(digitalPins[i]);
    Serial.print(":");
    Serial.print(pressed ? "PRESS" : "----");
    Serial.print("  ");
  }
  Serial.println();

  // --- Analog pins ---
  Serial.print("ANALOG   ");
  for (int i = 0; i < NUM_ANALOG; i++) {
    int value = analogRead(analogPins[i]);
    Serial.print(analogNames[i]);
    Serial.print("=");
    Serial.print(value);
    Serial.print("  ");
  }
  Serial.println();
  Serial.println();

  delay(200); // slow the output down so it is readable
}
