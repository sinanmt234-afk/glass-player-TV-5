import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ───────────────────────── Globals ─────────────────────────

final navKey = GlobalKey<NavigatorState>();
late final SharedPreferences prefs;
late final Player player;
late final VideoController videoController;

const kDefaultM3u = 'https://iptv-org.github.io/iptv/index.m3u';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  GlassCfg.blur.value = prefs.getBool('blur') ?? false;
  ThemeCfg.dark.value = prefs.getBool('dark') ?? true;
  Favs.load();
  // keep memory low on small TVs
  PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 48 << 20;
  player = Player(configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024));
  videoController = VideoController(player);
  _tuneMpv();
  Engine.init();
  SystemChrome.setPreferredOrientations(
      [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const TvApp());
}

/// Settings that keep 1080p smooth on weak hardware WITHOUT lowering picture quality.
const kHwdec = 'mediacodec,mediacodec-copy';

Future<void> _tuneMpv() async {
  final dynamic p = player.platform; // libmpv backend on Android
  final cores = Platform.numberOfProcessors.clamp(2, 8).toInt();
  final props = <String, String>{
    // lightest built-in mpv preset, then explicit overrides below
    'profile': 'fast',
    // ── decoding ──
    // Hardware decoder first (zero-copy), then the copy variant, and only then software.
    'hwdec': kHwdec,
    'hwdec-codecs': 'all',
    // Only matters if a stream falls back to software decoding (e.g. odd interlaced MPEG-2):
    'vd-lavc-threads': '$cores',
    'vd-lavc-fast': 'yes',
    'vd-lavc-skiploopfilter': 'nonref',
    // drop a frame instead of stalling if the chip cannot keep up
    'framedrop': 'decoder+vo',
    'video-sync': 'audio',
    'interpolation': 'no',
    'deband': 'no',
    'blend-subtitles': 'no',
    // ── network resilience for IPTV / HLS ──
    'cache': 'yes',
    'cache-secs': '30',
    'demuxer-readahead-secs': '30',
    'demuxer-max-back-bytes': '16777216', // live TV never seeks back, do not hoard RAM
    'cache-pause-wait': '3',
    'network-timeout': '25',
    'user-agent': 'VLC/3.0.20 LibVLC/3.0.20',
    'stream-lavf-o': 'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5',
    // pick the best HLS variant up to ~1080p bitrates (skips 4K variants a low-end chip can't decode)
    'hls-bitrate': '14000000',
    'audio-buffer': '0.4',
    // ── cheap GPU paths (no visible change at 1080p on a 1080p screen) ──
    'gpu-dumb-mode': 'yes',
    'dither-depth': 'no',
    'correct-downscaling': 'no',
    'sigmoid-upscaling': 'no',
    'hdr-compute-peak': 'no',
    'scale': 'bilinear',
    'dscale': 'bilinear',
    'cscale': 'bilinear',
  };
  for (final e in props.entries) {
    try {
      await p.setProperty(e.key, e.value);
    } catch (_) {}
  }
}

Stream<T> throttle<T>(Stream<T> s, Duration d) {
  var last = DateTime.fromMillisecondsSinceEpoch(0);
  return s.where((_) {
    final n = DateTime.now();
    if (n.difference(last) >= d) {
      last = n;
      return true;
    }
    return false;
  });
}

// ───────────────────────── Models / helpers ─────────────────────────

class Item {
  const Item({
    required this.path,
    required this.title,
    required this.audio,
    this.durationSec = 0,
    this.live = false,
    this.headers = const {},
  });
  final String path;
  final String title;
  final bool audio;
  final int durationSec;
  final bool live;
  final Map<String, String> headers;
}

bool isAudioName(String n) {
  final e = n.split('.').last.toLowerCase();
  return const {'mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'opus', 'wma', 'amr', 'mka', 'ac3', 'alac'}
      .contains(e);
}

String fmt(Duration d) {
  String t(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${t(m)}:${t(s)}' : '${t(m)}:${t(s)}';
}

String flag(String cc) => cc.length == 2
    ? String.fromCharCodes(cc.toUpperCase().codeUnits.map((c) => 0x1F1E6 + c - 65))
    : '';

bool _playerShown = false;
Future<void> openPlayer() {
  if (_playerShown) return Future<void>.value();
  _playerShown = true;
  final f = navKey.currentState?.push<void>(PageRouteBuilder<void>(
    // opaque = the page underneath (channel grid, glass background) is NOT painted
    // behind the video. With the default (false) Flutter kept drawing it on every video
    // frame, which is what made 1080p stutter on weak TV GPUs.
    opaque: true,
    pageBuilder: (_, __, ___) => Theme(data: kDarkTheme, child: const PlayerPage()),
    transitionsBuilder: (_, a, __, c) => FadeTransition(opacity: a, child: c),
  ));
  return (f ?? Future<void>.value()).then((_) {
    _playerShown = false;
  });
}

// ───────────────────────── Playback engine ─────────────────────────

/// Favorite channels (by stream URL), saved on the device.
class Favs {
  static Set<String> _s = {};
  static final tick = ValueNotifier<int>(0);

  static void load() {
    _s = (prefs.getStringList('favs') ?? const <String>[]).toSet();
  }

  static bool has(String url) => _s.contains(url);
  static int get count => _s.length;

  static bool toggle(String url) {
    final added = _s.add(url);
    if (!added) _s.remove(url);
    prefs.setStringList('favs', _s.toList());
    tick.value++;
    return added;
  }
}

/// Remembers live channels that failed. Hidden after 2 failures, cleared when they play fine again.
class Strikes {
  static Map<String, int> _m = {};
  static final Map<String, int> _lastAt = {};
  static final tick = ValueNotifier<int>(0);

  static void load() {
    try {
      final s = prefs.getString('strikes');
      if (s != null) _m = Map<String, int>.from(jsonDecode(s) as Map);
    } catch (_) {}
  }

  static bool hidden(String url) => (_m[url] ?? 0) >= 2;
  static int get hiddenCount => _m.values.where((v) => v >= 2).length;

  static void bad(String url) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_lastAt[url] ?? 0) < 20000) return; // one failure can raise several errors
    _lastAt[url] = now;
    _m[url] = (_m[url] ?? 0) + 1;
    _save();
  }

  static void ok(String url) {
    if (_m.remove(url) != null) _save();
  }

  static void clear() {
    _m = {};
    _save();
    tick.value++;
  }

  static void _save() {
    while (_m.length > 3000) {
      _m.remove(_m.keys.first);
    }
    prefs.setString('strikes', jsonEncode(_m));
  }
}

