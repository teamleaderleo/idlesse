// Scene.swift owns geometry helpers shared by the renderer and headless tests.
// Re-export CoreGraphics once for the runtime module so focused multi-file
// compilations see the same CGRect/CGSize API surface as the full app build.
@_exported import CoreGraphics
