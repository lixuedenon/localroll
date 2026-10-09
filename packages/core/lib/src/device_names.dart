// packages/core/lib/src/device_names.dart
import 'dart:math';

/// Random, friendly device names in the user's language: 24 × 24 = 576 per
/// language, about 9 800 across the 17 languages.
///
/// Theme "light + place" (Amber Lighthouse, 琥珀灯塔): fits a photo app, is
/// easy to say aloud ("send it to Amber Lighthouse"), and stays neutral across
/// cultures — no animals, food, religion or numbers, nothing with an unlucky
/// meaning or homophone. Each language composes the two parts its own way so
/// the result is grammatical (no gender/case agreement needed).
class DeviceNames {
  DeviceNames._();

  static final Random _rng = Random();

  /// A new name in [language] (falls back to English) that is not in
  /// [avoid] — pass the names of known devices and the names already shown,
  /// so rolling again always gives something new and no two devices clash.
  static String random(String language, {Random? rng, Set<String> avoid = const {}}) {
    final r = rng ?? _rng;
    final set = _sets[language] ?? _sets['en']!;
    var name = '';
    for (var i = 0; i < 60; i++) {
      name = set.compose(set.first[r.nextInt(set.first.length)], set.second[r.nextInt(set.second.length)]);
      if (!avoid.contains(name)) break;
    }
    return name;
  }

  /// How many different names [language] can produce (24 × 24 = 576).
  static int countFor(String language) {
    final set = _sets[language] ?? _sets['en']!;
    return set.first.length * set.second.length;
  }

