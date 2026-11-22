// apps/desktop/lib/services/backup_vault.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';
import 'package:localroll_core/localroll_core.dart' show DiagLog;

typedef _HardLinkC = Int32 Function(Pointer<Utf16> newName, Pointer<Utf16> existing, Pointer<Void> security);
typedef _HardLinkD = int Function(Pointer<Utf16> newName, Pointer<Utf16> existing, Pointer<Void> security);
typedef _VolInfoC = Int32 Function(Pointer<Utf16> root, Pointer<Utf16> name, Uint32 nameLen, Pointer<Uint32> serial,
    Pointer<Uint32> maxLen, Pointer<Uint32> flags, Pointer<Utf16> fs, Uint32 fsLen);
typedef _VolInfoD = int Function(Pointer<Utf16> root, Pointer<Utf16> name, int nameLen, Pointer<Uint32> serial,
    Pointer<Uint32> maxLen, Pointer<Uint32> flags, Pointer<Utf16> fs, int fsLen);
typedef _SetAttrC = Int32 Function(Pointer<Utf16> path, Uint32 attrs);
typedef _SetAttrD = int Function(Pointer<Utf16> path, int attrs);
typedef _CreateFileC = IntPtr Function(Pointer<Utf16> path, Uint32 access, Uint32 share, Pointer<Void> security,
    Uint32 disposition, Uint32 flags, IntPtr template);
typedef _CreateFileD = int Function(Pointer<Utf16> path, int access, int share, Pointer<Void> security, int disposition,
    int flags, int template);
typedef _FileInfoC = Int32 Function(IntPtr handle, Pointer<Uint8> info);
typedef _FileInfoD = int Function(int handle, Pointer<Uint8> info);
typedef _CloseC = Int32 Function(IntPtr handle);
typedef _CloseD = int Function(int handle);

/// A second, hidden name for every backed-up file (an NTFS hard link): the
/// same data under two names, no extra disk space. Deleting the file in
/// Explorer (even Shift+Delete, even emptying the Recycle Bin) removes only
/// its visible name — the data stays under the hidden one until Keepnear
/// is told it really should go ([purge]), and can be put back ([restore]).
///
/// The hidden folder is on the library's own drive (a hard link can't
/// cross drives): `%ProgramData%\Keepnear\vault\<id>` on the Windows drive,
/// `X:\.keepnear\vault\<id>` elsewhere; hidden + system, and its files
/// refuse deleting to everyone (an explicit deny, lifted by Keepnear only
/// for a moment when it removes them itself). Needs NTFS; elsewhere it is
/// simply off.
class BackupVault {
  BackupVault._(this.root, this.dir, this._manifest);

  /// The library folder it serves.
  final String root;

  /// The hidden folder.
  final String dir;

  final File _manifest;

  /// Library path ("2024/05/IMG_1.HEIC") → name in [dir].
  final Map<String, String> _names = {};
  Timer? _saveTimer;
  Timer? _lockTimer;
  bool _syncing = false;

  static const int _hidden = 0x2, _system = 0x4;
  static const String _everyone = '*S-1-1-0';

  /// The vault for [root], or null (not Windows, not NTFS, not writable).
  static Future<BackupVault?> open(String root, Directory dataDir) async {
    if (!Platform.isWindows) return null;
    try {
      final drive = root.length >= 2 && root[1] == ':' ? root.substring(0, 2).toUpperCase() : null;
      if (drive == null) return null;
      final fs = _fileSystem('$drive\\');
      if (fs != 'NTFS') {
        DiagLog.log('vault', 'off: the library drive is $fs, not NTFS');
        return null;
      }
      final id = crypto.sha1.convert(utf8.encode(root.toLowerCase())).toString().substring(0, 12);
      final sysDrive = (Platform.environment['SystemDrive'] ?? 'C:').toUpperCase();
      final programData = Platform.environment['ProgramData'];
      final String top;
      if (drive == sysDrive && programData != null) {
        top = '$programData\\Keepnear';
      } else {
        top = '$drive\\.keepnear';
      }
      final dir = '$top\\vault\\$id';
      await Directory(dir).create(recursive: true);
      _setAttrs(top, _hidden | _system);
      final v = BackupVault._(root, dir, File('${dataDir.path}${Platform.pathSeparator}vault_$id.json'));
      await v._load();
      return v;
    } catch (e) {
      DiagLog.log('vault', 'off: $e');
      return null;
    }
  }

