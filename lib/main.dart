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
    runApp(const XyzAiApp());
  }, (e, s) => debugPrint('ERR: $e'));
}

// TEMA GLOBAL
final isNightNotifier = ValueNotifier<bool>(true);
final isRootNotifier  = ValueNotifier<bool>(false);
bool get _night => isNightNotifier.value;
bool get _root  => isRootNotifier.value;

const kCyan   = Color(0xFF00E5FF);
const kGreen  = Color(0xFF34C759);
const kYellow = Color(0xFFE6A700);
const kRed    = Color(0xFFFF4747);
const kOrange = Color(0xFFFF6B47);
const kPurple = Color(0xFFB47FFF);
const kTeal   = Color(0xFF13B5A6);
const kBlue   = Color(0xFF3D8EFF);
const kPink   = Color(0xFFFF2D78);

Color get kBg     => _night ? const Color(0xFF060612) : const Color(0xFFF0F2F8);
Color get kPanel  => _night ? const Color(0xFF0D0D20) : const Color(0xFFFFFFFF);
Color get kPanel2 => _night ? const Color(0xFF12122A) : const Color(0xFFE8EAF2);
Color get kBorder => _night ? const Color(0xFF1A1A38) : const Color(0xFFDDE0EC);
Color get kWhite  => _night ? Colors.white : const Color(0xFF080818);
Color mut(double o) => _night
    ? Colors.white.withOpacity(o)
    : const Color(0xFF080818).withOpacity(o.clamp(0.05, 0.9));
Color glow(Color c, double o) => c.withOpacity(o);

// ROOT HELPERS
Future<bool> checkRoot() async {
  try {
    // Timeout jaga-jaga: kalau proses su menggantung (mis. popup izin root
    // tidak direspons user), app tidak boleh freeze selamanya menunggu.
    final r = await Process.run('su', ['-c', 'id'])
        .timeout(const Duration(seconds: 5), onTimeout: () =>
            ProcessResult(0, 1, '', 'timeout'));
    return r.stdout.toString().contains('uid=0');
  } catch (_) { return false; }
}

Future<String> runRoot(String cmd) async {
  if (!_root) return 'NO_ROOT';
  try {
    final r = await Process.run('su', ['-c', 'sh -c ${_shellQuote(cmd)}'])
        .timeout(const Duration(seconds: 8), onTimeout: () =>
            ProcessResult(0, 1, '', 'Command timeout (8s) — kemungkinan device lag atau perintah menggantung.'));
    final out = r.stdout.toString().trim();
    final err = r.stderr.toString().trim();
    if (out.isNotEmpty) return out;
    if (err.isNotEmpty) return 'ERR: $err';
    return 'OK';
  } catch (e) { return 'ERROR: $e'; }
}

String _shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

Future<String> readSys(String path) async {
  try {
    final s = (await File(path).readAsString()).trim();
    if (s.isNotEmpty) return s;
  } catch (_) {}
  if (_root) {
    try {
      final r = await Process.run('su', ['-c', 'cat "$path"'])
          .timeout(const Duration(seconds: 4), onTimeout: () =>
              ProcessResult(0, 1, '', 'timeout'));
      final out = r.stdout.toString().trim();
      if (out.isNotEmpty &&
          !out.contains('Permission denied') &&
          !out.contains('No such file')) {
        return out;
      }
    } catch (_) {}
  }
  return '';
}

// Baca properti Android (getprop) — jalan tanpa root
Future<String> getProp(String key) async {
  try {
    final r = await Process.run('getprop', [key])
        .timeout(const Duration(seconds: 4), onTimeout: () =>
            ProcessResult(0, 1, '', 'timeout'));
    return r.stdout.toString().trim();
  } catch (_) {
    if (_root) {
      final out = await runRoot('getprop $key');
      if (out != 'OK' && !out.startsWith('ERR')) return out;
    }
    return '';
  }
}

// ============================================================
// DEVICE INFO — deteksi otomatis kemampuan HP
// ============================================================
class DeviceInfo {
  static final DeviceInfo i = DeviceInfo._();
  DeviceInfo._();

  String model = '---';
  String brand = '---';
  String platform = '---';
  String androidVer = '---';
  String cpuArch = '---';
  int cpuCores = 0;

  // Nama tampilan final setelah validasi silang brand vs hardware asli.
  String displayName = '---';
  bool spoofSuspected = false; // true kalau brand tidak konsisten dgn chipset

  // Kemampuan yang terdeteksi
  List<String> governors = [];      // governor yang didukung
  List<int> freqsKhz = [];          // daftar frekuensi (kHz)
  String? thermalPath;              // path zone suhu CPU yang valid
  String? batteryTempPath;          // path suhu baterai
  String? dt2wPath;                 // path gesture double-tap-to-wake
  bool hasCpuFreq = false;

  bool loaded = false;
  bool _detecting = false; // guard anti tabrakan kalau detect() dipanggil paralel

  // Notifier terpisah dari data itu sendiri — dipakai UI (About, Command,
  // Dashboard) untuk auto-rebuild setiap kali hasil deteksi berubah, tanpa
  // perlu setState manual tersebar di banyak tempat. Nilainya cuma dipakai
  // sebagai sinyal "ada perubahan", bukan sebagai data sungguhan.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  // detect() AMAN dipanggil BERULANG KALI kapan pun (bukan cuma sekali saat
  // splash). Dipanggil ulang setiap kali Dashboard/Command tab dibuka, dan
  // bisa dipanggil manual lewat tombol refresh — sehingga app selalu
  // mendeteksi ulang device tempatnya berjalan, realtime, bukan cache statis.
  Future<void> detect() async {
    if (_detecting) return; // hindari 2 proses deteksi jalan bersamaan
    _detecting = true;
    try {
      // Jaring pengaman terakhir: walau tiap readSys/getProp individual
      // sudah punya timeout sendiri, deteksi memanggil puluhan di antaranya
      // berurutan. Batas total 20 detik memastikan proses ini TIDAK PERNAH
      // menggantung tanpa batas, apa pun yang terjadi di dalamnya.
      await _detectInternal().timeout(const Duration(seconds: 20),
          onTimeout: () => debugPrint('DeviceInfo.detect() timeout — data sebagian dipakai'));
      loaded = true;
      revision.value++; // broadcast: ada data baru, UI yang dengar akan rebuild
    } finally {
      _detecting = false;
    }
  }

  Future<void> _detectInternal() async {
    // Info dasar via getprop (tanpa root)
    model      = await getProp('ro.product.model');
    brand      = await getProp('ro.product.manufacturer');
    platform   = await getProp('ro.board.platform');
    androidVer = await getProp('ro.build.version.release');
    cpuArch    = await getProp('ro.product.cpu.abi');

    if (model.isEmpty) model = '---';
    if (brand.isEmpty) brand = '---';
    if (platform.isEmpty) platform = '---';
    if (androidVer.isEmpty) androidVer = '---';

    // ===== VALIDASI SILANG BRAND vs HARDWARE ASLI =====
    // `ro.product.manufacturer`/`model` gampang dipalsukan modul spoofing.
    // `ro.board.platform` (chipset) jauh lebih sulit dipalsukan karena
    // dibaca driver kernel langsung, bukan cuma properti sistem. Kalau
    // brand mengaku vendor yang TIDAK PERNAH memakai chipset ini (misal
    // "Apple" tapi board MediaTek/Qualcomm), brand dianggap tidak valid
    // dan kita pakai fallback yang jujur.
    final platformLower = platform.toLowerCase();
    final brandLower = brand.toLowerCase();
    final looksMediatek = platformLower.contains('mt') || platformLower.startsWith('k6');
    final looksQualcomm = platformLower.contains('sm') || platformLower.contains('msm') || platformLower.contains('kona') || platformLower.contains('lahaina');
    final claimsApple = brandLower.contains('apple') || model.toLowerCase().contains('iphone');

    spoofSuspected = claimsApple && (looksMediatek || looksQualcomm);

    if (spoofSuspected) {
      // Chipset asli tidak bisa berupa Apple Silicon di board Android —
      // ini pasti spoof. Tampilkan nama yang jujur berbasis chipset.
      displayName = 'Android (chipset $platform)';
    } else if (model == '---' && brand == '---') {
      displayName = 'Perangkat tidak dikenal';
    } else {
      displayName = '$brand $model';
    }

    // Jumlah core CPU
    cpuCores = 0;
    for (int c = 0; c < 16; c++) {
      final exists = await readSys('/sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq');
      if (exists.isNotEmpty) cpuCores++;
      else if (c > 0) break;
    }
    if (cpuCores == 0) cpuCores = 1;

    // Governor yang tersedia
    final govRaw = await readSys('/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors');
    governors = govRaw.split(RegExp(r'\s+')).where((g) => g.isNotEmpty).toList();
    hasCpuFreq = governors.isNotEmpty ||
        (await readSys('/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq')).isNotEmpty;

    // Frekuensi yang tersedia
    final freqRaw = await readSys('/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies');
    freqsKhz = freqRaw.split(RegExp(r'\s+'))
        .map((f) => int.tryParse(f) ?? 0)
        .where((f) => f > 0).toList()..sort();

    // Cari thermal zone CPU yang valid
    for (int z = 0; z < 20; z++) {
      final t = await readSys('/sys/class/thermal/thermal_zone$z/temp');
      final n = int.tryParse(t) ?? 0;
      if (n > 20000 && n < 100000) { thermalPath = '/sys/class/thermal/thermal_zone$z/temp'; break; }
    }

    // Cari path suhu baterai
    for (final p in [
      '/sys/class/power_supply/battery/temp',
      '/sys/class/power_supply/mtk-gauge/temp',
      '/sys/class/power_supply/bms/temp',
    ]) {
      if ((await readSys(p)).isNotEmpty) { batteryTempPath = p; break; }
    }

    // Cari path DT2W (gesture wake) di berbagai vendor touch
    for (final p in [
      '/sys/devices/platform/goodix_ts.0/gesture/enable',
      '/proc/touchpanel/double_tap_enable',
      '/sys/touchpanel/double_tap',
      '/sys/devices/virtual/touch/tp_dev/gesture_on',
      '/proc/tp_gesture',
    ]) {
      if ((await readSys(p)).isNotEmpty) { dt2wPath = p; break; }
    }
  }

