import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    runApp(const WelcomeSahrulApp());
  }, (error, stack) {
    debugPrint('Uncaught (diredam, app tetap jalan): $error');
  });
}

// ============================================================
// PALET "FLIGHT DECK"
// ============================================================
const kBg       = Color(0xFF0A0A0F);
const kPanel    = Color(0xFF12121A);
const kPanel2   = Color(0xFF161622);
const kBorder   = Color(0xFF1E1E2E);
const kCyan     = Color(0xFF00E5FF);
const kGreen    = Color(0xFF69FF47);
const kYellow   = Color(0xFFFFD700);
const kRed      = Color(0xFFFF4747);
const kOrange   = Color(0xFFFF6B47);
const kPurple   = Color(0xFFB47FFF);
const kTeal     = Color(0xFF47FFEC);
const kWhite    = Colors.white;

Color mut(double o) => Colors.white.withOpacity(o);
Color glow(Color c, double o) => c.withOpacity(o);

// ============================================================
// APP ROOT
// ============================================================
class WelcomeSahrulApp extends StatelessWidget {
  const WelcomeSahrulApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Welcome Sahrul',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: kBg,
        fontFamily: 'sans-serif',
        colorScheme: ColorScheme.fromSeed(
          seedColor: kCyan,
          brightness: Brightness.dark,
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

// ============================================================
// SPLASH
// ============================================================
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..forward();
    Timer(const Duration(milliseconds: 1900), () {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 500),
            pageBuilder: (_, a, __) =>
                FadeTransition(opacity: a, child: const RootShell()),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: CurvedAnimation(parent: _c, curve: Curves.elasticOut),
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [kCyan, Color(0xFF0090A8)],
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: glow(kCyan, .45),
                        blurRadius: 36,
                        spreadRadius: 2),
                  ],
                ),
                child: const Icon(Icons.bolt_rounded,
                    color: Colors.black, size: 48),
              ),
            ),
            const SizedBox(height: 24),
            FadeTransition(
              opacity: _c,
              child: const Text('Welcome Sahrul',
                  style: TextStyle(
                      color: kWhite,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.5)),
            ),
            const SizedBox(height: 6),
            FadeTransition(
              opacity: _c,
              child: Text('DEVICE CONTROL CENTER',
                  style: TextStyle(
                      color: glow(kCyan, .7),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 3)),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ROOT SHELL — bottom nav 4 tab
// ============================================================
class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _idx = 0;
  final _pages = const [DashboardTab(), TweakTab(), ToolsTab(), AboutTab()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(bottom: false, child: _pages[_idx]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: kPanel,
          border: Border(top: BorderSide(color: kBorder, width: 1)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _navItem(0, Icons.dashboard_rounded, 'Dashboard'),
                _navItem(1, Icons.tune_rounded, 'Tweak'),
                _navItem(2, Icons.build_rounded, 'Tools'),
                _navItem(3, Icons.info_rounded, 'Tentang'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, String label) {
    final on = _idx == i;
    return GestureDetector(
      onTap: () => setState(() => _idx = i),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: on ? glow(kCyan, .12) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: on ? kCyan : mut(.4)),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    color: on ? kCyan : mut(.4))),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ROOT SERVICE
// ============================================================
class RootService {
  static bool? _root;

  static Future<bool> hasRoot() async {
    if (_root != null) return _root!;
    try {
      final r = await Process.run('su', ['-c', 'id'])
          .timeout(const Duration(seconds: 3));
      _root = r.exitCode == 0;
    } catch (_) {
      _root = false;
    }
    return _root!;
  }

  static Future<String> run(String cmd) async {
    try {
      if (!await hasRoot()) return 'NO_ROOT';
      final r = await Process.run('su', ['-c', cmd])
          .timeout(const Duration(seconds: 6));
      final out = r.stdout.toString().trim();
      final err = r.stderr.toString().trim();
      if (out.isEmpty && err.isNotEmpty) return 'NO_ROOT';
      return out;
    } catch (_) {
      return 'NO_ROOT';
    }
  }

  static bool bad(String v) => v == 'NO_ROOT' || v.trim().isEmpty;

  static Future<List<int>> cores() async {
    final r = await run(
        'ls -d /sys/devices/system/cpu/cpu[0-9]* | sed "s#.*/cpu##"');
    if (bad(r)) return [0];
    final c = r
        .split('\n')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toList();
    return c.isEmpty ? [0] : c;
  }

  static Future<Map<String, String>> device() async {
    try {
      final man = await run('getprop ro.product.manufacturer');
      final mod = await run('getprop ro.product.model');
      final ver = await run('getprop ro.build.version.release');
      final chip = await run('getprop ro.board.platform');
      String name;
      if (!bad(man) && !bad(mod)) {
        name = mod.toLowerCase().contains(man.toLowerCase()) ? mod : '$man $mod';
      } else if (!bad(mod)) {
        name = mod;
      } else {
        name = 'Perangkat Android';
      }
      return {
        'name': name,
        'android': bad(ver) ? '-' : 'Android $ver',
        'chipset': bad(chip) ? '-' : chip,
      };
    } catch (_) {
      return {'name': 'Perangkat Android', 'android': '-', 'chipset': '-'};
    }
  }

  // Refresh rate — kunci peak+min agar tidak adaptif (anti naik-turun)
  static Future<String> setRefresh(int hz) => run(
      'settings put system peak_refresh_rate $hz.0 && '
      'settings put system min_refresh_rate $hz.0 && '
      'settings put system user_refresh_rate $hz && echo OK');

  static Future<String> currentRefresh() async {
    final r = await run(
        'dumpsys SurfaceFlinger | grep -m1 "refresh-rate" | grep -o "[0-9]*\\.[0-9]*" | head -1');
    if (!bad(r)) {
      final p = double.tryParse(r);
      if (p != null) return p.round().toString();
    }
    final peak = await run('settings get system peak_refresh_rate');
    if (!bad(peak)) {
      final p = double.tryParse(peak);
      if (p != null) return p.round().toString();
    }
    return 'NO_ROOT';
  }

  static Future<String> clearRam() => run('''
    for pkg in \$(cmd package list packages -3 | cut -f2 -d:); do
      am force-stop \$pkg 2>/dev/null
    done
    echo OK''');

  static Future<Map<String, String>> ram() async {
    try {
      final t = await run(
          "cat /proc/meminfo | grep MemTotal | awk '{print \$2}'");
      final a = await run(
          "cat /proc/meminfo | grep MemAvailable | awk '{print \$2}'");
      final tMB = (int.tryParse(t) ?? 0) ~/ 1024;
      final aMB = (int.tryParse(a) ?? 0) ~/ 1024;
      if (tMB == 0) return {'total': '-', 'avail': '-', 'used': '-', 'pct': '0'};
      final u = tMB - aMB;
      return {
        'total': '$tMB MB',
        'avail': '$aMB MB',
        'used': '$u MB',
        'pct': '${((u / tMB) * 100).round()}',
      };
    } catch (_) {
      return {'total': '-', 'avail': '-', 'used': '-', 'pct': '0'};
    }
  }

  static Future<String> setGov(String g) async {
    final cs = await cores();
    final cmd = cs
        .map((i) =>
            'echo $g > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor 2>/dev/null')
        .join('\n');
    return run('$cmd\necho OK');
  }

  static Future<String> gov() =>
      run('cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor');
  static Future<String> freq() => run(
      "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq | awk '{printf \"%.0f MHz\", \$1/1000}'");

  static Future<String> lockBand() => run('''
    echo "524288" > /data/local/tmp/bandlock.conf
    echo "AT+EPBSE=524288" > /dev/ttyC0 2>/dev/null
    echo OK''');
  static Future<String> unlockBand() => run('''
    echo "0" > /data/local/tmp/bandlock.conf
    echo "AT+EPBSE=0" > /dev/ttyC0 2>/dev/null
    echo OK''');
  static Future<String> bandStatus() =>
      run('cat /data/local/tmp/bandlock.conf 2>/dev/null || echo "0"');

  static Future<String> thermalEsports() =>
      run('setprop persist.thermal.config esports && echo OK');
  static Future<String> thermalNormal() =>
      run('setprop persist.thermal.config default && echo OK');
  static Future<String> thermal() => run('getprop persist.thermal.config');

  static Future<String> rebootSystem() => run('reboot');
  static Future<String> rebootRecovery() => run('reboot recovery');
  static Future<String> rebootFastboot() => run('reboot bootloader');

  static Future<String> battery() async {
    final r = await run('cat /sys/class/power_supply/battery/capacity');
    if (!bad(r)) return r;
    return run('cat /sys/class/power_supply/bms/capacity');
  }

  static Future<String> temp() async {
    for (var i = 0; i < 6; i++) {
      final type =
          await run('cat /sys/class/thermal/thermal_zone$i/type 2>/dev/null');
      if (type.toLowerCase().contains('cpu') ||
          type.toLowerCase().contains('tsens')) {
        final t = await run(
            "cat /sys/class/thermal/thermal_zone$i/temp | awk '{printf \"%.1f\", \$1/1000}'");
        if (!bad(t)) {
          final v = double.tryParse(t) ?? 0;
          final f = v > 200 ? v / 1000 : v;
          return '${f.toStringAsFixed(1)}°C';
        }
      }
    }
    final t = await run(
        "cat /sys/class/thermal/thermal_zone0/temp | awk '{printf \"%.1f\", \$1/1000}'");
    if (bad(t)) return 'NO_ROOT';
    final v = double.tryParse(t) ?? 0;
    final f = v > 200 ? v / 1000 : v;
    return '${f.toStringAsFixed(1)}°C';
  }

  static Future<Map<String, String>> sysInfo() async {
    try {
      if (!await hasRoot()) {
        return {'root': 'false'};
      }
      final b = await battery();
      final tp = await temp();
      final fq = await freq();
      final gv = await gov();
      final rr = await currentRefresh();
      final th = await thermal();
      final bn = await bandStatus();
      return {
        'battery': bad(b) ? '-' : '$b%',
        'temp': bad(tp) ? '-' : tp,
        'freq': bad(fq) ? '-' : fq,
        'gov': bad(gv) ? '-' : gv,
        'refresh': bad(rr) ? '-' : '${rr}Hz',
        'thermal': bad(th) ? 'default' : th,
        'band': bn == '524288' ? 'B1+B3+B8' : 'Auto',
        'root': 'true',
      };
    } catch (_) {
      return {'root': 'false'};
    }
  }
}

// ============================================================
// SHARED STATE (sederhana, via ValueNotifier global)
// ============================================================
final sysNotifier = ValueNotifier<Map<String, String>>({});
final ramNotifier = ValueNotifier<Map<String, String>>({});
final deviceNotifier =
    ValueNotifier<Map<String, String>>({'name': 'Memuat...', 'android': '-'});
final busyNotifier = ValueNotifier<bool>(false);
final toastNotifier = ValueNotifier<String>('');

Timer? _pollTimer;
void startPolling() {
  _refreshAll();
  _pollTimer ??=
      Timer.periodic(const Duration(seconds: 5), (_) => _refreshAll());
}

Future<void> _refreshAll() async {
  try {
    sysNotifier.value = await RootService.sysInfo();
    ramNotifier.value = await RootService.ram();
  } catch (_) {}
}

Future<void> loadDevice() async {
  try {
    deviceNotifier.value = await RootService.device();
  } catch (_) {}
}

void showToast(String msg) {
  toastNotifier.value = msg;
  Timer(const Duration(seconds: 3), () {
    if (toastNotifier.value == msg) toastNotifier.value = '';
  });
}

Future<void> runAction(Future<String> Function() action,
    {required String ok, String? noRoot}) async {
  if (busyNotifier.value) return;
  busyNotifier.value = true;
  try {
    final r = await action().timeout(const Duration(seconds: 9));
    showToast(RootService.bad(r)
        ? '⚠️ ${noRoot ?? 'Fitur ini butuh akses root aktif.'}'
        : ok);
    await _refreshAll();
  } catch (_) {
    showToast('⚠️ Gagal menjalankan aksi. Coba lagi.');
  } finally {
    busyNotifier.value = false;
  }
}

// ============================================================
// DASHBOARD TAB
// ============================================================
class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key});
  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  @override
  void initState() {
    super.initState();
    loadDevice();
    startPolling();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refreshAll,
      color: kCyan,
      backgroundColor: kPanel,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _header(),
          ValueListenableBuilder<String>(
            valueListenable: toastNotifier,
            builder: (_, msg, __) => msg.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _banner(msg)),
          ),
          ValueListenableBuilder<Map<String, String>>(
            valueListenable: sysNotifier,
            builder: (_, sys, __) {
              if (sys['root'] == 'false') {
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _banner(
                      '⚠️ Akses root belum aktif. Berikan izin root lalu tarik untuk refresh.',
                      color: kYellow),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          const SizedBox(height: 24),
          _sectionTitle('STATUS REAL-TIME', kCyan),
          const SizedBox(height: 12),
          _infoGrid(),
          const SizedBox(height: 24),
          _sectionTitle('AKSI CEPAT', kGreen),
          const SizedBox(height: 12),
          _quickActions(),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [kPanel, kPanel2],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: glow(kCyan, .15)),
      ),
      child: Row(children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(colors: [kCyan, Color(0xFF0090A8)]),
            boxShadow: [
              BoxShadow(color: glow(kCyan, .35), blurRadius: 14, spreadRadius: -2)
            ],
          ),
          child: const Icon(Icons.bolt_rounded, color: Colors.black, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: ValueListenableBuilder<Map<String, String>>(
            valueListenable: deviceNotifier,
            builder: (_, d, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Welcome Sahrul',
                    style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: kWhite,
                        letterSpacing: -.3)),
                const SizedBox(height: 2),
                Text('${d['name']} • ${d['android']}',
                    style: TextStyle(fontSize: 11.5, color: mut(.45)),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: busyNotifier,
          builder: (_, busy, __) => busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: kCyan))
              : GestureDetector(
                  onTap: _refreshAll,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: mut(.05),
                        borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.refresh_rounded,
                        color: kCyan, size: 20),
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _infoGrid() {
    return ValueListenableBuilder<Map<String, String>>(
      valueListenable: sysNotifier,
      builder: (_, sys, __) {
        return ValueListenableBuilder<Map<String, String>>(
          valueListenable: ramNotifier,
          builder: (_, ram, __) {
            final batV =
                double.tryParse((sys['battery'] ?? '').replaceAll('%', '')) ?? 0;
            final tmpV =
                double.tryParse((sys['temp'] ?? '').replaceAll('°C', '')) ?? 0;
            final ramP = (int.tryParse(ram['pct'] ?? '0') ?? 0) / 100;
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.25,
              children: [
                _ring(Icons.battery_charging_full_rounded, 'BATERAI',
                    sys['battery'] ?? '-', kGreen,
                    pct: sys['battery'] != null ? batV / 100 : null),
                _ring(Icons.thermostat_rounded, 'SUHU CPU', sys['temp'] ?? '-',
                    kOrange,
                    pct: sys['temp'] != null ? (tmpV / 90).clamp(0, 1) : null),
                _ring(Icons.memory_rounded, 'RAM TERPAKAI', ram['used'] ?? '-',
                    kYellow,
                    pct: ram['used'] != null ? ramP : null),
                _ring(Icons.speed_rounded, 'CPU FREQ', sys['freq'] ?? '-', kCyan),
                _ring(Icons.monitor_rounded, 'REFRESH', sys['refresh'] ?? '-',
                    kPurple),
                _ring(Icons.signal_cellular_alt_rounded, 'LTE BAND',
                    sys['band'] ?? '-', kTeal),
              ],
            );
          },
        );
      },
    );
  }

  Widget _quickActions() {
    return Row(children: [
      Expanded(
        child: _quickBtn(Icons.cleaning_services_rounded, 'Bersihkan RAM',
            kOrange, () {
          runAction(RootService.clearRam, ok: '✅ RAM dibersihkan!');
        }),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _quickBtn(Icons.rocket_launch_rounded, 'Mode Performa', kYellow,
            () {
          runAction(() => RootService.setGov('performance'),
              ok: '✅ CPU mode Performa aktif!');
        }),
      ),
    ]);
  }

  Widget _quickBtn(IconData ic, String label, Color c, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: glow(c, .25)),
        ),
        child: Column(children: [
          Icon(ic, color: c, size: 26),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  color: kWhite, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

// ============================================================
// TWEAK TAB
// ============================================================
class TweakTab extends StatefulWidget {
  const TweakTab({super.key});
  @override
  State<TweakTab> createState() => _TweakTabState();
}

class _TweakTabState extends State<TweakTab> {
  int _hz = 60;
  String _gov = 'schedutil';

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, String>>(
      valueListenable: sysNotifier,
      builder: (_, sys, __) {
        final bandLocked = sys['band'] != null && sys['band'] != 'Auto';
        final esports = sys['thermal'] == 'esports';
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            const Text('Tweak Performa',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: kWhite)),
            Text('Atur perilaku perangkat sesuai kebutuhanmu',
                style: TextStyle(fontSize: 12.5, color: mut(.45))),
            const SizedBox(height: 24),

            _sectionTitle('REFRESH RATE', kPurple),
            const SizedBox(height: 12),
            _refreshCard(sys),
            const SizedBox(height: 22),

            _sectionTitle('CPU GOVERNOR', kYellow),
            const SizedBox(height: 12),
            _govCard(sys),
            const SizedBox(height: 22),

            _sectionTitle('LTE BAND LOCK', kTeal),
            const SizedBox(height: 12),
            _controlCard(
              Icons.cell_tower_rounded,
              'Lock Band Tri Indonesia',
              bandLocked ? 'Terkunci: B1 + B3 + B8' : 'Mode: Auto (semua band)',
              bandLocked ? 'Lepas' : 'Lock',
              bandLocked ? kTeal : kPurple,
              () => runAction(
                bandLocked ? RootService.unlockBand : RootService.lockBand,
                ok: bandLocked ? '✅ Band kembali Auto' : '✅ Band dikunci Tri',
                noRoot: 'Lock band butuh dukungan modem khusus & root.',
              ),
            ),
            const SizedBox(height: 22),

            _sectionTitle('MODE THERMAL', kOrange),
            const SizedBox(height: 12),
            _controlCard(
              Icons.sports_esports_rounded,
              'Mode Esports (Gaming)',
              esports ? 'Aktif: thermal dibuka' : 'Aktif: Normal',
              esports ? 'Normal' : 'Aktifkan',
              esports ? kGreen : kOrange,
              () => runAction(
                esports
                    ? RootService.thermalNormal
                    : RootService.thermalEsports,
                ok: esports ? '✅ Thermal Normal' : '✅ Mode Esports aktif!',
                noRoot: 'Thermal profile ini tak didukung ROM kamu.',
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _refreshCard(Map<String, String> sys) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Terkunci:', style: TextStyle(color: mut(.55), fontSize: 12.5)),
          const SizedBox(width: 6),
          Text('${_hz}Hz',
              style: const TextStyle(
                  color: kPurple,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5)),
          const Spacer(),
          Text('Aktual: ${sys['refresh'] ?? '-'}',
              style: TextStyle(
                  color: mut(.35), fontSize: 11, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [40, 60, 90, 120, 144].map((hz) {
            final on = _hz == hz;
            return GestureDetector(
              onTap: () {
                setState(() => _hz = hz);
                runAction(() => RootService.setRefresh(hz),
                    ok: '✅ Refresh dikunci ${hz}Hz',
                    noRoot: 'Device membatasi refresh via root.');
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: on ? kPurple : mut(.04),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: on ? kPurple : Colors.transparent),
                ),
                child: Text('${hz}Hz',
                    style: TextStyle(
                        color: on ? Colors.black : kWhite,
                        fontWeight: FontWeight.bold,
                        fontSize: 12.5)),
              ),
            );
          }).toList(),
        ),
      ]),
    );
  }

  Widget _govCard(Map<String, String> sys) {
    final opts = [
      ['powersave', 'Hemat Daya', Icons.battery_saver_rounded, kGreen],
      ['schedutil', 'Seimbang', Icons.tune_rounded, kCyan],
      ['performance', 'Performa', Icons.rocket_launch_rounded, kYellow],
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
                color: glow(kCyan, .1),
                borderRadius: BorderRadius.circular(13)),
            child: const Icon(Icons.bolt_rounded, color: kCyan, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Mode Performa CPU',
                    style: TextStyle(
                        color: kWhite,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text('Governor aktif: ${sys['gov'] ?? 'schedutil'}',
                    style: TextStyle(color: mut(.45), fontSize: 11.5)),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Row(
          children: opts.map((o) {
            final val = o[0] as String;
            final label = o[1] as String;
            final ic = o[2] as IconData;
            final c = o[3] as Color;
            final on = _gov == val;
            final last = o == opts.last;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: last ? 0 : 8),
                child: GestureDetector(
                  onTap: () {
                    setState(() => _gov = val);
                    runAction(() => RootService.setGov(val),
                        ok: '✅ Governor: $val',
                        noRoot: 'Governor ini tak didukung kernel.');
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: on ? glow(c, .15) : mut(.04),
                      borderRadius: BorderRadius.circular(11),
                      border:
                          Border.all(color: on ? c : Colors.transparent),
                    ),
                    child: Column(children: [
                      Icon(ic, size: 16, color: on ? c : mut(.35)),
                      const SizedBox(height: 4),
                      Text(label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                              color: on ? c : mut(.4))),
                    ]),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ]),
    );
  }
}

// ============================================================
// TOOLS TAB
// ============================================================
class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        const Text('Tools',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w800, color: kWhite)),
        Text('Utilitas & informasi perangkat',
            style: TextStyle(fontSize: 12.5, color: mut(.45))),
        const SizedBox(height: 24),
        _sectionTitle('INFORMASI CHIPSET', kCyan),
        const SizedBox(height: 12),
        ValueListenableBuilder<Map<String, String>>(
          valueListenable: deviceNotifier,
          builder: (_, d, __) => Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: kPanel,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: kBorder)),
            child: Column(children: [
              _infoRow('Perangkat', d['name'] ?? '-'),
              _infoRow('Versi OS', d['android'] ?? '-'),
              _infoRow('Chipset', d['chipset'] ?? '-'),
            ]),
          ),
        ),
        const SizedBox(height: 22),
        _sectionTitle('REBOOT PERANGKAT', kRed),
        const SizedBox(height: 12),
        _rebootCard(context),
        const SizedBox(height: 22),
        _sectionTitle('LAINNYA', kGreen),
        const SizedBox(height: 12),
        _toolTile(Icons.developer_mode_rounded, 'Buka Pengaturan Developer',
            'Akses opsi pengembang sistem', kGreen, () {
          runAction(() => RootService.run('am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS && echo OK'),
              ok: '✅ Membuka pengaturan developer');
        }),
        const SizedBox(height: 10),
        _toolTile(Icons.bedtime_rounded, 'Tutup Semua Aplikasi Latar',
            'Hentikan app berjalan di background', kPurple, () {
          runAction(RootService.clearRam, ok: '✅ Aplikasi latar dihentikan');
        }),
      ],
    );
  }

  Widget _infoRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        SizedBox(
            width: 90,
            child: Text(k, style: TextStyle(color: mut(.45), fontSize: 12.5))),
        Expanded(
          child: Text(v,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: kWhite,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace')),
        ),
      ]),
    );
  }

  Widget _toolTile(IconData ic, String title, String sub, Color c,
      VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: kBorder)),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
                color: glow(c, .1), borderRadius: BorderRadius.circular(13)),
            child: Icon(ic, color: c, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: kWhite,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(sub, style: TextStyle(color: mut(.45), fontSize: 11.5)),
                ]),
          ),
          Icon(Icons.chevron_right_rounded, color: mut(.3), size: 20),
        ]),
      ),
    );
  }

  Widget _rebootCard(BuildContext context) {
    return _controlCard(
      Icons.restart_alt_rounded,
      'Reboot Device',
      'System / Recovery / Fastboot',
      'Reboot',
      kRed,
      () => _showRebootSheet(context),
    );
  }

  void _showRebootSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kPanel,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: mut(.2), borderRadius: BorderRadius.circular(2)),
            ),
            const Text('Pilih Mode Reboot',
                style: TextStyle(
                    color: kWhite, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            _rebootOpt(ctx, Icons.restart_alt_rounded, kCyan, 'Reboot System',
                'Restart normal', RootService.rebootSystem),
            _rebootOpt(ctx, Icons.build_circle_outlined, kYellow,
                'Reboot Recovery', 'Masuk mode recovery',
                RootService.rebootRecovery),
            _rebootOpt(ctx, Icons.usb_rounded, kPurple, 'Reboot Fastboot',
                'Masuk mode bootloader', RootService.rebootFastboot),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  Widget _rebootOpt(BuildContext ctx, IconData ic, Color c, String label,
      String desc, Future<String> Function() act) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: glow(c, .1), borderRadius: BorderRadius.circular(12)),
        child: Icon(ic, color: c, size: 22),
      ),
      title: Text(label,
          style: const TextStyle(
              color: kWhite, fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle:
          Text(desc, style: TextStyle(color: mut(.5), fontSize: 12)),
      onTap: () {
        Navigator.pop(ctx);
        showDialog(
          context: ctx,
          builder: (d) => AlertDialog(
            backgroundColor: kPanel,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Konfirmasi',
                style: TextStyle(color: kWhite)),
            content: Text('Jalankan "$label"? Perangkat akan restart sekarang.',
                style: TextStyle(color: mut(.7))),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(d),
                  child: const Text('Batal')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: kRed, foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.pop(d);
                  runAction(act,
                      ok: '✅ $label...',
                      noRoot: 'Gagal reboot. Pastikan root aktif.');
                },
                child: const Text('Ya, Reboot'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ============================================================
// ABOUT TAB
// ============================================================
class AboutTab extends StatelessWidget {
  const AboutTab({super.key});
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        const SizedBox(height: 20),
        Center(
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [kCyan, Color(0xFF0090A8)]),
              boxShadow: [
                BoxShadow(color: glow(kCyan, .35), blurRadius: 24, spreadRadius: 1)
              ],
            ),
            child: const Icon(Icons.bolt_rounded, color: Colors.black, size: 40),
          ),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text('Welcome Sahrul',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: kWhite)),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text('Device Control Center • v2.0.0',
              style: TextStyle(
                  fontSize: 12,
                  color: glow(kCyan, .7),
                  letterSpacing: 1,
                  fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 28),
        _aboutCard(
          Icons.shield_rounded,
          kGreen,
          'Anti Force-Close',
          'Semua perintah root dibungkus pengaman berlapis. App tidak akan menutup mendadak meski perintah gagal.',
        ),
        const SizedBox(height: 12),
        _aboutCard(
          Icons.devices_rounded,
          kCyan,
          'Universal',
          'Mendeteksi nama perangkat, jumlah core CPU, dan jalur sensor otomatis — mendukung beragam HP Android.',
        ),
        const SizedBox(height: 12),
        _aboutCard(
          Icons.warning_amber_rounded,
          kYellow,
          'Butuh Root',
          'Sebagian besar fitur memerlukan akses root aktif. Berikan izin lewat aplikasi manajer root kamu.',
        ),
        const SizedBox(height: 28),
        Center(
          child: Text('Dibuat oleh Sahrul',
              style: TextStyle(color: mut(.4), fontSize: 12)),
        ),
      ],
    );
  }

  Widget _aboutCard(IconData ic, Color c, String title, String body) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kBorder)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: glow(c, .1), borderRadius: BorderRadius.circular(12)),
          child: Icon(ic, color: c, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    color: kWhite, fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(body,
                style: TextStyle(color: mut(.5), fontSize: 12, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

// ============================================================
// SHARED WIDGETS (top-level)
// ============================================================
Widget _sectionTitle(String t, Color accent) => Row(children: [
      Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
              color: accent, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 8),
      Text(t,
          style: const TextStyle(
              color: kWhite,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: .3)),
    ]);

Widget _banner(String text, {Color color = kCyan}) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: glow(color, .08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: glow(color, .4)),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 12.5, height: 1.3)),
    );

