// windows/runner/media_keys_plugin.h
//
// Native Windows media transport bridge. It publishes a System Media
// Transport Controls session for the Windows media card and Bluetooth
// headsets, and uses raw RegisterHotKey while no session is active.
//
// WHY THIS EXISTS:
// hotkey_manager_windows crashes natively when asked to register
// LogicalKeyboardKey.mediaTrackNext / mediaTrackPrevious (confirmed by
// testing - the whole Flutter Windows process dies with "Lost
// connection to device", i.e. a native crash, not a Dart exception).
// audio_service_win's SMTC integration also has a bug where its
// Next/Previous buttons only arm after a play/pause transition.
//
// This plugin keeps one transport owner without adding an audio pipeline.
// RegisterHotKey + the VK_MEDIA_* transport keys work outside an active media
// session; an SMTC button event owns active playback. WM_APPCOMMAND covers
// foreground devices when SMTC or global hotkeys are unavailable.
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
#include <shobjidl.h>
#include <winrt/Windows.Media.h>

#include <memory>
#include <optional>
#include <string>

namespace resonance {

// Hotkey IDs passed to RegisterHotKey/UnregisterHotKey. Must be unique
// per-process; arbitrary small integers are fine.
constexpr int kHotkeyIdNext = 1001;
constexpr int kHotkeyIdPrevious = 1002;
constexpr int kHotkeyIdPlayPause = 1003;
constexpr int kTaskbarButtonPrevious = 2001;
constexpr int kTaskbarButtonPlayPause = 2002;
constexpr int kTaskbarButtonNext = 2003;
constexpr UINT kSmtcButtonMessage = WM_APP + 46;

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
  bool SetupTaskbarButtons(HWND hwnd);
  bool UpdateTaskbarPlayState(bool playing);
  bool SetupSystemMediaControls(HWND hwnd);
  bool UpdateSystemMediaControls(const flutter::EncodableMap& data);

  flutter::PluginRegistrarWindows* registrar_;
  int window_proc_id_ = -1;
  bool registered_ = false;
  bool play_pause_registered_ = false;
  bool next_registered_ = false;
  bool previous_registered_ = false;
  bool registration_requested_ = false;
  bool taskbar_requested_ = false;
  bool taskbar_ready_ = false;
  bool taskbar_playing_ = false;
  UINT taskbar_button_created_message_ = 0;
  HWND last_top_level_hwnd_ = nullptr;
  HWND registered_hwnd_ = nullptr;
  ITaskbarList3* taskbar_list_ = nullptr;
  winrt::Windows::Media::SystemMediaTransportControls smtc_{nullptr};
  winrt::event_token smtc_button_token_{};
  bool smtc_active_ = false;
  std::string smtc_title_;
  std::string smtc_artist_;
  std::string smtc_artwork_;
  std::string smtc_artwork_path_;

  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
};

}  // namespace resonance

#endif  // RUNNER_MEDIA_KEYS_PLUGIN_H_
