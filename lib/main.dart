import 'dart:async';
import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WearableMonitorApp());
}

class WearableMonitorApp extends StatelessWidget {
  const WearableMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Wearable Monitor PI6',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          surface: Color(0xFF1E293B),
          error: Color(0xFFEF4444),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Identificadores BLE e Firebase
  final String targetDeviceName = "Wearable-PI6";
  final String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String charUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  final String firebaseUrl =
      "https://monitor-univesp-default-rtdb.firebaseio.com/dados.json?auth=zdIqfhPcJWt5YUKGL17yeeqM23fwRkIMVdGRAjTh";

  final String firebaseHistoryUrl =
      "https://monitor-univesp-default-rtdb.firebaseio.com/historico_bpm.json?auth=zdIqfhPcJWt5YUKGL17yeeqM23fwRkIMVdGRAjTh";

  // =========================================================================
  // CREDENCIAIS DO TELEGRAM BOT (100% Gratuito)
  // =========================================================================
  final String telegramBotToken =
      "8345658232:AAFMliDp9qEcaviC9PSX7D6XCUXQxAUhjQA";
  final String telegramChatId = "8722502677";

  BluetoothDevice? connectedDevice;
  StreamSubscription? scanSubscription;
  StreamSubscription? bleValueSubscription;
  Timer? firebasePollingTimer;
  Timer? historyPollingTimer;

  final FlutterTts flutterTts = FlutterTts();

  bool isScanning = false;
  bool isBleConnected = false;
  String connectionSource = "Aguardando...";

  int bpm = 0;
  int battery = 100;
  String status = "Sistema OK";
  String? latitude;
  String? longitude;

  String _ultimoStatusFalado = "Sistema OK";
  List<FlSpot> bpmHistorySpots = [];
  DateTime _ultimoRegistroHistorico =
      DateTime.now().subtract(const Duration(minutes: 1));

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _configurarTTS();

    firebasePollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!isBleConnected) {
        _fetchFirebaseData();
      }
    });

    _fetchBpmHistory();
    historyPollingTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      _fetchBpmHistory();
    });
  }

  @override
  void dispose() {
    scanSubscription?.cancel();
    bleValueSubscription?.cancel();
    firebasePollingTimer?.cancel();
    historyPollingTimer?.cancel();
    connectedDevice?.disconnect();
    flutterTts.stop();
    super.dispose();
  }

  Future<void> _configurarTTS() async {
    try {
      await flutterTts.awaitSpeakCompletion(true);
      await flutterTts.setVolume(1.0);
      await flutterTts.setSpeechRate(0.5);
      await flutterTts.setPitch(1.0);

      var isAvailable = await flutterTts.isLanguageAvailable("pt-BR");
      if (isAvailable == true) {
        await flutterTts.setLanguage("pt-BR");
      }
    } catch (e) {
      debugPrint("Erro ao configurar TTS: $e");
    }
  }

  Future<void> _falarTexto(String texto) async {
    try {
      await flutterTts.stop();
      await flutterTts.speak(texto);
    } catch (e) {
      debugPrint("Erro ao emitir voz: $e");
    }
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.locationWhenInUse,
    ].request();
  }

  // Envio de alerta formatado em HTML ao Telegram
  Future<void> _enviarAlertaTelegram({
    required String tipoAlerta,
    required int bpmAtual,
    required int bateria,
    String? lat,
    String? lng,
  }) async {
    final String latitudeVal = lat ?? "-23.550520";
    final String longitudeVal = lng ?? "-46.633308";
    final String mapsLink =
        "https://www.google.com/maps?q=$latitudeVal,$longitudeVal";

    final String mensagem = """
🚨 <b>ALERTA DE EMERGÊNCIA - WEARABLE PI6</b> 🚨

⚠️ <b>Evento:</b> $tipoAlerta
💓 <b>Batimentos:</b> $bpmAtual BPM
🔋 <b>Bateria:</b> $bateria%
📍 <b>Localização GPS:</b>
<a href="$mapsLink">Abrir no Google Maps</a>
""";

    final Uri url =
        Uri.parse("https://api.telegram.org/bot$telegramBotToken/sendMessage");

    try {
      debugPrint(
          "[Telegram] Enviando requisicao HTTP para o chat $telegramChatId...");

      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'chat_id': telegramChatId,
              'text': mensagem,
              'parse_mode': 'HTML',
              'disable_web_page_preview': false,
            }),
          )
          .timeout(const Duration(seconds: 8));

      debugPrint("[Telegram] Status Code: ${response.statusCode}");
      debugPrint("[Telegram] Resposta: ${response.body}");

      if (response.statusCode == 200) {
        debugPrint("[Telegram] Mensagem entregue com sucesso!");
      }
    } catch (e) {
      debugPrint("[Telegram] Erro na requisicao: $e");
    }
  }

  // Cancelamento de Falso Positivo (Híbrido: BLE + Firebase)
  Future<void> _cancelarAlerta() async {
    try {
      if (isBleConnected && connectedDevice != null) {
        List<BluetoothService> services =
            await connectedDevice!.discoverServices();
        for (var service in services) {
          if (service.uuid.toString().toLowerCase() ==
              serviceUuid.toLowerCase()) {
            for (var char in service.characteristics) {
              if (char.uuid.toString().toLowerCase() ==
                  charUuid.toLowerCase()) {
                await char.write(utf8.encode("CANCELAR"),
                    withoutResponse: false);
                debugPrint("[BLE] Comando CANCELAR enviado ao relogio.");
              }
            }
          }
        }
      }

      Map<String, dynamic> resetData = {
        'status': 'Sistema OK',
        'bpm': bpm,
        'bat': battery,
        'lat': latitude ?? "-23.550520",
        'lng': longitude ?? "-46.633308",
      };

      String jsonPayload = jsonEncode(resetData);
      await http.put(
        Uri.parse(firebaseUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(jsonPayload),
      );

      setState(() {
        status = "Sistema OK";
      });

      _falarTexto("Alarme cancelado. Sistema em estado normal.");
    } catch (e) {
      debugPrint("Erro ao cancelar alerta: $e");
    }
  }

  Future<void> _fetchFirebaseData() async {
    try {
      final response = await http
          .get(Uri.parse(firebaseUrl))
          .timeout(const Duration(seconds: 2));

      if (response.statusCode == 200 &&
          response.body.isNotEmpty &&
          response.body != "null") {
        String raw = response.body;
        if (raw.startsWith('"') && raw.endsWith('"')) {
          raw = jsonDecode(raw);
        }
        Map<String, dynamic> data = (raw is Map)
            ? Map<String, dynamic>.from(raw as Map)
            : jsonDecode(raw);

        _updateState(data, source: "Nuvem (Firebase)");
      }
    } catch (_) {}
  }

  Future<void> _fetchBpmHistory() async {
    try {
      final response = await http
          .get(Uri.parse(firebaseHistoryUrl))
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200 &&
          response.body.isNotEmpty &&
          response.body != "null") {
        dynamic decoded = jsonDecode(response.body);
        List<double> values = [];

        if (decoded is Map) {
          decoded.forEach((key, val) {
            if (val is num && val > 30 && val < 220) {
              values.add(val.toDouble());
            }
          });
        } else if (decoded is List) {
          for (var item in decoded) {
            if (item is num && item > 30 && item < 220) {
              values.add(item.toDouble());
            }
          }
        }

        if (values.length > 15) {
          values = values.sublist(values.length - 15);
        }

        List<FlSpot> spots = [];
        for (int i = 0; i < values.length; i++) {
          spots.add(FlSpot(i.toDouble(), values[i]));
        }

        if (mounted) {
          setState(() {
            bpmHistorySpots = spots;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _forwardBleToFirebase(Map<String, dynamic> data) async {
    try {
      String jsonPayload = jsonEncode(data);
      await http.put(
        Uri.parse(firebaseUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(jsonPayload),
      );

      int currentBpm = data['bpm'] ?? 0;
      if (currentBpm > 40 && currentBpm < 220) {
        if (DateTime.now().difference(_ultimoRegistroHistorico).inSeconds >=
            30) {
          _ultimoRegistroHistorico = DateTime.now();

          await http.post(
            Uri.parse(firebaseHistoryUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(currentBpm),
          );
        }
      }
    } catch (e) {
      debugPrint("Erro ao encaminhar BLE -> Firebase: $e");
    }
  }

  void _startScanAndConnect() async {
    await _requestPermissions();

    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Ligue o Bluetooth do celular para parear.")),
        );
      }
      return;
    }

    setState(() => isScanning = true);

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidUsesFineLocation: true,
      );
    } catch (e) {
      debugPrint("Erro ao iniciar scan BLE: $e");
    }

    scanSubscription?.cancel();
    scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        String name = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName;

        String nameLower = name.toLowerCase();

        bool nameMatches = nameLower.contains("wearable");
        bool uuidMatches = r.advertisementData.serviceUuids.any(
            (u) => u.toString().toLowerCase() == serviceUuid.toLowerCase());

        if (nameMatches || uuidMatches) {
          await FlutterBluePlus.stopScan();
          setState(() => isScanning = false);
          _connectToDevice(r.device);
          break;
        }
      }
    });

    FlutterBluePlus.isScanning.listen((scanning) {
      if (!scanning && mounted) setState(() => isScanning = false);
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 8));
      setState(() {
        connectedDevice = device;
        isBleConnected = true;
        connectionSource = "BLE (Gateway Ativo)";
      });

      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() ==
            serviceUuid.toLowerCase()) {
          for (var char in service.characteristics) {
            if (char.uuid.toString().toLowerCase() == charUuid.toLowerCase()) {
              await char.setNotifyValue(true);
              bleValueSubscription?.cancel();
              bleValueSubscription = char.lastValueStream.listen((value) {
                if (value.isNotEmpty) {
                  try {
                    Map<String, dynamic> data = jsonDecode(utf8.decode(value));
                    _updateState(data, source: "BLE (Gateway Ativo)");
                    _forwardBleToFirebase(data);
                  } catch (_) {}
                }
              });
            }
          }
        }
      }
    } catch (e) {
      setState(() {
        isBleConnected = false;
        connectionSource = "Nuvem (Firebase)";
      });
    }
  }

  void _updateState(Map<String, dynamic> data, {required String source}) {
    String novoStatus = data['status'] ?? "Sistema OK";
    String novoStatusUpper = novoStatus.toUpperCase();

    if (novoStatus != _ultimoStatusFalado) {
      if (novoStatusUpper.contains("CONFIRMADA")) {
        _falarTexto(
            "Atencao! Alerta de emergencia! Queda confirmada detectada!");
        _enviarAlertaTelegram(
          tipoAlerta: "QUEDA CONFIRMADA",
          bpmAtual: data['bpm'] ?? bpm,
          bateria: data['bat'] ?? battery,
          lat: data['lat']?.toString(),
          lng: data['lng']?.toString(),
        );
      } else if (novoStatusUpper.contains("PANICO")) {
        _falarTexto("Alerta de emergencia! Botao de socorro acionado!");
        _enviarAlertaTelegram(
          tipoAlerta: "BOTÃO DE PÂNICO ACIONADO",
          bpmAtual: data['bpm'] ?? bpm,
          bateria: data['bat'] ?? battery,
          lat: data['lat']?.toString(),
          lng: data['lng']?.toString(),
        );
      } else if (novoStatusUpper.contains("PENDENTE")) {
        _falarTexto(
            "Possivel queda detectada. Pressione o botao para cancelar caso esteja bem.");
      }
      _ultimoStatusFalado = novoStatus;
    }

    setState(() {
      connectionSource = source;
      bpm = data['bpm'] ?? 0;
      status = novoStatus;
      battery = data['bat'] ?? 100;
      latitude = data['lat']?.toString();
      longitude = data['lng']?.toString();
    });
  }

  void _openGoogleMaps() async {
    if (latitude == null || longitude == null) return;

    final String lat = latitude!.trim();
    final String lng = longitude!.trim();

    final Uri mapsUrl =
        Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lng");

    try {
      if (await canLaunchUrl(mapsUrl)) {
        await launchUrl(mapsUrl, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint("Erro ao abrir Google Maps: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    bool isPending = status.toUpperCase().contains("PENDENTE");
    bool isConfirmed = status.toUpperCase().contains("CONFIRMADA") ||
        status.toUpperCase().contains("PANICO");
    bool isEmergency = isPending || isConfirmed;
    bool isConnected = isBleConnected || connectionSource.contains("Firebase");

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Wearable Monitor PI6',
              style:
                  GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 18),
            ),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isConnected ? const Color(0xFF10B981) : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  "Canal: $connectionSource",
                  style: GoogleFonts.inter(fontSize: 11, color: Colors.white60),
                ),
              ],
            )
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              isBleConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              color: isBleConnected ? const Color(0xFF38BDF8) : Colors.grey,
            ),
            onPressed: isScanning ? null : _startScanAndConnect,
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Banner de Status
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              decoration: BoxDecoration(
                color: isConfirmed
                    ? const Color(0xFFEF4444)
                    : (isPending
                        ? const Color(0xFFF59E0B)
                        : (isConnected
                            ? const Color(0xFF10B981).withValues(alpha: 0.15)
                            : const Color(0xFF334155))),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isConfirmed
                      ? Colors.redAccent
                      : (isPending
                          ? Colors.amber
                          : (isConnected
                              ? const Color(0xFF10B981)
                              : Colors.transparent)),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isEmergency
                        ? Icons.warning_amber_rounded
                        : (isConnected
                            ? Icons.check_circle_outline
                            : Icons.cloud_off),
                    color: isEmergency
                        ? Colors.white
                        : (isConnected ? const Color(0xFF10B981) : Colors.grey),
                    size: 28,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      isEmergency
                          ? "ALERTA: $status"
                          : (isConnected
                              ? "ESTADO: $status"
                              : "AGUARDANDO TELEMETRIA"),
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w700,
                        color: isEmergency ? Colors.white : Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // BOTÃO DE CANCELAMENTO DE FALSO POSITIVO
            if (isEmergency) ...[
              const SizedBox(height: 12),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: Colors.white, width: 1.5),
                  ),
                  elevation: 6,
                ),
                onPressed: _cancelarAlerta,
                icon: const Icon(Icons.cancel_outlined, size: 24),
                label: const Text(
                  "ESTOU BEM - CANCELAR ALARME",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ],

            const SizedBox(height: 12),

            // Teste de Voz
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF334155),
                foregroundColor: const Color(0xFF38BDF8),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF38BDF8), width: 1),
                ),
              ),
              onPressed: () {
                _falarTexto(
                    "Teste de audio do sistema Wearable Monitor PI6. Todos os modulos operacionais.");
              },
              icon: const Icon(Icons.volume_up, size: 20),
              label: const Text(
                "TESTAR VOZ / ALERTA SONORO",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),

            const SizedBox(height: 8),

            // Botão de Teste Manual do Telegram
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                _enviarAlertaTelegram(
                  tipoAlerta: "TESTE MANUAL DO APP",
                  bpmAtual: bpm > 0 ? bpm : 78,
                  bateria: battery,
                  lat: latitude,
                  lng: longitude,
                );
              },
              icon: const Icon(Icons.send, size: 20),
              label: const Text(
                "TESTAR DISPARO TELEGRAM",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),

            const SizedBox(height: 16),

            // Métricas (BPM e Bateria)
            Row(
              children: [
                Expanded(
                  child: _buildMetricCard(
                    title: "BATIMENTOS",
                    value: bpm > 0 ? "$bpm" : "--",
                    unit: "BPM",
                    icon: Icons.favorite,
                    iconColor: const Color(0xFFF43F5E),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildMetricCard(
                    title: "BATERIA",
                    value: "$battery",
                    unit: "%",
                    icon: battery > 20
                        ? Icons.battery_charging_full
                        : Icons.battery_alert,
                    iconColor: battery > 20
                        ? const Color(0xFF38BDF8)
                        : const Color(0xFFEF4444),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Geolocalização GPS
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.location_on,
                          color: Color(0xFF38BDF8), size: 22),
                      const SizedBox(width: 8),
                      Text(
                        "GEOLOCALIZACAO GPS",
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white60),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    latitude != null && longitude != null
                        ? "Lat: $latitude\nLng: $longitude"
                        : "Aguardando coordenadas GPS...",
                    style: GoogleFonts.jetBrainsMono(
                        fontSize: 13, color: Colors.white),
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      minimumSize: const Size(double.infinity, 42),
                    ),
                    onPressed: (latitude != null && longitude != null)
                        ? _openGoogleMaps
                        : null,
                    icon: const Icon(Icons.map, size: 18),
                    label: const Text("Abrir no Google Maps"),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Histórico de Batimentos
            _buildChartCard(),

            const SizedBox(height: 16),

            // Pareamento Manual BLE
            if (!isBleConnected)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF38BDF8),
                  side: const BorderSide(color: Color(0xFF38BDF8)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: isScanning ? null : _startScanAndConnect,
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(
                  isScanning
                      ? "Procurando Relogio..."
                      : "Parear Direto via Bluetooth (BLE)",
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChartCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.show_chart,
                      color: Color(0xFFF43F5E), size: 22),
                  const SizedBox(width: 8),
                  Text(
                    "HISTORICO DE BATIMENTOS",
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white60),
                  ),
                ],
              ),
              Text(
                "${bpmHistorySpots.length} leituras",
                style: GoogleFonts.inter(fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 160,
            child: bpmHistorySpots.isEmpty
                ? const Center(
                    child: Text(
                      "Aguardando registros no historico...",
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (value) => const FlLine(
                          color: Color(0xFF334155),
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 32,
                            getTitlesWidget: (value, meta) {
                              if (value % 20 == 0) {
                                return Text(
                                  value.toInt().toString(),
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                );
                              }
                              return const SizedBox.shrink();
                            },
                          ),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      minY: 40,
                      maxY: 160,
                      lineBarsData: [
                        LineChartBarData(
                          spots: bpmHistorySpots,
                          isCurved: true,
                          color: const Color(0xFFF43F5E),
                          barWidth: 3,
                          isStrokeCapRound: true,
                          dotData: const FlDotData(show: true),
                          belowBarData: BarAreaData(
                            show: true,
                            color:
                                const Color(0xFFF43F5E).withValues(alpha: 0.15),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String unit,
    required IconData icon,
    required Color iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white60),
              ),
              Icon(icon, color: iconColor, size: 20),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: GoogleFonts.inter(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: Colors.white),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white54),
              ),
            ],
          )
        ],
      ),
    );
  }
}
