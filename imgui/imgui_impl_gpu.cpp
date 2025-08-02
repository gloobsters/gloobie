// dear imgui: Renderer Backend for Gloobie's GPU abstraction (forked from SDL_gpu)
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
// - Unlike other backends, the user must call the function ImGui_ImplGPU_PrepareDrawData() BEFORE issuing a GPU_RenderPass containing ImGui_ImplGPU_RenderDrawData.
//   Calling the function is MANDATORY, otherwise the ImGui will not upload neither the vertex nor the index buffer for the GPU. See imgui_impl_sdlgpu3.cpp for more info.

// CHANGELOG
//  2025-08-02: Port to Gloobie's GPU fork.
//  2025-06-25: Mapping transfer buffer for texture update use cycle=true. Fixes artifacts e.g. on Metal backend.
//  2025-06-11: Added support for ImGuiBackendFlags_RendererHasTextures, for dynamic font atlas. Removed ImGui_ImplGPU_CreateFontsTexture() and ImGui_ImplGPU_DestroyFontsTexture().
//  2025-04-28: Added support for special ImDrawCallback_ResetRenderState callback to reset render state.
//  2025-03-30: Made ImGui_ImplGPU_PrepareDrawData() reuse GPU Transfer Buffers which were unusually slow to recreate every frame. Much faster now.
//  2025-03-21: Fixed typo in function name ImGui_ImplGPU_PrepareDrawData() -> ImGui_ImplGPU_PrepareDrawData().
//  2025-01-16: Renamed ImGui_ImplGPU_InitInfo::GpuDevice to Device.
//  2025-01-09: SDL_GPU: Added the SDL_GPU3 backend.

#include "imgui.h"
#ifndef IMGUI_DISABLE
#include "imgui_impl_gpu.h"
#include "imgui_impl_gpu_shaders.h"

// SDL_GPU Data
struct ImGui_ImplGPU_Texture
{
    GPU_Texture *Texture = nullptr;
    GPU_TextureSamplerBinding TextureSamplerBinding = {nullptr, nullptr};
};

// Reusable buffers used for rendering 1 current in-flight frame, for ImGui_ImplGPU_RenderDrawData()
struct ImGui_ImplGPU_FrameData
{
    GPU_Buffer *VertexBuffer = nullptr;
    GPU_TransferBuffer *VertexTransferBuffer = nullptr;
    uint32_t VertexBufferSize = 0;
    GPU_Buffer *IndexBuffer = nullptr;
    GPU_TransferBuffer *IndexTransferBuffer = nullptr;
    uint32_t IndexBufferSize = 0;
};

struct ImGui_ImplGPU_Data
{
    ImGui_ImplGPU_InitInfo InitInfo;

    // Graphics pipeline & shaders
    GPU_Shader *VertexShader = nullptr;
    GPU_Shader *FragmentShader = nullptr;
    GPU_GraphicsPipeline *Pipeline = nullptr;
    GPU_Sampler *TexSampler = nullptr;
    GPU_TransferBuffer *TexTransferBuffer = nullptr;
    uint32_t TexTransferBufferSize = 0;

    // Frame data for main window
    ImGui_ImplGPU_FrameData MainWindowFrameData;
};

// Forward Declarations
static void ImGui_ImplGPU_DestroyFrameData();

//-----------------------------------------------------------------------------
// FUNCTIONS
//-----------------------------------------------------------------------------

