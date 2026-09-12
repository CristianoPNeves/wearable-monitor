import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const WearableMonitorApp());
}

class WearableMonitorApp extends StatelessWidget {
  const WearableMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wearable Monitor - UNIVESP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.tealAccent,
          secondary: Colors.redAccent,
          surface: Color(0xFF1E1E1E),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF1E1E1E),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 4,
        ),
        useMaterial3: true,
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
  // --- CREDENCIAIS TELEGRAM BOT API ---
  // Insira aqui o seu token e chat id que já funcionaram nos testes:
  final String _telegramBotToken =
      "8345658232:AAFMliDp9qEcaviC9PSX7D6XCUXQxAUhjQA";
  final String _telegramChatId = "8722502677I";

  // --- ESTADOS DE TELEMETRIA ---
  int _bpm = 0;
  String _statusGeral = "Monitoramento Ativo";
  int _bateria = 100;
  double _latitude = -23.550520;
  double _longitude = -46.633308;
  String _origemDados = "Aguardando canal...";
  bool _alertaEmergencia = false;
  String _tipoEmergencia = "";

  // Histórico de BPM carregado do Firebase (historico_bpm)
  final List<FlSpot> _historicoBpm = [];

  // Conexões Firebase
  StreamSubscription<DatabaseEvent>? _firebaseSub;
  StreamSubscription<DatabaseEvent>? _historicoSub;

  // Bluetooth Low Energy
  BluetoothDevice? _dispositivoBle;
  StreamSubscription<BluetoothConnectionState>? _bleConnSub;
  StreamSubscription<List<int>>? _bleDataSub;
  bool _estaConectadoBle = false;

  // Alertas
  final FlutterTts _flutterTts = FlutterTts();
  DateTime _ultimoAlertaDisparado =
      DateTime.now().subtract(const Duration(minutes: 5));

  @override
  void initState() {
    super.initState();
    _iniciarTts();
    _iniciarFirebase();
    _iniciarOuvinteHistoricoFirebase();
  }

  @override
  void dispose() {
    _firebaseSub?.cancel();
    _historicoSub?.cancel();
    _bleConnSub?.cancel();
    _bleDataSub?.cancel();
    _dispositivoBle?.disconnect();
    _flutterTts.stop();
    super.dispose();
  }

  void _iniciarTts() async {
    await _flutterTts.setLanguage("pt-BR");
    await _flutterTts.setPitch(1.0);
    await _flutterTts.setSpeechRate(0.5);
  }

  // --- ESCUTA EM TEMPO REAL: NÓ "dados" ---
  void _iniciarFirebase() {
    try {
      DatabaseReference ref = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: "https://monitor-univesp-default-rtdb.firebaseio.com/",
      ).ref("dados");

      _firebaseSub = ref.onValue.listen((DatabaseEvent event) {
        if (!_estaConectadoBle && event.snapshot.value != null) {
          setState(() => _origemDados = "Firebase RTDB (Nuvem)");
          final raw = event.snapshot.value;
          if (raw is Map) {
            _processarEntrada(Map<String, dynamic>.from(
              raw.map((k, v) => MapEntry(k.toString(), v)),
            ));
          } else if (raw is String) {
            try {
              _processarEntrada(jsonDecode(raw));
            } catch (_) {}
          }
        }
      }, onError: (err) {
        debugPrint("[Firebase RTDB] Erro listener dados: $err");
      });
    } catch (e) {
      debugPrint("[Firebase RTDB] Erro de inicialização: $e");
    }
  }

  // --- LEITURA PERSISTIDA DO HISTÓRICO: NÓ "historico_bpm" ---
  void _iniciarOuvinteHistoricoFirebase() {
    try {
      Query queryHistorico = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: "https://monitor-univesp-default-rtdb.firebaseio.com/",
      ).ref("historico_bpm").limitToLast(20);

      _historicoSub = queryHistorico.onValue.listen((DatabaseEvent event) {
        if (event.snapshot.value != null) {
          final dynamic raw = event.snapshot.value;
          List<FlSpot> novosPontos = [];
          double index = 0;

          if (raw is Map) {
            // Ordena chaves cronologicamente
            final sortedKeys = raw.keys.toList()..sort();
            for (var key in sortedKeys) {
              var item = raw[key];
              double valorBpm = 0.0;
              if (item is Map) {
                valorBpm =
                    double.tryParse(item["bpm"]?.toString() ?? "0") ?? 0.0;
              } else {
                valorBpm = double.tryParse(item.toString()) ?? 0.0;
              }

              if (valorBpm > 0) {
                novosPontos.add(FlSpot(index, valorBpm));
                index++;
              }
            }
          } else if (raw is List) {
            for (var item in raw) {
              if (item != null) {
                double valorBpm = double.tryParse(item.toString()) ?? 0.0;
                if (valorBpm > 0) {
                  novosPontos.add(FlSpot(index, valorBpm));
                  index++;
                }
              }
            }
          }

          if (novosPontos.isNotEmpty) {
            setState(() {
              _historicoBpm.clear();
              _historicoBpm.addAll(novosPontos);
            });
          }
        }
      }, onError: (err) {
        debugPrint("[Firebase Historico] Erro: $err");
      });
    } catch (e) {
      debugPrint("[Firebase Historico] Falha na inicialização: $e");
    }
  }

  // --- BLUETOOTH LOW ENERGY ---
  void _abrirModalBle() async {
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
    }
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(16),
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Dispositivos Bluetooth",
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const Divider(color: Colors.white24),
            Expanded(
              child: StreamBuilder<List<ScanResult>>(
                stream: FlutterBluePlus.scanResults,
                builder: (context, snapshot) {
                  final results = snapshot.data ?? [];
                  if (results.isEmpty) {
                    return const Center(
                      child: Text("Buscando ESP32...",
                          style: TextStyle(color: Colors.grey)),
                    );
                  }
                  return ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, i) {
                      final item = results[i];
                      final name = item.device.platformName.isNotEmpty
                          ? item.device.platformName
                          : "Dispositivo BLE";
                      return ListTile(
                        leading: const Icon(Icons.bluetooth,
                            color: Colors.tealAccent),
                        title: Text(name),
                        subtitle: Text(item.device.remoteId.str),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.teal),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _conectarBle(item.device);
                          },
                          child: const Text("Conectar"),
                        ),
                      );
                    },
                  );
                },
              ),
            )
          ],
        ),
      ),
    ).whenComplete(() => FlutterBluePlus.stopScan());
  }

  Future<void> _conectarBle(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    try {
      await device.connect(autoConnect: false);
      _dispositivoBle = device;

      _bleConnSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.connected) {
          setState(() {
            _estaConectadoBle = true;
            _origemDados = "Bluetooth Local (ESP32)";
          });
          _escutarServicosBle(device);
        } else if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            _estaConectadoBle = false;
            _origemDados = "Firebase RTDB (Nuvem)";
          });
        }
      });
    } catch (e) {
      debugPrint("[BLE] Falha ao conectar: $e");
    }
  }

  Future<void> _escutarServicosBle(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (var s in services) {
      for (var c in s.characteristics) {
        if (c.properties.notify || c.properties.indicate) {
          await c.setNotifyValue(true);
          _bleDataSub = c.onValueReceived.listen((data) {
            try {
              _processarEntrada(jsonDecode(utf8.decode(data)));
            } catch (_) {}
          });
        }
      }
    }
  }

  // --- PROCESSAMENTO DE TELEMETRIA E CRITÉRIOS DE EMERGÊNCIA (60 - 100 BPM) ---
  void _processarEntrada(Map<String, dynamic> mapa) {
    int bpmLido = int.tryParse(mapa["bpm"]?.toString() ?? "0") ?? 0;
    String statusLido = mapa["status"]?.toString() ?? "OK";
    int batLida = int.tryParse(mapa["bat"]?.toString() ?? "100") ?? 100;
    double lat = double.tryParse(mapa["lat"]?.toString() ?? "0") ?? _latitude;
    double lng = double.tryParse(mapa["lng"]?.toString() ?? "0") ?? _longitude;

    String stUpper = statusLido.toUpperCase();
    bool ehQueda = stUpper.contains("QUEDA") || stUpper.contains("FALL");
    bool ehPanico = stUpper.contains("PANICO") ||
        stUpper.contains("PANIC") ||
        stUpper.contains("SOS");

    String motivo = "";
    if (ehPanico) {
      motivo = "BOTÃO DE PÂNICO ACIONADO";
    } else if (ehQueda) {
      motivo = "QUEDA DETECTADA";
    } else if (bpmLido > 0 && bpmLido < 60) {
      motivo = "BRADICARDIA DETECTADA ($bpmLido BPM)";
    } else if (bpmLido > 100) {
      motivo = "TAQUICARDIA DETECTADA ($bpmLido BPM)";
    }

    if (motivo.isNotEmpty) {
      _dispararProtocoloEmergencia(motivo, bpmLido, lat, lng);
    } else {
      setState(() {
        _alertaEmergencia = false;
        _tipoEmergencia = "";
      });
    }

    setState(() {
      _bpm = bpmLido;
      _statusGeral = statusLido;
      _bateria = batLida;
      _latitude = lat;
      _longitude = lng;
    });
  }

  void _dispararProtocoloEmergencia(
      String motivo, int bpm, double lat, double lng) {
    setState(() {
      _alertaEmergencia = true;
      _tipoEmergencia = motivo;
    });

    if (DateTime.now().difference(_ultimoAlertaDisparado).inSeconds > 15) {
      _ultimoAlertaDisparado = DateTime.now();
      _vibrarDispositivo();
      _flutterTts.speak("Atenção! Alerta de emergência: $motivo!");
      _enviarAlertaTelegram(motivo, bpm, lat, lng);
    }
  }

  void _vibrarDispositivo() async {
    try {
      for (int i = 0; i < 4; i++) {
        Vibration.vibrate(duration: 800);
        await Future.delayed(const Duration(milliseconds: 1000));
      }
    } catch (e) {
      debugPrint("[Vibrator] Falha: $e");
    }
  }

  // --- ENVIO TELEGRAM BOT API ---
  Future<void> _enviarAlertaTelegram(
      String motivo, int bpm, double lat, double lng) async {
    if (_telegramBotToken.contains("SEU_TELEGRAM") ||
        _telegramChatId.contains("SEU_TELEGRAM")) {
      debugPrint("⚠️ [Telegram] Credenciais não preenchidas.");
      return;
    }

    final String mapsUrl =
        "https://www.google.com/maps/search/?api=1&query=$lat,$lng";
    final String mensagem = "🚨 ALERTA DE EMERGÊNCIA - WEARABLE\n\n"
        "⚠️ Ocorrência: $motivo\n"
        "❤️ Frequência Cardíaca: $bpm BPM\n"
        "🔋 Bateria: $_bateria%\n"
        "📍 Coordenadas: $lat, $lng\n\n"
        "🗺️ Link Google Maps:\n$mapsUrl";

    try {
      final url = Uri.parse(
          "https://api.telegram.org/bot$_telegramBotToken/sendMessage");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "chat_id": _telegramChatId,
          "text": mensagem,
        }),
      );
      debugPrint("[Telegram Status]: ${response.statusCode}");
    } catch (e) {
      debugPrint("[Telegram Erro]: $e");
    }
  }

  Future<void> _abrirMapa() async {
    final Uri url = Uri.parse(
        "geo:$_latitude,$_longitude?q=$_latitude,$_longitude(Posicao+Wearable)");
    if (!await launchUrl(url)) {
      await launchUrl(
        Uri.parse(
            "https://www.google.com/maps/search/?api=1&query=$_latitude,$_longitude"),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  // --- INTERFACE VISUAL (PRESERVADA 100%) ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Monitoramento Wearable",
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: Icon(
              _estaConectadoBle ? Icons.bluetooth_connected : Icons.bluetooth,
              color: _estaConectadoBle ? Colors.tealAccent : Colors.white70,
            ),
            tooltip: _estaConectadoBle ? "Desconectar BLE" : "Buscar Bluetooth",
            onPressed: () {
              if (_estaConectadoBle) {
                _dispositivoBle?.disconnect();
              } else {
                _abrirModalBle();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.vibration, color: Colors.deepOrangeAccent),
            tooltip: "Testar Vibração",
            onPressed: _vibrarDispositivo,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Banner de Alerta Crítico (Pânico / Queda / BPM Fora da Faixa)
            if (_alertaEmergencia)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.red.withOpacity(0.5),
                        blurRadius: 10,
                        spreadRadius: 2)
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.white, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "EMERGÊNCIA DETECTADA",
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15),
                          ),
                          Text(_tipoEmergencia,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.red.shade900,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                      ),
                      onPressed: () {
                        setState(() {
                          _alertaEmergencia = false;
                          _tipoEmergencia = "";
                        });
                      },
                      child: const Text("Dispensar",
                          style: TextStyle(fontSize: 12)),
                    )
                  ],
                ),
              ),

            // Card Canal Ativo & Bateria
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      _estaConectadoBle
                          ? Icons.bluetooth_audio
                          : Icons.cloud_queue,
                      color: _estaConectadoBle
                          ? Colors.tealAccent
                          : Colors.cyanAccent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("Canal Ativo",
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 11)),
                          Text(_origemDados,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          _bateria > 20
                              ? Icons.battery_charging_full
                              : Icons.battery_alert,
                          color: _bateria > 20
                              ? Colors.greenAccent
                              : Colors.redAccent,
                        ),
                        const SizedBox(width: 4),
                        Text("$_bateria%",
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    )
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Card Frequência Cardíaca com Gráfico Persistente Ampliado
            Card(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        const Icon(Icons.favorite,
                            color: Colors.redAccent, size: 28),
                        const SizedBox(width: 8),
                        Text(
                          "$_bpm",
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -1,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          "BPM",
                          style: TextStyle(
                              color: Colors.white54,
                              fontSize: 15,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 200,
                      width: double.infinity,
                      child: _historicoBpm.length < 2
                          ? const Center(
                              child: Text(
                                "Carregando histórico do Firebase...",
                                style: TextStyle(
                                    color: Colors.white38, fontSize: 13),
                              ),
                            )
                          : LineChart(
                              LineChartData(
                                minY: 40,
                                maxY:
                                    (_bpm > 120) ? (_bpm + 25).toDouble() : 150,
                                minX: _historicoBpm.first.x,
                                maxX: _historicoBpm.last.x,
                                clipData: const FlClipData.none(),
                                gridData: FlGridData(
                                  show: true,
                                  drawVerticalLine: false,
                                  horizontalInterval: 20,
                                  getDrawingHorizontalLine: (value) => FlLine(
                                    color: Colors.white10,
                                    strokeWidth: 1,
                                    dashArray: [4, 4],
                                  ),
                                ),
                                titlesData: FlTitlesData(
                                  topTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  rightTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  bottomTitles: const AxisTitles(
                                      sideTitles:
                                          SideTitles(showTitles: false)),
                                  leftTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: 32,
                                      interval: 20,
                                      getTitlesWidget: (value, meta) {
                                        return Text(
                                          value.toInt().toString(),
                                          style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                borderData: FlBorderData(show: false),
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: _historicoBpm,
                                    isCurved: true,
                                    curveSmoothness: 0.2,
                                    color: Colors.redAccent,
                                    barWidth: 2.5,
                                    isStrokeCapRound: true,
                                    dotData: const FlDotData(show: false),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      color: Colors.redAccent.withOpacity(0.12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Card Condição Operacional
            Card(
              child: ListTile(
                dense: true,
                leading: Icon(
                  _alertaEmergencia
                      ? Icons.warning_amber_rounded
                      : Icons.health_and_safety,
                  color:
                      _alertaEmergencia ? Colors.redAccent : Colors.tealAccent,
                  size: 30,
                ),
                title: const Text("Condição Operacional",
                    style: TextStyle(color: Colors.white54, fontSize: 11)),
                subtitle: Text(
                  _statusGeral,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: _alertaEmergencia ? Colors.redAccent : Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Card Localização Geográfica
            Card(
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.location_on,
                    color: Colors.lightBlueAccent, size: 30),
                title: const Text("Rastreamento Geográfico",
                    style: TextStyle(color: Colors.white54, fontSize: 11)),
                subtitle: Text("Lat: $_latitude | Lng: $_longitude",
                    style: const TextStyle(fontSize: 12)),
                trailing: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade800,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  onPressed: _abrirMapa,
                  icon: const Icon(Icons.map, size: 15),
                  label: const Text("Abrir", style: TextStyle(fontSize: 12)),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Botão Manual de Disparo de Pânico (SOS)
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade800,
                  foregroundColor: Colors.white,
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.emergency, size: 22),
                label: const Text(
                  "ACIONAR PÂNICO (SOS MANUAL)",
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                onPressed: () {
                  _dispararProtocoloEmergencia(
                      "PÂNICO MANUAL", _bpm, _latitude, _longitude);
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
