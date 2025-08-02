/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2025 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/
// #include "SDL3/SDL_video.h"
// #include "SDL3/SDL_gpu.h"
#include "SDL3/SDL.h"
#include "gpu.h"
#include "hashtable/hashtable.h"

#include <stdbool.h>

#ifndef GPU_DRIVER_H
#define GPU_DRIVER_H

// GraphicsDevice Limits

#define MAX_TEXTURE_SAMPLERS_PER_STAGE 16
#define MAX_STORAGE_TEXTURES_PER_STAGE 8
#define MAX_STORAGE_BUFFERS_PER_STAGE 8
#define MAX_UNIFORM_BUFFERS_PER_STAGE 4
#define MAX_COMPUTE_WRITE_TEXTURES 8
#define MAX_COMPUTE_WRITE_BUFFERS 8
#define UNIFORM_BUFFER_SIZE 32768
#define MAX_VERTEX_BUFFERS 16
#define MAX_VERTEX_ATTRIBUTES 16
#define MAX_COLOR_TARGET_BINDINGS 4
#define MAX_PRESENT_COUNT 16
#define MAX_FRAMES_IN_FLIGHT 3

// Common Structs

typedef struct Pass
{
    GPU_CommandBuffer *command_buffer;
    bool in_progress;
} Pass;

