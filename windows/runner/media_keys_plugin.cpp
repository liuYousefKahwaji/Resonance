// windows/runner/media_keys_plugin.cpp
#include "media_keys_plugin.h"

#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <string>
#include <variant>

namespace resonance {

namespace {
constexpr char kMethodChannelName[] = "resonance/media_keys";
constexpr char kEventChannelName[] = "resonance/media_keys/events";

void Log(const wchar_t* msg) {
  OutputDebugStringW(msg);
}

void LogHwnd(const wchar_t* label, HWND hwnd) {
  std::wstringstream s;
  s << L"[MediaKeysPlugin] " << label << L" = " << hwnd << L"\n";
  OutputDebugStringW(s.str().c_str());
}

void LogError(const wchar_t* label, DWORD err) {
  std::wstringstream s;
  s << L"[MediaKeysPlugin] " << label << L" FAILED, GetLastError=" << err << L"\n";
  OutputDebugStringW(s.str().c_str());
}

// Minimal StreamHandler implementation. We avoid relying on the
// StreamHandlerFunctions<T> convenience template directly, since its
// exact template signature (and even its availability) varies between
// Flutter Windows embedder versions. Implementing flutter::StreamHandler
// directly is stable across versions.
class MediaKeysStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit MediaKeysStreamHandler(MediaKeysPlugin* plugin) : plugin_(plugin) {}

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override {
    plugin_->SetEventSink(std::move(events));
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override {
    plugin_->SetEventSink(nullptr);
    return nullptr;
  }

 private:
  MediaKeysPlugin* plugin_;
};

}  // namespace

// static
void MediaKeysPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<MediaKeysPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

MediaKeysPlugin::MediaKeysPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
  method_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), kMethodChannelName, &flutter::StandardMethodCodec::GetInstance());

  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), kEventChannelName, &flutter::StandardMethodCodec::GetInstance());

  event_channel_->SetStreamHandler(std::make_unique<MediaKeysStreamHandler>(this));

  // Hook into the TOP-LEVEL window's message loop so we can see
  // WM_HOTKEY. IMPORTANT: the hwnd parameter delivered to this lambda
  // on every call is the actual top-level frame HWND that owns this
  // message loop - this is the hwnd we MUST register the hotkey
  // against, not registrar_->GetView()->GetNativeWindow() (which can
  // be the embedded Flutter view's child window, a DIFFERENT hwnd
  // with its own separate message queue that RegisterHotKey would
  // post to instead, where nothing is listening for WM_HOTKEY).
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

MediaKeysPlugin::~MediaKeysPlugin() {
  UnregisterMediaKeys();
  if (window_proc_id_ != -1) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }
}

bool MediaKeysPlugin::RegisterMediaKeys(HWND hwnd) {
  if (registered_) return true;

  LogHwnd(L"Registering against HWND", hwnd);

  if (hwnd == nullptr) {
    Log(L"[MediaKeysPlugin] ERROR: hwnd is null, cannot register\n");
    return false;
  }

  // MOD_NOREPEAT: don't fire repeatedly while the key is held down.
  // These calls talk directly to the Win32 API - no third-party plugin
  // in between - which is why this works where hotkey_manager crashed.
  bool nextOk = RegisterHotKey(hwnd, kHotkeyIdNext, MOD_NOREPEAT, VK_MEDIA_NEXT_TRACK) != 0;
  if (!nextOk) {
    LogError(L"RegisterHotKey(Next)", GetLastError());
  } else {
    Log(L"[MediaKeysPlugin] RegisterHotKey(Next) OK\n");
  }

  bool prevOk = RegisterHotKey(hwnd, kHotkeyIdPrevious, MOD_NOREPEAT, VK_MEDIA_PREV_TRACK) != 0;
  if (!prevOk) {
    LogError(L"RegisterHotKey(Previous)", GetLastError());
  } else {
    Log(L"[MediaKeysPlugin] RegisterHotKey(Previous) OK\n");
  }

  registered_ = nextOk && prevOk;

  if (registered_) {
    registered_hwnd_ = hwnd;
  } else {
    // Clean up partial registration so we don't leak a hotkey id.
    UnregisterHotKey(hwnd, kHotkeyIdNext);
    UnregisterHotKey(hwnd, kHotkeyIdPrevious);
  }

  return registered_;
}

