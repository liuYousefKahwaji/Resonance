import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// Unlike NativePlayer.setProperty, check the return value of mpv's setter.
class WindowsAudioFilter {
  static final _library = DynamicLibrary.open(p.join(p.dirname(Platform.resolvedExecutable), 'libmpv-2.dll'));
  static final _set = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
      >('mpv_set_property_string');

  static Future<void> apply(NativePlayer player, String filter) async {
    final handle = await player.handle;
    final result = using(
      (arena) => _set(
        Pointer<Void>.fromAddress(handle),
        'af'.toNativeUtf8(allocator: arena),
        filter.toNativeUtf8(allocator: arena),
      ),
    );
    if (result < 0) throw StateError('libmpv rejected the audio filters ($result)');
  }
}
