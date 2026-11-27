import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const FlightTrackerApp());

class FlightTrackerApp extends StatelessWidget {
  const FlightTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '플라이트 트래커',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0F0D),
        colorScheme: const ColorScheme.dark(
          primary: Colors.greenAccent,
          secondary: Colors.tealAccent,
        ),
      ),
      home: const TrackerHomePage(),
    );
  }
}

class TrackerHomePage extends StatefulWidget {
  const TrackerHomePage({super.key});

  @override
  State<TrackerHomePage> createState() => _TrackerHomePageState();
}

class _TrackerHomePageState extends State<TrackerHomePage> {
  final _latCtrl = TextEditingController(text: "37.5665");
  final _lonCtrl = TextEditingController(text: "126.9780");

  int _radiusNm = 50;
  bool _usePhoneGps = true;
  bool _autoSync = false;
  bool _isConnected = false;
  bool _isBusy = false;

  Timer? _syncTimer;
  BluetoothDevice? _targetDevice;
  BluetoothCharacteristic? _txChar;

  String _statusMsg = "T-Display S3 전원을 켜고 연결을 눌러주세요.";
  List> _detectedPlanes = [];

  static const String targetDeviceName = "Flight-Tracker-S3";
  static const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String charUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  double _calcDistanceKm(double lat1, double lon1, double lat2, double lon2) {
    final dLat = (lat2 - lat1) * 111.0;
    final dLon = (lon2 - lon1) * 111.0 * cos(lat1 * pi / 180.0);
    return sqrt(dLat * dLat + dLon * dLon);
  }

