The notch glow in `swift/Sources/Parakey/NotchGlow.swift` retains the layered
angular-gradient approach and palette from Jacob Mobin’s AppleIntelligenceGlowEffect.
The renderer now uses Core Animation with cached Gaussian masks, driven by the
application’s display link. It has no visible stroke, filled camera shape, random
gradient timer, or independently animated SwiftUI view.

Source: https://github.com/jacobamobin/AppleIntelligenceGlowEffect/blob/main/IOS.swift

Retrieved on 2026-10-15. Original file SHA-256:
`7cf5ea320fb098c0b03620b54555ebdb7840dc8d11c8e090a6a7bc478168d36e`.

Geometry comes from NSScreen. The light reveals from the center, responds to
microphone levels with a time-based envelope, and changes to a sweeping light
while transcribing. Reduce Motion keeps the color and opacity feedback and
removes continuous movement. All rendering stops when hidden.
The MIT license is preserved here and copied into the installed application.
