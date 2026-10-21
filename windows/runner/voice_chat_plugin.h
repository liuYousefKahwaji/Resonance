#ifndef RUNNER_VOICE_CHAT_PLUGIN_H_
#define RUNNER_VOICE_CHAT_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>
#include <flutter/method_channel.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>

namespace resonance {
class VoiceChatPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  VoiceChatPlugin();
  ~VoiceChatPlugin() override;
 private:
  void Stop();
  void Run(std::wstring microphone, std::wstring output, std::wstring monitor);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::thread worker_;
  std::atomic<bool> stop_{false}, running_{false}, monitor_{false};
  std::atomic<float> gain_{1.0f}, peak_{0.0f};
  std::atomic<uint64_t> captured_frames_{0};
  std::mutex error_mutex_;
  std::string error_;
  std::string monitor_error_;
};
}
#endif
