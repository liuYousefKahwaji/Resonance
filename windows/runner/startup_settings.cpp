#include "startup_settings.h"
#include <vector>
namespace resonance {
namespace {
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
std::wstring ExecutablePath() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  return length && length < path.size() ? std::wstring(path.data(), length) : std::wstring();
}
}
std::wstring ExecutableDirectory() {
  const auto path = ExecutablePath();
  const auto end = path.find_last_of(L"\\/");
  return end == std::wstring::npos ? std::wstring() : path.substr(0, end);
}
LSTATUS ReadStartupSetting(bool* enabled, const wchar_t* name) {
  *enabled = false;
  DWORD size = 0;
  const auto status = RegGetValueW(HKEY_CURRENT_USER, kRunKey, name, RRF_RT_REG_SZ, nullptr, nullptr, &size);
  if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) return ERROR_SUCCESS;
  if (status != ERROR_SUCCESS) return status;
  *enabled = size > sizeof(wchar_t);
  return ERROR_SUCCESS;
}
LSTATUS WriteStartupSetting(bool enabled, const wchar_t* name) {
  if (!enabled) {
    const auto status = RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, name);
    return status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND ? ERROR_SUCCESS : status;
  }
  const auto path = ExecutablePath();
  if (path.empty()) return ERROR_BAD_PATHNAME;
  const std::wstring command = L"\"" + path + L"\" --launch-on-startup";
  if (command.size() > 260) return ERROR_FILENAME_EXCED_RANGE;
  HKEY key = nullptr;
  auto status = RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) return status;
  status = RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()),
                         static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return status;
}
LSTATUS RefreshStartupSetting() {
  bool enabled = false;
  const auto status = ReadStartupSetting(&enabled);
  return status != ERROR_SUCCESS || !enabled ? status : WriteStartupSetting(true);
}
}
