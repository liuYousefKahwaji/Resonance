#include "voice_chat_plugin.h"

#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <wrl/client.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cmath>
#include <deque>
#include <sstream>
#include <iomanip>
#include <string>
#include <vector>

namespace resonance {
namespace {
using Microsoft::WRL::ComPtr;
using flutter::EncodableValue;
using flutter::EncodableMap;
std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size);
  return result;
}
std::string Utf8(const wchar_t* value) {
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr, nullptr);
  if (!result.empty()) result.pop_back();
  return result;
}
std::string String(const EncodableMap& map, const char* key) {
  auto found = map.find(EncodableValue(key));
  if (found == map.end()) return {};
  auto value = std::get_if<std::string>(&found->second);
  return value ? *value : std::string();
}
double Number(const EncodableMap& map, const char* key, double fallback) {
  auto found = map.find(EncodableValue(key));
  if (found == map.end()) return fallback;
  auto value = std::get_if<double>(&found->second);
  return value ? *value : fallback;
}
bool Boolean(const EncodableMap& map, const char* key) {
  auto found = map.find(EncodableValue(key));
  if (found == map.end()) return false;
  auto value = std::get_if<bool>(&found->second);
  return value && *value;
}
flutter::EncodableList Devices(IMMDeviceEnumerator* enumerator, EDataFlow flow) {
  flutter::EncodableList result;
  ComPtr<IMMDeviceCollection> devices;
  if (FAILED(enumerator->EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE, &devices))) return result;
  UINT count = 0;
  devices->GetCount(&count);
  for (UINT i = 0; i < count; ++i) {
    ComPtr<IMMDevice> device;
    ComPtr<IPropertyStore> properties;
    LPWSTR id = nullptr;
    PROPVARIANT name{};
    if (FAILED(devices->Item(i, &device)) || FAILED(device->GetId(&id))) continue;
    std::string label = Utf8(id);
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &properties)) &&
        SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &name)) && name.vt == VT_LPWSTR) {
      label = Utf8(name.pwszVal);
    }
    result.emplace_back(EncodableMap{{EncodableValue("id"), EncodableValue(Utf8(id))},
                                    {EncodableValue("name"), EncodableValue(label)}});
    PropVariantClear(&name);
    CoTaskMemFree(id);
  }
  return result;
}
std::string DefaultDevice(IMMDeviceEnumerator* enumerator, EDataFlow flow, ERole role) {
  ComPtr<IMMDevice> device;
  LPWSTR id = nullptr;
  if (FAILED(enumerator->GetDefaultAudioEndpoint(flow, role, &device)) || FAILED(device->GetId(&id))) return {};
  const auto result = Utf8(id);
  CoTaskMemFree(id);
  return result;
}
struct Output {
  ComPtr<IAudioClient> client;
  ComPtr<IAudioRenderClient> render;
  UINT32 capacity = 0;
  std::deque<float> samples;
  bool started = false, primed = false;
  double fraction = 0;
  ~Output() { if (client && started) client->Stop(); }
  HRESULT Open(IMMDeviceEnumerator* enumerator, const std::wstring& id, WAVEFORMATEX* format) {
    ComPtr<IMMDevice> device;
    HRESULT hr = id.empty() ? enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)
                           : enumerator->GetDevice(id.c_str(), &device);
    if (FAILED(hr)) return hr;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client);
    if (FAILED(hr)) return hr;
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
          AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY | AUDCLNT_STREAMFLAGS_NOPERSIST,
          200000, 0, format, nullptr);
    if (FAILED(hr)) return hr;
    hr = client->GetBufferSize(&capacity);
    if (FAILED(hr)) return hr;
    hr = client->GetService(IID_PPV_ARGS(&render));
    if (FAILED(hr)) return hr;
    return S_OK;
  }
  HRESULT Write() {
    UINT32 padding = 0;
    HRESULT hr = client->GetCurrentPadding(&padding);
    if (FAILED(hr)) return hr;
    const size_t queued = samples.size() / 2;
    // Wait for capture packets instead of filling each gap with silence.
    if (!primed) {
      if (queued < 960) return S_OK;
      primed = true;
    }
    if (queued < 2) {
      if (padding == 0) primed = false;
      return S_OK;
    }
    // Small clock compensation keeps USB microphone/cable clocks aligned.
    const double step = std::clamp(1.0 + (static_cast<double>(queued + padding) - 960.0) * 0.0000002, 0.999, 1.001);
    const UINT32 input_frames = static_cast<UINT32>((static_cast<double>(queued) - fraction) / step);
    const UINT32 frames = std::min(capacity - padding, input_frames);
    if (!frames) return S_OK;
    BYTE* bytes = nullptr;
    hr = render->GetBuffer(frames, &bytes);
    if (FAILED(hr)) return hr;
    float* destination = reinterpret_cast<float*>(bytes);
    for (UINT32 i = 0; i < frames; ++i) {
      const double position = fraction + i * step;
      const size_t index = static_cast<size_t>(position);
      const size_t next = std::min(index + 1, queued - 1);
      const float weight = static_cast<float>(position - index);
      for (size_t channel = 0; channel < 2; ++channel) {
        const float first = samples[index * 2 + channel];
        destination[i * 2 + channel] = first + (samples[next * 2 + channel] - first) * weight;
      }
    }
    const double consumed = fraction + frames * step;
    const size_t whole_frames = static_cast<size_t>(consumed);
    fraction = consumed - whole_frames;
    for (size_t i = 0; i < whole_frames * 2; ++i) samples.pop_front();
    hr = render->ReleaseBuffer(frames, 0);
    if (SUCCEEDED(hr) && !started) {
      hr = client->Start();
      started = SUCCEEDED(hr);
    }
    return hr;
  }
  void Add(const std::vector<float>& packet) {
    samples.insert(samples.end(), packet.begin(), packet.end());
    // A disconnected or slower endpoint must never accumulate seconds of speech.
    while (samples.size() > 4800 * 2) { samples.pop_front(); samples.pop_front(); fraction = 0; }
  }
};
}

