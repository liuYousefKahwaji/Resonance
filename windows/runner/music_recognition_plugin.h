#ifndef RUNNER_MUSIC_RECOGNITION_PLUGIN_H_
#define RUNNER_MUSIC_RECOGNITION_PLUGIN_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace resonance {

// Captures either the default microphone or the default render endpoint's
// loopback stream and exposes the result as PCM16/16 kHz/mono over a method
// channel. WASAPI work happens off the Flutter platform thread; completion is
// posted to a message-only window owned by that thread.
class MusicRecognitionPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  explicit MusicRecognitionPlugin(
      flutter::PluginRegistrarWindows* registrar);
  ~MusicRecognitionPlugin() override;

  MusicRecognitionPlugin(const MusicRecognitionPlugin&) = delete;
  MusicRecognitionPlugin& operator=(const MusicRecognitionPlugin&) = delete;

 private:
  struct PendingCaptureResult {
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
    std::vector<uint8_t> pcm_bytes;
    std::string error_code;
    std::string error_message;
    bool succeeded = false;
  };

  static LRESULT CALLBACK MessageWindowProc(HWND window,
                                             UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) noexcept;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void StartCapture(
      const std::string& source,
      int64_t capture_duration_ms,
      int64_t wait_timeout_ms,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void FinishCaptureOnPlatformThread();

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  HWND message_window_ = nullptr;
  HANDLE cancel_event_ = nullptr;
  std::thread capture_thread_;
  bool capture_in_progress_ = false;

  std::mutex pending_result_mutex_;
  std::unique_ptr<PendingCaptureResult> pending_result_;
};

}  // namespace resonance

#endif  // RUNNER_MUSIC_RECOGNITION_PLUGIN_H_
