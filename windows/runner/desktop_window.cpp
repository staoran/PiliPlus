#include "desktop_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <optional>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kChannel[] = "window_control";
constexpr UINT_PTR kSubclass = 1;

struct WindowState {
  int64_t view_id;
  flutter::BinaryMessenger* messenger;
  bool intercept_close = false;
  double min_width = 0;
  double min_height = 0;
  double aspect_ratio = 0;
  LONG_PTR normal_style = 0;
  std::optional<WINDOWPLACEMENT> fullscreen_placement;
  std::optional<RECT> initial_bounds;
};

const EncodableValue& Value(const EncodableMap& map, const char* key) {
  static const EncodableValue empty;
  const auto it = map.find(EncodableValue(key));
  return it == map.end() ? empty : it->second;
}

double Number(const EncodableValue& value) {
  if (auto number = std::get_if<double>(&value)) return *number;
  return static_cast<double>(value.TryGetLongValue().value_or(0));
}

bool Flag(const EncodableMap& map, const char* key) {
  const auto* value = std::get_if<bool>(&Value(map, key));
  return value && *value;
}

double Scale(HWND window) {
  const auto dpi = GetDpiForWindow(window);
  return dpi ? dpi / 96.0 : 1.0;
}

MONITORINFO MonitorInfo(HMONITOR monitor) {
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  GetMonitorInfo(monitor, &info);
  return info;
}

EncodableMap Describe(HWND window, int64_t view_id) {
  RECT rect{};
  GetWindowRect(window, &rect);
  const auto scale = Scale(window);
  // Positions are desktop pixels. Dimensions are in this monitor's DIPs.
  return {
      {EncodableValue("viewId"), EncodableValue(view_id)},
      {EncodableValue("bounds"),
       EncodableValue(
           EncodableList{EncodableValue(static_cast<double>(rect.left)),
                         EncodableValue(static_cast<double>(rect.top)),
                         EncodableValue((rect.right - rect.left) / scale),
                         EncodableValue((rect.bottom - rect.top) / scale)})},
      {EncodableValue("positionScale"), EncodableValue(1.0)},
      {EncodableValue("maximized"), EncodableValue(IsZoomed(window) != 0)},
      {EncodableValue("minimized"), EncodableValue(IsIconic(window) != 0)},
      {EncodableValue("visible"), EncodableValue(IsWindowVisible(window) != 0)},
  };
}

void Notify(const WindowState& state, const char* method, EncodableMap data) {
  flutter::MethodChannel<> channel(
      state.messenger, kChannel, &flutter::StandardMethodCodec::GetInstance());
  channel.InvokeMethod(method,
                       std::make_unique<EncodableValue>(std::move(data)));
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
  auto* state = reinterpret_cast<WindowState*>(data);
  switch (message) {
    case WM_CLOSE:
      if (state->intercept_close) {
        Notify(*state, "closeRequested",
               {{EncodableValue("viewId"), EncodableValue(state->view_id)}});
        return 0;
      }
      break;
    case WM_GETMINMAXINFO: {
      const auto result = DefSubclassProc(window, message, wparam, lparam);
      const auto* work = reinterpret_cast<MINMAXINFO*>(lparam);
      auto& limits = *const_cast<MINMAXINFO*>(work);
      const auto area =
          MonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST))
              .rcWork;
      limits.ptMinTrackSize.x =
          std::min(area.right - area.left,
                   std::lround(state->min_width * Scale(window)));
      limits.ptMinTrackSize.y =
          std::min(area.bottom - area.top,
                   std::lround(state->min_height * Scale(window)));
      return result;
    }
    case WM_SIZING:
      if (state->aspect_ratio > 0) {
        auto& rect = *reinterpret_cast<RECT*>(lparam);
        if (wparam == WMSZ_TOP || wparam == WMSZ_BOTTOM) {
          rect.right = rect.left + std::lround((rect.bottom - rect.top) *
                                               state->aspect_ratio);
        } else {
          const auto height =
              std::lround((rect.right - rect.left) / state->aspect_ratio);
          if (wparam == WMSZ_TOPLEFT || wparam == WMSZ_TOPRIGHT) {
            rect.top = rect.bottom - height;
          } else {
            rect.bottom = rect.top + height;
          }
        }
        return TRUE;
      }
      break;
    case WM_WINDOWPOSCHANGING:
      if (const auto bounds = state->initial_bounds) {
        auto& position = *reinterpret_cast<WINDOWPOS*>(lparam);
        if (IsWindowVisible(window)) {
          state->initial_bounds.reset();
        } else {
          if ((position.flags & SWP_NOMOVE) == 0) {
            position.x = bounds->left;
            position.y = bounds->top;
          }
          if ((position.flags & SWP_NOSIZE) == 0) {
            position.cx = bounds->right - bounds->left;
            position.cy = bounds->bottom - bounds->top;
          }
          if ((position.flags & SWP_SHOWWINDOW) != 0) {
            state->initial_bounds.reset();
          }
        }
      }
      break;
    case WM_WINDOWPOSCHANGED:
      Notify(*state, "windowChanged", Describe(window, state->view_id));
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) != WA_INACTIVE) {
        Notify(*state, "activated",
               {{EncodableValue("viewId"), EncodableValue(state->view_id)}});
      }
      break;
    case WM_DESTROY:
      RemoveWindowSubclass(window, WindowProc, id);
      delete state;
      break;
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

