#include "music_recognition_plugin.h"

#include <audioclient.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <limits>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include <flutter/standard_method_codec.h>

namespace resonance {
namespace {

using Microsoft::WRL::ComPtr;

constexpr char kMethodChannelName[] = "resonance/music_recognition";
constexpr wchar_t kMessageWindowClassName[] =
    L"ResonanceMusicRecognitionMessageWindow";
constexpr UINT kCaptureCompleteMessage = WM_APP + 0x523;
constexpr uint32_t kOutputSampleRate = 16000;
constexpr float kNonSilentPeakThreshold = 0.0001f;
constexpr int64_t kMaximumCaptureDurationMs = 60000;
constexpr int64_t kMaximumWaitTimeoutMs = 60000;
constexpr DWORD kCapturePollIntervalMs = 10;
constexpr REFERENCE_TIME kWasapiBufferDuration = 1000000;  // 100 ms.

enum class CaptureSource {
  kMicrophone,
  kDeviceOutput,
};

enum class SampleEncoding {
  kPcm,
  kFloat,
};

struct NativeAudioFormat {
  SampleEncoding encoding = SampleEncoding::kFloat;
  uint16_t channels = 0;
  uint16_t container_bits = 0;
  uint16_t valid_bits = 0;
  uint16_t bytes_per_sample = 0;
  uint16_t block_align = 0;
  uint32_t sample_rate = 0;
};

struct CaptureOutcome {
  bool succeeded = false;
  std::vector<uint8_t> pcm_bytes;
  std::string error_code;
  std::string error_message;
};

class ScopedComInitialization {
 public:
  ScopedComInitialization()
      : result_(CoInitializeEx(nullptr, COINIT_MULTITHREADED)),
        should_uninitialize_(SUCCEEDED(result_)) {}

  ~ScopedComInitialization() {
    if (should_uninitialize_) {
      CoUninitialize();
    }
  }

  HRESULT result() const { return result_; }

 private:
  HRESULT result_;
  bool should_uninitialize_;
};

class ScopedStartedAudioClient {
 public:
  explicit ScopedStartedAudioClient(IAudioClient* client) : client_(client) {}

  ~ScopedStartedAudioClient() {
    if (started_) {
      client_->Stop();
    }
  }

  void MarkStarted() { started_ = true; }

