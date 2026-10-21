#ifndef RUNNER_STARTUP_SETTINGS_H_
#define RUNNER_STARTUP_SETTINGS_H_
#include <windows.h>
#include <string>
namespace resonance {
LSTATUS ReadStartupSetting(bool* enabled, const wchar_t* name = L"Resonance");
LSTATUS WriteStartupSetting(bool enabled, const wchar_t* name = L"Resonance");
LSTATUS RefreshStartupSetting();
std::wstring ExecutableDirectory();
}
#endif