VoiceChatPlugin::VoiceChatPlugin() = default;
VoiceChatPlugin::~VoiceChatPlugin() { Stop(); }
void VoiceChatPlugin::Stop() {
  stop_ = true;
  if (worker_.joinable()) worker_.join();
  running_ = false;
  peak_ = 0;
}
void VoiceChatPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<VoiceChatPlugin>();
  plugin->channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "resonance/voice_chat", &flutter::StandardMethodCodec::GetInstance());
  plugin->channel_->SetMethodCallHandler([self = plugin.get()](const auto& call, auto result) {
    const auto* arguments = std::get_if<EncodableMap>(call.arguments());
    const EncodableMap empty;
    const auto& args = arguments ? *arguments : empty;
    if (call.method_name() == "devices") {
      ComPtr<IMMDeviceEnumerator> enumerator;
      HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
      if (FAILED(hr)) { result->Error("DEVICES", "Windows audio devices could not be read."); return; }
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("microphones"), EncodableValue(Devices(enumerator.Get(), eCapture))},
        {EncodableValue("outputs"), EncodableValue(Devices(enumerator.Get(), eRender))},
        {EncodableValue("defaultMicrophone"), EncodableValue(DefaultDevice(enumerator.Get(), eCapture, eCommunications))},
        {EncodableValue("defaultOutput"), EncodableValue(DefaultDevice(enumerator.Get(), eRender, eConsole))}}));
    } else if (call.method_name() == "start") {
      self->Stop();
      const auto output = String(args, "output");
      if (output.empty()) { result->Error("OUTPUT", "Choose a virtual cable first."); return; }
      { std::lock_guard<std::mutex> lock(self->error_mutex_); self->error_.clear(); self->monitor_error_.clear(); }
      self->stop_ = false;
      self->captured_frames_ = 0;
      self->gain_ = static_cast<float>(std::clamp(Number(args, "gain", 1.0), 0.0, 2.0));
      self->monitor_ = Boolean(args, "monitor");
      self->worker_ = std::thread(&VoiceChatPlugin::Run, self, Wide(String(args, "microphone")), Wide(output), Wide(String(args, "headphones")));
      result->Success();
    } else if (call.method_name() == "levels") {
      { std::lock_guard<std::mutex> lock(self->error_mutex_); self->monitor_error_.clear(); }
      self->gain_ = static_cast<float>(std::clamp(Number(args, "gain", 1.0), 0.0, 2.0));
      self->monitor_ = Boolean(args, "monitor");
      result->Success();
    } else if (call.method_name() == "stop") {
      self->Stop(); result->Success();
    } else if (call.method_name() == "status") {
      std::lock_guard<std::mutex> lock(self->error_mutex_);
      result->Success(EncodableValue(EncodableMap{
        {EncodableValue("running"), EncodableValue(self->running_.load())},
        {EncodableValue("peak"), EncodableValue(static_cast<double>(self->peak_.load()))},
        {EncodableValue("error"), EncodableValue(self->error_)},
        {EncodableValue("monitorError"), EncodableValue(self->monitor_error_)}}));
    } else { result->NotImplemented(); }
  });
  registrar->AddPlugin(std::move(plugin));
}

