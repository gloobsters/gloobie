# gloobie

A cross-platform experimental renderer for Resonite.

## Legalities

> This project is not affiliated with Yellow Dog Man Studios or Resonite in any way, shape, or form. Any issues encountered while using Gloobie should be reported to our issue tracker, not to them.

## Disclaimer

This project is still in it's early-early stages, so we are not ready to take on external contributions yet. There's certain ways we would like things to be implemented to lay the foundation for future code that we have not documented, and external contributions on core parts would only slow us down as of now, since we very frequently do heavy refactors and rewrite large chunks of code, causing extra merge conflicts and painful review processes.

If you're interested in contributing, please get in touch and we'll let you know when we're ready for it, or if there's certain things outside of the core projects that you can help with!

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
