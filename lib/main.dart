// ============================================================================
//  XYZ_AI — COMMAND CENTER · v2.1 "OPTIMIZED"
//  main.dart — arsitektur single-file · Flutter murni (tanpa plugin native)
// ============================================================================
//
//  PRINSIP OPTIMASI VERSI INI (kenapa scroll & sentuhan jadi responsif):
//
//  1. REBUILD TERKECIL MUNGKIN
//     Data live (CPU, RAM, baterai) tidak lagi memicu setState() satu halaman.
//     Semua data polling mengalir lewat ValueNotifier<DashStats> dan hanya
//     kartu statistik yang rebuild — header, banner, dan scroll view TIDAK
//     ikut dibangun ulang tiap 3 detik. Ini penyebab utama jank saat scroll
//     di versi lama.
//
//  2. POLLING SADAR-VISIBILITAS (TabGate)
//     Timer Dashboard / Refresh Rate / Band Lock / animasi Avatar hanya
//     berjalan ketika tab-nya benar-benar terlihat DAN aplikasi di foreground.
//     Pindah tab atau minimize app = semua polling & ticker berhenti otomatis.
//     Hemat baterai, bebas frame-drop dari pekerjaan latar.
//
//  3. IndexedStack SHELL
//     Keempat tab tetap hidup — posisi scroll & state tersimpan saat
//     berpindah tab, tanpa deteksi ulang / rebuild penuh setiap kali kembali.
//
//  4. I/O PARALEL & PATH TER-CACHE
//     Deteksi device dan polling dashboard memakai Future.wait (paralel),
//     bukan puluhan await berurutan. Thermal zone & path baterai dicari
//     SEKALI lalu di-cache — bukan scan 15 zona setiap 3 detik.
//
//  5. SADAR MULTI-CLUSTER (pelajaran penting perangkat ini)
//     CPU modern punya beberapa cluster (policy0 LITTLE / policy4 BIG /
//     policy7 PRIME) dengan tabel frekuensi BERBEDA. Membaca cpu0 saja
//     menyesatkan (selalu menampilkan clock cluster kecil), dan menulis satu
//     angka kHz ke semua core bisa ditolak kernel. Versi ini mendeteksi tiap
//     policy dan menerapkan frekuensi PROPORSIONAL per-cluster.
//
//  6. URUTAN TULIS FREKUENSI YANG AMAN
//     Aturan kernel: scaling_min_freq tidak boleh melewati scaling_max_freq
//     walau sesaat. Semua perintah frekuensi di sini menurunkan min lebih
//     dulu bila perlu, dan saat reset menulis MAX dulu baru MIN.
//
//  7. DT2W VIA SETTINGS, BUKAN NODE HARDWARE
//     Menulis langsung ke node touchscreen (mis. goodix gesture) terbukti
//     bisa me-reboot perangkat. Kontrol double-tap-to-wake kini memakai kunci
//     sistem `settings put system os_action_tapping_wake` yang aman.
//
//  8. UMPAN BALIK SENTUH INSTAN (widget Tap)
//     Semua elemen interaktif memberi respon visual (scale-down) begitu jari
//     menyentuh — sebelum tap selesai — sehingga UI terasa cepat bahkan di
//     dalam daftar yang sedang di-scroll. Fisik scroll memakai
//     BouncingScrollPhysics agar gerakan terasa halus dan natural.
//
// ============================================================================

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BOOTSTRAP
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    // Edge-to-edge modern: konten menggambar di belakang status & nav bar,
    // SafeArea yang mengatur jaraknya. Tampilan lebih premium di layar penuh.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
    runApp(const XyzAiApp());
  }, (e, s) => debugPrint('UNCAUGHT: $e'));
}

// ─────────────────────────────────────────────────────────────────────────────
// STATE GLOBAL
// ─────────────────────────────────────────────────────────────────────────────

/// Tema malam/terang — didengarkan tiap tab lewat ValueListenableBuilder.
final ValueNotifier<bool> isNightNotifier = ValueNotifier<bool>(true);

/// Status akses root — diverifikasi saat splash, bisa dicek ulang manual.
final ValueNotifier<bool> isRootNotifier = ValueNotifier<bool>(false);

/// Indeks tab yang sedang terlihat. Sumber kebenaran untuk [TabGate]:
/// semua polling & animasi berat menyalakan/mematikan diri berdasar nilai ini.
final ValueNotifier<int> activeTabIndex = ValueNotifier<int>(0);

bool get _night => isNightNotifier.value;

// ─────────────────────────────────────────────────────────────────────────────
// DESIGN TOKENS — warna, gerak, fisika scroll
// ─────────────────────────────────────────────────────────────────────────────

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

/// Warna teks "muted" adaptif tema. [o] = kekuatan (0..1).
Color mut(double o) => _night
    ? Colors.white.withOpacity(o)
    : const Color(0xFF080818).withOpacity(o.clamp(0.05, 0.9));

/// Token durasi & kurva animasi — satu sumber, konsisten di seluruh app.
class Motion {
  Motion._();
  static const Duration tap   = Duration(milliseconds: 90);
  static const Duration fast  = Duration(milliseconds: 160);
  static const Duration med   = Duration(milliseconds: 220);
  static const Curve    curve = Curves.easeOutCubic;
}

/// Fisika scroll seragam: bouncing terasa lebih hidup & responsif terhadap
/// jari, dan `AlwaysScrollable` menjaga pull-to-refresh tetap bisa dipicu
/// walau konten pendek.
const ScrollPhysics kScroll =
    BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

// ─────────────────────────────────────────────────────────────────────────────
// SERVICE LAYER — akses shell & filesystem, terbungkus rapi + timeout ketat
// ─────────────────────────────────────────────────────────────────────────────

/// Eksekusi perintah dengan hak root (`su -c`).
///
/// Catatan implementasi: perintah dikirim sebagai SATU argumen argv ke `su`,
/// jadi tidak perlu shell-quoting manual — aman untuk skrip multi-baris
/// sekalipun. Setiap panggilan dilindungi timeout supaya UI tidak pernah
/// menggantung menunggu proses yang macet.
class Root {
  Root._();

  /// Verifikasi akses root (uid=0). Timeout menjaga app tetap jalan bila
  /// popup izin superuser dibiarkan tanpa respons.
  static Future<bool> check() async {
    try {
      final r = await Process.run('su', ['-c', 'id']).timeout(
          const Duration(seconds: 5),
          onTimeout: () => ProcessResult(0, 1, '', 'timeout'));
      return r.stdout.toString().contains('uid=0');
    } catch (_) {
      return false;
    }
  }

  /// Jalankan [cmd] sebagai root. Mengembalikan:
  ///  * stdout (trim) bila ada,
  ///  * 'ERR: ...' bila hanya stderr,
  ///  * 'OK' bila sukses tanpa output,
  ///  * 'NO_ROOT' bila root belum aktif.
  static Future<String> exec(String cmd,
      {Duration timeout = const Duration(seconds: 8)}) async {
    if (!isRootNotifier.value) return 'NO_ROOT';
    try {
      final r = await Process.run('su', ['-c', cmd]).timeout(timeout,
          onTimeout: () => ProcessResult(0, 1, '',
              'Timeout — perintah menggantung atau device sedang berat.'));
      final out = r.stdout.toString().trim();
      final err = r.stderr.toString().trim();
      if (out.isNotEmpty) return out;
      if (err.isNotEmpty) return 'ERR: $err';
      return 'OK';
    } catch (e) {
      return 'ERROR: $e';
    }
  }
}

/// Akses baca sistem TANPA root (dengan fallback root hanya bila benar-benar
/// perlu — lihat catatan di [read]).
class Sys {
  Sys._();

  /// Baca file sysfs/procfs.
  ///
  /// Jalur cepat: baca langsung via dart:io (mikrodetik, tanpa spawn proses).
  /// Fallback `su cat` HANYA dipakai saat error-nya EACCES (ditolak izin) —
  /// file yang memang tidak ada TIDAK memicu spawn `su`, supaya polling
  /// berkala tidak menghambur-hamburkan proses root.
  static Future<String> read(String path) async {
    try {
      return (await File(path).readAsString()).trim();
    } on FileSystemException catch (e) {
      final denied = (e.osError?.errorCode ?? 0) == 13; // EACCES
      if (!denied || !isRootNotifier.value) return '';
    } catch (_) {
      return '';
    }
    try {
      final r = await Process.run('su', ['-c', 'cat "$path"']).timeout(
          const Duration(seconds: 4),
          onTimeout: () => ProcessResult(0, 1, '', 'timeout'));
      final out = r.stdout.toString().trim();
      if (out.isNotEmpty &&
          !out.contains('Permission denied') &&
          !out.contains('No such file')) {
        return out;
      }
    } catch (_) {}
    return '';
  }

  /// Baca properti Android (`getprop`) — selalu tersedia tanpa root.
  static Future<String> prop(String key) async {
    try {
      final r = await Process.run('getprop', [key]).timeout(
          const Duration(seconds: 4),
          onTimeout: () => ProcessResult(0, 1, '', 'timeout'));
      return r.stdout.toString().trim();
    } catch (_) {
      return '';
    }
  }

  /// Jalankan perintah shell BIASA (non-root) — dipakai leaf read-only &
  /// Tools saat root tidak tersedia. Semantik keluaran sama dengan
  /// [Root.exec] supaya pemanggil cukup satu jalur penanganan.
  static Future<String> sh(String cmd,
      {Duration timeout = const Duration(seconds: 6)}) async {
    try {
      final r = await Process.run('sh', ['-c', cmd]).timeout(timeout,
          onTimeout: () => ProcessResult(0, 1, '', 'timeout'));
      final out = r.stdout.toString().trim();
      final err = r.stderr.toString().trim();
      if (out.isNotEmpty) return out;
      if (err.isNotEmpty) return 'ERR: $err';
      return 'OK';
    } catch (e) {
      return 'ERROR: $e';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB GATE — inti dari "hemat daya & bebas jank"
// ─────────────────────────────────────────────────────────────────────────────

/// Menyalakan/mematikan pekerjaan berkala berdasarkan dua syarat sekaligus:
/// (1) tab pemiliknya sedang terlihat, dan (2) aplikasi berada di foreground.
///
/// Dipakai oleh: poller Dashboard, poller Refresh Rate, poller Band Lock,
/// dan ticker animasi Avatar. Berkat gate ini, IndexedStack bisa menjaga
/// state semua tab TANPA membayar biaya timer/animasi tab yang tak terlihat.
class TabGate with WidgetsBindingObserver {
  TabGate({required this.tab, required this.onChanged});

  /// Indeks tab pemilik (0=Dashboard, 1=Command, 2=Tools, 3=Tentang).
  final int tab;

  /// Dipanggil dengan `true` saat gate terbuka (mulai bekerja) dan `false`
  /// saat tertutup (hentikan semua pekerjaan).
  final void Function(bool active) onChanged;

  bool _resumed = true;
  bool _last = false;
  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    activeTabIndex.addListener(_eval);
    _eval();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
    activeTabIndex.removeListener(_eval);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _eval();
  }

  void _eval() {
    final active = _resumed && activeTabIndex.value == tab;
    if (active != _last) {
      _last = active;
      onChanged(active);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAP — umpan balik sentuh instan untuk SEMUA elemen interaktif
// ─────────────────────────────────────────────────────────────────────────────

/// Pengganti GestureDetector polos: begitu jari menyentuh, child langsung
/// mengecil halus (scale 0.97) — bahkan sebelum gesture tap diputuskan.
/// Efek psikologisnya besar: aplikasi terasa "mengikuti jari" walau sedang
/// berada di dalam daftar yang di-scroll. `HitTestBehavior.opaque` menjamin
/// seluruh area kartu bisa ditekan, bukan hanya teks/ikonnya.
class Tap extends StatefulWidget {
  const Tap({
    super.key,
    required this.child,
    this.onTap,
    this.enabled = true,
    this.pressedScale = .97,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final double pressedScale;

  @override
  State<Tap> createState() => _TapState();
}

class _TapState extends State<Tap> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled && widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: on ? (_) => _set(true) : null,
      onTapCancel: on ? () => _set(false) : null,
      onTapUp: on ? (_) => _set(false) : null,
      onTap: on ? widget.onTap : null,
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        duration: Motion.tap,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HELPER UI GLOBAL — snackbar, sheet output, dialog konfirmasi
// ─────────────────────────────────────────────────────────────────────────────

/// Snackbar seragam. Selalu menutup snackbar sebelumnya dulu supaya aksi
/// beruntun tidak menumpuk antrean (penyebab UI terasa "telat").
void showSnack(BuildContext context, String msg, {Color? bg}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
      backgroundColor: bg ?? kPanel2,
      duration: const Duration(milliseconds: 1600),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
}

/// Bottom-sheet hasil perintah (monospace, bisa diseleksi/salin).
void showOutputSheet(
  BuildContext context, {
  required String title,
  required String body,
  IconData icon = Icons.terminal_rounded,
  Color color = kCyan,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: kPanel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (sheetCtx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .5,
      maxChildSize: .92,
      builder: (_, sc) => Column(children: [
        Container(
            margin: const EdgeInsets.only(top: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
                color: mut(.2), borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 16, 0),
          child: Row(children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: kWhite,
                        fontSize: 15,
                        fontWeight: FontWeight.w700))),
            Tap(
                onTap: () => Navigator.pop(sheetCtx),
                child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(Icons.close_rounded, color: mut(.4), size: 20))),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: sc,
            physics: kScroll,
            padding: const EdgeInsets.all(20),
            child: SelectableText(body,
                style: TextStyle(
                    color: color,
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    height: 1.6)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: Tap(
              onTap: () => Navigator.pop(sheetCtx),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 13),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: color.withOpacity(.14),
                    borderRadius: BorderRadius.circular(12)),
                child: Text('Tutup',
                    style: TextStyle(
                        color: color, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ),
      ]),
    ),
  );
}

/// Dialog konfirmasi untuk perintah berdampak besar (reboot, matikan
/// throttle, dsb). Mengembalikan `true` hanya bila pengguna menekan Lanjut.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  Color accent = kRed,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withOpacity(.6),
    builder: (dctx) => Dialog(
      backgroundColor: kPanel,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: accent.withOpacity(.35))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: accent.withOpacity(.12), shape: BoxShape.circle),
              child:
                  Icon(Icons.warning_amber_rounded, color: accent, size: 26)),
          const SizedBox(height: 14),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: kWhite, fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: TextStyle(color: mut(.45), fontSize: 12.5, height: 1.5)),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: Tap(
                onTap: () => Navigator.pop(dctx, false),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: mut(.06),
                      borderRadius: BorderRadius.circular(12)),
                  child: Text('Batal',
                      style: TextStyle(
                          color: mut(.6), fontWeight: FontWeight.w700)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Tap(
                onTap: () => Navigator.pop(dctx, true),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: accent.withOpacity(.16),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: accent.withOpacity(.4))),
                  child: Text('Lanjut',
                      style: TextStyle(
                          color: accent, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ]),
        ]),
      ),
    ),
  );
  return ok ?? false;
}