typedef struct ComputePass
{
    GPU_CommandBuffer *command_buffer;
    bool in_progress;

    GPU_ComputePipeline *compute_pipeline;

    bool sampler_bound[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    bool read_only_storage_texture_bound[MAX_STORAGE_TEXTURES_PER_STAGE];
    bool read_only_storage_buffer_bound[MAX_STORAGE_BUFFERS_PER_STAGE];
    bool read_write_storage_texture_bound[MAX_COMPUTE_WRITE_TEXTURES];
    bool read_write_storage_buffer_bound[MAX_COMPUTE_WRITE_BUFFERS];
} ComputePass;

typedef struct RenderPass
{
    GPU_CommandBuffer *command_buffer;
    bool in_progress;
    GPU_Texture *color_targets[MAX_COLOR_TARGET_BINDINGS];
    Uint32 num_color_targets;
    GPU_Texture *depth_stencil_target;

    GPU_GraphicsPipeline *graphics_pipeline;

    bool vertex_sampler_bound[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    bool vertex_storage_texture_bound[MAX_STORAGE_TEXTURES_PER_STAGE];
    bool vertex_storage_buffer_bound[MAX_STORAGE_BUFFERS_PER_STAGE];

    bool fragment_sampler_bound[MAX_TEXTURE_SAMPLERS_PER_STAGE];
    bool fragment_storage_texture_bound[MAX_STORAGE_TEXTURES_PER_STAGE];
    bool fragment_storage_buffer_bound[MAX_STORAGE_BUFFERS_PER_STAGE];
} RenderPass;

typedef struct CommandBufferCommonHeader
{
    GPU_Device *device;

    RenderPass render_pass;
    ComputePass compute_pass;

    Pass copy_pass;
    bool swapchain_texture_acquired;
    bool submitted;
    // used to avoid tripping assert on GenerateMipmaps
    bool ignore_render_pass_texture_validation;
} CommandBufferCommonHeader;

typedef struct TextureCommonHeader
{
    GPU_TextureCreateInfo info;
} TextureCommonHeader;

typedef struct GraphicsPipelineCommonHeader
{
    Uint32 num_vertex_samplers;
    Uint32 num_vertex_storage_textures;
    Uint32 num_vertex_storage_buffers;
    Uint32 num_vertex_uniform_buffers;

    Uint32 num_fragment_samplers;
    Uint32 num_fragment_storage_textures;
    Uint32 num_fragment_storage_buffers;
    Uint32 num_fragment_uniform_buffers;
} GraphicsPipelineCommonHeader;

typedef struct ComputePipelineCommonHeader
{
    Uint32 numSamplers;
    Uint32 numReadonlyStorageTextures;
    Uint32 numReadonlyStorageBuffers;
    Uint32 numReadWriteStorageTextures;
    Uint32 numReadWriteStorageBuffers;
    Uint32 numUniformBuffers;
} ComputePipelineCommonHeader;

typedef struct BlitFragmentUniforms
{
    // texcoord space
    float left;
    float top;
    float width;
    float height;

    Uint32 mip_level;
    float layer_or_depth;
} BlitFragmentUniforms;

typedef struct BlitPipelineCacheEntry
{
    GPU_TextureType type;
    GPU_TextureFormat format;
    GPU_GraphicsPipeline *pipeline;
} BlitPipelineCacheEntry;

// Internal Helper Utilities

#define GPU_TEXTUREFORMAT_MAX_ENUM_VALUE (GPU_TEXTUREFORMAT_ASTC_12x12_FLOAT + 1)
#define GPU_VERTEXELEMENTFORMAT_MAX_ENUM_VALUE (GPU_VERTEXELEMENTFORMAT_HALF4 + 1)
#define GPU_COMPAREOP_MAX_ENUM_VALUE (GPU_COMPAREOP_ALWAYS + 1)
#define GPU_STENCILOP_MAX_ENUM_VALUE (GPU_STENCILOP_DECREMENT_AND_WRAP + 1)
#define GPU_BLENDOP_MAX_ENUM_VALUE (GPU_BLENDOP_MAX + 1)
#define GPU_BLENDFACTOR_MAX_ENUM_VALUE (GPU_BLENDFACTOR_SRC_ALPHA_SATURATE + 1)
#define GPU_SWAPCHAINCOMPOSITION_MAX_ENUM_VALUE (GPU_SWAPCHAINCOMPOSITION_HDR10_ST2084 + 1)
#define GPU_PRESENTMODE_MAX_ENUM_VALUE (GPU_PRESENTMODE_MAILBOX + 1)

static inline Sint32 Texture_GetBlockWidth(
    GPU_TextureFormat format)
{
    switch (format)
    {
    case GPU_TEXTUREFORMAT_ASTC_12x10_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_12x12_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_12x10_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_12x12_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_12x10_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_12x12_FLOAT:
        return 12;
    case GPU_TEXTUREFORMAT_ASTC_10x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x8_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x10_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x10_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x8_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x10_FLOAT:
        return 10;
    case GPU_TEXTUREFORMAT_ASTC_8x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x8_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x8_FLOAT:
        return 8;
    case GPU_TEXTUREFORMAT_ASTC_6x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_6x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_6x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_6x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_6x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_6x6_FLOAT:
        return 6;
    case GPU_TEXTUREFORMAT_ASTC_5x4_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_5x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_5x4_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x4_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_5x5_FLOAT:
        return 5;
    case GPU_TEXTUREFORMAT_BC1_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC2_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC3_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC4_R_UNORM:
    case GPU_TEXTUREFORMAT_BC5_RG_UNORM:
    case GPU_TEXTUREFORMAT_BC7_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC6H_RGB_FLOAT:
    case GPU_TEXTUREFORMAT_BC6H_RGB_UFLOAT:
    case GPU_TEXTUREFORMAT_BC1_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC2_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC3_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC7_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_4x4_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_4x4_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_4x4_FLOAT:
        return 4;
    case GPU_TEXTUREFORMAT_R8G8B8A8_UNORM:
    case GPU_TEXTUREFORMAT_B8G8R8A8_UNORM:
    case GPU_TEXTUREFORMAT_B5G6R5_UNORM:
    case GPU_TEXTUREFORMAT_B5G5R5A1_UNORM:
    case GPU_TEXTUREFORMAT_B4G4R4A4_UNORM:
    case GPU_TEXTUREFORMAT_R10G10B10A2_UNORM:
    case GPU_TEXTUREFORMAT_R8G8_UNORM:
    case GPU_TEXTUREFORMAT_R16G16_UNORM:
    case GPU_TEXTUREFORMAT_R16G16B16A16_UNORM:
    case GPU_TEXTUREFORMAT_R8_UNORM:
    case GPU_TEXTUREFORMAT_R16_UNORM:
    case GPU_TEXTUREFORMAT_A8_UNORM:
    case GPU_TEXTUREFORMAT_R8_SNORM:
    case GPU_TEXTUREFORMAT_R8G8_SNORM:
    case GPU_TEXTUREFORMAT_R8G8B8A8_SNORM:
    case GPU_TEXTUREFORMAT_R16_SNORM:
    case GPU_TEXTUREFORMAT_R16G16_SNORM:
    case GPU_TEXTUREFORMAT_R16G16B16A16_SNORM:
    case GPU_TEXTUREFORMAT_R16_FLOAT:
    case GPU_TEXTUREFORMAT_R16G16_FLOAT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT:
    case GPU_TEXTUREFORMAT_R32_FLOAT:
    case GPU_TEXTUREFORMAT_R32G32_FLOAT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT:
    case GPU_TEXTUREFORMAT_R11G11B10_UFLOAT:
    case GPU_TEXTUREFORMAT_R8_UINT:
    case GPU_TEXTUREFORMAT_R8G8_UINT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_UINT:
    case GPU_TEXTUREFORMAT_R16_UINT:
    case GPU_TEXTUREFORMAT_R16G16_UINT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_UINT:
    case GPU_TEXTUREFORMAT_R32_UINT:
    case GPU_TEXTUREFORMAT_R32G32_UINT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_UINT:
    case GPU_TEXTUREFORMAT_R8_INT:
    case GPU_TEXTUREFORMAT_R8G8_INT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_INT:
    case GPU_TEXTUREFORMAT_R16_INT:
    case GPU_TEXTUREFORMAT_R16G16_INT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_INT:
    case GPU_TEXTUREFORMAT_R32_INT:
    case GPU_TEXTUREFORMAT_R32G32_INT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_INT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_D16_UNORM:
    case GPU_TEXTUREFORMAT_D24_UNORM:
    case GPU_TEXTUREFORMAT_D32_FLOAT:
    case GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT:
    case GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT:
        return 1;
    default:
        SDL_assert_release(!"Unrecognized TextureFormat!");
        return 0;
    }
}

static inline Sint32 Texture_GetBlockHeight(
    GPU_TextureFormat format)
{
    switch (format)
    {
    case GPU_TEXTUREFORMAT_ASTC_12x12_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_12x12_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_12x12_FLOAT:
        return 12;
    case GPU_TEXTUREFORMAT_ASTC_12x10_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_12x10_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_12x10_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x10_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x10_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x10_FLOAT:
        return 10;
    case GPU_TEXTUREFORMAT_ASTC_10x8_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x8_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x8_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x8_FLOAT:
        return 8;
    case GPU_TEXTUREFORMAT_ASTC_10x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_6x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_6x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_6x6_FLOAT:
        return 6;
    case GPU_TEXTUREFORMAT_ASTC_10x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_6x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_6x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_6x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_5x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_5x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x5_FLOAT:
        return 5;
    case GPU_TEXTUREFORMAT_BC1_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC2_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC3_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC4_R_UNORM:
    case GPU_TEXTUREFORMAT_BC5_RG_UNORM:
    case GPU_TEXTUREFORMAT_BC7_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC6H_RGB_FLOAT:
    case GPU_TEXTUREFORMAT_BC6H_RGB_UFLOAT:
    case GPU_TEXTUREFORMAT_BC1_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC2_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC3_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC7_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x4_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_5x4_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x4_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_4x4_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_4x4_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_4x4_FLOAT:
        return 4;
    case GPU_TEXTUREFORMAT_R8G8B8A8_UNORM:
    case GPU_TEXTUREFORMAT_B8G8R8A8_UNORM:
    case GPU_TEXTUREFORMAT_B5G6R5_UNORM:
    case GPU_TEXTUREFORMAT_B5G5R5A1_UNORM:
    case GPU_TEXTUREFORMAT_B4G4R4A4_UNORM:
    case GPU_TEXTUREFORMAT_R10G10B10A2_UNORM:
    case GPU_TEXTUREFORMAT_R8G8_UNORM:
    case GPU_TEXTUREFORMAT_R16G16_UNORM:
    case GPU_TEXTUREFORMAT_R16G16B16A16_UNORM:
    case GPU_TEXTUREFORMAT_R8_UNORM:
    case GPU_TEXTUREFORMAT_R16_UNORM:
    case GPU_TEXTUREFORMAT_A8_UNORM:
    case GPU_TEXTUREFORMAT_R8_SNORM:
    case GPU_TEXTUREFORMAT_R8G8_SNORM:
    case GPU_TEXTUREFORMAT_R8G8B8A8_SNORM:
    case GPU_TEXTUREFORMAT_R16_SNORM:
    case GPU_TEXTUREFORMAT_R16G16_SNORM:
    case GPU_TEXTUREFORMAT_R16G16B16A16_SNORM:
    case GPU_TEXTUREFORMAT_R16_FLOAT:
    case GPU_TEXTUREFORMAT_R16G16_FLOAT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT:
    case GPU_TEXTUREFORMAT_R32_FLOAT:
    case GPU_TEXTUREFORMAT_R32G32_FLOAT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT:
    case GPU_TEXTUREFORMAT_R11G11B10_UFLOAT:
    case GPU_TEXTUREFORMAT_R8_UINT:
    case GPU_TEXTUREFORMAT_R8G8_UINT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_UINT:
    case GPU_TEXTUREFORMAT_R16_UINT:
    case GPU_TEXTUREFORMAT_R16G16_UINT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_UINT:
    case GPU_TEXTUREFORMAT_R32_UINT:
    case GPU_TEXTUREFORMAT_R32G32_UINT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_UINT:
    case GPU_TEXTUREFORMAT_R8_INT:
    case GPU_TEXTUREFORMAT_R8G8_INT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_INT:
    case GPU_TEXTUREFORMAT_R16_INT:
    case GPU_TEXTUREFORMAT_R16G16_INT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_INT:
    case GPU_TEXTUREFORMAT_R32_INT:
    case GPU_TEXTUREFORMAT_R32G32_INT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_INT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_D16_UNORM:
    case GPU_TEXTUREFORMAT_D24_UNORM:
    case GPU_TEXTUREFORMAT_D32_FLOAT:
    case GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT:
    case GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT:
        return 1;
    default:
        SDL_assert_release(!"Unrecognized TextureFormat!");
        return 0;
    }
}

static inline bool IsDepthFormat(
    GPU_TextureFormat format)
{
    switch (format)
    {
    case GPU_TEXTUREFORMAT_D16_UNORM:
    case GPU_TEXTUREFORMAT_D24_UNORM:
    case GPU_TEXTUREFORMAT_D32_FLOAT:
    case GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT:
    case GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT:
        return true;

    default:
        return false;
    }
}

static inline bool IsStencilFormat(
    GPU_TextureFormat format)
{
    switch (format)
    {
    case GPU_TEXTUREFORMAT_D24_UNORM_S8_UINT:
    case GPU_TEXTUREFORMAT_D32_FLOAT_S8_UINT:
        return true;

    default:
        return false;
    }
}

static inline bool IsIntegerFormat(
    GPU_TextureFormat format)
{
    switch (format)
    {
    case GPU_TEXTUREFORMAT_R8_UINT:
    case GPU_TEXTUREFORMAT_R8G8_UINT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_UINT:
    case GPU_TEXTUREFORMAT_R16_UINT:
    case GPU_TEXTUREFORMAT_R16G16_UINT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_UINT:
    case GPU_TEXTUREFORMAT_R8_INT:
    case GPU_TEXTUREFORMAT_R8G8_INT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_INT:
    case GPU_TEXTUREFORMAT_R16_INT:
    case GPU_TEXTUREFORMAT_R16G16_INT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_INT:
        return true;

    default:
        return false;
    }
}

static inline bool IsCompressedFormat(
    GPU_TextureFormat format)
{
    switch (format)
    {
    case GPU_TEXTUREFORMAT_BC1_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC1_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC2_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC2_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC3_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC3_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC4_R_UNORM:
    case GPU_TEXTUREFORMAT_BC5_RG_UNORM:
    case GPU_TEXTUREFORMAT_BC6H_RGB_FLOAT:
    case GPU_TEXTUREFORMAT_BC6H_RGB_UFLOAT:
    case GPU_TEXTUREFORMAT_BC7_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC7_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_4x4_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_5x4_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_5x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_6x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_6x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x8_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x8_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x10_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_12x10_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_12x12_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_4x4_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x4_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_6x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_6x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x10_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_12x10_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_12x12_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_4x4_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_5x4_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_5x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_6x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_6x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x8_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x8_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x10_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_12x10_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_12x12_FLOAT:
        return true;

    default:
        return false;
    }
}

static inline bool FormatHasAlpha(
    GPU_TextureFormat format)
{
    switch (format)
    {
    case GPU_TEXTUREFORMAT_ASTC_12x10_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_12x12_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_12x10_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_12x12_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_12x10_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_12x12_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x8_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x10_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_10x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x10_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_10x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x8_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_10x10_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x8_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_8x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_8x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_8x8_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_6x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_6x6_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_6x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_6x6_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_6x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_6x6_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_5x4_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_5x5_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_5x4_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x5_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_5x4_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_5x5_FLOAT:
    case GPU_TEXTUREFORMAT_ASTC_4x4_UNORM:
    case GPU_TEXTUREFORMAT_ASTC_4x4_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_ASTC_4x4_FLOAT:
        // ASTC textures may or may not have alpha; return true as this is mainly intended for validation
        return true;

    case GPU_TEXTUREFORMAT_BC1_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC2_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC3_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC7_RGBA_UNORM:
    case GPU_TEXTUREFORMAT_BC1_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC2_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC3_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_BC7_RGBA_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_R8G8B8A8_UNORM:
    case GPU_TEXTUREFORMAT_B8G8R8A8_UNORM:
    case GPU_TEXTUREFORMAT_B5G5R5A1_UNORM:
    case GPU_TEXTUREFORMAT_B4G4R4A4_UNORM:
    case GPU_TEXTUREFORMAT_R10G10B10A2_UNORM:
    case GPU_TEXTUREFORMAT_R16G16B16A16_UNORM:
    case GPU_TEXTUREFORMAT_A8_UNORM:
    case GPU_TEXTUREFORMAT_R8G8B8A8_SNORM:
    case GPU_TEXTUREFORMAT_R16G16B16A16_SNORM:
    case GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_FLOAT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_UINT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_UINT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_UINT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_INT:
    case GPU_TEXTUREFORMAT_R16G16B16A16_INT:
    case GPU_TEXTUREFORMAT_R32G32B32A32_INT:
    case GPU_TEXTUREFORMAT_R8G8B8A8_UNORM_SRGB:
    case GPU_TEXTUREFORMAT_B8G8R8A8_UNORM_SRGB:
        return true;

    default:
        return false;
    }
}

static inline Uint32 IndexSize(GPU_IndexElementSize size)
{
    return (size == GPU_INDEXELEMENTSIZE_16BIT) ? 2 : 4;
}

static inline Uint32 BytesPerRow(
    Sint32 width,
    GPU_TextureFormat format)
{
    Uint32 blockWidth = Texture_GetBlockWidth(format);
    Uint32 blocksPerRow = (width + blockWidth - 1) / blockWidth;
    return blocksPerRow * GPU_TextureFormatTexelBlockSize(format);
}

// Internal Macros

#define EXPAND_ARRAY_IF_NEEDED(arr, elementType, newCount, capacity, newCapacity) \
    do                                                                            \
    {                                                                             \
        if ((newCount) >= (capacity))                                             \
        {                                                                         \
            (capacity) = (newCapacity);                                           \
            (arr) = (elementType *)SDL_realloc(                                   \
                (arr),                                                            \
                sizeof(elementType) * (capacity));                                \
        }                                                                         \
    } while (0)

// Internal Declarations

#ifdef __cplusplus
extern "C"
{
#endif // __cplusplus

    GPU_GraphicsPipeline *GPU_FetchBlitPipeline(
        GPU_Device *device,
        GPU_TextureType sourceTextureType,
        GPU_TextureFormat destinationFormat,
        GPU_Shader *blitVertexShader,
        GPU_Shader *blitFrom2DShader,
        GPU_Shader *blitFrom2DArrayShader,
        GPU_Shader *blitFrom3DShader,
        GPU_Shader *blitFromCubeShader,
        GPU_Shader *blitFromCubeArrayShader,
        BlitPipelineCacheEntry **blitPipelines,
        Uint32 *blitPipelineCount,
        Uint32 *blitPipelineCapacity);

    void GPU_BlitCommon(
        GPU_CommandBuffer *commandBuffer,
        const GPU_BlitInfo *info,
        GPU_Sampler *blitLinearSampler,
        GPU_Sampler *blitNearestSampler,
        GPU_Shader *blitVertexShader,
        GPU_Shader *blitFrom2DShader,
        GPU_Shader *blitFrom2DArrayShader,
        GPU_Shader *blitFrom3DShader,
        GPU_Shader *blitFromCubeShader,
        GPU_Shader *blitFromCubeArrayShader,
        BlitPipelineCacheEntry **blitPipelines,
        Uint32 *blitPipelineCount,
        Uint32 *blitPipelineCapacity);

#ifdef __cplusplus
}
#endif // __cplusplus

// GPU_Device Definition

typedef struct GPU_Renderer GPU_Renderer;

struct GPU_Device
{
    // Device

    void (*DestroyDevice)(GPU_Device *device);

    SDL_PropertiesID (*GetDeviceProperties)(GPU_Device *device);

    // State Creation

    GPU_ComputePipeline *(*CreateComputePipeline)(
        GPU_Renderer *driverData,
        const GPU_ComputePipelineCreateInfo *createinfo);

    GPU_GraphicsPipeline *(*CreateGraphicsPipeline)(
        GPU_Renderer *driverData,
        const GPU_GraphicsPipelineCreateInfo *createinfo);

    GPU_Sampler *(*CreateSampler)(
        GPU_Renderer *driverData,
        const GPU_SamplerCreateInfo *createinfo);

    GPU_Shader *(*CreateShader)(
        GPU_Renderer *driverData,
        const GPU_ShaderCreateInfo *createinfo);

    GPU_Texture *(*CreateTexture)(
        GPU_Renderer *driverData,
        const GPU_TextureCreateInfo *createinfo);

    GPU_Buffer *(*CreateBuffer)(
        GPU_Renderer *driverData,
        GPU_BufferUsageFlags usageFlags,
        Uint32 size,
        const char *debugName);

    GPU_TransferBuffer *(*CreateTransferBuffer)(
        GPU_Renderer *driverData,
        GPU_TransferBufferUsage usage,
        Uint32 size,
        const char *debugName);

    // Debug Naming

    void (*SetBufferName)(
        GPU_Renderer *driverData,
        GPU_Buffer *buffer,
        const char *text);

    void (*SetTextureName)(
        GPU_Renderer *driverData,
        GPU_Texture *texture,
        const char *text);

    void (*InsertDebugLabel)(
        GPU_CommandBuffer *commandBuffer,
        const char *text);

    void (*PushDebugGroup)(
        GPU_CommandBuffer *commandBuffer,
        const char *name);

    void (*PopDebugGroup)(
        GPU_CommandBuffer *commandBuffer);

    // Disposal

    void (*ReleaseTexture)(
        GPU_Renderer *driverData,
        GPU_Texture *texture);

    void (*ReleaseSampler)(
        GPU_Renderer *driverData,
        GPU_Sampler *sampler);

    void (*ReleaseBuffer)(
        GPU_Renderer *driverData,
        GPU_Buffer *buffer);

    void (*ReleaseTransferBuffer)(
        GPU_Renderer *driverData,
        GPU_TransferBuffer *transferBuffer);

    void (*ReleaseShader)(
        GPU_Renderer *driverData,
        GPU_Shader *shader);

    void (*ReleaseComputePipeline)(
        GPU_Renderer *driverData,
        GPU_ComputePipeline *computePipeline);

    void (*ReleaseGraphicsPipeline)(
        GPU_Renderer *driverData,
        GPU_GraphicsPipeline *graphicsPipeline);

    // Render Pass

    void (*BeginRenderPass)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_ColorTargetInfo *colorTargetInfos,
        Uint32 numColorTargets,
        const GPU_DepthStencilTargetInfo *depthStencilTargetInfo);

    void (*BindGraphicsPipeline)(
        GPU_CommandBuffer *commandBuffer,
        GPU_GraphicsPipeline *graphicsPipeline);

    void (*SetViewport)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_Viewport *viewport);

    void (*SetScissor)(
        GPU_CommandBuffer *commandBuffer,
        const SDL_Rect *scissor);

    void (*SetBlendConstants)(
        GPU_CommandBuffer *commandBuffer,
        SDL_FColor blendConstants);

    void (*SetStencilReference)(
        GPU_CommandBuffer *commandBuffer,
        Uint8 reference);

    void (*BindVertexBuffers)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        const GPU_BufferBinding *bindings,
        Uint32 numBindings);

    void (*BindIndexBuffer)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_BufferBinding *binding,
        GPU_IndexElementSize indexElementSize);

    void (*BindVertexSamplers)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        const GPU_TextureSamplerBinding *textureSamplerBindings,
        Uint32 numBindings);

    void (*BindVertexStorageTextures)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        GPU_Texture *const *storageTextures,
        Uint32 numBindings);

    void (*BindVertexStorageBuffers)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        GPU_Buffer *const *storageBuffers,
        Uint32 numBindings);

    void (*BindFragmentSamplers)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        const GPU_TextureSamplerBinding *textureSamplerBindings,
        Uint32 numBindings);

    void (*BindFragmentStorageTextures)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        GPU_Texture *const *storageTextures,
        Uint32 numBindings);

    void (*BindFragmentStorageBuffers)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        GPU_Buffer *const *storageBuffers,
        Uint32 numBindings);

    void (*PushVertexUniformData)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 slotIndex,
        const void *data,
        Uint32 length);

    void (*PushFragmentUniformData)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 slotIndex,
        const void *data,
        Uint32 length);

    void (*DrawIndexedPrimitives)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 numIndices,
        Uint32 numInstances,
        Uint32 firstIndex,
        Sint32 vertexOffset,
        Uint32 firstInstance);

    void (*DrawPrimitives)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 numVertices,
        Uint32 numInstances,
        Uint32 firstVertex,
        Uint32 firstInstance);

    void (*DrawPrimitivesIndirect)(
        GPU_CommandBuffer *commandBuffer,
        GPU_Buffer *buffer,
        Uint32 offset,
        Uint32 drawCount);

    void (*DrawIndexedPrimitivesIndirect)(
        GPU_CommandBuffer *commandBuffer,
        GPU_Buffer *buffer,
        Uint32 offset,
        Uint32 drawCount);

    void (*EndRenderPass)(
        GPU_CommandBuffer *commandBuffer);

    // Compute Pass

    void (*BeginComputePass)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_StorageTextureReadWriteBinding *storageTextureBindings,
        Uint32 numStorageTextureBindings,
        const GPU_StorageBufferReadWriteBinding *storageBufferBindings,
        Uint32 numStorageBufferBindings);

    void (*BindComputePipeline)(
        GPU_CommandBuffer *commandBuffer,
        GPU_ComputePipeline *computePipeline);

    void (*BindComputeSamplers)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        const GPU_TextureSamplerBinding *textureSamplerBindings,
        Uint32 numBindings);

    void (*BindComputeStorageTextures)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        GPU_Texture *const *storageTextures,
        Uint32 numBindings);

    void (*BindComputeStorageBuffers)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 firstSlot,
        GPU_Buffer *const *storageBuffers,
        Uint32 numBindings);

    void (*PushComputeUniformData)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 slotIndex,
        const void *data,
        Uint32 length);

    void (*DispatchCompute)(
        GPU_CommandBuffer *commandBuffer,
        Uint32 groupcountX,
        Uint32 groupcountY,
        Uint32 groupcountZ);

    void (*DispatchComputeIndirect)(
        GPU_CommandBuffer *commandBuffer,
        GPU_Buffer *buffer,
        Uint32 offset);

    void (*EndComputePass)(
        GPU_CommandBuffer *commandBuffer);

    // TransferBuffer Data

    void *(*MapTransferBuffer)(
        GPU_Renderer *device,
        GPU_TransferBuffer *transferBuffer,
        bool cycle);

    void (*UnmapTransferBuffer)(
        GPU_Renderer *device,
        GPU_TransferBuffer *transferBuffer);

    // Copy Pass

    void (*BeginCopyPass)(
        GPU_CommandBuffer *commandBuffer);

    void (*UploadToTexture)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_TextureTransferInfo *source,
        const GPU_TextureRegion *destination,
        bool cycle);

    void (*UploadToBuffer)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_TransferBufferLocation *source,
        const GPU_BufferRegion *destination,
        bool cycle);

    void (*CopyTextureToTexture)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_TextureLocation *source,
        const GPU_TextureLocation *destination,
        Uint32 w,
        Uint32 h,
        Uint32 d,
        bool cycle);

    void (*CopyBufferToBuffer)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_BufferLocation *source,
        const GPU_BufferLocation *destination,
        Uint32 size,
        bool cycle);

    void (*GenerateMipmaps)(
        GPU_CommandBuffer *commandBuffer,
        GPU_Texture *texture);

    void (*DownloadFromTexture)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_TextureRegion *source,
        const GPU_TextureTransferInfo *destination);

    void (*DownloadFromBuffer)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_BufferRegion *source,
        const GPU_TransferBufferLocation *destination);

    void (*EndCopyPass)(
        GPU_CommandBuffer *commandBuffer);

    void (*Blit)(
        GPU_CommandBuffer *commandBuffer,
        const GPU_BlitInfo *info);

    // Submission/Presentation

    bool (*SupportsSwapchainComposition)(
        GPU_Renderer *driverData,
        SDL_Window *window,
        GPU_SwapchainComposition swapchainComposition);

    bool (*SupportsPresentMode)(
        GPU_Renderer *driverData,
        SDL_Window *window,
        GPU_PresentMode presentMode);

    bool (*ClaimWindow)(
        GPU_Renderer *driverData,
        SDL_Window *window);

    void (*ReleaseWindow)(
        GPU_Renderer *driverData,
        SDL_Window *window);

    bool (*SetSwapchainParameters)(
        GPU_Renderer *driverData,
        SDL_Window *window,
        GPU_SwapchainComposition swapchainComposition,
        GPU_PresentMode presentMode);

    bool (*SetAllowedFramesInFlight)(
        GPU_Renderer *driverData,
        Uint32 allowedFramesInFlight);

    GPU_TextureFormat (*GetSwapchainTextureFormat)(
        GPU_Renderer *driverData,
        SDL_Window *window);

    GPU_CommandBuffer *(*AcquireCommandBuffer)(
        GPU_Renderer *driverData);

    bool (*AcquireSwapchainTexture)(
        GPU_CommandBuffer *commandBuffer,
        SDL_Window *window,
        GPU_Texture **swapchainTexture,
        Uint32 *swapchainTextureWidth,
        Uint32 *swapchainTextureHeight);

    bool (*WaitForSwapchain)(
        GPU_Renderer *driverData,
        SDL_Window *window);

    bool (*WaitAndAcquireSwapchainTexture)(
        GPU_CommandBuffer *commandBuffer,
        SDL_Window *window,
        GPU_Texture **swapchainTexture,
        Uint32 *swapchainTextureWidth,
        Uint32 *swapchainTextureHeight);

    bool (*Submit)(
        GPU_CommandBuffer *commandBuffer);

    GPU_Fence *(*SubmitAndAcquireFence)(
        GPU_CommandBuffer *commandBuffer);

    bool (*Cancel)(
        GPU_CommandBuffer *commandBuffer);

    bool (*Wait)(
        GPU_Renderer *driverData);

    bool (*WaitForFences)(
        GPU_Renderer *driverData,
        bool waitAll,
        GPU_Fence *const *fences,
        Uint32 numFences);

    bool (*QueryFence)(
        GPU_Renderer *driverData,
        GPU_Fence *fence);

    void (*ReleaseFence)(
        GPU_Renderer *driverData,
        GPU_Fence *fence);

    // Feature Queries

    bool (*SupportsTextureFormat)(
        GPU_Renderer *driverData,
        GPU_TextureFormat format,
        GPU_TextureType type,
        GPU_TextureUsageFlags usage);

    bool (*SupportsSampleCount)(
        GPU_Renderer *driverData,
        GPU_TextureFormat format,
        GPU_SampleCount desiredSampleCount);

    // !GLOOBIE! Add OpenXR support
