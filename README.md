# online-status

Online Status is a macOS menu bar application. It shows the quality of your internet connection.
Use it when the network is not reliable, for example a personal hotspot or Wi-Fi on a train or bus.

A colored dot in the menu bar shows the status of the connection:

| Icon | Meaning |
|---|---|
| 🟢 | Good |
| 🟡 | Mixed |
| 🔴 | Poor |
| ⚫ | No connectivity |
| 🔒 | You must log in to the Wi-Fi network (captive portal) |
| ◯ | Measurement in progress (the application started, or the network changed) |

When the status decreases, the dot pulses for approximately 12 seconds. For example, this
occurs when the status changes from green to yellow, from yellow to red, or from red to black.
To stop the pulse, click the dot. You can set this function to off in Settings. If Reduce Motion is on, the
dot shows a steady highlight and does not pulse.

Put the pointer on the dot to see a summary. The summary shows the latest latency. It also shows
the median, p90, maximum and loss for the last five minutes. The summary updates each second.

<img src="docs/screenshots/hover.png" width="364" alt="Summary panel. It shows the status, the latest latency, the median, p90 and maximum latency and the loss for the last 5 minutes, and the probe method and interval">

Click the dot to see a graph of the last five minutes. The graph has these parts:

* The line shows the latency of each probe. A probe that failed makes a gap in the line.
* The color of the background shows the status.
* The dashed lines show the thresholds for good and poor.
* A red vertical line shows a probe that failed.

Below the graph is the Probe Now button.

To see the menu, right-click the dot. You can also Control-click or Command-click the dot. The
menu has these items: Probe Now, Settings… and Quit Online Status.

<img src="docs/screenshots/graph.png" width="464" alt="Graph panel with five minutes of demo data: good latency, a slowdown, two failed probes, then recovery. The background color shows the status at each time. Below the graph are the median, p90, min/max, loss and probe count">

### Settings

| | |
|---|---|
| <img src="docs/screenshots/settings-probe.png" width="256" alt="Settings, Probe page: method, host, interval, timeout and personal hotspot options"> | <img src="docs/screenshots/settings-status.png" width="256" alt="Settings, Status page: latency thresholds, recovery time and the pulse option"> |
| <img src="docs/screenshots/settings-log.png" width="256" alt="Settings, Log page: log option, retention period, Show in Finder and Export"> | <img src="docs/screenshots/settings-launch.png" width="256" alt="Settings, Launch page: launch at login and Restore Defaults"> |

A GitHub Actions workflow makes these screenshots from demo data after each change to the
source code. To make them on your Mac, run
`./build.sh screenshots`.

## How the application does a check

The application does one probe at an interval. The default interval is 10 seconds. The default
timeout is 3 seconds. You can change these values in Settings. A timeout is a failure. Only one
probe operates at a time.

When the status changes, the application does probes more frequently for a short time. Thus
you can see how long a drop or a recovery continues. By default, the application does a probe
each 2 seconds for 1 minute after each change. Then it uses the usual interval again. You can
change these values, or stop this function, on the Probe page in Settings.

On a personal hotspot, the application does fewer probes. This decreases the quantity of data
that it uses. This occurs when one of these conditions is true:

* macOS identifies the network as expensive. An iPhone hotspot or another personal hotspot is
  an expensive network.
* Low Data Mode is on.

In these conditions, the default interval is 30 seconds. You can change this value in Settings,
or you can stop this function. The summary and the graph then show "(tethered)". At the longer
interval, the status uses the last six probes (three minutes). Thus the status changes more slowly.

There are two types of probe:

* **Ping** (the default). The application sends an ICMP echo to `8.8.8.8`, or to a host that
  you select. Only IPv4 is possible. The application uses an unprivileged ICMP socket, thus it
  does not need root access. Each probe uses a random identifier, sequence number and payload.
  The application accepts a reply only if all three agree and the reply comes from the target
  address. In the App Sandbox, the application must have the entitlement for
  incoming network traffic and the entitlement for outgoing network traffic. Each probe uses
  approximately 100 bytes. At the default interval, this is less than 1 MB each day.
* **Fetch URL**. The application sends an HTTP GET request to
  `https://connectivitycheck.gstatic.com/generate_204`, or to a URL that you select. The URL
  must start with `https://`. Plain `http://` is possible only for these connectivity-check
  hosts: `captive.apple.com`, `connectivitycheck.gstatic.com`, `clients3.google.com`,
  `detectportal.firefox.com` and `www.msftconnecttest.com`. The application does not follow
  redirects. It reads only the response headers and does not read the body. Use the setting
  that agrees with the URL:
  * "204 No Content only" (for `generate_204`). A 200 response or a redirect shows 🔒. This
    response or redirect usually comes from a captive portal.
  * "Any 2xx" (for other URLs). A redirect shows 🔒.

  An HTTPS certificate error also shows 🔒, because captive portals frequently intercept HTTPS.
  The application uses the same connection again for each probe. Thus each probe uses
  approximately one round trip and 1 KB.

## How the application calculates the status

The application uses the probes from the last minute. If six probe intervals are longer than
one minute, it uses the probes from the last six intervals.

* **Good**: No failures. The median latency is less than 150 ms. The 90th percentile is less
  than 375 ms (2.5 × the good threshold).
* **Mixed**: Not more than 20% failures. The median latency is not more than 500 ms.
* **Poor**: The result is worse than mixed.
* **No connectivity**: Two failures occur one after the other, or macOS shows that there is
  no network.

The status **decreases immediately**, but it **increases slowly**. The status increases one
level at a time. Before each increase, the probes must show a better result for 30 seconds and
for a minimum of three probes. After "No connectivity", the status always goes to "Poor" first.

