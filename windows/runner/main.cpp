#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// ─────────────────────────────────────────────────────────────────────────
// Single-instance enforcement.
//
// A named mutex is created on launch. If it already exists, another
// instance of Resonance is already running, so instead of opening a
// second window we find that instance's window and bring it to the
// foreground, then exit immediately WITHOUT constructing FlutterWindow
// (constructing it is what actually creates the visible second window -
// this must happen before that point).
//
// kMutexName must be globally unique enough to not collide with other
// apps; a GUID-style string is used for that reason.
// ─────────────────────────────────────────────────────────────────────────
namespace {

constexpr wchar_t kMutexName[] = L"Resonance_SingleInstance_Mutex_8F3D2A1C";
constexpr wchar_t kWindowTitle[] = L"resonance";

// Brings an already-running instance's window to the foreground.
// Handles the case where it's minimized (restores it first) and the
// common Windows "foreground lock" issue (AttachThreadInput trick) that
// can otherwise silently make SetForegroundWindow a no-op.
void FocusExistingInstance() {
  HWND existing = FindWindow(nullptr, kWindowTitle);
  if (!existing) {
    return;
  }

  if (IsIconic(existing)) {
    ShowWindow(existing, SW_RESTORE);
  }

  // SetForegroundWindow can silently fail if the calling process isn't
  // allowed to steal focus. Temporarily attaching this thread's input
  // queue to the target window's foreground thread works around that.
  DWORD foreground_thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
  DWORD current_thread = GetCurrentThreadId();

  if (foreground_thread != current_thread) {
    AttachThreadInput(current_thread, foreground_thread, TRUE);
    SetForegroundWindow(existing);
    AttachThreadInput(current_thread, foreground_thread, FALSE);
  } else {
    SetForegroundWindow(existing);
  }

  BringWindowToTop(existing);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                       _In_ wchar_t *command_line, _In_ int show_command) {
  // Single-instance check happens FIRST, before any Flutter/window setup.
  HANDLE instance_mutex = CreateMutex(nullptr, TRUE, kMutexName);
  if (instance_mutex != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {
    FocusExistingInstance();
    CloseHandle(instance_mutex);
    return 0;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    if (instance_mutex != nullptr) CloseHandle(instance_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();

  if (instance_mutex != nullptr) {
    CloseHandle(instance_mutex);
  }

  return EXIT_SUCCESS;
}