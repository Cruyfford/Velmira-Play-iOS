# Sony Remote Play inside Velmira — experimental SONY-HOST route

The user's requested integration is **not** an external link to Sony Remote Play. The goal is to remove Chiaki and run Sony's streaming engine in the **same application**, while eventually retaining Velmira's own controls and UI.

## Confirmed by inspecting the user-provided Sony 9.5.0 ZIP locally

- `Payload/RemotePlay.app/RemotePlay`: Mach-O arm64 `MH_EXECUTE`, not a reusable dylib.
- Decryption flag: `cryptid=0` in `LC_ENCRYPTION_INFO_64`.
- Private frameworks: `PMLSXClient`, `scenp`, `SocketRocket`, telemetry. No public standalone streaming interface is available from these libraries.
- The Sony app binary and dependencies must not be published in this GitHub repo.

## Implementation approach

This prototype builds an unsigned, dynamically linked `VelmiraSonyOverlay.dylib` which can be added by a **local-only** patcher to the user-supplied Sony executable as a load command. Sony's executable (not Chiaki) remains the runtime host.

The overlay currently displays only a floating diagnostic button `V` and a small label, in the Sony process. It has **no access yet** to Sony stream frames or controller events, and does not port Velmira's AI, touch interface, weapon profiles or settings.

The user-specific local packaging script lives in the accompanying ZIP output (it is not published with proprietary Sony executables). Its output needs to be re-signed with the same team for all bundled executable code, and evaluated on a real phone.

## Compile

See GitHub Action `Build experimental Sony-host overlay` for an arm64 iOS dylib artifact; the compiled artifact is **unsigned**.

## Risks, validation and status

- No Xcode build/phone/PS5 runtime verification of the final Sony-host app yet.
- Sony account, private entitlement, and code-signature checks may prevent a re-signed Sony app from working.
- Adding a Mach-O load command invalidates existing signatures, so do not install an output without correctly re-signing every embedded framework and dylib.
- The old Chiaki-based Velmira app is **not changed on main**. Delete/replace it only after same-process Sony streaming is validated on a real PS5.
- This is a **prototype**, not a production-ready engine replacement.