 private:
  IAudioClient* client_;
  bool started_ = false;
};

struct CoTaskMemFormatDeleter {
  void operator()(WAVEFORMATEX* format) const {
    CoTaskMemFree(format);
  }
};

CaptureOutcome Failure(std::string code, std::string message) {
  CaptureOutcome outcome;
  outcome.error_code = std::move(code);
  outcome.error_message = std::move(message);
  return outcome;
}

CaptureOutcome HResultFailure(const char* operation,
                              HRESULT result,
                              const char* code = "AUDIO_DEVICE_ERROR") {
  std::ostringstream message;
  message << operation << " failed (HRESULT 0x" << std::hex << std::uppercase
          << std::setw(8) << std::setfill('0')
          << static_cast<uint32_t>(result) << ").";
  return Failure(code, message.str());
}

bool ParseNativeFormat(const WAVEFORMATEX& wave_format,
                       NativeAudioFormat* parsed,
                       std::string* error_message) {
  if (wave_format.nChannels == 0 || wave_format.nSamplesPerSec == 0 ||
      wave_format.nBlockAlign == 0 || wave_format.wBitsPerSample == 0 ||
      wave_format.wBitsPerSample % 8 != 0) {
    *error_message = "The default audio endpoint returned an invalid mix format.";
    return false;
  }

  SampleEncoding encoding;
  uint16_t valid_bits = wave_format.wBitsPerSample;
  if (wave_format.wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    encoding = SampleEncoding::kFloat;
  } else if (wave_format.wFormatTag == WAVE_FORMAT_PCM) {
    encoding = SampleEncoding::kPcm;
  } else if (wave_format.wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    if (wave_format.cbSize <
        static_cast<WORD>(sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX))) {
      *error_message = "The endpoint returned a truncated extensible mix format.";
      return false;
    }
    const auto& extensible =
        reinterpret_cast<const WAVEFORMATEXTENSIBLE&>(wave_format);
    if (IsEqualGUID(extensible.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
      encoding = SampleEncoding::kFloat;
    } else if (IsEqualGUID(extensible.SubFormat, KSDATAFORMAT_SUBTYPE_PCM)) {
      encoding = SampleEncoding::kPcm;
    } else {
      *error_message = "The default audio endpoint uses an unsupported sample format.";
      return false;
    }
    if (extensible.Samples.wValidBitsPerSample != 0) {
      valid_bits = extensible.Samples.wValidBitsPerSample;
    }
  } else {
    *error_message = "The default audio endpoint uses an unsupported sample format.";
    return false;
  }

  const uint16_t container_bits = wave_format.wBitsPerSample;
  const uint16_t bytes_per_sample = static_cast<uint16_t>(container_bits / 8);
  const uint32_t minimum_block_align =
      static_cast<uint32_t>(bytes_per_sample) * wave_format.nChannels;
  if (wave_format.nBlockAlign < minimum_block_align || valid_bits == 0 ||
      valid_bits > container_bits) {
    *error_message = "The default audio endpoint returned an invalid sample layout.";
    return false;
  }

  if (encoding == SampleEncoding::kFloat &&
      container_bits != 32 && container_bits != 64) {
    *error_message = "Only 32-bit and 64-bit floating-point endpoint audio is supported.";
    return false;
  }
  if (encoding == SampleEncoding::kPcm && container_bits != 8 &&
      container_bits != 16 && container_bits != 24 && container_bits != 32) {
    *error_message = "Only 8-, 16-, 24-, and 32-bit PCM endpoint audio is supported.";
    return false;
  }

  parsed->encoding = encoding;
  parsed->channels = wave_format.nChannels;
  parsed->container_bits = container_bits;
  parsed->valid_bits = valid_bits;
  parsed->bytes_per_sample = bytes_per_sample;
  parsed->block_align = wave_format.nBlockAlign;
  parsed->sample_rate = wave_format.nSamplesPerSec;
  return true;
}

float DecodePcmSample(const BYTE* data, const NativeAudioFormat& format) {
  if (format.container_bits == 8) {
    const int32_t centered = static_cast<int32_t>(*data) - 128;
    return static_cast<float>(centered) / 128.0f;
  }

  int64_t value = 0;
  if (format.container_bits == 16) {
    int16_t sample = 0;
    std::memcpy(&sample, data, sizeof(sample));
    value = sample;
  } else if (format.container_bits == 24) {
    int32_t sample = static_cast<int32_t>(data[0]) |
                     (static_cast<int32_t>(data[1]) << 8) |
                     (static_cast<int32_t>(data[2]) << 16);
    if ((sample & 0x00800000) != 0) {
      sample |= static_cast<int32_t>(0xFF000000);
    }
    value = sample;
  } else {
    int32_t sample = 0;
    std::memcpy(&sample, data, sizeof(sample));
    value = sample;
  }

  // WAVEFORMATEXTENSIBLE stores valid PCM bits left-aligned in the sample
  // container, so discard any low padding before normalizing.
  if (format.valid_bits < format.container_bits) {
    value >>= format.container_bits - format.valid_bits;
  }
  const uint64_t magnitude = uint64_t{1} << (format.valid_bits - 1);
  return static_cast<float>(static_cast<double>(value) /
                            static_cast<double>(magnitude));
}

float DecodeSample(const BYTE* data, const NativeAudioFormat& format) {
  float value = 0.0f;
  if (format.encoding == SampleEncoding::kFloat) {
    if (format.container_bits == 32) {
      std::memcpy(&value, data, sizeof(value));
    } else {
      double double_value = 0.0;
      std::memcpy(&double_value, data, sizeof(double_value));
      value = static_cast<float>(double_value);
    }
  } else {
    value = DecodePcmSample(data, format);
  }

  if (!std::isfinite(value)) {
    return 0.0f;
  }
  return std::clamp(value, -1.0f, 1.0f);
}

void MixPacketToMono(const BYTE* data,
                     UINT32 frame_count,
                     DWORD flags,
                     const NativeAudioFormat& format,
                     std::vector<float>* mono) {
  mono->assign(frame_count, 0.0f);
  if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
    return;
  }

