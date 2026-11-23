import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

// ============================================================================
//  Sabitler / yardimcilar
// ============================================================================
const _videoExt = {
  '.mkv', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v',
  '.ts', '.mpg', '.mpeg', '.m2ts', '.3gp',
};
const _watchedRatio = 0.95;
const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0];

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

String fmtDur(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

String fmtSec(double s) => fmtDur(Duration(milliseconds: (s * 1000).round()));

String _decode(String s) {
  try {
    return Uri.decodeFull(s);
  } catch (_) {
    return s;
  }
}

int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final pa = re.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final pb = re.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final x = pa[i], y = pb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

// ============================================================================
//  Ayarlar
// ============================================================================
class Config {
  String url;
  String user;
  String password;
  bool allowInsecure;

  Config({
    this.url = '',
    this.user = '',
    this.password = '',
    this.allowInsecure = false,
  });

  bool get isValid => url.isNotEmpty;

  Map<String, String> get authHeaders {
    if (user.isEmpty) return {};
    final tok = base64Encode(utf8.encode('$user:$password'));
    return {'Authorization': 'Basic $tok'};
  }

  static Future<Config> load() async {
    final p = await SharedPreferences.getInstance();
    return Config(
      url: p.getString('url') ?? '',
      user: p.getString('user') ?? '',
      password: p.getString('password') ?? '',
      allowInsecure: p.getBool('insecure') ?? false,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('url', url);
    await p.setString('user', user);
    await p.setString('password', password);
    await p.setBool('insecure', allowInsecure);
  }
}

class _InsecureOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (cert, host, port) => true;
  }
}

// ============================================================================
//  Izleme ilerlemesi
// ============================================================================
class Entry {
  final double pos;
  final double dur;
  final bool watched;
  const Entry(this.pos, this.dur, this.watched);
}

class ProgressStore {
  ProgressStore._();
  static final ProgressStore instance = ProgressStore._();

  late SharedPreferences _p;
  Map<String, dynamic> _data = {};

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString('progress');
    if (raw != null) {
      try {
        _data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        _data = {};
      }
    }
  }

  Entry get(String key) {
    final m = _data[key];
    if (m is Map) {
      return Entry(
        (m['pos'] as num?)?.toDouble() ?? 0,
        (m['dur'] as num?)?.toDouble() ?? 0,
        m['watched'] == true,
      );
    }
    return const Entry(0, 0, false);
  }

  Future<void> update(String key, double pos, double dur,
      {bool? watched}) async {
    final w = watched ?? (dur > 0 && pos / dur >= _watchedRatio);
    _data[key] = {'pos': w ? 0.0 : pos, 'dur': dur, 'watched': w};
    await _p.setString('progress', jsonEncode(_data));
  }
}

// ============================================================================
//  WebDAV
// ============================================================================
class DavItem {
  final String name;
  final Uri uri;
  final String key; // cozulmus yol - ilerleme anahtari
  final bool isDir;
  DavItem(this.name, this.uri, this.key, this.isDir);
}

class DavError implements Exception {
  final String message;
  DavError(this.message);
  @override
  String toString() => message;
}

const _propBody = '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    '<d:resourcetype/><d:getcontentlength/>'
    '</d:prop></d:propfind>';

Future<List<DavItem>> propfind(Config cfg, Uri dir) async {
  final client = http.Client();
  try {
    final req = http.Request('PROPFIND', dir)
      ..headers.addAll({
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
        ...cfg.authHeaders,
      })
      ..body = _propBody;
    final streamed =
        await client.send(req).timeout(const Duration(seconds: 30));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw DavError(
          'Yetkilendirme hatasi (${res.statusCode}). Kullanici adi / sifreyi kontrol edin.');
    }
    if (res.statusCode != 207 && res.statusCode != 200) {
      throw DavError('Sunucu hatasi: HTTP ${res.statusCode}');
    }
    final doc = XmlDocument.parse(utf8.decode(res.bodyBytes, allowMalformed: true));
    final selfPath = _decode(dir.path).replaceAll(RegExp(r'/+$'), '');
    final items = <DavItem>[];

    for (final r in doc.findAllElements('response', namespace: '*')) {
      final hrefs = r.findElements('href', namespace: '*');
      if (hrefs.isEmpty) continue;
      final href = hrefs.first.innerText.trim();
      var uri = dir.resolve(href);
      final path = _decode(uri.path);
      if (path.replaceAll(RegExp(r'/+$'), '') == selfPath) continue;

      final isDir = r.findAllElements('collection', namespace: '*').isNotEmpty;
      final segs = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty) continue;
      final name = segs.last;
      if (name.startsWith('.')) continue;

      if (!isDir) {
        final dot = name.lastIndexOf('.');
        final ext = dot >= 0 ? name.substring(dot).toLowerCase() : '';
        if (!_videoExt.contains(ext)) continue;
      } else if (!uri.path.endsWith('/')) {
        uri = uri.replace(path: '${uri.path}/');
      }
      items.add(DavItem(name, uri, path, isDir));
    }

    items.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return naturalCompare(a.name, b.name);
    });
    return items;
  } on TimeoutException {
    throw DavError('Sunucu zaman asimina ugradi.');
  } on SocketException catch (e) {
    throw DavError('Baglanti kurulamadi: ${e.message}');
  } on HandshakeException {
    throw DavError(
        'SSL sertifika hatasi. Ayarlardan "Gecersiz sertifikaya izin ver" secenegini acabilirsiniz.');
  } on XmlException {
    throw DavError('Sunucudan gecersiz yanit alindi (WebDAV adresi dogru mu?).');
  } finally {
    client.close();
  }
}

