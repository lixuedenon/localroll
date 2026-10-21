// apps/desktop/lib/services/win_dialogs.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:localroll_core/localroll_core.dart';

/// "Open files" / "Choose a folder" dialogs that never freeze LocalRoll.
///
/// The usual Windows dialog runs on the app's own thread: if it gets stuck
/// on a PC (a disconnected network drive, a cloud-drive add-on in the
/// sidebar…) the whole app hangs with it. Here the same Windows dialog runs
/// on a thread of its own, so LocalRoll keeps working whatever happens to
/// the dialog. One dialog at a time.
class WinDialogs {
  WinDialogs._();

  static bool _open = false;

  /// On (beta.57): a PC's log showed the usual dialog opening and never
  /// returning — the whole app frozen for over half an hour (10-19). On a
  /// thread of its own, a stuck dialog no longer takes LocalRoll with it.
  static bool ownThread = true;

  /// Files chosen (empty: cancelled). [extensions] without dots limits what
  /// is shown (the user can still switch to "All files").
  static Future<List<String>> pickFiles({
    String? title,
    bool multiple = true,
    String? typeLabel,
    List<String>? extensions,
  }) async {
    if (!Platform.isWindows || !ownThread) {
      DiagLog.log('ui', 'file dialog opened');
      final groups = extensions == null ? const <fs.XTypeGroup>[] : [fs.XTypeGroup(label: typeLabel, extensions: extensions)];
      final List<String> r;
      if (multiple) {
        r = [for (final x in await fs.openFiles(acceptedTypeGroups: groups)) x.path];
      } else {
        final x = await fs.openFile(acceptedTypeGroups: groups);
        r = x == null ? const [] : [x.path];
      }
      DiagLog.log('ui', 'file dialog closed (${r.length} chosen)');
      return r;
    }
    final spec = extensions == null || extensions.isEmpty ? null : extensions.map((e) => '*.$e').join(';');
    return _run(folder: false, multiple: multiple, title: title, filterName: typeLabel ?? spec, filterSpec: spec);
  }

  /// A folder, or null (cancelled).
  static Future<String?> pickFolder({String? title}) async {
    if (!Platform.isWindows || !ownThread) {
      DiagLog.log('ui', 'folder dialog opened');
      final r = await fs.getDirectoryPath(confirmButtonText: title);
      DiagLog.log('ui', 'folder dialog closed');
      return r;
    }
    final r = await _run(folder: true, multiple: false, title: title, filterName: null, filterSpec: null);
    return r.isEmpty ? null : r.first;
  }

  /// Where to save a file (null: cancelled). The usual Windows dialog,
  /// logged like the others.
  static Future<String?> saveFile({required String suggestedName, String? typeLabel, List<String>? extensions}) async {
    if (Platform.isWindows && ownThread) {
      final spec = extensions == null || extensions.isEmpty ? null : extensions.map((e) => '*.$e').join(';');
      final r = await _run(
        folder: false,
        multiple: false,
        title: null,
        filterName: typeLabel ?? spec,
        filterSpec: spec,
        saveAs: suggestedName,
        defaultExt: extensions == null || extensions.isEmpty ? null : extensions.first,
      );
      return r.isEmpty ? null : r.first;
    }
    DiagLog.log('ui', 'save dialog opened');
    final groups = extensions == null ? const <fs.XTypeGroup>[] : [fs.XTypeGroup(label: typeLabel, extensions: extensions)];
    final r = await fs.getSaveLocation(suggestedName: suggestedName, acceptedTypeGroups: groups);
    DiagLog.log('ui', 'save dialog closed (${r == null ? 'cancelled' : 'chosen'})');
    return r?.path;
  }

  static Future<List<String>> _run({
    required bool folder,
    required bool multiple,
    required String? title,
    required String? filterName,
    required String? filterSpec,
    String? saveAs,
    String? defaultExt,
  }) async {
    final what = saveAs != null ? 'save' : (folder ? 'folder' : 'file');
    if (_open) {
      DiagLog.log('ui', '$what dialog already open');
      return const [];
    }
    _open = true;
    final started = DateTime.now();
    DiagLog.log('ui', '$what dialog opened (own thread)');
    try {
      final r = await Isolate.run(() => _show(folder, multiple, title, filterName, filterSpec, saveAs, defaultExt));
      DiagLog.log('ui', '$what dialog closed after '
          '${DateTime.now().difference(started).inSeconds} s (${r.length} chosen)');
      return r;
    } catch (e) {
      DiagLog.error('ui', e);
      return const [];
    } finally {
      _open = false;
    }
  }
}