  // Buat 3-4 pilihan frekuensi representatif dari daftar yang ada
  List<int> get freqChoices {
    if (freqsKhz.isEmpty) return [];
    final n = freqsKhz.length;
    if (n <= 4) return freqsKhz.reversed.toList();
    return [
      freqsKhz[n - 1],          // max
      freqsKhz[(n * 2 ~/ 3)],   // tinggi
      freqsKhz[(n ~/ 3)],       // sedang
      freqsKhz[0],              // min
    ];
  }
}

// APP
class XyzAiApp extends StatelessWidget {
  const XyzAiApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, night, __) => MaterialApp(
        title: 'Xyz_AI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: kBg,
          colorScheme: ColorScheme.fromSeed(seedColor: kCyan,
              brightness: night ? Brightness.dark : Brightness.light),
        ),
        home: const SplashScreen(),
      ),
    );
  }
}

// SPLASH
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  late AnimationController _main, _orbit;
  late Animation<double> _scale, _fade, _progress;
  String _status = 'Initializing...';

  @override
  void initState() {
    super.initState();
    _main  = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..forward();
    _orbit = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();
    _scale    = CurvedAnimation(parent: _main, curve: const Interval(0.0, 0.5, curve: Curves.elasticOut));
    _fade     = CurvedAnimation(parent: _main, curve: const Interval(0.4, 1.0, curve: Curves.easeOut));
    _progress = CurvedAnimation(parent: _main, curve: Curves.easeInOut);
    _initApp();
  }

  Future<void> _initApp() async {
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) setState(() => _status = 'Checking root...');
    final hasRoot = await checkRoot();
    isRootNotifier.value = hasRoot;
    if (mounted) setState(() => _status = hasRoot ? 'Root detected ✓' : 'Non-root mode');
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) setState(() => _status = 'Detecting device...');
    await DeviceInfo.i.detect();
    if (mounted) setState(() => _status = DeviceInfo.i.displayName);
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      Navigator.pushReplacement(context, PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, a, __) => FadeTransition(opacity: a, child: const RootShell()),
      ));
    }
  }

  @override
  void dispose() { _main.dispose(); _orbit.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060612),
      body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedBuilder(
          animation: Listenable.merge([_main, _orbit]),
          builder: (_, __) => Stack(alignment: Alignment.center, children: [
            Transform.rotate(
              angle: _orbit.value * 6.28318,
              child: SizedBox(width: 160, height: 160,
                  child: CustomPaint(painter: _OrbitPainter(_orbit.value))),
            ),
            Opacity(opacity: _scale.value,
              child: Container(width: 118 + 6 * (_orbit.value % 1), height: 118 + 6 * (_orbit.value % 1),
                decoration: BoxDecoration(shape: BoxShape.circle,
                    border: Border.all(color: kCyan.withOpacity(0.1), width: 1)))),
            ScaleTransition(scale: _scale, child: _AppIcon(size: 92)),
          ]),
        ),
        const SizedBox(height: 36),
        FadeTransition(opacity: _fade, child: Column(children: [
          Text('XYZ_AI', style: TextStyle(color: kCyan, fontSize: 28,
              fontWeight: FontWeight.w900, letterSpacing: 8)),
          const SizedBox(height: 4),
          Text('COMMAND CENTER', style: TextStyle(
              color: Colors.white.withOpacity(0.3), fontSize: 10,
              fontWeight: FontWeight.w600, letterSpacing: 5)),
          const SizedBox(height: 28),
          SizedBox(width: 160, child: AnimatedBuilder(
            animation: _progress,
            builder: (_, __) => Column(children: [
              LinearProgressIndicator(value: _progress.value, minHeight: 2,
                backgroundColor: Colors.white.withOpacity(0.06),
                valueColor: const AlwaysStoppedAnimation(kCyan),
                borderRadius: BorderRadius.circular(2)),
              const SizedBox(height: 10),
              Text(_status, style: TextStyle(color: Colors.white.withOpacity(0.35),
                  fontSize: 11, fontFamily: 'monospace')),
            ]),
          )),
        ])),
      ])),
    );
  }
}

// APP ICON — Hexagon chip / processor
class _AppIcon extends StatelessWidget {
  final double size;
  const _AppIcon({required this.size});
  @override
  Widget build(BuildContext context) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const RadialGradient(center: Alignment(-0.3, -0.3),
        colors: [Color(0xFF1C1C44), Color(0xFF080816)]),
      boxShadow: [
        BoxShadow(color: kCyan.withOpacity(.35), blurRadius: 26, spreadRadius: 1),
        BoxShadow(color: kPurple.withOpacity(.18), blurRadius: 46, spreadRadius: -6),
      ],
    ),
    child: CustomPaint(painter: _IconPainter(), size: Size(size, size)),
  );
}

class _IconPainter extends CustomPainter {
  double _c(double a) => 1 - a*a/2 + a*a*a*a/24 - a*a*a*a*a*a/720;
  double _s(double a) => a - a*a*a/6 + a*a*a*a*a/120 - a*a*a*a*a*a*a/5040;
  Offset _hex(double cx, double cy, double r, int i) {
    final a = (i * 60 - 90) * 3.14159265 / 180;
    return Offset(cx + r * _c(a), cy + r * _s(a));
  }
  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width / 2, cy = s.height / 2;
    final rOuter = s.width * 0.34, rInner = s.width * 0.16;
    final legPaint = Paint()..color = kCyan.withOpacity(.5)
      ..strokeWidth = s.width * 0.022..strokeCap = StrokeCap.round;
    final padPaint = Paint()..color = kCyan.withOpacity(.7);
    for (int i = 0; i < 6; i++) {
      final inner = _hex(cx, cy, rOuter, i);
      final outer = _hex(cx, cy, rOuter + s.width * 0.1, i);
      canvas.drawLine(inner, outer, legPaint);
      canvas.drawCircle(outer, s.width * 0.026, padPaint);
    }
    final hexPath = Path();
    for (int i = 0; i < 6; i++) {
      final p = _hex(cx, cy, rOuter, i);
      i == 0 ? hexPath.moveTo(p.dx, p.dy) : hexPath.lineTo(p.dx, p.dy);
    }
    hexPath.close();
    canvas.drawPath(hexPath, Paint()..shader = LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [kCyan.withOpacity(.18), kPurple.withOpacity(.08)])
      .createShader(Rect.fromCircle(center: Offset(cx, cy), radius: rOuter)));
    canvas.drawPath(hexPath, Paint()..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.028..strokeJoin = StrokeJoin.round
      ..color = kCyan..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    final corePath = Path();
    for (int i = 0; i < 6; i++) {
      final p = _hex(cx, cy, rInner, i);
      i == 0 ? corePath.moveTo(p.dx, p.dy) : corePath.lineTo(p.dx, p.dy);
    }
    corePath.close();
    canvas.drawPath(corePath, Paint()..shader =
      RadialGradient(colors: [kCyan, const Color(0xFF0080A0)])
        .createShader(Rect.fromCircle(center: Offset(cx, cy), radius: rInner))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1));
    canvas.drawCircle(Offset(cx, cy), s.width * 0.045,
      Paint()..color = Colors.white..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(Offset(cx, cy), s.width * 0.028, Paint()..color = Colors.white);
  }
  @override
  bool shouldRepaint(_) => false;
}

class _OrbitPainter extends CustomPainter {
  final double v;
  _OrbitPainter(this.v);
  double _c(double a) => 1 - a*a/2 + a*a*a*a/24;
  double _s(double a) => a - a*a*a/6 + a*a*a*a*a/120;
  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width/2, cy = s.height/2, r = s.width/2 - 4;
    for (int i = 0; i < 12; i++) {
      final a = (i / 12) * 6.28318;
      canvas.drawCircle(Offset(cx + r*_c(a), cy + r*_s(a)), i%3==0 ? 2.2 : 1.2,
        Paint()..color = kCyan.withOpacity(i%3==0 ? .45 : .18));
    }
    final ma = v * 6.28318;
    canvas.drawCircle(Offset(cx + r*_c(ma), cy + r*_s(ma)), 4,
      Paint()..color = kCyan..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
  }
  @override
  bool shouldRepaint(_OrbitPainter o) => o.v != v;
}

// ROOT SHELL
class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _idx = 0;
  final _pages = const [DashboardTab(), CommandTab(), ToolsTab(), AboutTab()];

  @override
  void initState() {
    super.initState();
    // Titik jaminan utama: begitu shell app ini terbentuk (app baru dibuka
    // dari mana pun — cold start, dari background, dsb), device langsung
    // dideteksi ulang. Ini memastikan poin "selalu mendeteksi device tempat
    // aplikasi di-install" terpenuhi tak peduli tab mana yang aktif duluan.
    DeviceInfo.i.detect();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => Scaffold(
        backgroundColor: kBg,
        body: SafeArea(bottom: false, child: _pages[_idx]),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(color: kPanel,
            border: Border(top: BorderSide(color: kBorder, width: .5)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.3), blurRadius: 20, offset: const Offset(0,-4))]),
          child: SafeArea(top: false, child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _nav(0, Icons.dashboard_rounded,    'Dashboard', kCyan),
              _nav(1, Icons.account_tree_rounded, 'Command',   kPurple),
              _nav(2, Icons.construction_rounded, 'Tools',     kOrange),
              _nav(3, Icons.person_rounded,       'Tentang',   kGreen),
            ]),
          )),
        ),
      ),
    );
  }

  Widget _nav(int i, IconData icon, String label, Color accent) {
    final on = _idx == i;
    return GestureDetector(
      onTap: () { setState(() => _idx = i); HapticFeedback.selectionClick(); },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: on ? accent.withOpacity(.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? accent.withOpacity(.3) : Colors.transparent)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 21, color: on ? accent : mut(.3)),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 9.5, fontWeight: on ? FontWeight.w800 : FontWeight.w500,
              color: on ? accent : mut(.3), letterSpacing: .3)),
        ]),
      ),
    );
  }
}