// ─────────────────────────────────────────────────────────────────────────────
// DEVICE INFO — deteksi kemampuan perangkat, paralel & multi-cluster
// ─────────────────────────────────────────────────────────────────────────────

/// Satu cluster CPU (satu entri /sys/devices/system/cpu/cpufreq/policyN).
/// Tiap cluster punya tabel frekuensi sendiri — inilah alasan semua fitur
/// frekuensi di app ini bekerja per-policy, bukan per-cpu0.
class CpuPolicy {
  CpuPolicy({required this.index});

  final int index;
  int hwMinKhz = 0;
  int hwMaxKhz = 0;

  /// LITTLE / BIG / PRIME (diberi berdasarkan urutan hwMax antar cluster).
  String label = 'CL';

  String get path => '/sys/devices/system/cpu/cpufreq/policy$index';
  String get curFreqPath => '$path/scaling_cur_freq';
}

class DeviceInfo {
  DeviceInfo._();
  static final DeviceInfo i = DeviceInfo._();

  /// Sinyal "hasil deteksi berubah" — UI (Command, About, banner) cukup
  /// mendengarkan notifier ini untuk auto-rebuild, tanpa setState tersebar.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  String model = '---';
  String brand = '---';
  String platform = '---';
  String androidVer = '---';
  String cpuArch = '---';
  int cpuCores = 0;

  /// Nama tampilan setelah validasi silang brand vs chipset asli.
  String displayName = '---';
  bool spoofSuspected = false;

  final List<CpuPolicy> policies = [];
  List<String> governors = [];
  String? thermalPath;      // di-cache: dashboard tak perlu scan 15 zona/3dtk
  String? batteryTempPath;  // di-cache dengan alasan yang sama

  bool loaded = false;
  bool _busy = false;

  /// Ringkasan cluster untuk banner, mis. "LITTLE 2.0 · BIG 3.0 · PRIME 3.1 GHz".
  String get clusterSummary {
    if (policies.isEmpty) return '';
    final parts = policies
        .map((p) => '${p.label} ${(p.hwMaxKhz / 1000000).toStringAsFixed(1)}')
        .join(' · ');
    return '$parts GHz';
  }

  /// Aman dipanggil berulang (splash, buka shell, pull-to-refresh). Guard
  /// [_busy] mencegah dua deteksi berjalan bersamaan; timeout total menjamin
  /// proses tidak pernah menggantung tanpa batas.
  Future<void> detect() async {
    if (_busy) return;
    _busy = true;
    try {
      await _run().timeout(const Duration(seconds: 15), onTimeout: () {
        debugPrint('DeviceInfo.detect timeout — memakai data parsial');
      });
      loaded = true;
      revision.value++;
    } finally {
      _busy = false;
    }
  }

  Future<void> _run() async {
    // ── Properti dasar: 5 getprop sekaligus (paralel) ──
    final p = await Future.wait([
      Sys.prop('ro.product.model'),
      Sys.prop('ro.product.manufacturer'),
      Sys.prop('ro.board.platform'),
      Sys.prop('ro.build.version.release'),
      Sys.prop('ro.product.cpu.abi'),
    ]);
    model      = p[0].isEmpty ? '---' : p[0];
    brand      = p[1].isEmpty ? '---' : p[1];
    platform   = p[2].isEmpty ? '---' : p[2];
    androidVer = p[3].isEmpty ? '---' : p[3];
    cpuArch    = p[4].isEmpty ? '---' : p[4];

    // ── Validasi silang brand vs chipset asli ──
    // Properti brand/model gampang dipalsukan modul spoofing; chipset
    // (ro.board.platform) jauh lebih sulit karena dibaca driver kernel.
    // Kalau brand mengaku vendor yang mustahil untuk chipset ini, tampilkan
    // nama jujur berbasis chipset + tandai kecurigaan spoof.
    final pl = platform.toLowerCase();
    final bl = brand.toLowerCase();
    final looksMediatek = pl.contains('mt') || pl.startsWith('k6');
    final looksQualcomm = pl.contains('sm') ||
        pl.contains('msm') ||
        pl.contains('kona') ||
        pl.contains('lahaina');
    final claimsApple =
        bl.contains('apple') || model.toLowerCase().contains('iphone');
    spoofSuspected = claimsApple && (looksMediatek || looksQualcomm);

    if (spoofSuspected) {
      displayName = 'Android (chipset $platform)';
    } else if (model == '---' && brand == '---') {
      displayName = 'Perangkat tidak dikenal';
    } else {
      displayName = '$brand $model';
    }

    // ── Jumlah core: langsung dari runtime, tanpa loop 16 kali baca sysfs ──
    cpuCores = Platform.numberOfProcessors;
    if (cpuCores <= 0) cpuCores = 1;

    // ── Cluster CPU (policy*) ──
    policies.clear();
    final found = <int>[];
    try {
      final dir = Directory('/sys/devices/system/cpu/cpufreq');
      for (final e in dir.listSync(followLinks: false)) {
        final name = e.path.split('/').last;
        if (name.startsWith('policy')) {
          final n = int.tryParse(name.substring(6));
          if (n != null) found.add(n);
        }
      }
    } catch (_) {
      // fallback: probe policy0..9 secara paralel
      final probes = await Future.wait(List.generate(
          10,
          (n) => Sys.read(
              '/sys/devices/system/cpu/cpufreq/policy$n/scaling_cur_freq')));
      for (var n = 0; n < probes.length; n++) {
        if (probes[n].isNotEmpty) found.add(n);
      }
    }
    found.sort();

    if (found.isNotEmpty) {
      // Baca batas hardware tiap policy — semuanya paralel.
      final reads = await Future.wait(found.expand((n) sync* {
        yield Sys.read('/sys/devices/system/cpu/cpufreq/policy$n/cpuinfo_min_freq');
        yield Sys.read('/sys/devices/system/cpu/cpufreq/policy$n/cpuinfo_max_freq');
      }).toList());
      for (var k = 0; k < found.length; k++) {
        final pol = CpuPolicy(index: found[k])
          ..hwMinKhz = int.tryParse(reads[k * 2]) ?? 0
          ..hwMaxKhz = int.tryParse(reads[k * 2 + 1]) ?? 0;
        policies.add(pol);
      }
      // Label berdasarkan urutan clock maksimum antar cluster.
      final byMax = [...policies]
        ..sort((a, b) => a.hwMaxKhz.compareTo(b.hwMaxKhz));
      for (var k = 0; k < byMax.length; k++) {
        byMax[k].label = switch (policies.length) {
          1 => 'CPU',
          2 => const ['LITTLE', 'BIG'][k],
          3 => const ['LITTLE', 'BIG', 'PRIME'][k],
          _ => 'CL${k + 1}',
        };
      }
    }

    // ── Governor dari cluster pertama (umumnya identik antar cluster) ──
    final govPath = policies.isNotEmpty
        ? '${policies.first.path}/scaling_available_governors'
        : '/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors';
    governors = (await Sys.read(govPath))
        .split(RegExp(r'\s+'))
        .where((g) => g.isNotEmpty)
        .toList();

    // ── Thermal zone CPU: scan 20 zona SEKALI (paralel), simpan path valid ──
    final temps = await Future.wait(List.generate(
        20, (z) => Sys.read('/sys/class/thermal/thermal_zone$z/temp')));
    thermalPath = null;
    for (var z = 0; z < temps.length; z++) {
      final n = int.tryParse(temps[z]) ?? 0;
      if (n > 20000 && n < 100000) {
        thermalPath = '/sys/class/thermal/thermal_zone$z/temp';
        break;
      }
    }

    // ── Path suhu baterai: kandidat dibaca paralel, ambil yang pertama ada ──
    const candidates = [
      '/sys/class/power_supply/battery/temp',
      '/sys/class/power_supply/mtk-gauge/temp',
      '/sys/class/power_supply/bms/temp',
    ];
    final bt = await Future.wait(candidates.map(Sys.read));
    batteryTempPath = null;
    for (var k = 0; k < candidates.length; k++) {
      if (bt[k].isNotEmpty) {
        batteryTempPath = candidates[k];
        break;
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// APP
// ─────────────────────────────────────────────────────────────────────────────

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
          colorScheme: ColorScheme.fromSeed(
              seedColor: kCyan,
              brightness: night ? Brightness.dark : Brightness.light),
          splashFactory: NoSplash.splashFactory, // umpan balik via widget Tap
        ),
        home: const SplashScreen(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SPLASH
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _main, _orbit;
  late final Animation<double> _scale, _fade, _progress;
  String _status = 'Initializing...';

  @override
  void initState() {
    super.initState();
    _main = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2000))
      ..forward();
    _orbit =
        AnimationController(vsync: this, duration: const Duration(seconds: 8))
          ..repeat();
    _scale = CurvedAnimation(
        parent: _main,
        curve: const Interval(0.0, 0.5, curve: Curves.elasticOut));
    _fade = CurvedAnimation(
        parent: _main, curve: const Interval(0.4, 1.0, curve: Curves.easeOut));
    _progress = CurvedAnimation(parent: _main, curve: Curves.easeInOut);
    _boot();
  }

  Future<void> _boot() async {
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) setState(() => _status = 'Checking root...');
    final hasRoot = await Root.check();
    isRootNotifier.value = hasRoot;
    if (mounted) {
      setState(() => _status = hasRoot ? 'Root detected ✓' : 'Non-root mode');
    }
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) setState(() => _status = 'Detecting device...');
    await DeviceInfo.i.detect();
    if (mounted) setState(() => _status = DeviceInfo.i.displayName);
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 550),
        pageBuilder: (_, a, __) =>
            FadeTransition(opacity: a, child: const RootShell()),
      ),
    );
  }

  @override
  void dispose() {
    _main.dispose();
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF060612),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedBuilder(
            animation: Listenable.merge([_main, _orbit]),
            builder: (_, __) => Stack(alignment: Alignment.center, children: [
              Transform.rotate(
                angle: _orbit.value * 2 * math.pi,
                child: SizedBox(
                    width: 160,
                    height: 160,
                    child: CustomPaint(painter: _OrbitPainter(_orbit.value))),
              ),
              Container(
                width: 118 + 6 * (_orbit.value % 1),
                height: 118 + 6 * (_orbit.value % 1),
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: kCyan.withOpacity(0.10 * _scale.value.clamp(0, 1)),
                        width: 1)),
              ),
              ScaleTransition(scale: _scale, child: const _AppIcon(size: 92)),
            ]),
          ),
          const SizedBox(height: 36),
          FadeTransition(
            opacity: _fade,
            child: Column(children: [
              const Text('XYZ_AI',
                  style: TextStyle(
                      color: kCyan,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 8)),
              const SizedBox(height: 4),
              Text('COMMAND CENTER',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.3),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 5)),
              const SizedBox(height: 28),
              SizedBox(
                width: 160,
                child: AnimatedBuilder(
                  animation: _progress,
                  builder: (_, __) => Column(children: [
                    LinearProgressIndicator(
                        value: _progress.value,
                        minHeight: 2,
                        backgroundColor: Colors.white.withOpacity(0.06),
                        valueColor: const AlwaysStoppedAnimation(kCyan),
                        borderRadius: BorderRadius.circular(2)),
                    const SizedBox(height: 10),
                    Text(_status,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.35),
                            fontSize: 11,
                            fontFamily: 'monospace')),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// APP ICON — chip heksagon (dipakai splash & header halaman)
// ─────────────────────────────────────────────────────────────────────────────

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
              center: Alignment(-0.3, -0.3),
              colors: [Color(0xFF1C1C44), Color(0xFF080816)]),
          boxShadow: [
            BoxShadow(
                color: kCyan.withOpacity(.35), blurRadius: 26, spreadRadius: 1),
            BoxShadow(
                color: kPurple.withOpacity(.18),
                blurRadius: 46,
                spreadRadius: -6),
          ],
        ),
        child: CustomPaint(painter: _IconPainter(), size: Size(size, size)),
      );
}