  for (UINT32 frame = 0; frame < frame_count; ++frame) {
    const BYTE* frame_data =
        data + static_cast<size_t>(frame) * format.block_align;
    double sum = 0.0;
    for (uint16_t channel = 0; channel < format.channels; ++channel) {
      const BYTE* sample_data =
          frame_data + static_cast<size_t>(channel) * format.bytes_per_sample;
      sum += DecodeSample(sample_data, format);
    }
    (*mono)[frame] = static_cast<float>(sum / format.channels);
  }
}

bool ContainsNonSilentAudio(const std::vector<float>& samples) {
  for (float sample : samples) {
    if (std::fabs(sample) >= kNonSilentPeakThreshold) {
      return true;
    }
  }
  return false;
}

std::vector<uint8_t> ResampleToPcm16(const std::vector<float>& source,
                                     uint32_t source_sample_rate,
                                     size_t target_frame_count) {
  std::vector<uint8_t> output(target_frame_count * sizeof(int16_t));
  const double source_frames_per_output_frame =
      static_cast<double>(source_sample_rate) / kOutputSampleRate;

  for (size_t output_frame = 0; output_frame < target_frame_count;
       ++output_frame) {
    const double source_position =
        static_cast<double>(output_frame) * source_frames_per_output_frame;
    const size_t lower_index = static_cast<size_t>(source_position);
    const size_t upper_index =
        std::min(lower_index + 1, source.size() - 1);
    const float fraction =
        static_cast<float>(source_position - static_cast<double>(lower_index));
    const float interpolated =
        source[lower_index] +
        (source[upper_index] - source[lower_index]) * fraction;
    const float clamped = std::clamp(interpolated, -1.0f, 1.0f);
    const int16_t pcm_sample =
        clamped <= -1.0f
            ? std::numeric_limits<int16_t>::min()
            : static_cast<int16_t>(std::lround(clamped * 32767.0f));
    const uint16_t encoded = static_cast<uint16_t>(pcm_sample);
    output[output_frame * 2] = static_cast<uint8_t>(encoded & 0xFFu);
    output[output_frame * 2 + 1] =
        static_cast<uint8_t>((encoded >> 8) & 0xFFu);
  }
  return output;
}

CaptureOutcome CaptureWasapi(CaptureSource source,
                             int64_t capture_duration_ms,
                             int64_t wait_timeout_ms,
                             HANDLE cancel_event) {
  ScopedComInitialization com;
  if (FAILED(com.result()) && com.result() != RPC_E_CHANGED_MODE) {
    return HResultFailure("CoInitializeEx", com.result(), "CAPTURE_ERROR");
  }

  ComPtr<IMMDeviceEnumerator> enumerator;
  HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                    CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (FAILED(result)) {
    return HResultFailure("Creating the Windows audio device enumerator", result);
  }

  ComPtr<IMMDevice> device;
  const EDataFlow data_flow = source == CaptureSource::kMicrophone
                                  ? eCapture
                                  : eRender;
  result = enumerator->GetDefaultAudioEndpoint(data_flow, eConsole, &device);
  if (FAILED(result)) {
    return HResultFailure("Opening the default Windows audio endpoint", result);
  }

  ComPtr<IAudioClient> audio_client;
  result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                            &audio_client);
  if (FAILED(result)) {
    return HResultFailure("Activating the Windows audio endpoint", result);
  }

  WAVEFORMATEX* raw_mix_format = nullptr;
  result = audio_client->GetMixFormat(&raw_mix_format);
  if (FAILED(result)) {
    return HResultFailure("Reading the endpoint mix format", result);
  }
  std::unique_ptr<WAVEFORMATEX, CoTaskMemFormatDeleter> mix_format(
      raw_mix_format);

  NativeAudioFormat native_format;
  std::string format_error;
  if (!ParseNativeFormat(*mix_format, &native_format, &format_error)) {
    return Failure("UNSUPPORTED_AUDIO_FORMAT", format_error);
  }