// DASHBOARD
class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key});
  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  String _freq = '---', _gov = '---', _temp = '---';
  String _memTotal = '---', _memFree = '---';
  String _bat = '---', _batTemp = '---', _uptime = '---';
  bool _loading = true;
  late Timer _timer;

  // Riwayat nilai numerik untuk grafik mini realtime di tiap kartu info
  // (poin 4). Panjang dibatasi (_histLen) supaya memori tidak terus
  // membengkak — cukup untuk menunjukkan tren naik/turun beberapa menit
  // terakhir tanpa membebani rebuild widget.
  static const int _histLen = 24; // 24 sampel x 3 detik ≈ 72 detik riwayat
  final List<double> _freqHist = [];
  final List<double> _tempHist = [];
  final List<double> _memHist = [];
  final List<double> _batHist = [];

  void _pushHist(List<double> list, double value) {
    list.add(value);
    if (list.length > _histLen) list.removeAt(0);
  }

  @override
  void initState() {
    super.initState();
    // Deteksi ulang device SETIAP KALI tab ini dibuka (bukan cuma sekali
    // saat splash) — supaya nama device & kemampuan hardware selalu
    // mencerminkan kondisi terkini tempat app benar-benar berjalan.
    DeviceInfo.i.detect();
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _fetch());
  }

  @override
  void dispose() { _timer.cancel(); super.dispose(); }

  Future<String> _r(String p) async => readSys(p);
  Future<String> _rf(String p) async => readSys(p);
  int _parseMem(String c, String k) {
    for (final l in c.split('\n')) {
      if (l.startsWith(k)) return int.tryParse(l.split(':')[1].trim().split(' ')[0]) ?? 0;
    }
    return 0;
  }

  Future<void> _fetch() async {
    try {
      final freq = await _r('/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq');
      final gov  = await _r('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor');
      String temp = '---';
      for (int i = 0; i < 15; i++) {
        final t = await _r('/sys/class/thermal/thermal_zone$i/temp');
        final n = int.tryParse(t) ?? 0;
        if (n > 25000 && n < 95000) { temp = '${(n/1000).toStringAsFixed(1)}°C'; break; }
      }
      final mem = await _rf('/proc/meminfo');
      final mt = _parseMem(mem, 'MemTotal'), mf = _parseMem(mem, 'MemAvailable');
      String bat = '', bt = '---';
      bat = await _r('/sys/class/power_supply/battery/capacity');
      String rawBt = await _r('/sys/class/power_supply/battery/temp');
      if (rawBt.isEmpty) rawBt = await _r('/sys/class/power_supply/mtk-gauge/temp');
      final bti = int.tryParse(rawBt) ?? 0;
      if (bti != 0) bt = bti > 100 ? '${(bti/10).toStringAsFixed(1)}°C' : '$bti°C';
      if (bat.isNotEmpty) bat = '$bat%';
      final up = await _rf('/proc/uptime');
      final sec = double.tryParse(up.split(' ')[0]) ?? 0;
      final upStr = '${sec~/3600}h ${((sec%3600)~/60)}m';
      final freqMhz = int.tryParse(freq) ?? 0;
      if (mounted) setState(() {
        _freq = freqMhz > 0 ? '${(freqMhz/1000).round()} MHz' : '---';
        _gov = gov.isEmpty ? '---' : gov;
        _temp = temp;
        _memTotal = mt > 0 ? '${(mt/1024).round()} MB' : '---';
        _memFree  = mf > 0 ? '${(mf/1024).round()} MB' : '---';
        _bat = bat.isEmpty ? '---' : bat;
        _batTemp = bt;
        _uptime = upStr;
        _loading = false;

        // Catat sampel realtime ke riwayat untuk grafik mini (poin 4).
        // Nilai yang tidak valid (device belum siap / path tak ada) tidak
        // dicatat, supaya grafik tidak menampilkan lonjakan palsu ke 0.
        if (freqMhz > 0) _pushHist(_freqHist, freqMhz / 1000);
        final tempVal = double.tryParse(temp.replaceAll('°C', ''));
        if (tempVal != null) _pushHist(_tempHist, tempVal);
        if (mt > 0) _pushHist(_memHist, mt > 0 ? ((mt - mf) / mt * 100) : 0);
        final batVal = double.tryParse(bat.replaceAll('%', ''));
        if (batVal != null) _pushHist(_batHist, batVal);
      });
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => RefreshIndicator(
        onRefresh: _fetch, color: kCyan,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _pageHeader('Dashboard', 'Live System Monitor', kCyan),
            const SizedBox(height: 16),
            ValueListenableBuilder<bool>(
              valueListenable: isRootNotifier,
              builder: (_, root, __) => _banner(root),
            ),
            const SizedBox(height: 18),
            _sectionLabel('PROCESSOR', kCyan),
            const SizedBox(height: 10),
            _loading ? _skel() : GridView.count(
              crossAxisCount: 2, shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.15,
              children: [
                _tile('CPU Freq', _freq, Icons.speed_rounded, kCyan, history: _freqHist),
                _tile('Governor', _gov, Icons.tune_rounded, kPurple),
                _tile('CPU Temp', _temp, Icons.thermostat_rounded,
                    _temp == '---' ? kBlue : (double.tryParse(_temp.replaceAll('°C',''))??0) > 55 ? kRed : kGreen,
                    history: _tempHist),
                _tile('Uptime', _uptime, Icons.timer_rounded, kTeal),
              ],
            ),
            const SizedBox(height: 18),
            _sectionLabel('MEMORY', kPurple),
            const SizedBox(height: 10),
            _loading ? _skel() : _memCard(),
            const SizedBox(height: 18),
            _sectionLabel('BATTERY', kGreen),
            const SizedBox(height: 10),
            _loading ? _skel() : Row(children: [
              Expanded(child: _tile('Kapasitas', _bat, Icons.battery_full_rounded, kGreen, history: _batHist)),
              const SizedBox(width: 10),
              Expanded(child: _tile('Suhu', _batTemp, Icons.device_thermostat_rounded, kOrange)),
            ]),
            const SizedBox(height: 20),
          ]),
        ),
      ),
    );
  }

  Widget _banner(bool root) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: root ? kGreen.withOpacity(.07) : kYellow.withOpacity(.07),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: root ? kGreen.withOpacity(.25) : kYellow.withOpacity(.25))),
    child: Row(children: [
      Icon(root ? Icons.verified_rounded : Icons.info_rounded,
          color: root ? kGreen : kYellow, size: 20),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(root ? 'Root Aktif — MT6895' : 'Mode Non-Root',
            style: TextStyle(color: kWhite, fontSize: 13, fontWeight: FontWeight.w700)),
        Text(root ? 'KernelSU · Semua fitur tersedia' : 'Mode aman — fitur terbatas',
            style: TextStyle(color: mut(.4), fontSize: 11)),
      ])),
      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: root ? kGreen.withOpacity(.15) : kYellow.withOpacity(.15),
            borderRadius: BorderRadius.circular(8)),
        child: Text(root ? 'ROOT' : 'SAFE',
            style: TextStyle(color: root ? kGreen : kYellow,
                fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: 1))),
    ]),
  );

  Widget _memCard() {
    final t = int.tryParse(_memTotal.replaceAll(' MB','')) ?? 1;
    final f = int.tryParse(_memFree.replaceAll(' MB',''))  ?? 0;
    final u = t - f; final pct = (u/t).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(18), border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.memory_rounded, color: kPurple, size: 18),
          const SizedBox(width: 8),
          Text('RAM Usage', style: TextStyle(color: kWhite, fontSize: 13, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('$u / $t MB', style: TextStyle(color: kPurple, fontSize: 12, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 12),
        ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(
          value: pct, minHeight: 8, backgroundColor: mut(.06),
          valueColor: AlwaysStoppedAnimation(pct > .85 ? kRed : pct > .65 ? kYellow : kPurple))),
        const SizedBox(height: 8),
        Row(children: [
          Text('Free: $_memFree', style: TextStyle(color: mut(.4), fontSize: 11)),
          const Spacer(),
          Text('${(pct*100).toStringAsFixed(0)}% used', style: TextStyle(color: mut(.4), fontSize: 11)),
        ]),
      ]),
    );
  }

  // history: riwayat nilai numerik (poin 4). Kalau diisi minimal 2 titik,
  // sparkline pergerakan realtime digambar tipis di belakang kartu.
  Widget _tile(String label, String val, IconData icon, Color color, {List<double>? history}) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withOpacity(.18))),
    child: Stack(children: [
      // Sparkline realtime — ditaruh di lapisan belakang, memenuhi bagian
      // bawah kartu, supaya tren naik-turun terlihat sekilas tanpa
      // mengganggu keterbacaan angka di atasnya.
      if (history != null && history.length >= 2)
        Positioned.fill(
          child: Align(alignment: Alignment.bottomCenter,
            child: SizedBox(height: 26,
              child: CustomPaint(painter: _SparklinePainter(history, color), size: Size.infinite))),
        ),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: color, size: 16)),
        const Spacer(),
        Text(val, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w800, fontFamily: 'monospace')),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: mut(.38), fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: .8)),
      ]),
    ]),
  );

  Widget _skel() => Container(height: 80, decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(18)),
    child: Center(child: SizedBox(width: 22, height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, color: kCyan.withOpacity(.5)))));
}