class _IconPainter extends CustomPainter {
  Offset _hex(double cx, double cy, double r, int i) {
    final a = (i * 60 - 90) * math.pi / 180;
    return Offset(cx + r * math.cos(a), cy + r * math.sin(a));
  }

  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width / 2, cy = s.height / 2;
    final rOuter = s.width * 0.34, rInner = s.width * 0.16;

    final legPaint = Paint()
      ..color = kCyan.withOpacity(.5)
      ..strokeWidth = s.width * 0.022
      ..strokeCap = StrokeCap.round;
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
    canvas.drawPath(
        hexPath,
        Paint()
          ..shader = LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [kCyan.withOpacity(.18), kPurple.withOpacity(.08)])
              .createShader(
                  Rect.fromCircle(center: Offset(cx, cy), radius: rOuter)));
    canvas.drawPath(
        hexPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s.width * 0.028
          ..strokeJoin = StrokeJoin.round
          ..color = kCyan
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));

    final corePath = Path();
    for (int i = 0; i < 6; i++) {
      final p = _hex(cx, cy, rInner, i);
      i == 0 ? corePath.moveTo(p.dx, p.dy) : corePath.lineTo(p.dx, p.dy);
    }
    corePath.close();
    canvas.drawPath(
        corePath,
        Paint()
          ..shader = RadialGradient(colors: [kCyan, const Color(0xFF0080A0)])
              .createShader(
                  Rect.fromCircle(center: Offset(cx, cy), radius: rInner))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1));

    canvas.drawCircle(
        Offset(cx, cy),
        s.width * 0.045,
        Paint()
          ..color = Colors.white
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(
        Offset(cx, cy), s.width * 0.028, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.v);
  final double v;

  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width / 2, cy = s.height / 2, r = s.width / 2 - 4;
    for (int i = 0; i < 12; i++) {
      final a = (i / 12) * 2 * math.pi;
      canvas.drawCircle(
          Offset(cx + r * math.cos(a), cy + r * math.sin(a)),
          i % 3 == 0 ? 2.2 : 1.2,
          Paint()..color = kCyan.withOpacity(i % 3 == 0 ? .45 : .18));
    }
    final ma = v * 2 * math.pi;
    canvas.drawCircle(
        Offset(cx + r * math.cos(ma), cy + r * math.sin(ma)),
        4,
        Paint()
          ..color = kCyan
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.v != v;
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT SHELL — IndexedStack + bottom navigation
// ─────────────────────────────────────────────────────────────────────────────

class RootShell extends StatefulWidget {
  const RootShell({super.key});
  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _idx = 0;

  // IndexedStack: keempat tab hidup terus → posisi scroll & state awet saat
  // berpindah tab. Biaya latar (timer/animasi) nol berkat TabGate di tiap
  // komponen yang punya pekerjaan berkala.
  static const _pages = <Widget>[
    DashboardTab(),
    CommandTab(),
    ToolsTab(),
    AboutTab(),
  ];

  @override
  void initState() {
    super.initState();
    activeTabIndex.value = 0;
    // Deteksi ulang setiap kali shell terbentuk (cold start / kembali dari
    // proses mati) — app selalu mengenal device tempat ia berjalan sekarang.
    DeviceInfo.i.detect();
  }

  void _select(int i) {
    if (_idx == i) return;
    HapticFeedback.selectionClick();
    setState(() => _idx = i);
    activeTabIndex.value = i; // beri tahu semua TabGate
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, night, __) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          statusBarIconBrightness: night ? Brightness.light : Brightness.dark,
          systemNavigationBarIconBrightness:
              night ? Brightness.light : Brightness.dark,
        ),
        child: Scaffold(
          backgroundColor: kBg,
          body: SafeArea(
              bottom: false,
              child: IndexedStack(index: _idx, children: _pages)),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              color: kPanel,
              border: Border(top: BorderSide(color: kBorder, width: .5)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(.3),
                    blurRadius: 20,
                    offset: const Offset(0, -4))
              ],
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _navItem(0, Icons.dashboard_rounded, 'Dashboard', kCyan),
                    _navItem(1, Icons.account_tree_rounded, 'Command', kPurple),
                    _navItem(2, Icons.construction_rounded, 'Tools', kOrange),
                    _navItem(3, Icons.person_rounded, 'Tentang', kGreen),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(int i, IconData icon, String label, Color accent) {
    final on = _idx == i;
    return Tap(
      onTap: () => _select(i),
      pressedScale: .93,
      child: AnimatedContainer(
        duration: Motion.med,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
            color: on ? accent.withOpacity(.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: on ? accent.withOpacity(.3) : Colors.transparent)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 21, color: on ? accent : mut(.3)),
          const SizedBox(height: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                  color: on ? accent : mut(.3),
                  letterSpacing: .3)),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  DASHBOARD
//  Pola inti optimasi: seluruh data polling dibungkus satu objek
//  immutable [DashStats] yang dipublikasikan lewat ValueNotifier.
//  Hanya kartu statistik yang rebuild tiap 3 detik — header, banner,
//  dan scroll view TIDAK ikut rebuild, sehingga scroll tetap 60fps
//  walau timer sedang jalan.
// ═══════════════════════════════════════════════════════════════════

class DashStats {
  const DashStats({
    required this.ready,
    required this.freqText,
    required this.gov,
    required this.tempText,
    required this.tempC,
    required this.batText,
    required this.batTempText,
    required this.uptime,
    required this.memTotalMb,
    required this.memUsedMb,
    required this.freqHist,
    required this.tempHist,
    required this.memHist,
    required this.batHist,
  });

  final bool ready;
  final String freqText, gov, tempText, batText, batTempText, uptime;
  final double? tempC;
  final int memTotalMb, memUsedMb;
  final List<double> freqHist, tempHist, memHist, batHist;

  /// Kondisi awal sebelum sampel pertama masuk (skeleton tampil).
  static DashStats initial() => const DashStats(
      ready: false, freqText: '---', gov: '---', tempText: '---',
      tempC: null, batText: '---', batTempText: '---', uptime: '---',
      memTotalMb: 0, memUsedMb: 0,
      freqHist: [], tempHist: [], memHist: [], batHist: []);

  /// Dipakai setelah 2x polling gagal total: tampilkan '---' alih-alih
  /// membiarkan spinner skeleton berputar selamanya.
  static DashStats offline(List<double> f, List<double> t, List<double> m,
          List<double> b) =>
      DashStats(
          ready: true, freqText: '---', gov: '---', tempText: '---',
          tempC: null, batText: '---', batTempText: '---', uptime: '---',
          memTotalMb: 0, memUsedMb: 0,
          freqHist: f, tempHist: t, memHist: m, batHist: b);
}

class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key});
  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  final ValueNotifier<DashStats> _stats =
      ValueNotifier<DashStats>(DashStats.initial());

  late final TabGate _gate;
  Timer? _timer;
  bool _ticking = false; // cegah tick menumpuk bila I/O lambat
  int _fail = 0;

  // Riwayat untuk sparkline. Dibatasi 24 sampel (≈72 detik) supaya memori
  // konstan & repaint murah.
  static const int _histLen = 24;
  final List<double> _freqHist = [];
  final List<double> _tempHist = [];
  final List<double> _memHist = [];
  final List<double> _batHist = [];

  void _push(List<double> l, double v) {
    l.add(v);
    if (l.length > _histLen) l.removeAt(0);
  }

  @override
  void initState() {
    super.initState();
    // Polling HANYA saat tab Dashboard aktif DAN app di foreground.
    // Pindah tab / app ke background → timer berhenti → hemat baterai,
    // tidak ada proses baca sysfs sia-sia di belakang layar.
    _gate = TabGate(
      tab: 0,
      onChanged: (on) {
        if (on) {
          DeviceInfo.i.detect(); // selalu re-deteksi saat dashboard tampil
          _start();
        } else {
          _stop();
        }
      },
    )..attach();
  }

  void _start() {
    _timer?.cancel();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    _gate.detach();
    _stats.dispose();
    super.dispose();
  }

  int _kb(String meminfo, String key) {
    for (final l in meminfo.split('\n')) {
      if (l.startsWith(key)) {
        final parts = l.split(RegExp(r'\s+'));
        if (parts.length >= 2) return int.tryParse(parts[1]) ?? 0;
      }
    }
    return 0;
  }

  /// Satu siklus sampling. SEMUA pembacaan dijalankan paralel lewat
  /// Future.wait — total latensi = pembacaan terlambat, bukan penjumlahan
  /// semuanya (dulu: belasan await berurutan + scan 15 zona thermal).
  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final di = DeviceInfo.i;

      // Frekuensi dibaca PER-POLICY (LITTLE/BIG/PRIME). Membaca cpu0 saja
      // menyesatkan — cluster LITTLE hampir selalu menampilkan angka rendah
      // yang sama walau cluster PRIME sedang bekerja penuh.
      final freqPaths = di.policies.isNotEmpty
          ? di.policies.map((p) => p.curFreqPath).toList()
          : ['/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq'];
      final govPath = di.policies.isNotEmpty
          ? '${di.policies.first.path}/scaling_governor'
          : '/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor';
      final nFreq = freqPaths.length;

      final r = await Future.wait<String>([
        ...freqPaths.map(Sys.read),                                   // 0..n-1
        Sys.read(govPath),                                            // n
        di.thermalPath != null                                        // n+1
            ? Sys.read(di.thermalPath!)
            : Future<String>.value(''),
        Sys.read('/proc/meminfo'),                                    // n+2
        Sys.read('/proc/uptime'),                                     // n+3
        Sys.read('/sys/class/power_supply/battery/capacity'),         // n+4
        di.batteryTempPath != null                                    // n+5
            ? Sys.read(di.batteryTempPath!)
            : Future<String>.value(''),
      ]);

      // ── CPU: pakai frekuensi TERTINGGI antar cluster sebagai angka utama ──
      int khzMax = 0;
      for (int i = 0; i < nFreq; i++) {
        final v = int.tryParse(r[i]) ?? 0;
        if (v > khzMax) khzMax = v;
      }
      final freqText = khzMax <= 0
          ? '---'
          : khzMax >= 1000000
              ? '${(khzMax / 1000000).toStringAsFixed(2)} GHz'
              : '${(khzMax / 1000).round()} MHz';

      final gov = r[nFreq].isEmpty ? '---' : r[nFreq];

      // ── Thermal: path SUDAH di-cache oleh DeviceInfo.detect() ──
      double? tempC;
      final tRaw = int.tryParse(r[nFreq + 1]) ?? 0;
      if (tRaw > 25000 && tRaw < 120000) tempC = tRaw / 1000.0;
      final tempText =
          tempC == null ? '---' : '${tempC.toStringAsFixed(1)}°C';

      // ── Memori ──
      final mem = r[nFreq + 2];
      final mtMb = _kb(mem, 'MemTotal') ~/ 1024;
      final maMb = _kb(mem, 'MemAvailable') ~/ 1024;
      final usedMb = (mtMb - maMb).clamp(0, 1 << 30);

      // ── Uptime (dengan hari) ──
      final sec = double.tryParse(r[nFreq + 3].split(' ').first) ?? 0;
      final d = sec ~/ 86400, h = (sec % 86400) ~/ 3600, m = (sec % 3600) ~/ 60;
      final uptime = sec <= 0
          ? '---'
          : d > 0
              ? '${d}d ${h}h ${m}m'
              : '${h}h ${m}m';

      // ── Baterai ──
      final batPct = int.tryParse(r[nFreq + 4]);
      final batText = batPct == null ? '---' : '$batPct%';
      final btRaw = int.tryParse(r[nFreq + 5]) ?? 0;
      final batTempText = btRaw == 0
          ? '---'
          : btRaw.abs() > 100
              ? '${(btRaw / 10).toStringAsFixed(1)}°C'
              : '$btRaw°C';

      final allDead = khzMax <= 0 && mtMb <= 0 && sec <= 0;
      if (allDead) {
        _fail++;
        if (_fail >= 2) {
          _stats.value =
              DashStats.offline(_freqHist, _tempHist, _memHist, _batHist);
        }
        return;
      }
      _fail = 0;

      // Sampel tidak valid TIDAK dicatat — grafik bebas lonjakan palsu ke 0.
      if (khzMax > 0) _push(_freqHist, khzMax / 1000000);
      if (tempC != null) _push(_tempHist, tempC);
      if (mtMb > 0) _push(_memHist, usedMb / mtMb * 100);
      if (batPct != null) _push(_batHist, batPct.toDouble());

      // Publikasi objek baru → HANYA ValueListenableBuilder kartu yang
      // rebuild. Tidak ada setState halaman penuh.
      _stats.value = DashStats(
        ready: true,
        freqText: freqText,
        gov: gov,
        tempText: tempText,
        tempC: tempC,
        batText: batText,
        batTempText: batTempText,
        uptime: uptime,
        memTotalMb: mtMb,
        memUsedMb: usedMb,
        freqHist: _freqHist,
        tempHist: _tempHist,
        memHist: _memHist,
        batHist: _batHist,
      );
    } catch (e) {
      debugPrint('Dashboard tick error: $e');
    } finally {
      _ticking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => RefreshIndicator(
        onRefresh: () async {
          await DeviceInfo.i.detect();
          await _tick();
        },
        color: kCyan,
        backgroundColor: kPanel,
        child: SingleChildScrollView(
          physics: kScroll,
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _pageHeader('Dashboard', 'Live System Monitor', kCyan),
            const SizedBox(height: 14),
            const _RootBanner(),
            const SizedBox(height: 18),
            _sectionLabel('PROCESSOR', kCyan),
            const SizedBox(height: 10),
            // RepaintBoundary per seksi: repaint sparkline/angka terkurung
            // di area kartu, tidak merambat ke seluruh layar.
            RepaintBoundary(
              child: ValueListenableBuilder<DashStats>(
                valueListenable: _stats,
                builder: (_, s, __) {
                  if (!s.ready) return const _Skeleton(226);
                  final tempColor = s.tempC == null
                      ? kBlue
                      : s.tempC! > 55
                          ? kRed
                          : kGreen;
                  return Column(children: [
                    Row(children: [
                      Expanded(
                          child: _StatTile('CPU Freq', s.freqText,
                              Icons.speed_rounded, kCyan,
                              history: s.freqHist)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _StatTile('Governor', s.gov,
                              Icons.tune_rounded, kPurple)),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          child: _StatTile('CPU Temp', s.tempText,
                              Icons.thermostat_rounded, tempColor,
                              history: s.tempHist)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _StatTile('Uptime', s.uptime,
                              Icons.timer_rounded, kTeal)),
                    ]),
                  ]);
                },
              ),
            ),
            const SizedBox(height: 18),
            _sectionLabel('MEMORY', kPurple),
            const SizedBox(height: 10),
            RepaintBoundary(
              child: ValueListenableBuilder<DashStats>(
                valueListenable: _stats,
                builder: (_, s, __) => s.ready
                    ? _MemCard(totalMb: s.memTotalMb, usedMb: s.memUsedMb)
                    : const _Skeleton(96),
              ),
            ),
            const SizedBox(height: 18),
            _sectionLabel('BATTERY', kGreen),
            const SizedBox(height: 10),
            RepaintBoundary(
              child: ValueListenableBuilder<DashStats>(
                valueListenable: _stats,
                builder: (_, s, __) => s.ready
                    ? Row(children: [
                        Expanded(
                            child: _StatTile('Kapasitas', s.batText,
                                Icons.battery_full_rounded, kGreen,
                                history: s.batHist)),
                        const SizedBox(width: 10),
                        Expanded(
                            child: _StatTile('Suhu', s.batTempText,
                                Icons.device_thermostat_rounded, kOrange)),
                      ])
                    : const _Skeleton(108),
              ),
            ),
            const SizedBox(height: 24),
          ]),
        ),
      ),
    );
  }
}

