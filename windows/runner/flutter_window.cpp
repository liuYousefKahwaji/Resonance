#include "flutter_window.h"
#include "media_keys_plugin.h"
#include "music_recognition_plugin.h"
#include <chrono>
#include <cstdio>
#include <optional>
#include <thread>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

void LogWindowsShutdownEvent(const char* event) {
  SYSTEMTIME timestamp{};
  GetLocalTime(&timestamp);
  char line[512];
  std::snprintf(line, sizeof(line),
                "[Resonance shutdown %04d-%02d-%02dT%02d:%02d:%02d.%03d] %s\n",
                timestamp.wYear, timestamp.wMonth, timestamp.wDay,
                timestamp.wHour, timestamp.wMinute, timestamp.wSecond,
                timestamp.wMilliseconds, event);
  OutputDebugStringA(line);
  std::fputs(line, stderr);
  std::fflush(stderr);
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  shutdown_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "resonance/windows_shutdown",
          &flutter::StandardMethodCodec::GetInstance());
  shutdown_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "configure") {
          const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments != nullptr) {
            const auto mode = arguments->find(flutter::EncodableValue("closeToTray"));
            if (mode != arguments->end()) {
              if (const auto* value = std::get_if<bool>(&mode->second)) {
                close_to_tray_ = *value;
                LogWindowsShutdownEvent(close_to_tray_
                                            ? "native close mode: close-to-tray"
                                            : "native close mode: exit");
              }
            }
          }
          result->Success();
          return;
        }
        if (call.method_name() == "beginExit") {
          if (GetHandle() != nullptr) {
            ShowWindow(GetHandle(), SW_HIDE);
          }
          StartExitWatchdog("Dart requested process exit");
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  {
    FlutterDesktopPluginRegistrarRef registrar_ref =
        flutter_controller_->engine()->GetRegistrarForPlugin("MediaKeysPlugin");
    media_keys_registrar_ =
        std::make_unique<flutter::PluginRegistrarWindows>(registrar_ref);
    resonance::MediaKeysPlugin::RegisterWithRegistrar(media_keys_registrar_.get());
  }
  {
    FlutterDesktopPluginRegistrarRef registrar_ref =
        flutter_controller_->engine()->GetRegistrarForPlugin(
            "MusicRecognitionPlugin");
    music_recognition_registrar_ =
        std::make_unique<flutter::PluginRegistrarWindows>(registrar_ref);
    resonance::MusicRecognitionPlugin::RegisterWithRegistrar(
        music_recognition_registrar_.get());
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  LogWindowsShutdownEvent("FlutterWindow::OnDestroy entered");
  // Stop native capture before tearing down the engine/messenger it completes
  // method calls through.
  shutdown_channel_ = nullptr;
  music_recognition_registrar_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
  LogWindowsShutdownEvent("FlutterWindow::OnDestroy finished");
}

void FlutterWindow::StartExitWatchdog(const char* reason) {
  if (exit_watchdog_started_.exchange(true)) {
    return;
  }
  LogWindowsShutdownEvent(reason);
  // This thread is intentionally independent of the Flutter engine. If Dart,
  // an audio worker, or a plugin teardown stalls, the process still exits well
  // inside the one-second close budget.
  std::thread([]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(900));
    LogWindowsShutdownEvent("native watchdog forcing final process exit");
    TerminateProcess(GetCurrentProcess(), 0);
  }).detach();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE) {
    LogWindowsShutdownEvent("WM_CLOSE received before Flutter/plugin dispatch");
    // Hide synchronously before any plugin or Dart callback. The user never
    // waits on the main isolate to see the window close.
    ShowWindow(hwnd, SW_HIDE);
    if (close_to_tray_) {
      LogWindowsShutdownEvent("WM_CLOSE hidden immediately; retaining tray process");
    } else {
      StartExitWatchdog("WM_CLOSE armed native exit watchdog");
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
