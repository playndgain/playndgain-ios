# Testing the iOS SDK

Run on the Mac with Xcode (27 here) and an iPhone simulator (`iPhone 17 Pro` here).

## 1. Unit tests

```
xcodebuild -scheme Playndgain -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Expected: 20 tests, 0 failures. `swift build` alone does not work: UIKit needs an iOS destination.

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

- **Offers → detail → Start → Safari → back → History → Close.** Checks the detail sheet, that the click leaves for Safari, that the click shows in History, and that the delegate saw `didOpen`, `rewardCheck` and `didClose`.
- **Arabic.** `-lang ar`: the tab bar is mirrored.
- **Blocked.** Skipped unless the wall is set up to refuse the simulator (below).

Screenshots are attached to the result bundle (`-resultBundlePath`).

## 4. Fraud parity on the simulator

The iOS simulator does not announce itself the way a stock Android emulator does: `utsname.machine` is `arm64` or `x86_64`, and the WKWebView User-Agent looks like an iPhone. The wall's `emulator_device` rule ships no signature for it on purpose (see the rule's docblock: only unambiguous strings ship). What is shared with the iframe on iOS is the whole server path: render gate, identity, consent, ban, and every pre-click rule on `/click`.

To exercise the blocked screen anyway, add `x86_64` or `arm64` to the rule's `signatures` in your local `fraud_rules` row only, and run `testBlockedNoticeOnEmulatorEvidence`. Never add those to production: a real device's `utsname` never says that, but the same token appears in some real User-Agents.

## 5. Things to check on a real iPhone before release

- iCloud Private Relay on: a click opens in Safari, and its egress may be classified as a proxy where the in-app iframe's would not. If so, decide between opening clicks in `SFSafariViewController` and accepting it.
- `pod lib lint Playndgain.podspec --allow-warnings` once the repository URL is filled in.
