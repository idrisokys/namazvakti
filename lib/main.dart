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
//  Sunucu (sabit)
// ============================================================================
const _serverUrl = 'http://192.168.1.44:8080/';

class Config {
  const Config();
  String get url => _serverUrl;
  Map<String, String> get authHeaders => const {};
  bool get allowInsecure => false;
}

const kConfig = Config();


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

  Map<String, dynamic> toJson() => {
        'name': name,
        'uri': uri.toString(),
        'key': key,
        'isDir': isDir,
      };

  factory DavItem.fromJson(Map<String, dynamic> m) => DavItem(
        m['name'] as String,
        Uri.parse(m['uri'] as String),
        m['key'] as String,
        m['isDir'] as bool,
      );
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
          'Yetkilendirme hatasi (${res.statusCode}). Sunucu kimlik dogrulama istiyor.');
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
        'SSL sertifika hatasi.');
  } on XmlException {
    throw DavError('Sunucudan gecersiz yanit alindi (WebDAV adresi dogru mu?).');
  } finally {
    client.close();
  }
}

// ============================================================================
//  Izleme listesi (kalici)
// ============================================================================
class WlFolder {
  final String id;
  String name;
  WlFolder(this.id, this.name);
}

class WlItem {
  final DavItem item;
  String? folder;
  WlItem(this.item, this.folder);
}

class AddResult {
  final int added;
  final int moved;
  const AddResult(this.added, this.moved);
}

class WatchlistStore extends ChangeNotifier {
  WatchlistStore._();
  static final WatchlistStore instance = WatchlistStore._();

  late SharedPreferences _p;
  final List<WlFolder> folders = [];
  final List<WlItem> items = [];

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString('watchlist');
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      for (final f in (m['folders'] as List? ?? [])) {
        folders.add(WlFolder(f['id'] as String, f['name'] as String));
      }
      for (final i in (m['items'] as List? ?? [])) {
        items.add(WlItem(
          DavItem.fromJson(Map<String, dynamic>.from(i as Map)),
          i['folder'] as String?,
        ));
      }
    } catch (_) {
      folders.clear();
      items.clear();
    }
  }

  Future<void> _save() async {
    await _p.setString(
      'watchlist',
      jsonEncode({
        'folders': [
          for (final f in folders) {'id': f.id, 'name': f.name},
        ],
        'items': [
          for (final i in items) {...i.item.toJson(), 'folder': i.folder},
        ],
      }),
    );
    notifyListeners();
  }

  bool contains(String key) => items.any((e) => e.item.key == key);

  List<WlItem> itemsIn(String? folder) =>
      items.where((e) => e.folder == folder).toList();

  int countIn(String id) => items.where((e) => e.folder == id).length;

  WlFolder? folderById(String? id) {
    if (id == null) return null;
    for (final f in folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  Future<WlFolder> createFolder(String name) async {
    final f = WlFolder(DateTime.now().microsecondsSinceEpoch.toString(), name);
    folders.add(f);
    await _save();
    return f;
  }

  Future<void> renameFolder(String id, String name) async {
    final f = folderById(id);
    if (f == null) return;
    f.name = name;
    await _save();
  }

  /// Klasor silinince icindeki ogeler ana listeye tasinir.
  Future<void> deleteFolder(String id) async {
    for (final i in items) {
      if (i.folder == id) i.folder = null;
    }
    folders.removeWhere((f) => f.id == id);
    await _save();
  }

  Future<AddResult> addAll(Iterable<DavItem> list, {String? folder}) async {
    var added = 0, moved = 0;
    for (final it in list) {
      final idx = items.indexWhere((e) => e.item.key == it.key);
      if (idx < 0) {
        items.add(WlItem(it, folder));
        added++;
      } else if (folder != null && items[idx].folder != folder) {
        items[idx].folder = folder;
        moved++;
      }
    }
    if (added + moved > 0) await _save();
    return AddResult(added, moved);
  }

  Future<void> moveItem(String key, String? folder) async {
    final idx = items.indexWhere((e) => e.item.key == key);
    if (idx < 0) return;
    items[idx].folder = folder;
    await _save();
  }

  Future<void> removeItem(String key) async {
    items.removeWhere((e) => e.item.key == key);
    await _save();
  }
}

// ============================================================================
//  Ortak diyaloglar
// ============================================================================
class _NameDialog extends StatefulWidget {
  final String title;
  final String initial;
  const _NameDialog({required this.title, required this.initial});
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Klasör adı',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text.trim()),
          child: const Text('Tamam'),
        ),
      ],
    );
  }
}

