# online-status

Simple macOS menu bar app to show online status. Good for iffy network conditions like when
tethered to personal hotspots or train/bus wifi.

A coloured dot in the menu bar shows how your connection is doing:

| Icon | Meaning |
|---|---|
| 🟢 | Good |
| 🟡 | Mixed |
| 🔴 | Poor |
| ⚫ | No connectivity |
| 🔒 | Wi-Fi login required (captive portal) |
| ◯ | Measuring (just started, or the network changed) |

Hover over the dot for the latest latency and statistics for the last five minutes.
Click it for a graph of the last five minutes, with Probe Now, Settings and Quit buttons.

## How it checks

Every 10 seconds (configurable) it runs one probe, with a 3 second timeout (configurable).
Timeouts count as failures. Only one probe runs at a time.

* **Ping** (default): an ICMP echo to `8.8.8.8` or a host of your choice (IPv4 only). It uses an
  unprivileged ICMP socket, so it needs no root access. Inside the App Sandbox this needs the
  incoming-network entitlement as well as the outgoing one.
  About 100 bytes per probe: under 1 MB a day at the default interval.
* **Fetch URL**: an HTTP GET of `https://connectivitycheck.gstatic.com/generate_204` or a URL of
  your choice. Redirects are not followed. With "204 No Content only" (for `generate_204`),
  a 200 or a redirect means a captive portal is in the way and shows 🔒. With "Any 2xx" (for other
  URLs), a redirect shows 🔒. HTTPS certificate errors also show 🔒, since portals often intercept
  HTTPS. Connections are reused, so each probe costs roughly one round trip plus about 1 KB.

## How the status is decided

The samples from the last minute (or six probe intervals, if that is longer) are summarised:

* **Good**: no failures, median latency below 150 ms, and 90th percentile below 375 ms
  (2.5 × the good threshold).
* **Mixed**: up to 20% failures, and median latency up to 500 ms.
* **Poor**: anything worse.
* **No connectivity**: two failures in a row, or macOS reports no network.

The status **drops immediately** but **improves slowly**: it climbs one level at a time, and only
after the samples have looked better for 30 seconds (and at least three probes). Coming back from
no connectivity always goes to poor first. With the defaults, a single lost ping takes you from
green to yellow at once, and about 100 seconds later (a minute for the failure to leave the window, then 30 s per level) you are back to green.

When the network changes (different interface or Wi-Fi network, or waking from sleep), the
status restarts from "measuring" and a probe runs right away. The graph keeps the earlier data.

The good and poor latency thresholds and the recovery time are in Settings.

## Building

Requires macOS 14 or later and Xcode 15 or later.

```sh
scripts/build-app.sh          # builds and ad-hoc signs build/OnlineStatus.app
open build/OnlineStatus.app
```

Copy `build/OnlineStatus.app` to `/Applications` to keep it, and turn on "Launch at login" in
Settings. Because it is only ad-hoc signed, the first time you may need to right-click the app
and choose Open.

Run the unit tests (status logic, statistics, ICMP packets) with `swift test`.

### Mac App Store

The app is sandboxed, so it is App Store friendly. It has the outgoing network entitlement and
also the incoming one (`com.apple.security.network.server`), because the sandbox treats ping
replies as incoming traffic. It does not listen on any port; App Review may ask about this.
To build an archive in Xcode:

```sh
brew install xcodegen
xcodegen generate
open OnlineStatus.xcodeproj
```

Then set your team under Signing & Capabilities and use Product › Archive. The bundle identifier
is `io.github.briandealwis.OnlineStatus`; change it in `project.yml` and `App/Info.plist` if needed.
`App/Info.plist` allows plain-HTTP loads so that `http://` check URLs work; App Review may ask
why (the answer: user-configured connectivity check URLs).

## Layout

* `Sources/OnlineStatusCore`: platform-independent logic (samples, statistics, status evaluation,
  ICMP packet encoding, settings), with tests in `Tests/`.
* `Sources/OnlineStatus`: the AppKit/SwiftUI app: probes, monitor, menu bar item, graph, settings.
* `App/`: `Info.plist` and entitlements, shared by the SwiftPM script and the Xcode project.
