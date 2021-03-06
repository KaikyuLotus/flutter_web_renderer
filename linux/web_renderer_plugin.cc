// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
#include "include/web_renderer/web_renderer_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// See web_renderer_channel.dart for documentation.
const char kChannelName[] = "flutter/windowsize";
const char kBadArgumentsError[] = "Bad Arguments";
const char kNoScreenError[] = "No Screen";
const char kSetWindowFrameMethod[] = "setWindowFrame";
const char kFrameKey[] = "frame";
const char kVisibleFrameKey[] = "visibleFrame";
const char kScaleFactorKey[] = "scaleFactor";

struct _FlWebRendererPlugin {
  GObject parent_instance;

  FlPluginRegistrar* registrar;

  // Connection to Flutter engine.
  FlMethodChannel* channel;

  // Requested window geometry.
  GdkGeometry window_geometry;
};

G_DEFINE_TYPE(FlWebRendererPlugin, fl_web_renderer_plugin, g_object_get_type())

// Gets the window being controlled.
GtkWindow* get_window(FlWebRendererPlugin* self) {
  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr) return nullptr;

  return GTK_WINDOW(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Gets the display connection.
GdkDisplay* get_display(FlWebRendererPlugin* self) {
  FlView* view = fl_plugin_registrar_get_view(self->registrar);
  if (view == nullptr) return nullptr;

  return gtk_widget_get_display(GTK_WIDGET(view));
}

// Converts frame dimensions into the Flutter representation.
FlValue* make_frame_value(gint x, gint y, gint width, gint height) {
  g_autoptr(FlValue) value = fl_value_new_list();

  fl_value_append_take(value, fl_value_new_float(x));
  fl_value_append_take(value, fl_value_new_float(y));
  fl_value_append_take(value, fl_value_new_float(width));
  fl_value_append_take(value, fl_value_new_float(height));

  return fl_value_ref(value);
}

// Converts monitor information into the Flutter representation.
FlValue* make_monitor_value(GdkMonitor* monitor) {
  g_autoptr(FlValue) value = fl_value_new_map();

  GdkRectangle frame;
  gdk_monitor_get_geometry(monitor, &frame);
  fl_value_set_string_take(
      value, kFrameKey,
      make_frame_value(frame.x, frame.y, frame.width, frame.height));

  gdk_monitor_get_workarea(monitor, &frame);
  fl_value_set_string_take(
      value, kVisibleFrameKey,
      make_frame_value(frame.x, frame.y, frame.width, frame.height));

  gint scale_factor = gdk_monitor_get_scale_factor(monitor);
  fl_value_set_string_take(value, kScaleFactorKey,
                           fl_value_new_float(scale_factor));

  return fl_value_ref(value);
}

// Sets the window position and dimensions.
static FlMethodResponse* set_window_frame(FlWebRendererPlugin* self,
                                          FlValue* args) {
  if (fl_value_get_type(args) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(args) != 4) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        kBadArgumentsError, "Expected 4-element list", nullptr));
  }
  double x = fl_value_get_float(fl_value_get_list_value(args, 0));
  double y = fl_value_get_float(fl_value_get_list_value(args, 1));
  double width = fl_value_get_float(fl_value_get_list_value(args, 2));
  double height = fl_value_get_float(fl_value_get_list_value(args, 3));

  GtkWindow* window = get_window(self);
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new(kNoScreenError, nullptr, nullptr));
  }

  gtk_window_move(window, static_cast<gint>(x), static_cast<gint>(y));
  gtk_window_resize(window, static_cast<gint>(width),
                    static_cast<gint>(height));

  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// Called when a method call is received from Flutter.
static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  FlWebRendererPlugin* self = FL_WEB_RENDERER_PLUGIN(user_data);

  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, kSetWindowFrameMethod) == 0) {
    response = set_window_frame(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error))
    g_warning("Failed to send method call response: %s", error->message);
}

static void fl_web_renderer_plugin_dispose(GObject* object) {
  FlWebRendererPlugin* self = FL_WEB_RENDERER_PLUGIN(object);

  g_clear_object(&self->registrar);
  g_clear_object(&self->channel);

  G_OBJECT_CLASS(fl_web_renderer_plugin_parent_class)->dispose(object);
}

static void fl_web_renderer_plugin_class_init(FlWebRendererPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = fl_web_renderer_plugin_dispose;
}

static void fl_web_renderer_plugin_init(FlWebRendererPlugin* self) {
  self->window_geometry.min_width = -1;
  self->window_geometry.min_height = -1;
  self->window_geometry.max_width = G_MAXINT;
  self->window_geometry.max_height = G_MAXINT;
}

FlWebRendererPlugin* fl_web_renderer_plugin_new(FlPluginRegistrar* registrar) {
  FlWebRendererPlugin* self = FL_WEB_RENDERER_PLUGIN(
      g_object_new(fl_web_renderer_plugin_get_type(), nullptr));

  self->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb,
                                            g_object_ref(self), g_object_unref);

  return self;
}

void web_renderer_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  FlWebRendererPlugin* plugin = fl_web_renderer_plugin_new(registrar);
  g_object_unref(plugin);
}