class Engine {
  static List<Item> queue = [];
  static final current = ValueNotifier<Item?>(null);
  static final error = ValueNotifier<String?>(null);
  static final notice = ValueNotifier<String?>(null);
  static final quality = ValueNotifier<int>(0);
  static const qualityNames = ['Best', 'Balanced', 'Data saver'];
  static const _qBitrate = ['14000000', '4000000', '1500000'];
  static Timer? _wd;
  static int _stall = 0, _autoSkips = 0;

  static void say(String t) {
    notice.value = null;
    notice.value = t;
  }

  /// Pick the HLS variant that fits the chosen quality (mpv does not switch variants by itself).
  static Future<void> applyQuality() async {
    try {
      final dynamic p = player.platform;
      await p.setProperty('hls-bitrate', _qBitrate[quality.value]);
    } catch (_) {}
  }

  static Future<bool> _netOk() async {
    try {
      final r = await InternetAddress.lookup('example.com').timeout(const Duration(seconds: 4));
      return r.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _failed(Item it, {bool skip = false}) async {
    if (!await _netOk()) {
      say('No internet connection');
      return;
    }
    Strikes.bad(it.path);
    if (!skip || current.value?.path != it.path) return;
    if (_autoSkips < 3) {
      _autoSkips++;
      say('Channel not responding. Trying the next one…');
      player.next();
    } else {
      say('Several channels are not responding');
    }
  }

  /// If a live channel sits on "buffering" for 20 s it is treated as stuck.
  static void _startWatch() {
    _wd?.cancel();
    _wd = Timer.periodic(const Duration(seconds: 2), (_) {
      final it = current.value;
      if (it == null || !it.live) {
        _stall = 0;
        return;
      }
      if (player.state.buffering) {
        _stall += 2;
        if (_stall >= 20) {
          _stall = 0;
          _failed(it, skip: true);
        }
      } else {
        _stall = 0;
        if (player.state.playing && player.state.position > const Duration(seconds: 8)) {
          Strikes.ok(it.path);
          _autoSkips = 0;
        }
      }
    });
  }
  static int _lastIndex = -1;
  static int _lastSave = 0;
  static bool _resuming = false;

  static void init() {
    Strikes.load();
    quality.value = (prefs.getInt('tvq') ?? 0).clamp(0, 2).toInt();
    _startWatch();
    player.stream.playlist.listen((p) {
      if (p.medias.isEmpty || p.index < 0 || p.index >= p.medias.length) return;
      if (p.index == _lastIndex) return;
      _lastIndex = p.index;
      final k = p.medias[p.index].extras?['i'];
      if (k is! int || k < 0 || k >= queue.length) return;
      final found = queue[k];
      error.value = null;
      current.value = found;
      _onStart(found);
    });
    player.stream.error.listen((e) {
      if (e.isEmpty) return;
      error.value = e;
      final it = current.value;
      if (it != null && it.live) _failed(it);
    });
    player.stream.position.listen((pos) {
      final it = current.value;
      if (it == null || it.live || _resuming) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSave > 3000) {
        _lastSave = now;
        _save(it, pos);
      }
    });
    player.stream.playing.listen((p) {
      final it = current.value;
      if (p) error.value = null;
      if (it != null && !it.live && !p && !_resuming) _save(it, player.state.position);
    });
  }

  static void _save(Item it, Duration pos) {
    final d = player.state.duration.inMilliseconds;
    if (d > 0 && pos.inMilliseconds > d - 8000) {
      prefs.remove('pos:${it.path}');
    } else {
      prefs.setInt('pos:${it.path}', pos.inMilliseconds);
    }
  }

  static Future<void> _onStart(Item it) async {
    if (it.live) return;
    final saved = prefs.getInt('pos:${it.path}') ?? 0;
    if (saved <= 5000) return;
    _resuming = true;
    try {
      await Future.delayed(const Duration(milliseconds: 250));
      for (var i = 0; i < 30; i++) {
        if (player.state.duration > Duration.zero) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      final d = player.state.duration.inMilliseconds;
      if (d > 0 && saved < d - 8000 && current.value?.path == it.path) {
        await player.seek(Duration(milliseconds: saved));
      }
    } catch (_) {}
    _resuming = false;
  }

  static Future<void> play(List<Item> items, int index) async {
    if (items.isEmpty) return;
    try {
      // media_kit sets its own hwdec when the video controller starts; re-assert ours.
      final dynamic p = player.platform;
      await p.setProperty('hwdec', kHwdec);
    } catch (_) {}
    if (items[index].live) await applyQuality();
    queue = items;
    _lastIndex = -1;
    current.value = items[index];
    await player.open(Playlist(
      [
        for (var i = 0; i < items.length; i++)
          Media(
            items[i].path,
            httpHeaders: items[i].headers.isEmpty ? null : items[i].headers,
            extras: {'i': i},
          ),
      ],
      index: index,
    ));
  }

  static Future<void> stop() async {
    current.value = null;
    await player.stop();
  }
}

// ───────────────────────── Theme + glass widgets ─────────────────────────

ThemeData _buildTheme(bool dark) {
  final b = dark ? Brightness.dark : Brightness.light;
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6C8CFF), brightness: b),
    scaffoldBackgroundColor: Colors.transparent,
  );
}

final ThemeData kDarkTheme = _buildTheme(true);
final ThemeData kLightTheme = _buildTheme(false);

bool isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

/// Dark / Light app theme (saved on the device). The video player is always dark.
class ThemeCfg {
  static final ValueNotifier<bool> dark = ValueNotifier(true);
  static void toggle() {
    dark.value = !dark.value;
    prefs.setBool('dark', dark.value);
  }
}

class TvApp extends StatelessWidget {
  const TvApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeCfg.dark,
      builder: (context, dark, _) => MaterialApp(
        navigatorKey: navKey,
        debugShowCheckedModeBanner: false,
        title: 'Glass Player TV',
        theme: dark ? kDarkTheme : kLightTheme,
        home: const HomePage(),
      ),
    );
  }
}

/// Background lives per page, so it is not painted while a video plays.
class GlassScaffold extends StatelessWidget {
  const GlassScaffold({super.key, required this.body});
  final Widget body;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(fit: StackFit.expand, children: [
        const RepaintBoundary(child: GlassBackground()),
        body,
      ]),
    );
  }
}