#ifdef XR_OPENXR
    // OpenXR
    XrResult (*CreateXRSession)(GPU_Renderer *driverData, const XrSessionCreateInfo *createinfo,
                                XrSession *session);

    XrResult (*CreateXRSwapchain)(GPU_Renderer *driverData, XrSession session,
                                  const XrSwapchainCreateInfo *createinfo,
                                  GPU_TextureFormat *textureFormat,
                                  XrSwapchain *swapchain,
                                  GPU_Texture ***textures);

    XrResult (*DestroyXRSwapchain)(GPU_Renderer *driverData, XrSwapchain swapchain, GPU_Texture **swapchainImages);
#endif

    // Opaque pointer for the Driver
    GPU_Renderer *driverData;

    // Store this for GPU_GetDeviceDriver()
    const char *backend;

    // Store this for GPU_GetShaderFormats()
    GPU_ShaderFormat shader_formats;

    // Store this for SDL_gpu.c's debug layer
    bool debug_mode;
};

#define ASSIGN_DRIVER_FUNC(func, name) \
    result->func = name##_##func;

// !GLOOBIE! Add OpenXR support
#ifdef XR_OPENXR
#define ASSIGN_DRIVER_FUNC_OPENXR(func, name) \
    result->func = name##_##func;
#else
#define ASSIGN_DRIVER_FUNC_OPENXR(func, name)
#endif

