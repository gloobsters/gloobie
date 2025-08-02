#ifdef GPU_VULKAN
#define XR_USE_GRAPHICS_API_VULKAN
#endif

#ifdef PLATFORM_LINUX
#define XR_USE_PLATFORM_XLIB
#define XR_USE_PLATFORM_XCB
#define XR_USE_PLATFORM_WAYLAND
#endif

#ifdef PLATFORM_WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define XR_USE_PLATFORM_WIN32
#endif

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
