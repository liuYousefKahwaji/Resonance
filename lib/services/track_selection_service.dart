List<int> validTrackSelectionIndices(int trackCount, Iterable<int> selectedIndices) {
  final indices = selectedIndices.where((index) => index >= 0 && index < trackCount).toSet().toList()..sort();
  return indices;
}

List<String> selectedTracks(List<String> tracks, Iterable<int> selectedIndices) =>
    validTrackSelectionIndices(tracks.length, selectedIndices).map((index) => tracks[index]).toList(growable: false);

List<String> tracksWithoutSelection(List<String> tracks, Iterable<int> selectedIndices) {
  final selected = validTrackSelectionIndices(tracks.length, selectedIndices).toSet();
  return <String>[
    for (var index = 0; index < tracks.length; index++)
      if (!selected.contains(index)) tracks[index],
  ];
}
