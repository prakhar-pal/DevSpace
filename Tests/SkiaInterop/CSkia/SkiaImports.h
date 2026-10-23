#pragma once

// Unmodified upstream headers; only the context upcast helper below adds code.
#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkTypeface.h"
#include "include/ports/SkFontMgr_fontconfig.h"
#include "include/ports/SkFontScanner_FreeType.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"

// Name concrete template specializations for Swift's C++ importer.
using SkiaSurface = sk_sp<SkSurface>;
using SkiaDirectContext = sk_sp<GrDirectContext>;
using SkiaColorSpace = sk_sp<SkColorSpace>;

// Swift cannot express C++ derived-to-base foreign reference conversions.
// This borrows the same object: no retain, release or ownership transfer.
inline GrRecordingContext* devspaceSkiaRecordingContext(GrDirectContext* context) {
    return static_cast<GrRecordingContext*>(context);
}
