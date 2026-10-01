#include "update_recovery.h"
#include <windows.h>
#include <fstream>
#include "utils.h"

bool RecoverInterruptedUpdate(const std::vector<std::string>& arguments) {
  // A new build launched by the active installer must reach Flutter and send
  // its health acknowledgement. Ordinary launches recover before loading
  // potentially half-replaced Flutter DLLs/assets.
  for (const auto& arg : arguments) {
    if (arg.rfind("--resonance-update-token=", 0) == 0) return false;
  }
  wchar_t executable[32768]{};
  const DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
  if (!length || length >= 32768) return false;
  const std::wstring path(executable, length);
  const std::wstring target = path.substr(0, path.find_last_of(L"\\"));
  const std::wstring marker = target + L"\\.resonance-update-pending";
  if (GetFileAttributesW(marker.c_str()) == INVALID_FILE_ATTRIBUTES) return false;
  std::ifstream input(marker);
  std::string stage_utf8;
  std::getline(input, stage_utf8);
  if (stage_utf8.empty() || stage_utf8.size() > 32000) return true;
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, stage_utf8.data(),
                                       static_cast<int>(stage_utf8.size()), nullptr, 0);
  if (!count) return true;
  std::wstring stage(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, stage_utf8.data(),
                      static_cast<int>(stage_utf8.size()), stage.data(), count);
  wchar_t temp[32768]{};
#ifdef RESONANCE_UPDATE_TEST
  const DWORD temp_length = GetEnvironmentVariableW(L"LOCALAPPDATA", temp, 32768);
  if (!temp_length || temp_length >= 32768) return true;
  const std::wstring allowed = std::wstring(temp) + L"\\ResonanceUpdateTest\\tmp\\resonance-update\\";
#else
  const DWORD temp_length = GetTempPathW(32768, temp);
  if (!temp_length || temp_length >= 32768) return true;
  const std::wstring allowed = std::wstring(temp) + L"resonance-update\\";
#endif
  if (stage.size() <= allowed.size() || _wcsnicmp(stage.c_str(), allowed.c_str(), allowed.size()) != 0 ||
      stage.find(L"..") != std::wstring::npos || stage.find(L'"') != std::wstring::npos ||
      stage.find(L'\n') != std::wstring::npos || stage.find(L'\r') != std::wstring::npos) return true;
  const std::wstring script = stage + L"\\apply-update.ps1";
  const std::wstring transaction = stage + L"\\transaction.json";
  const std::wstring zip = stage + L"\\payload.zip";
  if (GetFileAttributesW(script.c_str()) == INVALID_FILE_ATTRIBUTES ||
      GetFileAttributesW(transaction.c_str()) == INVALID_FILE_ATTRIBUTES) return true;
  wchar_t system[32768]{};
  if (!GetSystemDirectoryW(system, 32768)) return true;
  const std::wstring powershell = std::wstring(system) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  std::wstring command = L"\"" + powershell + L"\" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" +
      script + L"\" -Zip \"" + zip + L"\" -Transaction \"" + transaction + L"\" -Target \"" + target +
      L"\" -ParentPid " + std::to_wstring(GetCurrentProcessId()) + L" -RecoverOnly";
  STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION process{};
  if (CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr, FALSE,
                     CREATE_NO_WINDOW, nullptr, target.c_str(), &startup, &process)) {
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
  }
  return true;
}
