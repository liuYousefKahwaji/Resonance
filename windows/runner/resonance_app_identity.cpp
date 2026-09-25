#include "resonance_app_identity.h"

#include <windows.h>
#include <propkey.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <string>
#include <vector>

namespace resonance {

void RegisterAppIdentity() {
  SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);

  PWSTR programs = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_DEFAULT, nullptr, &programs))) return;
  const std::wstring shortcut = std::wstring(programs) + L"\\Resonance.lnk";
  CoTaskMemFree(programs);

  std::vector<wchar_t> buffer(MAX_PATH);
  DWORD length = 0;
  while (true) {
    length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) return;
    if (length < buffer.size() - 1) break;
    if (buffer.size() >= 32768) return;
    buffer.resize(buffer.size() * 2);
  }
  const std::wstring executable(buffer.data(), length);

  IShellLinkW* link = nullptr;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_IShellLinkW, reinterpret_cast<void**>(&link)))) return;
  link->SetPath(executable.c_str());
  link->SetIconLocation(executable.c_str(), 0);
  link->SetDescription(L"Resonance music player");

  IPropertyStore* properties = nullptr;
  if (SUCCEEDED(link->QueryInterface(IID_IPropertyStore, reinterpret_cast<void**>(&properties)))) {
    PROPVARIANT app_id{};
    app_id.vt = VT_LPWSTR;
    app_id.pwszVal = const_cast<LPWSTR>(kAppUserModelId);
    properties->SetValue(PKEY_AppUserModel_ID, app_id);
    properties->Commit();
    properties->Release();
  }

  IPersistFile* persist = nullptr;
  if (SUCCEEDED(link->QueryInterface(IID_IPersistFile, reinterpret_cast<void**>(&persist)))) {
    persist->Save(shortcut.c_str(), TRUE);
    persist->Release();
  }
  link->Release();
}

}  // namespace resonance