// ============================================================================
//  Uygulama
// ============================================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await ProgressStore.instance.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebDAV Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepOrange,
          brightness: Brightness.dark,
        ),
      ),
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  Config? cfg;
  int version = 0;

  @override
  void initState() {
    super.initState();
    Config.load().then((c) {
      _apply(c);
      if (mounted) setState(() => cfg = c);
    });
  }

  void _apply(Config c) {
    HttpOverrides.global = c.allowInsecure ? _InsecureOverrides() : null;
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (ctx) => SettingsScreen(
        cfg: cfg!,
        cancelable: true,
        onSaved: (c) {
          Navigator.of(ctx).pop();
          _apply(c);
          setState(() {
            cfg = c;
            version++;
          });
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = cfg;
    if (c == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!c.isValid) {
      return SettingsScreen(
        cfg: c,
        cancelable: false,
        onSaved: (n) {
          _apply(n);
          setState(() {
            cfg = n;
            version++;
          });
        },
      );
    }
    return BrowserScreen(
      key: ValueKey(version),
      cfg: c,
      onOpenSettings: _openSettings,
    );
  }
}

// ============================================================================
//  Ayarlar ekrani
// ============================================================================
class SettingsScreen extends StatefulWidget {
  final Config cfg;
  final bool cancelable;
  final void Function(Config) onSaved;
  const SettingsScreen({
    super.key,
    required this.cfg,
    required this.onSaved,
    required this.cancelable,
  });
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: widget.cfg.url);
  late final TextEditingController _user =
      TextEditingController(text: widget.cfg.user);
  late final TextEditingController _pass =
      TextEditingController(text: widget.cfg.password);
  late bool _insecure = widget.cfg.allowInsecure;
  bool _obscure = true;
  String? _err;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    var u = _url.text.trim();
    if (u.isEmpty) {
      setState(() => _err = 'Sunucu adresi gerekli');
      return;
    }
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    if (Uri.tryParse(u) == null) {
      setState(() => _err = 'Gecersiz adres');
      return;
    }
    if (!u.endsWith('/')) u = '$u/';
    final c = Config(
      url: u,
      user: _user.text.trim(),
      password: _pass.text,
      allowInsecure: _insecure,
    );
    await c.save();
    widget.onSaved(c);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV Ayarlari'),
        automaticallyImplyLeading: widget.cancelable,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Sunucu adresi',
                  hintText: 'https://sunucu.com:5006/videolar/',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _user,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Kullanici adi',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Sifre',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Gecersiz SSL sertifikasina izin ver'),
                subtitle: const Text('Kendinden imzali sertifika kullaniyorsaniz acin'),
                value: _insecure,
                onChanged: (v) => setState(() => _insecure = v),
              ),
              if (_err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_err!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: const Text('Kaydet')),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
//  Dosya gezgini
// ============================================================================
class BrowserScreen extends StatefulWidget {
  final Config cfg;
  final VoidCallback onOpenSettings;
  const BrowserScreen({
    super.key,
    required this.cfg,
    required this.onOpenSettings,
  });
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final List<Uri> stack;
  List<DavItem> items = [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    var u = widget.cfg.url;
    if (!u.endsWith('/')) u = '$u/';
    stack = [Uri.parse(u)];
    _load();
  }

