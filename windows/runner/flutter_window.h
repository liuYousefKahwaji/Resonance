#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <memory>

#include "win32_window.h"

void LogWindowsShutdownEvent(const char* event);

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void StartExitWatchdog(const char* reason);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::PluginRegistrarWindows> media_keys_registrar_;
  std::unique_ptr<flutter::PluginRegistrarWindows>
      music_recognition_registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      shutdown_channel_;
  std::atomic<bool> exit_watchdog_started_{false};
  // Exit is the safe default until Dart reports the persisted tray mode. This
  // prevents a close during early startup from leaving an invisible process.
  bool close_to_tray_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