Future<String?> askName(BuildContext context, String title,
    {String initial = ''}) async {
  final r = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, initial: initial),
  );
  if (r == null || r.isEmpty) return null;
  return r;
}

Future<bool> askConfirm(BuildContext context, String title, String body) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Evet'),
        ),
      ],
    ),
  );
  return r ?? false;
}

class FolderChoice {
  final String? id; // null = ana liste
  const FolderChoice(this.id);
}

Widget _optRow(IconData icon, String text, {bool current = false}) {
  return Row(
    children: [
      Icon(icon, color: Colors.amber),
      const SizedBox(width: 14),
      Expanded(child: Text(text, overflow: TextOverflow.ellipsis)),
      if (current) const Icon(Icons.check, size: 18),
    ],
  );
}

/// Klasor sec / yeni klasor olustur. Iptalde null doner.
Future<FolderChoice?> showFolderPicker(
  BuildContext context, {
  String? current,
  bool allowRoot = true,
  String title = 'Klasör seç',
}) {
  return showDialog<FolderChoice>(
    context: context,
    builder: (ctx) {
      final st = WatchlistStore.instance;
      return SimpleDialog(
        title: Text(title),
        children: [
          if (allowRoot)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, const FolderChoice(null)),
              child: _optRow(Icons.home_outlined, 'Ana liste',
                  current: current == null),
            ),
          for (final f in st.folders)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, FolderChoice(f.id)),
              child: _optRow(Icons.folder_special, f.name,
                  current: current == f.id),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final name = await askName(ctx, 'Yeni klasör');
              if (name == null) return;
              final f = await st.createFolder(name);
              if (ctx.mounted) Navigator.pop(ctx, FolderChoice(f.id));
            },
            child: _optRow(Icons.create_new_folder_outlined, 'Yeni klasör oluştur'),
          ),
        ],
      );
    },
  );
}

// ============================================================================
//  Ortak ogeler (ikonlar)
// ============================================================================
Widget statusIcon(DavItem it, {bool inWatchlist = false}) {
  if (it.isDir) {
    return Icon(inWatchlist ? Icons.folder_open : Icons.folder,
        color: Colors.lightBlueAccent, size: 28);
  }
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

String? progressText(DavItem it) {
  if (it.isDir) return null;
  final e = ProgressStore.instance.get(it.key);
  if (!e.watched && e.pos > 5 && e.dur > 0) {
    return '${fmtSec(e.pos)} / ${fmtSec(e.dur)}  •  %${(e.pos / e.dur * 100).floor()}';
  }
  if (e.watched) return 'İzlendi';
  return null;
}


// ============================================================================
//  Uygulama
// ============================================================================
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await ProgressStore.instance.init();
  await WatchlistStore.instance.init();
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
      builder: (context, child) {
        // Genis ekranlarda (Android TV / tablet) yaziyi biraz buyut
        final mq = MediaQuery.of(context);
        if (Platform.isAndroid && mq.size.width >= 900) {
          return MediaQuery(
            data: mq.copyWith(textScaler: TextScaler.linear(1.15)),
            child: child!,
          );
        }
        return child!;
      },
      home: const WatchlistScreen(),
    );
  }
}

// ============================================================================
//  Izleme listem (acilis ekrani)
// ============================================================================
class WatchlistScreen extends StatefulWidget {
  final String? folderId; // null = ana liste
  const WatchlistScreen({super.key, this.folderId});
  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  final st = WatchlistStore.instance;

  Future<void> _newFolder() async {
    final name = await askName(context, 'Yeni klasör');
    if (name != null) await st.createFolder(name);
  }

