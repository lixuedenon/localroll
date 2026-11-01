// apps/desktop/windows/loopback/loopback.cpp
//
// LocalRoll's "sound the PC plays" recorder: Windows' own loopback capture
// of the default speakers (WASAPI), written as a 16-bit stereo WAV. No
// "Stereo Mix" setting needed. While nothing plays, Windows sends nothing:
// silence is written so the sound stays in step with the clock.
//
//   lr_loopback.exe <out.wav>
// Prints:  ready <rate>      once it is recording
//          level <0..100>    about ten times a second
//          error <what>      when it can't
// Ends when stdin closes or says "stop"; the WAV is then finished.

#ifndef UNICODE
#define UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

std::atomic<bool> g_stop{false};

template <class T>
void release(T*& p) {
  if (p) {
    p->Release();
    p = nullptr;
  }
}

void say(const std::string& s) {
  std::fputs(s.c_str(), stdout);
  std::fputc('\n', stdout);
  std::fflush(stdout);
}

struct Wav {
  FILE* f = nullptr;
  uint32_t rate = 48000;
  uint32_t bytes = 0;

  bool open(const wchar_t* path, uint32_t r) {
    rate = r;
    if (_wfopen_s(&f, path, L"wb") != 0 || !f) return false;
    header();
    return true;
  }
  void header() {
    const uint16_t ch = 2, bits = 16, align = ch * bits / 8;
    const uint32_t byteRate = rate * align, riff = 36 + bytes, fmtLen = 16;
    const uint16_t pcm = 1;
    std::fseek(f, 0, SEEK_SET);
    std::fwrite("RIFF", 1, 4, f);
    std::fwrite(&riff, 4, 1, f);
    std::fwrite("WAVEfmt ", 1, 8, f);
    std::fwrite(&fmtLen, 4, 1, f);
    std::fwrite(&pcm, 2, 1, f);
    std::fwrite(&ch, 2, 1, f);
    std::fwrite(&rate, 4, 1, f);
    std::fwrite(&byteRate, 4, 1, f);
    std::fwrite(&align, 2, 1, f);
    std::fwrite(&bits, 2, 1, f);
    std::fwrite("data", 1, 4, f);
    std::fwrite(&bytes, 4, 1, f);
    std::fseek(f, 0, SEEK_END);
  }
  void write(const int16_t* s, size_t frames) {
    std::fwrite(s, sizeof(int16_t) * 2, frames, f);
    bytes += static_cast<uint32_t>(frames * 4);
  }
  void close() {
    if (!f) return;
    header();
    std::fclose(f);
    f = nullptr;
  }
};

int16_t clip(float v) {
  v = std::max(-1.0f, std::min(1.0f, v));
  return static_cast<int16_t>(std::lround(v * 32767.0f));
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc < 2) {
    say("error usage");
    return 2;
  }
  if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {
    say("error com");
    return 1;
  }
  IMMDeviceEnumerator* en = nullptr;
  IMMDevice* dev = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* cap = nullptr;
  WAVEFORMATEX* mix = nullptr;
  Wav wav;
  int code = 0;
  do {
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&en)))) {
      say("error no devices");
      code = 1;
      break;
    }
    if (FAILED(en->GetDefaultAudioEndpoint(eRender, eConsole, &dev))) {
      say("error no speakers");
      code = 1;
      break;
    }
    if (FAILED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&client))) ||
        FAILED(client->GetMixFormat(&mix))) {
      say("error no audio client");
      code = 1;
      break;
    }
    // Float or 16-bit, any number of channels: turned into 16-bit stereo.
    bool isFloat = mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
      auto* x = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix);
      // The sub-format GUIDs carry the old format tag in their first part.
      isFloat = x->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT;
    }
    const int ch = mix->nChannels;
    const int bits = mix->wBitsPerSample;
    const uint32_t rate = mix->nSamplesPerSec;
    if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 2000000, 0, mix, nullptr)) ||
        FAILED(client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(&cap)))) {
      say("error loopback refused");
      code = 1;
      break;
    }
    if (!wav.open(argv[1], rate)) {
      say("error file");
      code = 1;
      break;
    }
    // Commands: "stop", or the end of input.
    std::thread([] {
      std::string line;
      while (std::getline(std::cin, line)) {
        if (line.rfind("stop", 0) == 0) break;
      }
      g_stop = true;
    }).detach();

    client->Start();
    LARGE_INTEGER freq, t0, now;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    char b[48];
    std::snprintf(b, sizeof b, "ready %u", rate);
    say(b);

    uint64_t written = 0;
    std::vector<int16_t> out;
    float peak = 0;
    ULONGLONG lastLevel = GetTickCount64();
    while (!g_stop) {
      Sleep(10);
      UINT32 packet = 0;
      while (SUCCEEDED(cap->GetNextPacketSize(&packet)) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (FAILED(cap->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) break;
        out.assign(static_cast<size_t>(frames) * 2, 0);
        if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && data) {
          for (UINT32 i = 0; i < frames; ++i) {
            float l = 0, r = 0;
            for (int c = 0; c < std::min(ch, 2); ++c) {
              float v;
              if (isFloat && bits == 32) {
                v = reinterpret_cast<const float*>(data)[i * ch + c];
              } else if (bits == 16) {
                v = reinterpret_cast<const int16_t*>(data)[i * ch + c] / 32768.0f;
              } else if (bits == 32) {
                v = reinterpret_cast<const int32_t*>(data)[i * ch + c] / 2147483648.0f;
              } else {
                v = 0;
              }
              (c == 0 ? l : r) = v;
            }
            if (ch == 1) r = l;
            peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
            out[i * 2] = clip(l);
            out[i * 2 + 1] = clip(r);
          }
        }
        wav.write(out.data(), frames);
        written += frames;
        cap->ReleaseBuffer(frames);
      }
      // Nothing playing: Windows sends nothing, so silence is added to
      // keep up with the clock (a little behind, for what is still coming).
      QueryPerformanceCounter(&now);
      const uint64_t due = static_cast<uint64_t>((now.QuadPart - t0.QuadPart) * static_cast<double>(rate) / freq.QuadPart);
      const uint64_t slack = rate / 10;
      if (due > written + slack) {
        const uint64_t gap = due - written - slack / 2;
        out.assign(static_cast<size_t>(gap) * 2, 0);
        wav.write(out.data(), static_cast<size_t>(gap));
        written += gap;
      }
      if (GetTickCount64() - lastLevel >= 100) {
        lastLevel = GetTickCount64();
        std::snprintf(b, sizeof b, "level %d", static_cast<int>(std::lround(std::min(1.0f, peak) * 100)));
        say(b);
        peak = 0;
      }
    }
    client->Stop();
  } while (false);
  wav.close();
  if (mix) CoTaskMemFree(mix);
  release(cap);
  release(client);
  release(dev);
  release(en);
  CoUninitialize();
  return code;
}
