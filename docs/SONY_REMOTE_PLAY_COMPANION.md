# Sony PS Remote Play 9.5.0 — companion launch (experimental)

## What this implements
On the PS5 screen in Velmira, **فتح Sony PS Remote Play** asks iOS to open the separately installed Sony app.
The URL scheme `com.playstation.remoteplay.sceappcall` was read from the user-supplied Sony 9.5.0 (build 1751) app bundle's `Info.plist`.
This is an experimental launch scheme; it is **not** a documented public launch API and has not been validated on a physical iPhone.

## What it does NOT implement
- It does not embed Sony's executable or frameworks into Velmira.
- It does not capture Sony's video stream or share the Sony app's decrypted content, process, account tokens, controller commands, or data.
- Velmira's AI overlays and controller features are **not** visible or operable over the separate Sony app.
- It does not replace or interrupt the existing in-app Chiaki/TP Play Remote Play engine.

## iPhone test
1. Install Sony PS Remote Play separately (the user's already-working build, or the official App Store edition).
2. Install the Velmira development build.
3. Open **PS5** → **فتح Sony PS Remote Play**.
4. Verify whether iOS switches to Sony and whether Sony can connect to the console.
5. Return to Velmira and confirm the existing paired-console in-app session still launches normally.
6. If opening fails, the app shows a message rather than silently claiming a connection.

## Why a full Sony-in-Velmira client is not present
Sony's redistributed app bundle is a signed, closed-source application rather than a reusable iOS SDK.
Standard iOS app sandboxing prevents a separate application from embedding its UI/stream into Velmira, or drawing Velmira overlays inside Sony.
A genuine same-screen, in-process client with Velmira's analysis should continue to use the already-integrated open-source Remote Play implementation, or require an officially supported Sony SDK/interface.
Do not commit Sony binaries, credentials, or private tokens.

## Validation
Source changes made on the feature branch; source anchors verified after editing.
Xcode/iPhone and PS5 runtime testing were **not** performed.
