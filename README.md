# gloobie

A cross-platform experimental renderer for Resonite.

## TODO

- [ ] ImGui initialization and rendering
- [ ] Begin communicating with FE
- [ ] Desktop mode graphics initialization
- [ ] Desktop mode frame loop
- [ ] OpenXR graphics init
- [ ] OpenXR frame loop
- [ ] OpenVR graphics init
- [ ] OpenVR frame loop
- [ ] Desktop mode input
- [ ] OpenXR input
- [ ] OpenVR input
- [ ] Upload textures to GPU
- [ ] Upload meshes to GPU
- [ ] Basic shaders
- [ ] Use actual resonite shaders

## Sub-projects

- `client/`: The main client.
- `gpu/`: The low level GPU abstraction. Forked off SDL_gpu.
  - `gpu/vulkan/`: The Vulkan GPU backend. Primary target.
  - `gpu/d3d12/`: The D3D12 GPU backend, secondary target.
  - `gpu/metal/`: The Metal GPU backend, tertiary target.
  - `gpu/hashtable/`: A simple hash table implementation in C, used by the GPU backends.
- `xr/`: The VR abstraction layer.
  - `xr/openxr/`: The OpenXR backend. Primary target.
  - `xr/openvr/`: The OpenVR backend. Secondary target.
- `openxr/`: The OpenXR wrapper.
- `renderite/generator/`: Generates type definitions from the Renderite DLL file.
- `renderite/`: Types from the Renderite DLL file. Should stay in sync with engine updates. Some parts auto-generated, some manually written.
- `imgui/`: An implementation of an ImGui renderer for our GPU abstraction.
