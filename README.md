# gloobie

## Sub-projects

- `client/`: The main client.
- `gpu/`: The SDL_gpu based GPU abstraction.
- `xr/`: The VR abstraction layer.
  - `xr/openxr/`: The OpenXR implementation of the abstraction layer.
  - `xr/openvr/`: The OpenVR implementation of the abstraction layer.
- `openxr/`: The OpenXR wrapper.
- `renderite/generator/`: Generates type definitions from the Renderite DLL file.
- `renderite/shared/`: Auto-generated types from the Renderite DLL file. Should stay in sync with engine updates.
