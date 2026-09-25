#ifndef RUNNER_RESONANCE_APP_IDENTITY_H_
#define RUNNER_RESONANCE_APP_IDENTITY_H_

namespace resonance {

inline constexpr wchar_t kAppUserModelId[] = L"Resonance.MusicPlayer";

// A portable ZIP has no installer to register its Start Menu identity. Create
// the shell shortcut before the window and SMTC session are initialized.
void RegisterAppIdentity();

}  // namespace resonance

#endif  // RUNNER_RESONANCE_APP_IDENTITY_H_