#define ASSIGN_DRIVER(name)                                  \
    ASSIGN_DRIVER_FUNC(DestroyDevice, name)                  \
    ASSIGN_DRIVER_FUNC(GetDeviceProperties, name)            \
    ASSIGN_DRIVER_FUNC(CreateComputePipeline, name)          \
    ASSIGN_DRIVER_FUNC(CreateGraphicsPipeline, name)         \
    ASSIGN_DRIVER_FUNC(CreateSampler, name)                  \
    ASSIGN_DRIVER_FUNC(CreateShader, name)                   \
    ASSIGN_DRIVER_FUNC(CreateTexture, name)                  \
    ASSIGN_DRIVER_FUNC(CreateBuffer, name)                   \
    ASSIGN_DRIVER_FUNC(CreateTransferBuffer, name)           \
    ASSIGN_DRIVER_FUNC(SetBufferName, name)                  \
    ASSIGN_DRIVER_FUNC(SetTextureName, name)                 \
    ASSIGN_DRIVER_FUNC(InsertDebugLabel, name)               \
    ASSIGN_DRIVER_FUNC(PushDebugGroup, name)                 \
    ASSIGN_DRIVER_FUNC(PopDebugGroup, name)                  \
    ASSIGN_DRIVER_FUNC(ReleaseTexture, name)                 \
    ASSIGN_DRIVER_FUNC(ReleaseSampler, name)                 \
    ASSIGN_DRIVER_FUNC(ReleaseBuffer, name)                  \
    ASSIGN_DRIVER_FUNC(ReleaseTransferBuffer, name)          \
    ASSIGN_DRIVER_FUNC(ReleaseShader, name)                  \
    ASSIGN_DRIVER_FUNC(ReleaseComputePipeline, name)         \
    ASSIGN_DRIVER_FUNC(ReleaseGraphicsPipeline, name)        \
    ASSIGN_DRIVER_FUNC(BeginRenderPass, name)                \
    ASSIGN_DRIVER_FUNC(BindGraphicsPipeline, name)           \
    ASSIGN_DRIVER_FUNC(SetViewport, name)                    \
    ASSIGN_DRIVER_FUNC(SetScissor, name)                     \
    ASSIGN_DRIVER_FUNC(SetBlendConstants, name)              \
    ASSIGN_DRIVER_FUNC(SetStencilReference, name)            \
    ASSIGN_DRIVER_FUNC(BindVertexBuffers, name)              \
    ASSIGN_DRIVER_FUNC(BindIndexBuffer, name)                \
    ASSIGN_DRIVER_FUNC(BindVertexSamplers, name)             \
    ASSIGN_DRIVER_FUNC(BindVertexStorageTextures, name)      \
    ASSIGN_DRIVER_FUNC(BindVertexStorageBuffers, name)       \
    ASSIGN_DRIVER_FUNC(BindFragmentSamplers, name)           \
    ASSIGN_DRIVER_FUNC(BindFragmentStorageTextures, name)    \
    ASSIGN_DRIVER_FUNC(BindFragmentStorageBuffers, name)     \
    ASSIGN_DRIVER_FUNC(PushVertexUniformData, name)          \
    ASSIGN_DRIVER_FUNC(PushFragmentUniformData, name)        \
    ASSIGN_DRIVER_FUNC(DrawIndexedPrimitives, name)          \
    ASSIGN_DRIVER_FUNC(DrawPrimitives, name)                 \
    ASSIGN_DRIVER_FUNC(DrawPrimitivesIndirect, name)         \
    ASSIGN_DRIVER_FUNC(DrawIndexedPrimitivesIndirect, name)  \
    ASSIGN_DRIVER_FUNC(EndRenderPass, name)                  \
    ASSIGN_DRIVER_FUNC(BeginComputePass, name)               \
    ASSIGN_DRIVER_FUNC(BindComputePipeline, name)            \
    ASSIGN_DRIVER_FUNC(BindComputeSamplers, name)            \
    ASSIGN_DRIVER_FUNC(BindComputeStorageTextures, name)     \
    ASSIGN_DRIVER_FUNC(BindComputeStorageBuffers, name)      \
    ASSIGN_DRIVER_FUNC(PushComputeUniformData, name)         \
    ASSIGN_DRIVER_FUNC(DispatchCompute, name)                \
    ASSIGN_DRIVER_FUNC(DispatchComputeIndirect, name)        \
    ASSIGN_DRIVER_FUNC(EndComputePass, name)                 \
    ASSIGN_DRIVER_FUNC(MapTransferBuffer, name)              \
    ASSIGN_DRIVER_FUNC(UnmapTransferBuffer, name)            \
    ASSIGN_DRIVER_FUNC(BeginCopyPass, name)                  \
    ASSIGN_DRIVER_FUNC(UploadToTexture, name)                \
    ASSIGN_DRIVER_FUNC(UploadToBuffer, name)                 \
    ASSIGN_DRIVER_FUNC(DownloadFromTexture, name)            \
    ASSIGN_DRIVER_FUNC(DownloadFromBuffer, name)             \
    ASSIGN_DRIVER_FUNC(CopyTextureToTexture, name)           \
    ASSIGN_DRIVER_FUNC(CopyBufferToBuffer, name)             \
    ASSIGN_DRIVER_FUNC(GenerateMipmaps, name)                \
    ASSIGN_DRIVER_FUNC(EndCopyPass, name)                    \
    ASSIGN_DRIVER_FUNC(Blit, name)                           \
    ASSIGN_DRIVER_FUNC(SupportsSwapchainComposition, name)   \
    ASSIGN_DRIVER_FUNC(SupportsPresentMode, name)            \
    ASSIGN_DRIVER_FUNC(ClaimWindow, name)                    \
    ASSIGN_DRIVER_FUNC(ReleaseWindow, name)                  \
    ASSIGN_DRIVER_FUNC(SetSwapchainParameters, name)         \
    ASSIGN_DRIVER_FUNC(SetAllowedFramesInFlight, name)       \
    ASSIGN_DRIVER_FUNC(GetSwapchainTextureFormat, name)      \
    ASSIGN_DRIVER_FUNC(AcquireCommandBuffer, name)           \
    ASSIGN_DRIVER_FUNC(AcquireSwapchainTexture, name)        \
    ASSIGN_DRIVER_FUNC(WaitForSwapchain, name)               \
    ASSIGN_DRIVER_FUNC(WaitAndAcquireSwapchainTexture, name) \
    ASSIGN_DRIVER_FUNC(Submit, name)                         \
    ASSIGN_DRIVER_FUNC(SubmitAndAcquireFence, name)          \
    ASSIGN_DRIVER_FUNC(Cancel, name)                         \
    ASSIGN_DRIVER_FUNC(Wait, name)                           \
    ASSIGN_DRIVER_FUNC(WaitForFences, name)                  \
    ASSIGN_DRIVER_FUNC(QueryFence, name)                     \
    ASSIGN_DRIVER_FUNC(ReleaseFence, name)                   \
    ASSIGN_DRIVER_FUNC(SupportsTextureFormat, name)          \
    ASSIGN_DRIVER_FUNC(SupportsSampleCount, name)            \
    ASSIGN_DRIVER_FUNC_OPENXR(CreateXRSession, name)         \
    ASSIGN_DRIVER_FUNC_OPENXR(CreateXRSwapchain, name)       \
    ASSIGN_DRIVER_FUNC_OPENXR(DestroyXRSwapchain, name)
// !GLOOBIE! Add OpenXR support (see 3 lines above)

typedef struct GPU_Bootstrap
{
    const char *name;
    bool (*PrepareDriver)(SDL_PropertiesID props);
    GPU_Device *(*CreateDevice)(bool debug_mode, bool prefer_low_power, SDL_PropertiesID props);
} GPU_Bootstrap;

#ifdef __cplusplus
extern "C"
{
#endif

    extern GPU_Bootstrap GPU_VulkanDriver;
    extern GPU_Bootstrap GPU_D3D12Driver;
    extern GPU_Bootstrap GPU_MetalDriver;
    extern GPU_Bootstrap GPU_PrivateDriver;

#ifdef __cplusplus
}
#endif

#endif // GPU_DRIVER_H