  DWORD stream_flags = 0;
  if (source == CaptureSource::kDeviceOutput) {
    stream_flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
  }
  result = audio_client->Initialize(AUDCLNT_SHAREMODE_SHARED, stream_flags,
                                    kWasapiBufferDuration, 0,
                                    mix_format.get(), nullptr);
  if (FAILED(result)) {
    return HResultFailure("Initializing WASAPI capture", result);
  }

  ComPtr<IAudioCaptureClient> capture_client;
  result = audio_client->GetService(IID_PPV_ARGS(&capture_client));
  if (FAILED(result)) {
    return HResultFailure("Creating the WASAPI capture client", result);
  }

  result = audio_client->Start();
  if (FAILED(result)) {
    return HResultFailure("Starting WASAPI capture", result);
  }
  ScopedStartedAudioClient started_client(audio_client.Get());
  started_client.MarkStarted();

  const uint64_t source_frame_count_u64 =
      (static_cast<uint64_t>(native_format.sample_rate) *
           static_cast<uint64_t>(capture_duration_ms) +
       999u) /
      1000u;
  const uint64_t target_frame_count_u64 =
      (static_cast<uint64_t>(kOutputSampleRate) *
       static_cast<uint64_t>(capture_duration_ms)) /
      1000u;
  if (source_frame_count_u64 == 0 || target_frame_count_u64 == 0 ||
      source_frame_count_u64 >
          static_cast<uint64_t>(std::numeric_limits<size_t>::max()) ||
      target_frame_count_u64 >
          static_cast<uint64_t>(std::numeric_limits<size_t>::max() / 2)) {
    return Failure("INVALID_ARGUMENT", "The requested capture duration is too large.");
  }
  const size_t source_frame_count =
      static_cast<size_t>(source_frame_count_u64);
  const size_t target_frame_count =
      static_cast<size_t>(target_frame_count_u64);

  std::vector<float> captured_mono;
  captured_mono.reserve(source_frame_count);
  std::vector<float> packet_mono;

  bool collecting = source == CaptureSource::kMicrophone;
  std::optional<std::chrono::steady_clock::time_point> collection_deadline;
  if (collecting) {
    collection_deadline =
        std::chrono::steady_clock::now() +
        std::chrono::milliseconds(capture_duration_ms);
  }
  const auto wait_deadline =
      std::chrono::steady_clock::now() +
      std::chrono::milliseconds(wait_timeout_ms);

  while (captured_mono.size() < source_frame_count) {
    if (WaitForSingleObject(cancel_event, 0) == WAIT_OBJECT_0) {
      return Failure("CAPTURE_CANCELLED", "Audio capture was cancelled.");
    }

    UINT32 next_packet_frames = 0;
    result = capture_client->GetNextPacketSize(&next_packet_frames);
    if (FAILED(result)) {
      return HResultFailure("Querying WASAPI capture data", result);
    }

    while (next_packet_frames > 0) {
      BYTE* packet_data = nullptr;
      UINT32 packet_frame_count = 0;
      DWORD packet_flags = 0;
      result = capture_client->GetBuffer(&packet_data, &packet_frame_count,
                                         &packet_flags, nullptr, nullptr);
      if (FAILED(result)) {
        return HResultFailure("Reading WASAPI capture data", result);
      }

      MixPacketToMono(packet_data, packet_frame_count, packet_flags,
                      native_format, &packet_mono);
      if (!collecting && ContainsNonSilentAudio(packet_mono)) {
        collecting = true;
        collection_deadline =
            std::chrono::steady_clock::now() +
            std::chrono::milliseconds(capture_duration_ms);
      }

      if (collecting) {
        const size_t remaining = source_frame_count - captured_mono.size();
        const size_t frames_to_copy = std::min(remaining, packet_mono.size());
        captured_mono.insert(captured_mono.end(), packet_mono.begin(),
                             packet_mono.begin() +
                                 static_cast<std::ptrdiff_t>(frames_to_copy));
      }

      const HRESULT release_result = capture_client->ReleaseBuffer(
          packet_frame_count);
      if (FAILED(release_result)) {
        return HResultFailure("Releasing WASAPI capture data", release_result);
      }
      if (captured_mono.size() >= source_frame_count) {
        break;
      }

      result = capture_client->GetNextPacketSize(&next_packet_frames);
      if (FAILED(result)) {
        return HResultFailure("Querying WASAPI capture data", result);
      }
    }

    if (!collecting && std::chrono::steady_clock::now() >= wait_deadline) {
      return Failure("NO_AUDIO_TIMEOUT",
                     "No non-silent device output was detected before the timeout.");
    }
    // A render endpoint can stop emitting loopback packets as soon as all
    // playback streams close. Complete on wall-clock time in that case and
    // represent the missing tail as silence instead of waiting indefinitely.
    if (collecting && collection_deadline.has_value() &&
        std::chrono::steady_clock::now() >= *collection_deadline &&
        captured_mono.size() < source_frame_count) {
      captured_mono.resize(source_frame_count, 0.0f);
    }
    if (captured_mono.size() >= source_frame_count) {
      break;
    }

    const DWORD wait_result =
        WaitForSingleObject(cancel_event, kCapturePollIntervalMs);
    if (wait_result == WAIT_OBJECT_0) {
      return Failure("CAPTURE_CANCELLED", "Audio capture was cancelled.");
    }
    if (wait_result == WAIT_FAILED) {
      return Failure("CAPTURE_ERROR", "Waiting for WASAPI capture data failed.");
    }
  }

