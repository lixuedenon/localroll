// apps/mobile/lib/services/phone_names.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:localroll_core/localroll_core.dart';

import '../l10n/l10n.dart';
import 'discovery.dart';
import 'mobile_settings.dart';

/// This phone's name, three ways (like a PC's):
///  * the phone's own name, as the system gives it (iPhone: usually just
///    "iPhone"; Android: the "Device name" in its settings) — used as is;
///  * a random one from the same pleasant words as PCs ("Amber Lighthouse"),
///    followed by "iPhone" / "Android";
///  * one the person types, also followed by "iPhone" / "Android".
/// A rename is told to every paired PC at once.
class PhoneNames {
  PhoneNames._();

  static const MethodChannel _ch = MethodChannel('localroll/files');

  /// "iPhone" / "Android".
  static String get device => Platform.isIOS ? 'iPhone' : 'Android';

  /// The phone's own name (or just [device] if the system gives none).
  static Future<String> systemName() async {
    try {
      final n = (await _ch.invokeMethod<String>('deviceName'))?.trim();
      if (n != null && n.isNotEmpty) return n.length > 40 ? n.substring(0, 40) : n;
    } catch (e) {
      DiagLog.log('pair', 'phone name not read: $e');
    }
    return device;
  }

  /// [base] followed by "iPhone" / "Android" (not twice).
  static String withDevice(String base) {
    final b = base.trim();
    if (b.isEmpty) return device;
    if (b.toLowerCase().endsWith(device.toLowerCase())) return b;
    return '$b $device';
  }

  /// [name] without the " iPhone" / " Android" at its end (to edit it).
  static String baseOf(String name) {
    final suffix = ' $device';
    return name.toLowerCase().endsWith(suffix.toLowerCase()) ? name.substring(0, name.length - suffix.length) : name;
  }

  /// A new random name ("Amber Lighthouse iPhone"), not one in [avoid].
  static String random({Set<String> avoid = const {}}) => withDevice(DeviceNames.random(
        translator.language,
        avoid: {for (final a in avoid) baseOf(a)},
      ));

  /// Renames this phone and tells every paired PC that can be reached now
  /// (the others hear it the next time they are linked).
  static Future<void> rename(MobileSettings settings, DesktopDiscovery discovery, String name) async {
    await settings.setDeviceName(name);
    await tellPcs(settings, discovery);
  }

  /// This phone's name and its person's name, to every PC reachable now.
  static Future<void> tellPcs(MobileSettings settings, DesktopDiscovery discovery) async {
    await Future.wait([
      for (final d in settings.desktops)
        () async {
          try {
            final c = await connectToDesktop(settings, d, discovered: discovery.found);
            try {
              await c.presence(
                online: true,
                session: discovery.session,
                name: settings.deviceName,
                owner: settings.ownerName.trim(),
                timeout: const Duration(seconds: 4),
              );
            } finally {
              c.close();
            }
          } catch (e) {
            DiagLog.log('pair', '${d.name}: new name not told yet: $e');
          }
        }(),
    ]);
  }

  /// First start of this version: a phone still called just "iPhone" /
  /// "Android", or given a name by beta.64 on its own, takes the phone's own
  /// name. True when the person should be told once that they can rename it.
  static Future<bool> firstStart(MobileSettings settings, DesktopDiscovery discovery) async {
    if (settings.nameSettled) return false;
    if (settings.hasPlainName || _fromBeta64(settings.deviceName)) {
      final own = await systemName();
      if (own != settings.deviceName) await rename(settings, discovery, own);
    }
    await settings.settleName();
    return true;
  }