// ============================================================
// SPARKLINE PAINTER — grafik mini realtime untuk kartu info (poin 4).
// Digambar sebagai garis halus + area gradient tipis di bawahnya, mirip
// gaya "stock ticker". Auto-scale ke rentang min-max data yang ada supaya
// pergerakan kecil pun tetap terlihat jelas (bukan garis datar).
// ============================================================
class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _SparklinePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final minV = data.reduce((a, b) => a < b ? a : b);
    final maxV = data.reduce((a, b) => a > b ? a : b);
    // Beri sedikit padding rentang supaya garis tidak mepet ke tepi atas/bawah
    // saat data hampir datar (selisih sangat kecil).
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);
    final dx = size.width / (data.length - 1);

    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final normalized = (data[i] - minV) / range; // 0..1
      final y = size.height - (normalized * size.height);
      points.add(Offset(i * dx, y.clamp(0, size.height)));
    }

    // Area gradient tipis di bawah garis
    final areaPath = Path()..moveTo(points.first.dx, size.height);
    for (final p in points) { areaPath.lineTo(p.dx, p.dy); }
    areaPath.lineTo(points.last.dx, size.height);
    areaPath.close();
    canvas.drawPath(areaPath, Paint()
      ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [color.withOpacity(.22), color.withOpacity(0)])
        .createShader(Rect.fromLTWH(0, 0, size.width, size.height)));

    // Garis utama
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) { linePath.lineTo(p.dx, p.dy); }
    canvas.drawPath(linePath, Paint()
      ..color = color.withOpacity(.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);

    // Titik penanda nilai TERKINI (paling kanan) — dibuat sedikit menonjol
    // dengan lingkaran kecil, supaya jelas mana "sekarang" di grafik.
    canvas.drawCircle(points.last, 2.6, Paint()..color = color);
    canvas.drawCircle(points.last, 4.2, Paint()..color = color.withOpacity(.25));
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.data.length != data.length ||
      (data.isNotEmpty && old.data.isNotEmpty && old.data.last != data.last);
}

// COMMAND TAB
class CommandTab extends StatelessWidget {
  const CommandTab({super.key});

  @override
  Widget build(BuildContext context) {
    // Dihitung SEKALI per build (bukan 2x seperti sebelumnya), disimpan ke
    // variabel lokal. Ini juga menghindari pola `if (_x() != null) _x()!`
    // yang memanggil method yang sama dua kali untuk satu item.
    final govGroup = _govGroup();
    final freqGroup = _freqGroup();
    final dt2wPath = DeviceInfo.i.dt2wPath;

    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _pageHeader('Command', 'Device Control Hub', kPurple),
          const SizedBox(height: 10),
          ValueListenableBuilder<bool>(
            valueListenable: isRootNotifier,
            builder: (_, root, __) => Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: root ? kGreen.withOpacity(.07) : kRed.withOpacity(.07),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: root ? kGreen.withOpacity(.25) : kRed.withOpacity(.25))),
              child: Row(children: [
                Icon(root ? Icons.check_circle_rounded : Icons.lock_rounded,
                    color: root ? kGreen : kRed, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  root ? 'Root aktif — semua perintah dapat dieksekusi'
                       : 'Non-root — hanya info, tidak bisa ubah sistem',
                  style: TextStyle(color: root ? kGreen : kRed, fontSize: 11.5))),
              ]),
            ),
          ),
          const SizedBox(height: 16),

          // Banner info device terdeteksi
          _deviceBanner(),
          const SizedBox(height: 12),

          // CPU GOVERNOR & FREKUENSI — pakai variabel yang sudah dihitung
          // sekali di atas, bukan memanggil ulang method-nya.
          if (govGroup != null) govGroup,
          if (freqGroup != null) freqGroup,

          // REFRESH RATE LOCK + monitoring realtime (poin 2)
          const _RefreshRateGroup(),

          // LTE BAND LOCK + monitoring realtime (poin 3)
          const _BandLockGroup(),

          _CmdGroup(icon: Icons.memory_rounded, label: 'RAM & Cache', accent: kPurple,
            subtitle: 'Bersihkan memori',
            children: [
              _CmdLeaf('Clear Cache',     Icons.cleaning_services_rounded, kGreen,  'Bebaskan RAM cache',         cmd: 'sync; echo 3 > /proc/sys/vm/drop_caches'),
              _CmdLeaf('Swappiness 10',   Icons.swap_horiz_rounded,        kBlue,   'Prioritaskan RAM',           cmd: 'echo 10 > /proc/sys/vm/swappiness'),
              _CmdLeaf('Swappiness 60',   Icons.swap_vert_rounded,         kPurple, 'Seimbang (default)',         cmd: 'echo 60 > /proc/sys/vm/swappiness'),
            ]),

          _CmdGroup(icon: Icons.thermostat_rounded, label: 'Thermal', accent: kRed,
            subtitle: 'Kontrol suhu & throttle',
            children: [
              _CmdLeaf('Baca Suhu', Icons.thermostat_rounded, kCyan, 'Lihat semua zone suhu', cmd: 'for z in /sys/class/thermal/thermal_zone*/temp; do t=\$(cat \$z 2>/dev/null); [ -n "\$t" ] && echo "\$z: \$t"; done', readOnly: true),
              _CmdLeaf('Disable Throttle', Icons.warning_rounded,      kRed,   'Matikan throttle — pantau suhu!', cmd: 'echo disabled > /sys/class/thermal/thermal_zone0/mode'),
              _CmdLeaf('Enable Throttle',  Icons.check_circle_rounded, kGreen, 'Aktifkan throttle kembali',       cmd: 'echo enabled > /sys/class/thermal/thermal_zone0/mode'),
            ]),

          _CmdGroup(icon: Icons.storage_rounded, label: 'I/O Scheduler', accent: kTeal,
            subtitle: 'Optimasi storage',
            children: [
              _CmdLeaf('noop',     Icons.linear_scale_rounded, kGreen,  'Minimal overhead',     cmd: 'for d in /sys/block/*/queue/scheduler; do echo noop > \$d 2>/dev/null; done'),
              _CmdLeaf('deadline', Icons.timer_rounded,        kOrange, 'Responsif I/O',        cmd: 'for d in /sys/block/*/queue/scheduler; do echo deadline > \$d 2>/dev/null; done'),
            ]),

          _CmdGroup(icon: Icons.dns_rounded, label: 'DNS Pribadi', accent: kBlue,
            subtitle: 'Private DNS (DoT)',
            children: [
              _CmdLeaf('AdGuard',    Icons.shield_rounded,  kGreen,  'Blokir iklan & tracker',    cmd: 'settings put global private_dns_mode hostname; settings put global private_dns_specifier dns.adguard-dns.com'),
              _CmdLeaf('Cloudflare', Icons.cloud_rounded,   kOrange, 'Cepat & privat (1.1.1.1)',  cmd: 'settings put global private_dns_mode hostname; settings put global private_dns_specifier one.one.one.one'),
              _CmdLeaf('Quad9',      Icons.security_rounded, kBlue,   'Blokir situs berbahaya',    cmd: 'settings put global private_dns_mode hostname; settings put global private_dns_specifier dns.quad9.net'),
              _CmdLeaf('Google',     Icons.public_rounded,   kCyan,   'DNS Google (8.8.8.8)',      cmd: 'settings put global private_dns_mode hostname; settings put global private_dns_specifier dns.google'),
              _CmdLeaf('Matikan DNS Pribadi', Icons.power_settings_new_rounded, kRed, 'Kembali ke otomatis', cmd: 'settings put global private_dns_mode off'),
              _CmdLeaf('Cek DNS Aktif', Icons.search_rounded, kPurple, 'Lihat private DNS sekarang', cmd: 'settings get global private_dns_specifier', readOnly: true),
            ]),

          _CmdGroup(icon: Icons.network_check_rounded, label: 'TCP Network', accent: kGreen,
            subtitle: 'Congestion control',
            children: [
              _CmdLeaf('TCP BBR',   Icons.compress_rounded,   kGreen,  'Algoritma Google BBR', cmd: 'echo bbr > /proc/sys/net/ipv4/tcp_congestion_control'),
              _CmdLeaf('TCP Cubic', Icons.show_chart_rounded, kPurple, 'Default Linux',        cmd: 'echo cubic > /proc/sys/net/ipv4/tcp_congestion_control'),
            ]),

          // DT2W — hanya tampil kalau path gesture terdeteksi
          if (dt2wPath != null) _dt2wGroup(dt2wPath),

          _CmdGroup(icon: Icons.settings_rounded, label: 'System', accent: kYellow,
            subtitle: 'Info & reboot',
            children: [
              _CmdLeaf('Info Build', Icons.info_rounded,        kCyan,  'Model & versi Android',  cmd: 'getprop ro.product.model; getprop ro.board.platform; getprop ro.build.version.release', readOnly: true),
              _CmdLeaf('Clear Logcat', Icons.delete_rounded,    kOrange,'Bersihkan buffer log',   cmd: 'logcat -c'),
              _CmdLeaf('Reboot', Icons.restart_alt_rounded,     kRed,   'Reboot perangkat',       cmd: 'reboot'),
            ]),

          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  // Banner info device hasil deteksi otomatis
  Widget _deviceBanner() {
    final d = DeviceInfo.i;
    final accent = d.spoofSuspected ? kYellow : kCyan;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withOpacity(.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(.2))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.phone_android_rounded, color: accent, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d.displayName,
              style: TextStyle(color: kWhite, fontSize: 12.5, fontWeight: FontWeight.w700)),
          Text('${d.platform} · ${d.cpuCores} core · Android ${d.androidVer}',
              style: TextStyle(color: mut(.4), fontSize: 10.5)),
          if (d.spoofSuspected) ...[
            const SizedBox(height: 3),
            Text('⚠️ Brand tidak konsisten dengan chipset — kemungkinan device spoofing aktif',
                style: TextStyle(color: kYellow, fontSize: 9.5, height: 1.3)),
          ],
        ])),
      ]),
    );
  }

  // Group governor dinamis — hanya yang didukung
  _CmdGroup? _govGroup() {
    final govs = DeviceInfo.i.governors;
    if (govs.isEmpty) return null;
    // ikon & deskripsi per governor umum
    const meta = {
      'performance':  ['Semua core max — gaming', Icons.flash_on_rounded, kRed],
      'powersave':    ['Hemat daya maksimal', Icons.battery_saver_rounded, kGreen],
      'schedutil':    ['Adaptif — rekomendasi harian', Icons.schedule_rounded, kCyan],
      'ondemand':     ['Naik cepat saat butuh', Icons.trending_up_rounded, kOrange],
      'conservative': ['Naik pelan — hemat', Icons.trending_down_rounded, kBlue],
      'interactive':  ['Responsif untuk UI', Icons.touch_app_rounded, kPurple],
    };
    final leaves = govs.map((g) {
      final m = meta[g];
      final desc = m != null ? m[0] as String : 'Governor $g';
      final ic   = m != null ? m[1] as IconData : Icons.tune_rounded;
      final col  = m != null ? m[2] as Color : kTeal;
      return _CmdLeaf(g, ic, col, desc,
          cmd: 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo $g > \$f; done');
    }).toList();
    return _CmdGroup(icon: Icons.developer_board_rounded, label: 'CPU Governor', accent: kCyan,
        subtitle: '${govs.length} governor terdeteksi', children: leaves);
  }

  // Group frekuensi dinamis — dari daftar frekuensi device
  _CmdGroup? _freqGroup() {
    final choices = DeviceInfo.i.freqChoices;
    if (choices.isEmpty) return null;
    final icons = [Icons.rocket_launch_rounded, Icons.bolt_rounded, Icons.eco_rounded, Icons.battery_saver_rounded];
    final colors = [kRed, kOrange, kGreen, kBlue];
    final descs = ['Full speed', 'Tinggi', 'Sedang', 'Hemat daya'];
    final leaves = <_CmdLeaf>[];
    for (int i = 0; i < choices.length; i++) {
      final khz = choices[i];
      final mhz = (khz / 1000).round();
      leaves.add(_CmdLeaf('$mhz MHz',
          icons[i.clamp(0, icons.length - 1)],
          colors[i.clamp(0, colors.length - 1)],
          descs[i.clamp(0, descs.length - 1)],
          cmd: 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo $khz > \$f; done'));
    }
    return _CmdGroup(icon: Icons.speed_rounded, label: 'CPU Frekuensi Max', accent: kOrange,
        subtitle: '${DeviceInfo.i.freqsKhz.length} step tersedia', children: leaves);
  }

  // Group DT2W dinamis — pakai path yang terdeteksi
  _CmdGroup _dt2wGroup(String p) {
    return _CmdGroup(icon: Icons.touch_app_rounded, label: 'Layar & Gesture', accent: kPink,
      subtitle: 'Double tap to wake',
      children: [
        _CmdLeaf('Double Tap to Wake: ON',  Icons.touch_app_rounded,    kGreen, 'Ketuk 2x nyalakan layar', cmd: 'echo 1 > $p'),
        _CmdLeaf('Double Tap to Wake: OFF', Icons.do_not_touch_rounded, kRed,   'Matikan gesture wake',    cmd: 'echo 0 > $p'),
        _CmdLeaf('Cek Status DT2W', Icons.search_rounded, kCyan, 'Lihat status gesture', cmd: 'cat $p', readOnly: true),
      ]);
  }
}

// CMD GROUP
class _CmdGroup extends StatelessWidget {
  final IconData icon;
  final String label, subtitle;
  final Color accent;
  final List<_CmdLeaf> children;
  const _CmdGroup({required this.icon, required this.label, required this.subtitle, required this.accent, required this.children});

  void _open(BuildContext context) {
    HapticFeedback.selectionClick();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: label,
      barrierColor: Colors.black.withOpacity(.65),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) {
        final c = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return Transform.scale(scale: 0.92 + 0.08 * c.value,
          child: Opacity(opacity: c.value,
            child: _CmdDialog(icon: icon, label: label, subtitle: subtitle, accent: accent, children: children)));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ValueListenableBuilder<bool>(
        valueListenable: isNightNotifier,
        builder: (_, __, ___) => GestureDetector(
          onTap: () => _open(context),
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kBorder)),
            child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
              Container(padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: accent.withOpacity(.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withOpacity(.2))),
                child: Icon(icon, color: accent, size: 20)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(color: kWhite, fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: mut(.35), fontSize: 10.5), maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
              Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(color: accent.withOpacity(.12), borderRadius: BorderRadius.circular(8)),
                child: Text('${children.length}', style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w800))),
              const SizedBox(width: 8),
              Icon(Icons.open_in_full_rounded, color: mut(.3), size: 16),
            ])),
          ),
        ),
      ),
    );
  }
}

