// windows/runner/media_keys_plugin.h
//
// A minimal native Windows plugin that registers global hotkeys for the
// hardware Media Next Track / Media Previous Track keys using the raw
// Win32 RegisterHotKey API directly.
//
// WHY THIS EXISTS:
// hotkey_manager_windows crashes natively when asked to register
// LogicalKeyboardKey.mediaTrackNext / mediaTrackPrevious (confirmed by
// testing - the whole Flutter Windows process dies with "Lost
// connection to device", i.e. a native crash, not a Dart exception).
// audio_service_win's SMTC integration also has a bug where its
// Next/Previous buttons only arm after a play/pause transition.
//
// This plugin sidesteps both issues by talking to Win32 directly:
// RegisterHotKey + VK_MEDIA_NEXT_TRACK / VK_MEDIA_PREV_TRACK work fine
// at the raw Win32 level; the bug is specific to hotkey_manager's
// wrapper, not the underlying OS API.
//
#ifndef RUNNER_MEDIA_KEYS_PLUGIN_H_
#define RUNNER_MEDIA_KEYS_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include <memory>
#include <optional>

namespace resonance {

// Hotkey IDs passed to RegisterHotKey/UnregisterHotKey. Must be unique
// per-process; arbitrary small integers are fine.
constexpr int kHotkeyIdNext = 1001;
constexpr int kHotkeyIdPrevious = 1002;

class MediaKeysPlugin : public flutter::Plugin {
 public:
  // Registers this plugin with the given registrar. `registrar` must be
  // a FlutterWindowsPluginRegistrar so we can hook into the native
  // window's message loop (needed to receive WM_HOTKEY).
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  MediaKeysPlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~MediaKeysPlugin();

  // Disallow copy and assign.
  MediaKeysPlugin(const MediaKeysPlugin&) = delete;
  MediaKeysPlugin& operator=(const MediaKeysPlugin&) = delete;

  // Called by the EventChannel stream handler when Dart starts/stops
  // listening. Public so MediaKeysStreamHandler (defined in the .cpp)
  // can call it.
  void SetEventSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
    event_sink_ = std::move(sink);
  }

 private:
  // Called by Flutter for every native window message. We only care
  // about WM_HOTKEY; everything else is passed through untouched.
  //
  // IMPORTANT: the `hwnd` parameter here is captured the FIRST time
  // this fires and used as the target for RegisterHotKey. This is
  // deliberate: RegisterHotKey posts WM_HOTKEY to the message queue
  // of the EXACT hwnd you register it against. The top-level window
  // proc delegate is invoked with the actual top-level frame HWND -
  // which may differ from registrar_->GetView()->GetNativeWindow()
  // (that can return the embedded Flutter *view* child window rather
  // than the top-level frame window). Registering against the wrong
  // HWND means RegisterHotKey "succeeds" but WM_HOTKEY is posted to a
  // message queue nothing is reading from.
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  // MethodChannel handlers (register/unregister from Dart side).
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool RegisterMediaKeys(HWND hwnd);
  void UnregisterMediaKeys();

  flutter::PluginRegistrarWindows* registrar_;
  int window_proc_id_ = -1;
  bool registered_ = false;
  bool registration_requested_ = false;
  HWND registered_hwnd_ = nullptr;

  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
};

}  // namespace resonance

#endif  // RUNNER_MEDIA_KEYS_PLUGIN_H_