void MediaKeysPlugin::UnregisterMediaKeys() {
  if (!registered_ || registered_hwnd_ == nullptr) return;
  UnregisterHotKey(registered_hwnd_, kHotkeyIdNext);
  UnregisterHotKey(registered_hwnd_, kHotkeyIdPrevious);
  registered_ = false;
  registered_hwnd_ = nullptr;
}

std::optional<LRESULT> MediaKeysPlugin::HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  // Lazily register the hotkeys the first time we see a real top-level
  // hwnd, if Dart already asked us to (registration_requested_) before
  // this delegate had fired even once (e.g. if "register" arrives
  // before the first window message does - in practice this delegate
  // fires very early/often, but we guard for it anyway).
  if (registration_requested_ && !registered_) {
    // One-time diagnostic: compare the hwnd this delegate receives
    // against GetView()->GetNativeWindow(), to definitively confirm
    // or rule out the "two different windows" theory.
    HWND view_hwnd = registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr;
    bool same = (hwnd == view_hwnd);

    std::wstringstream cmp;
    cmp << L"[MediaKeysPlugin] DIAGNOSTIC: delegate hwnd=" << hwnd
        << L", GetView()->GetNativeWindow()=" << view_hwnd
        << L", SAME=" << (same ? L"YES" : L"NO") << L"\n";
    OutputDebugStringW(cmp.str().c_str());

    bool reg_ok = RegisterMediaKeys(hwnd);

    // Surface this diagnostic to Dart too (visible in `flutter run`
    // terminal) since OutputDebugStringW needs DebugView/Visual Studio
    // to see, which isn't always available.
    if (event_sink_) {
      std::ostringstream diag;
      diag << "diag:same_hwnd=" << (same ? "true" : "false") << ",registered=" << (reg_ok ? "true" : "false");
      event_sink_->Success(flutter::EncodableValue(diag.str()));
    }
  }

  if (message == WM_HOTKEY) {
    int id = static_cast<int>(wparam);

    std::wstringstream log;
    log << L"[MediaKeysPlugin] WM_HOTKEY received, id=" << id << L"\n";
    OutputDebugStringW(log.str().c_str());

    if (event_sink_) {
      if (id == kHotkeyIdNext) {
        Log(L"[MediaKeysPlugin] Sending 'next' event to Dart\n");
        event_sink_->Success(flutter::EncodableValue(std::string("next")));
      } else if (id == kHotkeyIdPrevious) {
        Log(L"[MediaKeysPlugin] Sending 'previous' event to Dart\n");
        event_sink_->Success(flutter::EncodableValue(std::string("previous")));
      }
    } else {
      Log(L"[MediaKeysPlugin] WARNING: event_sink_ is null, Dart isn't listening yet\n");
    }
    // Returning a value marks the message as handled.
    return 0;
  }
  // Not our message - let Flutter/the OS continue normal processing.
  return std::nullopt;
}

void MediaKeysPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "register") {
    registration_requested_ = true;

    // Do NOT attempt registration here using
    // registrar_->GetView()->GetNativeWindow() - that can be the
    // embedded Flutter view's CHILD hwnd rather than the top-level
    // frame hwnd, and if it "succeeds" against the wrong window,
    // registered_ becomes true and the correct lazy registration in
    // HandleWindowProc (against the verified top-level hwnd) would
    // then be skipped entirely by the `!registered_` guard - exactly
    // the bug that caused silent failures before.
    //
    // Instead, registration happens EXCLUSIVELY in HandleWindowProc,
    // the first time it fires with registration_requested_ true. By
    // the time this app is running and a user can press a hardware
    // key, the window proc delegate will have already fired many
    // times (every single window message goes through it), so this
    // happens effectively immediately - we don't need to wait
    // specifically for any particular message type.
    //
    // We report success optimistically here; if the underlying
    // RegisterHotKey call genuinely fails (e.g. another app already
    // owns these keys), that will show up in OutputDebugStringW logs
    // ("RegisterHotKey(...) FAILED, GetLastError=...") rather than as
    // a Dart-visible error, since the real attempt happens
    // asynchronously relative to this method call returning.
    result->Success(flutter::EncodableValue(true));
  } else if (call.method_name() == "unregister") {
    registration_requested_ = false;
    UnregisterMediaKeys();
    result->Success(flutter::EncodableValue(true));
  } else {
    result->NotImplemented();
  }
}

}  // namespace resonance
