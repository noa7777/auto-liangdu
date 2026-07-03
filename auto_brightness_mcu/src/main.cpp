#include <Arduino.h>
#include <Wire.h>
#include <BH1750.h>
#include <ESP8266WiFi.h>
#include <WiFiUdp.h>

const char *ssid = "wifi名";
const char *password = "wifi密码";

BH1750 lightMeter;
WiFiUDP udp;

void setup() {
  Serial.begin(115200);
  Wire.begin();
  lightMeter.begin();
  
  WiFi.mode(WIFI_STA);
  WiFi.setAutoConnect(true);
  WiFi.begin(ssid, password);
  
  Serial.println("Connecting to WiFi...");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi connected");
  Serial.print("IP address: ");
  Serial.println(WiFi.localIP());
}

void loop() {
  float lux = lightMeter.readLightLevel();
  Serial.print("Lux: ");
  Serial.println((int)lux);
  
  udp.beginPacket("255.255.255.255", 8888);
  udp.print((int)lux);
  udp.endPacket();
  
  delay(1000);
}