Widget _ring(IconData ic, String label, String value, Color c,
    {double? pct}) {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: kPanel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: glow(c, .18)),
      boxShadow: [
        BoxShadow(color: glow(c, .06), blurRadius: 16, spreadRadius: -4)
      ],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 36,
        height: 36,
        child: Stack(alignment: Alignment.center, children: [
          if (pct != null)
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                value: pct.clamp(0.0, 1.0),
                strokeWidth: 2.5,
                backgroundColor: mut(.06),
                valueColor: AlwaysStoppedAnimation(c),
              ),
            )
          else
            Container(
                width: 36,
                height: 36,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: glow(c, .08))),
          Icon(ic, color: c, size: 16),
        ]),
      ),
      const SizedBox(height: 12),
      Text(value,
          style: TextStyle(
              color: c,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              letterSpacing: -.5)),
      const SizedBox(height: 3),
      Text(label,
          style: TextStyle(
              color: mut(.38),
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: .8)),
    ]),
  );
}

Widget _controlCard(IconData ic, String title, String sub, String btnLabel,
    Color c, VoidCallback onTap) {
  return ValueListenableBuilder<bool>(
    valueListenable: busyNotifier,
    builder: (_, busy, __) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kBorder)),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
              color: glow(c, .1), borderRadius: BorderRadius.circular(13)),
          child: Icon(ic, color: c, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    color: kWhite,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(sub, style: TextStyle(color: mut(.45), fontSize: 11.5)),
          ]),
        ),
        const SizedBox(width: 10),
        ElevatedButton(
          onPressed: busy ? null : onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: glow(c, .15),
            foregroundColor: c,
            disabledBackgroundColor: mut(.05),
            disabledForegroundColor: mut(.3),
            side: BorderSide(color: busy ? Colors.transparent : c),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11)),
            elevation: 0,
          ),
          child: Text(btnLabel,
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.bold)),
        ),
      ]),
    ),
  );
}