  String get _title {
    final segs =
        stack.last.pathSegments.where((s) => s.isNotEmpty).toList();
    return segs.isEmpty ? 'WebDAV' : _decode(segs.last);
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await propfind(widget.cfg, stack.last);
      if (!mounted) return;
      setState(() {
        items = r;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        items = [];
        error = e.toString();
        loading = false;
      });
    }
  }

  void _up() {
    if (stack.length > 1) {
      stack.removeLast();
      _load();
    }
  }

  Future<void> _open(DavItem it) async {
    if (it.isDir) {
      stack.add(it.uri);
      _load();
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(cfg: widget.cfg, item: it),
    ));
    if (mounted) setState(() {}); // ikonlari guncelle
  }

  Widget _leading(DavItem it) {
    if (it.isDir) return const Icon(Icons.folder, color: Colors.amber, size: 28);
    final e = ProgressStore.instance.get(it.key);
    if (e.watched) {
      return const Icon(Icons.check_circle, color: Colors.green, size: 28);
    }
    if (e.pos > 5 && e.dur > 0) {
      return SizedBox(
        width: 26,
        height: 26,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: (e.pos / e.dur).clamp(0.03, 1.0),
                strokeWidth: 3.5,
                color: Colors.orange,
                backgroundColor: Colors.white24,
              ),
            ),
            const Icon(Icons.play_arrow, size: 14, color: Colors.orange),
          ],
        ),
      );
    }
    return const Icon(Icons.movie_outlined, color: Colors.white38, size: 26);
  }

  Widget? _subtitle(DavItem it) {
    if (it.isDir) return null;
    final e = ProgressStore.instance.get(it.key);
    if (!e.watched && e.pos > 5 && e.dur > 0) {
      return Text(
        '${fmtSec(e.pos)} / ${fmtSec(e.dur)}  •  %${(e.pos / e.dur * 100).floor()}',
        style: const TextStyle(color: Colors.orange),
      );
    }
    if (e.watched) return const Text('Izlendi');
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: stack.length > 1
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _up)
              : null,
          title: Text(_title, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Yenile',
                onPressed: _load),
            IconButton(
                icon: const Icon(Icons.settings),
                tooltip: 'Ayarlar',
                onPressed: widget.onOpenSettings),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text(error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Tekrar dene'),
              ),
            ],
          ),
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(child: Text('Video bulunamadi'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (_, i) {
          final it = items[i];
          return ListTile(
            leading: SizedBox(width: 32, child: Center(child: _leading(it))),
            title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: _subtitle(it),
            onTap: () => _open(it),
          );
        },
      ),
    );
  }
}

