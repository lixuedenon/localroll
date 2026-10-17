// packages/core/lib/src/office/xml_lite.dart

/// A small XML reader for Office files: elements, attributes and text.
/// Comments, processing instructions and DOCTYPE are skipped; CDATA is
/// kept as text. Names keep their prefix ("w:p").
class XElement {
  XElement(this.name, this.attrs);

  final String name;
  final Map<String, String> attrs;
  final List<Object> children = []; // XElement or String

  /// Name without the prefix ("p" for "w:p").
  String get local {
    final i = name.indexOf(':');
    return i < 0 ? name : name.substring(i + 1);
  }

  String? attr(String n) => attrs[n];

  Iterable<XElement> get elements => children.whereType<XElement>();

  XElement? child(String n) {
    for (final c in elements) {
      if (c.name == n) return c;
    }
    return null;
  }

  Iterable<XElement> all(String n) => elements.where((c) => c.name == n);

  /// Every element below (document order).
  Iterable<XElement> descendants() sync* {
    for (final c in elements) {
      yield c;
      yield* c.descendants();
    }
  }

  Iterable<XElement> find(String n) => descendants().where((e) => e.name == n);

  /// All text below, joined.
  String get text {
    final b = StringBuffer();
    void walk(XElement e) {
      for (final c in e.children) {
        if (c is String) {
          b.write(c);
        } else if (c is XElement) {
          walk(c);
        }
      }
    }

    walk(this);
    return b.toString();
  }
}

/// Parses [s]; null if it is not XML we can read.
XElement? parseXml(String s) {
  try {
    return _Parser(s).run();
  } catch (_) {
    return null;
  }
}

class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;

  XElement? run() {
    final root = XElement('#document', const {});
    final stack = <XElement>[root];
    while (i < s.length) {
      final lt = s.indexOf('<', i);
      if (lt < 0) {
        _text(stack.last, s.substring(i));
        break;
      }
      if (lt > i) _text(stack.last, s.substring(i, lt));
      i = lt;
      if (s.startsWith('<!--', i)) {
        final e = s.indexOf('-->', i + 4);
        i = e < 0 ? s.length : e + 3;
      } else if (s.startsWith('<![CDATA[', i)) {
        final e = s.indexOf(']]>', i + 9);
        final end = e < 0 ? s.length : e;
        stack.last.children.add(s.substring(i + 9, end));
        i = e < 0 ? s.length : e + 3;
      } else if (s.startsWith('<?', i)) {
        final e = s.indexOf('?>', i + 2);
        i = e < 0 ? s.length : e + 2;
      } else if (s.startsWith('<!', i)) {
        final e = s.indexOf('>', i + 2);
        i = e < 0 ? s.length : e + 1;
      } else if (s.startsWith('</', i)) {
        final e = s.indexOf('>', i + 2);
        final name = s.substring(i + 2, e < 0 ? s.length : e).trim();
        i = e < 0 ? s.length : e + 1;
        // Close up to the matching element (forgiving with bad nesting).
        for (var k = stack.length - 1; k > 0; k--) {
          if (stack[k].name == name) {
            stack.removeRange(k, stack.length);
            break;
          }
        }
      } else {
        _open(stack);
      }
    }
    return root.elements.isEmpty ? null : root.elements.first;
  }

  void _open(List<XElement> stack) {
    i++; // <
    final nameStart = i;
    while (i < s.length && !_space(s.codeUnitAt(i)) && s[i] != '>' && s[i] != '/') {
      i++;
    }
    final el = XElement(s.substring(nameStart, i), {});
    var selfClosing = false;
    while (i < s.length) {
      while (i < s.length && _space(s.codeUnitAt(i))) {
        i++;
      }
      if (i >= s.length) break;
      if (s[i] == '>') {
        i++;
        break;
      }
      if (s.startsWith('/>', i)) {
        selfClosing = true;
        i += 2;
        break;
      }
      final an = i;
      while (i < s.length && s[i] != '=' && !_space(s.codeUnitAt(i)) && s[i] != '>' && s[i] != '/') {
        i++;
      }
      final name = s.substring(an, i);
      while (i < s.length && _space(s.codeUnitAt(i))) {
        i++;
      }
      if (i < s.length && s[i] == '=') {
        i++;
        while (i < s.length && _space(s.codeUnitAt(i))) {
          i++;
        }
        final q = s[i];
        if (q == '"' || q == "'") {
          final e = s.indexOf(q, i + 1);
          final end = e < 0 ? s.length : e;
          el.attrs[name] = unescapeXml(s.substring(i + 1, end));
          i = end + 1;
        }
      } else if (name.isEmpty) {
        i++;
      }
    }
    stack.last.children.add(el);
    if (!selfClosing) stack.add(el);
  }

  void _text(XElement to, String t) {
    if (t.isEmpty) return;
    to.children.add(unescapeXml(t));
  }

  static bool _space(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
}

/// &amp; &lt; &gt; &quot; &apos; &#n; &#xn;
String unescapeXml(String t) {
  if (!t.contains('&')) return t;
  return t.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);'), (m) {
    final v = m.group(1)!;
    switch (v) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final code = v.startsWith('#x') ? int.tryParse(v.substring(2), radix: 16) : int.tryParse(v.substring(1));
    if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(code);
  });
}