void SetTitle(HWND window, const std::string& title) {
  const int length =
      MultiByteToWideChar(CP_UTF8, 0, title.c_str(), -1, nullptr, 0);
  if (length <= 0) return;
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, title.c_str(), -1, wide.data(), length);
  SetWindowText(window, wide.c_str());
}

void SetTitleBar(HWND window, bool show) {
  const auto style = GetWindowLongPtr(window, GWL_STYLE);
  SetWindowLongPtr(window, GWL_STYLE,
                   show ? style | WS_CAPTION : style & ~WS_CAPTION);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);
}

void SetOnTop(HWND window, bool value) {
  SetWindowPos(window, value ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void SetFullscreen(HWND window, WindowState& state, bool value) {
  if (value == state.fullscreen_placement.has_value()) return;
  if (value) {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    GetWindowPlacement(window, &placement);
    state.fullscreen_placement = placement;
    state.normal_style = GetWindowLongPtr(window, GWL_STYLE);
    SetWindowLongPtr(window, GWL_STYLE,
                     state.normal_style & ~WS_OVERLAPPEDWINDOW);
    const auto rect =
        MonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST))
            .rcMonitor;
    SetWindowPos(window, nullptr, rect.left, rect.top, rect.right - rect.left,
                 rect.bottom - rect.top, SWP_FRAMECHANGED | SWP_NOZORDER);
  } else {
    SetWindowLongPtr(window, GWL_STYLE, state.normal_style);
    SetWindowPlacement(window, &*state.fullscreen_placement);
    state.fullscreen_placement.reset();
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOACTIVATE);
  }
}

std::optional<POINT> SavedPosition(HWND window, const EncodableMap& args) {
  const auto* position = std::get_if<EncodableList>(&Value(args, "position"));
  if (!position || position->size() < 2) return std::nullopt;
  const auto saved_scale = Number(Value(args, "legacyScale"));
  const auto scale = saved_scale > 0 ? saved_scale : Scale(window);
  POINT point{std::lround(Number((*position)[0]) * scale),
              std::lround(Number((*position)[1]) * scale)};
  const auto monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONULL);
  if (!monitor) return std::nullopt;
  auto area = MonitorInfo(monitor).rcWork;
  area.right -= 30;
  area.bottom -= 30;
  return PtInRect(&area, point) ? std::optional<POINT>(point) : std::nullopt;
}

void Configure(HWND window, WindowState& state, const EncodableMap& args) {
  state.intercept_close = Flag(args, "interceptClose");
  const auto& minimum = std::get<EncodableList>(Value(args, "minimumSize"));
  state.min_width = Number(minimum[0]);
  state.min_height = Number(minimum[1]);
  SetTitle(window, std::get<std::string>(Value(args, "title")));
  SetTitleBar(window, Flag(args, "showTitleBar"));
  SetOnTop(window, Flag(args, "alwaysOnTop"));
  const auto& size = std::get<EncodableList>(Value(args, "size"));
  auto position = SavedPosition(window, args);
  POINT cursor{};
  GetCursorPos(&cursor);
  const auto monitor =
      MonitorFromPoint(position.value_or(cursor), MONITOR_DEFAULTTONEAREST);
  const auto area = MonitorInfo(monitor).rcWork;
  const auto scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const auto width =
      std::min(area.right - area.left, std::lround(Number(size[0]) * scale));
  const auto height =
      std::min(area.bottom - area.top, std::lround(Number(size[1]) * scale));
  const auto origin = position.value_or(
      POINT{area.left + (area.right - area.left - width) / 2,
            area.top + (area.bottom - area.top - height) / 2});
  // The shrink-wrap host resizes from its first frame before showing. Keep
  // the intended outer rectangle across that resize and any initial DPI change.
  if (Flag(args, "sizeToContentOnFirstFrame")) {
    state.initial_bounds =
        RECT{origin.x, origin.y, origin.x + width, origin.y + height};
  }
  SetWindowPos(window, nullptr, origin.x, origin.y, width, height,
               SWP_NOZORDER | SWP_NOACTIVATE);
  if (Flag(args, "maximized")) ShowWindow(window, SW_MAXIMIZE);
}