/// Banner status root. Judul memakai chipset hasil deteksi (dinamis, bukan
/// hardcode 'MT6895'), dan badge ROOT/SAFE bisa DITEKAN untuk memeriksa
/// ulang akses root tanpa restart app.
class _RootBanner extends StatelessWidget {
  const _RootBanner();

  Future<void> _recheck(BuildContext context) async {
    showSnack(context, 'Memeriksa ulang akses root…');
    final ok = await Root.check();
    isRootNotifier.value = ok;
    if (!context.mounted) return;
    showSnack(context, ok ? 'Root terdeteksi ✓' : 'Root tidak tersedia',
        bg: ok ? const Color(0xFF0E3B2E) : null);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isRootNotifier,
      builder: (_, root, __) => ValueListenableBuilder<int>(
        valueListenable: DeviceInfo.revision,
        builder: (ctx, rev, child) {
          final plat = DeviceInfo.i.platform;
          final chip = plat == '---' ? 'System' : plat.toUpperCase();
          final c = root ? kGreen : kYellow;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
                color: c.withOpacity(.07),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.withOpacity(.25))),
            child: Row(children: [
              Icon(root ? Icons.verified_rounded : Icons.info_rounded,
                  color: c, size: 20),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(root ? 'Root Aktif — $chip' : 'Mode Non-Root',
                        style: TextStyle(
                            color: kWhite,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                    Text(
                        root
                            ? 'Akses penuh · Semua fitur tersedia'
                            : 'Mode aman — ketuk badge untuk cek ulang',
                        style: TextStyle(color: mut(.4), fontSize: 11)),
                  ])),
              Tap(
                onTap: () => _recheck(context),
                child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        color: c.withOpacity(.15),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(root ? 'ROOT' : 'SAFE',
                        style: TextStyle(
                            color: c,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1))),
              ),
            ]),
          );
        },
      ),
    );
  }
}

/// Kartu statistik. Tinggi tetap (108) agar layout stabil antar-update,
/// nilai dibungkus FittedBox supaya teks panjang ('schedutil') menyusut
/// rapi alih-alih overflow.
class _StatTile extends StatelessWidget {
  const _StatTile(this.label, this.value, this.icon, this.accent,
      {this.history});

  final String label, value;
  final IconData icon;
  final Color accent;
  final List<double>? history;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 108,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withOpacity(.18))),
      child: Stack(children: [
        // Sparkline realtime di lapisan belakang bawah kartu.
        if (history != null && history!.length >= 2)
          Positioned.fill(
            child: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                    height: 26,
                    child: CustomPaint(
                        painter: _SparklinePainter(history!, accent),
                        size: Size.infinite))),
          ),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: accent.withOpacity(.12),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: accent, size: 16)),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                maxLines: 1,
                style: TextStyle(
                    color: accent,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  color: mut(.38),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .8)),
        ]),
      ]),
    );
  }
}

class _MemCard extends StatelessWidget {
  const _MemCard({required this.totalMb, required this.usedMb});
  final int totalMb, usedMb;

  @override
  Widget build(BuildContext context) {
    final t = totalMb <= 0 ? 1 : totalMb;
    final pct = (usedMb / t).clamp(0.0, 1.0);
    final freeMb = (t - usedMb).clamp(0, 1 << 30);
    final barColor = pct > .85 ? kRed : pct > .65 ? kYellow : kPurple;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.memory_rounded, color: kPurple, size: 18),
          const SizedBox(width: 8),
          Text('RAM Usage',
              style: TextStyle(
                  color: kWhite, fontSize: 13, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(totalMb <= 0 ? '---' : '$usedMb / $totalMb MB',
              style: TextStyle(
                  color: kPurple,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
                value: pct,
                minHeight: 8,
                backgroundColor: mut(.06),
                valueColor: AlwaysStoppedAnimation(barColor))),
        const SizedBox(height: 8),
        Row(children: [
          Text('Free: ${totalMb <= 0 ? '---' : '$freeMb MB'}',
              style: TextStyle(color: mut(.4), fontSize: 11)),
          const Spacer(),
          Text('${(pct * 100).toStringAsFixed(0)}% used',
              style: TextStyle(color: mut(.4), fontSize: 11)),
        ]),
      ]),
    );
  }
}

/// Placeholder loading dengan tinggi eksplisit — layout tidak "loncat"
/// saat data pertama masuk.
class _Skeleton extends StatelessWidget {
  const _Skeleton(this.height);
  final double height;
  @override
  Widget build(BuildContext context) => Container(
      height: height,
      decoration: BoxDecoration(
          color: kPanel, borderRadius: BorderRadius.circular(18)),
      child: Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: kCyan.withOpacity(.5)))));
}

// ─────────────────────────────────────────────────────────────────────
// SPARKLINE — grafik mini realtime kartu statistik. Auto-scale min-max
// agar pergerakan kecil tetap terlihat; titik paling kanan = "sekarang".
// ─────────────────────────────────────────────────────────────────────
class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _SparklinePainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final minV = data.reduce(math.min);
    final maxV = data.reduce(math.max);
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);
    final dx = size.width / (data.length - 1);

    final points = <Offset>[];
    for (int i = 0; i < data.length; i++) {
      final y = size.height - ((data[i] - minV) / range * size.height);
      points.add(Offset(i * dx, y.clamp(0, size.height)));
    }

    final areaPath = Path()..moveTo(points.first.dx, size.height);
    for (final p in points) {
      areaPath.lineTo(p.dx, p.dy);
    }
    areaPath.lineTo(points.last.dx, size.height);
    areaPath.close();
    canvas.drawPath(
        areaPath,
        Paint()
          ..shader = LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [color.withOpacity(.22), color.withOpacity(0)])
              .createShader(Rect.fromLTWH(0, 0, size.width, size.height)));

    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      linePath.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
        linePath,
        Paint()
          ..color = color.withOpacity(.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);

    canvas.drawCircle(points.last, 2.6, Paint()..color = color);
    canvas.drawCircle(points.last, 4.2, Paint()..color = color.withOpacity(.25));
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.data.length != data.length ||
      (data.isNotEmpty && old.data.isNotEmpty && old.data.last != data.last);
}

// ═══════════════════════════════════════════════════════════════════
//  COMMAND TAB
//  Stateless + ValueListenableBuilder(DeviceInfo.revision): begitu
//  deteksi device selesai/berubah, daftar grup ikut ter-update tanpa
//  setState manual. Grup ber-polling (RefreshRate, Band) adalah widget
//  stateful terpisah — setState mereka TIDAK menyentuh sisa halaman.
// ═══════════════════════════════════════════════════════════════════

String _stripErr(String s) =>
    s.replaceFirst(RegExp(r'^ERR(OR)?:\s*'), '').trim();

