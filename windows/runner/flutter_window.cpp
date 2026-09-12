#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr char kWindowsLibraryChannel[] =
    "pdf_markdown_reader/windows_library";

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(length, L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), result.data(),
                          length) <= 0) {
    return std::wstring();
  }
  return result;
}

HRESULT PickPdfFiles(HWND owner, const std::string& initial_directory,
                     std::vector<std::string>* paths) {
  IFileOpenDialog* dialog = nullptr;
  HRESULT result = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&dialog));
  if (FAILED(result)) {
    return result;
  }

  FILEOPENDIALOGOPTIONS options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    dialog->SetOptions(options | FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST |
                       FOS_PATHMUSTEXIST | FOS_FORCEFILESYSTEM);
  }
  const COMDLG_FILTERSPEC filters[] = {
      {L"PDF files (*.pdf)", L"*.pdf"},
  };
  dialog->SetFileTypes(1, filters);
  dialog->SetDefaultExtension(L"pdf");
  dialog->SetTitle(L"Import PDF files");

  const std::wstring initial_path = Utf16FromUtf8(initial_directory);
  if (!initial_path.empty()) {
    IShellItem* folder = nullptr;
    if (SUCCEEDED(SHCreateItemFromParsingName(initial_path.c_str(), nullptr,
                                              IID_PPV_ARGS(&folder)))) {
      dialog->SetDefaultFolder(folder);
      folder->Release();
    }
  }

  result = dialog->Show(owner);
  if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    dialog->Release();
    return S_OK;
  }
  if (FAILED(result)) {
    dialog->Release();
    return result;
  }

  IShellItemArray* items = nullptr;
  result = dialog->GetResults(&items);
  if (SUCCEEDED(result) && items != nullptr) {
    DWORD count = 0;
    items->GetCount(&count);
    for (DWORD index = 0; index < count; ++index) {
      IShellItem* item = nullptr;
      if (FAILED(items->GetItemAt(index, &item)) || item == nullptr) {
        continue;
      }
      PWSTR file_path = nullptr;
      if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &file_path)) &&
          file_path != nullptr) {
        paths->push_back(Utf8FromUtf16(file_path));
        CoTaskMemFree(file_path);
      }
      item->Release();
    }
    items->Release();
  }
  dialog->Release();
  return result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  windows_library_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowsLibraryChannel,
          &flutter::StandardMethodCodec::GetInstance());
  windows_library_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "pickPdfFiles") {
          result->NotImplemented();
          return;
        }
        std::string initial_directory;
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments != nullptr) {
          const auto iterator = arguments->find(
              flutter::EncodableValue("initialDirectory"));
          if (iterator != arguments->end()) {
            const auto* value = std::get_if<std::string>(&iterator->second);
            if (value != nullptr) {
              initial_directory = *value;
            }
          }
        }
        std::vector<std::string> paths;
        const HRESULT pick_result =
            PickPdfFiles(GetHandle(), initial_directory, &paths);
        if (FAILED(pick_result)) {
          result->Error("pick_pdf_failed", "Windows file dialog failed");
          return;
        }
        flutter::EncodableList encoded_paths;
        for (const auto& path : paths) {
          encoded_paths.emplace_back(path);
        }
        result->Success(flutter::EncodableValue(encoded_paths));
      });
  DragAcceptFiles(GetHandle(), TRUE);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  DragAcceptFiles(GetHandle(), FALSE);
  windows_library_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_DROPFILES: {
      const HDROP drop = reinterpret_cast<HDROP>(wparam);
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      flutter::EncodableList paths;
      for (UINT index = 0; index < count; ++index) {
        const UINT length = DragQueryFileW(drop, index, nullptr, 0);
        std::vector<wchar_t> path(length + 1, L'\0');
        if (DragQueryFileW(drop, index, path.data(), length + 1) > 0) {
          paths.emplace_back(Utf8FromUtf16(path.data()));
        }
      }
      DragFinish(drop);
      if (windows_library_channel_ && !paths.empty()) {
        windows_library_channel_->InvokeMethod(
            "filesDropped",
            std::make_unique<flutter::EncodableValue>(paths));
      }
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
