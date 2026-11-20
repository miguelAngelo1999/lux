#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>
#include <iterator>

#include "flutter_window.h"
#include "utils.h"

namespace {

struct FindLuxWindowContext {
  UINT show_msg = 0;
  DWORD current_pid = 0;
  bool found_any = false;
  bool found_visible = false;
};

struct MutexGuard {
  HANDLE handle = nullptr;
  ~MutexGuard() {
    if (handle != nullptr) {
      ::ReleaseMutex(handle);
      ::CloseHandle(handle);
    }
  }
};

bool EndsWithCaseInsensitive(const wchar_t* str, size_t str_len,
                             const wchar_t* suffix, size_t suffix_len) {
  if (str_len < suffix_len) {
    return false;
  }
  return ::_wcsicmp(str + (str_len - suffix_len), suffix) == 0;
}

bool IsLuxProcessImage(DWORD pid) {
  HANDLE proc = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (proc == nullptr) {
    return false;
  }
  wchar_t image_path[MAX_PATH * 2] = {};
  DWORD size = static_cast<DWORD>(std::size(image_path));
  BOOL ok = ::QueryFullProcessImageNameW(proc, 0, image_path, &size);
  ::CloseHandle(proc);
  if (!ok || size == 0) {
    return false;
  }
  constexpr wchar_t kExeSuffix[] = L"\\lux.exe";
  constexpr size_t kExeSuffixLen = (sizeof(kExeSuffix) / sizeof(wchar_t)) - 1;
  if (EndsWithCaseInsensitive(image_path, size, kExeSuffix, kExeSuffixLen)) {
    return true;
  }
  return ::_wcsicmp(image_path, L"lux.exe") == 0;
}

BOOL CALLBACK EnumLuxWindowsProc(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<FindLuxWindowContext*>(lparam);
  if (ctx == nullptr) {
    return TRUE;
  }

  wchar_t class_name[128] = {};
  if (::GetClassNameW(hwnd, class_name,
                      static_cast<int>(std::size(class_name))) == 0) {
    return TRUE;
  }
  if (::wcscmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) {
    return TRUE;
  }

  DWORD pid = 0;
  ::GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0 || pid == ctx->current_pid) {
    return TRUE;
  }

  bool is_lux = IsLuxProcessImage(pid);
  if (!is_lux) {
    wchar_t title[128] = {};
    int title_len =
        ::GetWindowTextW(hwnd, title, static_cast<int>(std::size(title)));
    if (title_len >= 3 && ::_wcsnicmp(title, L"Lux", 3) == 0) {
      is_lux = true;
    }
  }
  if (!is_lux) {
    return TRUE;
  }

  ::AllowSetForegroundWindow(pid);
  const BOOL posted = ::PostMessageW(hwnd, ctx->show_msg, 0, 0);
  ::ShowWindow(hwnd, SW_SHOW);
  ::ShowWindow(hwnd, SW_RESTORE);
  ::SetForegroundWindow(hwnd);

  if (posted) {
    ctx->found_any = true;
    if (::IsWindowVisible(hwnd)) {
      ctx->found_visible = true;
    }
    return FALSE;
  }
  return TRUE;
}

void FocusExistingLuxWindow(UINT show_msg) {
  FindLuxWindowContext ctx;
  ctx.show_msg = show_msg;
  ctx.current_pid = ::GetCurrentProcessId();

  // Retry briefly (~500ms) in case the first instance is mid-startup.
  for (int attempt = 0; attempt < 10; ++attempt) {
    ::EnumWindows(EnumLuxWindowsProc, reinterpret_cast<LPARAM>(&ctx));
    if (ctx.found_any) {
      break;
    }
    ::Sleep(50);
  }

  // Broadcast so a hidden or elevated Lux window wakes up across UIPI.
  if (!ctx.found_visible) {
    ::PostMessageW(HWND_BROADCAST, show_msg, 0, 0);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const UINT kShowWindowMsg = GetShowWindowMessage();

  HANDLE hMutex = ::CreateMutexW(
      nullptr, TRUE, L"Local\\com.github.igoogolx.lux.SingleInstance");
  const DWORD mutex_err = ::GetLastError();
  const bool already_running =
      (hMutex != nullptr && mutex_err == ERROR_ALREADY_EXISTS) ||
      (hMutex == nullptr && mutex_err == ERROR_ACCESS_DENIED);
  if (already_running) {
    FocusExistingLuxWindow(kShowWindowMsg);
    if (hMutex != nullptr) {
      ::CloseHandle(hMutex);
    }
    return EXIT_SUCCESS;
  }
  MutexGuard mutex_guard{hMutex};

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
  if (!window.Create(L"Lux", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
