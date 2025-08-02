# gloobie

A cross-platform experimental renderer for Resonite.

## TODO

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
- `gpu/`: The SDL_gpu based GPU abstraction.
- `xr/`: The VR abstraction layer.
  - `xr/openxr/`: The OpenXR implementation of the abstraction layer.
  - `xr/openvr/`: The OpenVR implementation of the abstraction layer.
- `openxr/`: The OpenXR wrapper.
- `renderite/generator/`: Generates type definitions from the Renderite DLL file.
- `renderite/shared/`: Auto-generated types from the Renderite DLL file. Should stay in sync with engine updates.
