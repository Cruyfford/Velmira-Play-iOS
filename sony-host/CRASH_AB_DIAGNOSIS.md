# Sony Remote Play launch crash — A/B test (31 Oct 2026)

The user's re-signed V2 Sony-host IPA crashes at launch. **A working Sony host on iPhone is not established.** Do not merge to main.

## Offline analysis of user's signed IPA

- The ZIP archive is structurally intact; the Sony executable, six nested frameworks and Velmira overlay are present.
- All 1008 main executable code pages match the signed SHA-256 CodeDirectory digests.
- The injected overlay and six nested Sony frameworks also match their embedded CodeDirectory page digests.
- The main Info.plist, CodeResources and XML/DER entitlements special-slot SHA-256 digests also match.
- There is a notable **identity mismatch**: the signed bundle ID and CodeDirectory identifier use one ID, while the `application-identifier` entitlement and provisioned App ID use a different ID. This is a code-signing/provisioning consistency problem. Static digest checks do **not** establish that iOS policy will accept the signature.
- The executable has `LC_LOAD_DYLIB` for `@executable_path/Frameworks/VelmiraSonyOverlay.dylib`, and the library exists at that location.
- The precise cause of the user's crash is **not** established without an iOS `.ips` report.

## Isolate the failure with consistent signing

Prepare two *unsigned* variants locally from the user's own decrypted Sony ZIP (not committed into this public repository):

A. Original Sony 9.5.0 without any Velmira library or load-command patch.
B. Original Sony 9.5.0 plus an arm64 `VelmiraSonyOverlay.dylib` **no-op** built from `VelmiraNoopProbe.m`, injected with `inject_sony.py`. The probe imports no UIKit and does no application-level work.

Use the **same signer, certificate, provisioning/profile, device, and app identity configuration** for both. Ensure the final signed CFBundleIdentifier and application-identifier/provisioning are consistent. Test A first:

- **A crashes:** the fault occurs without any Velmira hook; investigate re-signing, profile, entitlements, Sony's own startup assumptions, and decrypted input.
- **A runs, B crashes:** investigate added dylib signature/trust, loading and dependency resolution, re-signed resources and dyld/AMFI policy.
- **A and B run, UI-equipped V2 crashes:** focus on the Objective-C UIKit overlay lifecycle.

If test output depends on an incorrect App ID setting or Sony entitlement, fix signing first before interpreting the comparison. A successful A/B test is not the full Velmira feature integration.

## Build the diagnostic dylib

The `sony-host-overlay.yml` workflow now builds both the experimental overlay and the no-op probe on macOS. The no-op artifact contains one `VelmiraSonyOverlay.dylib` with install name `@rpath/VelmiraSonyOverlay.dylib`. Use `inject_sony.py` to add it to the user's locally supplied Sony 9.5.0 input.

Do not upload Sony's executables, customer certificates, provisioning profiles or PSN credentials to GitHub.
