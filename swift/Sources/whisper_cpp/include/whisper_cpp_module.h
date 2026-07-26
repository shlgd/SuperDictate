// Umbrella header for the whisper_cpp SwiftPM target.
//
// This intentionally only pulls in the C headers whisper.cpp/ggml
// actually need to be *called* from Swift (Task 3's WhisperEngine).
// It deliberately does NOT include ggml-cpp.h (C++-only, std::unique_ptr,
// would fail import as C), nor any backend header other than the CPU
// one (ggml-metal.h / ggml-cuda.h / ggml-vulkan.h / etc. must never be
// reachable from this module — this fork is CPU-only, see
// Package.swift's GGML_USE_CPU / GGML_USE_ACCELERATE defines).
#ifndef WHISPER_CPP_MODULE_H
#define WHISPER_CPP_MODULE_H

#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-opt.h"
#include "gguf.h"
#include "whisper.h"

#endif