  CaptureOutcome outcome;
  outcome.succeeded = true;
  outcome.pcm_bytes = ResampleToPcm16(
      captured_mono, native_format.sample_rate, target_frame_count);
  return outcome;
}

const flutter::EncodableValue* FindArgument(const flutter::EncodableMap& map,
                                             const char* name) {
  const auto found = map.find(flutter::EncodableValue(name));
  return found == map.end() ? nullptr : &found->second;
}

bool ReadStringArgument(const flutter::EncodableMap& map,
                        const char* name,
                        std::string* value) {
  const flutter::EncodableValue* encoded = FindArgument(map, name);
  const auto* string_value =
      encoded == nullptr ? nullptr : std::get_if<std::string>(encoded);
  if (string_value == nullptr) {
    return false;
  }
  *value = *string_value;
  return true;
}

bool ReadIntegerArgument(const flutter::EncodableMap& map,
                         const char* name,
                         int64_t* value) {
  const flutter::EncodableValue* encoded = FindArgument(map, name);
  if (encoded == nullptr) {
    return false;
  }
  if (const auto* int32_value = std::get_if<int32_t>(encoded)) {
    *value = *int32_value;
    return true;
  }
  if (const auto* int64_value = std::get_if<int64_t>(encoded)) {
    *value = *int64_value;
    return true;
  }
  return false;
}

}  // namespace

// static
void MusicRecognitionPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<MusicRecognitionPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

MusicRecognitionPlugin::MusicRecognitionPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      cancel_event_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {
  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar_->messenger(), kMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });

  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = MusicRecognitionPlugin::MessageWindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kMessageWindowClassName;
  if (RegisterClassExW(&window_class) != 0 ||
      GetLastError() == ERROR_CLASS_ALREADY_EXISTS) {
    message_window_ = CreateWindowExW(
        0, kMessageWindowClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
        GetModuleHandleW(nullptr), this);
  }
}

MusicRecognitionPlugin::~MusicRecognitionPlugin() {
  if (cancel_event_ != nullptr) {
    SetEvent(cancel_event_);
  }
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }
  if (message_window_ != nullptr) {
    DestroyWindow(message_window_);
    message_window_ = nullptr;
  }
  if (cancel_event_ != nullptr) {
    CloseHandle(cancel_event_);
    cancel_event_ = nullptr;
  }
  std::lock_guard<std::mutex> lock(pending_result_mutex_);
  pending_result_.reset();
}

