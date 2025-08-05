# gloobie

A cross-platform experimental renderer for Resonite.

## TODO

- [x] ImGui initialization and rendering
- [x] Begin reading from FE
- [x] Begin writing to FE
- [ ] Finish struct generator
- [x] Desktop mode graphics initialization
- [ ] Desktop mode frame loop
- [x] OpenXR graphics init
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
- `renderite/`: Code and types concerning communication with FrooxEngine.
  - `renderite/generator/`: Generates type definitions and (de)serialization code from the Renderite DLL file.
  - `renderite/shared.zig` Automatically generated types from the Renderite DLL file. This should stay in sync with engine updates.
- `imgui/`: An implementation of an ImGui renderer for our GPU abstraction.
- `math/`: An xr_linear based math library, with lots of extra routines sprinkled in. Taken from vrshit.
- `build/`: Misc build scripts.
- `tracy/`: Zig + Tracy integration
