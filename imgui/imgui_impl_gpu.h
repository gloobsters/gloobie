// dear imgui: Renderer Backend for SDL_GPU
// This needs to be used along with the SDL3 Platform Backend

// Implemented features:
//  [X] Renderer: User texture binding. Use simply cast a reference to your GPU_TextureSamplerBinding to ImTextureID.
//  [X] Renderer: Large meshes support (64k+ vertices) even with 16-bit indices (ImGuiBackendFlags_RendererHasVtxOffset).
//  [X] Renderer: Texture updates support for dynamic font atlas (ImGuiBackendFlags_RendererHasTextures).

// The aim of imgui_impl_sdlgpu3.h/.cpp is to be usable in your engine without any modification.
// IF YOU FEEL YOU NEED TO MAKE ANY CHANGE TO THIS CODE, please share them and your feedback at https://github.com/ocornut/imgui/

// You can use unmodified imgui_impl_* files in your project. See examples/ folder for examples of using this.
// Prefer including the entire imgui/ repository into your project (either as a copy or as a submodule), and only build the backends you need.
// Learn about Dear ImGui:
// - FAQ                  https://dearimgui.com/faq
// - Getting Started      https://dearimgui.com/getting-started
// - Documentation        https://dearimgui.com/docs (same as your local docs/ folder).
// - Introduction, links and more at the top of imgui.cpp

// Important note to the reader who wish to integrate imgui_impl_sdlgpu3.cpp/.h in their own engine/app.
// - Unlike other backends, the user must call the function ImGui_ImplSDLGPU_PrepareDrawData BEFORE issuing a GPU_RenderPass containing ImGui_ImplSDLGPU_RenderDrawData.
//   Calling the function is MANDATORY, otherwise the ImGui will not upload neither the vertex nor the index buffer for the GPU. See imgui_impl_sdlgpu3.cpp for more info.

#pragma once
#include "imgui.h" // IMGUI_IMPL_API
#ifndef IMGUI_DISABLE

#include <gpu.h>

extern "C"
{
    // Initialization data, for ImGui_ImplSDLGPU_Init()
    // - Remember to set ColorTargetFormat to the correct format. If you're rendering to the swapchain, call SDL_GetGPUSwapchainTextureFormat to query the right value
    struct ImGui_ImplGPU_InitInfo
    {
        GPU_Device *Device = nullptr;
        GPU_TextureFormat ColorTargetFormat = GPU_TEXTUREFORMAT_INVALID;
        GPU_SampleCount MSAASamples = GPU_SAMPLECOUNT_1;
    };

    // Follow "Getting Started" link and check examples/ folder to learn about using backends!
    IMGUI_IMPL_API bool ImGui_ImplGPU_Init(const ImGui_ImplGPU_InitInfo *info);
    IMGUI_IMPL_API void ImGui_ImplGPU_Shutdown();
    IMGUI_IMPL_API void ImGui_ImplGPU_NewFrame();
    IMGUI_IMPL_API void ImGui_ImplGPU_PrepareDrawData(ImDrawData *draw_data, GPU_CommandBuffer *command_buffer);
    IMGUI_IMPL_API void ImGui_ImplGPU_RenderDrawData(ImDrawData *draw_data, GPU_CommandBuffer *command_buffer, GPU_RenderPass *render_pass, GPU_GraphicsPipeline *pipeline = nullptr);

    // Use if you want to reset your rendering device without losing Dear ImGui state.
    IMGUI_IMPL_API void ImGui_ImplGPU_CreateDeviceObjects();
    IMGUI_IMPL_API void ImGui_ImplGPU_DestroyDeviceObjects();

    // (Advanced) Use e.g. if you need to precisely control the timing of texture updates (e.g. for staged rendering), by setting ImDrawData::Textures = NULL to handle this manually.
    IMGUI_IMPL_API void ImGui_ImplGPU_UpdateTexture(ImTextureData *tex);
} // extern "C"

#endif // #ifndef IMGUI_DISABLE