// static
LRESULT CALLBACK MusicRecognitionPlugin::MessageWindowProc(
    HWND window,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    const auto* create_struct = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(
        window, GWLP_USERDATA,
        reinterpret_cast<LONG_PTR>(create_struct->lpCreateParams));
  }

  auto* plugin = reinterpret_cast<MusicRecognitionPlugin*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (plugin != nullptr && message == kCaptureCompleteMessage) {
    plugin->FinishCaptureOnPlatformThread();
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void MusicRecognitionPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "cancelCapture") {
    const bool was_capturing = capture_in_progress_;
    if (was_capturing && cancel_event_ != nullptr) {
      SetEvent(cancel_event_);
    }
    result->Success(flutter::EncodableValue(was_capturing));
    return;
  }

  if (call.method_name() != "capturePcm") {
    result->NotImplemented();
    return;
  }
  if (capture_in_progress_) {
    result->Error("CAPTURE_BUSY", "An audio capture is already in progress.");
    return;
  }
  if (message_window_ == nullptr || cancel_event_ == nullptr) {
    result->Error("CAPTURE_ERROR",
                  "The Windows capture worker could not be initialized.");
    return;
  }

  const auto* arguments =
      std::get_if<flutter::EncodableMap>(call.arguments());
  std::string source;
  int64_t capture_duration_ms = 0;
  int64_t wait_timeout_ms = 0;
  if (arguments == nullptr ||
      !ReadStringArgument(*arguments, "source", &source) ||
      !ReadIntegerArgument(*arguments, "captureDurationMs",
                           &capture_duration_ms) ||
      !ReadIntegerArgument(*arguments, "waitTimeoutMs", &wait_timeout_ms)) {
    result->Error(
        "INVALID_ARGUMENT",
        "capturePcm requires source, captureDurationMs, and waitTimeoutMs.");
    return;
  }
  if (source != "microphone" && source != "deviceOutput") {
    result->Error("INVALID_ARGUMENT",
                  "source must be 'microphone' or 'deviceOutput'.");
    return;
  }
  if (capture_duration_ms <= 0 ||
      capture_duration_ms > kMaximumCaptureDurationMs) {
    result->Error("INVALID_ARGUMENT",
                  "captureDurationMs must be between 1 and 60000.");
    return;
  }
  if (wait_timeout_ms < 0 || wait_timeout_ms > kMaximumWaitTimeoutMs) {
    result->Error("INVALID_ARGUMENT",
                  "waitTimeoutMs must be between 0 and 60000.");
    return;
  }

  StartCapture(source, capture_duration_ms, wait_timeout_ms,
               std::move(result));
}

void MusicRecognitionPlugin::StartCapture(
    const std::string& source,
    int64_t capture_duration_ms,
    int64_t wait_timeout_ms,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  ResetEvent(cancel_event_);
  capture_in_progress_ = true;
  const CaptureSource capture_source = source == "microphone"
                                           ? CaptureSource::kMicrophone
                                           : CaptureSource::kDeviceOutput;
  HWND const completion_window = message_window_;

  capture_thread_ = std::thread(
      [this, capture_source, capture_duration_ms, wait_timeout_ms,
       completion_window, result = std::move(result)]() mutable {
        CaptureOutcome outcome =
            CaptureWasapi(capture_source, capture_duration_ms,
                          wait_timeout_ms, cancel_event_);
        auto pending = std::make_unique<PendingCaptureResult>();
        pending->result = std::move(result);
        pending->succeeded = outcome.succeeded;
        pending->pcm_bytes = std::move(outcome.pcm_bytes);
        pending->error_code = std::move(outcome.error_code);
        pending->error_message = std::move(outcome.error_message);
        {
          std::lock_guard<std::mutex> lock(pending_result_mutex_);
          pending_result_ = std::move(pending);
        }
        if (!PostMessageW(completion_window, kCaptureCompleteMessage, 0, 0)) {
          OutputDebugStringW(
              L"[MusicRecognitionPlugin] Failed to post capture completion.\n");
        }
      });
}

void MusicRecognitionPlugin::FinishCaptureOnPlatformThread() {
  std::unique_ptr<PendingCaptureResult> pending;
  {
    std::lock_guard<std::mutex> lock(pending_result_mutex_);
    pending = std::move(pending_result_);
  }
  if (capture_thread_.joinable()) {
    capture_thread_.join();
  }
  capture_in_progress_ = false;
  if (pending == nullptr || pending->result == nullptr) {
    return;
  }
  if (pending->succeeded) {
    pending->result->Success(
        flutter::EncodableValue(std::move(pending->pcm_bytes)));
  } else {
    pending->result->Error(pending->error_code, pending->error_message);
  }
}

}  // namespace resonance