class CommandTab extends StatelessWidget {
  const CommandTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => ValueListenableBuilder<int>(
        valueListenable: DeviceInfo.revision,
        builder: (ctx, rev, child) {
          // Dihitung SEKALI per build & disimpan lokal.
          final govGroup = _buildGovGroup();
          final freqGroup = _buildFreqGroup();
          return SingleChildScrollView(
            physics: kScroll,
            padding: const EdgeInsets.all(18),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _pageHeader('Command', 'Device Control Hub', kPurple),
                  const SizedBox(height: 10),
                  const _RootStrip(),
                  const SizedBox(height: 14),
                  const _DeviceBanner(),
                  const SizedBox(height: 12),

                  if (govGroup != null) govGroup,
                  if (freqGroup != null) freqGroup,

                  // Grup ber-polling — masing-masing dgn TabGate sendiri.
                  const _RefreshRateGroup(),
                  const _BandLockGroup(),

                  _CmdGroup(
                      icon: Icons.memory_rounded,
                      label: 'RAM & Cache',
                      accent: kPurple,
                      subtitle: 'Bersihkan memori',
                      children: const [
                        _CmdLeaf('Clear Cache', Icons.cleaning_services_rounded,
                            kGreen, 'Bebaskan RAM cache',
                            cmd: 'sync; echo 3 > /proc/sys/vm/drop_caches'),
                        _CmdLeaf('Swappiness 10', Icons.swap_horiz_rounded,
                            kBlue, 'Prioritaskan RAM',
                            cmd: 'echo 10 > /proc/sys/vm/swappiness'),
                        _CmdLeaf('Swappiness 60', Icons.swap_vert_rounded,
                            kPurple, 'Seimbang (default)',
                            cmd: 'echo 60 > /proc/sys/vm/swappiness'),
                      ]),

                  _CmdGroup(
                      icon: Icons.thermostat_rounded,
                      label: 'Thermal',
                      accent: kRed,
                      subtitle: 'Kontrol suhu & throttle',
                      children: const [
                        _CmdLeaf('Baca Suhu', Icons.thermostat_rounded, kCyan,
                            'Semua zona + nama sensornya',
                            cmd:
                                'for z in /sys/class/thermal/thermal_zone*; do t=\$(cat "\$z/temp" 2>/dev/null); n=\$(cat "\$z/type" 2>/dev/null); [ -n "\$t" ] && echo "\${n:-\$z}: \$t"; done',
                            readOnly: true),
                        // Loop SEMUA zona (bukan cuma zone0) + flag ok agar
                        // kegagalan total terlapor jelas sebagai ERR.
                        _CmdLeaf('Disable Throttle', Icons.warning_rounded,
                            kRed, 'Matikan throttle — pantau suhu!',
                            cmd:
                                'ok=0; for m in /sys/class/thermal/thermal_zone*/mode; do echo disabled > "\$m" 2>/dev/null && ok=1; done; [ \$ok -eq 1 ] && echo OK || echo "ERR: node mode tidak tersedia"',
                            danger: true),
                        _CmdLeaf('Enable Throttle', Icons.check_circle_rounded,
                            kGreen, 'Aktifkan throttle kembali',
                            cmd:
                                'ok=0; for m in /sys/class/thermal/thermal_zone*/mode; do echo enabled > "\$m" 2>/dev/null && ok=1; done; [ \$ok -eq 1 ] && echo OK || echo "ERR: node mode tidak tersedia"'),
                      ]),

                  _CmdGroup(
                      icon: Icons.storage_rounded,
                      label: 'I/O Scheduler',
                      accent: kTeal,
                      subtitle: 'Optimasi storage',
                      children: const [
                        _CmdLeaf('noop', Icons.linear_scale_rounded, kGreen,
                            'Minimal overhead',
                            cmd:
                                'for d in /sys/block/*/queue/scheduler; do echo noop > "\$d" 2>/dev/null; done; echo OK'),
                        _CmdLeaf('deadline', Icons.timer_rounded, kOrange,
                            'Responsif I/O',
                            cmd:
                                'for d in /sys/block/*/queue/scheduler; do echo deadline > "\$d" 2>/dev/null; done; echo OK'),
                      ]),

                  _CmdGroup(
                      icon: Icons.dns_rounded,
                      label: 'DNS Pribadi',
                      accent: kBlue,
                      subtitle: 'Private DNS (DoT)',
                      children: const [
                        _CmdLeaf('AdGuard', Icons.shield_rounded, kGreen,
                            'Blokir iklan & tracker',
                            cmd:
                                'settings put global private_dns_mode hostname; settings put global private_dns_specifier dns.adguard-dns.com; echo OK'),
                        _CmdLeaf('Cloudflare', Icons.cloud_rounded, kOrange,
                            'Cepat & privat (1.1.1.1)',
                            cmd:
                                'settings put global private_dns_mode hostname; settings put global private_dns_specifier one.one.one.one; echo OK'),
                        _CmdLeaf('Quad9', Icons.security_rounded, kBlue,
                            'Blokir situs berbahaya',
                            cmd:
                                'settings put global private_dns_mode hostname; settings put global private_dns_specifier dns.quad9.net; echo OK'),
                        _CmdLeaf('Google', Icons.public_rounded, kCyan,
                            'DNS Google (8.8.8.8)',
                            cmd:
                                'settings put global private_dns_mode hostname; settings put global private_dns_specifier dns.google; echo OK'),
                        _CmdLeaf('Matikan DNS Pribadi',
                            Icons.power_settings_new_rounded, kRed,
                            'Kembali ke otomatis',
                            cmd:
                                'settings put global private_dns_mode off; echo OK'),
                        _CmdLeaf('Cek DNS Aktif', Icons.search_rounded,
                            kPurple, 'Lihat private DNS sekarang',
                            cmd:
                                'settings get global private_dns_specifier',
                            readOnly: true),
                      ]),

                  _CmdGroup(
                      icon: Icons.network_check_rounded,
                      label: 'TCP Network',
                      accent: kGreen,
                      subtitle: 'Congestion control',
                      children: const [
                        _CmdLeaf('TCP BBR', Icons.compress_rounded, kGreen,
                            'Algoritma Google BBR',
                            cmd:
                                'echo bbr > /proc/sys/net/ipv4/tcp_congestion_control'),
                        _CmdLeaf('TCP Cubic', Icons.show_chart_rounded,
                            kPurple, 'Default Linux',
                            cmd:
                                'echo cubic > /proc/sys/net/ipv4/tcp_congestion_control'),
                      ]),

                  // DT2W — SELALU tampil. Memakai settings system
                  // os_action_tapping_wake (kunci Transsion/Infinix).
                  // Node hardware goodix SENGAJA tidak dipakai: menulis ke
                  // node itu pernah menyebabkan device reboot.
                  _CmdGroup(
                      icon: Icons.touch_app_rounded,
                      label: 'Layar & Gesture',
                      accent: kPink,
                      subtitle: 'Double tap to wake — aman via settings',
                      children: const [
                        _CmdLeaf('DT2W: Aktifkan', Icons.touch_app_rounded,
                            kGreen, 'Ketuk 2x untuk bangunkan layar',
                            cmd:
                                'settings put system os_action_tapping_wake 1; echo OK'),
                        _CmdLeaf('DT2W: Matikan', Icons.do_not_touch_rounded,
                            kRed, 'Nonaktifkan gesture wake',
                            cmd:
                                'settings put system os_action_tapping_wake 0; echo OK'),
                        _CmdLeaf('Cek Status DT2W', Icons.search_rounded,
                            kCyan, '1 = aktif · 0/null = mati',
                            cmd:
                                'settings get system os_action_tapping_wake',
                            readOnly: true),
                      ]),

                  _CmdGroup(
                      icon: Icons.settings_rounded,
                      label: 'System',
                      accent: kYellow,
                      subtitle: 'Info & reboot',
                      children: const [
                        _CmdLeaf('Info Build', Icons.info_rounded, kCyan,
                            'Model & versi Android',
                            cmd:
                                'getprop ro.product.model; getprop ro.board.platform; getprop ro.build.version.release',
                            readOnly: true),
                        _CmdLeaf('Clear Logcat', Icons.delete_rounded, kOrange,
                            'Bersihkan buffer log', cmd: 'logcat -c'),
                        _CmdLeaf('Reboot', Icons.restart_alt_rounded, kRed,
                            'Mulai ulang perangkat',
                            cmd: 'reboot', danger: true),
                      ]),

                  const SizedBox(height: 24),
                ]),
          );
        },
      ),
    );
  }

  // ── CPU Governor: tulis ke policy* (satu tulis per cluster, bukan
  //    per-core — lebih bersih & setara karena core dalam cluster share
  //    file governor yang sama). ──
  _CmdGroup? _buildGovGroup() {
    final govs = DeviceInfo.i.governors;
    if (govs.isEmpty) return null;
    const meta = {
      'performance': ['Semua cluster max — gaming', Icons.flash_on_rounded, kRed],
      'powersave': ['Hemat daya maksimal', Icons.battery_saver_rounded, kGreen],
      'schedutil': ['Adaptif — rekomendasi harian', Icons.schedule_rounded, kCyan],
      'ondemand': ['Naik cepat saat butuh', Icons.trending_up_rounded, kOrange],
      'conservative': ['Naik pelan — hemat', Icons.trending_down_rounded, kBlue],
      'interactive': ['Responsif untuk UI', Icons.touch_app_rounded, kPurple],
    };
    final leaves = govs.map((g) {
      final m = meta[g];
      return _CmdLeaf(
        g,
        m != null ? m[1] as IconData : Icons.tune_rounded,
        m != null ? m[2] as Color : kTeal,
        m != null ? m[0] as String : 'Governor $g',
        cmd:
            'ok=0; for f in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo $g > "\$f" 2>/dev/null && ok=1; done; [ \$ok -eq 1 ] && echo OK || echo "ERR: gagal menulis governor"',
      );
    }).toList();
    return _CmdGroup(
        icon: Icons.developer_board_rounded,
        label: 'CPU Governor',
        accent: kCyan,
        subtitle: '${govs.length} governor · semua cluster',
        children: leaves);
  }

  // ── CPU Frekuensi: tier PERSENTASE per-cluster. Tiap policy dihitung
  //    dari cpuinfo_max-nya sendiri, jadi LITTLE/BIG/PRIME turun
  //    proporsional (bukan satu angka dipaksakan ke semua cluster yang
  //    pasti ditolak kernel karena tabel frekuensinya beda). ──
  _CmdGroup? _buildFreqGroup() {
    final d = DeviceInfo.i;
    if (d.policies.isEmpty) return null;
    final leaves = <_CmdLeaf>[
      _CmdLeaf('Full Power', Icons.rocket_launch_rounded, kRed,
          '100% — performa penuh', cmd: _tierCmd(100)),
      _CmdLeaf('Tinggi', Icons.bolt_rounded, kOrange,
          '±80% dari max tiap cluster', cmd: _tierCmd(80)),
      _CmdLeaf('Seimbang', Icons.eco_rounded, kGreen,
          '±60% — harian adem', cmd: _tierCmd(60)),
      _CmdLeaf('Hemat Daya', Icons.battery_saver_rounded, kBlue,
          '±40% — baterai maksimal', cmd: _tierCmd(40)),
      const _CmdLeaf('Reset ke Default', Icons.restart_alt_rounded, kTeal,
          'Pulihkan rentang penuh hardware', cmd: _resetFreqCmd),
    ];
    return _CmdGroup(
        icon: Icons.speed_rounded,
        label: 'CPU Frekuensi',
        accent: kOrange,
        subtitle: d.clusterSummary.isEmpty
            ? 'Kunci frekuensi per-cluster'
            : d.clusterSummary,
        children: leaves);
  }

  /// Skrip tier frekuensi (POSIX murni — tanpa awk/bc, jalan di toybox).
  /// ATURAN URUTAN PENTING: scaling_min TIDAK BOLEH melebihi scaling_max
  /// walau sesaat — kernel menolak tulisan itu. Maka saat MENURUNKAN max:
  /// turunkan min ke cpuinfo_min dulu, baru tulis max target.
  String _tierCmd(int pct) => '''
ok=0
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
  [ -f "\$pol/scaling_max_freq" ] || continue
  hwmax=\$(cat "\$pol/cpuinfo_max_freq" 2>/dev/null)
  hwmin=\$(cat "\$pol/cpuinfo_min_freq" 2>/dev/null)
  [ -n "\$hwmax" ] || continue
  want=\$((hwmax * $pct / 100))
  best=""; bestd=999999999
  for f in \$(cat "\$pol/scaling_available_frequencies" 2>/dev/null); do
    d=\$((f - want)); [ \$d -lt 0 ] && d=\$((0 - d))
    if [ \$d -lt \$bestd ]; then bestd=\$d; best=\$f; fi
  done
  [ -n "\$best" ] || best=\$want
  curmin=\$(cat "\$pol/scaling_min_freq" 2>/dev/null)
  if [ -n "\$curmin" ] && [ "\$curmin" -gt "\$best" ]; then
    echo "\$hwmin" > "\$pol/scaling_min_freq"
  fi
  echo "\$best" > "\$pol/scaling_max_freq" && ok=1
done
[ \$ok -eq 1 ] && echo OK || echo "ERR: tidak ada policy yang bisa ditulis"
''';

  /// Reset: max DULU baru min — arah menaikkan, urutan ini yang aman.
  static const String _resetFreqCmd = '''
ok=0
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
  hwmax=\$(cat "\$pol/cpuinfo_max_freq" 2>/dev/null); [ -n "\$hwmax" ] || continue
  hwmin=\$(cat "\$pol/cpuinfo_min_freq" 2>/dev/null)
  echo "\$hwmax" > "\$pol/scaling_max_freq" && ok=1
  [ -n "\$hwmin" ] && echo "\$hwmin" > "\$pol/scaling_min_freq"
done
[ \$ok -eq 1 ] && echo OK || echo "ERR: policy tidak ditemukan"
''';
}

