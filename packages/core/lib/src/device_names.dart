// packages/core/lib/src/device_names.dart
import 'dart:math';

/// Random, friendly device names in the user's language.
///
/// Theme "light + place" (Amber Lighthouse, 琥珀灯塔): fits a photo app, is
/// easy to say aloud ("send it to Amber Lighthouse"), and stays neutral across
/// cultures — no animals, food, religion or numbers, nothing with an unlucky
/// meaning or homophone. Each language composes the two parts its own way so
/// the result is grammatical (no gender/case agreement needed).
class DeviceNames {
  DeviceNames._();

  static final Random _rng = Random();

  /// A new name in [language] (falls back to English).
  static String random(String language, {Random? rng}) {
    final r = rng ?? _rng;
    final set = _sets[language] ?? _sets['en']!;
    final a = set.first[r.nextInt(set.first.length)];
    final b = set.second[r.nextInt(set.second.length)];
    return set.compose(a, b);
  }

  static final Map<String, _NameSet> _sets = {
    'en': _NameSet(
      ['Amber', 'Misty', 'Golden', 'Quiet', 'Starlit', 'Silver', 'Morning', 'Coral'],
      ['Harbor', 'Lighthouse', 'Meadow', 'Valley', 'Island', 'Garden', 'Studio', 'Cove'],
      (a, b) => '$a $b',
    ),
    'zh': _NameSet(
      ['琥珀', '晨光', '星河', '月影', '青岚', '暖阳', '雾岛', '银杏'],
      ['灯塔', '港湾', '山谷', '花园', '小岛', '湖畔', '画室', '林间'],
      (a, b) => '$a$b',
    ),
    'zh_Hant': _NameSet(
      ['琥珀', '晨光', '星河', '月影', '青嵐', '暖陽', '霧島', '銀杏'],
      ['燈塔', '港灣', '山谷', '花園', '小島', '湖畔', '畫室', '林間'],
      (a, b) => '$a$b',
    ),
    'ja': _NameSet(
      ['琥珀', '朝霧', '星空', '月影', '若葉', '夕凪', '銀河', '陽だまり'],
      ['灯台', '港', '草原', '谷', '小島', '庭', 'アトリエ', '入り江'],
      (a, b) => '$aの$b',
    ),
    'ko': _NameSet(
      ['달빛', '새벽', '별빛', '노을', '안개', '은빛', '햇살', '호박빛'],
      ['항구', '정원', '언덕', '등대', '호수', '숲', '섬', '작업실'],
      (a, b) => '$a $b',
    ),
    'es': _NameSet(
      ['Faro', 'Bahía', 'Prado', 'Valle', 'Isla', 'Jardín', 'Estudio', 'Cala'],
      ['Ámbar', 'Luna', 'Niebla', 'Plata', 'Alba', 'Coral', 'Estrellas', 'Oro'],
      (a, b) => '$a de $b',
    ),
    'pt': _NameSet(
      ['Farol', 'Baía', 'Prado', 'Vale', 'Ilha', 'Jardim', 'Estúdio', 'Enseada'],
      ['Âmbar', 'Lua', 'Névoa', 'Prata', 'Aurora', 'Coral', 'Estrelas', 'Ouro'],
      (a, b) => '$a de $b',
    ),
    'it': _NameSet(
      ['Faro', 'Baia', 'Prato', 'Valle', 'Isola', 'Giardino', 'Studio', 'Cala'],
      ['Ambra', 'Luna', 'Nebbia', 'Argento', 'Aurora', 'Corallo', 'Stelle', 'Oro'],
      (a, b) => '$a di $b',
    ),
    'fr': _NameSet(
      ['Phare', 'Baie', 'Prairie', 'Vallée', 'Île', 'Jardin', 'Atelier', 'Crique'],
      ['Ambre', 'Lune', 'Brume', 'Argent', 'Aurore', 'Corail', 'Étoiles', 'Or'],
      (a, b) => RegExp(r'^[AEIOUÉÈÊaeiouéèê]').hasMatch(b) ? '$a d’$b' : '$a de $b',
    ),
    // German compounds: prefix + lowercase noun (Bernsteinbucht).
    'de': _NameSet(
      ['Bernstein', 'Morgen', 'Sternen', 'Nebel', 'Gold', 'Mond', 'Silber', 'Sommer'],
      ['bucht', 'hafen', 'wiese', 'tal', 'insel', 'garten', 'atelier', 'leuchtturm'],
      (a, b) => '$a$b',
    ),
    // Russian: noun + genitive noun (Маяк рассвета) — no adjective agreement.
    'ru': _NameSet(
      ['Маяк', 'Залив', 'Луг', 'Сад', 'Остров', 'Берег', 'Причал', 'Холм'],
      ['рассвета', 'луны', 'янтаря', 'тумана', 'звёзд', 'заката', 'серебра', 'лета'],
      (a, b) => '$a $b',
    ),
    // Arabic iḍāfa: indefinite noun + definite noun (منارة الفجر).
    'ar': _NameSet(
      ['منارة', 'خليج', 'مرج', 'وادي', 'جزيرة', 'حديقة', 'مرسى', 'تلة'],
      ['الفجر', 'القمر', 'الكهرمان', 'الضباب', 'النجوم', 'الغروب', 'الفضة', 'الربيع'],
      (a, b) => '$a $b',
    ),
    // Hindi: juxtaposed nouns, like place names (चाँदनी बाग़).
    'hi': _NameSet(
      ['चाँदनी', 'सुबह', 'सितारा', 'केसर', 'बादल', 'सागर', 'इंद्रधनुष', 'सूरज'],
      ['बाग़', 'घाट', 'दीप', 'घाटी', 'झील', 'टापू', 'नगर', 'वन'],
      (a, b) => '$a $b',
    ),
    'id': _NameSet(
      ['Mercusuar', 'Teluk', 'Padang', 'Lembah', 'Pulau', 'Taman', 'Studio', 'Pantai'],
      ['Senja', 'Bulan', 'Kabut', 'Perak', 'Fajar', 'Karang', 'Bintang', 'Emas'],
      (a, b) => '$a $b',
    ),
    'vi': _NameSet(
      ['Vịnh', 'Đồi', 'Hồ', 'Đảo', 'Vườn', 'Thung', 'Bến', 'Rừng'],
      ['Trăng', 'Sương', 'Sao', 'Bình Minh', 'Hoàng Hôn', 'Hổ Phách', 'Mây', 'Nắng'],
      (a, b) => '$a $b',
    ),
    'th': _NameSet(
      ['อ่าว', 'ทุ่ง', 'หุบเขา', 'เกาะ', 'สวน', 'ประภาคาร', 'ท่าเรือ', 'บึง'],
      ['จันทร์', 'ดาว', 'หมอก', 'อรุณ', 'สนธยา', 'อำพัน', 'เมฆ', 'ตะวัน'],
      (a, b) => '$a$b',
    ),
    'tr': _NameSet(
      ['Kehribar', 'Sakin', 'Altın', 'Puslu', 'Yıldızlı', 'Gümüş', 'Mavi', 'Ilık'],
      ['Fener', 'Vadi', 'Koy', 'Ada', 'Çayır', 'Tepe', 'Liman', 'Bahçe'],
      (a, b) => '$a $b',
    ),
  };
}

class _NameSet {
  const _NameSet(this.first, this.second, this.compose);

  final List<String> first;
  final List<String> second;
  final String Function(String a, String b) compose;
}

/// Icons a device can show (keys shared by both apps; each app maps them to
/// its own icon set) and the colour palette for the badge.
class DeviceLook {
  DeviceLook._();

  static const List<String> icons = [
    'desktop', 'laptop', 'home', 'work', 'sofa', 'study', 'bed', 'tv',
    'star', 'camera', 'mountain', 'sun', 'palette', 'music', 'plant', 'rocket',
  ];

  /// ARGB values that read well on the dark Darkroom background.
  static const List<int> colors = [
    0xFFFFB547, 0xFF5FD4C4, 0xFF7AA7FF, 0xFFFF8A80,
    0xFFB39DFF, 0xFF9CCC65, 0xFFFFD54F, 0xFFF48FB1,
  ];

  static String randomIcon([Random? rng]) => icons[(rng ?? Random()).nextInt(icons.length)];

  static int randomColor([Random? rng]) => colors[(rng ?? Random()).nextInt(colors.length)];
}