  static final Map<String, _NameSet> _sets = {
    'en': _NameSet(
      ['Amber', 'Misty', 'Golden', 'Quiet', 'Starlit', 'Silver', 'Morning', 'Coral', 'Sunny', 'Gentle',
       'Bright', 'Azure', 'Velvet', 'Crystal', 'Maple', 'Cedar', 'Willow', 'Autumn', 'Summer', 'Winter',
       'Spring', 'Ivory', 'Rosy', 'Twilight'],
      ['Harbor', 'Lighthouse', 'Meadow', 'Valley', 'Island', 'Garden', 'Studio', 'Cove', 'Bay', 'Ridge',
       'Grove', 'Lagoon', 'Canyon', 'Orchard', 'Terrace', 'Pier', 'Glade', 'Summit', 'Brook', 'Shore',
       'Hill', 'Lake', 'Field', 'Forest'],
      (a, b) => '$a $b',
    ),
    'zh': _NameSet(
      ['琥珀', '晨光', '星河', '月影', '青岚', '暖阳', '雾岛', '银杏', '春风', '秋水', '云海', '松间', '竹影', '晚霞', '碧空', '彩虹', '星光',
       '山岚', '海风', '白露', '朝露', '初雪', '夏夜', '微光'],
      ['灯塔', '港湾', '山谷', '花园', '小岛', '湖畔', '画室', '林间', '码头', '草原', '溪谷', '海湾', '庭院', '书屋', '山丘', '森林', '沙滩',
       '果园', '小屋', '平原', '江畔', '原野', '峡湾', '天台'],
      (a, b) => '$a$b',
    ),
    'zh_Hant': _NameSet(
      ['琥珀', '晨光', '星河', '月影', '青嵐', '暖陽', '霧島', '銀杏', '春風', '秋水', '雲海', '松間', '竹影', '晚霞', '碧空', '彩虹', '星光',
       '山嵐', '海風', '白露', '朝露', '初雪', '夏夜', '微光'],
      ['燈塔', '港灣', '山谷', '花園', '小島', '湖畔', '畫室', '林間', '碼頭', '草原', '溪谷', '海灣', '庭院', '書屋', '山丘', '森林', '沙灘',
       '果園', '小屋', '平原', '江畔', '原野', '峽灣', '天台'],
      (a, b) => '$a$b',
    ),
    'ja': _NameSet(
      ['琥珀', '朝霧', '星空', '月影', '若葉', '夕凪', '銀河', '陽だまり', '春風', '秋空', '雲海', '松風', '竹林', '夕焼け', '青空', '虹',
       '星明かり', '山霧', '潮風', '白露', '朝露', '初雪', '夏夜', '木漏れ日'],
      ['灯台', '港', '草原', '谷', '小島', '庭', 'アトリエ', '入り江', '桟橋', '丘', '森', '湖畔', '浜辺', '果樹園', '小屋', '野原', '渓谷',
       '書斎', 'テラス', '岬', '湾', '高原', '川辺', '里'],
      (a, b) => '$aの$b',
    ),
    'ko': _NameSet(
      ['달빛', '새벽', '별빛', '노을', '안개', '은빛', '햇살', '호박빛', '봄날', '가을빛', '구름', '바람', '무지개', '하늘빛', '이슬', '첫눈',
       '여름밤', '물빛', '윤슬', '솔바람', '금빛', '초록', '산들', '아침'],
      ['항구', '정원', '언덕', '등대', '호수', '숲', '섬', '작업실', '바다', '들판', '계곡', '포구', '오두막', '과수원', '테라스', '서재',
       '해변', '골짜기', '산마루', '강가', '마을', '초원', '나루', '쉼터'],
      (a, b) => '$a $b',
    ),
    'es': _NameSet(
      ['Faro', 'Bahía', 'Prado', 'Valle', 'Isla', 'Jardín', 'Estudio', 'Cala', 'Puerto', 'Colina', 'Bosque',
       'Laguna', 'Cañón', 'Huerto', 'Terraza', 'Muelle', 'Claro', 'Cumbre', 'Arroyo', 'Orilla', 'Lago',
       'Campo', 'Mirador', 'Refugio'],
      ['Ámbar', 'Luna', 'Niebla', 'Plata', 'Alba', 'Coral', 'Estrellas', 'Oro', 'Sol', 'Brisa', 'Otoño',
       'Verano', 'Invierno', 'Primavera', 'Cristal', 'Nubes', 'Marfil', 'Rocío', 'Arena', 'Cielo', 'Mar',
       'Seda', 'Lavanda', 'Arcoíris'],
      (a, b) => '$a de $b',
    ),
    'pt': _NameSet(
      ['Farol', 'Baía', 'Prado', 'Vale', 'Ilha', 'Jardim', 'Estúdio', 'Enseada', 'Porto', 'Colina', 'Bosque',
       'Lagoa', 'Cânion', 'Pomar', 'Terraço', 'Cais', 'Clareira', 'Cume', 'Riacho', 'Margem', 'Lago',
       'Campo', 'Mirante', 'Refúgio'],
      ['Âmbar', 'Lua', 'Névoa', 'Prata', 'Aurora', 'Coral', 'Estrelas', 'Ouro', 'Sol', 'Brisa', 'Outono',
       'Verão', 'Inverno', 'Primavera', 'Cristal', 'Nuvens', 'Marfim', 'Orvalho', 'Areia', 'Céu', 'Mar',
       'Seda', 'Lavanda', 'Arco-Íris'],
      (a, b) => '$a de $b',
    ),
    'it': _NameSet(
      ['Faro', 'Baia', 'Prato', 'Valle', 'Isola', 'Giardino', 'Studio', 'Cala', 'Porto', 'Collina', 'Bosco',
       'Laguna', 'Canyon', 'Frutteto', 'Terrazza', 'Molo', 'Radura', 'Vetta', 'Ruscello', 'Riva', 'Lago',
       'Campo', 'Belvedere', 'Rifugio'],
      ['Ambra', 'Luna', 'Nebbia', 'Argento', 'Aurora', 'Corallo', 'Stelle', 'Oro', 'Sole', 'Brezza',
       'Autunno', 'Estate', 'Inverno', 'Primavera', 'Cristallo', 'Nuvole', 'Avorio', 'Rugiada', 'Sabbia',
       'Cielo', 'Mare', 'Seta', 'Lavanda', 'Arcobaleno'],
      (a, b) => RegExp(r'^[AEIOUaeiou]').hasMatch(b) ? '$a d’$b' : '$a di $b',
    ),
    'fr': _NameSet(
      ['Phare', 'Baie', 'Prairie', 'Vallée', 'Île', 'Jardin', 'Atelier', 'Crique', 'Port', 'Colline', 'Bois',
       'Lagune', 'Canyon', 'Verger', 'Terrasse', 'Quai', 'Clairière', 'Sommet', 'Ruisseau', 'Rive', 'Lac',
       'Champ', 'Belvédère', 'Refuge'],
      ['Ambre', 'Lune', 'Brume', 'Argent', 'Aurore', 'Corail', 'Étoiles', 'Or', 'Soleil', 'Brise', 'Automne',
       'Été', 'Hiver', 'Printemps', 'Cristal', 'Nuages', 'Ivoire', 'Rosée', 'Sable', 'Ciel', 'Mer', 'Soie',
       'Lavande', 'Arc-en-ciel'],
      (a, b) => RegExp(r'^[AEIOUÉÈÊaeiouéèê]').hasMatch(b) ? '$a d’$b' : '$a de $b',
    ),
    // German compounds: prefix + lowercase noun (Bernsteinbucht).
    'de': _NameSet(
      ['Bernstein', 'Morgen', 'Sternen', 'Nebel', 'Gold', 'Mond', 'Silber', 'Sommer', 'Sonnen', 'Winter',
       'Herbst', 'Frühlings', 'Abend', 'Himmels', 'Wolken', 'Kristall', 'Regenbogen', 'Lavendel', 'Seiden',
       'Linden', 'Ahorn', 'Birken', 'Meeres', 'Wind'],
      ['bucht', 'hafen', 'wiese', 'tal', 'insel', 'garten', 'atelier', 'leuchtturm', 'hain', 'ufer', 'see',
       'hügel', 'feld', 'wald', 'grund', 'steg', 'bach', 'blick', 'lichtung', 'terrasse', 'klippe', 'strand',
       'hütte', 'höhe'],
      (a, b) => '$a$b',
    ),
    // Russian: noun + genitive noun (Маяк рассвета) — no adjective agreement.
    'ru': _NameSet(
      ['Маяк', 'Залив', 'Луг', 'Сад', 'Остров', 'Берег', 'Причал', 'Холм', 'Лес', 'Бор', 'Ручей', 'Утёс',
       'Перевал', 'Порт', 'Пруд', 'Мыс', 'Каньон', 'Хутор', 'Бухта', 'Поляна', 'Долина', 'Гавань', 'Терраса',
       'Плёс'],
      ['рассвета', 'луны', 'янтаря', 'тумана', 'звёзд', 'заката', 'серебра', 'лета', 'зари', 'солнца',
       'ветра', 'осени', 'зимы', 'весны', 'хрусталя', 'облаков', 'жемчуга', 'росы', 'прибоя', 'неба', 'моря',
       'шёлка', 'лаванды', 'радуги'],
      (a, b) => '$a $b',
    ),
    // Arabic iḍāfa: indefinite noun + definite noun (منارة الفجر).
    'ar': _NameSet(
      ['منارة', 'خليج', 'مرج', 'وادي', 'جزيرة', 'حديقة', 'مرسى', 'تلة', 'غابة', 'شاطئ', 'بحيرة', 'واحة',
       'جدول', 'قمة', 'ميناء', 'بستان', 'شرفة', 'سهل', 'ضفة', 'نبع', 'رابية', 'مرفأ', 'روضة', 'هضبة'],
      ['الفجر', 'القمر', 'الكهرمان', 'الضباب', 'النجوم', 'الغروب', 'الفضة', 'الربيع', 'الشمس', 'النسيم',
       'الخريف', 'الصيف', 'الشتاء', 'البلور', 'الغيوم', 'اللؤلؤ', 'الندى', 'الرمال', 'السماء', 'البحر',
       'الحرير', 'الخزامى', 'الشفق', 'الذهب'],
      (a, b) => '$a $b',
    ),
    // Hindi: juxtaposed nouns, like place names (चाँदनी बाग़).
    'hi': _NameSet(
      ['चाँदनी', 'सुबह', 'सितारा', 'केसर', 'बादल', 'सागर', 'इंद्रधनुष', 'सूरज', 'ओस', 'बसंत', 'सावन', 'शरद',
       'किरण', 'गगन', 'पवन', 'मोती', 'चंदन', 'कमल', 'गुलमोहर', 'संध्या', 'उषा', 'नीलम', 'शबनम', 'मेघ'],
      ['बाग़', 'घाट', 'दीप', 'घाटी', 'झील', 'टापू', 'नगर', 'वन', 'किनारा', 'तट', 'पहाड़ी', 'उपवन', 'आँगन',
       'कुटी', 'मैदान', 'सरोवर', 'पठार', 'निवास', 'नीड़', 'बस्ती', 'कुंज', 'झरना', 'चौपाल', 'डेरा'],
      (a, b) => '$a $b',
    ),
    'id': _NameSet(
      ['Mercusuar', 'Teluk', 'Padang', 'Lembah', 'Pulau', 'Taman', 'Studio', 'Pantai', 'Pelabuhan', 'Bukit',
       'Hutan', 'Danau', 'Ngarai', 'Kebun', 'Teras', 'Dermaga', 'Puncak', 'Sungai', 'Tepian', 'Telaga',
       'Ladang', 'Anjungan', 'Pondok', 'Lereng'],
      ['Senja', 'Bulan', 'Kabut', 'Perak', 'Fajar', 'Karang', 'Bintang', 'Emas', 'Mentari', 'Angin',
       'Pelangi', 'Embun', 'Awan', 'Samudra', 'Permata', 'Mutiara', 'Gerimis', 'Cahaya', 'Kemuning',
       'Melati', 'Cendana', 'Sutra', 'Kristal', 'Lembayung'],
      (a, b) => '$a $b',
    ),
    'vi': _NameSet(
      ['Vịnh', 'Đồi', 'Hồ', 'Đảo', 'Vườn', 'Bến', 'Rừng', 'Bãi', 'Cảng', 'Suối', 'Đèo', 'Gò', 'Đồng', 'Thác',
       'Bờ', 'Núi', 'Làng', 'Hiên', 'Cồn', 'Phố', 'Đầm', 'Sông', 'Ghềnh', 'Trảng'],
      ['Trăng', 'Sương', 'Sao', 'Bình Minh', 'Hoàng Hôn', 'Hổ Phách', 'Mây', 'Nắng', 'Gió', 'Cầu Vồng',
       'Mùa Thu', 'Mùa Xuân', 'Ngọc', 'Bạc', 'Vàng', 'Pha Lê', 'Ban Mai', 'Mưa Bụi', 'Hoa Mai', 'Lá Phong',
       'Sóng Biển', 'Ánh Dương', 'Thiên Thanh', 'Sao Mai'],
      (a, b) => '$a $b',
    ),
    'th': _NameSet(
      ['อ่าว', 'ทุ่ง', 'หุบเขา', 'เกาะ', 'สวน', 'ประภาคาร', 'ท่าเรือ', 'บึง', 'ภู', 'ป่า', 'ลำธาร', 'หาด',
       'ผา', 'ดอย', 'ชายฝั่ง', 'ลาน', 'ทะเลสาบ', 'ระเบียง', 'เนิน', 'บ้าน', 'ริมน้ำ', 'ไร่', 'เวิ้ง', 'แหลม'],
      ['จันทร์', 'ดาว', 'หมอก', 'อรุณ', 'สนธยา', 'อำพัน', 'เมฆ', 'ตะวัน', 'สายลม', 'รุ้ง', 'น้ำค้าง', 'ฟ้า',
       'คราม', 'เงิน', 'ทอง', 'ไข่มุก', 'บุปผา', 'ใบไม้', 'ฝน', 'หิมะ', 'ทะเล', 'ประกาย', 'รุ่ง', 'ลมหนาว'],
      (a, b) => '$a$b',
    ),
    'tr': _NameSet(
      ['Kehribar', 'Sakin', 'Altın', 'Puslu', 'Yıldızlı', 'Gümüş', 'Mavi', 'Ilık', 'Serin', 'Güneşli',
       'Bulutlu', 'Yeşil', 'Mor', 'Turkuaz', 'Lacivert', 'Pembe', 'Beyaz', 'İnci', 'Kristal', 'Rüzgarlı',
       'Huzurlu', 'Parlak', 'Sedef', 'Zümrüt'],
      ['Fener', 'Vadi', 'Koy', 'Ada', 'Çayır', 'Tepe', 'Liman', 'Bahçe', 'Göl', 'Orman', 'Sahil', 'Kumsal',
       'Yamaç', 'Körfez', 'Dere', 'Ova', 'Yayla', 'Burun', 'Teras', 'İskele', 'Kanyon', 'Pınar', 'Bayır',
       'Şelale'],
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