Example with the default settings: one ping fails. The status changes from green to yellow
immediately. The failed ping stays in the calculation for one minute. Then each level takes
30 seconds. Thus the status is green again after approximately 100 seconds.

When the network changes, the status starts again from "Measurement in progress". The
application then does a probe immediately. These events change the network:

* A change to a different interface.
* A change to a different Wi-Fi network.
* The Mac wakes from sleep.

The graph keeps the data from before the change.

You can change the thresholds for good and poor latency in Settings. You can also change the
time before the status increases.

## Connectivity log

You can record a log of the connection quality with the network and the location. Use the log to
find where the connection is frequently poor, for example on your commute. To start the log, go
to Settings › Log and set "Log connectivity with network and location" to on.

The log is a CSV file. Each row is one period with the same status, the same network and
approximately the same place. Thus the file stays small. A row stops and a new row starts when
one of these events occurs:

* The status changes.
* The network changes.
* The Mac moves more than 1 km.
* The row is 15 minutes long.
* The Mac goes to sleep, or the application stops. The time asleep is not in the log.

The application updates the last row after each probe. Thus the file always shows the current
period.

The columns are: `start`, `end`, `duration_s`, `status`, `network`, `latitude`, `longitude`,
`accuracy_m`, `probes`, `failed`, `loss_pct` and `median_ms`. The times are local time.
The `network` column shows the type of network, for example `Wi-Fi: TrainNet`,
`Hotspot: Brian's iPhone`, `Tethered (USB)` or `Ethernet`.

The Wi-Fi name and the coordinates need Location Services permission. macOS asks for this
permission when you start the log. If you do not give permission, the log does not contain the
Wi-Fi name or the coordinates. The application uses Location Services at an accuracy of
approximately 100 m.

The application deletes rows that are older than 90 days. You can change this period, or keep all
rows, in Settings. To see the file, click "Show in Finder". To save a copy, click "Export…". The
log stays on your Mac. The application does not send it to a different location.

Note: Each new ad-hoc build has a different signature. Thus macOS can ask for Location Services
permission again after you build the application again.

## How to build the application

You must have macOS 14 or later and Xcode 15 or later.

Use the `build.sh` script:

```sh
./build.sh              # Release build → build/OnlineStatus.app
./build.sh run          # Debug build and start
./build.sh test         # Run the unit tests
./build.sh screenshots  # Make docs/screenshots/*.png again
./build.sh install      # Release build, copied to ~/Applications
./build.sh dist         # Release build, packaged as build/OnlineStatus-<version>.zip
./build.sh clean        # Remove the build output
./build.sh help         # Show all commands and options
```

The script signs the application with an ad-hoc signature. To use your Apple Developer
identity, set `CODE_SIGN_IDENTITY`. To build for Apple silicon and Intel, set `UNIVERSAL=1`.

To keep the application, do these steps:

1. Run `./build.sh install`.
2. In Settings, set "Launch at login" to on.

The application has only an ad-hoc signature. Thus macOS can stop it the first time that you
start it. If this occurs, right-click the application and select Open.

The unit tests examine the status logic, the statistics, the ICMP packets and the log.

### Mac App Store

The application operates in the App Sandbox. Thus it can be submitted to the Mac App Store.

The application has the entitlement for outgoing network traffic. It also has the entitlement
for incoming network traffic (`com.apple.security.network.server`). The sandbox identifies ping
replies as incoming traffic, thus this entitlement is necessary. The application does not listen
on a port. App Review can ask about this entitlement. For the connectivity log, the application
also has the location entitlement and the entitlement to write a file that the user selects.

To make an archive in Xcode, do these steps:

1. Run these commands:

   ```sh
   brew install xcodegen
   xcodegen generate
   open OnlineStatus.xcodeproj
   ```

2. In Signing & Capabilities, set your team.
3. Select Product › Archive.

The bundle identifier is `io.github.briandealwis.OnlineStatus`. To use a different identifier,
change it in `project.yml` and in `App/Info.plist`.

`App/Info.plist` lets the application load plain HTTP only from the connectivity-check hosts
in the list above. App Transport Security applies to all other hosts. If you change the list,
change `MonitorSettings.plainHTTPHosts` also.

## iPhone application

The project also contains an iPhone application. It shows the status, the graph and the
statistics on one screen. It uses the same probes and the same status rules as the Mac
application.

The iPhone application does probes only while it is open. When you go to a different
application, it stops. When you open it again, it starts the measurement again.

On cellular data or in Low Data Mode, the application does fewer probes. By default, it does a
probe each 30 seconds. You can change this value in Settings.

To install the iPhone application, do these steps:

1. Run these commands on your Mac:

   ```sh
   brew install xcodegen
   xcodegen generate
   open OnlineStatus.xcodeproj
   ```

2. In Xcode, select the `OnlineStatusiOS` scheme and your iPhone.
3. In Signing & Capabilities, set your team.
4. Select Product › Run.

With a free Apple ID, the application stops after 7 days. Then you must install it again. With a
paid Apple Developer account, this does not occur.

## Layout

* `Sources/OnlineStatusCore`: The logic that does not change between platforms. This includes
  samples, statistics, status calculation, ICMP packet encoding and settings. The tests for this
  logic are in `Tests/`.
* `Sources/OnlineStatus/Shared`: The monitor, the probes and the graph. The Mac application and
  the iPhone application both use these files.
* `iOS`: The iPhone application: the main screen and the settings.
* `Sources/OnlineStatus`: The AppKit/SwiftUI application. This includes the probes, the monitor,
  the menu bar item, the graph and the settings.
* `App/`: The `Info.plist` file and the entitlements. The SwiftPM script and the Xcode project
  both use these files.