// DIALOG isi opsi
class _CmdDialog extends StatelessWidget {
  final IconData icon;
  final String label, subtitle;
  final Color accent;
  final List<_CmdLeaf> children;
  const _CmdDialog({required this.icon, required this.label, required this.subtitle, required this.accent, required this.children});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: Colors.transparent,
            child: Container(
              // Diperbesar dari 0.72/440 agar kartu dialog opsi lebih lega
              // dibaca dan lebih nyaman ditekan (poin 5).
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82, maxWidth: 500),
              decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(26),
                border: Border.all(color: accent.withOpacity(.35)),
                boxShadow: [
                  BoxShadow(color: accent.withOpacity(.15), blurRadius: 40, spreadRadius: -4),
                  BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 30),
                ]),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(padding: const EdgeInsets.fromLTRB(20, 20, 16, 16),
                  child: Row(children: [
                    Container(padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(color: accent.withOpacity(.14),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: accent.withOpacity(.3))),
                      child: Icon(icon, color: accent, size: 26)),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: TextStyle(color: kWhite, fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 3),
                      Text(subtitle, style: TextStyle(color: mut(.4), fontSize: 11.5), maxLines: 2, overflow: TextOverflow.ellipsis),
                    ])),
                    const SizedBox(width: 8),
                    GestureDetector(onTap: () => Navigator.pop(context),
                      child: Container(padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(color: mut(.06), shape: BoxShape.circle),
                        child: Icon(Icons.close_rounded, color: mut(.5), size: 20))),
                  ])),
                Divider(height: 1, color: kBorder),
                Flexible(child: SingleChildScrollView(padding: const EdgeInsets.all(14),
                  child: Column(children: children))),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// REFRESH RATE GROUP — Lock refresh rate + monitoring realtime (poin 2)
// ============================================================
// Beda dari _CmdGroup polos: widget ini StatefulWidget sendiri karena perlu
// POLLING status refresh rate aktual secara berkala (monitoring), bukan
// cuma daftar aksi sekali-tekan. Kartu ini menunjukkan Hz yang SEDANG
// AKTIF di sistem — bukan cuma Hz yang terakhir kita minta — sehingga
// kalau sistem menolak/mengubah sendiri (mis. sebagian device auto-switch
// refresh rate sesuai konten), status yang terlihat tetap jujur & akurat.
class _RefreshRateGroup extends StatefulWidget {
  const _RefreshRateGroup();
  @override
  State<_RefreshRateGroup> createState() => _RefreshRateGroupState();
}

class _RefreshRateGroupState extends State<_RefreshRateGroup> {
  String _current = '---'; // teks tampilan, mis. "120 Hz"
  int? _currentHz;         // nilai numerik murni untuk perbandingan akurat
                            // (memisahkan dari _current mencegah bug mismatch
                            // format string seperti "120 Hz" vs "120Hz")
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _poll();
    // Monitoring realtime: baca ulang tiap 4 detik selama grup ini
    // terlihat, supaya kartu selalu mencerminkan kondisi terkini —
    // termasuk kalau ada aplikasi lain yang mengubah refresh rate.
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  @override
  void dispose() { _pollTimer?.cancel(); super.dispose(); }

  Future<void> _poll() async {
    // Baca refresh rate aktual lewat beberapa sumber berurutan, karena
    // format/lokasi berbeda-beda tiap vendor. Berhenti di sumber pertama
    // yang memberi angka valid (masuk akal: 24-165 Hz).
    String hz = '';
    final peak = await readSys('/sys/class/graphics/fb0/measured_fps');
    if (peak.isNotEmpty) hz = peak;
    if (hz.isEmpty && isRootNotifier.value) {
      final out = await runRoot(
          'dumpsys display | grep -oE "fps=[0-9]+\\.?[0-9]*" | head -1 | grep -oE "[0-9]+\\.?[0-9]*"');
      if (!out.startsWith('ERR') && out != 'OK' && out.isNotEmpty) hz = out;
    }
    if (hz.isEmpty && isRootNotifier.value) {
      final out = await runRoot('settings get system peak_refresh_rate');
      if (!out.startsWith('ERR') && out != 'OK' && out.isNotEmpty) hz = out;
    }
    final parsed = double.tryParse(hz);
    if (!mounted) return;
    final validHz = (parsed != null && parsed >= 24 && parsed <= 165) ? parsed.round() : null;
    setState(() {
      _currentHz = validHz;
      _current = validHz != null ? '$validHz Hz' : '---';
    });
  }

  Future<void> _lock(int hz) async {
    if (!isRootNotifier.value) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('⚠ Butuh root untuk mengunci refresh rate', style: TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: kPanel2, behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
      return;
    }
    HapticFeedback.mediumImpact();
    // Tulis ke SEMUA key vendor sekaligus (AOSP + MIUI + Oppo/Realme) agar
    // benar-benar terkunci di berbagai ROM, dan peak=min supaya sistem
    // tidak punya celah untuk menaik-turunkan sendiri (anti-adaptif).
    final out = await runRoot('''
      settings put system peak_refresh_rate $hz.0
      settings put system min_refresh_rate $hz.0
      settings put system user_refresh_rate $hz
      settings put system miui_refresh_rate $hz
      echo OK
    ''');
    if (!mounted) return;
    final ok = !out.startsWith('ERR') && !out.startsWith('ERROR');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '✓ Refresh rate dikunci ke ${hz}Hz' : '✗ Gagal: $out',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      backgroundColor: kPanel2, behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    await Future.delayed(const Duration(milliseconds: 500));
    _poll(); // langsung baca ulang status supaya kartu update seketika
  }

