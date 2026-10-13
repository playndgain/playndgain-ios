# Testing the iOS SDK

Run on the Mac with Xcode (27 here) and an iPhone simulator (`iPhone 17 Pro` here).

## 1. Unit tests

```
xcodebuild -scheme Playndgain -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Expected: 42 tests, 0 failures. `StoreLinkTests` pins which URLs are App Store products; `OfferResolutionTests` drives every navigation the click can take (store, app link, landing, timeout, failure) without a web view. `swift build` alone does not work: UIKit needs an iOS destination.

## 2. Serve the wall

From the wall repo, with a database that has an active app in test mode:

```
cd public
DB_DATABASE=<db> PLAYNDGAIN_DEV_COUNTRY=US APP_URL=http://localhost:8765 \
  php -S 0.0.0.0:8765 ../vendor/laravel/framework/src/Illuminate/Foundation/resources/server.php
```

The simulator shares the Mac's network, so `localhost` works. The Example allows local http through `NSAllowsLocalNetworking`; the SDK does not change ATS.

## 3. UI tests (end to end)

```
cd Example
xcodebuild -project PlayndgainExample.xcodeproj -scheme PlayndgainExample \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`WallUITests` launches the Example with `-base http://localhost:8765 -userid … -autoshow 1` and drives the real SDK screens:

- **Offers → Test Offer → Start → browser sheet → Close → History → Close.** The wall's test offer, in test mode, lands on the wall's own page, so the in-app browser sheet rises with it and nothing leaves for Safari. Checks the detail sheet, the sheet and its web view, that History renders, and that the delegate saw `didOpen`, exactly one `rewardCheck`, and `didClose`. If the click instead reaches a store link, the simulator cannot load the App Store sheet and the store URL opens outside the app; the test then accepts Safari or the App Store in front and comes back.
- **A click that reaches nothing.** Puzzle Quest in the demo data redirects to a host that does not resolve: the wall stays and a sheet says "Offer unavailable", a `network` error, no `rewardCheck`.
- **Arabic.** `-lang ar`: the tab bar is mirrored.
- **Blocked.** Skipped unless the wall is set up to refuse the simulator (below).

Screenshots are attached to the result bundle (`-resultBundlePath`).

## 4. Fraud parity on the simulator

The iOS simulator does not announce itself the way a stock Android emulator does: `utsname.machine` is `arm64` or `x86_64`, and the WKWebView User-Agent looks like an iPhone. The wall's `emulator_device` rule ships no signature for it on purpose (see the rule's docblock: only unambiguous strings ship). What is shared with the iframe on iOS is the whole server path: render gate, identity, consent, ban, and every pre-click rule on `/click`.

To exercise the blocked screen anyway, add `x86_64` or `arm64` to the rule's `signatures` in your local `fraud_rules` row only, and run `testBlockedNoticeOnEmulatorEvidence`. Never add those to production: a real device's `utsname` never says that, but the same token appears in some real User-Agents.

## 5. Things to check on a real iPhone before release

- The App Store sheet. `SKStoreProductViewController` cannot load products on the simulator, which always takes the fallback (the store URL opens outside the app). On an iPhone, a click that ends on an App Store link must show the product sheet over the wall; closing it fires `rewardCheck` once.
- A real advertiser chain: Start shows the loading state, then the store sheet or the browser sheet within about 8 seconds, never Safari.
- iCloud Private Relay on: the click runs in the app's own web view now, so its egress should match the wall's own requests.
- `pod lib lint Playndgain.podspec --allow-warnings` once the repository URL is filled in.

## 6. Running the Example on an iPhone

The project commits no team. Sign from the command line instead:

```
cd Example
xcodebuild -project PlayndgainExample.xcodeproj -scheme PlayndgainExample \
  -destination 'id=<device UDID>' DEVELOPMENT_TEAM=<team id> \
  CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES -allowProvisioningUpdates build
xcrun devicectl device install app --device <device UDID> <path to PlayndgainExample.app>
```

The phone needs Developer Mode on and the developer trusted under Settings > General > VPN & Device Management. The Example uses the scene lifecycle: current iOS stops an app built with the latest SDK that sets up its window in the app delegate.