/// Strip status root ringkas di atas halaman Command.
class _RootStrip extends StatelessWidget {
  const _RootStrip();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: isRootNotifier,
        builder: (_, root, __) {
          final c = root ? kGreen : kRed;
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: c.withOpacity(.07),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.withOpacity(.25))),
            child: Row(children: [
              Icon(root ? Icons.check_circle_rounded : Icons.lock_rounded,
                  color: c, size: 16),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      root
                          ? 'Root aktif — semua perintah dapat dieksekusi'
                          : 'Non-root — hanya perintah info yang tersedia',
                      style: TextStyle(color: c, fontSize: 11.5))),
            ]),
          );
        },
      );
}

/// Banner hasil deteksi device — nama, chipset, cluster, & peringatan
/// bila brand tidak konsisten dengan chipset (modul spoofing aktif).
class _DeviceBanner extends StatelessWidget {
  const _DeviceBanner();
  @override
  Widget build(BuildContext context) {
    final d = DeviceInfo.i;
    final accent = d.spoofSuspected ? kYellow : kCyan;
    final sub = [
      if (d.platform != '---') d.platform,
      if (d.cpuCores > 0) '${d.cpuCores} core',
      if (d.androidVer != '---') 'Android ${d.androidVer}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: accent.withOpacity(.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withOpacity(.2))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.phone_android_rounded, color: accent, size: 18),
        const SizedBox(width: 10),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d.displayName,
              style: TextStyle(
                  color: kWhite, fontSize: 12.5, fontWeight: FontWeight.w700)),
          if (sub.isNotEmpty)
            Text(sub, style: TextStyle(color: mut(.4), fontSize: 10.5)),
          if (d.clusterSummary.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(d.clusterSummary,
                style: TextStyle(
                    color: accent.withOpacity(.75),
                    fontSize: 10,
                    fontFamily: 'monospace')),
          ],
          if (d.spoofSuspected) ...[
            const SizedBox(height: 3),
            Text(
                '⚠️ Brand tidak konsisten dengan chipset — kemungkinan modul spoofing aktif',
                style: TextStyle(color: kYellow, fontSize: 9.5, height: 1.3)),
          ],
        ])),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// REFRESH RATE — lock + monitoring, dengan JENDELA PROTEKSI ANTI-ADAPTIF:
// selama ~6 detik setelah user memilih Hz, hasil polling TIDAK menimpa
// highlight pilihan user (sistem adaptif sering butuh beberapa detik
// untuk benar-benar pindah). Teks status tetap menampilkan nilai AKTUAL
// apa adanya — yang di-hold hanya highlight tombol.
// ─────────────────────────────────────────────────────────────────────
class _RefreshRateGroup extends StatefulWidget {
  const _RefreshRateGroup();
  @override
  State<_RefreshRateGroup> createState() => _RefreshRateGroupState();
}

class _RefreshRateGroupState extends State<_RefreshRateGroup> {
  String _current = '---';
  int? _currentHz;
  int? _heldHz;
  DateTime? _holdUntil;
  Timer? _timer;
  late final TabGate _gate;
  bool _polling = false;

  bool get _inHold =>
      _holdUntil != null && DateTime.now().isBefore(_holdUntil!);

  @override
  void initState() {
    super.initState();
    // Polling 4 detik HANYA saat tab Command terlihat & app foreground.
    _gate = TabGate(
      tab: 1,
      onChanged: (on) {
        if (on) {
          _poll();
          _timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
        } else {
          _timer?.cancel();
          _timer = null;
        }
      },
    )..attach();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _gate.detach();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      String hz = '';
      // 1) node non-root paling murah
      final fb = await Sys.read('/sys/class/graphics/fb0/measured_fps');
      if (fb.isNotEmpty) hz = fb;
      // 2) dumpsys (root) — angka fps aktual dari display service
      if (hz.isEmpty && isRootNotifier.value) {
        final out = await Root.exec(
            'dumpsys display | grep -oE "fps=[0-9]+\\.?[0-9]*" | head -1 | grep -oE "[0-9]+\\.?[0-9]*"');
        if (!out.startsWith('ERR') && out != 'OK') hz = out;
      }
      // 3) fallback: settings get (jalan tanpa root)
      if (hz.isEmpty) {
        final out = await Sys.sh('settings get system peak_refresh_rate');
        if (!out.startsWith('ERR') && out != 'null') hz = out;
      }
      final parsed = double.tryParse(hz.trim());
      final valid = (parsed != null && parsed >= 24 && parsed <= 165)
          ? parsed.round()
          : null;
      if (!mounted) return;
      setState(() {
        _currentHz = valid;
        _current = valid != null ? '$valid Hz' : '---';
      });
    } finally {
      _polling = false;
    }
  }

  Future<void> _lock(int hz) async {
    if (!isRootNotifier.value) {
      showSnack(context, '⚠ Butuh akses root untuk mengunci refresh rate');
      return;
    }
    HapticFeedback.mediumImpact();
    // Aktifkan jendela proteksi SEBELUM eksekusi — pilihan user langsung
    // tersorot & tidak "berkedip" digeser hasil poll berikutnya.
    setState(() {
      _heldHz = hz;
      _holdUntil = DateTime.now().add(const Duration(seconds: 6));
    });
    // peak = min ke Hz yang sama menutup celah sistem menaik-turunkan
    // sendiri; key MIUI/user ikut ditulis untuk kompatibilitas lintas ROM.
    final out = await Root.exec('''
settings put system peak_refresh_rate $hz.0
settings put system min_refresh_rate $hz.0
settings put system user_refresh_rate $hz
settings put system miui_refresh_rate $hz
echo OK''');
    if (!mounted) return;
    final ok = !out.startsWith('ERR');
    showSnack(context,
        ok ? '✓ Refresh rate dikunci ke ${hz}Hz' : '✗ Gagal: ${_stripErr(out)}');
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) _poll();
  }

  @override
  Widget build(BuildContext context) {
    const options = [60, 90, 120, 144];
    final highlightHz = _inHold ? _heldHz : _currentHz;
    final status = _current == '---'
        ? 'Membaca status…'
        : _inHold && _heldHz != _currentHz
            ? 'Aktif: $_current · mengunci ${_heldHz}Hz…'
            : 'Aktif sekarang: $_current';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kBorder)),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: kTeal.withOpacity(.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kTeal.withOpacity(.2))),
                child: Icon(Icons.monitor_rounded, color: kTeal, size: 20)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Refresh Rate',
                      style: TextStyle(
                          color: kWhite,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Row(children: [
                    Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 5),
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _current == '---' ? mut(.2) : kGreen)),
                    Expanded(
                        child: Text(status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: mut(.4), fontSize: 10.5))),
                  ]),
                ])),
          ]),
          const SizedBox(height: 14),
          Row(
              children: options.map((hz) {
            final on = highlightHz == hz;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: hz == options.last ? 0 : 8),
                child: Tap(
                  onTap: () => _lock(hz),
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    curve: Motion.curve,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                        color: on ? kTeal.withOpacity(.16) : mut(.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: on ? kTeal : Colors.transparent)),
                    child: Column(children: [
                      Text('$hz',
                          style: TextStyle(
                              color: on ? kTeal : kWhite,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              fontFamily: 'monospace')),
                      Text('Hz',
                          style: TextStyle(
                              color: on ? kTeal.withOpacity(.7) : mut(.35),
                              fontSize: 9)),
                    ]),
                  ),
                ),
              ),
            );
          }).toList()),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// NETWORK / BAND LOCK — preferensi mode jaringan + monitoring tipe
// jaringan aktual. Kode mode dari RILConstants:
//   26 = NR/LTE/GSM/WCDMA (5G preferred) · 11 = LTE only · 9 = LTE/GSM/WCDMA
// Catatan: mode 0 (yang dulu dipakai sebagai "Auto") sebenarnya
// WCDMA-preferred TANPA LTE — itu bug lama yang diperbaiki di sini.
// ─────────────────────────────────────────────────────────────────────
class _BandLockGroup extends StatefulWidget {
  const _BandLockGroup();
  @override
  State<_BandLockGroup> createState() => _BandLockGroupState();
}

class _BandLockGroupState extends State<_BandLockGroup> {
  String _current = '---';
  Timer? _timer;
  late final TabGate _gate;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _gate = TabGate(
      tab: 1,
      onChanged: (on) {
        if (on) {
          _poll();
          _timer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
        } else {
          _timer?.cancel();
          _timer = null;
        }
      },
    )..attach();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _gate.detach();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      if (!isRootNotifier.value) {
        if (mounted) setState(() => _current = 'Butuh root');
        return;
      }
      final out = await Root.exec(
          'dumpsys telephony.registry | grep -oE "mDataNetworkType=[A-Za-z0-9_]+" | head -1');
      if (!mounted) return;
      if (out.startsWith('ERR') || out == 'OK' || out.isEmpty) {
        setState(() => _current = '---');
      } else {
        final cleaned = out.replaceFirst('mDataNetworkType=', '').trim();
        setState(() => _current = cleaned.isEmpty ? '---' : cleaned);
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _apply(String label, String cmd) async {
    if (!isRootNotifier.value) {
      showSnack(context, '⚠ Butuh akses root untuk mengatur mode jaringan');
      return;
    }
    HapticFeedback.mediumImpact();
    final out = await Root.exec(cmd);
    if (!mounted) return;
    final err = out.startsWith('ERR');
    showSnack(
        context,
        err
            ? '✗ Gagal — modem mungkin tak mendukung: ${_stripErr(out)}'
            : '✓ $label diterapkan');
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) _poll();
  }

  @override
  Widget build(BuildContext context) {
    // Tulis juga ke key per-slot (mode0/mode1) supaya berlaku di dual-SIM.
    String cmdFor(int mode) =>
        'settings put global preferred_network_mode $mode; '
        'settings put global preferred_network_mode0 $mode; '
        'settings put global preferred_network_mode1 $mode; echo OK';
    final modes = [
      ('5G Preferred', 'NR/LTE/GSM/WCDMA — jangkauan penuh', kPurple, cmdFor(26)),
      ('4G Only', 'LTE saja — stabil, tanpa fallback', kGreen, cmdFor(11)),
      ('4G/3G', 'LTE + fallback 3G (WCDMA)', kCyan, cmdFor(9)),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
            color: kPanel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kBorder)),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: kBlue.withOpacity(.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kBlue.withOpacity(.2))),
                child: Icon(Icons.signal_cellular_alt_rounded,
                    color: kBlue, size: 20)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Network / Band Lock',
                      style: TextStyle(
                          color: kWhite,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Row(children: [
                    Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 5),
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: (_current == '---' ||
                                    _current == 'Butuh root')
                                ? mut(.2)
                                : kGreen)),
                    Text(
                        _current == '---'
                            ? 'Membaca status…'
                            : 'Aktif: $_current',
                        style: TextStyle(color: mut(.4), fontSize: 10.5)),
                  ]),
                ])),
          ]),
          const SizedBox(height: 4),
          Text(
              'Catatan: dukungan tergantung modem. Kalau tidak berubah, coba mode lain.',
              style: TextStyle(color: mut(.28), fontSize: 9.5, height: 1.3)),
          const SizedBox(height: 10),
          ...modes.map((m) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Tap(
                  onTap: () => _apply(m.$1, m.$4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                        color: kPanel2,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: kBorder.withOpacity(.4))),
                    child: Row(children: [
                      Container(
                          width: 2.5,
                          height: 32,
                          decoration: BoxDecoration(
                              color: m.$3.withOpacity(.55),
                              borderRadius: BorderRadius.circular(2))),
                      const SizedBox(width: 12),
                      Icon(Icons.cell_tower_rounded, color: m.$3, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(m.$1,
                                style: TextStyle(
                                    color: kWhite,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600)),
                            Text(m.$2,
                                style: TextStyle(
                                    color: mut(.35), fontSize: 10)),
                          ])),
                      Icon(Icons.chevron_right_rounded,
                          color: mut(.25), size: 18),
                    ]),
                  ),
                ),
              )),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// CMD GROUP — kartu kategori. Ketuk → dialog daftar perintah (scale+fade
