import 'package:flutter/widgets.dart';

/// Use the first strong script in a lyric line. Digits and punctuation should
/// not make an Arabic or Hebrew line inherit the app's left-to-right layout.
TextDirection lyricTextDirection(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x0030 && rune <= 0x0039) ||
        (rune >= 0x0660 && rune <= 0x0669) ||
        (rune >= 0x06f0 && rune <= 0x06f9) ||
        (rune >= 0x064b && rune <= 0x065f)) {
      continue;
    }
    if ((rune >= 0x0590 && rune <= 0x08ff) ||
        (rune >= 0xfb1d && rune <= 0xfdff) ||
        (rune >= 0xfe70 && rune <= 0xfeff)) {
      return TextDirection.rtl;
    }
    if ((rune >= 0x0041 && rune <= 0x005a) ||
        (rune >= 0x0061 && rune <= 0x007a) ||
        (rune >= 0x00c0 && rune <= 0x02ff)) {
      return TextDirection.ltr;
    }
  }
  return TextDirection.ltr;
}
