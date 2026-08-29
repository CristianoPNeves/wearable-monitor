# 🩺 Wearable Monitor PI6 - Sistema Vestível de Telemetria e Detecção de Quedas

Sistema IoT vestível (*smartwatch/wearable*) autônomo e de baixo custo, desenvolvido para o monitoramento contínuo de sinais vitais e detecção precoce de acidentes mecânicos (quedas) em idosos ou pessoas em situação de vulnerabilidade motora.

> **Projeto Integrador 6 (PI6) — Universidade Virtual do Estado de São Paulo (UNIVESP)**  
> **Grupo 10**

---

## 🚀 Principais Funcionalidades

- **Detecção Inercial de Quedas:** Análise contínua de aceleração vetorial e velocidade angular para identificação de padrões de impacto e desnível.
- **Janela de Cancelamento (15s):** Temporizador de segurança visual no display OLED e sonoro via app para prevenir o envio de falsos positivos.
- **Botão de Pânico Integrado:** Disparo manual imediato de socorro por pressão contínua do botão táctil.
- **Telemetria de Sinais Vitais:** Leitura óptica de frequência cardíaca (BPM) e percentual de bateria.
- **Geolocalização para Resgate:** Aquisição contínua de coordenadas (Latitude e Longitude) via GPS.
- **Notificação Automática via Telegram Bot:** Transmissão instantânea de alertas multimídia estruturados com hiperlink direto para rota no Google Maps.
- **Acessibilidade por Voz (TTS):** Sintetização nativa de voz em português no aplicativo móvel.

---

## 🛠️ Tecnologias e Arquitetura

### Hardware Embarcado
- **Microcontrolador:** ESP32 NodeMCU / DevKit (Dual-Core, Wi-Fi e Bluetooth 4.2 BLE)
- **Sensor Inercial:** MPU-6050 (Acelerômetro e Giroscópio de 3 eixos)
- **Sensor Biométrico:** MAX30105 / MAX30102 (Frequência Cardíaca Óptica / Oximetria)
- **Display Local:** OLED SSD1306 0.96" (I2C, 128x64 pixels)
- **Módulo de Posicionamento:** GPS NEO-6M (Comunicação UART Serial)
- **Botão de Controle:** Push-button táctil com resistor pull-up interno e debouncing

### Software e Nuvem
- **Aplicativo Mobile:** Flutter & Dart (Comunicação híbrida BLE com fallback para Firebase)
- **Backend / Persistência:** Firebase Realtime Database (Sincronização JSON NoSQL)
- **Mensageria de Emergência:** Telegram Bot API (Requisições HTTP POST com payload HTML)
- **Interface Gráfica & Gráficos:** `fl_chart`, `google_fonts` e `flutter_tts`

---

## 📱 Fluxo de Comunicação do Sistema