// 240ms). Dialog memakai ListView + kScroll supaya daftar panjang tetap
// mulus digulir di dalam dialog.
// ─────────────────────────────────────────────────────────────────────
class _CmdGroup extends StatelessWidget {
  const _CmdGroup(
      {required this.icon,
      required this.label,
      required this.subtitle,
      required this.accent,
      required this.children});

  final IconData icon;
  final String label, subtitle;
  final Color accent;
  final List<_CmdLeaf> children;

  void _open(BuildContext context) {
    HapticFeedback.selectionClick();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: label,
      barrierColor: Colors.black.withOpacity(.62),
      transitionDuration: const Duration(milliseconds: 240),
      transitionBuilder: (_, anim, __, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Motion.curve);
        return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
                scale: Tween<double>(begin: .92, end: 1).animate(curved),
                child: child));
      },
      pageBuilder: (_, __, ___) => _CmdDialog(
          icon: icon,
          label: label,
          subtitle: subtitle,
          accent: accent,
          children: children),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Tap(
        onTap: () => _open(context),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: kPanel,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: kBorder)),
          child: Row(children: [
            Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: accent.withOpacity(.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: accent.withOpacity(.2))),
                child: Icon(icon, color: accent, size: 20)),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(label,
                      style: TextStyle(
                          color: kWhite,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: mut(.4), fontSize: 10.5)),
                ])),
            Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: accent.withOpacity(.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Text('${children.length}',
                    style: TextStyle(
                        color: accent,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'monospace'))),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: mut(.25), size: 20),
          ]),
        ),
      ),
    );
  }
}

class _CmdDialog extends StatelessWidget {
  const _CmdDialog(
      {required this.icon,
      required this.label,
      required this.subtitle,
      required this.accent,
      required this.children});

  final IconData icon;
  final String label, subtitle;
  final Color accent;
  final List<_CmdLeaf> children;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return SafeArea(
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            constraints:
                BoxConstraints(maxWidth: 500, maxHeight: size.height * .82),
            decoration: BoxDecoration(
                color: kPanel,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: accent.withOpacity(.25)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(.5),
                      blurRadius: 40,
                      offset: const Offset(0, 16)),
                ]),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
                child: Row(children: [
                  Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                          color: accent.withOpacity(.12),
                          borderRadius: BorderRadius.circular(11)),
                      child: Icon(icon, color: accent, size: 18)),
                  const SizedBox(width: 11),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(label,
                            style: TextStyle(
                                color: kWhite,
                                fontSize: 15,
                                fontWeight: FontWeight.w800)),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(color: mut(.4), fontSize: 10.5)),
                      ])),
                  Tap(
                      onTap: () => Navigator.pop(context),
                      child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.close_rounded,
                              color: mut(.4), size: 20))),
                ]),
              ),
              Container(height: 1, color: kBorder.withOpacity(.6)),
              Flexible(
                child: ListView(
                    shrinkWrap: true,
                    physics: kScroll,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    children: children),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// CMD LEAF — satu perintah.
//   readOnly : boleh jalan TANPA root (via Sys.sh), hasil → bottom sheet.
//   danger   : minta konfirmasi dulu (Reboot, Disable Throttle).
// ─────────────────────────────────────────────────────────────────────
class _CmdLeaf extends StatefulWidget {
  const _CmdLeaf(this.label, this.icon, this.color, this.desc,
      {required this.cmd, this.readOnly = false, this.danger = false});

  final String label, desc, cmd;
  final IconData icon;
  final Color color;
  final bool readOnly, danger;

  @override
  State<_CmdLeaf> createState() => _CmdLeafState();
}

class _CmdLeafState extends State<_CmdLeaf> {
  bool _flash = false, _running = false;

  Future<void> _exec() async {
    if (_running) return;
    if (widget.danger) {
      final ok = await confirmAction(context,
          title: widget.label,
          message:
              'Perintah ini berdampak besar pada sistem. Yakin melanjutkan?',
          accent: widget.color);
      if (!ok || !mounted) return;
    }
    HapticFeedback.mediumImpact();
    _running = true;
    try {
      final out = isRootNotifier.value
          ? await Root.exec(widget.cmd)
          : await Sys.sh(widget.cmd); // jalur non-root untuk leaf readOnly
      if (!mounted) return;
      final isErr = out.startsWith('ERR');

      if (widget.readOnly) {
        showOutputSheet(context,
            title: widget.label,
            body: (out == 'OK' || out.isEmpty)
                ? '(tidak ada output)'
                : isErr
                    ? _stripErr(out)
                    : out,
            icon: widget.icon,
            color: isErr ? kRed : widget.color);
        return;
      }
      if (isErr) {
        showSnack(context, '✗ ${_stripErr(out)}');
        return;
      }
      setState(() => _flash = true);
      showSnack(context, '✓ ${widget.label} diterapkan');
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _flash = false);
      });
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isRootNotifier,
      builder: (_, root, __) {
        final locked = !root && !widget.readOnly;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Tap(
            onTap: locked
                ? () => showSnack(context, '⚠ Butuh akses root')
                : _exec,
            child: AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.curve,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              decoration: BoxDecoration(
                  color: _flash
                      ? widget.color.withOpacity(.18)
                      : locked
                          ? mut(.03)
                          : kPanel2,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: _flash
                          ? widget.color.withOpacity(.5)
                          : kBorder.withOpacity(.4))),
              child: Row(children: [
                Container(
                    width: 3,
                    height: 42,
                    decoration: BoxDecoration(
                        color: locked
                            ? mut(.15)
                            : widget.color.withOpacity(.55),
                        borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 13),
                Icon(locked ? Icons.lock_rounded : widget.icon,
                    color: locked ? mut(.3) : widget.color, size: 21),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Row(children: [
                        Flexible(
                            child: Text(widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: kWhite,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700))),
                        if (widget.danger) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.warning_amber_rounded,
                              color: kRed.withOpacity(.8), size: 13),
                        ],
                        if (widget.readOnly) ...[
                          const SizedBox(width: 6),
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                  color: widget.color.withOpacity(.1),
                                  borderRadius: BorderRadius.circular(5)),
                              child: Text('INFO',
                                  style: TextStyle(
                                      color: widget.color,
                                      fontSize: 7.5,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: .8))),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Text(widget.desc,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: mut(.38), fontSize: 10.5, height: 1.3)),
                    ])),
                const SizedBox(width: 8),
                Icon(
                    widget.readOnly
                        ? Icons.visibility_rounded
                        : Icons.play_arrow_rounded,
                    color:
                        locked ? mut(.2) : widget.color.withOpacity(.6),
                    size: 18),
              ]),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  TOOLS TAB — utilitas baca-saja. Hasil ditampilkan lewat bottom sheet
//  monospace yang bisa diseleksi/disalin.
// ═══════════════════════════════════════════════════════════════════

class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key});

  Future<void> _run(BuildContext context, String title, String cmd,
      {bool needRoot = false}) async {
    if (needRoot && !isRootNotifier.value) {
      showOutputSheet(context,
          title: 'Butuh Root',
          body: 'Fitur ini memerlukan akses root aktif.',
          icon: Icons.lock_rounded,
          color: kYellow);
      return;
    }
    HapticFeedback.selectionClick();
    final out = isRootNotifier.value
        ? await Root.exec(cmd)
        : await Sys.sh(cmd);
    if (!context.mounted) return;
    final isErr = out.startsWith('ERR');
    showOutputSheet(context,
        title: title,
        body: (out == 'OK' || out.isEmpty)
            ? 'Tidak ada output'
            : isErr
                ? _stripErr(out)
                : out,
        color: isErr ? kRed : kCyan);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => SingleChildScrollView(
        physics: kScroll,
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _pageHeader('Tools', 'System Utilities', kOrange),
          const SizedBox(height: 18),
          _sectionLabel('INFO (TANPA ROOT)', kCyan),
          const SizedBox(height: 10),
          _tool(context, 'CPU Info', 'Model, core, frekuensi, BogoMIPS',
              Icons.developer_board_rounded, kCyan, false,
              'cat /proc/cpuinfo | grep -E "model name|processor|cpu MHz|BogoMIPS|Hardware" | head -20'),
          _tool(context, 'Memory Detail', 'MemTotal, MemFree, Cached, Swap',
              Icons.memory_rounded, kPurple, false, 'cat /proc/meminfo'),
          _tool(context, 'Battery Detail', 'Status, kapasitas, suhu',
              Icons.battery_full_rounded, kGreen, false,
              'cat /sys/class/power_supply/battery/uevent 2>/dev/null || cat /sys/class/power_supply/*/uevent 2>/dev/null'),
          _tool(context, 'Suhu Thermal', 'Semua zona + nama sensor',
              Icons.thermostat_rounded, kRed, false,
              'for z in /sys/class/thermal/thermal_zone*; do t=\$(cat "\$z/temp" 2>/dev/null); n=\$(cat "\$z/type" 2>/dev/null); [ -n "\$t" ] && echo "\${n:-\$z}: \$t"; done'),
          _tool(context, 'Uptime & Load', 'Uptime dan load average sistem',
              Icons.timer_rounded, kTeal, false,
              'uptime; echo "---"; cat /proc/loadavg; echo "---"; cat /proc/uptime'),
          _tool(context, 'Disk Usage', 'Partisi dan penggunaan storage',
              Icons.storage_rounded, kOrange, false, 'df -h'),
          _tool(context, 'Network Info', 'IP, interface, DNS aktif',
              Icons.wifi_rounded, kBlue, false,
              'ip addr show 2>/dev/null; echo "---"; getprop net.dns1; getprop net.dns2'),
          _tool(context, 'Android Props', 'Build, model, versi OS',
              Icons.android_rounded, kGreen, false,
              'getprop ro.product.model; getprop ro.board.platform; getprop ro.build.version.release; getprop ro.product.manufacturer'),
          const SizedBox(height: 18),
          _sectionLabel('ROOT TOOLS', kRed),
          const SizedBox(height: 10),
          _tool(context, 'Kernel Log', 'dmesg 30 baris terakhir',
              Icons.article_rounded, kRed, true, 'dmesg | tail -30'),
          _tool(context, 'Proses Berjalan', 'Snapshot proses aktif',
              Icons.list_alt_rounded, kOrange, true, 'ps aux | head -25'),
          _tool(context, 'Governor per Core', 'Governor aktif tiap core CPU',
              Icons.tune_rounded, kCyan, true,
              'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "\$c: \$(cat "\$c" 2>/dev/null)"; done'),
          _tool(context, 'Frekuensi per Core', 'Frekuensi aktif tiap core CPU',
              Icons.speed_rounded, kBlue, true,
              'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do echo "\$c: \$(cat "\$c" 2>/dev/null)"; done'),
          _tool(context, 'Modules Kernel', 'Modul kernel yang ter-load',
              Icons.extension_rounded, kTeal, true, 'lsmod | head -25'),
          _tool(context, 'Swappiness Saat Ini', 'Nilai swappiness aktif',
              Icons.swap_horiz_rounded, kPurple, true,
              'cat /proc/sys/vm/swappiness'),
          _tool(context, 'TCP Congestion Aktif', 'Algoritma TCP aktif',
              Icons.compress_rounded, kGreen, true,
              'cat /proc/sys/net/ipv4/tcp_congestion_control'),
          _tool(context, 'I/O Scheduler Aktif', 'Scheduler tiap block device',
              Icons.storage_rounded, kYellow, true,
              'for d in /sys/block/*/queue/scheduler; do echo "\$d: \$(cat "\$d" 2>/dev/null)"; done'),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  Widget _tool(BuildContext context, String title, String desc, IconData icon,
          Color color, bool needRoot, String cmd) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Tap(
          onTap: () => _run(context, title, cmd, needRoot: needRoot),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
                color: kPanel,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kBorder)),
            child: Row(children: [
              Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                      color: color.withOpacity(.1),
                      borderRadius: BorderRadius.circular(11)),
                  child: Icon(icon, color: color, size: 18)),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      Flexible(
                          child: Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: kWhite,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700))),
                      if (needRoot) ...[
                        const SizedBox(width: 6),
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                                color: kRed.withOpacity(.1),
                                borderRadius: BorderRadius.circular(5)),
                            child: Text('ROOT',
                                style: TextStyle(
                                    color: kRed,
                                    fontSize: 7.5,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: .8))),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(desc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: mut(.38), fontSize: 10.5)),
                  ])),
              Icon(Icons.chevron_right_rounded, color: mut(.25), size: 18),
            ]),
          ),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════
//  ABOUT TAB
// ═══════════════════════════════════════════════════════════════════

