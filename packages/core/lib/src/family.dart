// packages/core/lib/src/family.dart

/// A phone paired with the PC, as seen by the family group.
class FamilyDevice {
  const FamilyDevice({
    required this.id,
    required this.deviceName,
    required this.pairedMs,
    this.owner,
    this.memberOverride,
  });

  final String id;

  /// The phone's own name ("iPhone 16").
  final String deviceName;
  final int pairedMs;

  /// The person's name as typed on the phone.
  final String? owner;

  /// The member name chosen on the PC (wins over [owner]).
  final String? memberOverride;

  /// Which family member this phone belongs to.
  String get member => _clean(memberOverride) ?? _clean(owner) ?? deviceName;

  static String? _clean(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}

/// Family members = phones grouped by person. One person can have several
/// phones/tablets; they are labelled "Anna 1", "Anna 2" in pairing order.
/// No accounts: the grouping is just the name.
class FamilyDirectory {
  FamilyDirectory(Iterable<FamilyDevice> devices) {
    final sorted = devices.toList()..sort((a, b) => a.pairedMs.compareTo(b.pairedMs));
    for (final d in sorted) {
      final key = keyOf(d.member);
      // The first device's spelling names the member.
      final name = _nameOfKey.putIfAbsent(key, () {
        _members.add(d.member);
        return d.member;
      });
      _byKey.putIfAbsent(key, () => []).add(d);
      _memberOfDevice[d.id] = name;
    }
  }

  final List<String> _members = [];
  final Map<String, String> _nameOfKey = {};
  final Map<String, List<FamilyDevice>> _byKey = {};
  final Map<String, String> _memberOfDevice = {};

  /// Case- and space-insensitive, so "anna " and "Anna" are one person.
  static String keyOf(String member) => member.trim().toLowerCase();

  /// Member names, in order of their first paired device.
  List<String> get members => List.unmodifiable(_members);

  /// The member a device belongs to, or null for unknown devices.
  String? memberOf(String deviceId) => _memberOfDevice[deviceId];

  List<FamilyDevice> devicesOf(String member) => List.unmodifiable(_byKey[keyOf(member)] ?? const []);

  /// "Anna" for a person with one device, "Anna 2" for her second one.
  String? labelOf(String deviceId) {
    final m = _memberOfDevice[deviceId];
    if (m == null) return null;
    final group = _byKey[keyOf(m)]!;
    if (group.length == 1) return m;
    final i = group.indexWhere((d) => d.id == deviceId);
    return '$m ${i + 1}';
  }
}
