// apps/desktop/lib/server/port_mux.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One TCP port, two protocols: HTTPS and plain HTTP.
///
/// The first byte of a TLS connection is always 0x16 (handshake); an HTTP
/// request starts with a letter ("GET", "PUT"…). Each connection is sorted
/// on that byte and handed to [secure] or [plain] — use each as the socket
/// source of its own HttpServer (`HttpServer.listenOn`).
///
/// Why not two ports: Windows Firewall rules and the QR codes / pairings of
/// phones already in use all name one port; older phones keep working over
/// plain HTTP while updated ones switch to HTTPS on the same port.
class PortMux {
  PortMux._(this._server, this._context) {
    plain = SocketSource._(_server);
    secure = SocketSource._(_server);
    _server.listen(_accept, onError: (Object _) {}, onDone: () {
      plain._close();
      secure._close();
    });
  }

  static Future<PortMux> bind(Object address, int port, SecurityContext? context) async =>
      PortMux._(await ServerSocket.bind(address, port), context);

  final ServerSocket _server;
  final SecurityContext? _context;
  late final SocketSource plain;
  late final SocketSource secure;

  int get port => _server.port;

  Future<void> close() async {
    await _server.close();
    plain._close();
    secure._close();
  }

  void _accept(Socket s) {
    var decided = false;
    late final StreamSubscription<Uint8List> sub;
    // Nothing sent within a while: drop it (stops idle connections piling up).
    final timer = Timer(const Duration(seconds: 15), () {
      if (decided) return;
      decided = true;
      sub.cancel();
      s.destroy();
    });
    sub = s.listen(
      (data) {
        if (decided) return;
        decided = true;
        timer.cancel();
        sub.pause();
        final ctx = _context;
        if (ctx != null && data.isNotEmpty && data[0] == 0x16) {
          SecureSocket.secureServer(s, ctx, bufferedData: data).then(
            secure._add,
            onError: (Object _) => s.destroy(), // failed handshake (wrong pin on the other side…)
          );
        } else {
          plain._add(_ReplaySocket(s, sub, data));
        }
      },
      onError: (Object _) {
        if (!decided) {
          decided = true;
          timer.cancel();
          s.destroy();
        }
      },
      onDone: () {
        if (!decided) {
          decided = true;
          timer.cancel();
          s.destroy();
        }
      },
    );
  }
}

/// A stream of accepted connections that HttpServer can listen on.
class SocketSource extends Stream<Socket> implements ServerSocket {
  SocketSource._(this._server);

  final ServerSocket _server;
  final StreamController<Socket> _c = StreamController<Socket>();

  void _add(Socket s) {
    if (_c.isClosed) {
      s.destroy();
    } else {
      _c.add(s);
    }
  }

  void _close() {
    if (!_c.isClosed) _c.close();
  }

  @override
  InternetAddress get address => _server.address;

  @override
  int get port => _server.port;

  @override
  Future<ServerSocket> close() async {
    _close();
    return this;
  }

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _c.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
}

/// A plain connection whose first bytes were already read to sort it:
/// gives them back first, then the rest of the socket.
class _ReplaySocket extends Stream<Uint8List> implements Socket {
  _ReplaySocket(this._s, this._sub, this._first);

  final Socket _s;
  final StreamSubscription<Uint8List> _sub;
  final Uint8List _first;
  bool _listened = false;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listened) throw StateError('Stream has already been listened to.');
    _listened = true;
    late final StreamController<Uint8List> c;
    c = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        c.add(_first);
        _sub
          ..onData(c.add)
          ..onError(c.addError)
          ..onDone(c.close)
          ..resume();
      },
      onPause: _sub.pause,
      onResume: _sub.resume,
      onCancel: _sub.cancel,
    );
    return c.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  // Everything else goes straight to the real socket.
  @override
  Encoding get encoding => _s.encoding;
  @override
  set encoding(Encoding value) => _s.encoding = value;
  @override
  void add(List<int> data) => _s.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _s.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _s.addStream(stream);
  @override
  Future<void> close() => _s.close();
  @override
  Future<void> get done => _s.done;
  @override
  Future<void> flush() => _s.flush();
  @override
  void write(Object? object) => _s.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) => _s.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _s.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _s.writeln(object);
  @override
  InternetAddress get address => _s.address;
  @override
  int get port => _s.port;
  @override
  InternetAddress get remoteAddress => _s.remoteAddress;
  @override
  int get remotePort => _s.remotePort;
  @override
  bool setOption(SocketOption option, bool enabled) => _s.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _s.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _s.setRawOption(option);
  @override
  void destroy() => _s.destroy();
}
