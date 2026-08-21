import 'dart:convert';
import 'dart:typed_data';

class YoutubeCookieValidation {
  const YoutubeCookieValidation._({
    required this.isValid,
    this.errorMessage,
    this.cookieCount = 0,
    this.domains = const {},
  });

  const YoutubeCookieValidation.valid({required int cookieCount, required Set<String> domains})
    : this._(isValid: true, cookieCount: cookieCount, domains: domains);

  const YoutubeCookieValidation.invalid(String message) : this._(isValid: false, errorMessage: message);

  final bool isValid;
  final String? errorMessage;
  final int cookieCount;
  final Set<String> domains;
}

class YoutubeCookieValidator {
  const YoutubeCookieValidator._();

  static const maxBytes = 1024 * 1024;
  static const _headers = {'# HTTP Cookie File', '# Netscape HTTP Cookie File'};
  static const _sapisidCookieNames = {'SAPISID', '__Secure-1PAPISID', '__Secure-3PAPISID'};
  static const signedOutMessage =
      'This export does not contain a signed-in YouTube session. Confirm your profile avatar is visible in the private tab, reload youtube.com/robots.txt, then export Current Site again.';

  static YoutubeCookieValidation validateBytes(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return const YoutubeCookieValidation.invalid('This file is empty.');
    }
    if (bytes.length > maxBytes) {
      return const YoutubeCookieValidation.invalid('This cookie file is too large. Do not export ALL sites.');
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return const YoutubeCookieValidation.invalid(
        'Choose the Netscape cookies.txt file downloaded by the Firefox add-on.',
      );
    }
    if (text.startsWith('\ufeff')) text = text.substring(1);
    return validateText(text);
  }

  static YoutubeCookieValidation validateText(String text) {
    if (utf8.encode(text).length > maxBytes) {
      return const YoutubeCookieValidation.invalid('This cookie file is too large. Do not export ALL sites.');
    }
    if (text.startsWith('\ufeff')) text = text.substring(1);
    final lines = const LineSplitter().convert(text);
    final firstNonEmpty = lines.where((line) => line.trim().isNotEmpty).firstOrNull;
    if (firstNonEmpty == null) return const YoutubeCookieValidation.invalid('This file is empty.');
    if (!_headers.contains(firstNonEmpty.trim())) {
      return const YoutubeCookieValidation.invalid(
        'Choose the Netscape cookies.txt file downloaded by the Firefox add-on.',
      );
    }

    var count = 0;
    var hasYoutube = false;
    var hasLoginInfo = false;
    var hasSapisid = false;
    final domains = <String>{};
    for (final original in lines.skipWhile((line) => line != firstNonEmpty).skip(1)) {
      if (original.trim().isEmpty) continue;
      var line = original;
      if (line.startsWith('#HttpOnly_')) {
        line = line.substring('#HttpOnly_'.length);
      } else if (line.startsWith('#')) {
        continue;
      }
      final fields = line.split('\t');
      if (fields.length != 7 ||
          !_validFlag(fields[1]) ||
          fields[2].isEmpty ||
          !_validFlag(fields[3]) ||
          int.tryParse(fields[4]) == null ||
          fields[5].isEmpty) {
        return const YoutubeCookieValidation.invalid(
          'Choose the Netscape cookies.txt file downloaded by the Firefox add-on.',
        );
      }
      final domain = fields[0].trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '');
      if (domain.isEmpty) {
        return const YoutubeCookieValidation.invalid(
          'Choose the Netscape cookies.txt file downloaded by the Firefox add-on.',
        );
      }
      domains.add(domain);
      hasYoutube |= domain == 'youtube.com' || domain.endsWith('.youtube.com');
      if (domain == 'youtube.com' || domain.endsWith('.youtube.com')) {
        hasLoginInfo |= fields[5] == 'LOGIN_INFO';
        hasSapisid |= _sapisidCookieNames.contains(fields[5]);
      }
      count++;
    }
    if (!hasYoutube) {
      return const YoutubeCookieValidation.invalid(
        'This file does not contain YouTube cookies. Export Current Site while youtube.com/robots.txt is open.',
      );
    }
    if (!hasLoginInfo || !hasSapisid) {
      return const YoutubeCookieValidation.invalid(signedOutMessage);
    }
    return YoutubeCookieValidation.valid(cookieCount: count, domains: Set.unmodifiable(domains));
  }

  static bool _validFlag(String value) => value == 'TRUE' || value == 'FALSE';
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
