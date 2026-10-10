# Playndgain iOS SDK

A native offerwall for iOS apps: an offer list, offer details and the player's history, built with UIKit. Offers open in Safari or the App Store. Rewards reach your server by the same signed postback the iframe wall uses.

- iOS 13+, Swift 5.9, UIKit. No third-party dependencies.
- Swift Package Manager and CocoaPods.
- Your secret key never goes into the app.

## Install

Not published yet. Until it is, add this folder as a local package (File → Add Package Dependencies → Add Local…), or in a `Podfile`:

```ruby
pod 'Playndgain', :path => '../playndgain-ios'
```

## Use

```swift
import Playndgain

Playndgain.initialize(appId: "YOUR_APP_ID")

Playndgain.setUser("4812") { appId, userId, completion in
    // Ask your own server for sha256(appId + userId + secret), then:
    completion(.success(sigFromYourServer))
}

Playndgain.delegate = self          // PlayndgainDelegate, held weakly
Playndgain.show(options: PlayndgainOptions(subIds: ["spring_promo"]))
```

`playndgainRewardCheck()` is a prompt to look, not a payment. Credit the player from your postback.

## What the SDK sends

| Field | What |
|---|---|
| User-Agent | The WKWebView shape for this device and iOS version, plus ` PlayndgainSDK/<version>` |
| `sdk`, `sdk_v`, `model` | Platform, SDK version, `utsname.machine` (e.g. `iPhone15,2`) |
| `dh` | `utsname.machine`. Used only by the emulator check |
| `ds` | A small device-signal token in the format the wall's identity checks already read |

No IDFA, no IDFV, nothing persistent. `setAdvertisingIdEnabled` and `setChildDirected` are stored and nothing reads them in 1.0. When a later version uses the opt-in, it will read the IDFA only if the app already has App Tracking Transparency permission, and it will never show the prompt itself.

## Example app

`Example/` signs on the device with a secret typed into a field. That is a test shortcut and must never ship: a real app asks its own server for the signature.