  Future<void> _openAdd() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BrowserScreen(
        start: Uri.parse(kConfig.url),
        selectMode: true,
        targetFolder: widget.folderId,
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _play(DavItem it) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(cfg: kConfig, item: it),
    ));
    if (mounted) setState(() {}); // ikonlari guncelle
  }

  Future<void> _openDir(DavItem it) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BrowserScreen(start: it.uri, selectMode: false),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _moveItem(WlItem w) async {
    final c = await showFolderPicker(
      context,
      current: w.folder,
      title: 'Klasöre taşı',
    );
    if (c == null) return;
    await st.moveItem(w.item.key, c.id);
  }

  Future<void> _renameFolder(WlFolder f) async {
    final name = await askName(context, 'Klasörü yeniden adlandır',
        initial: f.name);
    if (name != null) await st.renameFolder(f.id, name);
  }

  Future<void> _deleteFolder(WlFolder f) async {
    final ok = await askConfirm(context, 'Klasör silinsin mi?',
        '"${f.name}" silinir. İçindeki öğeler ana listeye taşınır.');
    if (ok) await st.deleteFolder(f.id);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: st,
      builder: (context, _) {
        final inRoot = widget.folderId == null;
        final folder = st.folderById(widget.folderId);
        final folders = inRoot ? st.folders : <WlFolder>[];
        final its = st.itemsIn(widget.folderId);
        final empty = folders.isEmpty && its.isEmpty;

        return Scaffold(
          appBar: AppBar(
            title: Text(inRoot ? 'İzleme Listem' : (folder?.name ?? 'Klasör')),
            actions: [
              if (inRoot)
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: 'Yeni klasör',
                  onPressed: _newFolder,
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _openAdd,
            icon: const Icon(Icons.add),
            label: const Text('Listeme ekle'),
          ),
          body: empty ? _emptyView() : _list(folders, its),
        );
      },
    );
  }

  Widget _emptyView() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_play, size: 64, color: Colors.white38),
            SizedBox(height: 12),
            Text(
              'Listen boş.\nSağ alttaki "Listeme ekle" ile sunucundan video veya klasör ekle.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(List<WlFolder> folders, List<WlItem> its) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        for (final f in folders)
          ListTile(
            leading: const SizedBox(
              width: 32,
              child: Center(
                  child: Icon(Icons.folder_special, color: Colors.amber, size: 28)),
            ),
            title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${st.countIn(f.id)} öğe'),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'rename') _renameFolder(f);
                if (v == 'delete') _deleteFolder(f);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Yeniden adlandır')),
                PopupMenuItem(value: 'delete', child: Text('Klasörü sil')),
              ],
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => WatchlistScreen(folderId: f.id),
            )),
          ),
        for (final w in its)
          ListTile(
            leading: SizedBox(
              width: 32,
              child: Center(child: statusIcon(w.item, inWatchlist: true)),
            ),
            title: Text(w.item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: progressText(w.item) == null
                ? null
                : Text(
                    progressText(w.item)!,
                    style: TextStyle(
                      color: progressText(w.item) == 'İzlendi'
                          ? null
                          : Colors.orange,
                    ),
                  ),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'move') _moveItem(w);
                if (v == 'remove') st.removeItem(w.item.key);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'move', child: Text('Klasöre taşı')),
                PopupMenuItem(value: 'remove', child: Text('Listeden çıkar')),
              ],
            ),
            onTap: () => w.item.isDir ? _openDir(w.item) : _play(w.item),
          ),
      ],
    );
  }
}

// ============================================================================
//  Sunucu gezgini (ekleme ekrani / klasor izleme)
// ============================================================================
class BrowserScreen extends StatefulWidget {
  final Uri start;
  final bool selectMode; // true: listeye ekleme ekrani
  final String? targetFolder; // ekleme hedefi (null = ana liste)
  const BrowserScreen({
    super.key,
    required this.start,
    required this.selectMode,
    this.targetFolder,
  });
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final List<Uri> stack;
  final Map<String, DavItem> selected = {};
  List<DavItem> items = [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    var u = widget.start.toString();
    if (!u.endsWith('/')) u = '$u/';
    stack = [Uri.parse(u)];
    _load();
  }

  String get _title {
    if (widget.selectMode && stack.length == 1) return 'Listeye ekle';
    final segs = stack.last.pathSegments.where((s) => s.isNotEmpty).toList();
    return segs.isEmpty ? 'Sunucu' : _decode(segs.last);
  }

  bool get _allSelected =>
      items.isNotEmpty && items.every((i) => selected.containsKey(i.key));

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await propfind(kConfig, stack.last);
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

