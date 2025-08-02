#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include <cimgui.h>

#include <SDL3/SDL.h>

#include <gpu.h>

typedef enum
{
    ImGui_ImplSDL3_GamepadMode_AutoFirst,
    ImGui_ImplSDL3_GamepadMode_AutoAll,
    ImGui_ImplSDL3_GamepadMode_Manual
} ImGui_ImplSDL3_GamepadMode;

CIMGUI_API bool ImGui_ImplSDL3_InitForOpenGL(SDL_Window *window, void *sdl_gl_context);
CIMGUI_API bool ImGui_ImplSDL3_InitForVulkan(SDL_Window *window);
CIMGUI_API bool ImGui_ImplSDL3_InitForD3D(SDL_Window *window);
CIMGUI_API bool ImGui_ImplSDL3_InitForMetal(SDL_Window *window);
CIMGUI_API bool ImGui_ImplSDL3_InitForSDLRenderer(SDL_Window *window, SDL_Renderer *renderer);
CIMGUI_API bool ImGui_ImplSDL3_InitForSDLGPU(SDL_Window *window);
CIMGUI_API bool ImGui_ImplSDL3_InitForOther(SDL_Window *window);
CIMGUI_API void ImGui_ImplSDL3_Shutdown(void);
CIMGUI_API void ImGui_ImplSDL3_NewFrame(void);
CIMGUI_API bool ImGui_ImplSDL3_ProcessEvent(const SDL_Event *event);
CIMGUI_API void ImGui_ImplSDL3_SetGamepadMode(ImGui_ImplSDL3_GamepadMode mode, SDL_Gamepad **manual_gamepads_array, int manual_gamepads_count);

// Initialization data, for ImGui_ImplSDLGPU_Init()
// - Remember to set ColorTargetFormat to the correct format. If you're rendering to the swapchain, call SDL_GetGPUSwapchainTextureFormat to query the right value
struct ImGui_ImplGPU_InitInfo
{
    GPU_Device *Device;
    GPU_TextureFormat ColorTargetFormat;
    GPU_SampleCount MSAASamples;
};

// Follow "Getting Started" link and check examples/ folder to learn about using backends!
CIMGUI_API bool ImGui_ImplGPU_Init(struct ImGui_ImplGPU_InitInfo *info);
CIMGUI_API void ImGui_ImplGPU_Shutdown();
CIMGUI_API void ImGui_ImplGPU_NewFrame();
CIMGUI_API void ImGui_ImplGPU_PrepareDrawData(ImDrawData *draw_data, GPU_CommandBuffer *command_buffer);
CIMGUI_API void ImGui_ImplGPU_RenderDrawData(ImDrawData *draw_data, GPU_CommandBuffer *command_buffer, GPU_RenderPass *render_pass, GPU_GraphicsPipeline *pipeline);

// Use if you want to reset your rendering device without losing Dear ImGui state.
CIMGUI_API void ImGui_ImplGPU_CreateDeviceObjects();
CIMGUI_API void ImGui_ImplGPU_DestroyDeviceObjects();

// (Advanced) Use e.g. if you need to precisely control the timing of texture updates (e.g. for staged rendering), by setting ImDrawData::Textures = NULL to handle this manually.
CIMGUI_API void ImGui_ImplGPU_UpdateTexture(ImTextureData *tex);