class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key});

  Widget _blob(double size, Color c, {double? top, double? left, double? right, double? bottom}) => Positioned(
        top: top,
        left: left,
        right: right,
        bottom: bottom,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [c, c.withOpacity(0)]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [Color(0xFF0B1020), Color(0xFF1A1033), Color(0xFF071A2B)]
                  : const [Color(0xFFEEF2FF), Color(0xFFF6EDFB), Color(0xFFE8F5FF)],
            ),
          ),
        ),
        _blob(420, dark ? const Color(0x886C5CFF) : const Color(0x556C5CFF), top: -120, left: -100),
        _blob(380, dark ? const Color(0x77FF4FA3) : const Color(0x44FF4FA3), top: 120, right: -140),
        _blob(440, dark ? const Color(0x7700C2FF) : const Color(0x4400C2FF), bottom: -160, left: 120),
      ],
    );
  }
}

class GlassCfg {
  static final ValueNotifier<bool> blur = ValueNotifier(false);
}

class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding,
    this.blur = 22,
    this.flat = false,
    this.scrim = false,
    this.tint,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final bool flat; // never blurs (used for lists / grids)
  final bool scrim; // dark fill for panels on top of video when blur is off
  final Color? tint;

  Widget _box(BuildContext context) {
    final dark = isDark(context);
    final br = BorderRadius.circular(radius);
    Color a, b, border;
    if (tint != null) {
      a = tint!.withOpacity(dark ? 0.55 : 0.34);
      b = tint!.withOpacity(dark ? 0.30 : 0.20);
      border = dark ? Colors.white.withOpacity(0.28) : tint!.withOpacity(0.60);
    } else if (scrim) {
      a = Colors.black.withOpacity(0.70);
      b = Colors.black.withOpacity(0.58);
      border = Colors.white.withOpacity(0.28);
    } else if (dark) {
      a = Colors.white.withOpacity(0.18);
      b = Colors.white.withOpacity(0.06);
      border = Colors.white.withOpacity(0.28);
    } else {
      a = Colors.white.withOpacity(0.74);
      b = Colors.white.withOpacity(0.42);
      border = const Color(0xFF1B2440).withOpacity(0.14);
    }
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: br,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [a, b]),
        border: Border.all(color: border, width: 1.2),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Panels on top of live video never blur: a BackdropFilter over a video texture is very
    // expensive and was a second cause of dropped frames when "Blur effect" was ON.
    if (flat || scrim) return _box(context);
    return ValueListenableBuilder<bool>(
      valueListenable: GlassCfg.blur,
      builder: (c, on, _) {
        if (!on) return _box(c);
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: _box(c),
          ),
        );
      },
    );
  }
}

/// A glass button that can be focused with the remote and activated with OK.
/// Hold OK (if [onLongPress] is given) for a secondary action.
class TvButton extends StatefulWidget {
  const TvButton({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.radius = 20,
    this.padding = const EdgeInsets.all(12),
    this.selected = false,
    this.blur = false,
    this.onFocus,
  });
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool selected;
  final bool blur;
  final VoidCallback? onFocus;

