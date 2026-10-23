#pragma once

// Declarations only: no wrapper implementation and no changes to Skia headers.
#include "include/core/SkCanvas.h"
#include "include/core/SkFont.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"

// Name concrete template specializations for Swift's C++ importer.
using SkiaSurface = sk_sp<SkSurface>;
using SkiaDirectContext = sk_sp<GrDirectContext>;