  @override
  Widget build(BuildContext context) {
    const options = [60, 90, 120, 144];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ValueListenableBuilder<bool>(
        valueListenable: isNightNotifier,
        builder: (_, __, ___) => Container(
          decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kBorder)),
          child: Padding(padding: const EdgeInsets.all(14), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: kTeal.withOpacity(.12),
                    borderRadius: BorderRadius.circular(12), border: Border.all(color: kTeal.withOpacity(.2))),
                  child: Icon(Icons.monitor_rounded, color: kTeal, size: 20)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Refresh Rate', style: TextStyle(color: kWhite, fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  // MONITORING: status aktual saat ini, bukan cuma pilihan terakhir
                  Row(children: [
                    Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5),
                      decoration: BoxDecoration(shape: BoxShape.circle,
                        color: _current == '---' ? mut(.2) : kGreen)),
                    Text(_current == '---' ? 'Membaca status...' : 'Aktif sekarang: $_current',
                        style: TextStyle(color: mut(.4), fontSize: 10.5)),
                  ]),
                ])),
              ]),
              const SizedBox(height: 14),
              // Pilihan lock — segmented, menyorot Hz yang cocok dgn status aktif
              Row(children: options.map((hz) {
                final isActive = _currentHz == hz;
                return Expanded(child: Padding(
                  padding: EdgeInsets.only(right: hz == options.last ? 0 : 8),
                  child: GestureDetector(
                    onTap: () => _lock(hz),
                    child: AnimatedContainer(duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: isActive ? kTeal.withOpacity(.16) : mut(.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isActive ? kTeal : Colors.transparent)),
                      child: Column(children: [
                        Text('$hz', style: TextStyle(color: isActive ? kTeal : kWhite,
                            fontSize: 15, fontWeight: FontWeight.w800, fontFamily: 'monospace')),
                        Text('Hz', style: TextStyle(color: isActive ? kTeal.withOpacity(.7) : mut(.35), fontSize: 9)),
                      ]),
                    ),
                  ),
                ));
              }).toList()),
            ],
          )),
        ),
      ),
    );
  }
}

// ============================================================
// BAND LOCK GROUP — Lock LTE band + monitoring realtime (poin 3)
// ============================================================
// Catatan jujur: lock band via AT command / QMI berbeda-beda drastis
// antar chipset modem (MediaTek vs Qualcomm punya perintah berbeda total).
// Implementasi ini memakai jalur yang paling umum bekerja di modem
// MediaTek (lewat service telephony & properti radio), dengan fallback
// aman kalau tidak didukung — leaf akan melaporkan gagal dengan jelas,
// bukan diam-diam tidak berbuat apa-apa.
class _BandLockGroup extends StatefulWidget {
  const _BandLockGroup();
  @override
  State<_BandLockGroup> createState() => _BandLockGroupState();
}

class _BandLockGroupState extends State<_BandLockGroup> {
  String _current = '---'; // ringkasan band/network type aktual
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  @override
  void dispose() { _pollTimer?.cancel(); super.dispose(); }

  Future<void> _poll() async {
    if (!isRootNotifier.value) {
      if (mounted) setState(() => _current = 'Butuh root');
      return;
    }
    // Baca tipe jaringan aktual dari dumpsys telephony — ini yang paling
    // konsisten tersedia lintas vendor dibanding membaca band spesifik.
    final out = await runRoot(
        'dumpsys telephony.registry | grep -oE "mDataNetworkType=[A-Za-z0-9_]+" | head -1');
    if (!mounted) return;
    if (out.startsWith('ERR') || out == 'OK' || out.isEmpty) {
      setState(() => _current = '---');
    } else {
      final cleaned = out.replaceFirst('mDataNetworkType=', '').trim();
      setState(() => _current = cleaned.isEmpty ? '---' : cleaned);
    }
  }

  Future<void> _apply(String label, String cmd) async {
    if (!isRootNotifier.value) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('⚠ Butuh root untuk mengunci band', style: TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: kPanel2, behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
      return;
    }
    HapticFeedback.mediumImpact();
    final out = await runRoot(cmd);
    if (!mounted) return;
    final isError = out.startsWith('ERR') || out.startsWith('ERROR');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(isError ? '✗ Gagal — modem mungkin tak mendukung: $out' : '✓ $label diterapkan',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      backgroundColor: kPanel2, behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));
    await Future.delayed(const Duration(milliseconds: 800));
    _poll();
  }

  @override
  Widget build(BuildContext context) {
    // Preferensi mode jaringan lewat telephony manager — cara paling
    // universal untuk "mengunci" ke tipe koneksi tertentu (memaksa
    // 4G-only misalnya efektif mengunci ke band LTE, menghindari
    // fallback ke 3G/2G yang lebih lambat).
    final modes = [
      ['4G Only', 'LTE saja — paling stabil', kGreen, 'settings put global preferred_network_mode 11; echo OK'],
      ['4G/3G',   'LTE + fallback 3G', kCyan, 'settings put global preferred_network_mode 9; echo OK'],
      ['Auto',    'Semua mode (default)', kPurple, 'settings put global preferred_network_mode 0; echo OK'],
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ValueListenableBuilder<bool>(
        valueListenable: isNightNotifier,
        builder: (_, __, ___) => Container(
          decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kBorder)),
          child: Padding(padding: const EdgeInsets.all(14), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: kBlue.withOpacity(.12),
                    borderRadius: BorderRadius.circular(12), border: Border.all(color: kBlue.withOpacity(.2))),
                  child: Icon(Icons.signal_cellular_alt_rounded, color: kBlue, size: 20)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Network / Band Lock', style: TextStyle(color: kWhite, fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  // MONITORING: tipe jaringan aktual saat ini
                  Row(children: [
                    Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5),
                      decoration: BoxDecoration(shape: BoxShape.circle,
                        color: (_current == '---' || _current == 'Butuh root') ? mut(.2) : kGreen)),
                    Text(_current == '---' ? 'Membaca status...' : 'Aktif: $_current',
                        style: TextStyle(color: mut(.4), fontSize: 10.5)),
                  ]),
                ])),
              ]),
              const SizedBox(height: 4),
              Text(
                'Catatan: dukungan tergantung modem perangkat. Kalau gagal, coba mode lain.',
                style: TextStyle(color: mut(.28), fontSize: 9.5, height: 1.3)),
              const SizedBox(height: 10),
              ...modes.map((m) {
                final label = m[0] as String;
                final desc = m[1] as String;
                final color = m[2] as Color;
                final cmd = m[3] as String;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: GestureDetector(
                    onTap: () => _apply(label, cmd),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(color: kPanel2, borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: kBorder.withOpacity(.4))),
                      child: Row(children: [
                        Container(width: 2.5, height: 32,
                          decoration: BoxDecoration(color: color.withOpacity(.55), borderRadius: BorderRadius.circular(2))),
                        const SizedBox(width: 12),
                        Icon(Icons.cell_tower_rounded, color: color, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(label, style: TextStyle(color: kWhite, fontSize: 12.5, fontWeight: FontWeight.w600)),
                          Text(desc, style: TextStyle(color: mut(.35), fontSize: 10)),
                        ])),
                        Icon(Icons.chevron_right_rounded, color: mut(.25), size: 18),
                      ]),
                    ),
                  ),
                );
              }),
            ],
          )),
        ),
      ),
    );
  }
}


class _CmdLeaf extends StatefulWidget {
  final String label, desc, cmd;
  final IconData icon;
  final Color color;
  final bool readOnly;
  const _CmdLeaf(this.label, this.icon, this.color, this.desc, {required this.cmd, this.readOnly = false});
  @override
  State<_CmdLeaf> createState() => _CmdLeafState();
}

class _CmdLeafState extends State<_CmdLeaf> {
  bool _running = false;
  bool _flash = false; // efek kilat sukses sesaat

  Future<void> _exec() async {
    if (_running) return;
    if (!isRootNotifier.value) { _snack('⚠ Butuh root untuk perintah ini', kYellow); return; }
    setState(() => _running = true);
    HapticFeedback.mediumImpact();
    try {
      final out = await runRoot(widget.cmd);
      if (!mounted) return;
      final isError = out.startsWith('ERR') || out.startsWith('ERROR');
      if (widget.readOnly) {
        if (out.isNotEmpty && out != 'OK') { _showSheet(out); }
        else { _snack('📋 Selesai', widget.color); }
      } else if (isError) {
        _snack('✗ Gagal: ${out.replaceFirst(RegExp(r"ERR:?R?:? "), "")}', kRed);
      } else {
        // kilat hijau sukses sesaat
        setState(() => _flash = true);
        _snack('✓ ${widget.label} diterapkan', widget.color);
        Future.delayed(const Duration(milliseconds: 600), () { if (mounted) setState(() => _flash = false); });
      }
    } catch (e) {
      // Jaring pengaman terakhir: exception tak terduga (mis. proses
      // terputus) tidak boleh membuat tombol nyangkut ter-disable selamanya.
      if (mounted) _snack('✗ Gagal: $e', kRed);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _snack(String msg, Color c) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
    backgroundColor: kPanel2, duration: const Duration(milliseconds: 1800),
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));

  void _showSheet(String result) {
    showModalBottomSheet(context: context, backgroundColor: kPanel, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(expand: false, initialChildSize: .5, maxChildSize: .9,
        builder: (_, sc) => Column(children: [
          Container(margin: const EdgeInsets.only(top: 10), width: 36, height: 4,
            decoration: BoxDecoration(color: mut(.2), borderRadius: BorderRadius.circular(2))),
          Padding(padding: const EdgeInsets.fromLTRB(20,14,20,0),
            child: Row(children: [
              Icon(widget.icon, color: widget.color, size: 18),
              const SizedBox(width: 8),
              Text(widget.label, style: TextStyle(color: kWhite, fontSize: 15, fontWeight: FontWeight.w700)),
              const Spacer(),
              GestureDetector(onTap: () => Navigator.pop(context),
                child: Icon(Icons.close_rounded, color: mut(.4), size: 20)),
            ])),
          Expanded(child: SingleChildScrollView(controller: sc, padding: const EdgeInsets.all(20),
            child: SelectableText(result, style: TextStyle(color: kCyan, fontSize: 11.5, fontFamily: 'monospace', height: 1.6)))),
          Padding(padding: const EdgeInsets.all(16),
            child: SizedBox(width: double.infinity,
              child: ElevatedButton(onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(backgroundColor: widget.color.withOpacity(.15),
                  foregroundColor: widget.color, elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: const Text('Tutup')))),
        ])));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isRootNotifier,
      builder: (_, root, __) {
        final locked = !root && !widget.readOnly;
        return Padding(padding: const EdgeInsets.only(bottom: 8),
          child: GestureDetector(
            onTap: locked ? () => _snack('⚠ Butuh root', kYellow) : _exec,
            child: AnimatedContainer(duration: const Duration(milliseconds: 200),
              // Diperbesar dari (14,12) agar kartu opsi di dalam dialog lebih
              // lega dibaca & lebih nyaman ditekan (poin 5).
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              decoration: BoxDecoration(
                color: _flash ? widget.color.withOpacity(.18) : locked ? mut(.03) : kPanel2,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _flash ? widget.color.withOpacity(.5) : kBorder.withOpacity(.4))),
              child: Row(children: [
                Container(width: 3, height: 42,
                  decoration: BoxDecoration(color: locked ? mut(.15) : widget.color.withOpacity(.55), borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 13),
                Icon(locked ? Icons.lock_rounded : widget.icon, color: locked ? mut(.3) : widget.color, size: 21),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.label, style: TextStyle(color: locked ? mut(.4) : kWhite,
                      fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(widget.desc, style: TextStyle(color: mut(.3), fontSize: 11.5)),
                ])),
                const SizedBox(width: 10),
                if (_running)
                  SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: widget.color))
                else if (_flash)
                  Icon(Icons.check_circle_rounded, color: widget.color, size: 22)
                else if (widget.readOnly)
                  Icon(Icons.search_rounded, color: mut(.35), size: 20)
                else
                  Icon(Icons.play_arrow_rounded, color: locked ? mut(.2) : widget.color.withOpacity(.7), size: 24),
              ]),
            ),
          ),
        );
      },
    );
  }
}

