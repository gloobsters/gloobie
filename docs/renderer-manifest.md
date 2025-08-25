# Renderer Manifest File Specification, Version 1

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", and "MAY" in this documentation are to be interpreted as described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119).

The Renderer Manifest File describes a custom Renderer compatible with FrooxEngine. It includes the name and details required for a Bootstrapper to run the Renderer.

This also covers how Bootstrappers should implement things when reading them.

## Glossary

"FrooxEngine" refers to the engine Resonite runs under.

"Installation Directory" refers to the place at which the FrooxEngine game is installed to - usually the same folder as `FrooxEngine.dll` and `Renderite.Shared.dll`.

"Wine" refers to the Windows compatibility layer on unix-like platforms. It can also mean Proton, the fork shipped with Steam.

"Renderer" refers to a program implementing FrooxEngine's IPC bindings, usually using the GPU to draw the scene for the user.

"Bootstrapper" refers to a program that starts both FrooxEngine and a Renderer.

## Location, format, and naming

The Renderer Manifest File MUST reside in the "Renderers" subdirectory of the Installation Directory with an extension of `.renderer.json`.
As an example, Gloobie's manifest is stored as "Renderers/Gloobie.renderer.json".

This file and the contents within MUST be encoded as either UTF-8 or WTF-8, with no Byte Order Mark (BOM).

## Versioning

`int` `version` refers to the schema version of the manifest file.
`version` MUST be present, MUST be an integer, and MUST be the first field in the file.

## Compatibility between versions

Bootstrappers MUST be backwards and forwards compatible with every version of this specification. In other words, the Bootstrapper MUST still try to launch the Renderer using the data it has available, even if the manifest version is not equal to the implemented version.

For example, if a Bootstrapper is targeting Version 2, and comes across a manifest of Version 1, it MUST NOT fail due to a missing field.

The Bootstrapper MAY warn the user if the manifest version is higher than expected. For example, if the Bootstrapper implements Version 1, but sees an unknown field or a manifest of Version 2, the Bootstrapper could warn the user to update their Bootstrapper before launching that Renderer.

## Fields

The word `optional` below means that the field MAY be excluded or left as `null`. A RECOMMENDED fallback path is provided for these fields when this is the case.

This does not mean `optional` fields may be entirely unhandled by the Bootstrapper - Bootstrappers MUST implement support for `optional` fields in the case that they are present.

Fields not marked `optional` MUST be present and valid.

## Version 1

### `string` `name`

A user-friendly name of the Renderer. This can be any text, but MUST NOT be over 64 bytes.

Example: `"Gloobie"`

### `string` `winExecutablePath`

The path to the Renderer to run on Windows.

This SHOULD be relative to the Installation Directory, but MAY be a full path for the purposes of development.

This path MUST be a valid UTF-8/WTF-8 sequence that when represented as WTF-16 does not exceed the maximum path length on Windows.

Example: `"Renderers/Gloobie/Gloobie.exe"`

### `string` `unixExecutablePath`

The path to the Renderer to run on Linux, MacOS, and other unix-like platforms.

This SHOULD be relative to the Installation Directory, but MAY be a full path for the purposes of development.

This path MUST be a valid UTF-8, and the length when represented as bytes MUST not exceed the maximum path length on Linux.

This MAY be an empty string, however this is only the case when `runInWine` is set to `true`. In the case that both are set, this field MUST be ignored in favor of `winExecutablePath`.

Example: `"Renderers/Gloobie/Renderite.Gloobie"`

### `optional` `bool` `runInWine`

When `true` on unix-like platforms, the Renderer should be executed under a Wine context using the `winExecutablePath`.

This should generally be unnecessary, excluding the default renderer.

Default: `false`