  void _toggle(DavItem it) {
    setState(() {
      if (selected.containsKey(it.key)) {
        selected.remove(it.key);
      } else {
        selected[it.key] = it;
      }
    });
  }

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        for (final i in items) {
          selected.remove(i.key);
        }
      } else {
        for (final i in items) {
          selected[i.key] = i;
        }
      }
    });
  }

  Future<void> _addSelected({required bool pickFolder}) async {
    String? folder = widget.targetFolder;
    if (pickFolder) {
      final c = await showFolderPicker(
        context,
        current: folder,
        title: 'Hangi klasöre eklensin?',
      );
      if (c == null) return;
      folder = c.id;
    }
    final r = await WatchlistStore.instance
        .addAll(selected.values.toList(), folder: folder);
    if (!mounted) return;
    final parts = <String>[
      if (r.added > 0) '${r.added} öğe eklendi',
      if (r.moved > 0) '${r.moved} öğe klasöre taşındı',
    ];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          parts.isEmpty ? 'Seçilenler zaten listede' : parts.join(', ')),
    ));
    setState(selected.clear);
  }

  Future<void> _enter(DavItem it) async {
    stack.add(it.uri);
    await _load();
  }

  Future<void> _play(DavItem it) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(cfg: kConfig, item: it),
    ));
    if (mounted) setState(() {});
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
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (stack.length > 1) {
                _up();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
          title: Text(_title, overflow: TextOverflow.ellipsis),
          actions: [
            if (widget.selectMode && items.isNotEmpty)
              TextButton.icon(
                onPressed: _toggleAll,
                icon: Icon(_allSelected ? Icons.deselect : Icons.select_all),
                label: Text(_allSelected ? 'Seçimi kaldır' : 'Tümünü seç'),
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Yenile',
              onPressed: _load,
            ),
          ],
        ),
        body: _body(),
        bottomNavigationBar:
            widget.selectMode && selected.isNotEmpty ? _selectBar() : null,
      ),
    );
  }

  Widget _selectBar() {
    return Material(
      elevation: 8,
      color: Colors.grey.shade900,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Seçimi temizle',
                    onPressed: () => setState(selected.clear),
                  ),
                  Text('${selected.length} seçili'),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _addSelected(pickFolder: true),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Klasöre ekle'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _addSelected(pickFolder: false),
                    icon: const Icon(Icons.playlist_add),
                    label: Text(widget.targetFolder == null
                        ? 'Listeme ekle'
                        : 'Bu klasöre ekle'),
                  ),
                ],
              ),
            ],
          ),
        ),
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
      return const Center(child: Text('Video bulunamadı'));
    }
    final wl = WatchlistStore.instance;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (_, i) {
          final it = items[i];
          final inList = widget.selectMode && wl.contains(it.key);
          final prog = progressText(it);
          final sub = [
            if (inList) 'Listede',
            if (prog != null) prog,
          ].join('  •  ');
          final sel = selected.containsKey(it.key);
          return ListTile(
            selected: sel,
            selectedTileColor: Colors.white12,
            leading: SizedBox(width: 32, child: Center(child: statusIcon(it))),
            title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: sub.isEmpty
                ? null
                : Text(sub,
                    style: TextStyle(
                        color: prog != null && prog != 'İzlendi'
                            ? Colors.orange
                            : null)),
            trailing: widget.selectMode
                ? Checkbox(value: sel, onChanged: (_) => _toggle(it))
                : null,
            onTap: () {
              if (it.isDir) {
                _enter(it);
              } else if (widget.selectMode) {
                _toggle(it);
              } else {
                _play(it);
              }
            },
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
    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      player.playOrPause();
    } else if (k == LogicalKeyboardKey.mediaPlay) {
      player.play();
    } else if (k == LogicalKeyboardKey.mediaPause) {
      player.pause();
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.mediaRewind) {
      _seekBy(shift ? -60 : -10);
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(shift ? 60 : 10);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      // Masaustunde ses, TV/telefonda hiz (ses uzaktan kumandadan ayarlanir)
      if (_isMobile) {
        _changeSpeed(1);
      } else {
        _setVolume(_volume + 5);
      }
    } else if (k == LogicalKeyboardKey.arrowDown) {
      if (_isMobile) {
        _changeSpeed(-1);
      } else {
        _setVolume(_volume - 5);
      }
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
