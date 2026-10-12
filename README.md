# Playndgain iOS SDK

A native offerwall for iOS apps: an offer list, offer details and the player's history, built with UIKit. Offers open inside the app (see below). Rewards reach your server by the same signed postback the iframe wall uses.

- iOS 15+, Swift 5.9, UIKit. No third-party dependencies.
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

## How an offer opens

"Start this offer" shows a short loading state while the SDK follows the offer's link in a web view the player does not see yet. The link is requested once.

- An App Store app: the App Store sheet opens over the wall. If the product cannot load (the simulator has no App Store), the App Store app opens instead.
- Another app's link: the system opens that app.
- A web page, or no store within about 8 seconds: the same web view rises as a sheet with a Close button.

`playndgainRewardCheck()` fires once per offer: when the player closes the store sheet or the web sheet, or when the app comes back to the foreground after the offer left it.

## What the SDK sends

| Field | What |
|---|---|
| User-Agent | The WKWebView shape for this device and iOS version, plus ` PlayndgainSDK/<version>` |
| `sdk`, `sdk_v`, `model` | Platform, SDK version, `utsname.machine` (e.g. `iPhone15,2`) |
| `dh` | `utsname.machine`. Used only by the emulator check |
| `ds` | A small device-signal token in the format the wall's identity checks already read |

No IDFA, no IDFV, nothing persistent. `setAdvertisingIdEnabled` and `setChildDirected` are stored and nothing reads them yet. When a later version uses the opt-in, it will read the IDFA only if the app already has App Tracking Transparency permission, and it will never show the prompt itself.

## Example app

`Example/` signs on the device with a secret typed into a field. That is a test shortcut and must never ship: a real app asks its own server for the signature.