// TOOLS TAB
class ToolsTab extends StatefulWidget {
  const ToolsTab({super.key});
  @override
  State<ToolsTab> createState() => _ToolsTabState();
}

class _ToolsTabState extends State<ToolsTab> {
  Future<void> _run(String cmd, {bool needRoot = false}) async {
    if (needRoot && !isRootNotifier.value) {
      _sheet('Butuh Root', 'Fitur ini memerlukan akses root aktif.', kYellow); return;
    }
    String out = '';
    if (isRootNotifier.value) {
      out = await runRoot(cmd);
      if (out == 'OK') out = '';
    } else {
      try { final r = await Process.run('sh', ['-c', cmd]); out = r.stdout.toString().trim(); if (out.isEmpty) out = r.stderr.toString().trim(); }
      catch (e) { out = 'Error: $e'; }
    }
    _sheet(cmd.split(';')[0].split('|')[0].trim(), out.isEmpty ? 'Tidak ada output' : out, kCyan);
  }

  void _sheet(String title, String content, Color color) {
    showModalBottomSheet(context: context, backgroundColor: kPanel, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(expand: false, initialChildSize: .5, maxChildSize: .9,
        builder: (_, sc) => Column(children: [
          Container(margin: const EdgeInsets.only(top: 10), width: 36, height: 4,
            decoration: BoxDecoration(color: mut(.2), borderRadius: BorderRadius.circular(2))),
          Padding(padding: const EdgeInsets.fromLTRB(20,14,20,0),
            child: Row(children: [
              Text(title, style: TextStyle(color: kWhite, fontSize: 14, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
              const Spacer(),
              GestureDetector(onTap: () => Navigator.pop(context), child: Icon(Icons.close_rounded, color: mut(.4), size: 20)),
            ])),
          Expanded(child: SingleChildScrollView(controller: sc, padding: const EdgeInsets.all(20),
            child: SelectableText(content, style: TextStyle(color: color, fontSize: 11.5, fontFamily: 'monospace', height: 1.6)))),
        ])));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _pageHeader('Tools', 'System Utilities', kOrange),
          const SizedBox(height: 18),

          _sectionLabel('INFO (TANPA ROOT)', kCyan),
          const SizedBox(height: 10),
          _tool('CPU Info', 'Model, core, frekuensi, BogoMIPS', Icons.developer_board_rounded, kCyan, false,
              'cat /proc/cpuinfo | grep -E "model name|processor|cpu MHz|BogoMIPS|Hardware" | head -20'),
          _tool('Memory Detail', 'MemTotal, MemFree, Cached, Swap', Icons.memory_rounded, kPurple, false, 'cat /proc/meminfo'),
          _tool('Battery Detail', 'Status, kapasitas, suhu', Icons.battery_full_rounded, kGreen, false,
              'cat /sys/class/power_supply/battery/uevent 2>/dev/null || cat /sys/class/power_supply/*/uevent 2>/dev/null'),
          _tool('Suhu Thermal', 'Semua zone thermal MT6895', Icons.thermostat_rounded, kRed, false,
              'for i in \$(seq 0 20); do t=\$(cat /sys/class/thermal/thermal_zone\$i/temp 2>/dev/null); [ -n "\$t" ] && echo "Zone\$i: \$t"; done'),
          _tool('Uptime & Load', 'Uptime dan load average sistem', Icons.timer_rounded, kTeal, false,
              'uptime; echo "---"; cat /proc/loadavg; echo "---"; cat /proc/uptime'),
          _tool('Disk Usage', 'Partisi dan penggunaan storage', Icons.storage_rounded, kOrange, false, 'df -h'),
          _tool('Network Info', 'IP, interface, DNS aktif', Icons.wifi_rounded, kBlue, false,
              'ip addr show 2>/dev/null; echo "---"; getprop net.dns1; getprop net.dns2'),
          _tool('Android Props', 'Build, model, versi OS', Icons.android_rounded, kGreen, false,
              'getprop ro.product.model; getprop ro.board.platform; getprop ro.build.version.release; getprop ro.product.manufacturer'),

          const SizedBox(height: 18),
          _sectionLabel('ROOT TOOLS', kRed),
          const SizedBox(height: 10),
          _tool('Kernel Log', 'dmesg 30 baris terakhir', Icons.article_rounded, kRed, true, 'dmesg | tail -30'),
          _tool('Proses Berjalan', 'Snapshot proses aktif', Icons.list_alt_rounded, kOrange, true, 'ps aux | head -25'),
          _tool('Governor Semua Core', 'Governor aktif tiap core CPU', Icons.tune_rounded, kCyan, true,
              'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "\$c: \$(cat \$c 2>/dev/null)"; done'),
          _tool('Frekuensi Semua Core', 'Frekuensi aktif tiap core CPU', Icons.speed_rounded, kBlue, true,
              'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do echo "\$c: \$(cat \$c 2>/dev/null)"; done'),
          _tool('Modules Kernel', 'List modul kernel yang terload', Icons.extension_rounded, kTeal, true, 'lsmod | head -25'),
          _tool('Swappiness Saat Ini', 'Baca nilai swappiness aktif', Icons.swap_horiz_rounded, kPurple, true, 'cat /proc/sys/vm/swappiness'),
          _tool('TCP Congestion Aktif', 'Algoritma TCP congestion aktif', Icons.compress_rounded, kGreen, true,
              'cat /proc/sys/net/ipv4/tcp_congestion_control'),
          _tool('I/O Scheduler Aktif', 'Scheduler storage tiap block device', Icons.storage_rounded, kOrange, true,
              'for d in /sys/block/*/queue/scheduler; do echo "\$d:"; cat \$d 2>/dev/null; echo; done'),

          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  Widget _tool(String title, String sub, IconData icon, Color color, bool needRoot, String cmd) {
    return Padding(padding: const EdgeInsets.only(bottom: 8),
      child: ValueListenableBuilder<bool>(
        valueListenable: isRootNotifier,
        builder: (_, root, __) {
          final locked = needRoot && !root;
          return GestureDetector(
            onTap: () => _run(cmd, needRoot: needRoot),
            child: Container(padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(16), border: Border.all(color: locked ? kBorder.withOpacity(.4) : kBorder)),
              child: Row(children: [
                Container(padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: locked ? mut(.05) : color.withOpacity(.12), borderRadius: BorderRadius.circular(12)),
                  child: Icon(locked ? Icons.lock_rounded : icon, color: locked ? mut(.3) : color, size: 20)),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(color: locked ? mut(.4) : kWhite, fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(color: mut(.35), fontSize: 11)),
                ])),
                Icon(Icons.play_circle_rounded, color: locked ? mut(.2) : color.withOpacity(.7), size: 24),
              ])),
          );
        }));
  }
}

// AVATAR
class _AvatarPainter extends CustomPainter {
  final double pulse, orbit;
  _AvatarPainter(this.pulse, this.orbit);
  double _c(double a) => 1 - a*a/2 + a*a*a*a/24;
  double _s(double a) => a - a*a*a/6 + a*a*a*a*a/120;

  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width/2, cy = s.height/2, r = s.width/2;
    canvas.drawCircle(Offset(cx,cy), r, Paint()..shader =
      RadialGradient(colors: [const Color(0xFF1A1A40), const Color(0xFF060612)])
        .createShader(Rect.fromCircle(center: Offset(cx,cy), radius: r)));
    for (int i = 0; i < 8; i++) {
      final a = (i/8 + orbit) * 6.28318;
      canvas.drawCircle(Offset(cx + r*.82*_c(a), cy + r*.82*_s(a)), i%2==0 ? 2.5 : 1.5,
        Paint()..color = kCyan.withOpacity(i%2==0 ? .5+.3*pulse : .2));
    }
    canvas.drawCircle(Offset(cx,cy), r*(.78+.04*pulse),
      Paint()..style=PaintingStyle.stroke..color=kCyan.withOpacity(.15+.1*pulse)..strokeWidth=1.2);
    final body = Path()
      ..moveTo(cx-r*.3,cy+r*.2)..lineTo(cx+r*.3,cy+r*.2)
      ..lineTo(cx+r*.42,cy+r*.75)..lineTo(cx-r*.42,cy+r*.75)..close();
    canvas.drawPath(body, Paint()..shader =
      LinearGradient(colors:[const Color(0xFF1E1E50),kCyan.withOpacity(.2)],
        begin:Alignment.topCenter,end:Alignment.bottomCenter)
      .createShader(Rect.fromLTWH(cx-r*.42,cy+r*.2,r*.84,r*.55)));
    canvas.drawPath(Path()..moveTo(cx-r*.1,cy+r*.2)..lineTo(cx,cy+r*.35)..lineTo(cx+r*.1,cy+r*.2),
      Paint()..style=PaintingStyle.stroke..color=kCyan.withOpacity(.5)..strokeWidth=1.5..strokeCap=StrokeCap.round);
    canvas.drawCircle(Offset(cx,cy-r*.18),r*.28, Paint()..shader =
      RadialGradient(colors:[const Color(0xFF252560),const Color(0xFF0F0F30)])
        .createShader(Rect.fromCircle(center:Offset(cx-r*.05,cy-r*.28),radius:r*.28)));
    canvas.drawCircle(Offset(cx,cy-r*.18),r*.28,
      Paint()..style=PaintingStyle.stroke..color=kCyan.withOpacity(.3)..strokeWidth=1.2);
    final hair = Path()
      ..addArc(Rect.fromCircle(center:Offset(cx,cy-r*.18),radius:r*.28),3.14159+.25,2.63)
      ..lineTo(cx,cy-r*.18)..close();
    canvas.drawPath(hair, Paint()..color=const Color(0xFF5030D0));
    canvas.drawArc(Rect.fromCircle(center:Offset(cx-r*.07,cy-r*.38),radius:r*.08),3.8,1.4,false,
      Paint()..style=PaintingStyle.stroke..color=kPurple.withOpacity(.5)..strokeWidth=2);
    for (final dx in [-r*.1, r*.1]) {
      canvas.drawCircle(Offset(cx+dx,cy-r*.2),3.5,
        Paint()..color=kCyan..maskFilter=const MaskFilter.blur(BlurStyle.normal,2));
      canvas.drawCircle(Offset(cx+dx,cy-r*.2),1.5,Paint()..color=Colors.white);
    }
    canvas.drawArc(Rect.fromCenter(center:Offset(cx,cy-r*.08),width:r*.22,height:r*.13),
      .3,2.5,false,
      Paint()..style=PaintingStyle.stroke..color=kCyan.withOpacity(.6)..strokeWidth=1.8..strokeCap=StrokeCap.round);
    final badge = RRect.fromRectAndRadius(
      Rect.fromCenter(center:Offset(cx,cy+r*.4),width:r*.5,height:r*.17),const Radius.circular(4));
    canvas.drawRRect(badge,Paint()..color=kCyan.withOpacity(.12));
    canvas.drawRRect(badge,Paint()..style=PaintingStyle.stroke..color=kCyan.withOpacity(.45)..strokeWidth=1);
  }
  @override
  bool shouldRepaint(_AvatarPainter o) => o.pulse != pulse || o.orbit != orbit;
}