  Future<void> _load() async {
    try {
      if (!await _manifest.exists()) return;
      final j = jsonDecode(await _manifest.readAsString());
      if (j is Map) {
        for (final e in j.entries) {
          if (e.key is String && e.value is String) _names[e.key as String] = e.value as String;
        }
      }
    } catch (e) {
      DiagLog.log('vault', 'list unreadable: $e');
    }
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final tmp = File('${_manifest.path}.tmp');
        await tmp.writeAsString(jsonEncode(_names));
        await tmp.rename(_manifest.path);
      } catch (e) {
        DiagLog.log('vault', 'list not saved: $e');
      }
    });
  }

  String _abs(String rel) => '$root\\${rel.replaceAll('/', '\\')}';
  String _kept(String name) => '$dir\\$name';

  /// Kept for [rel] (its data can be brought back).
  bool has(String rel) {
    final n = _names[rel];
    return n != null && File(_kept(n)).existsSync();
  }

  /// Brings the library in line: every file in [rels] gets its hidden
  /// name; hidden names whose file left the library are dropped when the
  /// data still has another name (moved, renamed, in "Recently deleted"),
  /// or when nothing else holds it and it isn't waiting for an answer
  /// ([waiting]).
  Future<void> sync(Iterable<String> rels, Set<String> waiting) async {
    if (_syncing) return;
    _syncing = true;
    try {
      final now = rels.toSet();
      // An empty or unreadable library list must never empty the vault.
      final mayDrop = now.isNotEmpty;
      var added = 0;
      for (final rel in now) {
        if (has(rel)) continue;
        final abs = _abs(rel);
        if (!File(abs).existsSync()) continue;
        final dot = rel.lastIndexOf('.');
        final ext = dot > rel.lastIndexOf('/') ? rel.substring(dot) : '';
        final name = '${crypto.sha1.convert(utf8.encode('$rel|${DateTime.now().microsecondsSinceEpoch}')).toString().substring(0, 24)}$ext';
        if (_link(_kept(name), abs)) {
          _names[rel] = name;
          added++;
        }
        // A long first run: a breath now and then.
        if (added % 200 == 199) await Future<void>.delayed(Duration.zero);
      }
      final drop = <String>[];
      var only = 0;
      for (final e in _names.entries) {
        if (!mayDrop || now.contains(e.key) || waiting.contains(e.key)) continue;
        // Gone already (0), or the data lives on elsewhere (>1: moved,
        // renamed, in "Recently deleted"), or only here and nobody waits
        // for it (1: deleted in Keepnear for good): the hidden name goes.
        if (_linkCount(_kept(e.value)) == 1) only++;
        drop.add(e.key);
      }
      // Many files held only here leaving at once: not trusted (a library
      // list gone wrong) — kept, said in the log.
      if (only > 20 && only * 3 > _names.length) {
        DiagLog.log('vault', 'not dropping $only files only kept here (the library list may be wrong)');
        drop.clear();
      }
      if (drop.isNotEmpty) await _remove(drop);
      if (added > 0) {
        DiagLog.log('vault', '$added kept');
        _lockSoon();
      }
      if (added > 0 || drop.isNotEmpty) _save();
    } finally {
      _syncing = false;
    }
  }

  /// [rels] put back in the library from their hidden names. Returns how
  /// many came back.
  int restore(Iterable<String> rels) {
    var n = 0;
    for (final rel in rels) {
      final name = _names[rel];
      if (name == null) continue;
      final abs = _abs(rel);
      if (File(abs).existsSync()) {
        n++;
        continue;
      }
      try {
        Directory(File(abs).parent.path).createSync(recursive: true);
      } catch (_) {}
      if (_link(abs, _kept(name))) n++;
    }
    DiagLog.log('vault', 'restored $n');
    return n;
  }

  /// [rels] deleted for good: their hidden names go too (the space is
  /// freed once no name is left).
  Future<void> purge(Iterable<String> rels) async {
    final list = rels.where(_names.containsKey).toList();
    if (list.isEmpty) return;
    await _remove(list);
    _save();
    DiagLog.log('vault', 'deleted for good: ${list.length}');
  }

  Future<void> _remove(List<String> rels) async {
    // The deny lifted for a moment (whole folder: one call), the names
    // removed, the rest locked again.
    await _icacls([dir, '/remove:d', _everyone, '/T', '/C', '/Q']);
    for (final rel in rels) {
      final name = _names.remove(rel);
      if (name == null) continue;
      try {
        File(_kept(name)).deleteSync();
      } catch (_) {}
    }
    _lockSoon(now: true);
  }

  void _lockSoon({bool now = false}) {
    _lockTimer?.cancel();
    _lockTimer = Timer(now ? Duration.zero : const Duration(seconds: 20), () => unawaited(_lock()));
  }

  /// Nobody may delete what is in the hidden folder (nor the folder).
  Future<void> _lock() async {
    await _icacls([dir, '/deny', '$_everyone:(OI)(CI)(DE,DC)', '/C', '/Q']);
    await _icacls(['$dir\\*', '/deny', '$_everyone:(DE)', '/C', '/Q']);
  }

  static Future<void> _icacls(List<String> args) async {
    try {
      final r = await Process.run('icacls', args, runInShell: false);
      if (r.exitCode != 0) DiagLog.log('vault', 'icacls ${args.skip(1).join(' ')}: ${r.exitCode} ${'${r.stdout}${r.stderr}'.trim()}');
    } catch (e) {
      DiagLog.log('vault', 'icacls: $e');
    }
  }

  // ------------------------------------------------------------ Windows

  static final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
  static final _HardLinkD _createHardLink = _k32.lookupFunction<_HardLinkC, _HardLinkD>('CreateHardLinkW');
  static final _VolInfoD _volInfo = _k32.lookupFunction<_VolInfoC, _VolInfoD>('GetVolumeInformationW');
  static final _SetAttrD _setAttr = _k32.lookupFunction<_SetAttrC, _SetAttrD>('SetFileAttributesW');
  static final _CreateFileD _createFile = _k32.lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
  static final _FileInfoD _fileInfo = _k32.lookupFunction<_FileInfoC, _FileInfoD>('GetFileInformationByHandle');
  static final _CloseD _close = _k32.lookupFunction<_CloseC, _CloseD>('CloseHandle');

  static bool _link(String newName, String existing) {
    final a = newName.toNativeUtf16(), b = existing.toNativeUtf16();
    try {
      return _createHardLink(a, b, nullptr) != 0;
    } finally {
      calloc.free(a);
      calloc.free(b);
    }
  }

  static String? _fileSystem(String root) {
    final r = root.toNativeUtf16();
    final fs = calloc<Uint16>(64).cast<Utf16>();
    final serial = calloc<Uint32>(), maxLen = calloc<Uint32>(), flags = calloc<Uint32>();
    try {
      if (_volInfo(r, nullptr, 0, serial, maxLen, flags, fs, 64) == 0) return null;
      return fs.toDartString();
    } finally {
      calloc.free(r);
      calloc.free(fs);
      calloc.free(serial);
      calloc.free(maxLen);
      calloc.free(flags);
    }
  }

  static void _setAttrs(String path, int attrs) {
    final p = path.toNativeUtf16();
    try {
      _setAttr(p, attrs);
    } finally {
      calloc.free(p);
    }
  }

  /// How many names the file's data has (0: not there).
  static int _linkCount(String path) {
    final p = path.toNativeUtf16();
    final info = calloc<Uint8>(52);
    const readAttributes = 0x80, shareAll = 0x7, openExisting = 3, backupSemantics = 0x02000000;
    try {
      final h = _createFile(p, readAttributes, shareAll, nullptr, openExisting, backupSemantics, 0);
      if (h == -1 || h == 0) return 0;
      try {
        if (_fileInfo(h, info) == 0) return 0;
        // BY_HANDLE_FILE_INFORMATION.nNumberOfLinks
        return info.cast<Uint32>()[10];
      } finally {
        _close(h);
      }
    } finally {
      calloc.free(p);
      calloc.free(info);
    }
  }
}
