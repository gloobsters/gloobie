# Renderer Manifest File Specification, Version 1

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", and "MAY" in this documentation are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

The renderer manifest file describes a custom renderer compatible with FrooxEngine. It includes the name and details required for a bootstrapper to run the renderer.

This also covers how bootstrappers should implement things when reading them.

## Glossary

"FrooxEngine" refers to the engine Resonite runs under.

"Installation Directory" refers to the place at which the FrooxEngine game is installed to - usually the same folder as `FrooxEngine.dll` and `Renderite.Shared.dll`.

"Wine" refers to the Windows compatibility layer on unix-like platforms. It can also mean Proton, the fork shipped with Steam.

"Renderer" refers to a program implementing FrooxEngine's IPC bindings, usually using the GPU to draw the scene for the user.

"Bootstrapper" refers to a program that starts both FrooxEngine and a Renderer.

## Location, format, and naming

The renderer manifest file is a JSON file with the extension of ".renderer.json". It MUST placed in a folder under Resonite's installation directory named "Renderers".
As an example, Gloobie's manifest is stored as "Renderers/Gloobie.renderer.json".

This file and the contents within MUST be encoded as either UTF-8 or WTF-8, with no Byte Order Mark (BOM).

## Versioning

`version` refers to the schema version of the manifest file.
`version` MUST be present, MUST be an integer, and MUST be the first field in the file.

## Compatibility between versions

Bootstrappers MUST be backwards and forwards compatible with every version of this specification. In other words, the bootstrapper MUST still try to launch the renderer using the data it has available, even if the manifest version is not equal to the implemented version.

For example, if a bootstrapper is targeting Version 2, and comes across a manifest of Version 1, it MUST NOT fail due to a missing field.

The bootstrapper MAY warn the user if the manifest version is higher than expected. For example, if the bootstrapper implements Version 1, but sees an unknown field or a manifest of Version 2, the bootstrapper could warn the user to update their bootstrapper before launching that renderer.

## Fields

The word `optional` below means that the field MAY be excluded or left as `null`. A RECOMMENDED fallback path is provided for these fields.

## Version 1

### `string` `name`

A user-friendly name of the renderer. This can be any text, but MUST NOT be over 64 bytes.

Example: `"Gloobie"`

### `string` `winExecutablePath`

The path to the renderer to run on Windows.

This SHOULD be relative to the Installation Directory, but MAY be a full path for the purposes of development.

This path MUST be a valid UTF-8/WTF-8 sequence that when represented as WTF-16 does not exceed the maximum path length on Windows.

Example: `"Renderers/Gloobie/Gloobie.exe"`

### `string` `unixExecutablePath`

The path to the renderer to run on Linux/Mac/other unix-like platforms.

This SHOULD be relative to the Installation Directory, but MAY be a full path for the purposes of development.

This path MUST be a valid UTF-8/WTF-8 sequence, and the length when represented as bytes MUST not exceed the maximum path length on Linux.

Example: `"Renderers/Gloobie/Renderite.Gloobie"`

### `optional` `bool` `runInWine`

When true on unix-like platforms, the Renderer should be executed under a Wine context. 

Default: `false`