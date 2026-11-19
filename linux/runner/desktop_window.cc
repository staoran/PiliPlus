#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>
#include <initializer_list>

namespace {

struct WindowControl {
  GtkWindow* window;
  FlMethodChannel* channel;
  int64_t view_id = 0;
  bool intercept_close = false;
  int min_width = 0;
  int min_height = 0;
  double aspect = 0;
};

FlValue* ViewArgs(const WindowControl& control) {
  auto* state = fl_value_new_map();
  fl_value_set_string_take(state, "viewId", fl_value_new_int(control.view_id));
  return state;
}

FlValue* WindowState(const WindowControl& control) {
  auto* state = ViewArgs(control);
  int x, y, width, height;
  gtk_window_get_position(control.window, &x, &y);
  gtk_window_get_size(control.window, &width, &height);
  auto* bounds = fl_value_new_list();
  for (const auto value : {x, y, width, height}) {
    fl_value_append_take(bounds, fl_value_new_int(value));
  }
  fl_value_set_string_take(state, "bounds", bounds);
  auto* native = gtk_widget_get_window(GTK_WIDGET(control.window));
  const auto flags = native ? gdk_window_get_state(native) : GdkWindowState{};
  fl_value_set_string_take(
      state, "maximized",
      fl_value_new_bool(flags & GDK_WINDOW_STATE_MAXIMIZED));
  fl_value_set_string_take(
      state, "minimized",
      fl_value_new_bool(flags & GDK_WINDOW_STATE_ICONIFIED));
  fl_value_set_string_take(
      state, "visible",
      fl_value_new_bool(gtk_widget_get_visible(GTK_WIDGET(control.window))));
  return state;
}

void Notify(const WindowControl& control, const char* method, FlValue* args) {
  g_autoptr(FlValue) owned = args;
  fl_method_channel_invoke_method(control.channel, method, owned, nullptr,
                                  nullptr, nullptr);
}

gboolean GeometryChanged(GtkWidget*, GdkEvent*, WindowControl* control) {
  Notify(*control, "windowChanged", WindowState(*control));
  return FALSE;
}

gboolean FocusChanged(GtkWidget*, GdkEvent*, WindowControl* control) {
  Notify(*control, "activated", ViewArgs(*control));
  return FALSE;
}

gboolean CloseRequested(GtkWidget*, GdkEvent*, WindowControl* control) {
  if (!control->intercept_close) return FALSE;
  Notify(*control, "closeRequested", ViewArgs(*control));
  return TRUE;
}

double Number(FlValue* value) {
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT)
    return fl_value_get_int(value);
  return fl_value_get_float(value);
}

int IntegerAt(FlValue* list, size_t index) {
  return static_cast<int>(Number(fl_value_get_list_value(list, index)));
}

void UpdateConstraints(const WindowControl& control) {
  GdkGeometry geometry{};
  geometry.min_width = control.min_width;
  geometry.min_height = control.min_height;
  auto hints = GDK_HINT_MIN_SIZE;
  if (control.aspect > 0) {
    geometry.min_aspect = geometry.max_aspect = control.aspect;
    hints = static_cast<GdkWindowHints>(hints | GDK_HINT_ASPECT);
  }
  gtk_window_set_geometry_hints(control.window, nullptr, &geometry, hints);
}

void SetTitle(GtkWindow* window, const char* title) {
  gtk_window_set_title(window, title);
  auto* bar = gtk_window_get_titlebar(window);
  if (GTK_IS_HEADER_BAR(bar))
    gtk_header_bar_set_title(GTK_HEADER_BAR(bar), title);
}

void Configure(WindowControl& control, FlValue* args) {
  const auto lookup = [args](const char* key) {
    return fl_value_lookup_string(args, key);
  };
  auto* window = control.window;
  control.view_id = fl_value_get_int(lookup("viewId"));
  control.intercept_close = fl_value_get_bool(lookup("interceptClose"));
  SetTitle(window, fl_value_get_string(lookup("title")));
  gtk_window_set_decorated(window, fl_value_get_bool(lookup("showTitleBar")));
  gtk_window_set_keep_above(window, fl_value_get_bool(lookup("alwaysOnTop")));
  auto* min_size = lookup("minimumSize");
  control.min_width = IntegerAt(min_size, 0);
  control.min_height = IntegerAt(min_size, 1);
  UpdateConstraints(control);
  auto* size = lookup("size");
  gtk_window_resize(window, IntegerAt(size, 0), IntegerAt(size, 1));
  auto* position = lookup("position");
  if (fl_value_get_type(position) == FL_VALUE_TYPE_LIST &&
      fl_value_get_length(position) >= 2) {
    gtk_window_move(window, IntegerAt(position, 0), IntegerAt(position, 1));
  } else {
    gtk_window_set_position(window, GTK_WIN_POS_CENTER);
  }
  if (fl_value_get_bool(lookup("maximized"))) gtk_window_maximize(window);
}

