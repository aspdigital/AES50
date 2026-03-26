/* ============================================================================
 * Project      : AES50 VHDL IP-CORE
 * File         : <RPI_Pico_2040_HA_Remote_Example.ino>
 * Authors      : Markus Noll, Christian Nöding, with kind support from Thomas Zint (Behringer R&D Germany)
 * Created      : <2026-03-25>
 *
 * Description  : A simple Arduino style example (prototyped on RPI-Pico-2040) to show how to control Head-Amps remotely
 *
 * License      : GNU General Public License v3.0 or later (GPL-3.0-or-later)
 *
 * This file is part of the AES50 VHDL IP-CORE.
 *
 * The AES50 VHDL IP-CORE is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * The AES50 VHDL IP-CORE is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 * ========================================================================== */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

//Send packet every 100ms
#define HAControlFrameSendInterval    100
#define PropertySendInterval          1000
#define NameSendInterval              5000 // 408 bytes are sent, so dont send too often

//define the timeout of received message to frame them
#define MesageReceivedTimeout         10

unsigned long HAControlFrameSendTimeout;
unsigned long PropertySendTimeout;
unsigned long NameSendTimeout;
unsigned long LastAES50MsgReceiveTime;
uint8_t       MsgReceiveDirty;


float         GainLevel[48]; // in dB - will be rescaled to device-specific values below
bool          PhantomPowerStatus[48];


float gainMap(float in, float inMin, float inMax, float outMin, float outMax) {
  return ((in - inMin) * (outMax - outMin) / (inMax - inMin)) + outMin;
}


void AES50_Frame_AddChecksum(uint8_t* buf) {
  uint8_t messageID = buf[0];
  uint8_t len = buf[1];
  uint8_t deviceChar = buf[7];

  // initializing
  uint32_t ids4 = (uint32_t)deviceChar << 24;
  uint16_t cks = (uint16_t)(ids4 >> 16) ^ (uint16_t)(ids4 & 0xFFFF);

  uint32_t* dataWords = (uint32_t*)&buf[8];

  if (len > 2) {
    for (int i = 0; i <= (len - 3); i++) {
      uint32_t currentWord = dataWords[i];
      cks -= (uint16_t)(currentWord >> 16) ^ (uint16_t)(currentWord & 0xFFFF);
    }
  }
  uint16_t finalCks = cks ^ 0xFFFF;

  buf[2] = (uint8_t)(finalCks & 0xFF);
  buf[3] = (uint8_t)(finalCks >> 8);
}

void AES50_Send_Device_Property_Frame(void) {
  uint8_t PropertyFrame[16];

  PropertyFrame[0] = 0x05;
  PropertyFrame[1] = (16 / 4); // message-length in 32-bit words
  PropertyFrame[2] = 0; // checksum
  PropertyFrame[3] = 0; // checksum

  // AES50-DeviceChars for the last four connected devices (AES50 seems to support up to 6, but only the last 4 are transmitted)
  PropertyFrame[4] = 0;   // fourth device in AES50-chain
  PropertyFrame[5] = 0;   // third device in AES50-chain
  PropertyFrame[6] = 0;   // second device in AES50-chain
  PropertyFrame[7] = 'C'; // first device in AES50-chain: here X32 Fullsize

  // data[8 .. 13] <- '0' if no headamp-control, '2' if headamp-control is present
  PropertyFrame[8] = '0';  // AES50 Ch 1-8 have no headamp-control in current device
  PropertyFrame[9] = '0';  // AES50 Ch 9-16 have no headamp-control in current device
  PropertyFrame[10] = '0'; // AES50 Ch 17-24 have no headamp-control in current device
  PropertyFrame[11] = '0'; // AES50 Ch 25-32 have no headamp-control in current device
  PropertyFrame[12] = '0'; // AES50 Ch 33-40 have no headamp-control in current device
  PropertyFrame[13] = '0'; // AES50 Ch 41-48 have no headamp-control in current device

  // byte-stuffing with zeros to have full divider by 4
  PropertyFrame[14] = 0x00;
  PropertyFrame[15] = 0x00;

  AES50_Frame_AddChecksum(&PropertyFrame[0]);

  Serial1.write(&PropertyFrame[0], 16);  
}


//warning - this is not working yet
void AES50_Send_Names_Frame(void) {
  uint8_t NamesFrame[408];

  NamesFrame[0] = 0x10;
  NamesFrame[1] = (408 / 4); // message-length in 32-bit words
  NamesFrame[2] = 0; // checksum
  NamesFrame[3] = 0; // checksum
  
  // AES50-DeviceChars for the last four connected devices (AES50 seems to support up to 6, but only the last 4 are transmitted)
  NamesFrame[4] = 0;   // fourth device in AES50-chain
  NamesFrame[5] = 0;   // third device in AES50-chain
  NamesFrame[6] = 0;   // second device in AES50-chain
  NamesFrame[7] = 'C'; // first device in AES50-chain: here X32 Fullsize

  // the next bytes are zero-terminated ASCII-strings. First clear the data-array with zeros
  for (int i = 8; i < 408; i++) {
    NamesFrame[i] = 0x00;
  }

  // insert zero-terminated device-string of current AES50-device
  sprintf((char*)&NamesFrame[8], "X32");
  
  // from data[25] 48x 8-char ASCII-Name for each channel is sent
  for (int i = 0; i < 48; i++) {
    sprintf((char*)&NamesFrame[25 + (i * 8)], "IN %u", i + 1);
  }

  // calculate and add checksum to begin of message
  AES50_Frame_AddChecksum(&NamesFrame[0]);

  // send data over UART to AES50 IP-core
  Serial1.write(&NamesFrame[0], 408);
}