  /// Names beta.64 gave on its own (pattern, words): such a phone gets its
  /// own name back once.
  static const List<(String, List<String>)> _beta64 = [
    ('{device} {word}', ['القمر', 'النجم', 'الغيمة', 'النسيم', 'الندى', 'الفجر', 'الواحة', 'الزيتون', 'الياسمين', 'الغزال', 'البحر', 'الوادي', 'الشفق', 'النخلة', 'الربيع', 'الضياء']),
    ('{word}-{device}', ['Morgenrot', 'Sternschnuppe', 'Bergwind', 'Kiefer', 'Lavendel', 'Seerose', 'Abendstern', 'Bergsee', 'Lerche', 'Birke', 'Sonnenblume', 'Nordlicht', 'Kirschblüte', 'Regenbogen', 'Fuchs', 'Kastanie']),
    ('{word} {device}', ['Willow', 'Maple', 'Aurora', 'Comet', 'Meadow', 'Harbor', 'Juniper', 'Sparrow', 'Cedar', 'Lotus', 'River', 'Saffron', 'Starling', 'Clover', 'Ember', 'Breeze']),
    ('{device} {word}', ['Aurora', 'Brisa', 'Lucero', 'Olivo', 'Jazmín', 'Colibrí', 'Arrecife', 'Pradera', 'Lavanda', 'Cometa', 'Girasol', 'Alba', 'Marea', 'Romero', 'Luna', 'Cedro']),
    ('{device} {word}', ['Aurore', 'Brise', 'Lavande', 'Comète', 'Prairie', 'Mésange', 'Olivier', 'Étoile', 'Coquelicot', 'Lilas', 'Rivière', 'Cerisier', 'Écume', 'Mistral', 'Lune', 'Tilleul']),
    ('{word} {device}', ['चाँदनी', 'सितारा', 'बादल', 'पवन', 'कमल', 'मोर', 'सागर', 'धूप', 'झरना', 'गुलमोहर', 'इंद्रधनुष', 'तितली', 'सुबह', 'पीपल', 'नदी', 'चमेली']),
    ('{device} {word}', ['Mentari', 'Embun', 'Pelangi', 'Melati', 'Samudra', 'Senja', 'Bintang', 'Kenari', 'Angin', 'Purnama', 'Teratai', 'Cendana', 'Fajar', 'Kejora', 'Ombak', 'Rimba']),
    ('{device} {word}', ['Aurora', 'Brezza', 'Cometa', 'Lavanda', 'Ulivo', 'Stella', 'Rondine', 'Girasole', 'Gelsomino', 'Prato', 'Marea', 'Luna', 'Alba', 'Cipresso', 'Corallo', 'Ciliegio']),
    ('{word}の{device}', ['そよ風', '夕焼け', '朝露', '星空', '若葉', '桜', '月光', '青空', '虹', '小鳥', 'ひまわり', 'こもれび', '流れ星', '海風', 'もみじ', '白雲']),
    ('{word} {device}', ['햇살', '바람', '은하수', '별빛', '구름', '새벽', '무지개', '솔잎', '파도', '달빛', '꽃잎', '이슬', '노을', '단풍', '들꽃', '하늘']),
    ('{device} {word}', ['Aurora', 'Brisa', 'Cometa', 'Oliveira', 'Jasmim', 'Beija-flor', 'Maré', 'Lavanda', 'Girassol', 'Estrela', 'Luar', 'Alecrim', 'Orvalho', 'Cerejeira', 'Prado', 'Coral']),
    ('{device} «{word}»', ['Рассвет', 'Ветерок', 'Звезда', 'Берёза', 'Ромашка', 'Комета', 'Сирень', 'Радуга', 'Ласточка', 'Луна', 'Роса', 'Кедр', 'Река', 'Сосна', 'Заря', 'Василёк']),
    ('{device} {word}', ['สายลม', 'ดวงดาว', 'ทะเล', 'ดอกบัว', 'ตะวัน', 'สายรุ้ง', 'ใบไม้', 'จันทรา', 'ฟ้าใส', 'น้ำค้าง', 'ผีเสื้อ', 'ภูเขา', 'ดอกแก้ว', 'ลำธาร', 'เมฆขาว', 'รุ่งอรุณ']),
    ('{word} {device}', ['Şafak', 'Meltem', 'Yıldız', 'Lale', 'Martı', 'Gökkuşağı', 'Ay ışığı', 'Çınar', 'Deniz', 'Papatya', 'Bulut', 'Yakamoz', 'Kartal', 'Zeytin', 'Lavanta', 'Rüzgar']),
    ('{device} {word}', ['Bình minh', 'Gió mát', 'Sao băng', 'Hoa sen', 'Trăng rằm', 'Mây trắng', 'Cầu vồng', 'Sương mai', 'Biển xanh', 'Hoa mai', 'Chim sẻ', 'Đồi thông', 'Suối nhỏ', 'Hoàng hôn', 'Lá thu', 'Nắng hạ']),
    ('{word}的{device}', ['晨光', '星河', '青竹', '远山', '海风', '白鹭', '萤火', '云朵', '松果', '麦穗', '月牙', '晴空', '春溪', '雪松', '风铃', '银杏']),
    ('{word}的{device}', ['晨光', '星河', '青竹', '遠山', '海風', '白鷺', '螢火', '雲朵', '松果', '麥穗', '月牙', '晴空', '春溪', '雪松', '風鈴', '銀杏']),
  ];

  static bool _fromBeta64(String name) {
    for (final (pattern, words) in _beta64) {
      for (final w in words) {
        for (final d in const ['iPhone', 'Android']) {
          if (pattern.replaceAll('{word}', w).replaceAll('{device}', d) == name) return true;
        }
      }
    }
    return false;
  }
}
