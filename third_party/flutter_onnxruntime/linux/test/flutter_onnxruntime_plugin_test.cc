// Copyright (c) MASIC AI
// All rights reserved.
//
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "include/flutter_onnxruntime/flutter_onnxruntime_plugin.h"

// Define the macro for casting to the plugin type
#define FLUTTER_ONNXRUNTIME_PLUGIN(obj)                                                                                \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_onnxruntime_plugin_get_type(), FlutterOnnxruntimePlugin))

// This demonstrates a simple unit test of the C portion of this plugin's
// implementation.
//
// Once you have built the plugin's example app, you can run these tests
// from the command line. For instance, for a plugin called my_plugin
// built for x64 debug, run:
// $ build/linux/x64/debug/plugins/my_plugin/my_plugin_test

// Test that the plugin can be created without crashing.
TEST(FlutterOnnxruntimePlugin, BasicCreation) {
  FlutterOnnxruntimePlugin *plugin =
      FLUTTER_ONNXRUNTIME_PLUGIN(g_object_new(flutter_onnxruntime_plugin_get_type(), nullptr));
  EXPECT_NE(plugin, nullptr);
  g_object_unref(plugin);
}

// Test that the version reported matches what we expect.
TEST(FlutterOnnxruntimePlugin, GetPlatformVersion) {
  FlutterOnnxruntimePlugin *plugin =
      FLUTTER_ONNXRUNTIME_PLUGIN(g_object_new(flutter_onnxruntime_plugin_get_type(), nullptr));
  EXPECT_NE(plugin, nullptr);
  g_object_unref(plugin);
}