// ------------------------------------------------------------ Windows (COM)
//
// IFileOpenDialog through its vtable (ShObjIdl_core.h order).

final class _Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

final class _FilterSpec extends Struct {
  external Pointer<Utf16> name;
  external Pointer<Utf16> spec;
}

Pointer<_Guid> _guid(Arena arena, String s) {
  final h = s.replaceAll('-', '');
  final g = arena<_Guid>();
  g.ref
    ..data1 = int.parse(h.substring(0, 8), radix: 16)
    ..data2 = int.parse(h.substring(8, 12), radix: 16)
    ..data3 = int.parse(h.substring(12, 16), radix: 16);
  for (var i = 0; i < 8; i++) {
    g.ref.data4[i] = int.parse(h.substring(16 + i * 2, 18 + i * 2), radix: 16);
  }
  return g;
}

/// Entry [index] of the vtable of COM object [obj].
Pointer<NativeFunction<T>> _vt<T extends Function>(Pointer<Void> obj, int index) =>
    obj.cast<Pointer<Pointer<Void>>>().value[index].cast<NativeFunction<T>>();

typedef _ReleaseN = Uint32 Function(Pointer<Void>);
typedef _ReleaseD = int Function(Pointer<Void>);
typedef _ShowN = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _ShowD = int Function(Pointer<Void>, Pointer<Void>);
typedef _SetFileTypesN = Int32 Function(Pointer<Void>, Uint32, Pointer<_FilterSpec>);
typedef _SetFileTypesD = int Function(Pointer<Void>, int, Pointer<_FilterSpec>);
typedef _SetOptionsN = Int32 Function(Pointer<Void>, Uint32);
typedef _SetOptionsD = int Function(Pointer<Void>, int);
typedef _GetU32N = Int32 Function(Pointer<Void>, Pointer<Uint32>);
typedef _GetU32D = int Function(Pointer<Void>, Pointer<Uint32>);
typedef _SetTextN = Int32 Function(Pointer<Void>, Pointer<Utf16>);
typedef _SetTextD = int Function(Pointer<Void>, Pointer<Utf16>);
typedef _GetObjN = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetObjD = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _ItemAtN = Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>);
typedef _ItemAtD = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _NameN = Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Utf16>>);
typedef _NameD = int Function(Pointer<Void>, int, Pointer<Pointer<Utf16>>);

void _release(Pointer<Void> obj) => _vt<_ReleaseN>(obj, 2).asFunction<_ReleaseD>()(obj);

void _check(int hr, String what) {
  if (hr < 0) throw Exception('$what failed (0x${hr.toUnsigned(32).toRadixString(16)})');
}

