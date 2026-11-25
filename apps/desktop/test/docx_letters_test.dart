// apps/desktop/test/docx_letters_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:localroll_desktop/services/docx_letters.dart';

String _box(int x, String t, {int y = 100}) =>
    '<wps:wsp><wps:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="70" cy="60"/></a:xfrm></wps:spPr>'
    '<wps:txbx><w:txbxContent><w:p><w:pPr><w:jc w:val="start"/></w:pPr><w:r><w:rPr><w:sz w:val="14"/></w:rPr><w:t>$t</w:t></w:r></w:p></w:txbxContent></wps:txbx>'
    '<wps:bodyPr lIns="0"><a:noAutofit/></wps:bodyPr></wps:wsp>';

void main() {
  test('letters of a line in one box each are joined; a far column stays apart', () {
    final g = '<wpg:wgp>${_box(0, 'A')}${_box(55, 'B')}${_box(110, 'C')}${_box(5000, '9')}</wpg:wgp>';
    final xml = '<mc:AlternateContent><mc:Choice Requires="wpg"><w:drawing>$g</w:drawing></mc:Choice><mc:Fallback><w:pict>old</w:pict></mc:Fallback></mc:AlternateContent>';
    final (out, n) = DocxLetters.mendXml(xml);
    expect(n, 2);
    expect(out.contains('<w:t xml:space="preserve">ABC</w:t>'), isTrue);
    expect(out.contains('>9</w:t>'), isTrue);
    expect(out.contains('mc:Fallback'), isFalse);
    expect(out.contains('wrap="none"><a:spAutoFit/></wps:bodyPr>'), isTrue);
  });

  test('nothing to join: unchanged', () {
    final xml = '<wpg:wgp>${_box(0, 'Hello')}${_box(5000, 'World')}</wpg:wgp>';
    final (out, n) = DocxLetters.mendXml(xml);
    expect(n, 0);
    expect(out, xml);
  });
}