void AES50_Send_Headamp_Control_Frame(void) {
  uint8_t HAControlFrame[60];

  HAControlFrame[0] = 0x01;
  HAControlFrame[1] = (60 / 4); // message-length in 32-bit words
  HAControlFrame[2] = 0; // checksum
  HAControlFrame[3] = 0; // checksum
  
  // AES50-DeviceChars for the last four connected devices (AES50 seems to support up to 6, but only the last 4 are transmitted)
  HAControlFrame[4] = 0;
  HAControlFrame[5] = 0;
  HAControlFrame[6] = 0;
  HAControlFrame[7] = 'C'; // X32 Fullsize

  // now insert the headamp-gains
  // the specific value depends on the connected AES50 device as some devices have more gain-options than others
  
  // An S16 for example has settings between -2.0dB and 45.5dB resulting in 47.5dB range with 2.5dB steps -> 47.5 / 2.5 = 19. So we have settings between 0 = -2.0dB and 19 = 45.5dB
  // A Wing has settings between -2.5dB and 45dB (also having steps between 0-19 possible)

  for (int i = 0; i < 48; i++) {
    HAControlFrame[8 + i] = (uint8_t) roundf(gainMap(GainLevel[i], -2.5f, 45.0f, 0, 19)); //this map function is adapted to control a Wing    
    if (PhantomPowerStatus[i]) HAControlFrame[i + 8] |= 0x80;
  }

  // a single 32-bit word with zeros for finalizing the message
  HAControlFrame[56] = 0;
  HAControlFrame[57] = 0;
  HAControlFrame[58] = 0;
  HAControlFrame[59] = 0;

  AES50_Frame_AddChecksum(&HAControlFrame[0]);
  

  // send data over UART to AES50 IP-core
  Serial1.write(&HAControlFrame[0], 60);   
}


void setup() {

  //Serial to Computer for monitoring & control
  Serial.begin(115200); 

  //Serial to FPGA/AES50 (mapped to RP2040 UART0 on Rx-pin GP1 Tx-pin GP0 - connect this Tx/Rx cross-connected to the UART pins from the AES50 IP-Core)
  Serial1.begin(115200); 

  //Init Gains and Phantom-Power with default values
  for (int i = 0; i < 48; i++) {
    GainLevel[i] = 0.0;
    PhantomPowerStatus[i] = false;
  }

  //schedule first packet to send
  HAControlFrameSendTimeout = millis() + HAControlFrameSendInterval;
  PropertySendTimeout = millis() + PropertySendInterval;
  NameSendTimeout = millis() + NameSendInterval;


}


void HandleCMDFromComputer() {
  String command;
  String answer;

  if (Serial.available() > 0) {
    command = Serial.readStringUntil('\n');
    command.trim();

    // execute command
    if (command.length() > 2){
      if (command.indexOf("gain:ch") > -1){
        // received command "gain:chX@valueY"
        uint8_t channel = command.substring(7, command.indexOf("@")).toInt();
        float value = command.substring(command.indexOf("@")+1).toFloat();

        GainLevel[channel - 1] = value;
      }
      else if (command.indexOf("phantom:ch") > -1){ 
        // received command "phantom:chX@valueY"
        uint8_t channel = command.substring(10, command.indexOf("@")).toInt();
        uint8_t value = command.substring(command.indexOf("@")+1).toInt();

        PhantomPowerStatus[channel - 1] = (value > 0);
      }
      else{
        answer = "UNKNOWN_CMD: " + command;
      }
    }
    else{
      answer = "ERROR";
    }

    // send answer back to computer
    Serial.println(answer);
  }
}


void loop() {
  
  //if timeouts have passed, we send the frames
  if (millis() > HAControlFrameSendTimeout) {
    HAControlFrameSendTimeout = millis() + HAControlFrameSendInterval;
    AES50_Send_Headamp_Control_Frame();    
  }
  if (millis() > PropertySendTimeout) {
    PropertySendTimeout = millis() + PropertySendInterval;
    AES50_Send_Device_Property_Frame();
  }
  if (millis() > NameSendTimeout) {
    NameSendTimeout = millis() + NameSendInterval;
    //not working currently - need to be checked
    //AES50_Send_Names_Frame(); 
  }

  //Forward data from AES50 to Computer
  while (Serial1.available() > 0) {   
    if (MsgReceiveDirty==0) Serial.print("Msg-RX:");  
    Serial.write(Serial1.read());
    LastAES50MsgReceiveTime = millis();
    MsgReceiveDirty = 1;
  }

  //If the receive time-out from aes50-aux-rx has passed, indicate the new message
  if ( (millis() > LastAES50MsgReceiveTime + MesageReceivedTimeout) && MsgReceiveDirty == 1 ) {
    MsgReceiveDirty = 0;
    Serial.print("\n");     
  }
  
  // handle incoming messages via serial-port
  HandleCMDFromComputer();
}
