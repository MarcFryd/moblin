# Testing the WagaWebRTC fork

This fork combines Moblin `ios-35.0.0-245` with the WagaWebRTC integration tested
against [WagaStrim](https://github.com/Anywaystv/wagaStrim). It is experimental;
test your setup before relying on it for a live broadcast.

## Build on a Mac

You need full Xcode 26.6 or newer, Python 3, Rust installed through rustup, and an
Apple development team that can sign an app for your iPhone.

```sh
git clone --recurse-submodules --branch wagawebrtc-testing https://github.com/MarcFryd/moblin.git
cd moblin
sh WagaWebRTC/scripts/build-xcframework.sh
cp User.template.xcconfig Config/User.xcconfig
```

The submodule pins the WagaWebRTC source version. After pulling updates, run
`git submodule update --init --recursive` and rebuild the XCFramework before
opening Xcode. Downloading the repository ZIP does not include the submodule.

Edit `Config/User.xcconfig`: set `DEVELOPMENT_TEAM` to your team ID and choose a
unique `BASE_PRODUCT_BUNDLE_IDENTIFIER`. Keep `CAPABILITIES = free` unless your
team has the required additional capabilities. This local file is gitignored;
do not commit your signing configuration.

Open `Moblin.xcodeproj`, select the **Moblin** scheme and your connected iPhone,
then build and run. A separate bundle identifier keeps this test app separate
from the App Store installation. Upstream App Store and TestFlight builds do not
contain the WagaWebRTC integration.

The included core build supports iPhone and iOS Simulator. It does not include
a Mac Catalyst slice, so the upstream Catalyst unit-test command cannot run with
this XCFramework.

## Stream test

1. Create a WHIP stream and enter your sender URL. Start with H.264 video and
   Opus audio; AAC publishing is experimental and needs receiver support.
2. In the stream's WHIP settings, enable adaptive bitrate and bonding. Both
   are enabled by default in this fork. Connection priorities control the
   preference for Wi-Fi, cellular, and wired Ethernet.
3. Use a compatible WagaStrim ingest for the bonding test. Keep cellular enabled,
   then disconnect and reconnect Wi-Fi while watching the received stream.
4. Compare with bonding disabled, and include both normal motion and a dark,
   stationary scene when testing adaptive bitrate.

Bonding can use cellular data while Wi-Fi is connected. Adaptive bitrate may
reduce the encoder target when the transport reports less available capacity.
Earlier phone tests showed smooth handoffs; one dark-scene bitrate drop was not
reproduced on the repeat test and remains worth checking.

## Report a result

Open an issue on this fork with the fork commit, iPhone model, iOS version,
video/audio codecs, target bitrate, receiver version, and whether bonding and
adaptive bitrate were enabled. Describe any network switches and when a problem
occurred. Remove stream URLs, keys, tokens, and private addresses from logs and
screenshots before sharing them.

Moblin and its dependencies keep their upstream licenses and attribution.
WagaWebRTC's generated XCFramework includes its project and dependency notices.