bool SetProperty(HWND window, HWND content, WindowState& state,
                 const std::string& key, const EncodableValue& value) {
  if (key == "bounds") {
    const auto& rect = std::get<EncodableList>(value);
    const POINT origin{std::lround(Number(rect[0])),
                       std::lround(Number(rect[1]))};
    const auto monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTONEAREST);
    const auto scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
    SetWindowPos(window, nullptr, origin.x, origin.y,
                 std::lround(Number(rect[2]) * scale),
                 std::lround(Number(rect[3]) * scale),
                 SWP_NOZORDER | SWP_NOACTIVATE);
  } else if (key == "contentSize") {
    const auto& size = std::get<EncodableList>(value);
    const auto dpi = GetDpiForWindow(window);
    RECT rect{0, 0, std::lround(Number(size[0]) * Scale(window)),
              std::lround(Number(size[1]) * Scale(window))};
    AdjustWindowRectExForDpi(
        &rect, static_cast<DWORD>(GetWindowLongPtr(window, GWL_STYLE)), FALSE,
        static_cast<DWORD>(GetWindowLongPtr(window, GWL_EXSTYLE)), dpi);
    SetWindowPos(window, nullptr, 0, 0, rect.right - rect.left,
                 rect.bottom - rect.top,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
  } else if (key == "minimumSize") {
    const auto& size = std::get<EncodableList>(value);
    state.min_width = Number(size[0]);
    state.min_height = Number(size[1]);
  } else if (key == "aspectRatio") {
    state.aspect_ratio = Number(value);
  } else if (key == "title") {
    SetTitle(window, std::get<std::string>(value));
  } else if (key == "showTitleBar") {
    SetTitleBar(window, std::get<bool>(value));
  } else if (key == "alwaysOnTop") {
    SetOnTop(window, std::get<bool>(value));
  } else if (key == "fullscreen") {
    SetFullscreen(window, state, std::get<bool>(value));
  } else if (key == "dark") {
    const BOOL dark = std::get<bool>(value);
    DwmSetWindowAttribute(window, 20, &dark, sizeof(dark));
  } else if (key == "show") {
    if (std::get<bool>(value)) {
      if (state.initial_bounds && !IsWindowVisible(window)) return true;
      ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
      SetForegroundWindow(window);
      SetFocus(content);
    } else {
      ShowWindow(window, SW_HIDE);
    }
  } else if (key == "drag") {
    ReleaseCapture();
    PostMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
  } else {
    return false;
  }
  return true;
}

}  // namespace

void RegisterDesktopWindowControl(flutter::FlutterEngine* engine) {
  auto* messenger = engine->messenger();
  const auto registrar = engine->GetRegistrarForPlugin("PiliPlusWindowControl");
  flutter::MethodChannel<> channel(
      messenger, kChannel, &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([registrar, messenger](const auto& call,
                                                      auto result) {
    const auto& method = call.method_name();
    const auto* arguments = call.arguments();
    if (method == "getWindowHandle") {
      const auto id = arguments ? arguments->TryGetLongValue() : std::nullopt;
      const auto view =
          id ? FlutterDesktopPluginRegistrarGetViewById(registrar, *id)
             : nullptr;
      if (view) {
        result->Success(EncodableValue(reinterpret_cast<int64_t>(
            GetAncestor(FlutterDesktopViewGetHWND(view), GA_ROOT))));
      } else {
        result->Success();
      }
      return;
    }
    const auto* args =
        arguments ? std::get_if<EncodableMap>(arguments) : nullptr;
    const auto id =
        args ? Value(*args, "viewId").TryGetLongValue() : std::nullopt;
    const auto view =
        id ? FlutterDesktopPluginRegistrarGetViewById(registrar, *id) : nullptr;
    const auto content = view ? FlutterDesktopViewGetHWND(view) : nullptr;
    const auto window = content ? GetAncestor(content, GA_ROOT) : nullptr;
    if (!window) {
      result->Error("window_unavailable",
                    "The Flutter view has no top-level window.");
      return;
    }
    DWORD_PTR data = 0;
    GetWindowSubclass(window, WindowProc, kSubclass, &data);
    auto* state = reinterpret_cast<WindowState*>(data);
    if (method == "configure") {
      if (!state) {
        auto owned = std::make_unique<WindowState>();
        owned->view_id = *id;
        owned->messenger = messenger;
        if (!SetWindowSubclass(window, WindowProc, kSubclass,
                               reinterpret_cast<DWORD_PTR>(owned.get()))) {
          result->Error("window_unavailable",
                        "Could not observe the Flutter window.");
          return;
        }
        state = owned.release();
      }
      Configure(window, *state, *args);
      auto description = Describe(window, *id);
      RECT client{};
      if (state->initial_bounds && GetClientRect(window, &client)) {
        description[EncodableValue("clientSizeInPixels")] =
            EncodableValue(EncodableList{
                EncodableValue(static_cast<double>(client.right - client.left)),
                EncodableValue(
                    static_cast<double>(client.bottom - client.top))});
      }
      result->Success(EncodableValue(std::move(description)));
    } else if (method == "windowState") {
      result->Success(EncodableValue(Describe(window, *id)));
    } else if (method == "setWindow" && state &&
               SetProperty(window, content, *state,
                           std::get<std::string>(Value(*args, "key")),
                           Value(*args, "value"))) {
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}
