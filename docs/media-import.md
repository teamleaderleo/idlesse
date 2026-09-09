# Media import

Library imports reference playable JPG/PNG/HEIC/MP4/MOV files directly. Non-native
GIF/APNG/WebP, AVIF/TIFF/BMP/JP2/JXL, MKV/WebM/AVI/M4V/MPEG/TS/MTS/M2TS/WMV/FLV/OGV
imports use the installed FFmpeg at /opt/homebrew/bin or /usr/local/bin. MP4/MOV
that AVFoundation cannot play also take the conversion path.

Conversion runs outside the main thread, one batch at a time. Motion becomes
silent HEVC (CRF 22); still images become PNG. Originals are never overwritten.
Frame dimensions/cadence are retained, with odd video dimensions padded for HEVC.
Codec availability depends on the installed FFmpeg; this is not support for every
possible codec, DRM, or corrupt input. HDR tone mapping is not qualified.

Derivatives live in ~/Library/Application Support/Idlesse/Converted Media.
Source path, modification time, size, and conversion revision determine reuse.
Each conversion has a 256 MiB output ceiling; results near that ceiling are rejected
and partial files removed. A new job requires the directory to be below 768 MiB,
reserving headroom within 1 GiB for its output. Existing derivatives are retained
because Library entries may reference them; removing a Library entry does not
delete media. Closing the main window or quitting cancels an active conversion.

Run bash test-media-import.sh with FFmpeg installed for GIF/WebM conversion,
original preservation, cache reuse, invalid input, and cancellation checks.

Library video previews show measured source dimensions and frame rate. Posters
remain bounded 512-pixel stills; desktop playback uses the actual media source.