// ============================================================================
//  Oynatici
// ============================================================================
class PlayerScreen extends StatefulWidget {
  final Config cfg;
  final DavItem item;
  const PlayerScreen({super.key, required this.cfg, required this.item});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player player;
  late final VideoController controller;
  final FocusNode _focus = FocusNode();
  final List<StreamSubscription> _subs = [];
  Timer? _hideTimer;
  Timer? _saveTimer;
  bool _controlsVisible = true;
  bool _completedHandled = false;
  double? _dragMs;
  double _volume = 100;
  TapDownDetails? _dtap;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isMobile) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    player = Player(
      configuration: PlayerConfiguration(bufferSize: 64 * 1024 * 1024),
    );
    controller = VideoController(player);
    _init();
  }

  Future<void> _init() async {
    final platform = player.platform;
    if (widget.cfg.allowInsecure && platform is NativePlayer) {
      await platform.setProperty('tls-verify', 'no');
    }
    final st = ProgressStore.instance.get(widget.item.key);
    final Duration? start = (!st.watched && st.pos > 5)
        ? Duration(milliseconds: (st.pos * 1000).round())
        : null;

    _subs.add(player.stream.completed.listen((c) {
      if (c) _onCompleted();
    }));
    _subs.add(player.stream.error.listen((e) {
      if (!mounted || e.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Oynatma hatasi: $e')),
      );
    }));

    await player.open(
      Media(
        widget.item.uri.toString(),
        httpHeaders: widget.cfg.authHeaders,
        start: start,
      ),
    );
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
    _scheduleHide();
  }

  void _save() {
    if (_completedHandled) return;
    final d = player.state.duration.inMilliseconds / 1000.0;
    final p = player.state.position.inMilliseconds / 1000.0;
    if (d > 0 && p > 1) {
      ProgressStore.instance.update(widget.item.key, p, d);
    }
  }

  void _onCompleted() {
    if (_completedHandled) return;
    final d = player.state.duration.inMilliseconds / 1000.0;
    if (d > 0) {
      _completedHandled = true;
      ProgressStore.instance.update(widget.item.key, d, d, watched: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _save();
    }
  }

  @override
  void dispose() {
    _save();
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    if (_isMobile) {
      SystemChrome.setPreferredOrientations([]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    player.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---- kontrol gorunurlugu
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && player.state.playing && _dragMs == null) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  // ---- eylemler
  void _seekBy(int sec) {
    final dur = player.state.duration;
    var t = player.state.position + Duration(seconds: sec);
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    player.seek(t);
    _showControls();
  }

  void _changeSpeed(int dir) {
    final cur = player.state.rate;
    final double next = dir > 0
        ? _speeds.firstWhere((s) => s > cur + 1e-6, orElse: () => _speeds.last)
        : _speeds.lastWhere((s) => s < cur - 1e-6, orElse: () => _speeds.first);
    player.setRate(next);
    _showControls();
  }

  void _setVolume(double v) {
    final nv = v.clamp(0.0, 100.0).toDouble();
    setState(() => _volume = nv);
    player.setVolume(nv);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (k == LogicalKeyboardKey.space) {
      player.playOrPause();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(shift ? -60 : -10);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(shift ? 60 : 10);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _setVolume(_volume + 5);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _setVolume(_volume - 5);
    } else if (k == LogicalKeyboardKey.bracketRight) {
      _changeSpeed(1);
    } else if (k == LogicalKeyboardKey.bracketLeft) {
      _changeSpeed(-1);
    } else if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    } else {
      return KeyEventResult.ignored;
    }
    _showControls();
    return KeyEventResult.handled;
  }

  void _onDoubleTap() {
    final d = _dtap;
    if (d == null) return;
    final w = MediaQuery.of(context).size.width;
    _seekBy(d.localPosition.dx < w / 2 ? -10 : 10);
  }

  // ---- arayuz
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showControls(),
          cursor: _controlsVisible
              ? MouseCursor.defer
              : SystemMouseCursors.none,
          child: Stack(
            children: [
              Positioned.fill(
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  fit: BoxFit.contain,
                ),
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _isMobile ? _toggleControls : () => player.playOrPause(),
                  onDoubleTapDown: (d) => _dtap = d,
                  onDoubleTap: _onDoubleTap,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: StreamBuilder<bool>(
                      stream: player.stream.buffering,
                      initialData: player.state.buffering,
                      builder: (_, s) => (s.data ?? false)
                          ? const CircularProgressIndicator()
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControls(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Column(
      children: [
        // ust cubuk
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    widget.item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        // alt cubuk
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 4),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [_seekRow(), _buttonRow()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _seekRow() {
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: player.state.duration,
      builder: (_, ds) {
        final dur = ds.data ?? Duration.zero;
        final maxMs = dur.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (_, ps) {
            final pos = ps.data ?? Duration.zero;
            final hasDur = maxMs > 0;
            final value = (_dragMs ?? pos.inMilliseconds.toDouble())
                .clamp(0.0, hasDur ? maxMs : 1.0)
                .toDouble();
            return Row(
              children: [
                SizedBox(
                  width: 56,
                  child: Text(fmtDur(Duration(milliseconds: value.round())),
                      style: const TextStyle(color: Colors.white)),
                ),
                Expanded(
                  child: Slider(
                    value: value,
                    min: 0,
                    max: hasDur ? maxMs : 1.0,
                    onChangeStart: (_) => _hideTimer?.cancel(),
                    onChanged:
                        hasDur ? (v) => setState(() => _dragMs = v) : null,
                    onChangeEnd: (v) {
                      player.seek(Duration(milliseconds: v.round()));
                      setState(() => _dragMs = null);
                      _scheduleHide();
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(fmtDur(dur),
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buttonRow() {
    return Row(
      children: [
        IconButton(
          iconSize: 30,
          color: Colors.white,
          icon: const Icon(Icons.replay_10),
          onPressed: () => _seekBy(-10),
        ),
        StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (_, s) => IconButton(
            iconSize: 42,
            color: Colors.white,
            icon: Icon((s.data ?? false)
                ? Icons.pause_circle_filled
                : Icons.play_circle_fill),
            onPressed: () {
              player.playOrPause();
              _showControls();
            },
          ),
        ),
        IconButton(
          iconSize: 30,
          color: Colors.white,
          icon: const Icon(Icons.forward_10),
          onPressed: () => _seekBy(10),
        ),
        const Spacer(),
        // hiz
        IconButton(
          color: Colors.white,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: () => _changeSpeed(-1),
        ),
        StreamBuilder<double>(
          stream: player.stream.rate,
          initialData: player.state.rate,
          builder: (_, s) => TextButton(
            onPressed: () {
              player.setRate(1.0);
              _showControls();
            },
            child: Text('${(s.data ?? 1.0).toStringAsFixed(2)}x',
                style: const TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ),
        IconButton(
          color: Colors.white,
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () => _changeSpeed(1),
        ),
        // ses (masaustu); Android'de donanim tuslari kullanilir
        if (!_isMobile) ...[
          const SizedBox(width: 12),
          Icon(_volume == 0 ? Icons.volume_off : Icons.volume_up,
              color: Colors.white),
          SizedBox(
            width: 120,
            child: Slider(
              value: _volume,
              min: 0,
              max: 100,
              onChanged: (v) {
                _setVolume(v);
                _scheduleHide();
              },
            ),
          ),
        ],
      ],
    );
  }
}