  Future<void> _updatePhoneLocation() async {
    if (!_usePhoneGps) return;
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) return;
      }

      Position pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      setState(() {
        _latCtrl.text = pos.latitude.toStringAsFixed(4);
        _lonCtrl.text = pos.longitude.toStringAsFixed(4);
      });
    } catch (_) {}
  }

  Future<bool> _connectToS3() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    setState(() {
      _isBusy = true;
      _statusMsg = "주변에서 '$targetDeviceName' 검색 중...";
    });

    try {
      BluetoothDevice? found;
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));

      await for (final results in FlutterBluePlus.scanResults) {
        for (final r in results) {
          if (r.device.platformName == targetDeviceName) {
            found = r.device;
            break;
          }
        }
        if (found != null) break;
      }
      await FlutterBluePlus.stopScan();

      if (found == null) {
        setState(() {
          _statusMsg = "기기를 찾지 못했습니다. 블루투스와 보드 전원을 확인하세요.";
          _isBusy = false;
        });
        return false;
      }

      setState(() => _statusMsg = "연결 중...");
      await found.connect(autoConnect: false);
      await found.requestMtu(512);

      found.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            _isConnected = false;
            _txChar = null;
            _statusMsg = "BLE 연결이 끊어졌습니다.";
          });
        }
      });

      final services = await found.discoverServices();
      final srv = services.firstWhere((s) => s.uuid.toString() == serviceUuid);
      final chr = srv.characteristics.firstWhere((c) => c.uuid.toString() == charUuid);

      setState(() {
        _targetDevice = found;
        _txChar = chr;
        _isConnected = true;
        _isBusy = false;
        _statusMsg = "연결 완료! ($targetDeviceName)";
      });
      return true;
    } catch (e) {
      setState(() {
        _isConnected = false;
        _isBusy = false;
        _statusMsg = "연결 오류: $e";
      });
      return false;
    }
  }

  Future<void> _fetchAndSendRadarData() async {
    if (_txChar == null || !_isConnected) {
      bool ok = await _connectToS3();
      if (!ok) return;
    }

    try {
      if (_usePhoneGps) {
        await _updatePhoneLocation();
      }

      final myLat = double.parse(_latCtrl.text.trim());
      final myLon = double.parse(_lonCtrl.text.trim());
      final maxKm = _radiusNm * 1.852;

      final url = Uri.parse("https://api.adsb.lol/v2/point/$myLat/$myLon/$_radiusNm");
      final res = await http.get(url).timeout(const Duration(seconds: 6));

      if (res.statusCode != 200) {
        setState(() => _statusMsg = "API 서버 응답 오류 (${res.statusCode})");
        return;
      }

      final jsonBody = jsonDecode(res.body);
      final acList = (jsonBody["ac"] as List?) ?? [];

      double minDist = 9999.0;
      String nearestFlight = "NONE";
      int nearestAlt = 0;
      int nearestSpd = 0;

      final parsedPlanes = >[];

      for (final ac in acList) {
        if (ac["lat"] == null || ac["lon"] == null) continue;

        final lat = (ac["lat"] as num).toDouble();
        final lon = (ac["lon"] as num).toDouble();
        final dist = _calcDistanceKm(myLat, myLon, lat, lon);

        if (dist <= maxKm) {
          final dyKm = (lat - myLat) * 111.0;
          final dxKm = (lon - myLon) * 111.0 * cos(myLat * pi / 180.0);

          final rx = (dxKm / maxKm).clamp(-1.0, 1.0);
          final ry = (dyKm / maxKm).clamp(-1.0, 1.0);

          String cs = (ac["flight"] ?? "").toString().trim();
          if (cs.isEmpty) cs = "UNK";

          final trk = ac["track"] != null ? (ac["track"] as num).toDouble() : -1.0;
          final alt = ac["alt_baro"] is num ? (ac["alt_baro"] as num).toInt() : 0;
          final spd = ac["gs"] is num ? (ac["gs"] as num).toInt() : 0;

          parsedPlanes.add({
            "cs": cs,
            "rx": rx.toStringAsFixed(2),
            "ry": ry.toStringAsFixed(2),
            "trk": trk.toStringAsFixed(0),
            "alt": alt,
            "spd": spd,
            "dist": dist,
          });

          if (dist < minDist) {
            minDist = dist;
            nearestFlight = cs;
            nearestAlt = alt;
            nearestSpd = spd;
          }
        }
      }

      parsedPlanes.sort((a, b) => (a["dist"] as double).compareTo(b["dist"] as double));
      final topList = parsedPlanes.take(14).toList();

      final itemsStr = topList.map((p) {
        final dStr = (p["dist"] as double).toStringAsFixed(1);
        return "${p['cs']},${p['rx']},${p['ry']},${p['trk']},${p['alt']},${p['spd']},$dStr";
      }).join(";");

      final distHeader = parsedPlanes.isEmpty ? "0.0" : minDist.toStringAsFixed(1);
      final packet = "RADAR|${maxKm.round()}|$nearestFlight|$distHeader|$nearestAlt|$nearestSpd|$itemsStr";

      await _txChar!.write(utf8.encode(packet), withoutResponse: false);

      setState(() {
        _detectedPlanes = parsedPlanes;
        _statusMsg = "전송 완료: 반경 ${maxKm.round()}km 내 ${parsedPlanes.length}대 포착";
      });
    } catch (e) {
      setState(() => _statusMsg = "전송 중 오류: $e");
    }
  }

  void _toggleAutoSync(bool enabled) {
    setState(() => _autoSync = enabled);
    _syncTimer?.cancel();
    if (enabled) {
      _fetchAndSendRadarData();
      _syncTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        _fetchAndSendRadarData();
      });
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _targetDevice?.disconnect();
    _latCtrl.dispose();
    _lonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("플라이트 트래커"),
        backgroundColor: const Color(0xFF111C18),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Icon(
              _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: _isConnected ? Colors.greenAccent : Colors.grey,
            ),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("내 스마트폰 GPS 위치 자동 사용"),
              subtitle: Text(_usePhoneGps ? "이동 시 현재 위치 기준 자동 추적" : "아래 입력된 고정 좌표 사용"),
              value: _usePhoneGps,
              onChanged: (v) => setState(() => _usePhoneGps = v),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latCtrl,
                    enabled: !_usePhoneGps,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: "위도 (LAT)", border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _lonCtrl,
                    enabled: !_usePhoneGps,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: "경도 (LON)", border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 10, label: Text("18km (10NM)")),
                ButtonSegment(value: 25, label: Text("46km (25NM)")),
                ButtonSegment(value: 50, label: Text("92km (50NM)")),
              ],
              selected: {_radiusNm},
              onSelectionChanged: (s) {
                setState(() => _radiusNm = s.first);
                if (_isConnected) _fetchAndSendRadarData();
              },
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("10초마다 실시간 자동 전송"),
              value: _autoSync,
              onChanged: _toggleAutoSync,
            ),
            ElevatedButton.icon(
              onPressed: _isBusy ? null : _fetchAndSendRadarData,
              icon: const Icon(Icons.radar),
              label: Text(_isConnected ? "지금 주변 항공기 조회 및 전송" : "S3 연결 후 즉시 전송"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF14221D),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
              ),
              child: Text(_statusMsg, style: const TextStyle(color: Colors.greenAccent, fontSize: 13)),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: _detectedPlanes.length,
                itemBuilder: (context, idx) {
                  final p = _detectedPlanes[idx];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.flight, color: Colors.greenAccent, size: 20),
                    title: Text("${p['cs']}  (${(p['dist'] as double).toStringAsFixed(1)} km)"),
                    subtitle: Text("고도: ${p['alt']} ft  |  속도: ${p['spd']} kt  |  방향: ${p['trk']}°"),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
