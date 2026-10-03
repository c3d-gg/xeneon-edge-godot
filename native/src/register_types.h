#pragma once

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_touch_interceptor_module(ModuleInitializationLevel p_level);
void uninitialize_touch_interceptor_module(ModuleInitializationLevel p_level);