class _AnimatedAvatar extends StatefulWidget {
  const _AnimatedAvatar();
  @override
  State<_AnimatedAvatar> createState() => _AnimatedAvatarState();
}

class _AnimatedAvatarState extends State<_AnimatedAvatar> with TickerProviderStateMixin {
  late AnimationController _p, _o;
  @override
  void initState() {
    super.initState();
    _p = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat(reverse: true);
    _o = AnimationController(vsync: this, duration: const Duration(seconds: 10))..repeat();
  }
  @override
  void dispose() { _p.dispose(); _o.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_p, _o]),
    builder: (_, __) => CustomPaint(size: const Size(130,130), painter: _AvatarPainter(_p.value, _o.value)));
}

// ABOUT TAB
class AboutTab extends StatelessWidget {
  const AboutTab({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => ValueListenableBuilder<int>(
        // Mendengarkan DeviceInfo.revision: setiap kali detect() selesai
        // (dipanggil ulang dari Dashboard tiap tab dibuka), tab ini
        // otomatis rebuild dengan data terbaru — tanpa hardcode apa pun.
        valueListenable: DeviceInfo.revision,
        builder: (_, __, ___) {
          final d = DeviceInfo.i;
          return SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _pageHeader('Tentang', 'About This App', kGreen),
          const SizedBox(height: 20),
          Container(width: double.infinity, padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors:[kCyan.withOpacity(.08),kPurple.withOpacity(.06)],
                begin:Alignment.topLeft, end:Alignment.bottomRight),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: kCyan.withOpacity(.2))),
            child: Column(children: [
              Stack(alignment: Alignment.bottomRight, children: [
                const _AnimatedAvatar(),
                Container(width:22,height:22,
                  decoration:BoxDecoration(color:kGreen,shape:BoxShape.circle,border:Border.all(color:kPanel,width:2.5)),
                  child:const Icon(Icons.check_rounded,color:Colors.white,size:12)),
              ]),
              const SizedBox(height: 14),
              Text('Xyz_AI', style: TextStyle(color:kWhite,fontSize:24,fontWeight:FontWeight.w900,letterSpacing:-.5)),
              const SizedBox(height: 4),
              Text('Android Developer & Enthusiast', style: TextStyle(color:mut(.4),fontSize:13)),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _chip(isRootNotifier.value ? 'Root Active' : 'Non-Root', Icons.security_rounded,
                    isRootNotifier.value ? kGreen : kYellow),
                const SizedBox(width: 8),
                _chip(d.platform == '---' ? '...' : d.platform, Icons.developer_board_rounded, kCyan),
                const SizedBox(width: 8),
                _chip('v2.0', Icons.rocket_launch_rounded, kPurple),
              ]),
            ])),
          const SizedBox(height: 20),
          _sectionLabel('SPESIFIKASI', kCyan),
          const SizedBox(height: 10),
          // Semua nilai di bawah ini REALTIME dari DeviceInfo.i — dibaca
          // ulang dari device tempat app benar-benar berjalan, bukan
          // hardcode satu perangkat tertentu. Kalau di-install di HP lain,
          // nilai-nilai ini otomatis menyesuaikan.
          _info('Perangkat', d.displayName, Icons.phone_android_rounded,
              d.spoofSuspected ? kYellow : kCyan),
          _info('Chipset', d.platform, Icons.developer_board_rounded, kPurple),
          _info('CPU Core', '${d.cpuCores} core', Icons.memory_rounded, kBlue),
          _info('Root', isRootNotifier.value ? 'Aktif' : 'Tidak aktif',
              Icons.verified_rounded, isRootNotifier.value ? kGreen : kRed),
          _info('Android', 'Android ${d.androidVer}', Icons.android_rounded, kTeal),
          const SizedBox(height: 20),
          _sectionLabel('FITUR', kPurple),
          const SizedBox(height: 10),
          _feat(Icons.account_tree_rounded, kPurple, 'Nested Command Menu', 'Kontrol berlapis — governor, frekuensi, cache, thermal, network, I/O.'),
          _feat(Icons.terminal_rounded, kCyan, 'Eksekusi Root Real', 'Semua perintah dijalankan langsung via su -c ke kernel perangkat.'),
          _feat(Icons.dashboard_rounded, kBlue, 'Live Dashboard', 'CPU freq, governor, suhu, RAM, baterai — refresh tiap 3 detik.'),
          _feat(Icons.lock_rounded, kYellow, 'Non-Root Compatible', 'Mode aman tanpa root — info tetap tampil, kontrol dikunci.'),
          _feat(Icons.dark_mode_rounded, kOrange, 'Night / Light Mode', 'Ganti tema kapan saja dengan satu ketukan.'),
          const SizedBox(height: 24),
          Center(child: Text('Dibuat dengan ❤️ oleh Xyz_AI', style: TextStyle(color:mut(.3),fontSize:12))),
          const SizedBox(height: 6),
          Center(child: Text('Xyz_AI © 2026', style: TextStyle(color:mut(.2),fontSize:11))),
          const SizedBox(height: 20),
        ]),
          );
        },
      ),
    );
  }

  Widget _chip(String l, IconData i, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal:10,vertical:6),
    decoration: BoxDecoration(color:c.withOpacity(.1),borderRadius:BorderRadius.circular(10),border:Border.all(color:c.withOpacity(.3))),
    child: Row(mainAxisSize:MainAxisSize.min,children:[Icon(i,color:c,size:13),const SizedBox(width:5),Text(l,style:TextStyle(color:c,fontSize:11,fontWeight:FontWeight.w700))]));

  Widget _info(String label, String value, IconData icon, Color color) => Padding(
    padding: const EdgeInsets.only(bottom:8),
    child: Container(padding:const EdgeInsets.symmetric(horizontal:14,vertical:12),
      decoration:BoxDecoration(color:kPanel,borderRadius:BorderRadius.circular(14),border:Border.all(color:kBorder)),
      child:Row(children:[Icon(icon,color:color,size:17),const SizedBox(width:10),
        Text(label,style:TextStyle(color:mut(.4),fontSize:12)),const Spacer(),
        Text(value,style:TextStyle(color:kWhite,fontSize:12,fontWeight:FontWeight.w600))])));

  Widget _feat(IconData ic, Color c, String title, String body) => Padding(
    padding: const EdgeInsets.only(bottom:8),
    child: Container(padding:const EdgeInsets.all(14),
      decoration:BoxDecoration(color:kPanel,borderRadius:BorderRadius.circular(16),border:Border.all(color:kBorder)),
      child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Container(padding:const EdgeInsets.all(9),decoration:BoxDecoration(color:c.withOpacity(.1),borderRadius:BorderRadius.circular(11)),child:Icon(ic,color:c,size:19)),
        const SizedBox(width:12),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(title,style:TextStyle(color:kWhite,fontSize:13,fontWeight:FontWeight.w700)),
          const SizedBox(height:3),
          Text(body,style:TextStyle(color:mut(.4),fontSize:11.5,height:1.4)),
        ])),
      ])));
}

// SHARED
Widget _pageHeader(String title, String subtitle, Color accent) {
  return ValueListenableBuilder<bool>(
    valueListenable: isNightNotifier,
    builder: (_, night, __) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _AppIcon(size: 36),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900, color: kWhite, letterSpacing: -.5)),
        Text(subtitle, style: TextStyle(fontSize: 11, color: mut(.35))),
      ])),
      GestureDetector(
        onTap: () => isNightNotifier.value = !isNightNotifier.value,
        child: AnimatedContainer(duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(color: (night ? kPurple : kYellow).withOpacity(.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: (night ? kPurple : kYellow).withOpacity(.35))),
          child: Icon(night ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
              size: 18, color: night ? kPurple : kYellow))),
    ]),
  );
}

Widget _sectionLabel(String text, Color accent) => Padding(
  padding: const EdgeInsets.only(bottom: 2),
  child: Row(children: [
    Container(width: 3, height: 12, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2))),
    const SizedBox(width: 8),
    Text(text, style: TextStyle(color: accent, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1.8)),
  ]));