void VoiceChatPlugin::Run(std::wstring microphone, std::wstring output, std::wstring monitor) {
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  HRESULT hr = com;
  const char* operation = "Opening microphone";
  if (SUCCEEDED(com)) {
    DWORD task_index = 0;
    HANDLE audio_task = AvSetMmThreadCharacteristicsW(L"Audio", &task_index);
    // All COM audio objects are created, used and released on this worker.
    [&]() {
      ComPtr<IMMDeviceEnumerator> enumerator;
      hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
      if (FAILED(hr)) return;
      ComPtr<IMMDevice> device;
      hr = microphone.empty() ? enumerator->GetDefaultAudioEndpoint(eCapture, eCommunications, &device)
                              : enumerator->GetDevice(microphone.c_str(), &device);
      if (FAILED(hr)) return;
      ComPtr<IAudioClient> capture;
      hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &capture);
      if (FAILED(hr)) return;
      WAVEFORMATEX format{};
      format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
      format.nChannels = 2;
      format.nSamplesPerSec = 48000;
      format.wBitsPerSample = 32;
      format.nBlockAlign = 8;
      format.nAvgBytesPerSec = 384000;
      HANDLE capture_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
      struct EventOwner { HANDLE handle; ~EventOwner() { if (handle) CloseHandle(handle); } } event_owner{capture_event};
      if (!capture_event) { hr = HRESULT_FROM_WIN32(GetLastError()); return; }
      hr = capture->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
          AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY | AUDCLNT_STREAMFLAGS_NOPERSIST, 200000, 0, &format, nullptr);
      if (FAILED(hr)) return;
      ComPtr<IAudioCaptureClient> input;
      hr = capture->SetEventHandle(capture_event);
      if (FAILED(hr)) return;
      hr = capture->GetService(IID_PPV_ARGS(&input));
      if (FAILED(hr)) return;
      Output cable;
      std::unique_ptr<Output> headphones;
      operation = "Opening virtual cable";
      hr = cable.Open(enumerator.Get(), output, &format);
      if (FAILED(hr)) return;
      operation = "Starting microphone";
      hr = capture->Start();
      if (FAILED(hr)) return;
      running_ = true;
      operation = "Routing microphone (device disconnected or access lost)";
      while (!stop_) {
        if (monitor_ && !headphones) {
          auto candidate = std::make_unique<Output>();
          const auto monitor_hr = candidate->Open(enumerator.Get(), monitor, &format);
          if (SUCCEEDED(monitor_hr)) headphones = std::move(candidate);
          else {
            monitor_ = false;
            std::lock_guard<std::mutex> lock(error_mutex_);
            monitor_error_ = "Microphone monitoring could not open your headphones. Music and microphone sharing are still on.";
          }
        } else if (!monitor_) { headphones.reset(); }
        UINT32 next = 0;
        hr = input->GetNextPacketSize(&next);
        if (FAILED(hr)) break;
        while (next > 0 && !stop_) {
          BYTE* data = nullptr;
          UINT32 frames = 0;
          DWORD flags = 0;
          hr = input->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
          if (FAILED(hr)) break;
          std::vector<float> samples(frames * 2, 0.0f);
          float peak = 0;
          if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
            const auto* source = reinterpret_cast<const float*>(data);
            for (size_t i = 0; i < samples.size(); ++i) {
              samples[i] = std::clamp(source[i] * gain_.load(), -1.0f, 1.0f);
              peak = std::max(peak, std::abs(samples[i]));
            }
          }
          input->ReleaseBuffer(frames);
          captured_frames_ += frames;
          peak_ = peak;
          cable.Add(samples);
          if (headphones) headphones->Add(samples);
          hr = input->GetNextPacketSize(&next);
          if (FAILED(hr)) break;
        }
        if (FAILED(hr)) break;
        hr = cable.Write();
        if (FAILED(hr)) break;
        if (headphones) {
          const auto monitor_hr = headphones->Write();
          if (FAILED(monitor_hr)) {
            headphones.reset(); monitor_ = false;
            std::lock_guard<std::mutex> lock(error_mutex_);
            monitor_error_ = "Microphone monitoring stopped. Music and microphone sharing are still on.";
          }
        }
        WaitForSingleObject(capture_event, 5);
      }
      capture->Stop();
    }();
    if (audio_task) AvRevertMmThreadCharacteristics(audio_task);
    CoUninitialize();
  }
  running_ = false;
  peak_ = 0;
  if (FAILED(hr) && !stop_) {
    std::ostringstream message;
    message << operation << " failed (0x" << std::hex << static_cast<unsigned long>(hr)
            << "). Check microphone permission and reconnect your audio devices.";
    std::lock_guard<std::mutex> lock(error_mutex_);
    error_ = message.str();
  }
}
}