/// Runs on its own isolate (own thread): shows the dialog, returns paths.
/// [saveAs]: a "Save as" dialog with that name filled in (one path back).
List<String> _show(bool folder, bool multiple, String? title, String? filterName, String? filterSpec,
    [String? saveAs, String? defaultExt]) {
  final ole32 = DynamicLibrary.open('ole32.dll');
  final coInit = ole32.lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('CoInitializeEx');
  final coUninit = ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize');
  final coCreate = ole32.lookupFunction<
      Int32 Function(Pointer<_Guid>, Pointer<Void>, Uint32, Pointer<_Guid>, Pointer<Pointer<Void>>),
      int Function(Pointer<_Guid>, Pointer<Void>, int, Pointer<_Guid>, Pointer<Pointer<Void>>)>('CoCreateInstance');
  final coFree = ole32.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CoTaskMemFree');

  const coinitApartment = 0x2, coinitNoOle1Dde = 0x4, clsctxInproc = 0x1;
  const fosNoChangeDir = 0x8, fosPickFolders = 0x20, fosForceFileSystem = 0x40;
  const fosAllowMulti = 0x200, fosPathMustExist = 0x800, fosFileMustExist = 0x1000, fosOverwritePrompt = 0x2;
  final cancelled = 0x800704C7.toSigned(32);
  final sigdnFileSysPath = 0x80058000.toSigned(32);

  final init = coInit(nullptr, coinitApartment | coinitNoOle1Dde);
  try {
    return using((arena) {
      final pp = arena<Pointer<Void>>();
      final save = saveAs != null;
      _check(
          save
              // FileSaveDialog / IFileSaveDialog
              ? coCreate(_guid(arena, 'C0B4E2F3-BA21-4773-8DBA-335EC946EB8B'), nullptr, clsctxInproc,
                  _guid(arena, '84bccd23-5fde-4cdb-aea4-af64b83d78ab'), pp)
              // FileOpenDialog / IFileOpenDialog
              : coCreate(_guid(arena, 'DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7'), nullptr, clsctxInproc,
                  _guid(arena, 'd57c7288-d4ad-4768-be02-9d969532d960'), pp),
          'CoCreateInstance');
      final dlg = pp.value;
      try {
        final opts = arena<Uint32>();
        _check(_vt<_GetU32N>(dlg, 10).asFunction<_GetU32D>()(dlg, opts), 'GetOptions');
        var o = opts.value | fosForceFileSystem | fosNoChangeDir | fosPathMustExist;
        if (save) {
          o |= fosOverwritePrompt;
        } else if (folder) {
          o |= fosPickFolders;
        } else {
          o |= fosFileMustExist;
          if (multiple) o |= fosAllowMulti;
        }
        _check(_vt<_SetOptionsN>(dlg, 9).asFunction<_SetOptionsD>()(dlg, o), 'SetOptions');
        if (title != null && title.isNotEmpty) {
          _vt<_SetTextN>(dlg, 17).asFunction<_SetTextD>()(dlg, title.toNativeUtf16(allocator: arena));
        }
        if (!folder && filterSpec != null) {
          final specs = arena<_FilterSpec>(2);
          specs[0]
            ..name = (filterName ?? filterSpec).toNativeUtf16(allocator: arena)
            ..spec = filterSpec.toNativeUtf16(allocator: arena);
          specs[1]
            ..name = '*.*'.toNativeUtf16(allocator: arena)
            ..spec = '*.*'.toNativeUtf16(allocator: arena);
          _vt<_SetFileTypesN>(dlg, 4).asFunction<_SetFileTypesD>()(dlg, 2, specs);
        }
        if (save) {
          _vt<_SetTextN>(dlg, 15).asFunction<_SetTextD>()(dlg, saveAs!.toNativeUtf16(allocator: arena)); // SetFileName
          if (defaultExt != null) {
            _vt<_SetTextN>(dlg, 22).asFunction<_SetTextD>()(dlg, defaultExt.toNativeUtf16(allocator: arena)); // SetDefaultExtension
          }
        }
        final hr = _vt<_ShowN>(dlg, 3).asFunction<_ShowD>()(dlg, nullptr);
        if (hr == cancelled) return const <String>[];
        _check(hr, 'Show');

        if (save) {
          // GetResult: one IShellItem.
          final ip = arena<Pointer<Void>>();
          _check(_vt<_GetObjN>(dlg, 20).asFunction<_GetObjD>()(dlg, ip), 'GetResult');
          final item = ip.value;
          try {
            final name = arena<Pointer<Utf16>>();
            _check(_vt<_NameN>(item, 5).asFunction<_NameD>()(item, sigdnFileSysPath, name), 'GetDisplayName');
            final path = name.value.toDartString();
            coFree(name.value.cast());
            return [path];
          } finally {
            _release(item);
          }
        }

        final ap = arena<Pointer<Void>>();
        _check(_vt<_GetObjN>(dlg, 27).asFunction<_GetObjD>()(dlg, ap), 'GetResults');
        final items = ap.value;
        try {
          final n = arena<Uint32>();
          _check(_vt<_GetU32N>(items, 7).asFunction<_GetU32D>()(items, n), 'GetCount');
          final out = <String>[];
          for (var i = 0; i < n.value; i++) {
            final ip = arena<Pointer<Void>>();
            if (_vt<_ItemAtN>(items, 8).asFunction<_ItemAtD>()(items, i, ip) < 0) continue;
            final item = ip.value;
            try {
              final name = arena<Pointer<Utf16>>();
              if (_vt<_NameN>(item, 5).asFunction<_NameD>()(item, sigdnFileSysPath, name) >= 0) {
                out.add(name.value.toDartString());
                coFree(name.value.cast());
              }
            } finally {
              _release(item);
            }
          }
          return out;
        } finally {
          _release(items);
        }
      } finally {
        _release(dlg);
      }
    });
  } finally {
    if (init >= 0) coUninit();
  }
}
