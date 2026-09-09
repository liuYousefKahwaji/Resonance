import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/widgets/library/track_list.dart';

void main() {
  test('title matches precede artist matches and matching ignores case and whitespace', () {
    expect(trackSearchRank('  BLUE  ', 'Blue', 'Other'), 0);
    expect(trackSearchRank('blue', 'Blue Moon', 'Other'), 1);
    expect(trackSearchRank('blue', 'A Blue Moon', 'Other'), 2);
    expect(trackSearchRank('blue', 'Moon', 'Blue'), 3);
    expect(trackSearchRank('moon blue', 'Moon', 'Blue'), 4);
    expect(trackSearchRank('red', 'Moon', 'Blue'), -1);
  });
}