  @override
  State<TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<TvButton> {
  bool _f = false;
  Timer? _lp;
  bool _fired = false;

  @override
  void dispose() {
    _lp?.cancel();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    final k = e.logicalKey;
    final isOk = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter;
    if (!isOk) return KeyEventResult.ignored; // arrows etc. move focus
    if (widget.onLongPress == null) {
      if (e is KeyDownEvent) widget.onTap();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent) {
      _fired = false;
      _lp?.cancel();
      _lp = Timer(const Duration(milliseconds: 550), () {
        _fired = true;
        widget.onLongPress!();
      });
    } else if (e is KeyUpEvent) {
      _lp?.cancel();
      if (!_fired) widget.onTap();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (v) {
        setState(() => _f = v);
        if (v) widget.onFocus?.call();
      },
      onKeyEvent: _key,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _f ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 140),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(
                  color: _f ? (isDark(context) ? Colors.white : const Color(0xFF1B2440)) : Colors.transparent,
                  width: 3),
            ),
            child: Glass(
              radius: widget.radius,
              flat: !widget.blur,
              padding: widget.padding,
              tint: widget.selected ? Theme.of(context).colorScheme.primary : null,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

Widget bigTitle(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(t, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
    );

// ───────────────────────── Home ─────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  final Set<int> visited = {0};

  Widget _nav(IconData icon, String label, int i) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TvButton(
          autofocus: i == 0,
          selected: tab == i,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          onFocus: () => setState(() {
            tab = i;
            visited.add(i);
          }),
          onTap: () => setState(() {
            tab = i;
            visited.add(i);
          }),
          child: Row(children: [
            Icon(icon),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
          ]),
        ),
      );

  Widget _themeBtn() => ValueListenableBuilder<bool>(
        valueListenable: ThemeCfg.dark,
        builder: (c, d, _) => TvButton(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          onTap: ThemeCfg.toggle,
          child: Row(children: [
            Icon(d ? Icons.dark_mode_rounded : Icons.light_mode_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Text(d ? 'Dark theme' : 'Light theme',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ]),
        ),
      );

  Widget _content(int i) {
    if (!visited.contains(i)) return const SizedBox.shrink();
    switch (i) {
      case 0:
        return const LiveTab();
      case 1:
        return const LibraryTab(video: true);
      case 2:
        return const LibraryTab(video: false);
      default:
        return const MoreTab();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Row(children: [
          SizedBox(
            width: 220,
            child: Glass(
              radius: 30,
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(6, 6, 6, 18),
                  child: Text('Glass Player', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ),
                _nav(Icons.live_tv_rounded, 'Live TV', 0),
                _nav(Icons.video_library_rounded, 'Videos', 1),
                _nav(Icons.library_music_rounded, 'Music', 2),
                _nav(Icons.settings_remote_rounded, 'More', 3),
                const Spacer(),
                _themeBtn(),
              ]),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: IndexedStack(
              index: tab,
              children: [
                for (var i = 0; i < 4; i++) ExcludeFocus(excluding: i != tab, child: _content(i)),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────── Live TV (M3U / IPTV) ─────────────────────────

class Channel {
  const Channel({
    required this.name,
    required this.url,
    required this.group,
    required this.logo,
    required this.cc,
    required this.headers,
  });
  final String name, url, group, logo, cc;
  final Map<String, String> headers;
  Item toItem() => Item(path: url, title: name, audio: false, live: true, headers: headers);
}

const Map<String, String> kNoHeaders = {};

String _attr(String line, String key) => RegExp('$key="([^"]*)"').firstMatch(line)?.group(1)?.trim() ?? '';

List<Channel> parseM3u(String text) {
  final out = <Channel>[];
  var name = '', group = '', logo = '', cc = '';
  var headers = kNoHeaders;
  var have = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF')) {
      have = true;
      headers = kNoHeaders;
      final ci = line.lastIndexOf(',');
      name = ci >= 0 ? line.substring(ci + 1).trim() : '';
      group = _attr(line, 'group-title');
      logo = _attr(line, 'tvg-logo');
      final id = _attr(line, 'tvg-id');
      cc = RegExp(r'\.([a-z]{2})(?:@|$)').firstMatch(id)?.group(1)?.toUpperCase() ?? '';
    } else if (line.startsWith('#EXTVLCOPT:')) {
      final kv = line.substring(11);
      final i = kv.indexOf('=');
      if (i > 0) {
        final k = kv.substring(0, i).toLowerCase();
        final v = kv.substring(i + 1);
        if (identical(headers, kNoHeaders)) headers = <String, String>{};
        if (k == 'http-referrer' || k == 'http-referer') headers['Referer'] = v;
        if (k == 'http-user-agent') headers['User-Agent'] = v;
      }
    } else if (line.startsWith('#')) {
      continue;
    } else if (have) {
      out.add(Channel(
        name: name.isEmpty ? line : name,
        url: line,
        group: group,
        logo: logo,
        cc: cc,
        headers: headers,
      ));
      have = false;
    }
  }
  return out;
}

List<Channel> parseM3uBytes(Uint8List b) => parseM3u(utf8.decode(b, allowMalformed: true));

Future<Uint8List> fetchBytes(String url) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await c.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'VLC/3.0.20 LibVLC/3.0.20');
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final bb = BytesBuilder(copy: false);
    await for (final chunk in res) {
      bb.add(chunk);
    }
    return bb.takeBytes();
  } finally {
    c.close();
  }
}

Future<String?> askText(BuildContext context, String title, String initial, {String hint = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(c, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

class LiveTab extends StatefulWidget {
  const LiveTab({super.key});
  @override
  State<LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<LiveTab> {
  String url = prefs.getString('tvurl') ?? kDefaultM3u;

  Future<void> _edit() async {
    final r = await askText(context, 'Playlist URL (.m3u)', url);
    if (r == null || r.isEmpty) return;
    prefs.setString('tvurl', r);
    setState(() => url = r);
  }

  @override
  Widget build(BuildContext context) => LiveView(url: url, onEditUrl: _edit);
}

class TvPage extends StatelessWidget {
  const TvPage({super.key, required this.url});
  final String url;
  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: LiveView(url: url),
      ),
    );
  }
}

class LiveView extends StatefulWidget {
  const LiveView({super.key, required this.url, this.onEditUrl});
  final String url;
  final VoidCallback? onEditUrl;
  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> {
  List<Channel> all = [];
  List<Channel> shown = [];
  List<String> groups = [];
  Map<String, int> countries = {};
  bool loading = true;
  String? err;
  String q = '';
  String group = 'All';
  bool favOnly = false;
  String country = prefs.getString('tvcountry') ?? '';

  @override
  void initState() {
    super.initState();
    Strikes.tick.addListener(_onTick);
    _load(false);
  }

  @override
  void didUpdateWidget(LiveView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load(false);
  }

  Future<void> _bgRefresh(File f) async {
    try {
      await f.writeAsBytes(await fetchBytes(widget.url));
    } catch (_) {}
  }

  Future<void> _load(bool force) async {
    setState(() {
      loading = true;
      err = null;
    });
    try {
      final f = File('${Directory.systemTemp.path}/tv_${widget.url.hashCode}.m3u');
      Uint8List bytes;
      var stale = false;
      if (f.existsSync() && !force) {
        // start instantly from the saved list
        bytes = await f.readAsBytes();
        stale = DateTime.now().difference(f.lastModifiedSync()).inHours >= 12;
      } else {
        try {
          bytes = await fetchBytes(widget.url);
          await f.writeAsBytes(bytes);
        } catch (e) {
          if (!f.existsSync()) rethrow;
          bytes = await f.readAsBytes();
        }
      }
      if (stale) _bgRefresh(f);
      final list = await compute(parseM3uBytes, bytes);
      final gs = <String, int>{};
      final cs = <String, int>{};
      for (final c in list) {
        for (final g in c.group.split(';')) {
          final t = g.trim();
          if (t.isNotEmpty) gs[t] = (gs[t] ?? 0) + 1;
        }
        if (c.cc.isNotEmpty) cs[c.cc] = (cs[c.cc] ?? 0) + 1;
      }
      if (!mounted) return;
      setState(() {
        all = list;
        groups = gs.keys.toList()..sort();
        countries = cs;
        if (country.isNotEmpty && !cs.containsKey(country)) country = '';
        if (group != 'All' && !gs.containsKey(group)) group = 'All';
        loading = false;
        _apply();
        if (list.isEmpty) err = 'No channels found in this playlist.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        err = 'Could not load the playlist.\nCheck the internet connection.\n($e)';
      });
    }
  }

  bool get hideBad => prefs.getBool('hidebad') ?? true;

  void _onTick() {
    if (mounted) setState(_apply);
  }

  @override
  void dispose() {
    Strikes.tick.removeListener(_onTick);
    super.dispose();
  }

  void _apply() {
    final ql = q.toLowerCase();
    final hide = hideBad && !favOnly;
    shown = all.where((c) {
      if (favOnly && !Favs.has(c.url)) return false;
      if (hide &&
          (Strikes.hidden(c.url) || c.name.contains('[Geo-blocked]') || c.name.contains('[Not 24/7]'))) {
        return false;
      }
      if (country.isNotEmpty && c.cc != country) return false;
      if (group != 'All' && !c.group.split(';').map((e) => e.trim()).contains(group)) return false;
      if (ql.isNotEmpty && !c.name.toLowerCase().contains(ql)) return false;
      return true;
    }).toList();
  }

  Future<void> _play(int i) async {
    final start = math.max(0, i - 100);
    final end = math.min(shown.length, i + 101);
    final win = shown.sublist(start, end);
    await Engine.play(win.map((c) => c.toItem()).toList(), i - start);
    await openPlayer();
    if (mounted) setState(_apply);
  }

  void _toggleFav(Channel c) {
    final added = Favs.toggle(c.url);
    setState(() {
      if (favOnly) _apply();
    });
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text(added ? '★ Added to favorites: ${c.name}' : 'Removed from favorites: ${c.name}'),
    ));
  }

  Future<void> _search() async {
    final r = await askText(context, 'Search channels', q, hint: 'Channel name');
    if (r == null) return;
    setState(() {
      q = r;
      _apply();
    });
  }

  void _setCountry(String v) {
    prefs.setString('tvcountry', v);
    setState(() {
      country = v;
      _apply();
    });
  }

  void _pickCountry() {
    final list = countries.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    showDialog(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: Colors.transparent,
        child: Glass(
          radius: 28,
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 620, maxHeight: MediaQuery.of(c).size.height * 0.8),
            child: SingleChildScrollView(
              child: Wrap(spacing: 8, runSpacing: 6, children: [
                ChoiceChip(
                  autofocus: true,
                  label: const Text('🌍 All'),
                  selected: country.isEmpty,
                  onSelected: (_) {
                    Navigator.pop(c);
                    _setCountry('');
                  },
                ),
                for (final e in list)
                  ChoiceChip(
                    label: Text('${flag(e.key)} ${e.key} (${e.value})'),
                    selected: country == e.key,
                    onSelected: (_) {
                      Navigator.pop(c);
                      _setCountry(e.key);
                    },
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hb(IconData i, String tip, VoidCallback f) => Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Tooltip(
          message: tip,
          child: TvButton(radius: 18, padding: const EdgeInsets.all(12), onTap: f, child: Icon(i)),
        ),
      );

  Widget _card(Channel c, int i) {
    const fallback = Icon(Icons.tv_rounded, size: 40, color: Colors.black45);
    return TvButton(
      radius: 18,
      padding: const EdgeInsets.all(10),
      onTap: () => _play(i),
      onLongPress: () => _toggleFav(c),
      child: Column(children: [
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.92),
              borderRadius: BorderRadius.circular(12),
            ),
            child: c.logo.isEmpty
                ? fallback
                : Image.network(c.logo,
                    fit: BoxFit.contain, cacheWidth: 160, errorBuilder: (_, __, ___) => fallback),
          ),
        ),
        const SizedBox(height: 8),
        Text(Favs.has(c.url) ? '★ ${c.name}' : c.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _body() {
    if (loading) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(),
          SizedBox(height: 14),
          Text('Loading channels…'),
        ]),
      );
    }
    if (err != null) {
      return Center(
        child: Glass(
          radius: 28,
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 44),
            const SizedBox(height: 12),
            Text(err!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TvButton(
              autofocus: true,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              onTap: () => _load(true),
              child: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 58,
        child: ListView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: TvButton(
                radius: 18,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                selected: favOnly,
                onTap: () => setState(() {
                  favOnly = !favOnly;
                  _apply();
                }),
                child: Row(children: [
                  Icon(favOnly ? Icons.star_rounded : Icons.star_border_rounded, size: 18),
                  const SizedBox(width: 6),
                  Text('Favorites (${Favs.count})'),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: TvButton(
                radius: 18,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                selected: hideBad,
                onTap: () => setState(() {
                  prefs.setBool('hidebad', !hideBad);
                  _apply();
                }),
                child: Row(children: [
                  Icon(hideBad ? Icons.verified_rounded : Icons.all_inclusive_rounded, size: 18),
                  const SizedBox(width: 6),
                  Text(hideBad && Strikes.hiddenCount > 0
                      ? 'Working only (${Strikes.hiddenCount} hidden)'
                      : 'Working only'),
                ]),
              ),
            ),
            if (q.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: TvButton(
                  radius: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  selected: true,
                  onTap: () => setState(() {
                    q = '';
                    _apply();
                  }),
                  child: Row(children: [
                    const Icon(Icons.close_rounded, size: 18),
                    const SizedBox(width: 6),
                    Text(q),
                  ]),
                ),
              ),
            for (final g in ['All', ...groups])
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: TvButton(
                  radius: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  selected: group == g,
                  onTap: () => setState(() {
                    group = g;
                    _apply();
                  }),
                  child: Text(g, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
        child: Text('${shown.length} channels', style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: shown.isEmpty
            ? const Center(child: Text('No channels found'))
            : GridView.builder(
                clipBehavior: Clip.none,
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 170,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 1.1,
                ),
                itemCount: shown.length,
                itemBuilder: (c, i) => _card(shown[i], i),
              ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Live TV', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const Spacer(),
        if (countries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: TvButton(
              radius: 18,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              onTap: _pickCountry,
              child: Text(country.isEmpty ? '🌍 All countries' : '${flag(country)} $country',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        _hb(Icons.search_rounded, 'Search', _search),
        _hb(Icons.refresh_rounded, 'Refresh', () => _load(true)),
        if (widget.onEditUrl != null) _hb(Icons.link_rounded, 'Playlist URL', widget.onEditUrl!),
      ]),
      const SizedBox(height: 10),
      Expanded(child: _body()),
    ]);
  }
}

// ───────────────────────── Library (videos / music) ─────────────────────────

class Library {
  static Future<bool> ensure() async {
    final ps = await PhotoManager.requestPermissionExtend();
    return ps.hasAccess;
  }

  static Future<void> playFrom(List<AssetEntity> assets, int tapped) async {
    final files = await Future.wait(assets.map((a) => a.file));
    final items = <Item>[];
    var idx = 0;
    for (var i = 0; i < assets.length; i++) {
      final f = files[i];
      if (f == null) continue;
      if (i == tapped) idx = items.length;
      items.add(Item(
        path: f.path,
        title: assets[i].title ?? f.path.split('/').last,
        audio: assets[i].type == AssetType.audio,
        durationSec: assets[i].duration,
      ));
    }
    if (items.isEmpty) return;
    await Engine.play(items, idx);
    openPlayer();
  }
}

class Thumb extends StatefulWidget {
  const Thumb({super.key, required this.asset});
  final AssetEntity asset;
  @override
  State<Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<Thumb> {
  late final Future<Uint8List?> f = widget.asset.thumbnailDataWithSize(const ThumbnailSize(240, 135));
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: f,
      builder: (c, s) => s.data == null
          ? const Center(child: Icon(Icons.movie_rounded))
          : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key, required this.video});
  final bool video;
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  List<AssetPathEntity> paths = [];
  List<int> counts = [];
  bool loading = true, denied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final ok = await Library.ensure();
    if (!ok) {
      if (mounted) setState(() { denied = true; loading = false; });
      return;
    }
    final ps = await PhotoManager.getAssetPathList(
        type: widget.video ? RequestType.video : RequestType.audio);
    final cs = await Future.wait(ps.map((p) => p.assetCountAsync));
    final fp = <AssetPathEntity>[];
    final fc = <int>[];
    for (var i = 0; i < ps.length; i++) {
      if (cs[i] > 0) {
        fp.add(ps[i]);
        fc.add(cs[i]);
      }
    }
    if (!mounted) return;
    setState(() { paths = fp; counts = fc; denied = false; loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.video ? 'Videos' : 'Music';
    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (denied) {
      body = Center(
        child: TvButton(
          autofocus: true,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          onTap: () async {
            final ps = await PhotoManager.requestPermissionExtend();
            if (!ps.hasAccess) {
              await PhotoManager.openSetting();
            } else {
              _load();
            }
          },
          child: const Text('Allow access to videos and music', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      );
    } else if (paths.isEmpty) {
      body = Center(child: Text(widget.video ? 'No videos found on this device' : 'No music found on this device'));
    } else {
      body = ListView.builder(
        clipBehavior: Clip.none,
        padding: const EdgeInsets.all(8),
        itemCount: paths.length,
        itemBuilder: (c, i) {
          final p = paths[i];
          final name = p.isAll ? (widget.video ? 'All videos' : 'All music') : p.name;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TvButton(
              padding: const EdgeInsets.all(16),
              onTap: () => Navigator.push(
                  c, MaterialPageRoute(builder: (_) => FolderPage(path: p, title: name))),
              child: Row(children: [
                const Icon(Icons.folder_rounded, size: 34),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                ),
                Text('${counts[i]}'),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded),
              ]),
            ),
          );
        },
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bigTitle(title), Expanded(child: body)]);
  }
}

class FolderPage extends StatefulWidget {
  const FolderPage({super.key, required this.path, required this.title});
  final AssetPathEntity path;
  final String title;
  @override
  State<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends State<FolderPage> {
  List<AssetEntity>? assets;

  @override
  void initState() {
    super.initState();
    widget.path.getAssetListPaged(page: 0, size: 3000).then((v) {
      if (mounted) setState(() => assets = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = assets;
    return GlassScaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          bigTitle(widget.title),
          Expanded(
            child: a == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.all(8),
                    itemCount: a.length,
                    itemBuilder: (c, i) {
                      final e = a[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: TvButton(
                          autofocus: i == 0,
                          padding: const EdgeInsets.all(8),
                          onTap: () => Library.playFrom(a, i),
                          child: Row(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox(
                                width: 128,
                                height: 72,
                                child: e.type == AssetType.video
                                    ? Thumb(asset: e)
                                    : const Center(child: Icon(Icons.music_note_rounded, size: 34)),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(e.title ?? '',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                                const SizedBox(height: 4),
                                Text(fmt(Duration(seconds: e.duration)),
                                    style: Theme.of(context).textTheme.bodySmall),
                              ]),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

// ───────────────────────── More ─────────────────────────

class MoreTab extends StatelessWidget {
  const MoreTab({super.key});

  Future<void> _openUrl(BuildContext context) async {
    final url = await askText(context, 'Network stream', '', hint: 'https://… .mp4 / .m3u8 / .m3u');
    if (url == null || url.isEmpty) return;
    if (url.toLowerCase().split('?').first.endsWith('.m3u')) {
      if (!context.mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => TvPage(url: url)));
      return;
    }
    await Engine.play([Item(path: url, title: url.split('/').last, audio: isAudioName(url))], 0);
    openPlayer();
  }

  Widget _help(String key, String what) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(width: 150, child: Text(key, style: const TextStyle(fontWeight: FontWeight.w700))),
          Expanded(child: Text(what)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ListView(clipBehavior: Clip.none, padding: const EdgeInsets.all(8), children: [
      bigTitle('More'),
      TvButton(
        padding: const EdgeInsets.all(16),
        onTap: () => _openUrl(context),
        child: const Row(children: [
          Icon(Icons.link_rounded, size: 32),
          SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Network stream', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
              Text('HTTP, HLS, RTSP link or .m3u playlist'),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      ValueListenableBuilder<bool>(
        valueListenable: ThemeCfg.dark,
        builder: (c, d, _) => TvButton(
          padding: const EdgeInsets.all(16),
          onTap: ThemeCfg.toggle,
          child: Row(children: [
            Icon(d ? Icons.dark_mode_rounded : Icons.light_mode_rounded, size: 32),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Theme', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                Text('Switch between the Dark and Light look'),
              ]),
            ),
            Text(d ? 'Dark' : 'Light', style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      ValueListenableBuilder<int>(
        valueListenable: Engine.quality,
        builder: (c, q, _) => TvButton(
          padding: const EdgeInsets.all(16),
          onTap: () {
            Engine.quality.value = (q + 1) % 3;
            prefs.setInt('tvq', Engine.quality.value);
          },
          child: Row(children: [
            const Icon(Icons.high_quality_rounded, size: 32),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Live TV quality', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                Text('Best = highest quality. Choose Balanced or Data saver if channels keep buffering'),
              ]),
            ),
            Text(Engine.qualityNames[q], style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      TvButton(
        padding: const EdgeInsets.all(16),
        onTap: () {
          Strikes.clear();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hidden channels reset')));
        },
        child: const Row(children: [
          Icon(Icons.restart_alt_rounded, size: 32),
          SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Reset hidden channels', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
              Text('Bring back channels that were hidden because they did not work'),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      ValueListenableBuilder<bool>(
        valueListenable: GlassCfg.blur,
        builder: (c, on, _) => TvButton(
          padding: const EdgeInsets.all(16),
          onTap: () {
            GlassCfg.blur.value = !on;
            prefs.setBool('blur', !on);
          },
          child: Row(children: [
            const Icon(Icons.blur_on_rounded, size: 32),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Blur effect', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                Text('Prettier glass. Keep OFF on low-end TVs for the smoothest playback'),
              ]),
            ),
            Text(on ? 'ON' : 'OFF', style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        ),
      ),
      const SizedBox(height: 22),
      Glass(
        radius: 24,
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Remote control', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          _help('OK', 'Press: open controls (Pause is highlighted, not pressed). Hold: 2× speed (videos)'),
          _help('◀  ▶', 'Seek 10 s. With controls open: move between the buttons'),
          _help('▲  ▼', 'Live TV: next / previous channel. Videos: open controls'),
          _help('Hold OK on a channel', 'Add / remove favorite ★ (or use the ♥ button in the player)'),
          _help('Menu', 'Audio track, subtitles and speed'),
          _help('Play / Pause', 'Play or pause'),
          _help('Back', 'Close controls, then stop and leave the player'),
        ]),
      ),
    ]);
  }
}

// ───────────────────────── Player page ─────────────────────────

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final FocusNode _root = FocusNode(debugLabel: 'player-root');
  final FocusNode _playNode = FocusNode(debugLabel: 'player-play');
  bool _panel = false;
  bool _closing = false;
  bool _osdBig = false;
  BoxFit _fit = BoxFit.contain;
  Timer? _hide, _osdT, _holdT;
  String? _osd;
  late final bool _audio;
  bool _selDown = false;
  late final Stream<Duration> _pos = throttle(player.stream.position, const Duration(milliseconds: 500));
  bool _fast = false;
  double _prevRate = 1.0;
  bool _stats = false, _polling = false;
  String _statsTxt = '';
  Timer? _statsT;

  bool get _live => Engine.current.value?.live ?? false;

  @override
  void initState() {
    super.initState();
    _audio = Engine.current.value?.audio ?? false;
    _panel = _audio;
    Engine.error.addListener(_onErr);
    Engine.notice.addListener(_onNotice);
    Engine.current.addListener(_onItem);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onItem();
      if (_panel) _playNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    _osdT?.cancel();
    _holdT?.cancel();
    _statsT?.cancel();
    if (_fast) player.setRate(_prevRate);
    Engine.error.removeListener(_onErr);
    Engine.notice.removeListener(_onNotice);
    Engine.current.removeListener(_onItem);
    _root.dispose();
    _playNode.dispose();
    Engine.stop();
    super.dispose();
  }

  void _onItem() {
    final it = Engine.current.value;
    if (!mounted || it == null || !it.live) return;
    _osdShow(it.title, ms: 3500);
  }

  void _onNotice() {
    final t = Engine.notice.value;
    if (!mounted || t == null) return;
    _osdShow(t, ms: 3500);
  }

  void _onErr() {
    if (!mounted || Engine.error.value == null) return;
    _osdShow(_live ? 'Channel not working. Press ▲ or ▼ for another one' : 'Cannot play this file', ms: 3500);
  }

  void _osdShow(String t, {int ms = 1200, bool big = false}) {
    _osdT?.cancel();
    setState(() {
      _osd = t;
      _osdBig = big;
    });
    _osdT = Timer(Duration(milliseconds: ms), () {
      if (mounted) setState(() => _osd = null);
    });
  }

  void _kick() {
    _hide?.cancel();
    if (_audio) return;
    _hide = Timer(const Duration(seconds: 6), _hidePanel);
  }

  void _showPanel() {
    setState(() => _panel = true);
    _kick();
    // focus the Pause button (selected, but not pressed) so < > move between the options
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panel) _playNode.requestFocus();
    });
  }

  void _hidePanel() {
    if (!mounted || _audio) return;
    _hide?.cancel();
    setState(() => _panel = false);
    _root.requestFocus();
  }

  void _skip(int s) {
    if (_live) return;
    var t = player.state.position + Duration(seconds: s);
    if (t < Duration.zero) t = Duration.zero;
    final d = player.state.duration;
    if (d > Duration.zero && t > d) t = d;
    player.seek(t);
    _osdShow('${s > 0 ? '+' : ''}${s}s    ${fmt(t)}', big: true);
  }

  void _toggleFavNow(Item it) {
    final added = Favs.toggle(it.path);
    setState(() {});
    _osdShow(added ? '★ Added to favorites' : 'Removed from favorites', ms: 1800);
  }

  void _cycleFit() {
    setState(() {
      _fit = _fit == BoxFit.contain
          ? BoxFit.cover
          : _fit == BoxFit.cover
              ? BoxFit.fill
              : BoxFit.contain;
    });
    _osdShow(_fit == BoxFit.contain ? 'Fit' : _fit == BoxFit.cover ? 'Zoom to fill' : 'Stretch', big: true);
  }

  void _toggleStats() {
    _statsT?.cancel();
    if (_stats) {
      setState(() => _stats = false);
      return;
    }
    setState(() {
      _stats = true;
      _statsTxt = 'Reading stats…';
    });
    _pollStats();
    _statsT = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
  }

  Future<void> _pollStats() async {
    if (_polling) return;
    _polling = true;
    try {
      final dynamic p = player.platform;
      Future<String> g(String k) async {
        try {
          return (await p.getProperty(k)).toString();
        } catch (_) {
          return '';
        }
      }

      final vf = await g('video-format');
      final w = await g('video-params/w');
      final h = await g('video-params/h');
      final fpsN = double.tryParse(await g('estimated-vf-fps'));
      final hw = await g('hwdec-current');
      final dd = await g('decoder-frame-drop-count');
      final vd = await g('frame-drop-count');
      final cacheN = double.tryParse(await g('demuxer-cache-duration'));
      final soft = hw.isEmpty || hw == 'no';
      final fpsTxt = fpsN == null ? '' : '  ${fpsN.toStringAsFixed(0)} fps';
      final cacheTxt = cacheN == null ? '-' : cacheN.toStringAsFixed(1);
      final t = '${vf.isEmpty ? '?' : vf.toUpperCase()}  ${w}x$h$fpsTxt\n'
          'Decoder: ${soft ? 'SOFTWARE (heavy)' : 'Hardware ($hw)'}\n'
          'Dropped: decoder ${dd.isEmpty ? '0' : dd} · display ${vd.isEmpty ? '0' : vd}\n'
          'Buffer: $cacheTxt s';
      if (mounted && _stats) setState(() => _statsTxt = t);
    } finally {
      _polling = false;
    }
  }

  void _startFast() {
    if (!mounted || _live || !_selDown || _fast) return;
    _prevRate = player.state.rate;
    player.setRate(2.0);
    _osdT?.cancel();
    setState(() {
      _fast = true;
      _osd = '⏩  2× speed';
      _osdBig = false;
    });
  }

  void _stopFast() {
    player.setRate(_prevRate);
    _osdT?.cancel();
    setState(() {
      _fast = false;
      _osd = null;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final k = e.logicalKey;
    final isOk = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter;
    // OK button: short press = controls, hold = 2x speed until released
    if (isOk && !_panel) {
      if (e is KeyDownEvent) {
        _selDown = true;
        _holdT?.cancel();
        _holdT = Timer(const Duration(milliseconds: 450), _startFast);
      } else if (e is KeyUpEvent) {
        _holdT?.cancel();
        if (_fast) {
          _stopFast();
        } else if (_selDown) {
          _showPanel();
        }
        _selDown = false;
      }
      return KeyEventResult.handled;
    }
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.mediaPlayPause) {
      player.playOrPause();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlay) {
      player.play();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPause) {
      player.pause();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaFastForward) {
      _skip(30);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaRewind) {
      _skip(-30);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext || k == LogicalKeyboardKey.channelUp) {
      player.next();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious || k == LogicalKeyboardKey.channelDown) {
      player.previous();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.contextMenu) {
      _tracks();
      return KeyEventResult.handled;
    }
    if (_panel) {
      _kick();
      return KeyEventResult.ignored; // let the remote move focus between buttons
    }
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _showPanel();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _skip(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _skip(10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_live) {
        player.next();
      } else {
        _showPanel();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (_live) {
        player.previous();
      } else {
        _showPanel();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _tl(dynamic t) {
    if (t.id == 'auto') return 'Auto';
    if (t.id == 'no') return 'Off';
    final parts = <String>[
      if ((t.title as String?)?.isNotEmpty ?? false) t.title as String,
      if ((t.language as String?)?.isNotEmpty ?? false) t.language as String,
    ];
    return parts.isEmpty ? 'Track ${t.id}' : parts.join(' · ');
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      );

  Widget _opt(String t, bool sel, VoidCallback f) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(t),
        trailing: sel ? const Icon(Icons.check_rounded) : null,
        onTap: f,
      );

  Future<void> _tracks() async {
    _hide?.cancel();
    await showDialog(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: Colors.transparent,
        child: Glass(
          radius: 28,
          padding: const EdgeInsets.all(22),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 520, maxHeight: MediaQuery.of(c).size.height * 0.85),
            child: StreamBuilder<Track>(
              stream: player.stream.track,
              initialData: player.state.track,
              builder: (c, ts) {
                final tr = player.state.tracks;
                final cur = ts.data ?? player.state.track;
                return ListView(shrinkWrap: true, children: [
                  _h('Speed'),
                  StreamBuilder<double>(
                    stream: player.stream.rate,
                    initialData: player.state.rate,
                    builder: (c, rs) => Wrap(spacing: 8, children: [
                      for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                        ChoiceChip(
                          autofocus: r == 1.0,
                          label: Text('${r}x'),
                          selected: rs.data == r,
                          onSelected: (_) => player.setRate(r),
                        ),
                    ]),
                  ),
                  _h('Audio track'),
                  for (final t in tr.audio) _opt(_tl(t), cur.audio.id == t.id, () => player.setAudioTrack(t)),
                  _h('Subtitles'),
                  for (final t in tr.subtitle)
                    _opt(_tl(t), cur.subtitle.id == t.id, () => player.setSubtitleTrack(t)),
                  _h('Diagnostics'),
                  _opt(_stats ? 'Hide playback stats' : 'Show playback stats', _stats, () {
                    Navigator.pop(c);
                    _toggleStats();
                  }),
                ]);
              },
            ),
          ),
        ),
      ),
    );
    if (mounted && _panel) _kick();
  }

  Widget _pb(IconData i, VoidCallback f, {FocusNode? node, double size = 30}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: TvButton(
          focusNode: node,
          radius: 40,
          padding: const EdgeInsets.all(14),
          onTap: () {
            f();
            _kick();
          },
          child: Icon(i, size: size, color: Colors.white),
        ),
      );

  Widget _panelUi(Item item) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 26),
        child: Glass(
          scrim: true,
          radius: 32,
          padding: const EdgeInsets.fromLTRB(26, 16, 26, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              if (item.live)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: Icon(Icons.circle, size: 12, color: Colors.redAccent),
                ),
              Expanded(
                child: Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              ),
              if (item.live) const Text('LIVE', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5)),
            ]),
            if (!item.live)
              StreamBuilder<Duration>(
                stream: _pos,
                initialData: player.state.position,
                builder: (c, ps) => StreamBuilder<Duration>(
                  stream: player.stream.duration,
                  initialData: player.state.duration,
                  builder: (c, ds) {
                    final pos = ps.data ?? Duration.zero;
                    final dur = ds.data ?? Duration.zero;
                    final v = dur.inMilliseconds <= 0
                        ? 0.0
                        : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0).toDouble();
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Text(fmt(pos), style: const TextStyle(fontSize: 13)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: v,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(4),
                            backgroundColor: Colors.white24,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(fmt(dur), style: const TextStyle(fontSize: 13)),
                      ]),
                    );
                  },
                ),
              )
            else
              const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _pb(Icons.skip_previous_rounded, () => player.previous(), size: 32),
              if (!item.live) _pb(Icons.replay_10_rounded, () => _skip(-10)),
              StreamBuilder<bool>(
                stream: player.stream.playing,
                initialData: player.state.playing,
                builder: (c, s) => _pb(
                  s.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  () => player.playOrPause(),
                  node: _playNode,
                  size: 38,
                ),
              ),
              if (!item.live) _pb(Icons.forward_10_rounded, () => _skip(10)),
              _pb(Icons.skip_next_rounded, () => player.next(), size: 32),
              if (item.live)
                _pb(Favs.has(item.path) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    () => _toggleFavNow(item)),
              _pb(Icons.tune_rounded, _tracks),
              if (!item.audio) _pb(Icons.aspect_ratio_rounded, _cycleFit),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _audio || !_panel,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _panel) _hidePanel();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: !_panel,
          focusNode: _root,
          onKeyEvent: _onKey,
          child: ValueListenableBuilder<Item?>(
            valueListenable: Engine.current,
            builder: (c, item, _) {
              if (item == null) {
                if (!_closing) {
                  _closing = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) Navigator.of(context).pop();
                  });
                }
                return const ColoredBox(color: Colors.black);
              }
              return Stack(fit: StackFit.expand, children: [
                if (_audio)
                  const GlassBackground()
                else
                  Video(
                    controller: videoController,
                    controls: NoVideoControls,
                    fit: _fit,
                    fill: Colors.black,
                    subtitleViewConfiguration: const SubtitleViewConfiguration(
                      style: TextStyle(
                        fontSize: 30,
                        color: Colors.white,
                        backgroundColor: Color(0x99000000),
                      ),
                      padding: EdgeInsets.fromLTRB(24, 0, 24, 48),
                    ),
                  ),
                if (_audio)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 150),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Glass(
                          radius: 90,
                          child: SizedBox(
                            width: 180,
                            height: 180,
                            child: Icon(Icons.music_note_rounded, size: 90, color: Colors.white),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 60),
                          child: Text(item.title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                        ),
                      ]),
                    ),
                  ),
                IgnorePointer(
                  child: StreamBuilder<bool>(
                    stream: player.stream.buffering,
                    initialData: player.state.buffering,
                    builder: (c, s) => s.data == true
                        ? const Center(child: CircularProgressIndicator())
                        : const SizedBox.shrink(),
                  ),
                ),
                if (_osd != null)
                  IgnorePointer(
                    child: Align(
                      alignment: _osdBig ? Alignment.center : Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(40, 30, 40, 30),
                        child: Glass(
                          scrim: true,
                          radius: 22,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          child: Text(_osd!,
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                  ),
                if (_stats)
                  IgnorePointer(
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(40, 30, 40, 30),
                        child: Glass(
                          scrim: true,
                          radius: 18,
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          child: Text(_statsTxt,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.4)),
                        ),
                      ),
                    ),
                  ),
                if (_panel) _panelUi(item),
              ]);
            },
          ),
        ),
      ),
    );
  }
}