extern "C"
{

    // Backend data stored in io.BackendRendererUserData to allow support for multiple Dear ImGui contexts
    // It is STRONGLY preferred that you use docking branch with multi-viewports (== single Dear ImGui context + multiple windows) instead of multiple Dear ImGui contexts.
    // FIXME: multi-context support has never been tested.
    static ImGui_ImplGPU_Data *ImGui_ImplGPU_GetBackendData()
    {
        return ImGui::GetCurrentContext() ? (ImGui_ImplGPU_Data *)ImGui::GetIO().BackendRendererUserData : nullptr;
    }

    static void ImGui_ImplGPU_SetupRenderState(ImDrawData *draw_data, GPU_GraphicsPipeline *pipeline, GPU_CommandBuffer *command_buffer, GPU_RenderPass *render_pass, ImGui_ImplGPU_FrameData *fd, uint32_t fb_width, uint32_t fb_height)
    {
        // ImGui_ImplGPU_Data* bd = ImGui_ImplGPU_GetBackendData();

        // Bind graphics pipeline
        GPU_BindGraphicsPipeline(render_pass, pipeline);

        // Bind Vertex And Index Buffers
        if (draw_data->TotalVtxCount > 0)
        {
            GPU_BufferBinding vertex_buffer_binding = {};
            vertex_buffer_binding.buffer = fd->VertexBuffer;
            vertex_buffer_binding.offset = 0;
            GPU_BufferBinding index_buffer_binding = {};
            index_buffer_binding.buffer = fd->IndexBuffer;
            index_buffer_binding.offset = 0;
            GPU_BindVertexBuffers(render_pass, 0, &vertex_buffer_binding, 1);
            GPU_BindIndexBuffer(render_pass, &index_buffer_binding, sizeof(ImDrawIdx) == 2 ? GPU_INDEXELEMENTSIZE_16BIT : GPU_INDEXELEMENTSIZE_32BIT);
        }

        // Setup viewport
        GPU_Viewport viewport = {};
        viewport.x = 0;
        viewport.y = 0;
        viewport.w = (float)fb_width;
        viewport.h = (float)fb_height;
        viewport.min_depth = 0.0f;
        viewport.max_depth = 1.0f;
        GPU_SetViewport(render_pass, &viewport);

        // Setup scale and translation
        // Our visible imgui space lies from draw_data->DisplayPps (top left) to draw_data->DisplayPos+data_data->DisplaySize (bottom right). DisplayPos is (0,0) for single viewport apps.
        struct UBO
        {
            float scale[2];
            float translation[2];
        } ubo;
        ubo.scale[0] = 2.0f / draw_data->DisplaySize.x;
        ubo.scale[1] = 2.0f / draw_data->DisplaySize.y;
        ubo.translation[0] = -1.0f - draw_data->DisplayPos.x * ubo.scale[0];
        ubo.translation[1] = -1.0f - draw_data->DisplayPos.y * ubo.scale[1];
        GPU_PushVertexUniformData(command_buffer, 0, &ubo, sizeof(UBO));
    }

    static void CreateOrResizeBuffers(GPU_Buffer **buffer, GPU_TransferBuffer **transferbuffer, uint32_t *old_size, uint32_t new_size, GPU_BufferUsageFlags usage)
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_InitInfo *v = &bd->InitInfo;

        // FIXME-OPT: Not optimal, but this is fairly rarely called.
        GPU_WaitForIdle(v->Device);
        GPU_ReleaseBuffer(v->Device, *buffer);
        GPU_ReleaseTransferBuffer(v->Device, *transferbuffer);

        GPU_BufferCreateInfo buffer_info = {};
        buffer_info.usage = usage;
        buffer_info.size = new_size;
        buffer_info.props = 0;
        *buffer = GPU_CreateBuffer(v->Device, &buffer_info);
        *old_size = new_size;
        IM_ASSERT(*buffer != nullptr && "Failed to create GPU Buffer, call SDL_GetError() for more information");

        GPU_TransferBufferCreateInfo transferbuffer_info = {};
        transferbuffer_info.usage = GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        transferbuffer_info.size = new_size;
        *transferbuffer = GPU_CreateTransferBuffer(v->Device, &transferbuffer_info);
        IM_ASSERT(*transferbuffer != nullptr && "Failed to create GPU Transfer Buffer, call SDL_GetError() for more information");
    }

    // SDL_GPU doesn't allow copy passes to occur while a render or compute pass is bound!
    // The only way to allow a user to supply their own RenderPass (to render to a texture instead of the window for example),
    // is to split the upload part of ImGui_ImplGPU_RenderDrawData() to another function that needs to be called by the user before rendering.
    void ImGui_ImplGPU_PrepareDrawData(ImDrawData *draw_data, GPU_CommandBuffer *command_buffer)
    {
        // Avoid rendering when minimized, scale coordinates for retina displays (screen coordinates != framebuffer coordinates)
        int fb_width = (int)(draw_data->DisplaySize.x * draw_data->FramebufferScale.x);
        int fb_height = (int)(draw_data->DisplaySize.y * draw_data->FramebufferScale.y);
        if (fb_width <= 0 || fb_height <= 0 || draw_data->TotalVtxCount <= 0)
            return;

        // Catch up with texture updates. Most of the times, the list will have 1 element with an OK status, aka nothing to do.
        // (This almost always points to ImGui::GetPlatformIO().Textures[] but is part of ImDrawData to allow overriding or disabling texture updates).
        if (draw_data->Textures != nullptr)
            for (ImTextureData *tex : *draw_data->Textures)
                if (tex->Status != ImTextureStatus_OK)
                    ImGui_ImplGPU_UpdateTexture(tex);

        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_InitInfo *v = &bd->InitInfo;
        ImGui_ImplGPU_FrameData *fd = &bd->MainWindowFrameData;

        uint32_t vertex_size = draw_data->TotalVtxCount * sizeof(ImDrawVert);
        uint32_t index_size = draw_data->TotalIdxCount * sizeof(ImDrawIdx);
        if (fd->VertexBuffer == nullptr || fd->VertexBufferSize < vertex_size)
            CreateOrResizeBuffers(&fd->VertexBuffer, &fd->VertexTransferBuffer, &fd->VertexBufferSize, vertex_size, GPU_BUFFERUSAGE_VERTEX);
        if (fd->IndexBuffer == nullptr || fd->IndexBufferSize < index_size)
            CreateOrResizeBuffers(&fd->IndexBuffer, &fd->IndexTransferBuffer, &fd->IndexBufferSize, index_size, GPU_BUFFERUSAGE_INDEX);

        ImDrawVert *vtx_dst = (ImDrawVert *)GPU_MapTransferBuffer(v->Device, fd->VertexTransferBuffer, true);
        ImDrawIdx *idx_dst = (ImDrawIdx *)GPU_MapTransferBuffer(v->Device, fd->IndexTransferBuffer, true);
        for (const ImDrawList *draw_list : draw_data->CmdLists)
        {
            memcpy(vtx_dst, draw_list->VtxBuffer.Data, draw_list->VtxBuffer.Size * sizeof(ImDrawVert));
            memcpy(idx_dst, draw_list->IdxBuffer.Data, draw_list->IdxBuffer.Size * sizeof(ImDrawIdx));
            vtx_dst += draw_list->VtxBuffer.Size;
            idx_dst += draw_list->IdxBuffer.Size;
        }
        GPU_UnmapTransferBuffer(v->Device, fd->VertexTransferBuffer);
        GPU_UnmapTransferBuffer(v->Device, fd->IndexTransferBuffer);

        GPU_TransferBufferLocation vertex_buffer_location = {};
        vertex_buffer_location.offset = 0;
        vertex_buffer_location.transfer_buffer = fd->VertexTransferBuffer;
        GPU_TransferBufferLocation index_buffer_location = {};
        index_buffer_location.offset = 0;
        index_buffer_location.transfer_buffer = fd->IndexTransferBuffer;

        GPU_BufferRegion vertex_buffer_region = {};
        vertex_buffer_region.buffer = fd->VertexBuffer;
        vertex_buffer_region.offset = 0;
        vertex_buffer_region.size = vertex_size;

        GPU_BufferRegion index_buffer_region = {};
        index_buffer_region.buffer = fd->IndexBuffer;
        index_buffer_region.offset = 0;
        index_buffer_region.size = index_size;

        GPU_CopyPass *copy_pass = GPU_BeginCopyPass(command_buffer);
        GPU_UploadToBuffer(copy_pass, &vertex_buffer_location, &vertex_buffer_region, true);
        GPU_UploadToBuffer(copy_pass, &index_buffer_location, &index_buffer_region, true);
        GPU_EndCopyPass(copy_pass);
    }

    void ImGui_ImplGPU_RenderDrawData(ImDrawData *draw_data, GPU_CommandBuffer *command_buffer, GPU_RenderPass *render_pass, GPU_GraphicsPipeline *pipeline)
    {
        // Avoid rendering when minimized, scale coordinates for retina displays (screen coordinates != framebuffer coordinates)
        int fb_width = (int)(draw_data->DisplaySize.x * draw_data->FramebufferScale.x);
        int fb_height = (int)(draw_data->DisplaySize.y * draw_data->FramebufferScale.y);
        if (fb_width <= 0 || fb_height <= 0)
            return;

        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_FrameData *fd = &bd->MainWindowFrameData;

        if (pipeline == nullptr)
            pipeline = bd->Pipeline;

        ImGui_ImplGPU_SetupRenderState(draw_data, pipeline, command_buffer, render_pass, fd, fb_width, fb_height);

        // Will project scissor/clipping rectangles into framebuffer space
        ImVec2 clip_off = draw_data->DisplayPos;         // (0,0) unless using multi-viewports
        ImVec2 clip_scale = draw_data->FramebufferScale; // (1,1) unless using retina display which are often (2,2)

        // Render command lists
        // (Because we merged all buffers into a single one, we maintain our own offset into them)
        int global_vtx_offset = 0;
        int global_idx_offset = 0;
        for (const ImDrawList *draw_list : draw_data->CmdLists)
        {
            for (int cmd_i = 0; cmd_i < draw_list->CmdBuffer.Size; cmd_i++)
            {
                const ImDrawCmd *pcmd = &draw_list->CmdBuffer[cmd_i];
                if (pcmd->UserCallback != nullptr)
                {
                    // User callback, registered via ImDrawList::AddCallback()
                    // (ImDrawCallback_ResetRenderState is a special callback value used by the user to request the renderer to reset render state.)
                    if (pcmd->UserCallback == ImDrawCallback_ResetRenderState)
                        ImGui_ImplGPU_SetupRenderState(draw_data, pipeline, command_buffer, render_pass, fd, fb_width, fb_height);
                    else
                        pcmd->UserCallback(draw_list, pcmd);
                }
                else
                {
                    // Project scissor/clipping rectangles into framebuffer space
                    ImVec2 clip_min((pcmd->ClipRect.x - clip_off.x) * clip_scale.x, (pcmd->ClipRect.y - clip_off.y) * clip_scale.y);
                    ImVec2 clip_max((pcmd->ClipRect.z - clip_off.x) * clip_scale.x, (pcmd->ClipRect.w - clip_off.y) * clip_scale.y);

                    // Clamp to viewport as GPU_SetScissor() won't accept values that are off bounds
                    if (clip_min.x < 0.0f)
                    {
                        clip_min.x = 0.0f;
                    }
                    if (clip_min.y < 0.0f)
                    {
                        clip_min.y = 0.0f;
                    }
                    if (clip_max.x > fb_width)
                    {
                        clip_max.x = (float)fb_width;
                    }
                    if (clip_max.y > fb_height)
                    {
                        clip_max.y = (float)fb_height;
                    }
                    if (clip_max.x <= clip_min.x || clip_max.y <= clip_min.y)
                        continue;

                    // Apply scissor/clipping rectangle
                    SDL_Rect scissor_rect = {};
                    scissor_rect.x = (int)clip_min.x;
                    scissor_rect.y = (int)clip_min.y;
                    scissor_rect.w = (int)(clip_max.x - clip_min.x);
                    scissor_rect.h = (int)(clip_max.y - clip_min.y);
                    GPU_SetScissor(render_pass, &scissor_rect);

                    // Bind DescriptorSet with font or user texture
                    GPU_BindFragmentSamplers(render_pass, 0, (GPU_TextureSamplerBinding *)pcmd->GetTexID(), 1);

                    // Draw
                    GPU_DrawIndexedPrimitives(render_pass, pcmd->ElemCount, 1, pcmd->IdxOffset + global_idx_offset, pcmd->VtxOffset + global_vtx_offset, 0);
                }
            }
            global_idx_offset += draw_list->IdxBuffer.Size;
            global_vtx_offset += draw_list->VtxBuffer.Size;
        }

        // Note: at this point both GPU_SetViewport() and GPU_SetScissor() have been called.
        // Our last values will leak into user/application rendering if you forgot to call GPU_SetViewport() and GPU_SetScissor() yourself to explicitly set that state
        // In theory we should aim to backup/restore those values but I am not sure this is possible.
        // We perform a call to GPU_SetScissor() to set back a full viewport which is likely to fix things for 99% users but technically this is not perfect. (See github #4644)
        SDL_Rect scissor_rect{0, 0, fb_width, fb_height};
        GPU_SetScissor(render_pass, &scissor_rect);
    }

    static void ImGui_ImplGPU_DestroyTexture(ImTextureData *tex)
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_Texture *backend_tex = (ImGui_ImplGPU_Texture *)tex->BackendUserData;
        if (backend_tex == nullptr)
            return;
        GPU_TextureSamplerBinding *binding = (GPU_TextureSamplerBinding *)(intptr_t)tex->BackendUserData;
        IM_ASSERT(backend_tex->Texture == binding->texture);
        GPU_ReleaseTexture(bd->InitInfo.Device, backend_tex->Texture);
        IM_DELETE(backend_tex);

        // Clear identifiers and mark as destroyed (in order to allow e.g. calling InvalidateDeviceObjects while running)
        tex->SetTexID(ImTextureID_Invalid);
        tex->SetStatus(ImTextureStatus_Destroyed);
        tex->BackendUserData = nullptr;
    }

    void ImGui_ImplGPU_UpdateTexture(ImTextureData *tex)
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_InitInfo *v = &bd->InitInfo;

        if (tex->Status == ImTextureStatus_WantCreate)
        {
            // Create and upload new texture to graphics system
            // IMGUI_DEBUG_LOG("UpdateTexture #%03d: WantCreate %dx%d\n", tex->UniqueID, tex->Width, tex->Height);
            IM_ASSERT(tex->TexID == ImTextureID_Invalid && tex->BackendUserData == nullptr);
            IM_ASSERT(tex->Format == ImTextureFormat_RGBA32);
            ImGui_ImplGPU_Texture *backend_tex = IM_NEW(ImGui_ImplGPU_Texture)();

            // Create texture
            GPU_TextureCreateInfo texture_info = {};
            texture_info.type = GPU_TEXTURETYPE_2D;
            texture_info.format = GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
            texture_info.usage = GPU_TEXTUREUSAGE_SAMPLER;
            texture_info.width = tex->Width;
            texture_info.height = tex->Height;
            texture_info.layer_count_or_depth = 1;
            texture_info.num_levels = 1;
            texture_info.sample_count = GPU_SAMPLECOUNT_1;

            backend_tex->Texture = GPU_CreateTexture(v->Device, &texture_info);
            backend_tex->TextureSamplerBinding.texture = backend_tex->Texture;
            backend_tex->TextureSamplerBinding.sampler = bd->TexSampler;
            IM_ASSERT(backend_tex->Texture && "Failed to create font texture, call SDL_GetError() for more info");

            // Store identifiers
            tex->SetTexID((ImTextureID)(intptr_t)&backend_tex->TextureSamplerBinding);
            tex->BackendUserData = backend_tex;
        }

        if (tex->Status == ImTextureStatus_WantCreate || tex->Status == ImTextureStatus_WantUpdates)
        {
            ImGui_ImplGPU_Texture *backend_tex = (ImGui_ImplGPU_Texture *)tex->BackendUserData;
            IM_ASSERT(tex->Format == ImTextureFormat_RGBA32);

            // Update full texture or selected blocks. We only ever write to textures regions which have never been used before!
            // This backend choose to use tex->UpdateRect but you can use tex->Updates[] to upload individual regions.
            // We could use the smaller rect on _WantCreate but using the full rect allows us to clear the texture.
            const int upload_x = (tex->Status == ImTextureStatus_WantCreate) ? 0 : tex->UpdateRect.x;
            const int upload_y = (tex->Status == ImTextureStatus_WantCreate) ? 0 : tex->UpdateRect.y;
            const int upload_w = (tex->Status == ImTextureStatus_WantCreate) ? tex->Width : tex->UpdateRect.w;
            const int upload_h = (tex->Status == ImTextureStatus_WantCreate) ? tex->Height : tex->UpdateRect.h;
            uint32_t upload_pitch = upload_w * tex->BytesPerPixel;
            uint32_t upload_size = upload_w * upload_h * tex->BytesPerPixel;

            // Create transfer buffer
            if (bd->TexTransferBufferSize < upload_size)
            {
                GPU_ReleaseTransferBuffer(v->Device, bd->TexTransferBuffer);
                GPU_TransferBufferCreateInfo transferbuffer_info = {};
                transferbuffer_info.usage = GPU_TRANSFERBUFFERUSAGE_UPLOAD;
                transferbuffer_info.size = upload_size + 1024;
                bd->TexTransferBufferSize = upload_size + 1024;
                bd->TexTransferBuffer = GPU_CreateTransferBuffer(v->Device, &transferbuffer_info);
                IM_ASSERT(bd->TexTransferBuffer != nullptr && "Failed to create font transfer buffer, call SDL_GetError() for more information");
            }

            // Copy to transfer buffer
            {
                void *texture_ptr = GPU_MapTransferBuffer(v->Device, bd->TexTransferBuffer, true);
                for (int y = 0; y < upload_h; y++)
                    memcpy((void *)((uintptr_t)texture_ptr + y * upload_pitch), tex->GetPixelsAt(upload_x, upload_y + y), upload_pitch);
                GPU_UnmapTransferBuffer(v->Device, bd->TexTransferBuffer);
            }

            GPU_TextureTransferInfo transfer_info = {};
            transfer_info.offset = 0;
            transfer_info.transfer_buffer = bd->TexTransferBuffer;

            GPU_TextureRegion texture_region = {};
            texture_region.texture = backend_tex->Texture;
            texture_region.x = (Uint32)upload_x;
            texture_region.y = (Uint32)upload_y;
            texture_region.w = (Uint32)upload_w;
            texture_region.h = (Uint32)upload_h;
            texture_region.d = 1;

            // Upload
            {
                GPU_CommandBuffer *cmd = GPU_AcquireCommandBuffer(v->Device);
                GPU_CopyPass *copy_pass = GPU_BeginCopyPass(cmd);
                GPU_UploadToTexture(copy_pass, &transfer_info, &texture_region, false);
                GPU_EndCopyPass(copy_pass);
                GPU_SubmitCommandBuffer(cmd);
            }

            tex->SetStatus(ImTextureStatus_OK);
        }
        if (tex->Status == ImTextureStatus_WantDestroy && tex->UnusedFrames > 0)
            ImGui_ImplGPU_DestroyTexture(tex);
    }

    static void ImGui_ImplGPU_CreateShaders()
    {
        // Create the shader modules
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_InitInfo *v = &bd->InitInfo;

        const char *driver = GPU_GetDeviceDriver(v->Device);

        GPU_ShaderCreateInfo vertex_shader_info = {};
        vertex_shader_info.entrypoint = "main";
        vertex_shader_info.stage = GPU_SHADERSTAGE_VERTEX;
        vertex_shader_info.num_uniform_buffers = 1;
        vertex_shader_info.num_storage_buffers = 0;
        vertex_shader_info.num_storage_textures = 0;
        vertex_shader_info.num_samplers = 0;

        GPU_ShaderCreateInfo fragment_shader_info = {};
        fragment_shader_info.entrypoint = "main";
        fragment_shader_info.stage = GPU_SHADERSTAGE_FRAGMENT;
        fragment_shader_info.num_samplers = 1;
        fragment_shader_info.num_storage_buffers = 0;
        fragment_shader_info.num_storage_textures = 0;
        fragment_shader_info.num_uniform_buffers = 0;

        if (strcmp(driver, "vulkan") == 0)
        {
            vertex_shader_info.format = GPU_SHADERFORMAT_SPIRV;
            vertex_shader_info.code = spirv_vertex;
            vertex_shader_info.code_size = sizeof(spirv_vertex);
            fragment_shader_info.format = GPU_SHADERFORMAT_SPIRV;
            fragment_shader_info.code = spirv_fragment;
            fragment_shader_info.code_size = sizeof(spirv_fragment);
        }
        else if (strcmp(driver, "direct3d12") == 0)
        {
            vertex_shader_info.format = GPU_SHADERFORMAT_DXBC;
            vertex_shader_info.code = dxbc_vertex;
            vertex_shader_info.code_size = sizeof(dxbc_vertex);
            fragment_shader_info.format = GPU_SHADERFORMAT_DXBC;
            fragment_shader_info.code = dxbc_fragment;
            fragment_shader_info.code_size = sizeof(dxbc_fragment);
        }
#ifdef __APPLE__
        else
        {
            vertex_shader_info.entrypoint = "main0";
            vertex_shader_info.format = GPU_SHADERFORMAT_METALLIB;
            vertex_shader_info.code = metallib_vertex;
            vertex_shader_info.code_size = sizeof(metallib_vertex);
            fragment_shader_info.entrypoint = "main0";
            fragment_shader_info.format = GPU_SHADERFORMAT_METALLIB;
            fragment_shader_info.code = metallib_fragment;
            fragment_shader_info.code_size = sizeof(metallib_fragment);
        }
#endif
        bd->VertexShader = GPU_CreateShader(v->Device, &vertex_shader_info);
        bd->FragmentShader = GPU_CreateShader(v->Device, &fragment_shader_info);
        IM_ASSERT(bd->VertexShader != nullptr && "Failed to create vertex shader, call SDL_GetError() for more information");
        IM_ASSERT(bd->FragmentShader != nullptr && "Failed to create fragment shader, call SDL_GetError() for more information");
    }

    static void ImGui_ImplGPU_CreateGraphicsPipeline()
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_InitInfo *v = &bd->InitInfo;
        ImGui_ImplGPU_CreateShaders();

        GPU_VertexBufferDescription vertex_buffer_desc[1];
        vertex_buffer_desc[0].slot = 0;
        vertex_buffer_desc[0].input_rate = GPU_VERTEXINPUTRATE_VERTEX;
        vertex_buffer_desc[0].instance_step_rate = 0;
        vertex_buffer_desc[0].pitch = sizeof(ImDrawVert);

        GPU_VertexAttribute vertex_attributes[3];
        vertex_attributes[0].buffer_slot = 0;
        vertex_attributes[0].format = GPU_VERTEXELEMENTFORMAT_FLOAT2;
        vertex_attributes[0].location = 0;
        vertex_attributes[0].offset = offsetof(ImDrawVert, pos);

        vertex_attributes[1].buffer_slot = 0;
        vertex_attributes[1].format = GPU_VERTEXELEMENTFORMAT_FLOAT2;
        vertex_attributes[1].location = 1;
        vertex_attributes[1].offset = offsetof(ImDrawVert, uv);

        vertex_attributes[2].buffer_slot = 0;
        vertex_attributes[2].format = GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM;
        vertex_attributes[2].location = 2;
        vertex_attributes[2].offset = offsetof(ImDrawVert, col);

        GPU_VertexInputState vertex_input_state = {};
        vertex_input_state.num_vertex_attributes = 3;
        vertex_input_state.vertex_attributes = vertex_attributes;
        vertex_input_state.num_vertex_buffers = 1;
        vertex_input_state.vertex_buffer_descriptions = vertex_buffer_desc;

        GPU_RasterizerState rasterizer_state = {};
        rasterizer_state.fill_mode = GPU_FILLMODE_FILL;
        rasterizer_state.cull_mode = GPU_CULLMODE_NONE;
        rasterizer_state.front_face = GPU_FRONTFACE_COUNTER_CLOCKWISE;
        rasterizer_state.enable_depth_bias = false;
        rasterizer_state.enable_depth_clip = false;

        GPU_MultisampleState multisample_state = {};
        multisample_state.sample_count = v->MSAASamples;
        multisample_state.enable_mask = false;

        GPU_DepthStencilState depth_stencil_state = {};
        depth_stencil_state.enable_depth_test = false;
        depth_stencil_state.enable_depth_write = false;
        depth_stencil_state.enable_stencil_test = false;

        GPU_ColorTargetBlendState blend_state = {};
        blend_state.enable_blend = true;
        blend_state.src_color_blendfactor = GPU_BLENDFACTOR_SRC_ALPHA;
        blend_state.dst_color_blendfactor = GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend_state.color_blend_op = GPU_BLENDOP_ADD;
        blend_state.src_alpha_blendfactor = GPU_BLENDFACTOR_ONE;
        blend_state.dst_alpha_blendfactor = GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend_state.alpha_blend_op = GPU_BLENDOP_ADD;
        blend_state.color_write_mask = GPU_COLORCOMPONENT_R | GPU_COLORCOMPONENT_G | GPU_COLORCOMPONENT_B | GPU_COLORCOMPONENT_A;

        GPU_ColorTargetDescription color_target_desc[1];
        color_target_desc[0].format = v->ColorTargetFormat;
        color_target_desc[0].blend_state = blend_state;

        GPU_GraphicsPipelineTargetInfo target_info = {};
        target_info.num_color_targets = 1;
        target_info.color_target_descriptions = color_target_desc;
        target_info.has_depth_stencil_target = false;

        GPU_GraphicsPipelineCreateInfo pipeline_info = {};
        pipeline_info.vertex_shader = bd->VertexShader;
        pipeline_info.fragment_shader = bd->FragmentShader;
        pipeline_info.vertex_input_state = vertex_input_state;
        pipeline_info.primitive_type = GPU_PRIMITIVETYPE_TRIANGLELIST;
        pipeline_info.rasterizer_state = rasterizer_state;
        pipeline_info.multisample_state = multisample_state;
        pipeline_info.depth_stencil_state = depth_stencil_state;
        pipeline_info.target_info = target_info;

        bd->Pipeline = GPU_CreateGraphicsPipeline(v->Device, &pipeline_info);
        IM_ASSERT(bd->Pipeline != nullptr && "Failed to create graphics pipeline, call SDL_GetError() for more information");
    }

    void ImGui_ImplGPU_CreateDeviceObjects()
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_InitInfo *v = &bd->InitInfo;

        ImGui_ImplGPU_DestroyDeviceObjects();

        if (bd->TexSampler == nullptr)
        {
            // Bilinear sampling is required by default. Set 'io.Fonts->Flags |= ImFontAtlasFlags_NoBakedLines' or 'style.AntiAliasedLinesUseTex = false' to allow point/nearest sampling.
            GPU_SamplerCreateInfo sampler_info = {};
            sampler_info.min_filter = GPU_FILTER_LINEAR;
            sampler_info.mag_filter = GPU_FILTER_LINEAR;
            sampler_info.mipmap_mode = GPU_SAMPLERMIPMAPMODE_LINEAR;
            sampler_info.address_mode_u = GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
            sampler_info.address_mode_v = GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
            sampler_info.address_mode_w = GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
            sampler_info.mip_lod_bias = 0.0f;
            sampler_info.min_lod = -1000.0f;
            sampler_info.max_lod = 1000.0f;
            sampler_info.enable_anisotropy = false;
            sampler_info.max_anisotropy = 1.0f;
            sampler_info.enable_compare = false;

            bd->TexSampler = GPU_CreateSampler(v->Device, &sampler_info);
            IM_ASSERT(bd->TexSampler != nullptr && "Failed to create font sampler, call SDL_GetError() for more information");
        }

        ImGui_ImplGPU_CreateGraphicsPipeline();
    }

    void ImGui_ImplGPU_DestroyFrameData()
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_InitInfo *v = &bd->InitInfo;

        ImGui_ImplGPU_FrameData *fd = &bd->MainWindowFrameData;
        GPU_ReleaseBuffer(v->Device, fd->VertexBuffer);
        GPU_ReleaseBuffer(v->Device, fd->IndexBuffer);
        GPU_ReleaseTransferBuffer(v->Device, fd->VertexTransferBuffer);
        GPU_ReleaseTransferBuffer(v->Device, fd->IndexTransferBuffer);
        fd->VertexBuffer = fd->IndexBuffer = nullptr;
        fd->VertexTransferBuffer = fd->IndexTransferBuffer = nullptr;
        fd->VertexBufferSize = fd->IndexBufferSize = 0;
    }

    void ImGui_ImplGPU_DestroyDeviceObjects()
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        ImGui_ImplGPU_InitInfo *v = &bd->InitInfo;

        ImGui_ImplGPU_DestroyFrameData();

        // Destroy all textures
        for (ImTextureData *tex : ImGui::GetPlatformIO().Textures)
            if (tex->RefCount == 1)
                ImGui_ImplGPU_DestroyTexture(tex);
        if (bd->TexTransferBuffer)
        {
            GPU_ReleaseTransferBuffer(v->Device, bd->TexTransferBuffer);
            bd->TexTransferBuffer = nullptr;
        }
        if (bd->VertexShader)
        {
            GPU_ReleaseShader(v->Device, bd->VertexShader);
            bd->VertexShader = nullptr;
        }
        if (bd->FragmentShader)
        {
            GPU_ReleaseShader(v->Device, bd->FragmentShader);
            bd->FragmentShader = nullptr;
        }
        if (bd->TexSampler)
        {
            GPU_ReleaseSampler(v->Device, bd->TexSampler);
            bd->TexSampler = nullptr;
        }
        if (bd->Pipeline)
        {
            GPU_ReleaseGraphicsPipeline(v->Device, bd->Pipeline);
            bd->Pipeline = nullptr;
        }
    }

    bool ImGui_ImplGPU_Init(ImGui_ImplGPU_InitInfo *info)
    {
        ImGuiIO &io = ImGui::GetIO();
        IMGUI_CHECKVERSION();
        IM_ASSERT(io.BackendRendererUserData == nullptr && "Already initialized a renderer backend!");

        // Setup backend capabilities flags
        ImGui_ImplGPU_Data *bd = IM_NEW(ImGui_ImplGPU_Data)();
        io.BackendRendererUserData = (void *)bd;
        io.BackendRendererName = "imgui_impl_sdlgpu3";
        io.BackendFlags |= ImGuiBackendFlags_RendererHasVtxOffset; // We can honor the ImDrawCmd::VtxOffset field, allowing for large meshes.
        io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures;  // We can honor ImGuiPlatformIO::Textures[] requests during render.

        IM_ASSERT(info->Device != nullptr);
        IM_ASSERT(info->ColorTargetFormat != GPU_TEXTUREFORMAT_INVALID);

        bd->InitInfo = *info;

        return true;
    }

    void ImGui_ImplGPU_Shutdown()
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        IM_ASSERT(bd != nullptr && "No renderer backend to shutdown, or already shutdown?");
        ImGuiIO &io = ImGui::GetIO();

        ImGui_ImplGPU_DestroyDeviceObjects();
        io.BackendRendererName = nullptr;
        io.BackendRendererUserData = nullptr;
        io.BackendFlags &= ~(ImGuiBackendFlags_RendererHasVtxOffset | ImGuiBackendFlags_RendererHasTextures);
        IM_DELETE(bd);
    }

    void ImGui_ImplGPU_NewFrame()
    {
        ImGui_ImplGPU_Data *bd = ImGui_ImplGPU_GetBackendData();
        IM_ASSERT(bd != nullptr && "Context or backend not initialized! Did you call ImGui_ImplGPU_Init()?");

        if (!bd->TexSampler)
            ImGui_ImplGPU_CreateDeviceObjects();
    }

} // extern "C"

#endif // #ifndef IMGUI_DISABLE