/// Avatar robot animasi. Ticker HANYA berjalan saat tab Tentang terlihat
/// & app foreground (TabGate) — IndexedStack menjaga widget ini tetap
/// hidup di semua tab, tapi tanpa gate ia akan memaksa repaint 60fps
/// terus-menerus di latar belakang.
class _AnimatedAvatar extends StatefulWidget {
  const _AnimatedAvatar();
  @override
  State<_AnimatedAvatar> createState() => _AnimatedAvatarState();
}

class _AnimatedAvatarState extends State<_AnimatedAvatar>
    with TickerProviderStateMixin {
  late final AnimationController _p;
  late final AnimationController _o;
  late final TabGate _gate;

  @override
  void initState() {
    super.initState();
    _p = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600));
    _o = AnimationController(vsync: this, duration: const Duration(seconds: 10));
    _gate = TabGate(
      tab: 3,
      onChanged: (on) {
        if (on) {
          _p.repeat(reverse: true);
          _o.repeat();
        } else {
          _p.stop();
          _o.stop();
        }
      },
    )..attach();
  }

  @override
  void dispose() {
    _gate.detach();
    _p.dispose();
    _o.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
            animation: Listenable.merge([_p, _o]),
            builder: (_, __) => CustomPaint(
                size: const Size(130, 130),
                painter: _AvatarPainter(_p.value, _o.value))),
      );
}

class _AvatarPainter extends CustomPainter {
  final double pulse, orbit;
  _AvatarPainter(this.pulse, this.orbit);

  @override
  void paint(Canvas canvas, Size s) {
    final cx = s.width / 2, cy = s.height / 2, r = s.width / 2;
    canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..shader = RadialGradient(
                  colors: [const Color(0xFF1A1A40), const Color(0xFF060612)])
              .createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r)));
    for (int i = 0; i < 8; i++) {
      final a = (i / 8 + orbit) * 2 * math.pi;
      canvas.drawCircle(
          Offset(cx + r * .82 * math.cos(a), cy + r * .82 * math.sin(a)),
          i % 2 == 0 ? 2.5 : 1.5,
          Paint()..color = kCyan.withOpacity(i % 2 == 0 ? .5 + .3 * pulse : .2));
    }
    canvas.drawCircle(
        Offset(cx, cy),
        r * (.78 + .04 * pulse),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = kCyan.withOpacity(.15 + .1 * pulse)
          ..strokeWidth = 1.2);
    final body = Path()
      ..moveTo(cx - r * .3, cy + r * .2)
      ..lineTo(cx + r * .3, cy + r * .2)
      ..lineTo(cx + r * .42, cy + r * .75)
      ..lineTo(cx - r * .42, cy + r * .75)
      ..close();
    canvas.drawPath(
        body,
        Paint()
          ..shader = LinearGradient(
                  colors: [const Color(0xFF1E1E50), kCyan.withOpacity(.2)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter)
              .createShader(
                  Rect.fromLTWH(cx - r * .42, cy + r * .2, r * .84, r * .55)));
    canvas.drawPath(
        Path()
          ..moveTo(cx - r * .1, cy + r * .2)
          ..lineTo(cx, cy + r * .35)
          ..lineTo(cx + r * .1, cy + r * .2),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = kCyan.withOpacity(.5)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(
        Offset(cx, cy - r * .18),
        r * .28,
        Paint()
          ..shader = RadialGradient(
                  colors: [const Color(0xFF252560), const Color(0xFF0F0F30)])
              .createShader(Rect.fromCircle(
                  center: Offset(cx - r * .05, cy - r * .28), radius: r * .28)));
    canvas.drawCircle(
        Offset(cx, cy - r * .18),
        r * .28,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = kCyan.withOpacity(.3)
          ..strokeWidth = 1.2);
    final hair = Path()
      ..addArc(
          Rect.fromCircle(center: Offset(cx, cy - r * .18), radius: r * .28),
          math.pi + .25,
          2.63)
      ..lineTo(cx, cy - r * .18)
      ..close();
    canvas.drawPath(hair, Paint()..color = const Color(0xFF5030D0));
    canvas.drawArc(
        Rect.fromCircle(center: Offset(cx - r * .07, cy - r * .38), radius: r * .08),
        3.8,
        1.4,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = kPurple.withOpacity(.5)
          ..strokeWidth = 2);
    for (final dx in [-r * .1, r * .1]) {
      canvas.drawCircle(
          Offset(cx + dx, cy - r * .2),
          3.5,
          Paint()
            ..color = kCyan
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      canvas.drawCircle(
          Offset(cx + dx, cy - r * .2), 1.5, Paint()..color = Colors.white);
    }
    canvas.drawArc(
        Rect.fromCenter(
            center: Offset(cx, cy - r * .08), width: r * .22, height: r * .13),
        .3,
        2.5,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = kCyan.withOpacity(.6)
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round);
    final badge = RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(cx, cy + r * .4), width: r * .5, height: r * .17),
        const Radius.circular(4));
    canvas.drawRRect(badge, Paint()..color = kCyan.withOpacity(.12));
    canvas.drawRRect(
        badge,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = kCyan.withOpacity(.45)
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_AvatarPainter o) => o.pulse != pulse || o.orbit != orbit;
}

class AboutTab extends StatelessWidget {
  const AboutTab({super.key});

  Future<void> _recheckRoot(BuildContext context) async {
    showSnack(context, 'Memeriksa ulang akses root…');
    final ok = await Root.check();
    isRootNotifier.value = ok;
    if (!context.mounted) return;
    showSnack(context, ok ? 'Root terdeteksi ✓' : 'Root tidak tersedia');
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: isNightNotifier,
      builder: (_, __, ___) => ValueListenableBuilder<int>(
        // Deteksi ulang selesai → tab ini otomatis rebuild dengan data baru.
        valueListenable: DeviceInfo.revision,
        builder: (_, rev, ___) => ValueListenableBuilder<bool>(
          valueListenable: isRootNotifier,
          builder: (ctx, root, child) {
            final d = DeviceInfo.i;
            return SingleChildScrollView(
              physics: kScroll,
              padding: const EdgeInsets.all(18),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _pageHeader('Tentang', 'About This App', kGreen),
                    const SizedBox(height: 20),
                    Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                            gradient: LinearGradient(
                                colors: [
                                  kCyan.withOpacity(.08),
                                  kPurple.withOpacity(.06)
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight),
                            borderRadius: BorderRadius.circular(24),
                            border:
                                Border.all(color: kCyan.withOpacity(.2))),
                        child: Column(children: [
                          Stack(alignment: Alignment.bottomRight, children: [
                            const _AnimatedAvatar(),
                            Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                    color: kGreen,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: kPanel, width: 2.5)),
                                child: const Icon(Icons.check_rounded,
                                    color: Colors.white, size: 12)),
                          ]),
                          const SizedBox(height: 14),
                          Text('Xyz_AI',
                              style: TextStyle(
                                  color: kWhite,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -.5)),
                          const SizedBox(height: 4),
                          Text('Android Developer & Enthusiast',
                              style:
                                  TextStyle(color: mut(.4), fontSize: 13)),
                          const SizedBox(height: 14),
                          Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Chip root BISA DITEKAN → cek ulang akses
                                // root tanpa restart aplikasi.
                                Tap(
                                    onTap: () => _recheckRoot(ctx),
                                    child: _chip(
                                        root ? 'Root Active' : 'Non-Root',
                                        Icons.security_rounded,
                                        root ? kGreen : kYellow)),
                                const SizedBox(width: 8),
                                _chip(
                                    d.platform == '---' ? '…' : d.platform,
                                    Icons.developer_board_rounded,
                                    kCyan),
                                const SizedBox(width: 8),
                                _chip('v2.1', Icons.rocket_launch_rounded,
                                    kPurple),
                              ]),
                        ])),
                    const SizedBox(height: 20),
                    _sectionLabel('SPESIFIKASI', kCyan),
                    const SizedBox(height: 10),
                    // Semua nilai REALTIME dari DeviceInfo — dibaca dari
                    // device tempat app benar-benar berjalan, bukan hardcode.
                    _info('Perangkat', d.displayName,
                        Icons.phone_android_rounded,
                        d.spoofSuspected ? kYellow : kCyan),
                    _info('Chipset', d.platform,
                        Icons.developer_board_rounded, kPurple),
                    _info('CPU Core', '${d.cpuCores} core',
                        Icons.memory_rounded, kBlue),
                    _info('Root', root ? 'Aktif' : 'Tidak aktif',
                        Icons.verified_rounded, root ? kGreen : kRed),
                    _info('Android', 'Android ${d.androidVer}',
                        Icons.android_rounded, kTeal),
                    const SizedBox(height: 20),
                    _sectionLabel('FITUR', kPurple),
                    const SizedBox(height: 10),
                    _feat(Icons.account_tree_rounded, kPurple,
                        'Nested Command Menu',
                        'Kontrol berlapis — governor, frekuensi, cache, thermal, network, I/O.'),
                    _feat(Icons.terminal_rounded, kCyan, 'Eksekusi Root Real',
                        'Semua perintah dijalankan langsung via su -c ke kernel perangkat.'),
                    _feat(Icons.dashboard_rounded, kBlue, 'Live Dashboard',
                        'CPU multi-cluster, suhu, RAM, baterai — dengan sparkline realtime.'),
                    _feat(Icons.hub_rounded, kTeal, 'Multi-Cluster Aware',
                        'Frekuensi & governor diterapkan per-policy: LITTLE, BIG, dan PRIME.'),
                    _feat(Icons.battery_saver_rounded, kGreen,
                        'Hemat Daya Cerdas',
                        'Polling & animasi berhenti otomatis saat tab tak terlihat atau app di background.'),
                    _feat(Icons.lock_rounded, kYellow, 'Non-Root Compatible',
                        'Mode aman tanpa root — info tetap tampil, kontrol dikunci.'),
                    _feat(Icons.dark_mode_rounded, kOrange,
                        'Night / Light Mode',
                        'Ganti tema kapan saja dengan satu ketukan.'),
                    const SizedBox(height: 24),
                    Center(
                        child: Text('Dibuat dengan ❤️ oleh Xyz_AI',
                            style:
                                TextStyle(color: mut(.3), fontSize: 12))),
                    const SizedBox(height: 6),
                    Center(
                        child: Text('Xyz_AI © 2026',
                            style:
                                TextStyle(color: mut(.2), fontSize: 11))),
                    const SizedBox(height: 20),
                  ]),
            );
          },
        ),
      ),
    );
  }

  Widget _chip(String l, IconData i, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
          color: c.withOpacity(.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.withOpacity(.3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(i, color: c, size: 13),
        const SizedBox(width: 5),
        Text(l,
            style: TextStyle(
                color: c, fontSize: 11, fontWeight: FontWeight.w700)),
      ]));

  Widget _info(String label, String value, IconData icon, Color color) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                  color: kPanel,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder)),
              child: Row(children: [
                Icon(icon, color: color, size: 17),
                const SizedBox(width: 10),
                Text(label, style: TextStyle(color: mut(.4), fontSize: 12)),
                const Spacer(),
                Flexible(
                    child: Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: kWhite,
                            fontSize: 12,
                            fontWeight: FontWeight.w600))),
              ])));

  Widget _feat(IconData ic, Color c, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: kPanel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: kBorder)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                    color: c.withOpacity(.1),
                    borderRadius: BorderRadius.circular(11)),
                child: Icon(ic, color: c, size: 19)),
            const SizedBox(width: 12),
            Expanded(
                child:
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      color: kWhite,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(body,
                  style:
                      TextStyle(color: mut(.4), fontSize: 11.5, height: 1.4)),
            ])),
          ])));
}

// ═══════════════════════════════════════════════════════════════════
//  SHARED WIDGET HELPERS
// ═══════════════════════════════════════════════════════════════════

Widget _pageHeader(String title, String subtitle, Color accent) {
  return ValueListenableBuilder<bool>(
    valueListenable: isNightNotifier,
    builder: (_, night, __) =>
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _AppIcon(size: 36),
      const SizedBox(width: 12),
      Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w900,
                color: kWhite,
                letterSpacing: -.5)),
        Text(subtitle, style: TextStyle(fontSize: 11, color: mut(.35))),
      ])),
      Tap(
        onTap: () => isNightNotifier.value = !isNightNotifier.value,
        child: AnimatedContainer(
            duration: Motion.fast,
            curve: Motion.curve,
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
                color: (night ? kPurple : kYellow).withOpacity(.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: (night ? kPurple : kYellow).withOpacity(.35))),
            child: Icon(
                night ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                size: 18,
                color: night ? kPurple : kYellow)),
      ),
    ]),
  );
}

Widget _sectionLabel(String text, Color accent) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(children: [
      Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
              color: accent, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 8),
      Text(text,
          style: TextStyle(
              color: accent,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.8)),
    ]));