bool SetProperty(WindowControl& control, const char* key, FlValue* value) {
  auto* window = control.window;
  if (strcmp(key, "show") == 0) {
    if (fl_value_get_bool(value)) {
      gtk_widget_show(GTK_WIDGET(window));
      gtk_window_deiconify(window);
      gtk_window_present(window);
    } else {
      gtk_widget_hide(GTK_WIDGET(window));
    }
    Notify(control, "windowChanged", WindowState(control));
  } else if (strcmp(key, "bounds") == 0) {
    gtk_window_move(window, IntegerAt(value, 0), IntegerAt(value, 1));
    gtk_window_resize(window, IntegerAt(value, 2), IntegerAt(value, 3));
  } else if (strcmp(key, "minimumSize") == 0) {
    control.min_width = IntegerAt(value, 0);
    control.min_height = IntegerAt(value, 1);
    UpdateConstraints(control);
  } else if (strcmp(key, "contentSize") == 0) {
    gtk_window_resize(window, IntegerAt(value, 0), IntegerAt(value, 1));
  } else if (strcmp(key, "aspectRatio") == 0) {
    control.aspect = Number(value);
    UpdateConstraints(control);
  } else if (strcmp(key, "showTitleBar") == 0) {
    gtk_window_set_decorated(window, fl_value_get_bool(value));
  } else if (strcmp(key, "alwaysOnTop") == 0) {
    gtk_window_set_keep_above(window, fl_value_get_bool(value));
  } else if (strcmp(key, "fullscreen") == 0) {
    fl_value_get_bool(value) ? gtk_window_fullscreen(window)
                             : gtk_window_unfullscreen(window);
  } else if (strcmp(key, "dark") == 0) {
    g_object_set(gtk_settings_get_default(),
                 "gtk-application-prefer-dark-theme", fl_value_get_bool(value),
                 nullptr);
  } else if (strcmp(key, "title") == 0) {
    SetTitle(window, fl_value_get_string(value));
  } else if (strcmp(key, "drag") == 0) {
    auto* display = gtk_widget_get_display(GTK_WIDGET(window));
    auto* pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(display));
    int x, y;
    gdk_device_get_position(pointer, nullptr, &x, &y);
    gtk_window_begin_move_drag(window, 1, x, y, gtk_get_current_event_time());
  } else {
    return false;
  }
  return true;
}

void HandleCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto& control = *static_cast<WindowControl*>(data);
  const auto* method = fl_method_call_get_name(call);
  auto* args = fl_method_call_get_args(call);
  if (strcmp(method, "configure") == 0) {
    Configure(control, args);
  }
  if (strcmp(method, "configure") == 0 || strcmp(method, "windowState") == 0) {
    g_autoptr(FlValue) state = WindowState(control);
    fl_method_call_respond_success(call, state, nullptr);
  } else if (strcmp(method, "setWindow") == 0 &&
             SetProperty(
                 control,
                 fl_value_get_string(fl_value_lookup_string(args, "key")),
                 fl_value_lookup_string(args, "value"))) {
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

}  // namespace

void RegisterDesktopWindowControl(FlView* view, GtkWindow* window) {
  auto* messenger = fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto* channel = fl_method_channel_new(messenger, "window_control",
                                        FL_METHOD_CODEC(codec));
  auto* control = new WindowControl{window, channel};
  g_object_set_data_full(G_OBJECT(window), "pili-window-control", control,
                         [](gpointer data) {
                           auto* control = static_cast<WindowControl*>(data);
                           g_object_unref(control->channel);
                           delete control;
                         });
  fl_method_channel_set_method_call_handler(channel, HandleCall, control,
                                            nullptr);
  g_signal_connect(window, "delete-event", G_CALLBACK(CloseRequested), control);
  g_signal_connect(window, "configure-event", G_CALLBACK(GeometryChanged),
                   control);
  g_signal_connect(window, "window-state-event", G_CALLBACK(GeometryChanged),
                   control);
  g_signal_connect(window, "focus-in-event", G_CALLBACK(FocusChanged), control);
}
