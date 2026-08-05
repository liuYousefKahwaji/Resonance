import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/services/track_selection_service.dart';

void main() {
  test('selection preserves playlist order and ignores invalid indices', () {
    const tracks = ['one', 'two', 'three', 'four'];

    expect(selectedTracks(tracks, {3, -1, 1, 99}), ['two', 'four']);
    expect(tracksWithoutSelection(tracks, {3, -1, 1, 99}), ['one', 'three']);
  });

  test('duplicate playlist entries remain independently selectable', () {
    const tracks = ['same', 'middle', 'same'];

    expect(selectedTracks(tracks, {2}), ['same']);
    expect(tracksWithoutSelection(tracks, {2}), ['same', 'middle']);
  });
}
